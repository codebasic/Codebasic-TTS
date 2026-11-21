// Agent bridge: signed local STDIO MCP helper for the Codebasic TTS app.
//
// Build (comments only, nothing here is executed):
//   swiftc -O -swift-version 5 Sources/App/AgentPeerSignature.swift Integrations/AgentBridge/main.swift \
//       -o build/codebasic-tts-agent-bridge
//   codesign --force --options runtime --identifier com.codebasic.tts.agent-bridge \
//       --sign "<the user-selected signing identity>" build/codebasic-tts-agent-bridge
//
// Required environment (both non-secret, both mandatory, no defaults, no fallbacks):
//   CODEBASIC_TTS_APP_BUNDLE_ID   exact expected signing identifier of the app
//   CODEBASIC_TTS_SIGNER_SHA1     40 hex digits, SHA-1 of the trusted public leaf certificate
//
// Behaviour: no listener, no network, no files other than lstat/open of the fixed private socket
// directory, no logs, no stderr output, no app launch, no speech, no credentials. Every command uses a
// fresh connection to ai.sock or ad.sock, and the live peer (UID + kernel audit token + exact identifier +
// pinned leaf certificate) is verified BEFORE a single request byte is written.
//
// Draft statuses accepted from the app (must match the app slice; anything else becomes unconfirmed):
//   accepted, denied, not_paired, rate_limited, too_large, stale_revision, busy

import Darwin
import Dispatch

// MARK: - Strict JSON (rejects duplicate keys, invalid UTF-8, lone surrogates, deep nesting)

enum JSON: Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(String(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { first, _ in first }))
    }
}

struct JSONParser {
    let b: [UInt8]
    var i = 0

    static func parse(_ bytes: [UInt8]) -> JSON? {
        var p = JSONParser(b: bytes)
        p.ws()
        guard let v = p.value(0) else { return nil }
        p.ws()
        return p.i == p.b.count ? v : nil
    }

    mutating func ws() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
    }

    mutating func lit(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard i + u.count <= b.count, b[i..<(i + u.count)].elementsEqual(u) else { return false }
        i += u.count
        return true
    }

    mutating func value(_ depth: Int) -> JSON? {
        guard depth < 32, i < b.count else { return nil }
        switch b[i] {
        case 0x7B:
            i += 1
            var o = [String: JSON]()
            ws()
            if i < b.count, b[i] == 0x7D { i += 1; return .object(o) }
            while true {
                ws()
                guard let k = string() else { return nil }
                ws()
                guard i < b.count, b[i] == 0x3A else { return nil }
                i += 1
                ws()
                guard let v = value(depth + 1), o[k] == nil else { return nil }
                o[k] = v
                ws()
                guard i < b.count else { return nil }
                if b[i] == 0x2C { i += 1; continue }
                if b[i] == 0x7D { i += 1; return .object(o) }
                return nil
            }
        case 0x5B:
            i += 1
            var a = [JSON]()
            ws()
            if i < b.count, b[i] == 0x5D { i += 1; return .array(a) }
            while true {
                ws()
                guard let v = value(depth + 1) else { return nil }
                a.append(v)
                ws()
                guard i < b.count else { return nil }
                if b[i] == 0x2C { i += 1; continue }
                if b[i] == 0x5D { i += 1; return .array(a) }
                return nil
            }
        case 0x22:
            guard let s = string() else { return nil }
            return .string(s)
        case 0x74: return lit("true") ? .bool(true) : nil
        case 0x66: return lit("false") ? .bool(false) : nil
        case 0x6E: return lit("null") ? .null : nil
        default: return number()
        }
    }

    @discardableResult
    mutating func digits() -> Int {
        let start = i
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
        return i - start
    }

    mutating func number() -> JSON? {
        let start = i
        if i < b.count, b[i] == 0x2D { i += 1 }
        guard i < b.count, b[i] >= 0x30, b[i] <= 0x39 else { return nil }
        if b[i] == 0x30 { i += 1 } else { digits() }
        if i < b.count, b[i] == 0x2E {
            i += 1
            guard digits() > 0 else { return nil }
        }
        if i < b.count, b[i] == 0x65 || b[i] == 0x45 {
            i += 1
            if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
            guard digits() > 0 else { return nil }
        }
        guard i - start <= 64 else { return nil }
        return .number(String(decoding: b[start..<i], as: UTF8.self))
    }

    mutating func hex4() -> UInt32? {
        guard i + 4 <= b.count else { return nil }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = b[i]
            i += 1
            switch c {
            case 0x30...0x39: v = (v << 4) | UInt32(c - 0x30)
            case 0x41...0x46: v = (v << 4) | UInt32(c - 0x37)
            case 0x61...0x66: v = (v << 4) | UInt32(c - 0x57)
            default: return nil
            }
        }
        return v
    }

    mutating func string() -> String? {
        guard i < b.count, b[i] == 0x22 else { return nil }
        i += 1
        var out = [UInt8]()
        while i < b.count {
            let c = b[i]
            i += 1
            if c == 0x22 {
                let s = String(decoding: out, as: UTF8.self)
                return Array(s.utf8) == out ? s : nil
            }
            if c < 0x20 { return nil }
            if c != 0x5C { out.append(c); continue }
            guard i < b.count else { return nil }
            let e = b[i]
            i += 1
            switch e {
            case 0x22, 0x5C, 0x2F: out.append(e)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                guard var u = hex4() else { return nil }
                if u >= 0xD800, u <= 0xDBFF {
                    guard i + 1 < b.count, b[i] == 0x5C, b[i + 1] == 0x75 else { return nil }
                    i += 2
                    guard let lo = hex4(), lo >= 0xDC00, lo <= 0xDFFF else { return nil }
                    u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
                }
                guard let scalar = Unicode.Scalar(u) else { return nil }
                out += Array(String(Character(scalar)).utf8)
            default: return nil
            }
        }
        return nil
    }
}

