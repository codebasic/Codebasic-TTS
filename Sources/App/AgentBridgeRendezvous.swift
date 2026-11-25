// AgentBridgeRendezvous.swift
// Consent rendezvous: how the running app and the bundled bridge helper find each other without any
// owner-entered PID, port, socket path, signer fingerprint or app identifier.
//
// Design decision record
// - Each app process owns one private generation directory named from its own PID and kernel start
//   time inside the per-user 0700 root. A name that already exists is refused, so endpoints left by
//   an earlier run or a crash are never reused, repaired or unlinked. Only the inode this process
//   created is removed on a clean shutdown.
// - c.sock carries no user data: one fixed hello in, one status word out. The peer is authenticated
//   by its kernel audit token (same real and effective UID, fixed bridge identifier, this app's own
//   leaf certificate) before a single byte is read. Handshake JSON, process names, environment and
//   same-UID alone are never trusted. Ad hoc or unsigned builds do not listen at all.
// - A knock only lists a candidate. The owner approves exactly one listed process; several
//   candidates are shown side by side and never resolved silently. Nothing is persisted.

import Combine
import Darwin
import Foundation

/// Private AF_UNIX listener for the fixed hello. No public or network listener exists.
final class AgentRendezvousListener {
    typealias Authenticator = (Int32) -> AgentBridgeIdentity?

    private let directory: String
    private let path: String
    private let authenticate: Authenticator
    private let answer: (AgentBridgeIdentity) -> String
    private let queue = DispatchQueue(label: "com.codebasic.tts.agent-rendezvous")
    private var source: DispatchSourceRead?
    private var inode: ino_t = 0

    init(directory: String, authenticate: @escaping Authenticator,
         answer: @escaping (AgentBridgeIdentity) -> String) {
        self.directory = directory
        path = directory + "/" + AgentBridgeEndpoint.rendezvousName
        self.authenticate = authenticate
        self.answer = answer
    }

    static func isPrivateDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid()
            && (st.st_mode & 0o7777) == 0o700
    }

    /// Production authenticator: same real and effective UID, not this process, a live signature with
    /// the fixed bridge identifier and the pinned leaf certificate, then the kernel start time.
    static func signedBridge(leafSHA1: String) -> Authenticator {
        { fd in
            let identifier = AgentPeerSignature.bridgeIdentifier
            guard getuid() == geteuid(),
                  let peer = AgentPeerSignature.verifyConnectedPeer(fd: fd, expectedUID: getuid(),
                                                                    identifier: identifier, leafSHA1: leafSHA1),
                  let start = AgentBridgeEndpoint.Generation.live(pid: peer.pid),
                  // Checked again after the PID lookup so a PID reused in between is never mixed in.
                  AgentPeerSignature.verify(peer: peer, identifier: identifier, leafSHA1: leafSHA1) else { return nil }
            return AgentBridgeIdentity(pid: peer.pid, pidVersion: peer.pidVersion,
                                       startSeconds: start.startSeconds, startMicroseconds: start.startMicroseconds)
        }
    }

    /// Fails closed when the directory is not private or the path exists. Never unlinks to make room.
    func start() -> Bool {
        var st = stat()
        guard source == nil, Self.isPrivateDirectory(directory),
              lstat(path, &st) != 0, errno == ENOENT else { return false }
        var addr = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in bytes.withUnsafeBytes { dst.copyBytes(from: $0) } }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); return false }
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { close(fd); return false }
        inode = st.st_ino
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            close(fd); unlinkOwnSocket(); return false
        }
        let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setEventHandler { [weak self] in self?.acceptOne(fd) }
        listener.setCancelHandler { close(fd) }
        source = listener
        listener.resume()
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        unlinkOwnSocket()
    }

    private func unlinkOwnSocket() {
        var st = stat()
        if inode != 0, lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK,
           st.st_uid == getuid(), st.st_ino == inode { unlink(path) }
        inode = 0
    }

    private func acceptOne(_ listener: Int32) {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        // The security decision, taken before a single byte is read.
        guard let identity = authenticate(fd),
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return }
        guard let frame = readFrame(fd, deadline: DispatchTime.now() + .milliseconds(600)), Self.isHello(frame),
              authenticate(fd) == identity else { return }
        let object: [String: Any] = ["protocol": AgentBridgeEndpoint.protocolVersion, "status": answer(identity)]
        guard var out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        out.append(10)
        let deadline = DispatchTime.now() + .milliseconds(200)
        out.withUnsafeBytes { (view: UnsafeRawBufferPointer) in
            guard let base = view.baseAddress else { return }
            var sent = 0
            while sent < view.count {
                guard ready(fd, event: Int16(POLLOUT), deadline: deadline) else { return }
                let count = send(fd, base.advanced(by: sent), view.count - sent, 0)
                guard count > 0 else { return }
                sent += count
            }
        }
    }

    /// Exactly the fixed hello. Extra, missing or differently typed fields get no reply.
    static func isHello(_ frame: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any], object.count == 2,
              object["operation"] as? String == "hello",
              object["protocol"] as? Int == AgentBridgeEndpoint.protocolVersion else { return false }
        return true
    }

    /// One LF-terminated frame of at most 63 bytes followed by the client's half-close.
    private func readFrame(_ fd: Int32, deadline: DispatchTime) -> Data? {
        var frame = Data()
        var terminated = false
        var chunk = [UInt8](repeating: 0, count: 256)
        while ready(fd, event: Int16(POLLIN), deadline: deadline) {
            let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count == 0 { return terminated ? frame : nil }
            guard count > 0, !terminated else { return nil }
            let received = chunk.prefix(count)
            if let index = received.firstIndex(of: 10) {
                guard index == received.endIndex - 1 else { return nil }
                frame.append(contentsOf: received.prefix(upTo: index))
                terminated = true
            } else {
                frame.append(contentsOf: received)
            }
            guard frame.count < 64 else { return nil }
        }
        return nil
    }

    private func ready(_ fd: Int32, event: Int16, deadline: DispatchTime) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { return false }
        let ms = Int32((deadline.uptimeNanoseconds - now + 999_999) / 1_000_000)
        var target = pollfd(fd: fd, events: event, revents: 0)
        return poll(&target, 1, ms) > 0 && target.revents & event != 0
    }
}

