import Darwin
import Foundation

/// Dedicated single-login, opt-in IPC bridge for external-agent explain drafts (`e.sock`).
/// Accepted drafts land ONLY in the Explain inbox; this bridge never mutates the
/// active editor or starts audio synthesis/playback.
final class LocalExplainDraftSocket {
    static let maxIPCFrameBytes = 48 * 1024

    private let queue = DispatchQueue(label: "com.codebasic.tts.local-explain-drafts")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var socketInode: ino_t = 0
    private let directory: String
    private var path: String { directory + "/e.sock" }
    private let handler: @MainActor (ExplainDraftPayload) -> String

    init(
        directory: String = "/private/tmp/codebasic-tts-mcp-\(getuid())",
        handler: @escaping @MainActor (ExplainDraftPayload) -> String
    ) {
        self.directory = directory
        self.handler = handler
    }

    func start() -> Bool {
        guard fd == -1 else { return true }
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { return false }
        var st = stat()
        guard lstat(directory, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(), (st.st_mode & 0o777) == 0o700 else { return false }
        // Never unlink a pre-existing path; stale sockets must be removed explicitly.
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
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(s); return false }
        guard chmod(path, 0o600) == 0, listen(s, 4) == 0 else { close(s); unlink(path); return false }
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else {
            close(s); return false
        }
        socketInode = st.st_ino
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
        source?.cancel()
        source = nil
        fd = -1
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK,
           st.st_uid == getuid(), st.st_ino == socketInode {
            unlink(path)
        }
    }

    static func parsePayload(from frame: Data) -> ExplainDraftPayload? {
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { return nil }
        let allowedKeys: Set<String> = [
            "display_text", "spoken_text", "idempotency_key", "mode", "instruction_revision"
        ]
        guard Set(object.keys).isSubset(of: allowedKeys) else { return nil }
        guard let displayText = object["display_text"] as? String,
              let idempotencyKey = object["idempotency_key"] as? String else { return nil }

        let spokenText: String?
        if let rawSpoken = object["spoken_text"] {
            guard let s = rawSpoken as? String else { return nil }
            spokenText = s
        } else {
            spokenText = nil
        }

        let mode: ExplainInstructionMode
        if let rawMode = object["mode"] {
            guard let m = rawMode as? String, let parsed = ExplainInstructionMode(rawValue: m) else { return nil }
            mode = parsed
        } else {
            mode = .full
        }

        let instructionRevision: String?
        if let rawRev = object["instruction_revision"] {
            guard let r = rawRev as? String else { return nil }
            instructionRevision = r
        } else {
            instructionRevision = nil
        }

        return ExplainDraftPayload(
            displayText: displayText,
            spokenText: spokenText,
            mode: mode,
            idempotencyKey: idempotencyKey,
            instructionRevision: instructionRevision
        )
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
        while buffer.count < Self.maxIPCFrameBytes {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < readDeadline else { return }
            var pfd = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let remainingMS = Int32((readDeadline - now + 999_999) / 1_000_000)
            guard poll(&pfd, 1, remainingMS) > 0, (pfd.revents & Int16(POLLIN)) != 0,
                  recv(client, &b, 1, 0) == 1 else { return }
            if b == 10 { break }
            buffer.append(b)
        }

        var status = "invalid"
        if buffer.count < Self.maxIPCFrameBytes,
           b == 10,
           let payload = Self.parsePayload(from: Data(buffer)) {
            let semaphore = DispatchSemaphore(value: 0)
            let deadline = DispatchTime.now() + .milliseconds(1000)
            let lock = NSLock()
            var result = "unconfirmed"
            DispatchQueue.main.async { [handler] in
                guard DispatchTime.now() < deadline else { semaphore.signal(); return }
                let value = MainActor.assumeIsolated { handler(payload) }
                lock.lock()
                result = value
                lock.unlock()
                semaphore.signal()
            }
            if semaphore.wait(timeout: deadline) == .success {
                lock.lock()
                status = result
                lock.unlock()
            } else {
                status = "unconfirmed"
            }
        }

        let response = Data("{\"status\":\"\(status)\"}\n".utf8)
        response.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = send(client, base, ptr.count, 0)
        }
    }
}
