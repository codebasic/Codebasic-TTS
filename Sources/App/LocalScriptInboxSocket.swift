import Darwin
import Foundation

/// Opt-in, single-login IPC for agent script delivery (`submit_script`). Separate from
/// `s.sock` (speak_text): a submission is stored for review and never starts playback.
/// No text is logged or persisted by this bridge.
final class LocalScriptInboxSocket {
    struct Submission {
        let displayText: String
        let speechText: String?
        let key: String
    }

    static let maxFrame = 40 * 1024
    private let queue = DispatchQueue(label: "com.codebasic.tts.local-script-inbox")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var socketInode: ino_t = 0
    private let directory: String
    private var path: String { directory + "/r.sock" }
    private let handler: @MainActor (Submission) -> String

    init(directory: String = "/private/tmp/codebasic-tts-mcp-\(getuid())",
         handler: @escaping @MainActor (Submission) -> String) {
        self.directory = directory
        self.handler = handler
    }

    func start() -> Bool {
        guard fd == -1 else { return true }
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { return false }
        var st = stat()
        guard lstat(directory, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(), (st.st_mode & 0o777) == 0o700 else { return false }
        // Never unlink a pre-existing path. A stale socket must be removed explicitly.
        guard lstat(path, &st) != 0 && errno == ENOENT else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in bytes.withUnsafeBytes { dst.copyBytes(from: $0) } }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(s); return false }
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { close(s); return false }
        socketInode = st.st_ino
        guard chmod(path, 0o600) == 0, listen(s, 4) == 0 else { close(s); unlinkOwnSocket(); return false }
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne(s) }
        src.setCancelHandler { close(s) }
        source = src
        src.resume()
        return true
    }

    func stop() {
        guard fd >= 0 else { return }
        source?.cancel(); source = nil; fd = -1
        unlinkOwnSocket()
    }

    /// Remove only the socket we created, never an arbitrary replacement.
    private func unlinkOwnSocket() {
        var st = stat()
        if socketInode != 0, lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK,
           st.st_uid == getuid(), st.st_ino == socketInode { unlink(path) }
    }

    /// Exactly `display_text` + `idempotency_key`, optionally `speech_text`; all strings.
    static func decode(_ frame: Data) -> Submission? {
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let display = object["display_text"] as? String, let key = object["idempotency_key"] as? String,
              Set(object.keys).isSubset(of: ["display_text", "speech_text", "idempotency_key"]) else { return nil }
        if object["speech_text"] != nil && !(object["speech_text"] is String) { return nil }
        return Submission(displayText: display, speechText: object["speech_text"] as? String, key: key)
    }

    private func acceptOne(_ listening: Int32) {
        let client = accept(listening, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        var noSigPipe: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var complete = false
        let readDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while !complete && buffer.count <= Self.maxFrame {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < readDeadline else { return }
            var pfd = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let remainingMS = Int32((readDeadline - now + 999_999) / 1_000_000)
            guard poll(&pfd, 1, remainingMS) > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return }
            let n = recv(client, &chunk, chunk.count, 0)
            guard n > 0 else { return }
            if let newline = chunk[..<n].firstIndex(of: 10) {
                guard newline == n - 1 else { return }   // one frame per connection, nothing after it
                buffer.append(contentsOf: chunk[..<newline]); complete = true
            } else {
                buffer.append(contentsOf: chunk[..<n])
            }
        }
        var status = "invalid"
        if complete, buffer.count <= Self.maxFrame, let submission = Self.decode(buffer) {
            let semaphore = DispatchSemaphore(value: 0)
            let deadline = DispatchTime.now() + .milliseconds(1000)
            let lock = NSLock()
            var result = "unconfirmed"
            DispatchQueue.main.async { [handler] in
                guard DispatchTime.now() < deadline else { semaphore.signal(); return }
                let value = MainActor.assumeIsolated { handler(submission) }
                lock.lock(); result = value; lock.unlock(); semaphore.signal()
            }
            if semaphore.wait(timeout: deadline) == .success { lock.lock(); status = result; lock.unlock() } else { status = "unconfirmed" }
        }
        let response = Data("{\"status\":\"\(status)\"}\n".utf8)
        response.withUnsafeBytes { ptr in _ = send(client, ptr.baseAddress!, ptr.count, 0) }
    }
}
