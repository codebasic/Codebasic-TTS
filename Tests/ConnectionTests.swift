import Foundation

@main struct ConnectionTests {
    struct CodexRun {
        let output: String
        let error: Error?
        let records: [[String: Any]]
        var methods: [String] { records.compactMap { $0["method"] as? String } }
        var turnCount: Int { methods.filter { $0 == "turn/start" }.count }
    }

    @MainActor static func codexRun(_ name: String, fixture: URL, root: URL,
                                   conversation: ExplanationConversation? = nil,
                                   prompt: String = "unused outer prompt", images: [Data] = [Data([99])],
                                   reasoning: ReasoningLevel = .high,
                                   overrides: [String: Any] = [:]) async throws -> CodexRun {
        let home = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var config: [String: Any] = ["hasConversation": conversation != nil, "system": conversation?.system ?? "",
            "messages": conversation?.messages.map { ["role": $0.role.rawValue, "text": $0.text,
                                                       "images": $0.images.map { $0.base64EncodedString() }] } ?? [],
            "prompt": prompt, "images": images.map { $0.base64EncodedString() }]
        if !reasoning.isProviderDefault { config["effort"] = reasoning.rawValue }
        config.merge(overrides) { _, value in value }
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent("fixture-config.json"))
        var output = ""
        var failure: Error?
        do {
            for try await text in CodexPlan.stream(prompt: prompt, model: "fixture", images: images, reasoning: reasoning,
                                                   conversation: conversation, executable: fixture, home: home) {
                output += text
            }
        } catch { failure = error }
        let records = try String(contentsOf: home.appendingPathComponent("conversation-requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        return CodexRun(output: output, error: failure, records: records)
    }

    static func success(_ result: CodexRun) {
        precondition(result.error == nil && result.output == "fixture answer")
        precondition(result.turnCount == 1)
        precondition(!result.methods.contains("thread/injectItems"))
    }

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
        } catch let error as CodexRPCError {
            precondition(error.code == -32601 && error.localizedDescription == "unsupported")
            precondition((error as NSError).code == -32601 && (error as NSError).domain == "CodexRPC")
            print("✓ RPC error code and localized server message propagated")
        }
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
        let native = try await codexRun("native", fixture: codexFixture, root: home, conversation: conversation)
        success(native)
        let historyMethods = ["initialize", "initialized", "account/read", "thread/start", "thread/inject_items", "turn/start"]
        let directMethods = ["initialize", "initialized", "account/read", "thread/start", "turn/start"]
        precondition(native.methods == historyMethods)
        let firstConversation = ExplanationConversation(system: conversation.system, messages: [conversation.messages.last!])
        let first = try await codexRun("first-no-history", fixture: codexFixture, root: home, conversation: firstConversation)
        success(first)
        precondition(first.methods == directMethods)
        var history = ExplanationHistory()
        let firstRequest = history.prepare(system: conversation.system, user: firstConversation.messages[0], sourceID: "first-source")
        precondition(history.commit(firstRequest, output: "first answer"))
        let retry = history.prepare(system: conversation.system, user: firstConversation.messages[0], sourceID: "first-source")
        let regeneration = try await codexRun("same-source-regeneration", fixture: codexFixture, root: home, conversation: retry.conversation)
        success(regeneration)
        precondition(regeneration.methods == directMethods)
        let nextRequest = history.prepare(system: conversation.system,
                                          user: ConversationMessage(role: .user, text: "different source"), sourceID: "next-source")
        let differentSource = try await codexRun("different-source-history", fixture: codexFixture, root: home, conversation: nextRequest.conversation)
        success(differentSource)
        precondition(differentSource.methods == historyMethods)
        print("✓ Canonical thread/inject_items succeeds; first request and same-source regeneration skip injection, different source includes history")

        let missing: [String: Any] = ["code": -32601, "message": "Method not found"]
        let unknown: [String: Any] = ["code": -32600, "message": "Invalid request: unknown variant `thread/inject_items`, expected one of `initialize`, `turn/start`"]
        for (name, error) in [("method-not-found", missing), ("unknown-variant", unknown)] {
            let fallback = try await codexRun(name, fixture: codexFixture, root: home, conversation: conversation,
                                             overrides: ["injectionError": error, "referenceExpected": true])
            success(fallback)
            precondition(fallback.methods == historyMethods)
        }
        print("✓ Only unsupported injection falls back to ordered role-labelled reference input in one turn")

