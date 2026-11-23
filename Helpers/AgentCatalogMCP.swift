import Darwin
import Foundation
import Security

/// One native signed helper per MCP session. This executable owns both local
/// connections; the model never sees a receipt capability or pairing identity.
/// The helper proves which approved client it is with a key only it can use.
@main struct AgentCatalogMCP {
    static let maxFrame = AgentLimits.frameBytes
    static let statusTool = "tts_agent_status"
    static let reader = "get_tts_instructions"
    static let plainReceiver = "submit_tts_draft"
    static let receiver = "submit_explanation_draft"
    static let maxProofs = AgentLimits.proofCount
    // Derive the peer pin from this trusted bundled executable, never the socket.
    static let pin = AgentPeerSigning.ownLeaf()
    static let directory = TTSRuntime.socketDirectory

    struct Proof {
        let profile: String
        let revision: String
        let bodyHash: String
        var token: String
        var expiry: ContinuousClock.Instant
        var key: String { profile + ":" + revision }
    }

    /// `--client <name>` names the key slot; otherwise the MCP client's own name does.
    static var clientOverride: String?
    static var clientName = "default"
    static var clientKey: ClientKey?

    static func main() {
        // A keychain dialog raised by a background helper would block the agent's
        // tool call. Fail instead; an unusable key is replaced and approved again.
        SecKeychainSetUserInteractionAllowed(false)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let flag = arguments.firstIndex(of: "--client"), arguments.indices.contains(flag + 1) {
            clientOverride = AgentPairing.clientName(arguments[flag + 1])
        }
        if arguments.contains("--forget-key") {
            // Lets the user discard this client's credential from the client side.
            exit(ClientKey.delete(slot: clientOverride ?? "default") ? 0 : 1)
        }
        var initialized = false, ready = false
        var proofs: [Proof] = []
        while let input = readFrame() {
            if input.isEmpty { emit(error(nil, -32700, "Malformed or oversized frame")); continue }
            guard let frame = decode(input), frame["jsonrpc"] as? String == "2.0",
                  let method = frame["method"] as? String else {
                emit(error(nil, -32600, "Invalid request")); continue
            }
            guard let id = frame["id"] else {
                if method == "notifications/initialized", initialized, !ready {
                    ready = true
                    _ = pairingStatus()
                }
                continue
            }
            guard id is String || id is NSNumber else { emit(error(nil, -32600, "Invalid request id")); continue }
            let params = frame["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                guard !initialized else { emit(error(id, -32600, "Already initialized")); continue }
                initialized = true
                clientName = clientOverride ?? AgentPairing.clientName((params["clientInfo"] as? [String: Any])?["name"] as? String)
                let requested = params["protocolVersion"] as? String ?? ""
                let version = ["2025-11-25", "2025-06-18", "2025-03-26"].contains(requested) ? requested : "2025-11-25"
                result(id, ["protocolVersion":version, "serverInfo":["name":TTSRuntime.mcpServerName, "version":"2.0"],
                            "capabilities":["tools":["listChanged":false]],
                            "instructions":"Open \(TTSRuntime.displayName) → Agent (에이전트), then enable the session. With no instruction selected, use submit_tts_draft without reading anything. If an instruction is selected, read it and use submit_explanation_draft. Incoming drafts open for editing without playback."])
            case "ping":
                result(id, [:])
            case "tools/list" where ready:
                result(id, ["tools": tools])
            case "tools/call" where ready:
                guard let name = params["name"] as? String, (params["arguments"] == nil || params["arguments"] is [String: Any]) else {
                    emit(error(id, -32602, "Tool name and arguments required")); continue
                }
                let args = params["arguments"] as? [String: Any] ?? [:]
                switch name {
                case statusTool where args.isEmpty:
                    let status = pairingStatus()
                    tool(id, describe(status), extra: ["status": status, "limits": [
                        "text_bytes": AgentLimits.textBytes, "frame_bytes": maxFrame] as [String: Any]])

                case reader:
                    let requested = args["profile"] as? String
                    guard args.isEmpty || (Set(args.keys) == ["profile"] && requested.map(validSelector) == true) else {
                        tool(id, "Omit profile to read the approved selection, or specify its exact ID.", failed: true); continue
                    }
                    let status = pairingStatus()
                    guard status == "ready" || status == "reading_only" else {
                        tool(id, describe(status), failed: true, extra: ["status": status]); continue
                    }
                    var request: [String: Any] = ["schema_version": 2]
                    if let requested { request["profile"] = requested }
                    guard let reply = exchange(socket: "i.sock", request),
                          reply["schema_version"] as? Int == 2,
                          let selector = reply["profile"] as? String, validSelector(selector),
                          requested == nil || requested == selector,
                          let text = reply["instructions"] as? String, AgentBytes.textValid(text),
                          let rev = reply["revision"] as? String, UUID(uuidString: rev) != nil,
                          let hash = reply["body_sha256"] as? String, hash == AgentBytes.hash(Data(text.utf8)),
                          let opaque = reply["proof"] as? String, UUID(uuidString: opaque) != nil else {
                        tool(id, "That profile is not approved or its revision changed. Select it in \(TTSRuntime.displayName) → Agent (에이전트).", failed: true); continue
                    }
                    let proof = Proof(profile: selector, revision: rev, bodyHash: hash, token: opaque,
                                      expiry: .now.advanced(by: .seconds(AgentLimits.proofSeconds)))
                    proofs.removeAll { $0.key == proof.key }
                    proofs.append(proof)
                    if proofs.count > maxProofs { proofs.removeFirst(proofs.count - maxProofs) }
                    tool(id, text, extra: ["schema_version":2, "profile":selector, "revision":rev,
                                          "body_sha256":hash, "instructions":text])
                case plainReceiver:
                    let required: Set<String> = ["idempotency_key", "display_text"]
                    guard validDraft(args, required: required) else {
                        rejectDraft(id, args, "Invalid plain-text draft arguments."); continue
                    }
                    let status = pairingStatus()
                    if status == "ready" || status == "instruction_required" {
                        reportReceipt(id, "instruction_required", shareable: status == "ready"); continue
                    }
                    guard status == "receiving_only" else {
                        tool(id, describe(status), failed: true, extra: ["status": status]); continue
                    }
                    var request = args
                    request["schema_version"] = 2
                    reportReceipt(id, exchange(socket: "d.sock", request)?["status"] as? String)
                case receiver:
                    let required: Set<String> = ["profile", "revision", "idempotency_key", "display_text"]
                    guard validDraft(args, required: required),
                          let profile = args["profile"] as? String, let revision = args["revision"] as? String else {
                        rejectDraft(id, args, "Invalid instruction-linked draft arguments."); continue
                    }
                    let connection = pairingStatus()
                    guard connection == "ready" || connection == "receiving_only" || connection == "instruction_required" else {
                        let message = connection == "reading_only"
                            ? "Draft receipt is not approved. Select an instruction in \(TTSRuntime.displayName) → Agent (에이전트)."
                            : describe(connection)
                        tool(id, message, failed: true, extra: ["status": connection]); continue
                    }
                    guard let index = proofs.lastIndex(where: { $0.profile == profile && $0.revision == revision }) else {
                        tool(id, "This helper did not receive that exact revision. Read it first or paste manually.", failed: true,
                             extra: ["status": "unproven"]); continue
                    }
                    if proofs[index].expiry <= .now {
                        // Only the proof aged out. Read the same selection again through
                        // the normal channel; anything but the identical revision and
                        // body means the user changed it, and the agent must read it.
                        guard let reply = exchange(socket: "i.sock", ["schema_version": 2, "profile": profile]),
                              reply["revision"] as? String == revision,
                              reply["body_sha256"] as? String == proofs[index].bodyHash,
                              let text = reply["instructions"] as? String,
                              AgentBytes.hash(Data(text.utf8)) == proofs[index].bodyHash,
                              let opaque = reply["proof"] as? String, UUID(uuidString: opaque) != nil else {
                            proofs.remove(at: index)
                            reportReceipt(id, "unproven"); continue
                        }
                        proofs[index].token = opaque
                        proofs[index].expiry = .now.advanced(by: .seconds(AgentLimits.proofSeconds))
                    }
                    let proof = proofs[index]
                    var request = args
                    request["schema_version"] = 2
                    request["body_sha256"] = proof.bodyHash
                    request["proof"] = proof.token
                    reportReceipt(id, exchange(socket: "d.sock", request)?["status"] as? String)
                default:
                    emit(error(id, -32602, "Unknown tool"))
                }
            default:
                emit(error(id, -32601, "Method unavailable"))
            }
        }
    }

