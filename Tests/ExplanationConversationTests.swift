import Foundation

@main struct ExplanationConversationTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        precondition(condition(), name); checks += 1
    }
    static func user(_ text: String, images: [Data] = []) -> ConversationMessage {
        ConversationMessage(role: .user, text: text, images: images)
    }
    static func main() {
        var history = ExplanationHistory()
        let first = history.prepare(system: "current rules", user: user("A"), sourceID: "A")
        check(first.conversation.messages == [user("A")], "first request has only current user")
        check(history.turns.isEmpty, "prepare/failure does not commit")
        check(!history.commit(first, output: " \n"), "empty response rejected")
        check(history.commit(first, output: "answer A"), "successful pair commits")
        let second = history.prepare(system: "current rules", user: user("B"), sourceID: "B")
        check(Array(second.conversation.messages.prefix(first.conversation.messages.count)) == first.conversation.messages,
              "new request appends without rewriting old input")
        check(second.conversation.messages.map(\.role) == [.user, .assistant, .user], "chronological roles preserved")
        check(second.conversation.messages[1].text == "answer A", "successful output sent as assistant")
        check(history.commit(second, output: "answer B"), "second pair commits")
        let retry = history.prepare(system: "current rules", user: user("B"), sourceID: "B")
        check(retry.conversation.cacheIdentity == second.conversation.cacheIdentity, "same source reuses original request context")
        // A failed retry has no side effects. A successful regeneration replaces its answer.
        check(history.turns.count == 2, "failed/cancelled retry does not append")
        check(history.commit(retry, output: "new answer B"), "regeneration succeeds")
        check(history.turns.count == 2 && history.turns.last?.assistant.text == "new answer B", "regeneration replaces latest pair")
        let third = history.prepare(system: "current rules", user: user("C"), sourceID: "C")
        let changedHint = history.prepare(system: "current rules", user: user("C with new hint"), sourceID: "C")
        func key(_ c: ExplanationConversation, _ endpoint: String = "endpoint", _ model: String = "model", _ temperature: Double = 0.4, _ reasoning: String = "medium") -> String {
            c.resultCacheKey(endpointIdentity: endpoint, model: model, temperature: temperature, reasoning: reasoning)
        }
        check(key(third.conversation) == key(third.conversation), "result key deterministic")
        check(key(third.conversation) != key(changedHint.conversation), "hint invalidates result key")
        check(key(third.conversation) != key(third.conversation, "other"), "endpoint invalidates result key")
        check(key(third.conversation) != key(third.conversation, "endpoint", "other"), "model invalidates result key")
        check(key(third.conversation) != key(third.conversation, "endpoint", "model", 0.7), "temperature invalidates result key")
        check(key(third.conversation) != key(third.conversation, "endpoint", "model", 0.4, "high"), "reasoning invalidates result key")
        check(key(third.conversation) != key(ExplanationConversation(system: "other rules", messages: third.conversation.messages)), "system instruction invalidates key")
        check(key(third.conversation) != key(ExplanationConversation(system: third.conversation.system, messages: [user("C")])), "selected history invalidates key")
        check(key(third.conversation) != key(ExplanationConversation(system: third.conversation.system, messages: third.conversation.messages.reversed())), "message order invalidates key")
        history.clear()
        check(history.turns.isEmpty, "clear removes history")
        check(!history.commit(third, output: "late completion"), "clear invalidates in-flight completion")
        let fresh = history.prepare(system: "current rules", user: user("C"), sourceID: "C")
        check(fresh.conversation.messages.count == 1, "clear also removes retry snapshot")

        var bounded = ExplanationHistory(maxTurns: 6, maxTextBytes: 1000, maxImageBytes: 1000)
        for i in 0..<6 {
            let r = bounded.prepare(system: "rules", user: user("input \(i)"), sourceID: "\(i)")
            check(bounded.commit(r, output: "output \(i)"), "bounded pair commits")
        }
        let roll = bounded.prepare(system: "rules", user: user("input 6"), sourceID: "6")
        check(roll.prefix.count == 3, "overflow evicts a batch rather than sliding every turn")
        check(roll.prefix.first?.sourceID == "3", "batch retains recent complete pairs")
        check(bounded.commit(roll, output: "output 6"), "rollover commits")
        let rollRetry = bounded.prepare(system: "rules", user: user("input 6"), sourceID: "6")
        check(rollRetry.conversation == roll.conversation, "regeneration preserves cache context across pruning")
        let next = bounded.prepare(system: "rules", user: user("input 7"), sourceID: "7")
        check(next.prefix.first?.sourceID == "3", "prefix stays fixed after rollover")
        check(Array(next.conversation.messages.prefix(roll.conversation.messages.count)) == roll.conversation.messages, "append-only resumes after batch pruning")
        var bytes = ExplanationHistory(maxTurns: 8, maxTextBytes: 30, maxImageBytes: 3)
        let large = bytes.prepare(system: "rules", user: user("한글한글한글한글한글"), sourceID: "large")
        check(bytes.commit(large, output: "large answer"), "oversized response completes")
        check(bytes.turns.isEmpty, "oversized pair omitted instead of truncated")
        let image = bytes.prepare(system: "rules", user: user("x", images: [Data([1, 2, 3, 4])]), sourceID: "image")
        check(bytes.commit(image, output: "y") && bytes.turns.isEmpty, "image byte limit enforced")

        let messages = [user("old hint", images: [Data([1, 2])]), ConversationMessage(role: .assistant, text: "old answer"), user("new request")]
        let conversation = ExplanationConversation(system: "current rules win", messages: messages)
        let openAI = conversation.openAIMessages
        check(openAI.compactMap { $0["role"] as? String } == ["system", "user", "assistant", "user"], "OpenAI native roles")
        check(conversation.geminiContents.compactMap { $0["role"] as? String } == ["user", "model", "user"], "Gemini model role")
        check(conversation.anthropicMessages.compactMap { $0["role"] as? String } == ["user", "assistant", "user"], "Anthropic native roles")
        check(conversation.ollamaMessages.compactMap { $0["role"] as? String } == ["system", "user", "assistant", "user"], "Ollama native roles")
        check(conversation.codexHistoryItems.compactMap { $0["role"] as? String } == ["user", "assistant"], "Codex explicit history excludes current user")
        let codexContent = conversation.codexHistoryItems[0]["content"] as! [[String: Any]]
        check(codexContent.last?["type"] as? String == "input_image", "Codex historical image preserved")
        check(conversation.hasImages, "CLI rejects historical images too")
        let extended = ExplanationConversation(system: conversation.system, messages: messages + [ConversationMessage(role: .assistant, text: "new answer"), user("next")])
        check(extended.transcript.hasPrefix(conversation.transcript + "\n"), "CLI transcript prefix is append-only")
        check((try! JSONDecoder().decode(ExplanationConversation.self, from: Data(conversation.cacheIdentity.utf8))) == conversation, "stable serialization preserves text/roles/images")
        let changedImage = ExplanationConversation(system: conversation.system, messages: [user("old hint", images: [Data([1, 3])])] + Array(messages.dropFirst()))
        check(key(conversation) != key(changedImage), "image content invalidates cache key")
        func canonical(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        check(canonical(Array(extended.openAIMessages.prefix(openAI.count))) == canonical(openAI), "OpenAI cached message boundaries stay identical")
        check(canonical(Array(extended.geminiContents.prefix(messages.count))) == canonical(conversation.geminiContents), "Gemini cached prefix stays identical")
        check(canonical(Array(extended.anthropicMessages.prefix(messages.count))) == canonical(conversation.anthropicMessages), "Anthropic cached prefix stays identical")
        check(canonical(Array(extended.ollamaMessages.prefix(openAI.count))) == canonical(conversation.ollamaMessages), "Ollama cached prefix stays identical")
        var byteLimited = ExplanationHistory(maxTurns: 100, maxTextBytes: 32, maxImageBytes: 4)
        for i in 0..<20 {
            let r = byteLimited.prepare(system: "rules", user: user("한\(i)", images: [Data([1])]), sourceID: "\(i)")
            check(byteLimited.commit(r, output: "답"), "UTF8/image bounded pair commits")
            check(byteLimited.turns.reduce(0) { $0 + $1.textBytes } <= 32, "history obeys UTF8 byte cap")
            check(byteLimited.turns.reduce(0) { $0 + $1.imageBytes } <= 4, "history obeys image byte cap")
            check(byteLimited.turns.allSatisfy { $0.user.role == .user && $0.assistant.role == .assistant }, "eviction preserves complete pairs")
        }
        print("Conversation tests passed (\(checks) checks).")
    }
}
