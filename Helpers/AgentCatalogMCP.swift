import CoreFoundation
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
    static let guide = "get_tts_submission_guide"

    /// The one definition of what a draft submission may contain. The tool
    /// schemas, the argument check and the guide are all generated from it.
    /// `plain`/`linked`: true = required, false = optional, nil = not accepted.
    struct Field {
        let name: String
        let plain: Bool?
        let linked: Bool?
        let meaning: String
    }
    static let fields: [Field] = [
        Field(name: "profile", plain: nil, linked: true,
              meaning: "ID of the saved instruction the user selected, exactly as returned by \(reader). Only for \(receiver)."),
        Field(name: "revision", plain: nil, linked: true,
              meaning: "Revision of that instruction, exactly as returned by the same \(reader) call. Only for \(receiver)."),
        Field(name: "idempotency_key", plain: true, linked: true,
              meaning: "Retry key you choose once per draft: 1-128 characters of A-Z a-z 0-9 . _ -. Reuse it only to resend the identical draft."),
        Field(name: "title", plain: false, linked: false,
              meaning: "Optional name shown in the app's draft list only. Never inserted into the text, captions or speech. Up to \(AgentLimits.titleCharacters) characters and \(AgentLimits.titleBytes) UTF-8 bytes, one line. If omitted, the first non-blank line of display_text is shown instead."),
        Field(name: "display_text", plain: true, linked: true,
              meaning: "The body the user sees and edits, up to \(AgentLimits.textBytes) UTF-8 bytes. Do not repeat the title here unless it belongs in the body."),
        Field(name: "speech_text", plain: false, linked: false,
              meaning: "Optional separate wording to be read aloud instead of display_text, up to \(AgentLimits.textBytes) UTF-8 bytes. Omit it to read display_text."),
    ]

    static func names(linked: Bool, required: Bool? = nil) -> Set<String> {
        Set(fields.filter { field in
            guard let need = linked ? field.linked : field.plain else { return false }
            return required.map { $0 == need } ?? true
        }.map(\.name))
    }

    static func schema(linked: Bool) -> [String: Any] {
        var properties: [String: Any] = [:]
        for field in fields where (linked ? field.linked : field.plain) != nil {
            properties[field.name] = ["type": "string", "description": field.meaning]
        }
        return ["type": "object", "properties": properties, "additionalProperties": false,
                "required": fields.filter { (linked ? $0.linked : $0.plain) == true }.map(\.name)]
    }
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

    /// `--client <name>` supplies a display name only.
    static var clientOverride: String?
    static var clientName = "default"
    static var clientKey: ClientKey?
    static let registeredHost = AgentPeerSigning.registeredHost(pid: getpid())
    static var slot: Int?

    static func main() {
        // A keychain dialog raised by a background helper would block the agent's
        // tool call. An inaccessible registered credential stays unavailable.
        SecKeychainSetUserInteractionAllowed(false)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let flag = arguments.firstIndex(of: "--client"), arguments.indices.contains(flag + 1) {
            clientOverride = AgentPairing.clientName(arguments[flag + 1])
        }
        if arguments.contains("--forget-key") {
            // Explicit reset from the same registered host. A revoked credential
            // stays revoked until the host requests a reset and the user approves again.
            guard let registeredHost else { exit(1) }
            exit(ClientKey.delete(host: registeredHost) ? 0 : 1)
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
                            "instructions":"Open \(TTSRuntime.displayName) → Agent (에이전트), then enable the session. With no instruction selected, use submit_tts_draft without reading anything. If an instruction is selected, read it and use submit_explanation_draft. Call \(guide) for the fields, limits and examples. Incoming drafts open for editing without playback."])
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

                case guide where args.isEmpty:
                    // Format only: no socket is opened and nothing of the user's is read.
                    tool(id, guideText, extra: guideContent)

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
                    guard let reply = exchange(socket: "i", request),
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
                    guard validDraft(args, linked: false) else {
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
                    reportReceipt(id, exchange(socket: "d", request)?["status"] as? String)
                case receiver:
                    guard validDraft(args, linked: true),
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
                        guard let reply = exchange(socket: "i", ["schema_version": 2, "profile": profile]),
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
                    reportReceipt(id, exchange(socket: "d", request)?["status"] as? String)
                default:
                    emit(error(id, -32602, "Unknown tool"))
                }
            default:
                emit(error(id, -32601, "Method unavailable"))
            }
        }
    }

    static func validDraft(_ args: [String: Any], linked: Bool) -> Bool {
        let keys = Set(args.keys)
        guard keys.isSuperset(of: names(linked: linked, required: true)), keys.isSubset(of: names(linked: linked)),
              args["title"].map({ ($0 as? String).map { AgentBytes.title($0) != .invalid } == true }) ?? true,
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
        if let title = args["title"] as? String, AgentBytes.title(title) == .invalid {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let tooLong = trimmed.count > AgentLimits.titleCharacters || trimmed.utf8.count > AgentLimits.titleBytes
            tool(id, tooLong
                 ? "title is \(trimmed.count) characters (\(trimmed.utf8.count) UTF-8 bytes); the limit is \(AgentLimits.titleCharacters) characters and \(AgentLimits.titleBytes) bytes. Nothing was opened and nothing was shortened. Send a shorter title or omit it."
                 : "title must be a single line without control characters. Nothing was opened.",
                 failed: true, extra: tooLong
                 ? ["status": "too_large", "field": "title", "characters": trimmed.count, "bytes": trimmed.utf8.count,
                    "limit_characters": AgentLimits.titleCharacters, "limit_bytes": AgentLimits.titleBytes]
                 : ["status": "invalid", "field": "title"])
            return
        }
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
        case "busy": fail("busy", "The app could not store the draft, so nothing was opened. Ask the user to check \(app), then retry with the same key.")
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
        let none: [String: Any] = ["type":"object", "properties": [String: Any](), "additionalProperties":false]
        let readOnly: [String: Any] = ["readOnlyHint":true, "openWorldHint":false]
        let submit: [String: Any] = ["readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false]
        return [["name": statusTool, "description": "Check the local app connection and whether the user has approved access.",
                 "inputSchema": none, "annotations": readOnly],
                ["name": guide, "description": "Read how to submit a draft: which tool to use, every field and its limit, examples, and what to do for each result. Returns format information only; reads nothing of the user's and changes nothing.",
                 "inputSchema": none, "annotations": readOnly],
                ["name":reader, "description":"Read the exact instruction revision approved in the app. Omit profile to use the approved selection.",
                 "inputSchema":["type":"object","properties":["profile":["type":"string"]],"additionalProperties":false],
                 "annotations": readOnly],
                ["name":plainReceiver, "description":"Open an editable plain-text draft without reading any instruction. Available only when no saved instruction is selected. Never plays. See \(guide) for the fields.",
                 "inputSchema": schema(linked: false), "annotations": submit],
                ["name":receiver, "description":"Open an editable draft linked to the selected saved revision received by this helper. Receipt proof does not verify content compliance. Never plays. See \(guide) for the fields.",
                 "inputSchema": schema(linked: true), "annotations": submit]]
    }

    static let statusActions: [(String, String)] = [
        ("accepted", "Received and opened for editing. Done."),
        ("duplicate", "This exact draft was already received under this key. Done; do not send it again."),
        ("conflict", "This key was already used for a different title or text. Nothing changed. Use a new key only if this is really a new draft."),
        ("unconfirmed", "No answer for this request. It may or may not have been received. Resend once with the same key and identical fields; never with a new key."),
        ("instruction_required", "The user selected a saved instruction. Read it with \(reader) and use \(receiver), or ask the user to clear the selection. Do not work around it."),
        ("unproven", "The selected instruction changed or was not read by this helper. Read it again with \(reader), then resend with the returned profile and revision."),
        ("approval_required", "Ask the user to approve this pending connection in the app. Do not retry in a loop."),
        ("disabled", "Draft receipt is off for this app or globally. Ask the user to turn it on."),
        ("revoked", "This app's approval was revoked. It requires a credential reset and new approval."),
        ("locked", "The Mac is locked. Retry after the user unlocks it."),
        ("too_large", "A field is over its limit. Nothing was opened or shortened. Shorten it, or split the body into separate drafts with their own keys."),
        ("invalid", "A field is missing, misnamed or malformed. Fix the arguments; resending unchanged will not help."),
        ("rate_limited", "Too many drafts in a short time. Wait a minute, then resend with the same key."),
        ("busy", "The app could not store the draft. Ask the user to check the app, then resend with the same key."),
    ]

    static var guideContent: [String: Any] {
        func tool(_ linked: Bool, _ when: String) -> [String: Any] {
            ["when": when, "required": fields.filter { (linked ? $0.linked : $0.plain) == true }.map(\.name),
             "optional": fields.filter { (linked ? $0.linked : $0.plain) == false }.map(\.name)]
        }
        return [
            "tools": [
                plainReceiver: tool(false, "No saved instruction is selected in the app (\(statusTool) reports receiving_only). Leave out profile and revision entirely."),
                receiver: tool(true, "The user selected a saved instruction (\(statusTool) reports ready). First call \(reader); pass the profile and revision it returns."),
            ],
            "fields": Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.meaning) }),
            "limits": ["text_bytes": AgentLimits.textBytes, "frame_bytes": maxFrame,
                       "title_characters": AgentLimits.titleCharacters, "title_bytes": AgentLimits.titleBytes],
            "examples": [
                plainReceiver: ["idempotency_key": "demo-1", "title": "예제 제목", "display_text": "이 문장만 본문입니다."],
                receiver: ["profile": "<profile returned by \(reader)>", "revision": "<revision returned by the same call>",
                           "idempotency_key": "demo-2", "display_text": "이 문장만 본문입니다."],
            ],
            "results": Dictionary(uniqueKeysWithValues: statusActions),
        ]
    }

    static var guideText: String {
        var lines = ["How to submit a draft to \(TTSRuntime.displayName). Drafts open for editing; nothing is played automatically.", "",
                     "Which tool:"]
        for (name, linked) in [(plainReceiver, false), (receiver, true)] {
            let info = (guideContent["tools"] as? [String: [String: Any]])?[name]
            lines.append("- \(name): \(info?["when"] as? String ?? "")")
            lines.append("  required: \((info?["required"] as? [String] ?? []).joined(separator: ", ")); optional: \((info?["optional"] as? [String] ?? []).joined(separator: ", "))")
            _ = linked
        }
        lines += ["", "Fields:"] + fields.map { "- \($0.name): \($0.meaning)" }
        lines += ["", "Examples (replace the <...> values with what \(reader) actually returned):"]
        for name in [plainReceiver, receiver] {
            if let example = (guideContent["examples"] as? [String: Any])?[name],
               let data = try? JSONSerialization.data(withJSONObject: example, options: [.sortedKeys, .withoutEscapingSlashes]) {
                lines.append("- \(name) \(String(decoding: data, as: UTF8.self))")
            }
        }
        lines += ["", "Results (structuredContent.status) and what to do:"] + statusActions.map { "- \($0.0): \($0.1)" }
        return lines.joined(separator: "\n")
    }

    /// Asks the app where this process stands and, when the app does not know
    /// it yet, proves which client it is. Never needs the user unless the app
    /// answers that an approval is required.
    static func pairingStatus() -> String {
        guard pin != nil else { return "signing_required" }
        slot = nil
        let schema = AgentPairing.schema
        guard let reply = exchange(socket: "p.sock", ["schema_version": schema, "op": "status"]) else {
            return "app_unavailable"
        }
        let status = connectionState(reply)
        guard status == "identify" else { return status }
        if clientKey == nil { clientKey = ClientKey.load(host: registeredHost) }
        guard let key = clientKey else { return "unavailable" }
        let hello: [String: Any] = ["schema_version": schema, "op": "hello", "client": clientName,
                                    "public_key": key.publicKey.base64EncodedString(), "persistent": key.persistent]
        guard let offer = exchange(socket: "p.sock", hello),
              let answer = offer["status"] as? String else { return "app_unavailable" }
        guard answer == "challenge", let nonce = offer["nonce"] as? String else { return answer }
        let message = AgentPairing.message(appID: AgentPeerSigning.appID, nonce: nonce, keyID: AgentBytes.hash(key.publicKey))
        guard let signature = key.sign(message) else { return "unavailable" }
        let proof: [String: Any] = ["schema_version": schema, "op": "prove", "nonce": nonce,
                                    "signature": signature.base64EncodedString()]
        guard let result = exchange(socket: "p.sock", proof) else { return "app_unavailable" }
        return connectionState(result)
    }

    private static func connectionState(_ result: [String: Any]) -> String {
        guard let status = result["status"] as? String else { return "app_unavailable" }
        if ["ready", "receiving_only", "instruction_required", "reading_only"].contains(status) {
            guard let raw = result["slot"] as? String, let index = Int(raw),
                  (0..<AgentPairing.slotCount).contains(index), raw == String(index) else { return "upgrade_required" }
            slot = index
        }
        return status
    }

    static func describe(_ status: String) -> String {
        switch status {
        case "signing_required": return "Use the certificate-signed helper bundled with \(TTSRuntime.displayName)."
        case "app_unavailable": return "Open \(TTSRuntime.displayName) and try again. The running app must match this signed helper."
        case "other_agent": return "This agent app already has a connected MCP session. Close that session or disconnect it in \(TTSRuntime.displayName) → Agent (에이전트), then retry."
        case "approval_required": return "Ask the user to approve this specific pending connection in \(TTSRuntime.displayName) → Agent (에이전트), then check again."
        case "disabled": return "Draft receipt is off globally or for this agent app. Ask the user to enable it in \(TTSRuntime.displayName) → Agent (에이전트)."
        case "locked": return "The Mac's screen is locked, so nothing is received. Retry after the user unlocks it; no new approval is needed."
        case "revoked": return "The user removed this client in \(TTSRuntime.displayName). An explicit host credential reset and a new approval are required for this registered agent."
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

    static func exchange(socket kind: String, _ request: [String: Any]) -> [String: Any]? {
        guard let pin else { return nil }
        let endpoint: String
        switch kind {
        case "p.sock": endpoint = kind
        case "i":
            guard let slot else { return nil }
            endpoint = AgentPairing.instructionEndpoint(slot: slot)
        case "d":
            guard let slot else { return nil }
            endpoint = AgentPairing.draftEndpoint(slot: slot)
        default: return nil
        }
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
        let maximum = kind == "i" ? 52 * 1024 : 256
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

/// A registered host (an identified agent app) gets a durable signing key in a
/// private per-user file. All other hosts use a fresh key for the current
/// helper process.
struct ClientKey {
    let key: SecKey
    let publicKey: Data
    let persistent: Bool

    private static func slot(_ host: String) -> String { AgentBytes.hash(Data(host.utf8)) }

    private static let keyAttributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
    ]

    /// Coordinate credential creation and explicit reset across helper processes.
    private static func withSlot<T>(_ host: String, _ run: (String) -> T?) -> T? {
        let slot = slot(host)
        let directory = open(TTSRuntime.socketDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { return nil }
        let fd = openat(directory, ".client-keys.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
        return run(slot)
    }

    static func load(host: String?) -> ClientKey? {
        if let host {
            // A busy or unreadable registered slot is retryable. Never replace an
            // unreadable key or silently issue an ephemeral one for this host.
            return withSlot(host) { slot in storedKey(slot) }
        }
        return SecKeyCreateRandomKey(keyAttributes as CFDictionary, nil).flatMap { make($0, persistent: false) }
    }

    static func delete(host: String) -> Bool {
        withSlot(host) { slot in
            guard let url = keyURL(slot) else { return false }
            if unlink(url.path) == 0 || errno == ENOENT { return true }
            return false
        } ?? false
    }

    /// Keys live in a private file rather than the login Keychain. A Keychain key
    /// created by a self-signed helper (no Team ID) is bound to that build's
    /// cdhash, so every rebuild or update of the app would lose access to it and
    /// the approved app could never connect again. The approval itself is bound
    /// to the launching app's code signature; this key only proves continuity of
    /// one helper credential and is readable only by this user.
    private static func keyDirectory() -> URL? {
        #if TTS_AGENT_FIXTURE_KEYS
        // Integration fixtures use their own synthetic key directory.
        return ProcessInfo.processInfo.environment["TTS_AGENT_FIXTURE_KEY_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        return TTSRuntime.applicationSupport(home: URL(fileURLWithPath: String(cString: home), isDirectory: true))
            .appendingPathComponent("agent-client-keys", isDirectory: true)
        #endif
    }

    private static func keyURL(_ slot: String) -> URL? {
        guard let directory = keyDirectory() else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { return nil }
        return directory.appendingPathComponent(slot + ".key")
    }

    private static func storedKey(_ slot: String) -> ClientKey? {
        guard let url = keyURL(slot) else { return nil }
        var attributes = keyAttributes
        attributes[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096,
                  let bytes = try? reader.read(upToCount: 4096),
                  let key = SecKeyCreateWithData(bytes as CFData, attributes as CFDictionary, nil) else { return nil }
            let stored = make(key, persistent: true)
            return stored?.sign(Data("self-test".utf8)) == nil ? nil : stored
        }
        guard errno == ENOENT,
              let key = SecKeyCreateRandomKey(keyAttributes as CFDictionary, nil),
              let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        let temp = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
        let out = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { return nil }
        defer { unlink(temp.path) }
        let writer = FileHandle(fileDescriptor: out, closeOnDealloc: true)
        // Publish with an exclusive rename, not link()+unlink(): a helper killed
        // between those two calls would leave the key with st_nlink == 2, which
        // the read path above rejects forever. rename keeps one link at every
        // instant, and RENAME_EXCL never replaces a key that already exists.
        guard (try? writer.write(contentsOf: bytes)) != nil, (try? writer.synchronize()) != nil,
              renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 else { return nil }
        return make(key, persistent: true)
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
