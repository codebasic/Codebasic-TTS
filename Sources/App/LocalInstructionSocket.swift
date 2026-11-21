import CryptoKit
import Darwin
import Foundation

/// An instruction grant is for one currently running process, not all same-UID processes.
struct LocalInstructionPeer: Equatable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func current(pid: pid_t) -> Self? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == geteuid(), info.pbi_ruid == getuid(), info.pbi_start_tvsec > 0 else { return nil }
        return Self(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    static func connected(_ fd: Int32) -> Self? {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              size == socklen_t(MemoryLayout<pid_t>.size) else { return nil }
        return current(pid: pid)
    }
}

struct LocalInstructionProfile {
    enum Name: String, CaseIterable { case explain, `continue`, normalize }
    let name: Name
    let text: String
    let revision: String

    init?(name: Name, text: String) {
        guard text.utf8.count <= 8 * 1024, !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.name = name
        self.text = text
        revision = SHA256.hash(data: Data("tts-profile-v1\0\(name.rawValue)\0\(text)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Read-only profile endpoint. Granting this transport never enables receipt or playback.
final class LocalInstructionSocket {
    private let transport: LocalApprovedSocket

    init(peer: LocalInstructionPeer, profile: LocalInstructionProfile,
         directory: String = LocalApprovedSocket.defaultDirectory,
         lifetime: DispatchTimeInterval = .seconds(600)) {
        transport = LocalApprovedSocket(peer: peer, endpoint: "i.sock", directory: directory,
                                        lifetime: lifetime, maxFrame: 128) { bytes, _ in
            guard let args = try? JSONDecoder().decode([String: String].self, from: bytes),
                  args == ["profile": profile.name.rawValue] else { return nil }
            let result: [String: Any] = ["schema_version": 1, "profile": profile.name.rawValue,
                                         "revision": profile.revision, "instructions": profile.text]
            guard let reply = try? JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes]),
                  reply.count < 52 * 1024 else { return nil }
            return reply
        }
    }

    func start() -> Bool { transport.start() }
    func stop() { transport.stop() }
}

/// Private Unix transport for one explicitly approved live process. Endpoint
/// instances have disjoint paths, handlers, and leases.
final class LocalApprovedSocket {
    static var defaultDirectory: String { "/private/tmp/codebasic-tts-mcp-\(getuid())" }
    private let directory: String
    private let endpoint: String
    private var path: String { directory + "/" + endpoint }
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let approvedPeer: LocalInstructionPeer
    private let maxFrame: Int
    private let expires: DispatchTime
    private let handle: (Data, @escaping () -> Bool) -> Data?
    private var source: DispatchSourceRead?
    private var inode: ino_t = 0
    private var revoked = false

    init(peer: LocalInstructionPeer, endpoint: String, directory: String,
         lifetime: DispatchTimeInterval, maxFrame: Int,
         handle: @escaping (Data, @escaping () -> Bool) -> Data?) {
        approvedPeer = peer
        self.endpoint = endpoint
        self.directory = directory
        self.maxFrame = maxFrame
        self.handle = handle
        queue = DispatchQueue(label: "com.codebasic.tts.approved-ipc." + endpoint)
        expires = .now() + lifetime
    }

    /// Start/stop are owned by the AppDelegate's main actor. Requests are serialized separately.
    func start() -> Bool {
        guard source == nil, LocalInstructionPeer.current(pid: approvedPeer.pid) == approvedPeer else { return false }
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { return false }
        var st = stat()
        guard lstat(directory, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(), (st.st_mode & 0o777) == 0o700,
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
        guard chmod(path, 0o600) == 0, listen(fd, 4) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
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
        lock.lock(); revoked = true; lock.unlock()
        source?.cancel(); source = nil
        unlinkOwnSocket()
    }

    private func unlinkOwnSocket() {
        var st = stat()
        if inode != 0, lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK,
           st.st_uid == getuid(), st.st_ino == inode { unlink(path) }
    }

    private func acceptOne(_ listener: Int32) {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        guard LocalInstructionPeer.connected(fd) == approvedPeer,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return }
        let deadline = DispatchTime.now() + .milliseconds(600)
        guard let bytes = readFrame(fd, deadline: deadline),
              LocalInstructionPeer.connected(fd) == approvedPeer,
              active(),
              var out = handle(bytes, { [weak self] in self?.active() == true }) else { return }
        out.append(10)
        lock.lock()
        defer { lock.unlock() }
        // Keep the lease checked across the write. Stop can wait only for the short send deadline.
        guard !revoked, DispatchTime.now() < expires, LocalInstructionPeer.connected(fd) == approvedPeer else { return }
        let sendDeadline = DispatchTime.now() + .milliseconds(100)
        _ = out.withUnsafeBytes { (view: UnsafeRawBufferPointer) -> Bool in
            guard let base = view.baseAddress else { return false }
            var sent = 0
            while sent < view.count {
                guard ready(fd, event: Int16(POLLOUT), deadline: sendDeadline) else { return false }
                let n = send(fd, base.advanced(by: sent), view.count - sent, 0)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }

    private func active() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !revoked && DispatchTime.now() < expires && LocalInstructionPeer.current(pid: approvedPeer.pid) == approvedPeer
    }

    /// Require a single LF-terminated frame followed by client half-close.
    /// No queued or trailing second frame can be mistaken for the approved request.
    private func readFrame(_ fd: Int32, deadline: DispatchTime) -> Data? {
        var frame = Data()
        var terminated = false
        var chunk = [UInt8](repeating: 0, count: 4096)
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
            guard frame.count < maxFrame else { return nil }
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