func encodeString(_ s: String, into out: inout [UInt8]) {
    let hex = Array("0123456789abcdef".utf8)
    out.append(0x22)
    for c in s.utf8 {
        if c == 0x22 || c == 0x5C {
            out.append(0x5C)
            out.append(c)
        } else if c < 0x20 || c == 0x7F {
            out += [0x5C, 0x75, 0x30, 0x30, hex[Int(c >> 4)], hex[Int(c & 15)]]
        } else {
            out.append(c)
        }
    }
    out.append(0x22)
}

func encode(_ value: JSON, into out: inout [UInt8]) {
    switch value {
    case .null: out += Array("null".utf8)
    case .bool(let flag): out += Array((flag ? "true" : "false").utf8)
    case .number(let text): out += Array(text.utf8)
    case .string(let s): encodeString(s, into: &out)
    case .array(let a):
        out.append(0x5B)
        for (n, v) in a.enumerated() {
            if n > 0 { out.append(0x2C) }
            encode(v, into: &out)
        }
        out.append(0x5D)
    case .object(let o):
        out.append(0x7B)
        for (n, k) in o.keys.sorted().enumerated() {
            if n > 0 { out.append(0x2C) }
            encodeString(k, into: &out)
            out.append(0x3A)
            if let v = o[k] { encode(v, into: &out) }
        }
        out.append(0x7D)
    }
}

// MARK: - Configuration and limits

struct BridgeConfig {
    let appIdentifier: String
    let signerSHA1: String
}

func environmentValue(_ name: String) -> String? {
    guard let raw = getenv(name) else { return nil }
    return String(cString: raw)
}

func loadConfig() -> BridgeConfig? {
    guard let identifier = environmentValue("CODEBASIC_TTS_APP_BUNDLE_ID"),
          AgentPeerSignature.isValidIdentifier(identifier),
          identifier != AgentPeerSignature.bridgeIdentifier,
          let rawPin = environmentValue("CODEBASIC_TTS_SIGNER_SHA1"),
          let pin = AgentPeerSignature.normalizedSHA1(rawPin) else { return nil }
    return BridgeConfig(appIdentifier: identifier, signerSHA1: pin)
}

