import CryptoKit
import Darwin
import Foundation

/// Signed native Swift stdio MCP 2025-11-25 server helper (`com.seongjoo.SelectedTextTTS.agent-mcp`).
/// External agent harnesses spawn this helper as an MCP server client connection;
/// the helper verifies the TTS app's OS code signature via `LOCAL_PEERTOKEN` before
/// exchanging pairing knocks, instruction reads, or explanation drafts over local Unix sockets.
enum NativeAgentMCP {
    static let protocolVersion = "2025-11-25"
    static let maxStdioFrame = 100 * 1024
    static let maxTextBytes = 8 * 1024
    static let maxReplyBytes = 56 * 1024
    static let socketTimeoutSeconds = 2.0

    enum TransportResult {
        case ok(Data)
        case offline
        case unsafe
        case unconfirmed
    }

    static func socketDirectory() -> String {
        if let override = ProcessInfo.processInfo.environment["CODEBASIC_TTS_MCP_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        return "/private/tmp/codebasic-tts-mcp-\(getuid())"
    }

    static func expectedAppLeafSHA1() -> String? {
        if let rawPin = ProcessInfo.processInfo.environment["CODEBASIC_TTS_SIGNER_SHA1"] {
            let trimmed = rawPin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return AgentPeerVerifier.isValidHexSHA1(trimmed) ? trimmed : nil
        }
        guard let own = AgentPeerVerifier.ownSigningIdentity(),
              !own.isAdhoc,
              AgentPeerVerifier.isValidHexSHA1(own.leafCertSHA1) else {
            return nil
        }
        return own.leafCertSHA1.lowercased()
    }

    static func isSafeSocketPath(directory: String, socketName: String) -> (safe: Bool, missingOrRefused: Bool) {
        var dirStat = stat()
        guard lstat(directory, &dirStat) == 0 else {
            return (false, errno == ENOENT)
        }
        guard (dirStat.st_mode & S_IFMT) == S_IFDIR,
              dirStat.st_uid == getuid(),
              (dirStat.st_mode & 0o777) == 0o700 else {
            return (false, false)
        }
        let full = directory + "/" + socketName
        var sockStat = stat()
        guard lstat(full, &sockStat) == 0 else {
            return (false, errno == ENOENT)
        }
        guard (sockStat.st_mode & S_IFMT) == S_IFSOCK,
              sockStat.st_uid == getuid(),
              (sockStat.st_mode & 0o777) == 0o600 else {
            return (false, false)
        }
        return (true, false)
    }

    static func exchangeUnix(socketName: String, requestObject: [String: Any]) -> TransportResult {
        guard let leafSHA1 = expectedAppLeafSHA1() else {
            return .unsafe
        }
        let dir = socketDirectory()
        let pathCheck = isSafeSocketPath(directory: dir, socketName: socketName)
        if !pathCheck.safe {
            return pathCheck.missingOrRefused ? .offline : .unsafe
        }
        guard let json = try? JSONSerialization.data(withJSONObject: requestObject, options: [.withoutEscapingSlashes]),
              json.count < maxStdioFrame else {
            return .unconfirmed
        }
        var frame = json
        frame.append(10)

        let path = dir + "/" + socketName
        var addr = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return .unconfirmed
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { dst.copyBytes(from: $0) }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unconfirmed }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            if errno == ENOENT || errno == ECONNREFUSED { return .offline }
            return .unconfirmed
        }

        guard AgentPeerVerifier.verifyConnectedApp(fd: fd, expectedLeafSHA1: leafSHA1) != nil else {
            return .unsafe
        }