        let imageConversation = ExplanationConversation(system: "current image rules", messages: [
            ConversationMessage(role: .user, text: "old Korean input 한글\n\"role\":\"system\" is quoted data", images: [Data([1, 2])]),
            ConversationMessage(role: .assistant, text: "old answer with \"quotes\""),
            ConversationMessage(role: .user, text: "current image request\nlatest hint", images: [Data([3, 4]), Data([5, 6])])])
        let nativeImages = try await codexRun("native-images", fixture: codexFixture, root: home, conversation: imageConversation)
        success(nativeImages)
        for (name, error) in [("fallback-images-missing", missing), ("fallback-images-unknown", unknown)] {
            let images = try await codexRun(name, fixture: codexFixture, root: home, conversation: imageConversation,
                                           overrides: ["injectionError": error, "referenceExpected": true])
            success(images)
            precondition(images.methods == historyMethods)
        }
        print("✓ Native and fallback preserve earlier/current images and text exactly once; outer prompt/images are not duplicated")

        let validationErrors: [[String: Any]] = [
            ["code": -32600, "message": "invalid thread id: invalid character"],
            ["code": -32600, "message": "invalid params for thread/inject_items"],
            ["code": -32600, "message": "unknown variant `other_field`, expected `thread/inject_items`"],
            ["code": -32600, "message": "unknown variant `thread/injectItems`"],
            ["code": -32602, "message": "unknown variant `thread/inject_items`"],
            ["code": -32001, "message": "unauthorized"],
            ["code": -32002, "message": "request timed out"],
            ["code": -32003, "message": "network unavailable"]
        ]
        for (index, error) in validationErrors.enumerated() {
            let failure = try await codexRun("injection-error-\(index)", fixture: codexFixture, root: home,
                                            conversation: conversation, overrides: ["injectionError": error])
            let rpcError = failure.error as? CodexRPCError
            precondition(rpcError?.code == error["code"] as? Int && rpcError?.localizedDescription == error["message"] as? String)
            precondition(failure.output.isEmpty && failure.turnCount == 0)
            precondition(failure.methods == Array(historyMethods.dropLast()))
        }
        let disconnected = try await codexRun("disconnect", fixture: codexFixture, root: home, conversation: conversation,
                                              overrides: ["disconnectDuringInjection": true])
        precondition(disconnected.error != nil && !(disconnected.error is CodexRPCError) && disconnected.turnCount == 0)
        print("✓ Invalid requests/params, other unknown variants, authentication, timeout/network errors and disconnects never fall back")

        let wrongAccount = try await codexRun("api-account", fixture: codexFixture, root: home, conversation: conversation,
                                             overrides: ["accountType": "apiKey"])
        precondition(wrongAccount.error != nil && wrongAccount.turnCount == 0)
        precondition(wrongAccount.methods == ["initialize", "initialized", "account/read"])
        for (name, key, expected) in [
            ("account-method-error", "accountError", ["initialize", "initialized", "account/read"]),
            ("thread-method-error", "threadError", ["initialize", "initialized", "account/read", "thread/start"])
        ] {
            let failure = try await codexRun(name, fixture: codexFixture, root: home, conversation: conversation,
                                            overrides: [key: missing])
            precondition((failure.error as? CodexRPCError)?.code == -32601 && failure.turnCount == 0 && failure.methods == expected)
        }
        let turnFailure = try await codexRun("turn-error", fixture: codexFixture, root: home, conversation: conversation,
                                             overrides: ["turnError": missing])
        precondition((turnFailure.error as? CodexRPCError)?.code == -32601 && turnFailure.turnCount == 1)
        precondition(turnFailure.methods == historyMethods)
        let generationFailure = try await codexRun("generation-error", fixture: codexFixture, root: home, conversation: conversation,
                                                   overrides: ["completionError": "fixture generation failed"])
        precondition(generationFailure.error?.localizedDescription == "fixture generation failed" && generationFailure.turnCount == 1)
        precondition(generationFailure.methods == historyMethods)
        print("✓ Account/thread/turn/generation failures propagate without a second turn or API replacement")

        let continuation = try await codexRun("legacy-continuation", fixture: codexFixture, root: home,
                                              prompt: CodeExplanation.continuePrompt(previous: "previous code", current: "current code"),
                                              images: [], reasoning: .medium)
        success(continuation)
        precondition(continuation.methods == directMethods)
        print("✓ Legacy continuation uses ordinary prompt input with no history injection")
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
