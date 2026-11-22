import Foundation
import Darwin
import CryptoKit

/// Single-login, opt-in IPC. No text is logged or persisted by this bridge.
final class LocalSpeechSocket {
    private let queue = DispatchQueue(label: "com.codebasic.tts.local-speech")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var socketInode: ino_t = 0
    private let directory = "/private/tmp/codebasic-tts-mcp-\(getuid())"
    private var path: String { directory + "/s.sock" }
    private let handler: @MainActor (String, String) -> String

    init(handler: @escaping @MainActor (String, String) -> String) { self.handler = handler }

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
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { close(s); return false }
        guard chmod(path, 0o600) == 0, listen(s, 4) == 0 else { close(s); unlink(path); return false }
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { close(s); return false }
        socketInode = st.st_ino
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne(s) }
        src.setCancelHandler { close(s) }
        source = src; src.resume()
        return true
    }

    func stop() {
        guard fd >= 0 else { return }
        source?.cancel(); source = nil; fd = -1
        // Remove only the socket we created, never an arbitrary replacement.
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid(), st.st_ino == socketInode { unlink(path) }
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
        var buffer = [UInt8](), b: UInt8 = 0
        let readDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while buffer.count < 25 * 1024 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < readDeadline else { return }
            var pfd = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let remainingMS = Int32((readDeadline - now + 999_999) / 1_000_000)
            guard poll(&pfd, 1, remainingMS) > 0, (pfd.revents & Int16(POLLIN)) != 0,
                  recv(client, &b, 1, 0) == 1 else { return }
            if b == 10 { break }; buffer.append(b)
        }
        var status = "invalid"
        if buffer.count < 25 * 1024,
           let object = try? JSONSerialization.jsonObject(with: Data(buffer)) as? [String: Any],
           object.count == 2, let text = object["text"] as? String, let key = object["idempotency_key"] as? String,
           text.utf8.count <= 4096, !text.contains("\0"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !key.isEmpty, key.utf8.count <= 128,
           key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) {
            let semaphore = DispatchSemaphore(value: 0)
            let deadline = DispatchTime.now() + .milliseconds(1000)
            let lock = NSLock()
            var result = "busy"
            DispatchQueue.main.async { [handler] in
                guard DispatchTime.now() < deadline else { semaphore.signal(); return }
                let value = MainActor.assumeIsolated { handler(text, key) }
                lock.lock(); result = value; lock.unlock(); semaphore.signal()
            }
            if semaphore.wait(timeout: deadline) == .success { lock.lock(); status = result; lock.unlock() } else { status = "unconfirmed" }
        }
        let response = Data("{\"status\":\"\(status)\"}\n".utf8)
        response.withUnsafeBytes { ptr in _ = send(client, ptr.baseAddress!, ptr.count, 0) }
    }
}

/// In-memory only, scoped to this opt-in session and bounded to 128 entries.
@MainActor
final class LocalSpeechGate {
    private var keys: [String: Data] = [:]
    private var order: [String] = []
    func accept(text: String, key: String, app: AppState) -> String {
        guard !SSMLGuard.containsSSML(text) else { return "invalid" }
        let digest = Data(SHA256.hash(data: Data(text.utf8)))
        if let existing = keys[key] { return existing == digest ? "duplicate" : "conflict" }
        guard !app.isBusy, !app.explaining, !app.normalizing else { return "busy" }
        keys[key] = digest; order.append(key)
        if order.count > 128 { keys.removeValue(forKey: order.removeFirst()) }
        app.playbackMode = .tts
        app.synthesize(text, displayText: text, preserveLiteral: true)
        // synthesize starts an asynchronous task; reserve synchronously before
        // another IPC request can see an idle phase.
        app.phase = .synthesizing
        return "accepted"
    }
}
