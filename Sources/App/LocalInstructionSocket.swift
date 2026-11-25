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

    /// Context for the consent dialog, not an authentication input.
    func parentExecutable() -> String? {
        var child = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &child, size) == size,
              child.pbi_start_tvsec == startSeconds, child.pbi_start_tvusec == startMicroseconds,
              child.pbi_ppid > 1 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid_t(child.pbi_ppid), &path, UInt32(path.count)) > 0,
              Self.current(pid: pid) == self else { return nil }
        return String(validatingUTF8: path)
    }

    func parentPID() -> pid_t? {
        var child = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &child, size) == size,
              child.pbi_start_tvsec == startSeconds, child.pbi_start_tvusec == startMicroseconds,
              child.pbi_ppid > 1 else { return nil }
        return pid_t(child.pbi_ppid)
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
    var requiresPathInspection: Bool { transport.requiresPathInspection }
}

/// Private Unix transport for one explicitly approved live process. Endpoint
/// instances have disjoint paths, handlers, and leases.
final class LocalApprovedSocket {
    static var defaultDirectory: String { TTSRuntime.socketDirectory }
    static let unknownPathMessage = "기존 소켓의 출처를 확인할 수 없어 그대로 두었습니다. 이전 앱을 종료하고 다시 시도하거나 복사·붙여넣기를 사용하세요."
    private let directory: String
    private let endpoint: String
    private var path: String { directory + "/" + endpoint }
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let approvedPeer: LocalInstructionPeer?
    private let maxFrame: Int
    private let verified: (Int32) -> Bool
    private let didDeliver: (Data) -> Void
    private let deliveryGate: (@escaping () -> Void) -> Void
    private let expires: DispatchTime
    private let handle: (Data, LocalInstructionPeer, @escaping () -> Bool) -> Data?
    private var source: DispatchSourceRead?
    private var pathLease: SocketPathLease?
    private var identity: String?
    private var revoked = false
    private(set) var requiresPathInspection = false

    /// `lifetime: nil` lasts until `stop()`; the caller owns revocation.
    convenience init(peer: LocalInstructionPeer, endpoint: String, directory: String,
         lifetime: DispatchTimeInterval?, maxFrame: Int,
         verified: @escaping (Int32) -> Bool = { _ in true },
         deliveryGate: @escaping (@escaping () -> Void) -> Void = { $0() },
         didDeliver: @escaping (Data) -> Void = { _ in },
         handle: @escaping (Data, @escaping () -> Bool) -> Data?) {
        self.init(peer: peer, endpoint: endpoint, directory: directory, lifetime: lifetime, maxFrame: maxFrame,
                  verified: verified, deliveryGate: deliveryGate, didDeliver: didDeliver,
                  identifiedHandler: { data, _, active in handle(data, active) })
    }

    /// Pairing discovers a verified live process without granting it access to data.
    /// There is no unsigned or unrestricted mode for an unbound listener.
    init(pairingDirectory directory: String, verified: @escaping (Int32) -> Bool,
         handler: @escaping (Data, LocalInstructionPeer, @escaping () -> Bool) -> Data?) {
        approvedPeer = nil
        endpoint = "p.sock"
        self.directory = directory
        maxFrame = 1024
        self.verified = verified
        deliveryGate = { $0() }
        didDeliver = { _ in }
        handle = handler
        queue = DispatchQueue(label: "com.codebasic.tts.approved-ipc.pairing")
        expires = .distantFuture
    }

    private init(peer: LocalInstructionPeer, endpoint: String, directory: String,
                 lifetime: DispatchTimeInterval?, maxFrame: Int, verified: @escaping (Int32) -> Bool,
                 deliveryGate: @escaping (@escaping () -> Void) -> Void, didDeliver: @escaping (Data) -> Void,
                 identifiedHandler: @escaping (Data, LocalInstructionPeer, @escaping () -> Bool) -> Data?) {
        approvedPeer = peer
        self.endpoint = endpoint
        self.directory = directory
        self.maxFrame = maxFrame
        self.verified = verified
        self.deliveryGate = deliveryGate
        self.didDeliver = didDeliver
        self.handle = identifiedHandler
        queue = DispatchQueue(label: "com.codebasic.tts.approved-ipc." + endpoint)
        expires = lifetime.map { .now() + $0 } ?? .distantFuture
    }

