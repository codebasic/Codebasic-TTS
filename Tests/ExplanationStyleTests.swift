import Foundation

@main struct ExplanationStyleTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        precondition(condition(), name); checks += 1
    }
    static func main() {
        // Entirely synthetic instructions and input; no user settings or images.
        let custom = "SYNTHETIC_CUSTOM: 코드 표기는 그대로 유지하고 a + b를 예로 드세요. 응답에 코드를 재현하지 마세요."
        let hint = "SYNTHETIC_HINT: 계산을 식으로 적어 보세요."
        let source = "sample_score = evaluate(samples)\nprint(sample_score)"
        let previous = "sample_score = evaluate(old_samples)"
        let rules = CodeExplanation.outputStyleRules
        let effective = CodeExplanation.effectiveInstruction(custom)
        check(effective.hasPrefix(custom + "\n\n"), "custom instruction preserved verbatim")
        check(effective.hasSuffix(rules), "common policy follows conflicting custom examples")
        check(CodeExplanation.effectiveInstruction("").hasPrefix(CodeExplanation.defaultInstruction), "default instruction retained")
        check(!CodeExplanation.defaultInstruction.contains("x @ w"), "default does not suggest a whole expression example")
        for name in ["np.mean", "knn.score", "X_test", "y_pred"] {
            check(rules.contains(name), "identifier explicitly permitted: \(name)")
        }
        for boundary in ["실행문", "대입문", "호출 인수", "계산식·연산식", "문장 속 인용", "단독 기호", "과거 assistant", "출력 예시로 삼거나 따라 하지"] {
            check(rules.contains(boundary), "policy covers \(boundary)")
        }
        check(CodeExplanation.hintBlock(hint).hasSuffix(rules), "hint cannot override shared output boundary")
        check(CodeExplanation.hintBlock("") == "", "empty hint remains empty")
        for instruction in ["", custom] {
            let system = CodeExplanation.conversationSystem(instruction)
            let legacy = CodeExplanation.prompt(instruction, source, hint: hint)
            check(system.contains(rules), "ordinary conversation has output policy")
            check(legacy.contains(rules) && legacy.contains(source), "legacy prompt keeps source as internal context and adds policy")
            check(legacy.contains(hint), "legacy hint preserved")
        }
        let input = ConversationMessage(role: .user, text: CodeExplanation.conversationInput(source, hint: hint))
        var history = ExplanationHistory()
        let old = history.prepare(system: "synthetic previous rules", user: input, sourceID: "A")
        check(history.commit(old, output: "synthetic old answer: print(sample_score)"), "synthetic prior answer recorded")
        let oldTurn = history.turns[0]
        let system = CodeExplanation.conversationSystem(custom)
        let next = history.prepare(system: system, user: input, sourceID: "B")
        check(next.conversation.messages[1].text == oldTurn.assistant.text, "historical assistant text not rewritten")
        check(next.conversation.system.contains("과거 assistant") && next.conversation.system.contains("따라 하지"), "past code reproduction is not an output example")
        check(history.commit(next, output: "synthetic description"), "new description commits")
        let retry = history.prepare(system: system, user: input, sourceID: "B")
        check(retry.conversation == next.conversation, "regeneration keeps original context with new policy")
        let oldSystem = system.replacingOccurrences(of: "\n\n" + rules, with: "")
        let oldRequest = ExplanationConversation(system: oldSystem, messages: next.conversation.messages)
        func ordinaryKey(_ request: ExplanationConversation) -> String {
            request.resultCacheKey(endpointIdentity: "synthetic", model: "resolved", temperature: 0.4, reasoning: "medium")
        }
        check(ordinaryKey(next.conversation) != ordinaryKey(oldRequest), "new policy invalidates old ordinary custom-prompt cache")

        let fakeImages = [Data([0xA1]), Data([0xB2])]
        let imageInput = ConversationMessage(role: .user, text: CodeExplanation.conversationInput(CodeExplanation.imageOnlyInput), images: fakeImages)
        let imageRequest = ExplanationConversation(system: system, messages: [imageInput])
        check(CodeExplanation.imageOnlyInput.contains("내부 참고 자료") && CodeExplanation.imageOnlyInput.contains("전사하지"), "image-only placeholder distinguishes recognition from output")
        check(imageRequest.messages[0].images == fakeImages && imageRequest.system.contains(rules), "direct image-only request keeps both images and common policy")
        let transcription = "[코드]\n\(source)\n[강조 표시]\nsynthetic comparison\n[참고 자료]\nsynthetic context"
        let transcribedInput = CodeExplanation.conversationInput(transcription, hint: hint)
        check(transcribedInput.contains(transcription) && transcribedInput.hasSuffix(rules), "OCR text kept intact as explanation context with output policy")

        let endpoint = CustomEndpoint(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "synthetic",
                                      baseURL: "http://example.invalid", apiStyle: .gemini)
        let generator = EndpointGenerator(endpoint: endpoint, apiKey: "", model: "resolved-model", instruction: custom,
                                          temperature: 0.35, reasoningLevel: .high)
        let prompt = generator.continuationPrompt(previous: previous, current: source, hint: hint)
        check(prompt == CodeExplanation.continuePrompt(previous: previous, current: source, hint: hint, instruction: custom), "endpoint uses shared continuation prompt with custom instruction")
        check(prompt.hasPrefix(effective) && prompt.contains(rules) && prompt.contains(hint), "continuation applies custom, shared rules and hint")
        check(prompt.contains("부분만 이어서") && prompt.contains("정확히 '변경 없음'만"), "continuation delta scope and sentinel retained")
        check(!CodeExplanation.continueInstruction.contains("발음대로 풀어 말"), "continuation no longer substitutes spoken symbol names")
        func key(_ p: String, endpointID: String? = nil, model: String? = nil,
                 temperature: Double? = nil, reasoning: ReasoningLevel? = nil) -> String {
            CodeExplanation.continuationCacheKey(prompt: p, endpointIdentity: endpointID ?? endpoint.cacheIdentity,
                                                 model: model ?? generator.model, temperature: temperature ?? generator.temperature,
                                                 reasoning: reasoning ?? generator.reasoningLevel)
        }
        check(key(prompt) == key(prompt), "continuation cache key deterministic")
        for changedPrompt in [prompt + "synthetic new rule",
                              CodeExplanation.continuePrompt(previous: previous, current: source, hint: "different", instruction: custom),
                              CodeExplanation.continuePrompt(previous: previous, current: source, hint: hint, instruction: "different custom")] {
            check(key(prompt) != key(changedPrompt), "actual prompt/instruction/hint changes continuation cache")
        }
        check(key(prompt) != key(prompt, endpointID: "different"), "endpoint changes cache")
        check(key(prompt) != key(prompt, model: "different"), "resolved model changes cache")
        check(key(prompt) != key(prompt, temperature: 0.7), "temperature changes cache")
        check(key(prompt) != key(prompt, reasoning: .low), "reasoning changes cache")
        let legacyKey = NormalizationCache.key(text: previous + "\u{1F}" + source, provider: "explain-cont:" + endpoint.cacheIdentity,
                                                model: "configured-model", prompt: "continue\u{1F}" + hint + ReasoningLevel.high.cacheSuffix)
        check(key(prompt) != legacyKey, "old continuation cache entries are not reused")

        let identifiers = "np.mean, knn.score, X_test, y_pred, @, ==, 0.5"
        check(CodeExplanation.stripMarkdown(identifiers) == identifiers, "identifiers and standalone symbols preserved by postprocessing")
        check(CodeExplanation.stripMarkdown(source) == source, "no broad code-deletion postprocessor added")
        check(!normalizationPrompt("", identifiers).contains(rules), "TTS normalization remains separate from explanation policy")
        print("Explanation style tests passed (\(checks) checks).")
    }
}
