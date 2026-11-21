import Darwin
import Foundation

/// One native signed helper per MCP session. This executable owns both local
/// connections; the model never sees a receipt capability or pairing identity.
@main struct AgentCatalogMCP {
    static let maxFrame = 100 * 1024
    static let reader = "get_tts_instructions"
    static let receiver = "submit_explanation_draft"
    static let maxProofs = AgentLimits.proofCount
    static let pin = ProcessInfo.processInfo.environment[AgentPeerSigning.pinEnvironment]?.lowercased()
    static let directory = "/private/tmp/codebasic-tts-mcp-\(getuid())"

    struct Proof {
        let profile: String
        let revision: String
        let bodyHash: String
        let token: String
        let expiry: ContinuousClock.Instant
        var key: String { profile + ":" + revision }
    }

    static func main() {
        var initialized = false, ready = false
        var proofs: [Proof] = []
        while let input = readFrame() {
            if input.isEmpty { emit(error(nil, -32700, "Malformed or oversized frame")); continue }
            guard let frame = decode(input), frame["jsonrpc"] as? String == "2.0",
                  let method = frame["method"] as? String else {
                emit(error(nil, -32600, "Invalid request")); continue
            }
            guard let id = frame["id"] else {
                if method == "notifications/initialized", initialized { ready = true }
                continue
            }
            guard id is String || id is NSNumber else { emit(error(nil, -32600, "Invalid request id")); continue }
            let params = frame["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                guard !initialized else { emit(error(id, -32600, "Already initialized")); continue }
                initialized = true
                let requested = params["protocolVersion"] as? String ?? ""
                let version = ["2025-11-25", "2025-06-18", "2025-03-26"].contains(requested) ? requested : "2025-11-25"
                result(id, ["protocolVersion":version, "serverInfo":["name":"codebasic-tts-agent", "version":"2.0"],
                            "capabilities":["tools":["listChanged":false]]])
            case "ping":
                result(id, [:])
            case "tools/list" where ready:
                result(id, ["tools": tools])
            case "tools/call" where ready:
                guard let name = params["name"] as? String, let args = params["arguments"] as? [String: Any] else {
                    emit(error(id, -32602, "Tool name and arguments required")); continue
                }
                switch name {
                case reader:
                    guard Set(args.keys) == ["profile"], let selector = args["profile"] as? String,
                          validSelector(selector) else {
                        tool(id, "Use an exact built-in profile ID or the ID shown by the app.", failed: true); continue
                    }
                    guard let reply = exchange(socket: "i.sock", ["schema_version": 2, "profile": selector]),
                          reply["schema_version"] as? Int == 2, reply["profile"] as? String == selector,
                          let text = reply["instructions"] as? String, AgentBytes.textValid(text),
                          let rev = reply["revision"] as? String, UUID(uuidString: rev) != nil,
                          let hash = reply["body_sha256"] as? String, hash == AgentBytes.hash(Data(text.utf8)),
                          let opaque = reply["proof"] as? String, UUID(uuidString: opaque) != nil else {
                        tool(id, "No pinned, approved instruction revision available. Local helper PID: \(getpid()).", failed: true); continue
                    }
                    let proof = Proof(profile: selector, revision: rev, bodyHash: hash, token: opaque,
                                      expiry: .now.advanced(by: .seconds(AgentLimits.grantSeconds)))
                    proofs.removeAll { $0.key == proof.key || $0.expiry <= .now }
                    proofs.append(proof)
                    if proofs.count > maxProofs { proofs.removeFirst(proofs.count - maxProofs) }
                    tool(id, text, extra: ["schema_version":2, "profile":selector, "revision":rev,
                                          "body_sha256":hash, "instructions":text])
                case receiver:
                    let required: Set<String> = ["profile", "revision", "idempotency_key", "display_text"]
                    let keys = Set(args.keys)
                    guard keys == required || keys == required.union(["speech_text"]),
                          let profile = args["profile"] as? String, let revision = args["revision"] as? String,
                          let retry = args["idempotency_key"] as? String,
                          (1...128).contains(retry.utf8.count), retry.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
                          let display = args["display_text"] as? String, AgentBytes.textValid(display),
                          args["speech_text"].map({ ($0 as? String).map(AgentBytes.textValid) == true }) ?? true else {
                        tool(id, "Invalid plain-text draft arguments.", failed: true); continue
                    }
                    proofs.removeAll { $0.expiry <= .now }
                    guard let proof = proofs.last(where: { $0.profile == profile && $0.revision == revision }) else {
                        tool(id, "This helper did not receive that exact revision. Read it first or paste manually.", failed: true); continue
                    }
                    var request = args
                    request["schema_version"] = 2
                    request["body_sha256"] = proof.bodyHash
                    request["proof"] = proof.token
                    let status = exchange(socket: "d.sock", request)?["status"] as? String
                    switch status {
                    case "accepted": tool(id, "Queued in the app. Not applied or played.")
                    case "duplicate": tool(id, "Already received. Nothing new was queued or played.")
                    case "conflict": tool(id, "Retry key already used for different content.", failed: true)
                    case "busy": tool(id, "Inbox is full. Nothing was queued.", failed: true)
                    case "rate_limited": tool(id, "This grant’s receipt rate limit was reached.", failed: true)
                    case "unproven": tool(id, "Revision proof expired, was revoked, or the profile was deleted. Read again or paste manually.", failed: true)
                    default: tool(id, "Receipt not confirmed. Retry unchanged or paste manually. Local helper PID: \(getpid()).", failed: true)
                    }
                default:
                    emit(error(id, -32602, "Unknown tool"))
                }
            default:
                emit(error(id, -32601, "Method unavailable"))
            }
        }
    }