    /// Start/stop are owned by the AppDelegate's main actor. Requests are serialized separately.
    func start() -> Bool {
        requiresPathInspection = false
        guard source == nil else { return false }
        if let approvedPeer, LocalInstructionPeer.current(pid: approvedPeer.pid) != approvedPeer { return false }
        var addr = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path),
              let pathLease = SocketPathLease(directory: directory, endpoint: endpoint) else { return false }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in bytes.withUnsafeBytes { dst.copyBytes(from: $0) } }
        switch pathLease.prepare(&addr) {
        case .clear: break
        case .unmanaged: requiresPathInspection = true; return false
        case .busyOrUnsafe: return false
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); return false }
        guard let identity = pathLease.currentSocket(), pathLease.remember(identity) else { close(fd); return false }
        guard pathLease.makePrivate(identity),
              listen(fd, 4) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd); pathLease.remove(identity); return false
        }
        self.pathLease = pathLease
        self.identity = identity
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
        if let identity { pathLease?.remove(identity) }
        identity = nil
        pathLease = nil
    }

    private func acceptOne(_ listener: Int32) {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        guard let peer = LocalInstructionPeer.connected(fd), approvedPeer == nil || approvedPeer == peer, verified(fd),
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return }
        let deadline = DispatchTime.now() + .milliseconds(600)
        guard let bytes = readFrame(fd, deadline: deadline),
              LocalInstructionPeer.connected(fd) == peer, verified(fd),
              active(peer),
              var out = handle(bytes, peer, { [weak self] in self?.active(peer) == true }) else { return }
        out.append(10)
        deliveryGate { self.sendFrame(out, fd: fd, peer: peer) }
    }

    private func sendFrame(_ out: Data, fd: Int32, peer: LocalInstructionPeer) {
        lock.lock()
        defer { lock.unlock() }
        // Keep the lease checked across the write. Stop can wait only for the short send deadline.
        guard !revoked, DispatchTime.now() < expires, LocalInstructionPeer.connected(fd) == peer,
              verified(fd) else { return }
        let sendDeadline = DispatchTime.now() + .milliseconds(100)
        let delivered = out.withUnsafeBytes { (view: UnsafeRawBufferPointer) -> Bool in
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
        if delivered { didDeliver(out) }
    }

    private func active(_ peer: LocalInstructionPeer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !revoked && DispatchTime.now() < expires && LocalInstructionPeer.current(pid: peer.pid) == peer
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

/// Keep a kernel-released lock for each socket's entire bound lifetime and
/// remember its exact identity. Only a known non-listening inode can be
/// recovered. An unmanaged/ambiguous old path is deliberately left untouched.
private final class SocketPathLease {
    enum Readiness { case clear, unmanaged, busyOrUnsafe }
    private let directory: String
    private let endpoint: String
    private let directoryFD: Int32
    private let leaseFD: Int32
    private let directoryStat: stat
    private let leaseStat: stat

    init?(directory: String, endpoint: String) {
        guard ["i.sock", "d.sock", "p.sock"].contains(endpoint) else { return nil }
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { return nil }
        let dir = Darwin.open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return nil }
        var keepDir = false
        defer { if !keepDir { close(dir) } }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { return nil }
        let fd = openat(dir, "." + endpoint + ".lease", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return nil }
        var keepFD = false
        defer { if !keepFD { close(fd) } }
        var lock = stat()
        guard fstat(fd, &lock) == 0, (lock.st_mode & S_IFMT) == S_IFREG,
              lock.st_uid == getuid(), lock.st_nlink == 1, lock.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
        self.directory = directory
        self.endpoint = endpoint
        directoryFD = dir
        leaseFD = fd
        directoryStat = info
        leaseStat = lock
        keepFD = true
        keepDir = true
    }

    deinit { close(leaseFD); close(directoryFD) }

    private func namespaceUnchanged() -> Bool {
        var current = stat()
        return lstat(directory, &current) == 0 && (current.st_mode & S_IFMT) == S_IFDIR &&
            current.st_uid == getuid() && current.st_mode & 0o777 == 0o700 &&
            current.st_dev == directoryStat.st_dev && current.st_ino == directoryStat.st_ino &&
            fstatat(directoryFD, "." + endpoint + ".lease", &current, AT_SYMLINK_NOFOLLOW) == 0 &&
            (current.st_mode & S_IFMT) == S_IFREG && current.st_uid == getuid() &&
            current.st_nlink == 1 && current.st_mode & 0o777 == 0o600 &&
            current.st_dev == leaseStat.st_dev && current.st_ino == leaseStat.st_ino
    }

    private func identity(_ st: stat) -> String? {
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid(), st.st_nlink == 1,
              st.st_birthtimespec.tv_sec > 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino):\(st.st_birthtimespec.tv_sec):\(st.st_birthtimespec.tv_nsec)\n"
    }

    func currentSocket() -> String? {
        var st = stat()
        guard namespaceUnchanged(), fstatat(directoryFD, endpoint, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return identity(st)
    }

    func remember(_ identity: String) -> Bool {
        let bytes = Array(identity.utf8)
        return currentSocket() == identity && bytes.withUnsafeBytes {
            pwrite(leaseFD, $0.baseAddress, $0.count, 0) == $0.count
        } && ftruncate(leaseFD, off_t(bytes.count)) == 0 && fsync(leaseFD) == 0
    }

    func makePrivate(_ expected: String) -> Bool {
        currentSocket() == expected &&
            fchmodat(directoryFD, endpoint, 0o600, AT_SYMLINK_NOFOLLOW) == 0 &&
            currentSocket() == expected
    }

    func prepare(_ address: inout sockaddr_un) -> Readiness {
        var st = stat()
        guard namespaceUnchanged() else { return .busyOrUnsafe }
        if fstatat(directoryFD, endpoint, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            return errno == ENOENT ? .clear : .busyOrUnsafe
        }
        guard let expected = identity(st) else { return .unmanaged }
        var marker = [UInt8](repeating: 0, count: 128)
        let count = marker.withUnsafeMutableBytes { pread(leaseFD, $0.baseAddress, $0.count, 0) }
        guard count == expected.utf8.count, marker.prefix(count).elementsEqual(expected.utf8) else { return .unmanaged }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return .busyOrUnsafe }
        defer { close(probe) }
        guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else { return .busyOrUnsafe }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // A refusal plus the matching marker and still-held lock is the only stale case.
        guard result < 0, errno == ECONNREFUSED else { return .busyOrUnsafe }
        return remove(expected) ? .clear : .busyOrUnsafe
    }

    @discardableResult
    func remove(_ expected: String) -> Bool {
        currentSocket() == expected && unlinkat(directoryFD, endpoint, 0) == 0
    }
}