@MainActor
final class AgentBridgeRendezvous: ObservableObject {
    enum Availability: Equatable { case stopped, listening, unsigned, identifierMismatch, endpointUnavailable }

    let admission = AgentBridgeAdmission()
    /// Public leaf certificate SHA-1 of this app's own valid signature; nil for ad hoc builds.
    let ownLeafSHA1: String?
    @Published private(set) var availability = Availability.stopped
    @Published private(set) var candidates: [AgentBridgeAdmission.Candidate] = []
    /// Private directory of this app generation. ai.sock and ad.sock are created here as well.
    private(set) var directory: String?
    private var created: (path: String, inode: ino_t)?
    private var listener: AgentRendezvousListener?
    private var timer: Timer?

    init() { ownLeafSHA1 = AgentPeerSignature.ownSignerSHA1() }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Creates root (if needed) and the generation directory. Existing entries are never repaired,
    /// reused or removed: a root that is not private, or a name that already exists, fails closed.
    nonisolated static func makeGenerationDirectory(root: String, generation: AgentBridgeEndpoint.Generation)
        -> (path: String, inode: ino_t)? {
        if mkdir(root, 0o700) != 0 && errno != EEXIST { return nil }
        guard AgentRendezvousListener.isPrivateDirectory(root) else { return nil }
        let path = root + "/" + generation.name
        guard mkdir(path, 0o700) == 0 else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, AgentRendezvousListener.isPrivateDirectory(path) else {
            rmdir(path)
            return nil
        }
        return (path, st.st_ino)
    }

    /// Starts listening. This grants nothing: a verified bridge can only become a listed candidate.
    func start() {
        guard listener == nil else { return }
        guard let leaf = ownLeafSHA1 else { availability = .unsigned; return }
        guard AgentPeerSignature.ownSigningIdentifier() == AgentPeerSignature.appIdentifier else {
            availability = .identifierMismatch
            return
        }
        guard getuid() == geteuid(), let generation = AgentBridgeEndpoint.Generation.live(pid: getpid()),
              let made = Self.makeGenerationDirectory(root: AgentBridgeEndpoint.root(uid: getuid()),
                                                     generation: generation) else {
            availability = .endpointUnavailable
            return
        }
        created = made
        let admission = self.admission
        admission.onChange = { [weak self] in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        }
        let socket = AgentRendezvousListener(directory: made.path,
                                             authenticate: AgentRendezvousListener.signedBridge(leafSHA1: leaf)) { identity in
            admission.knock(identity, now: ProcessInfo.processInfo.systemUptime).rawValue
        }
        guard socket.start() else {
            removeOwnDirectory()
            availability = .endpointUnavailable
            return
        }
        listener = socket
        directory = made.path
        availability = .listening
        let ticker = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func approve(_ identity: AgentBridgeIdentity) -> Bool {
        let granted = admission.approve(identity, now: uptime)
        refresh()
        return granted
    }

    func deny(_ identity: AgentBridgeIdentity) {
        admission.deny(identity, now: uptime)
        refresh()
    }

    /// Ends the approval; the same bridge process needs a new owner decision.
    func revoke() { admission.revoke() }

    /// Drops expired candidates and those whose process is gone, then publishes the list.
    func refresh() {
        let now = uptime
        admission.prune(now: now) { Self.isLive($0) }
        let next = admission.candidates(now: now)
        if next != candidates { candidates = next }
    }

    nonisolated static func isLive(_ identity: AgentBridgeIdentity) -> Bool {
        guard let live = AgentBridgeEndpoint.Generation.live(pid: identity.pid) else { return false }
        return live.startSeconds == identity.startSeconds && live.startMicroseconds == identity.startMicroseconds
    }

    /// Quit: stop listening, forget every decision and remove only what this process created.
    func shutdown() {
        timer?.invalidate()
        timer = nil
        listener?.stop()
        listener = nil
        admission.reset()
        if !candidates.isEmpty { candidates = [] }
        removeOwnDirectory()
        availability = .stopped
    }

    private func removeOwnDirectory() {
        // rmdir only succeeds on an empty directory, and only the inode created here is tried.
        var st = stat()
        if let made = created, lstat(made.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
           st.st_uid == getuid(), st.st_ino == made.inode { rmdir(made.path) }
        created = nil
        directory = nil
    }
}