    static func validDraft(_ args: [String: Any], required: Set<String>) -> Bool {
        let keys = Set(args.keys)
        guard keys == required || keys == required.union(["speech_text"]),
              let retry = args["idempotency_key"] as? String,
              // Byte check identical to the app's, so a key cannot pass here and fail there.
              (1...128).contains(retry.utf8.count),
              retry.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }),
              let display = args["display_text"] as? String, AgentBytes.textValid(display) else { return false }
        return args["speech_text"].map { ($0 as? String).map(AgentBytes.textValid) == true } ?? true
    }

    /// Says which limit a refused draft broke, in bytes, so a client never has to
    /// guess whether a long script was cut, dropped or rejected.
    static func rejectDraft(_ id: Any, _ args: [String: Any], _ fallback: String) {
        let sizes = ["display_text", "speech_text"].compactMap { name in (args[name] as? String).map { (name, $0.utf8.count) } }
        guard let (name, bytes) = sizes.first(where: { $0.1 > AgentLimits.textBytes }) else {
            tool(id, fallback, failed: true, extra: ["status": "invalid"]); return
        }
        tool(id, "\(name) is \(bytes) UTF-8 bytes; the limit is \(AgentLimits.textBytes). Nothing was opened. Shorten it or split it into separate drafts with their own keys.",
             failed: true, extra: ["status": "too_large", "field": name, "bytes": bytes, "limit_bytes": AgentLimits.textBytes])
    }

    /// Every outcome carries a machine-readable status, and each failure names a
    /// recovery the agent or the user can actually perform in the reported state.
    static func reportReceipt(_ id: Any, _ status: String?, shareable: Bool? = nil) {
        let app = "\(TTSRuntime.displayName) → Agent (에이전트)"
        func fail(_ code: String, _ message: String) { tool(id, message, failed: true, extra: ["status": code]) }
        switch status {
        case "accepted": tool(id, "Received in the app’s editor. Not played.", extra: ["status": "accepted"])
        case "duplicate": tool(id, "Already received. Nothing new was opened or played.", extra: ["status": "duplicate"])
        case "conflict": fail("conflict", "Retry key already used for different content. Use a new key for new content.")
        case "busy": fail("busy", "Open documents have reached their limit. Ask the user to close a tab in \(app), then retry with the same key.")
        case "editor_full":
            fail("editor_full", "The text open in the app is too large to keep beside a new draft. Ask the user to shorten or move it in \(app), then retry with the same key.")
        case "rate_limited": fail("rate_limited", "This session’s receipt rate limit was reached. Wait a minute, then retry with the same key.")
        case "instruction_required":
            switch shareable {
            case true?:
                fail("instruction_required", "A saved instruction is selected. Read it with get_tts_instructions and send with submit_explanation_draft, or ask the user to clear the selection.")
            case false?:
                fail("instruction_required", "A saved instruction is selected but is not being shared, so it cannot be read. Ask the user to select it again or clear the selection in \(app).")
            case nil:
                fail("instruction_required", "A saved instruction is selected. Check tts_agent_status: when it is ready, read the instruction and use submit_explanation_draft; otherwise ask the user to select it again or clear the selection in \(app).")
            }
        case "unproven": fail("unproven", "Instruction selection, revision, or proof is no longer valid. Check tts_agent_status, read the selected saved instruction again, and retry.")
        case "invalid": fail("invalid", "The app rejected the draft arguments. Check the key and text limits; retrying unchanged will not help.")
        case "upgrade_required": fail("upgrade_required", "The running app and this helper are different versions. Use the helper bundled with the running app.")
        default: fail("unconfirmed", "Receipt not confirmed. Check tts_agent_status and retry with the same key.")
        }
    }

    static var tools: [[String: Any]] {
        let string = ["type":"string"]
        return [["name": statusTool, "description": "Check the local app connection and whether the user has approved access.",
                 "inputSchema": ["type":"object", "properties": [String: Any](), "additionalProperties":false],
                 "annotations": ["readOnlyHint":true, "openWorldHint":false]],
                ["name":reader, "description":"Read the exact instruction revision approved in the app. Omit profile to use the approved selection.",
                 "inputSchema":["type":"object","properties":["profile":string],"additionalProperties":false],
                 "annotations":["readOnlyHint":true,"openWorldHint":false]],
                ["name":plainReceiver, "description":"Open an editable plain-text draft without reading any instruction. Available only when no saved instruction is selected. Never plays.",
                 "inputSchema":["type":"object", "properties":["idempotency_key":string,"display_text":string,"speech_text":string],
                                "required":["idempotency_key","display_text"], "additionalProperties":false],
                 "annotations":["readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false]],
                ["name":receiver, "description":"Open an editable draft linked to the selected saved revision received by this helper. Receipt proof does not verify content compliance. Never plays.",
                 "inputSchema":["type":"object", "properties":["profile":string,"revision":string,"idempotency_key":string,
                     "display_text":string,"speech_text":string],"required":["profile","revision","idempotency_key","display_text"],
                     "additionalProperties":false],
                 "annotations":["readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false]]]
    }

    /// Asks the app where this process stands and, when the app does not know
    /// it yet, proves which client it is. Never needs the user unless the app
    /// answers that an approval is required.
    static func pairingStatus() -> String {
        guard pin != nil else { return "signing_required" }
        let schema = AgentPairing.schema
        guard let status = exchange(socket: "p.sock", ["schema_version": schema, "op": "status"])?["status"] as? String else {
            return "app_unavailable"
        }
        guard status == "identify" else { return status }
        for attempt in 0..<2 {
            if clientKey == nil { clientKey = ClientKey.load(slot: clientName) }
            guard let key = clientKey else { return "unavailable" }
            let hello: [String: Any] = ["schema_version": schema, "op": "hello", "client": clientName,
                                        "public_key": key.publicKey.base64EncodedString(), "persistent": key.persistent]
            guard let offer = exchange(socket: "p.sock", hello), let answer = offer["status"] as? String else { return "app_unavailable" }
            if answer == "revoked", attempt == 0 {
                // The user forgot this client. Its old credential is dead; a new
                // one starts over as an unknown client that needs approval.
                ClientKey.delete(slot: clientName)
                clientKey = nil
                continue
            }
            guard answer == "challenge", let nonce = offer["nonce"] as? String else { return answer }
            let message = AgentPairing.message(appID: AgentPeerSigning.appID, nonce: nonce, keyID: AgentBytes.hash(key.publicKey))
            guard let signature = key.sign(message) else {
                // The stored key can no longer be used by this build of the helper.
                ClientKey.delete(slot: clientName)
                clientKey = nil
                if attempt == 0 { continue }
                return "unavailable"
            }
            let proof: [String: Any] = ["schema_version": schema, "op": "prove", "nonce": nonce,
                                        "signature": signature.base64EncodedString()]
            return exchange(socket: "p.sock", proof)?["status"] as? String ?? "app_unavailable"
        }
        return "unavailable"
    }

    static func describe(_ status: String) -> String {
        switch status {
        case "signing_required": return "Use the certificate-signed helper bundled with \(TTSRuntime.displayName)."
        case "app_unavailable": return "Open \(TTSRuntime.displayName) and try again. The running app must match this signed helper."
        case "other_agent": return "Another MCP session is connected. Close it or disconnect it in \(TTSRuntime.displayName) → Agent (에이전트), then retry."
        case "approval_required": return "Not approved yet, or receipt is off. Ask the user to turn on the connection in \(TTSRuntime.displayName) → Agent (에이전트), then check again. An approved client is not asked again."
        case "locked": return "The Mac's screen is locked, so nothing is received. Retry after the user unlocks it; no new approval is needed."
        case "revoked": return "The user removed this client in \(TTSRuntime.displayName). Ask them to approve it again in Agent (에이전트)."
        case "upgrade_required": return "The running app and this helper are different versions. Use the helper bundled with the running app."
        case "reading_only": return "Connected. One instruction revision is approved. Draft receipt is off."
        case "receiving_only": return "Connected. Send with submit_tts_draft; there is no selected instruction."
        case "instruction_required": return "A saved instruction was selected but is no longer shareable. Ask the user to update or clear the selection."
        case "ready": return "Connected. Read the selected saved instruction and submit with submit_explanation_draft. Nothing plays automatically."
        default: return "Connection not confirmed. Check \(TTSRuntime.displayName) → Agent (에이전트) and try again."
        }
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
        guard let pin, ["p.sock", "i.sock", "d.sock"].contains(endpoint) else { return nil }
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
        // Never wait indefinitely for a saturated or nonresponsive local listener.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        let connection = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connection == 0, fcntl(fd, F_SETFL, flags) == 0,
              AgentPeerSigning.matches(socket: fd, identifier: AgentPeerSigning.appID, leaf: pin) else { return nil }
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
        let maximum = endpoint == "i.sock" ? 52 * 1024 : 256
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

/// This client's signing key. Kept in the login keychain, marked non-extractable,
/// and usable without a prompt only by the helper build that created it. When the
/// keychain cannot hold one, the key lives for this process only and the app is
/// told so, which means the user approves each run.
struct ClientKey {
    let key: SecKey
    let publicKey: Data
    let persistent: Bool

    private static func tag(_ slot: String) -> Data { Data("\(AgentPeerSigning.helperID).client.\(slot)".utf8) }

    private static func query(_ slot: String) -> [String: Any] {
        [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag(slot),
         kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom]
    }

    static func load(slot: String) -> ClientKey? {
        var found: CFTypeRef?
        var lookup = query(slot)
        lookup[kSecReturnRef as String] = true
        if SecItemCopyMatching(lookup as CFDictionary, &found) == errSecSuccess, let found,
           CFGetTypeID(found) == SecKeyGetTypeID(), let existing = make(found as! SecKey, persistent: true),
           existing.sign(Data("self-test".utf8)) != nil {
            return existing
        }
        delete(slot: slot)
        let stored: [String: Any] = [
            kSecAttrIsExtractable as String: false,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag(slot),
                kSecAttrLabel as String: "\(TTSRuntime.displayName) agent client (\(slot))"] as [String: Any]]
        if let created = SecKeyCreateRandomKey(stored as CFDictionary, nil), let key = make(created, persistent: true),
           key.sign(Data("self-test".utf8)) != nil {
            return key
        }
        delete(slot: slot)
        let temporary: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                        kSecAttrKeySizeInBits as String: 256]
        return SecKeyCreateRandomKey(temporary as CFDictionary, nil).flatMap { make($0, persistent: false) }
    }

    @discardableResult
    static func delete(slot: String) -> Bool {
        let status = SecItemDelete(query(slot) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func make(_ key: SecKey, persistent: Bool) -> ClientKey? {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, bytes.count == 65 else { return nil }
        return ClientKey(key: key, publicKey: bytes, persistent: persistent)
    }

    func sign(_ message: Data) -> Data? {
        SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, nil) as Data?
    }
}