let maxFrameBytes = 102_400
let maxTextBytes = 8192
let maxStdinLineBytes = 262_144
let exchangeTimeoutNanos: UInt64 = 10_000_000_000
let helperPID = getpid()
let config = loadConfig()
let knownDraftStatuses: Set<String> = ["accepted", "duplicate", "conflict", "denied", "not_paired", "rate_limited", "too_large", "stale_revision", "busy"]

// MARK: - Native socket exchange

enum Exchange {
    case unavailable            // provably nothing was transmitted
    case unconfirmed            // bytes may have left; outcome unknown
    case frame([UInt8])
}

func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func waitFD(_ fd: Int32, _ events: Int32, _ deadline: UInt64) -> Bool {
    while true {
        let now = nowNanos()
        guard now < deadline else { return false }
        var p = pollfd(fd: fd, events: Int16(events), revents: 0)
        let ms = Int32(min((deadline - now) / 1_000_000 + 1, 60_000))
        let r = poll(&p, 1, ms)
        if r > 0 { return (Int32(p.revents) & POLLNVAL) == 0 }
        if r < 0 && errno != EINTR { return false }
    }
}

func matches(_ st: stat, type: mode_t, mode: mode_t, uid: uid_t) -> Bool {
    (st.st_mode & S_IFMT) == type && (st.st_mode & 0o7777) == mode && st.st_uid == uid
}

func exchange(_ socketName: String, _ payload: [UInt8], _ cfg: BridgeConfig) -> Exchange {
    guard !payload.isEmpty, payload.count <= maxFrameBytes else { return .unavailable }
    let uid = geteuid()
    guard getuid() == uid else { return .unavailable }
    let deadline = nowNanos() + exchangeTimeoutNanos
    let directory = "/private/tmp/codebasic-tts-mcp-" + String(uid)
    let path = directory + "/" + socketName

    // Private directory: real directory (no symlink), ours, exactly 0700; socket: ours, exactly 0600.
    var ls = stat()
    guard lstat(directory, &ls) == 0, matches(ls, type: S_IFDIR, mode: 0o700, uid: uid) else { return .unavailable }
    let dfd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard dfd >= 0 else { return .unavailable }
    defer { close(dfd) }
    var ds = stat()
    guard fstat(dfd, &ds) == 0, matches(ds, type: S_IFDIR, mode: 0o700, uid: uid),
          ds.st_dev == ls.st_dev, ds.st_ino == ls.st_ino else { return .unavailable }
    var ss = stat()
    guard fstatat(dfd, socketName, &ss, AT_SYMLINK_NOFOLLOW) == 0,
          matches(ss, type: S_IFSOCK, mode: 0o600, uid: uid) else { return .unavailable }

    var addr = sockaddr_un()
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return .unavailable }
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (n, c) in pathBytes.enumerated() { raw[n] = c }
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .unavailable }
    defer { close(fd) }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
        return .unavailable
    }
    var on: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        return .unavailable
    }

    let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if rc != 0 {
        let e = errno
        guard e == EINPROGRESS || e == EINTR, waitFD(fd, POLLOUT, deadline) else { return .unavailable }
        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen) == 0, soError == 0 else { return .unavailable }
    }

    // The security decision. Nothing has been written yet.
    guard AgentPeerSignature.verifyConnectedPeer(fd: fd, expectedUID: uid, identifier: cfg.appIdentifier,
                                                 leafSHA1: cfg.signerSHA1) != nil,
          nowNanos() < deadline else { return .unavailable }

    var sent = 0
    while sent < payload.count {
        let n = payload.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return send(fd, base + sent, raw.count - sent, 0)
        }
        let e = errno
        if n > 0 { sent += n; continue }
        if n < 0 && e == EINTR { continue }
        if n < 0 && (e == EAGAIN || e == EWOULDBLOCK) && waitFD(fd, POLLOUT, deadline) { continue }
        return sent == 0 ? .unavailable : .unconfirmed
    }
    guard shutdown(fd, SHUT_WR) == 0 else { return .unconfirmed }

    var response = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 16_384)
    let capacity = chunk.count
    // Set once the single LF has been read; the reply is only returned after EOF follows it.
    var terminated = false
    while true {
        let n = recv(fd, &chunk, capacity, 0)
        let e = errno
        if n > 0 {
            // Any byte after the LF, in this or a later read, invalidates the reply.
            guard !terminated else { return .unconfirmed }
            if let newline = chunk[0..<n].firstIndex(of: 0x0A) {
                guard newline == n - 1 else { return .unconfirmed }
                response += chunk[0..<newline]
                guard !response.isEmpty, response.count <= maxFrameBytes else { return .unconfirmed }
                terminated = true
                continue
            }
            response += chunk[0..<n]
            guard response.count <= maxFrameBytes else { return .unconfirmed }
            continue
        }
        if n == 0 { return terminated ? .frame(response) : .unconfirmed }
        if e == EINTR { continue }
        if (e == EAGAIN || e == EWOULDBLOCK) && waitFD(fd, POLLIN, deadline) { continue }
        return .unconfirmed
    }
}

