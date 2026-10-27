import Foundation
import Combine
import AppKit

func connectionError(_ message: String) -> NSError {
    NSError(domain: "ServiceConnection", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Keep server error codes available for narrow protocol compatibility decisions,
/// while presenting the same server message in the UI.
struct CodexRPCError: LocalizedError, CustomNSError {
    let code: Int
    let message: String
    static var errorDomain: String { "CodexRPC" }
    var errorCode: Int { code }
    var errorDescription: String? { message }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }

    func isUnsupportedMethod(_ method: String) -> Bool {
        code == -32601 || (code == -32600 && message.contains("unknown variant `\(method)`"))
    }
}

/// Owns an official app-server process. Tokens stay in Codex's own auth storage.
/// A dedicated home avoids importing the user's project tools, MCP servers or API configuration.
@MainActor
final class CodexPlanRPC {
    private let diagnosticID = MemoryDiagnostics.begin("codexRPC.instance")
    deinit { MemoryDiagnostics.end(diagnosticID) }
    private func updateMemoryMetrics() {
        MemoryDiagnostics.update(diagnosticID, values: ["rpcBufferBytes": buffer.count, "rpcPending": pending.count])
    }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data() { didSet { updateMemoryMetrics() } }
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:] { didSet { updateMemoryMetrics() } }
    var notification: ((String, [String: Any]) -> Void)?
    var disconnected: (() -> Void)?
    private var closed = false

    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    init(executable suppliedExecutable: URL? = nil, home suppliedHome: URL? = nil) throws {
        guard let executable = suppliedExecutable ?? Self.executable else { throw connectionError("Codex CLI가 필요합니다. 설치 안내를 확인하세요.") }
        let home = suppliedHome ?? URL(fileURLWithPath: Secrets.appSupportDir).appendingPathComponent("codex-plan", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://", "-c", "model_provider=\"openai\"",
                             "-c", "features.shell_tool=false", "-c", "features.apply_patch_freeform=false",
                             "-c", "features.code_mode=false", "-c", "web_search=\"disabled\""]
        // Minimal environment: no inherited API credentials or provider overrides.
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "CODEX_HOME": home.path, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                               "TMPDIR": NSTemporaryDirectory()]
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                let activityID = MemoryDiagnostics.begin("CodexPlan.rpcRead")
                defer { MemoryDiagnostics.end(activityID) }
                guard let self else { return }
                if data.isEmpty { self.stop(); return }
                self.receive(data)
            }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.stop() } }
        try process.run()
        MemoryDiagnostics.sample("codex.process.started", details: "childPID=\(process.processIdentifier)")
    }

    func initialize(experimental: Bool = false) async throws {
        _ = try await request("initialize", ["clientInfo": ["name": "codebasic_tts", "version": "1.0"],
                                             "capabilities": ["experimentalApi": experimental]])
        try send(["method": "initialized", "params": [:]])
    }

    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard !closed else { throw connectionError("연결이 종료되었습니다.") }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try send(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { [weak self] in
                let activityID = MemoryDiagnostics.begin("CodexPlan.rpcDeadline")
                defer { MemoryDiagnostics.end(activityID) }
                try? await Task.sleep(for: .seconds(30))
                self?.pending.removeValue(forKey: id)?.resume(throwing: connectionError("연결 응답 시간이 초과되었습니다."))
            }
        }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<end)
            buffer.removeSubrange(buffer.startIndex...end)
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let method = object["method"] as? String {
                if let id = object["id"] {
                    // This text-only integration never approves tool use or external actions.
                    try? send(["id": id, "error": ["code": -32601, "message": "Tools are unavailable in this client"]])
                } else { notification?(method, object["params"] as? [String: Any] ?? [:]) }
            } else if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                if let error = object["error"] as? [String: Any] {
                    continuation.resume(throwing: CodexRPCError(code: error["code"] as? Int ?? 0,
                                                               message: error["message"] as? String ?? "연결 오류"))
                } else { continuation.resume(returning: object["result"] as? [String: Any] ?? [:]) }
            }
        }
    }

    func requirePlan() async throws -> [String: Any] {
        let result = try await request("account/read", ["refreshToken": false])
        guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
            throw connectionError("기존 플랜을 사용하려면 설정에서 ChatGPT로 로그인하세요.")
        }
        return account
    }

    func stop() {
        guard !closed else { return }
        closed = true
        MemoryDiagnostics.sample("codex.stop.requested", details: "childPID=\(process.processIdentifier) running=\(process.isRunning)")
        notification = nil
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let requests = pending.values
        pending.removeAll()
        for continuation in requests { continuation.resume(throwing: connectionError("연결이 종료되었습니다.")) }
        disconnected?()
        disconnected = nil
    }
}

@MainActor
final class CodexPlanLogin: ObservableObject {
    @Published var status = "ChatGPT 구독으로 연결합니다."
    @Published var busy = false
    private var rpc: CodexPlanRPC?
    private var timeout: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?