    static var tools: [[String: Any]] {
        let string = ["type":"string"]
        return [["name":reader, "description":"Read one exact locally approved instruction revision.",
                 "inputSchema":["type":"object","properties":["profile":string],"required":["profile"],"additionalProperties":false],
                 "annotations":["readOnlyHint":true,"openWorldHint":false]],
                ["name":receiver, "description":"Queue an editable plain-text draft for a revision received by this helper. Never plays.",
                 "inputSchema":["type":"object", "properties":["profile":string,"revision":string,"idempotency_key":string,
                     "display_text":string,"speech_text":string],"required":["profile","revision","idempotency_key","display_text"],
                     "additionalProperties":false],
                 "annotations":["readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false]]]
    }

    static func validSelector(_ selector: String) -> Bool {
        if ["explain","continue","normalize"].contains(selector) { return true }
        return UUID(uuidString: selector)?.uuidString.lowercased() == selector
    }

    static func decode(_ data: Data) -> [String: Any]? {
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func readFrame() -> Data? {
        var data = Data(), oversized = false
        while true {
            let c = fgetc(stdin)
            if c == EOF { return data.isEmpty && !oversized ? nil : Data() }
            if c == 10 { return oversized ? Data() : data }
            if data.count + 1 >= maxFrame { oversized = true }
            if !oversized { data.append(UInt8(c)) }
        }
    }

    static func exchange(socket endpoint: String, _ request: [String: Any]) -> [String: Any]? {
        guard let pin, endpoint == "i.sock" || endpoint == "d.sock" else { return nil }
        var st = stat()
        let path = directory + "/" + endpoint
        guard lstat(directory, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFDIR, st.st_mode & 0o777 == 0o700,
              lstat(path, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFSOCK, st.st_mode & 0o777 == 0o600,
              var data = try? JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes]),
              data.count < maxFrame else { return nil }
        data.append(10)
        var addr = sockaddr_un()
        let wire = Array(path.utf8CString)
        guard wire.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in wire.withUnsafeBytes { dst.copyBytes(from: $0) } }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var yes: Int32 = 1, timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { return nil }
        let connection = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connection == 0, AgentPeerSigning.matches(socket: fd, identifier: AgentPeerSigning.appID, leaf: pin) else { return nil }
        let sent = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var done = 0
            while done < bytes.count {
                let n = send(fd, base.advanced(by: done), bytes.count - done, 0)
                if n <= 0 { return false }
                done += n
            }
            return true
        }
        guard sent, shutdown(fd, SHUT_WR) == 0 else { return nil }
        let maximum = endpoint == "i.sock" ? 52 * 1024 : 128
        var output = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var terminated = false
        while ContinuousClock.now < deadline {
            let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count == 0 { return terminated ? decode(output) : nil }
            guard count > 0, !terminated, output.count + count <= maximum else { return nil }
            output.append(contentsOf: chunk.prefix(count))
            if let newline = output.firstIndex(of: 10) {
                guard newline == output.endIndex - 1 else { return nil }
                terminated = true
            }
        }
        return nil
    }

    static func emit(_ envelope: [String: Any]) {
        if var data = try? JSONSerialization.data(withJSONObject: envelope, options: [.withoutEscapingSlashes]) {
            data.append(10); FileHandle.standardOutput.write(data)
        }
    }

    static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc":"2.0","id":id ?? NSNull(),"error":["code":code,"message":message]]
    }

    static func result(_ id: Any, _ payload: [String: Any]) {
        emit(["jsonrpc":"2.0","id":id,"result":payload])
    }

    static func tool(_ id: Any, _ message: String, failed: Bool = false, extra: [String: Any]? = nil) {
        var value: [String: Any] = ["content":[["type":"text","text":message]],"isError":failed]
        if let extra { value["structuredContent"] = extra }
        result(id, value)
    }
}