// MARK: - Validation

func validText(_ s: String) -> Bool {
    let u = s.utf8
    guard u.count <= maxTextBytes, !u.contains(0) else { return false }
    return s.unicodeScalars.contains { !$0.properties.isWhitespace }
}

func validRevision(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard u.count >= 1, u.count <= 256 else { return false }
    return !u.contains { $0 < 0x20 || $0 == 0x7F }
}

func validIdempotencyKey(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard u.count >= 1, u.count <= 128 else { return false }
    return u.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
}

func validUUID(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard u.count == 36 else { return false }
    for (n, c) in u.enumerated() {
        if n == 8 || n == 13 || n == 18 || n == 23 {
            if c != 0x2D { return false }
        } else {
            switch c {
            case 0x30...0x39, 0x41...0x46, 0x61...0x66: break
            default: return false
            }
        }
    }
    return true
}

// MARK: - Tools

func toolResult(_ payload: JSON, isError: Bool) -> JSON {
    var out = [UInt8]()
    encode(payload, into: &out)
    let text = String(decoding: out, as: UTF8.self)
    return ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
}

func failure(_ status: String) -> JSON {
    let help = "Nothing is confirmed as delivered or played. Ask the app owner to check that the app is running and to pair local helper pid "
        + String(helperPID)
        + " in the app's agent pairing UI. This helper also requires CODEBASIC_TTS_APP_BUNDLE_ID and CODEBASIC_TTS_SIGNER_SHA1 to name the app identifier and its trusted signer certificate SHA-1. If the status is unconfirmed, retry only with the same idempotency_key."
    return toolResult(["status": .string(status), "helper_pid": .number(String(helperPID)), "help": .string(help)], isError: true)
}

func invalidArguments(_ help: String) -> JSON {
    toolResult(["status": "invalid_arguments", "help": .string(help)], isError: true)
}

func getInstructions(_ args: [String: JSON]) -> JSON {
    guard args.isEmpty else { return invalidArguments("get_tts_instructions takes no arguments.") }
    var request = [UInt8]()
    encode(["operation": "get"], into: &request)
    request.append(0x0A)
    guard let cfg = config,
          case .frame(let frame) = exchange("ai.sock", request, cfg),
          case .object(let o)? = JSONParser.parse(frame),
          o.count == 4,
          o["schema_version"] == .number("2"),
          case .string(let profile)? = o["profile_id"], validUUID(profile),
          case .string(let revision)? = o["revision"], validRevision(revision),
          case .string(let instructions)? = o["instructions"],
          instructions.utf8.count <= maxTextBytes, !instructions.utf8.contains(0)
    else { return failure("unavailable") }
    return toolResult(.object(o), isError: false)
}