    func login() {
        cancel()
        busy = true
        status = "로그인 준비 중…"
        loginTask = Task {
            let activityID = MemoryDiagnostics.begin("CodexPlan.login")
            defer { MemoryDiagnostics.end(activityID) }
            do {
                try Task.checkCancellation()
                let client = try CodexPlanRPC()
                rpc = client
                client.notification = { [weak self] method, params in
                    guard method == "account/login/completed" else { return }
                    self?.status = params["success"] as? Bool == true ? "로그인 완료 · 저장 및 연결 확인을 눌러 주세요." : "로그인 실패. 다시 시도하세요."
                    self?.busy = false
                    self?.timeout?.cancel()
                    client.stop()
                }
                try await client.initialize()
                try Task.checkCancellation()
                let result = try await client.request("account/login/start", ["type": "chatgpt"])
                try Task.checkCancellation()
                guard let raw = result["authUrl"] as? String, let url = URL(string: raw),
                      url.scheme == "https", let host = url.host,
                      host == "auth.openai.com" || host == "auth0.openai.com" || host == "chatgpt.com" else {
                    throw connectionError("공식 로그인 주소를 받지 못했습니다.")
                }
                guard NSWorkspace.shared.open(url) else { throw connectionError("로그인 브라우저를 열 수 없습니다.") }
                status = "브라우저에서 ChatGPT 로그인을 완료하세요."
                timeout = Task { [weak self] in
                    let activityID = MemoryDiagnostics.begin("CodexPlan.loginDeadline")
                    defer { MemoryDiagnostics.end(activityID) }
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.cancel()
                    self?.status = "로그인 시간이 초과되었습니다. 다시 시도하세요."
                }
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription; busy = false; rpc?.stop()
            }
        }
    }

    func cancel() { loginTask?.cancel(); loginTask = nil; timeout?.cancel(); timeout = nil; rpc?.stop(); rpc = nil; busy = false }
}

enum CodexPlan {
    @MainActor static func models() async throws -> [String] {
        let rpc = try CodexPlanRPC()
        defer { rpc.stop() }
        try await rpc.initialize()
        _ = try await rpc.requirePlan()
        var models: [String] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let result = try await rpc.request("model/list", params)
            models += (result["data"] as? [[String: Any]] ?? []).compactMap { $0["model"] as? String }
            cursor = result["nextCursor"] as? String
        } while cursor != nil
        return models
    }

    static func stream(prompt: String, model: String, images: [Data], reasoning: ReasoningLevel,
                       conversation: ExplanationConversation? = nil, executable: URL? = nil, home: URL? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let activityID = MemoryDiagnostics.begin("CodexPlan.generation")
                defer { MemoryDiagnostics.end(activityID) }
                var rpc: CodexPlanRPC?
                do {
                    try Task.checkCancellation()
                    let client = try CodexPlanRPC(executable: executable, home: home)
                    rpc = client
                    defer { client.stop() }
                    try await client.initialize(experimental: conversation != nil)
                    _ = try await client.requirePlan()
                    try Task.checkCancellation()
                    let thread = try await client.request("thread/start", ["ephemeral": true, "model": model,
                        "modelProvider": "openai", "sandbox": "read-only", "approvalPolicy": "never",
                        "baseInstructions": "Return only the requested text. Do not use tools, access files, or perform actions."
                            + (conversation.map { "\n\n" + $0.system } ?? ""),
                        "config": ["features.shell_tool": false, "features.apply_patch_freeform": false,
                                   "features.code_mode": false, "web_search": "disabled"]])
                    guard let info = thread["thread"] as? [String: Any], let id = info["id"] as? String else {
                        throw connectionError("생성 세션을 시작하지 못했습니다.")
                    }
                    var referenceHistory = false
                    if let conversation, !conversation.codexHistoryItems.isEmpty {
                        let method = "thread/inject_items"
                        do {
                            _ = try await client.request(method, ["threadId": id, "items": conversation.codexHistoryItems])
                        } catch let error as CodexRPCError where error.isUnsupportedMethod(method) {
                            // No turn has started. Only a missing injection method
                            // falls back to one ordinary input containing all context.
                            referenceHistory = true
                        }
                    }
                    let (events, eventContinuation) = AsyncStream<(String, [String: Any])>.makeStream()
                    client.notification = { eventContinuation.yield(($0, $1)) }
                    client.disconnected = { eventContinuation.finish() }
                    let current = conversation?.messages.last
                    var input: [[String: Any]] = [["type": "text", "text": current?.text ?? prompt, "text_elements": []]]
                    input += (current?.images ?? images).map { ["type": "image", "url": "data:image/png;base64,\($0.base64EncodedString())"] }
                    if referenceHistory, let conversation { input = conversation.codexReferenceInput }
                    var params: [String: Any] = ["threadId": id, "input": input]
                    if !reasoning.isProviderDefault { params["effort"] = reasoning.rawValue }
                    try Task.checkCancellation()
                    _ = try await client.request("turn/start", params)
                    let deadline = Task { @MainActor in
                        let activityID = MemoryDiagnostics.begin("CodexPlan.generationDeadline")
                        defer { MemoryDiagnostics.end(activityID) }
                        do { try await Task.sleep(for: .seconds(180)) } catch { return }
                        eventContinuation.finish()
                    }
                    defer { deadline.cancel() }
                    for await (method, params) in events {
                        try Task.checkCancellation()
                        if method == "item/agentMessage/delta", let delta = params["delta"] as? String { continuation.yield(delta) }
                        if method == "turn/completed" {
                            let turn = params["turn"] as? [String: Any] ?? [:]
                            guard turn["status"] as? String == "completed" else {
                                let error = turn["error"] as? [String: Any]
                                throw connectionError(error?["message"] as? String ?? "생성이 완료되지 않았습니다. API로 자동 전환하지 않습니다.")
                            }
                            continuation.finish(); return
                        }
                    }
                    throw connectionError("생성 연결이 종료되었거나 시간이 초과되었습니다.")
                } catch { rpc?.stop(); continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
