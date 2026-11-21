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

/// A separate read-only socket; this never accesses AppState, files or a playback/provider backend.
final class LocalInstructionSocket {
    private let directory: String
    private var path: String { directory + "/i.sock" }
    private let queue = DispatchQueue(label: "com.codebasic.tts.local-instructions")
    private let lock = NSLock()
    private let approvedPeer: LocalInstructionPeer
    private let profile: LocalInstructionProfile
    private let expires: DispatchTime
    private var source: DispatchSourceRead?
    private var inode: ino_t = 0
    private var revoked = false

    init(peer: LocalInstructionPeer, profile: LocalInstructionProfile,
         directory: String = "/private/tmp/codebasic-tts-mcp-\(getuid())", lifetime: DispatchTimeInterval = .seconds(600)) {
        approvedPeer = peer
        self.profile = profile
        self.directory = directory
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
        let deadline = DispatchTime.now() + .milliseconds(400)
        var bytes = Data()
        var byte: UInt8 = 0
        while bytes.count < 128 {
            guard ready(fd, event: Int16(POLLIN), deadline: deadline), recv(fd, &byte, 1, 0) == 1 else { return }
            if byte == 10 { break }
            bytes.append(byte)
        }
        guard byte == 10, let args = try? JSONDecoder().decode([String: String].self, from: bytes),
              args == ["profile": profile.name.rawValue] else { return }
        let result: [String: Any] = ["schema_version": 1, "profile": profile.name.rawValue,
                                     "revision": profile.revision, "instructions": profile.text]
        guard var out = try? JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes]),
              out.count < 52 * 1024 else { return }
        out.append(10)
        lock.lock()
        defer { lock.unlock() }
        // Keep this checked across the write. Stop can wait only for the short send deadline.
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

    private func ready(_ fd: Int32, event: Int16, deadline: DispatchTime) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { return false }
        let ms = Int32((deadline.uptimeNanoseconds - now + 999_999) / 1_000_000)
        var target = pollfd(fd: fd, events: event, revents: 0)
        return poll(&target, 1, ms) > 0 && target.revents & event != 0
    }
}
