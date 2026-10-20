import Foundation

@main struct ConnectionTests {
    @MainActor static func main() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tts-rpc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let client = try CodexPlanRPC(executable: fixture, home: home)
        defer { client.stop() }
        try await client.initialize()
        let result = try await client.request("echo", ["text": "한국어\nstream"])
        precondition(result["text"] as? String == "한국어\nstream")
        print("✓ RPC handles fragmented JSON and Unicode")
        do {
            _ = try await client.requirePlan()
            fatalError("API authentication must not count as a plan")
        } catch { print("✓ API authentication rejected for plan mode") }
        do {
            _ = try await client.request("unsupported")
            fatalError("RPC errors must surface")
        } catch { print("✓ RPC error propagated") }
        client.stop()
        do {
            _ = try await client.request("echo")
            fatalError("Closed connection must fail")
        } catch { print("✓ Closed connection fails immediately") }
        try AntigravityPlan.prepare(home: home)
        let env = AntigravityPlan.environment(home: home)
        precondition(env["GEMINI_API_KEY"] == nil && env["GOOGLE_API_KEY"] == nil && env["GEMINI_CLI_HOME"] == nil)
        let fixtureAGY = fixture.deletingLastPathComponent().appendingPathComponent("fake-agy.py")
        let models = try await AntigravityPlan.models(executable: fixtureAGY, home: home)
        precondition(models == ["gemini-test-high"])
        var generated = ""
        for try await chunk in AntigravityPlan.stream(prompt: "한국어 @/tmp/file", model: "auto", images: [], executable: fixtureAGY, home: home) {
            generated += chunk
            try Data().write(to: home.appendingPathComponent("first-delta-seen"))
        }
        precondition(generated == "한국어 @/tmp/file")
        for status in ["ERROR", "CANCELED", "INTERRUPTED", "WAITING", "RUNNING", "INVALID"] {
            let data = try JSONSerialization.data(withJSONObject: ["event": "result", "result": ["status": status, "response": "partial"]])
            do { _ = try AntigravityPlan.decodeResponse(data, exitCode: 0); fatalError("Failed result accepted") } catch { }
        }
        do { _ = try AntigravityPlan.decodeResponse(Data("{}".utf8), exitCode: 0); fatalError("Missing result accepted") } catch { }
        do {
            for try await _ in AntigravityPlan.stream(prompt: "image", model: "auto", images: [Data()], executable: fixtureAGY, home: home) { }
            fatalError("Unsupported image silently accepted")
        } catch { }
        print("✓ First delta delivered before CLI exit; final response not duplicated")
        print("✓ Antigravity model lookup and structured stdin subprocess round trip")
        print("✓ API/credit fallback disabled; non-success responses and images rejected")
        let conversation = ExplanationConversation(system: "current test rules", messages: [
            ConversationMessage(role: .user, text: "old test input"),
            ConversationMessage(role: .assistant, text: "old test answer"),
            ConversationMessage(role: .user, text: "current test input")])
        let codexFixture = fixture.deletingLastPathComponent().appendingPathComponent("fake-codex-conversation.py")
        var codexOutput = ""
        for try await text in CodexPlan.stream(prompt: "unused", model: "fixture", images: [], reasoning: .medium,
                                               conversation: conversation, executable: codexFixture, home: home) {
            codexOutput += text
        }
        precondition(codexOutput == "fixture answer")
        let records = try String(contentsOf: home.appendingPathComponent("conversation-requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        precondition(records.compactMap { $0["method"] as? String } == ["initialize", "initialized", "account/read", "thread/start", "thread/injectItems", "turn/start"])
        var agyTranscript = ""
        for try await text in AntigravityPlan.stream(prompt: "unused", model: "auto", images: [], executable: fixtureAGY,
                                                     home: home, conversation: conversation) { agyTranscript += text }
        precondition(agyTranscript == conversation.transcript)
        let system = CodeExplanation.conversationSystem("current custom instruction")
        precondition(system.hasPrefix("current custom instruction") && system.contains("현재 지시는 과거 지시보다 우선"))
        let currentInput = CodeExplanation.conversationInput("fixture code", hint: "latest hint")
        precondition(currentInput.contains("fixture code") && currentInput.contains("latest hint") && !currentInput.contains("old test answer"))
        precondition(CodeExplanation.continuePrompt(previous: "previous code", current: "current code").contains("[이전 코드"))
        precondition(!normalizationPrompt("script rule", "script source").contains("old test answer"))
        print("✓ Codex new ephemeral thread receives explicit native user/assistant history before current input")
        print("✓ Antigravity transcript preserves roles; current instructions win; legacy continuation/script paths unchanged")
        print("Connection tests passed.")
    }
}