        let sentAll: Bool = frame.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return false }
            var offset = 0
            while offset < ptr.count {
                let n = Darwin.send(fd, base.advanced(by: offset), ptr.count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard sentAll else { return .unconfirmed }
        Darwin.shutdown(fd, SHUT_WR)

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while reply.count < maxReplyBytes {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n == 0 { break }
            if n < 0 { return .unconfirmed }
            reply.append(contentsOf: chunk[0..<n])
            if reply.contains(10) { break }
        }
        guard reply.count <= maxReplyBytes,
              let nl = reply.firstIndex(of: 10),
              nl == reply.index(before: reply.endIndex) else {
            return .unconfirmed
        }
        return .ok(reply.prefix(upTo: nl))
    }

    static func validID(_ key: String) -> Bool {
        (1...128).contains(key.utf8.count) && key.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    static func validText(_ value: String) -> Bool {
        value.utf8.count <= maxTextBytes
            && !value.utf8.contains(0)
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func verifyInstructionReply(_ obj: [String: Any], requestedTarget: String) -> Bool {
        guard (obj["schema_version"] as? Int) == 2,
              let target = obj["target"] as? String, target == requestedTarget,
              let label = obj["label"] as? String, !label.isEmpty,
              let origin = obj["origin"] as? String, origin == "builtin" || origin == "local",
              let revision = obj["revision"] as? String,
              let instructions = obj["instructions"] as? String,
              validText(instructions),
              let proof = obj["delivery_proof"] as? String,
              proof.utf8.count == 32 else {
            return false
        }
        if origin == "builtin" {
            guard let name = LocalInstructionProfile.Name(rawValue: target),
                  let profile = LocalInstructionProfile(name: name, text: instructions) else {
                return false
            }
            return profile.revision == revision
        }
        return AgentInstructionEntry.computeRevision(id: target, label: label, body: instructions) == revision
    }
}

final class NativeMCPSession {
    private var initialized = false
    private var ready = false
    private var clientName = "MCP Client"

    private static let tools: [[String: Any]] = [
        [
            "name": "pair_tts_session",
            "description": "Knock on Codebasic TTS's pairing endpoint so the user can approve pinning this signed MCP helper session. Requires the user to open pairing wait mode in the app first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "client_note": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 64,
                        "description": "Optional short label shown in the pairing approval prompt.",
                    ],
                ],
                "additionalProperties": false,
            ],
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ],
        [
            "name": "get_agent_instruction",
            "description": "Read one explicitly app-approved instruction profile (built-in or local catalog ID). Returns exact instruction text, revision, and a per-delivery proof token.",
            "inputSchema": [
                "type": "object",
                "required": ["target"],
                "properties": [
                    "target": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 80,
                        "description": "Target profile ('explain', 'continue', 'normalize', or local catalog entry ID).",
                    ],
                ],
                "additionalProperties": false,
            ],
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ],
        [
            "name": "submit_explanation_draft",
            "description": "Submit an editable plain-text explanation draft to the pinned app's Agent inbox. Never overwrites the editor or triggers synthesis/playback. Requires separate receipt grant.",
            "inputSchema": [
                "type": "object",
                "required": ["display_text", "idempotency_key"],
                "properties": [
                    "display_text": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": NativeAgentMCP.maxTextBytes,
                        "description": "Screen/subtitle text, at most 8192 UTF-8 bytes.",
                    ],
                    "speech_text": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": NativeAgentMCP.maxTextBytes,
                        "description": "Optional voice-ready pronunciation text, at most 8192 UTF-8 bytes.",
                    ],
                    "idempotency_key": [
                        "type": "string",
                        "pattern": "^[A-Za-z0-9._-]{1,128}$",
                        "description": "Reuse exact key and payload only when retrying.",
                    ],
                    "late_draft": [
                        "type": "boolean",
                        "description": "Set true if submitting after read access was revoked or for a fetched target.",
                    ],
                    "instruction_target": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 80,
                    ],
                    "instruction_revision": [
                        "type": "string",
                        "pattern": "^[0-9a-f]{64}$",
                    ],
                    "delivery_proof": [
                        "type": "string",
                        "minLength": 32,
                        "maxLength": 64,
                    ],
                ],
                "additionalProperties": false,
            ],
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ],
    ]

    func handle(frame: Data) -> [String: Any]? {
        guard let req = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              (req["jsonrpc"] as? String) == "2.0",
              let method = req["method"] as? String else {
            return (try? JSONSerialization.jsonObject(with: frame)) == nil
                ? rpcError(NSNull(), -32700, "Parse error")
                : rpcError(NSNull(), -32600, "Invalid request")
        }

        let params = req["params"] ?? [:]
        if req["id"] == nil {
            if method == "notifications/initialized", initialized, params is [String: Any] {
                ready = true
            }
            return nil
        }

        guard let requestID = req["id"], isValidRequestID(requestID) else {
            return rpcError(NSNull(), -32600, "Invalid request ID")
        }
        guard let dictParams = params as? [String: Any] else {
            return rpcError(requestID, -32602, "Invalid params")
        }

        switch method {
        case "initialize":
            guard !initialized,
                  dictParams["protocolVersion"] is String,
                  dictParams["capabilities"] is [String: Any],
                  let client = dictParams["clientInfo"] as? [String: Any],
                  let name = client["name"] as? String,
                  client["version"] is String else {
                return rpcError(requestID, -32602, "Invalid initialization")
            }
            initialized = true
            clientName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
            return [
                "jsonrpc": "2.0",
                "id": requestID,
                "result": [
                    "protocolVersion": NativeAgentMCP.protocolVersion,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "codebasic-tts-agent", "version": "0.1.0"],
                ],
            ]

        case "ping":
            return ["jsonrpc": "2.0", "id": requestID, "result": [:]]

        case "tools/list":
            guard ready else { return rpcError(requestID, -32002, "Server not initialized") }
            guard dictParams["cursor"] == nil else { return rpcError(requestID, -32602, "Invalid cursor") }
            return ["jsonrpc": "2.0", "id": requestID, "result": ["tools": Self.tools]]

        case "tools/call":
            guard ready else { return rpcError(requestID, -32002, "Server not initialized") }
            guard dictParams["task"] == nil else {
                return rpcError(requestID, -32602, "Task execution is not supported")
            }
            guard let toolName = dictParams["name"] as? String else {
                return rpcError(requestID, -32602, "Invalid tool call")
            }
            let args = dictParams["arguments"]
            switch toolName {
            case "pair_tts_session":
                return ["jsonrpc": "2.0", "id": requestID, "result": callPair(args)]
            case "get_agent_instruction":
                return ["jsonrpc": "2.0", "id": requestID, "result": callGetInstruction(args)]
            case "submit_explanation_draft":
                return ["jsonrpc": "2.0", "id": requestID, "result": callSubmitDraft(args)]
            default:
                return rpcError(requestID, -32602, "Unknown tool")
            }

        default:
            return rpcError(requestID, -32601, "Method not found")
        }
    }

    private func callPair(_ rawArgs: Any?) -> [String: Any] {
        let dict: [String: Any]
        if let rawArgs {
            guard let d = rawArgs as? [String: Any] else {
                return textResult("invalid: Invalid pairing arguments.", isError: true)
            }
            dict = d
        } else {
            dict = [:]
        }
        guard Set(dict.keys).isSubset(of: ["client_note"]) else {
            return textResult("invalid: Unexpected pairing arguments.", isError: true)
        }
        var note = clientName
        if let rawNote = dict["client_note"] {
            guard let s = rawNote as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return textResult("invalid: client_note must be a non-empty string.", isError: true)
            }
            note = String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        switch NativeAgentMCP.exchangeUnix(
            socketName: "pair.sock",
            requestObject: ["op": "pair_knock", "client_name": note]
        ) {
        case .offline:
            return textResult("offline: Pairing wait mode is not open in Codebasic TTS (helper PID \(pid)).", isError: true)
        case .unsafe:
            return textResult("unsafe: Could not verify Codebasic TTS app signature.", isError: true)
        case .unconfirmed:
            return textResult("unconfirmed: Could not confirm pairing request.", isError: true)
        case .ok(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let status = obj["status"] else {
                return textResult("unconfirmed: Malformed pairing reply.", isError: true)
            }
            switch status {
            case "pending_approval":
                return textResult("pending_approval: Helper PID \(pid) knocked; approve in the Agent tab.", isError: false)
            case "already_pinned":
                return textResult("already_pinned: Helper PID \(pid) is already pinned.", isError: false)
            default:
                return textResult("\(status): Pairing request was not accepted (helper PID \(pid)).", isError: true)
            }
        }
    }

    private func callGetInstruction(_ rawArgs: Any?) -> [String: Any] {
        guard let args = rawArgs as? [String: Any],
              Set(args.keys) == ["target"],
              let target = args["target"] as? String,
              InstructionTarget(wireName: target) != nil else {
            return textResult("invalid: Provide a valid instruction target.", isError: true)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        switch NativeAgentMCP.exchangeUnix(socketName: "i.sock", requestObject: ["target": target]) {
        case .offline:
            return textResult("offline: Instruction read is not currently permitted for helper PID \(pid).", isError: true)
        case .unsafe:
            return textResult("unsafe: Could not verify Codebasic TTS app signature.", isError: true)
        case .unconfirmed:
            return textResult("unconfirmed: No approved instruction returned for helper PID \(pid).", isError: true)
        case .ok(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  NativeAgentMCP.verifyInstructionReply(obj, requestedTarget: target),
                  let instructions = obj["instructions"] as? String else {
                return textResult("unsafe: Returned instruction payload failed integrity verification.", isError: true)
            }
            return [
                "content": [["type": "text", "text": instructions]],
                "structuredContent": obj,
                "isError": false,
            ]
        }
    }

    private func callSubmitDraft(_ rawArgs: Any?) -> [String: Any] {
        guard let args = rawArgs as? [String: Any] else {
            return textResult("invalid: Invalid draft arguments.", isError: true)
        }
        let allowed: Set<String> = [
            "idempotency_key", "display_text", "speech_text",
            "late_draft", "instruction_target", "instruction_revision", "delivery_proof",
        ]
        guard Set(args.keys).isSubset(of: allowed),
              let key = args["idempotency_key"] as? String, NativeAgentMCP.validID(key),
              let display = args["display_text"] as? String, NativeAgentMCP.validText(display) else {
            return textResult("invalid: Invalid idempotency_key or display_text.", isError: true)
        }
        if let rawSpeech = args["speech_text"] {
            guard let speech = rawSpeech as? String, NativeAgentMCP.validText(speech) else {
                return textResult("invalid: Invalid speech_text.", isError: true)
            }
        }
        if let rawLate = args["late_draft"], !(rawLate is Bool) {
            return textResult("invalid: late_draft must be boolean.", isError: true)
        }
        if let rawTarget = args["instruction_target"] {
            guard let t = rawTarget as? String, InstructionTarget(wireName: t) != nil else {
                return textResult("invalid: Invalid instruction_target.", isError: true)
            }
        }
        if let rawRev = args["instruction_revision"] {
            guard let r = rawRev as? String,
                  r.utf8.count == 64,
                  r.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                return textResult("invalid: Invalid instruction_revision.", isError: true)
            }
        }
        if let rawProof = args["delivery_proof"] {
            guard let p = rawProof as? String, (32...64).contains(p.utf8.count) else {
                return textResult("invalid: Invalid delivery_proof.", isError: true)
            }
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        switch NativeAgentMCP.exchangeUnix(socketName: "d.sock", requestObject: args) {
        case .offline:
            return textResult("offline: Draft receipt is not currently permitted for helper PID \(pid).", isError: true)
        case .unsafe:
            return textResult("unsafe: Could not verify Codebasic TTS app signature.", isError: true)
        case .unconfirmed:
            return textResult("unconfirmed: Could not confirm draft receipt; reuse the exact key on retry.", isError: true)
        case .ok(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let status = obj["status"] else {
                return textResult("unconfirmed: Malformed draft receipt reply.", isError: true)
            }
            return textResult(
                "\(status): Draft status '\(status)' (helper PID \(pid)).",
                isError: status != "accepted" && status != "duplicate"
            )
        }
    }

    private func isValidRequestID(_ value: Any) -> Bool {
        if value is NSNumber {
            // Reject booleans bridged as NSNumber.
            return CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID()
        }
        if let s = value as? String {
            return s.utf8.count <= 256
        }
        return false
    }

    private func textResult(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func rpcError(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}

@main struct CodebasicTTSAgentMCPMain {
    static func writeJSONLine(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else {
            return
        }
        data.append(10)
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var offset = 0
            while offset < ptr.count {
                let n = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), ptr.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let session = NativeMCPSession()
        var buffer = Data()
        var discardingOversized = false
        var chunk = [UInt8](repeating: 0, count: 8192)

        while true {
            let n = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if n <= 0 { break }
            for byte in chunk[0..<n] {
                if discardingOversized {
                    if byte == 10 {
                        discardingOversized = false
                        writeJSONLine(["jsonrpc": "2.0", "id": NSNull(),
                                       "error": ["code": -32700, "message": "Frame too long"]])
                    }
                    continue
                }
                if byte == 10 {
                    let frame = buffer
                    buffer.removeAll(keepingCapacity: true)
                    if let reply = session.handle(frame: frame) {
                        writeJSONLine(reply)
                    }
                } else {
                    if buffer.count >= NativeAgentMCP.maxStdioFrame {
                        buffer.removeAll(keepingCapacity: true)
                        discardingOversized = true
                    } else {
                        buffer.append(byte)
                    }
                }
            }
        }
    }
}