func submitDraft(_ args: [String: JSON]) -> JSON {
    let allowed: Set<String> = ["revision", "display_text", "speech_text", "idempotency_key"]
    guard Set(args.keys).isSubset(of: allowed) else {
        return invalidArguments("Only revision, display_text, speech_text and idempotency_key are allowed.")
    }
    guard case .string(let revision)? = args["revision"], validRevision(revision) else {
        return invalidArguments("revision must be the exact revision string returned by get_tts_instructions.")
    }
    guard case .string(let display)? = args["display_text"], validText(display) else {
        return invalidArguments("display_text must be a non-blank string of at most 8192 UTF-8 bytes without NUL.")
    }
    guard case .string(let key)? = args["idempotency_key"], validIdempotencyKey(key) else {
        return invalidArguments("idempotency_key must be 1 to 128 printable ASCII characters without spaces.")
    }
    var wire: [String: JSON] = ["revision": .string(revision), "display_text": .string(display), "idempotency_key": .string(key)]
    if let rawSpeech = args["speech_text"] {
        guard case .string(let speech) = rawSpeech, validText(speech) else {
            return invalidArguments("speech_text, when present, must be a non-blank string of at most 8192 UTF-8 bytes without NUL.")
        }
        wire["speech_text"] = .string(speech)
    }
    var request = [UInt8]()
    encode(.object(wire), into: &request)
    request.append(0x0A)
    guard request.count <= maxFrameBytes, let cfg = config else { return failure("unavailable") }
    switch exchange("ad.sock", request, cfg) {
    case .unavailable:
        return failure("unavailable")
    case .unconfirmed:
        return failure("unconfirmed")
    case .frame(let frame):
        guard case .object(let o)? = JSONParser.parse(frame), o.count == 1,
              case .string(let status)? = o["status"], knownDraftStatuses.contains(status) else {
            return failure("unconfirmed")
        }
        if status == "accepted" { return toolResult(["status": "accepted"], isError: false) }
        // The same content was already queued earlier: idempotent success, no new draft was created.
        if status == "duplicate" { return toolResult(["status": "duplicate"], isError: false) }
        return failure(status)
    }
}

let getToolSchema: JSON = ["type": "object", "properties": [:], "additionalProperties": false]
let draftProperties: JSON = [
    "revision": ["type": "string", "minLength": 1, "maxLength": 256,
                 "description": "Exact revision returned by get_tts_instructions."],
    "display_text": ["type": "string", "minLength": 1, "maxLength": 8192,
                     "description": "Text to display. Non-blank, at most 8192 UTF-8 bytes."],
    "speech_text": ["type": "string", "minLength": 1, "maxLength": 8192,
                    "description": "Optional text to speak instead. Non-blank, at most 8192 UTF-8 bytes."],
    "idempotency_key": ["type": "string", "minLength": 1, "maxLength": 128, "pattern": "^[!-~]{1,128}$",
                        "description": "Printable ASCII key; reuse the same key when retrying the same draft."],
]
let draftToolSchema: JSON = [
    "type": "object", "properties": draftProperties,
    "required": ["revision", "display_text", "idempotency_key"], "additionalProperties": false,
]
let getTool: JSON = [
    "name": "get_tts_instructions",
    "description": "Fetch the current TTS explanation instructions and their revision from the local app.",
    "inputSchema": getToolSchema,
]
let draftTool: JSON = [
    "name": "submit_explanation_draft",
    "description": "Submit an explanation draft for the given instructions revision to the local app. A result of accepted means only that the app accepted the draft.",
    "inputSchema": draftToolSchema,
]
let toolList: JSON = ["tools": [getTool, draftTool]]

// MARK: - MCP over STDIO (newline-delimited JSON-RPC, stdout only)

