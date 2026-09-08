import AppKit
import Foundation

/// Official Antigravity account transport. The CLI owns Keychain authentication.
enum AntigravityPlan {
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codebasic TTS/antigravity-plan")
    }
    static func environment(home: URL) -> [String: String] {
        ["HOME": home.path,
         "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
         "TMPDIR": NSTemporaryDirectory(), "TERM": "xterm-256color"]
    }
    static func prepare(home: URL) throws {
        let config = home.appendingPathComponent(".gemini/antigravity-cli")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // No modelProvider override: the official CLI uses account authentication.
        // Never import user plugins, MCP servers, or the retired Gemini OAuth file.
        let settings: [String: Any] = [
            "toolPermission": "strict", "allowNonWorkspaceAccess": false,
            "useG1Credits": false, "enableTelemetry": false,
            "permissions": ["deny": ["read_file(*)", "write_file(*)", "read_url(*)",
                                      "execute_url(*)", "command(*)", "unsandboxed(*)", "mcp(*)"]]
        ]
        try JSONSerialization.data(withJSONObject: settings).write(to: config.appendingPathComponent("settings.json"), options: .atomic)
    }
    @MainActor static func login() throws {
        guard let executable else { throw connectionError("Antigravity CLI를 설치한 뒤 다시 시도하세요.") }
        try prepare(home: home)
        let script = home.appendingPathComponent("Google 로그인.command")
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let env = environment(home: home).sorted { $0.key < $1.key }.map { "\($0.key)=\(quote($0.value))" }.joined(separator: " ")
        let contents = "#!/bin/sh\nprintf '\\033[2J\\033[3J\\033[H\\033]0;Google 계정 연결\\007'\ncd \(quote(home.path)) || exit 1\nexec /usr/bin/env -i \(env) \(quote(executable.path))\n"
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else { throw connectionError("로그인 터미널을 열지 못했습니다.") }
    }
    @MainActor static func run(arguments: [String], input: Data = Data(), executable: URL? = AntigravityPlan.executable,
                               home: URL = AntigravityPlan.home, timeout: TimeInterval = 180, onOutput: ((Data) throws -> Void)? = nil) async throws -> (Data, Int32) {
        guard let executable else { throw connectionError("Antigravity CLI(agy) 설치가 필요합니다.") }
        try prepare(home: home)
        let process = Process()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("tts-agy-\(UUID())")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { if process.isRunning { process.terminate() }; try? FileManager.default.removeItem(at: work) }
        let inputURL = work.appendingPathComponent("input")
        let outputURL = work.appendingPathComponent("output")
        try input.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: inputURL)
        let writer = try FileHandle(forWritingTo: outputURL)
        let outputReader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close(); try? writer.close(); try? outputReader.close() }
        process.executableURL = executable
        process.currentDirectoryURL = work
        process.environment = environment(home: home)
        process.arguments = arguments
        process.standardInput = reader
        process.standardOutput = writer
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            try Task.checkCancellation()
            if let onOutput { try onOutput(outputReader.readDataToEndOfFile()) }
            guard Date() < deadline else { throw connectionError("Antigravity CLI 응답 시간이 초과되었습니다.") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        if let onOutput { try onOutput(outputReader.readDataToEndOfFile()) }
        return (try Data(contentsOf: outputURL), process.terminationStatus)
    }
    static func decodeModels(_ data: Data, exitCode: Int32) throws -> [String] {
        guard exitCode == 0 else { throw connectionError("Antigravity 모델 조회 실패. Google로 로그인한 뒤 다시 확인하세요.") }
        let models = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            guard let slug = line.split(whereSeparator: { $0.isWhitespace }).first,
                  slug.range(of: "^[a-z0-9]+(?:-[a-z0-9.]+)+$", options: .regularExpression) != nil else { return nil }
            return String(slug)
        }
        guard !models.isEmpty else { throw connectionError("Antigravity CLI에서 사용 가능한 모델을 조회하지 못했습니다.") }
        return Array(NSOrderedSet(array: models)) as? [String] ?? models
    }
    @MainActor static func models(executable: URL? = AntigravityPlan.executable, home: URL = AntigravityPlan.home) async throws -> [String] {
        let (data, code) = try await run(arguments: ["models"], executable: executable, home: home, timeout: 30)
        return try decodeModels(data, exitCode: code)
    }
    static func inputData(_ prompt: String) throws -> Data {
        // Keep text out of argv and prevent CLI @path expansion or slash/skill interpretation.
        let json = try JSONSerialization.data(withJSONObject: prompt, options: [.fragmentsAllowed])
        let encoded = String(decoding: json, as: UTF8.self).replacingOccurrences(of: "@", with: "\\u0040")
        let content = "Decode the following JSON string and follow its text transformation instructions. Return only the requested output. Do not use tools.\n" + encoded
        var data = try JSONSerialization.data(withJSONObject: ["event": "user", "message": ["content": content]])
        data.append(10)
        return data
    }
    static func decodeResponse(_ data: Data, exitCode: Int32) throws -> String {
        guard exitCode == 0 else { throw connectionError("Antigravity 요청 실패 (종료 코드 \(exitCode)). Google 로그인과 구독 한도를 확인하세요. API로 전환하지 않았습니다.") }
        let events = try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] ?? [:] }
        let results = events.filter { $0["event"] as? String == "result" }
        guard results.count == 1, let result = results.first?["result"] as? [String: Any],
              result["status"] as? String == "SUCCESS", result["error"] == nil,
              let response = result["response"] as? String, !response.isEmpty else {
            throw connectionError("Antigravity CLI가 성공한 응답을 반환하지 않았습니다.")
        }
        return response
    }
    static func stream(prompt: String, model: String, images: [Data], executable: URL? = AntigravityPlan.executable,
                       home: URL = AntigravityPlan.home) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    // The documented stream input protocol supports text blocks only.
                    guard images.isEmpty else { throw connectionError("Antigravity CLI의 자동 연결은 텍스트 입력만 지원합니다. 이미지 인식에는 API 키 연결을 선택하세요.") }
                    var args = ["--input-format", "stream-json", "--output-format", "stream-json",
                                "--disable-slash-commands", "--print-timeout", "3m"]
                    // Migrate the former Gemini auto sentinel to the CLI's default selection.
                    if !model.isEmpty && model != "auto" { args += ["--model", model] }
                    var decoder = AntigravityDeltaDecoder()
                    let (data, code) = try await run(arguments: args, input: inputData(prompt), executable: executable, home: home) { bytes in
                        for delta in try decoder.append(bytes) { continuation.yield(delta) }
                    }
                    let response = try decodeResponse(data, exitCode: code)
                    // Result repeats the full answer. Emit only text not already delivered.
                    guard response.hasPrefix(decoder.emitted) else {
                        throw connectionError("Antigravity의 스트림과 완료 응답이 일치하지 않습니다. 다시 시도하세요.")
                    }
                    let remainder = String(response.dropFirst(decoder.emitted.count))
                    if !remainder.isEmpty { continuation.yield(remainder) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Draft-only connection state. Checking or canceling never saves endpoint settings.
@MainActor final class AntigravityLogin: ObservableObject {
    @Published private(set) var status = "Google 계정 연결을 확인하세요."
    @Published private(set) var models: [String] = []
    @Published private(set) var busy = false
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        busy = false
        status = models.isEmpty ? "Google 계정 연결을 확인하세요." : "Google 계정 연결됨"
    }
    func check(openLoginIfNeeded: Bool = false) {
        cancel()
        models = []
        busy = true
        status = "Google 계정 확인 중…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                do {
                    let found = try await AntigravityPlan.models()
                    try Task.checkCancellation()
                    self.models = found
                    self.status = "Google 계정 연결됨 · 모델 \(found.count)개"
                    self.busy = false
                    return
                } catch {
                    try Task.checkCancellation()
                    guard openLoginIfNeeded else { throw error }
                }
                try AntigravityPlan.login()
                self.status = "열린 창에서 로그인하세요. 완료되면 자동으로 연결됩니다."
                let deadline = Date().addingTimeInterval(180)
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    do {
                        let found = try await AntigravityPlan.models()
                        try Task.checkCancellation()
                        self.models = found
                        self.status = "Google 계정 연결됨 · 로그인 터미널은 닫아도 됩니다."
                        self.busy = false
                        return
                    } catch { try Task.checkCancellation() }
                }
                self.status = "로그인 확인 시간이 지났습니다. 완료 후 다시 확인하세요."
                self.busy = false
            } catch {
                guard !Task.isCancelled else { return }
                self.status = error.localizedDescription
                self.busy = false
            }
        }
    }
}

/// Buffer bytes, not characters: a CLI write can split UTF-8 or a JSON line anywhere.
struct AntigravityDeltaDecoder {
    private var pending = Data()
    private(set) var emitted = ""
    mutating func append(_ bytes: Data) throws -> [String] {
        pending.append(bytes)
        var deltas: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            defer { pending.removeSubrange(...newline) }
            if line.isEmpty { continue }
            let event = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] ?? [:]
            guard event["event"] as? String == "step_update",
                  let step = event["step_update"] as? [String: Any],
                  step["step_type"] as? String == "agent_response",
                  let delta = step["text_delta"] as? String, !delta.isEmpty else { continue }
            emitted += delta
            deltas.append(delta)
        }
        return deltas
    }
}