func emit(_ value: JSON) {
    var out = [UInt8]()
    encode(value, into: &out)
    out.append(0x0A)
    var offset = 0
    while offset < out.count {
        let n = out.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(STDOUT_FILENO, base + offset, raw.count - offset)
        }
        let e = errno
        if n > 0 { offset += n; continue }
        if n < 0 && e == EINTR { continue }
        if n < 0 && e == EAGAIN {
            var p = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
            _ = poll(&p, 1, 1000)
            continue
        }
        exit(1)
    }
}

func reply(_ id: JSON, result: JSON) {
    emit(["jsonrpc": "2.0", "id": id, "result": result])
}

func replyError(_ id: JSON, _ code: Int, _ message: String) {
    emit(["jsonrpc": "2.0", "id": id, "error": ["code": .number(String(code)), "message": .string(message)]])
}

func handle(_ line: [UInt8]) {
    guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { return }
    guard let message = JSONParser.parse(line) else { replyError(.null, -32700, "Parse error"); return }
    guard case .object(let o) = message else { replyError(.null, -32600, "Invalid Request"); return }
    var requestID: JSON?
    if let raw = o["id"] {
        switch raw {
        case .string, .number: requestID = raw
        default: replyError(.null, -32600, "Invalid Request"); return
        }
    }
    guard case .string(let method)? = o["method"] else {
        // Responses from the host are ignored; anything else without a method is an invalid request.
        if o["result"] == nil && o["error"] == nil { replyError(requestID ?? .null, -32600, "Invalid Request") }
        return
    }
    // Notifications (including malformed ones) never produce output.
    guard let id = requestID else { return }
    guard o["jsonrpc"] == .string("2.0") else { replyError(id, -32600, "Invalid Request"); return }
    var params = [String: JSON]()
    if let rawParams = o["params"] {
        guard case .object(let d) = rawParams else { replyError(id, -32602, "Invalid params"); return }
        params = d
    }
    switch method {
    case "initialize":
        let supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
        var version = supported[0]
        if case .string(let requested)? = params["protocolVersion"], supported.contains(requested) { version = requested }
        reply(id, result: [
            "protocolVersion": .string(version),
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "codebasic-tts-agent-bridge", "version": "1.0.0"],
        ])
    case "ping":
        reply(id, result: [:])
    case "tools/list":
        reply(id, result: toolList)
    case "tools/call":
        guard case .string(let name)? = params["name"] else { replyError(id, -32602, "Invalid params"); return }
        var args = [String: JSON]()
        if let rawArgs = params["arguments"] {
            guard case .object(let d) = rawArgs else { replyError(id, -32602, "Invalid params"); return }
            args = d
        }
        switch name {
        case "get_tts_instructions": reply(id, result: getInstructions(args))
        case "submit_explanation_draft": reply(id, result: submitDraft(args))
        default: replyError(id, -32602, "Unknown tool")
        }
    default:
        replyError(id, -32601, "Method not found")
    }
}

_ = signal(SIGPIPE, SIG_IGN)

var lineBuffer = [UInt8]()
var lineOverflow = false
var stdinChunk = [UInt8](repeating: 0, count: 65_536)
let stdinCapacity = stdinChunk.count
readLoop: while true {
    let n = read(STDIN_FILENO, &stdinChunk, stdinCapacity)
    if n < 0 {
        if errno == EINTR { continue }
        break readLoop
    }
    if n == 0 { break readLoop }
    for byte in stdinChunk[0..<n] {
        if byte == 0x0A {
            if lineOverflow {
                replyError(.null, -32700, "Parse error")
            } else {
                handle(lineBuffer)
            }
            lineOverflow = false
            lineBuffer.removeAll(keepingCapacity: true)
        } else if !lineOverflow {
            lineBuffer.append(byte)
            if lineBuffer.count > maxStdinLineBytes {
                lineOverflow = true
                lineBuffer.removeAll(keepingCapacity: true)
            }
        }
    }
}
if !lineOverflow && !lineBuffer.isEmpty { handle(lineBuffer) }
exit(0)
