import Foundation

/// All roles share the same connection selection; a plan never falls back to an API key.
struct EndpointGenerator: Normalizing, Explaining {
    let endpoint: CustomEndpoint
    let apiKey: String
    let model: String
    let instruction: String
    let temperature: Double
    let reasoningLevel: ReasoningLevel

    func normalizeStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        generate(normalizationPrompt(instruction, text))
    }
    func stream(_ code: String, hint: String) -> AsyncThrowingStream<String, Error> {
        generate(CodeExplanation.prompt(instruction, code, hint: hint))
    }
    func streamContinuing(previous: String, current: String, hint: String) -> AsyncThrowingStream<String, Error> {
        generate(continuationPrompt(previous: previous, current: current, hint: hint))
    }
    func continuationPrompt(previous: String, current: String, hint: String) -> String {
        CodeExplanation.continuePrompt(previous: previous, current: current, hint: hint, instruction: instruction)
    }
    func generate(_ prompt: String, images: [Data] = [], conversation: ExplanationConversation? = nil) -> AsyncThrowingStream<String, Error> {
        if endpoint.usesPlan {
            if endpoint.resolvedProvider == .google {
                return AntigravityPlan.stream(prompt: prompt, model: model, images: images, conversation: conversation)
            }
            guard endpoint.resolvedProvider == .openAI else {
                return AsyncThrowingStream { $0.finish(throwing: connectionError("이 공급자의 플랜 연결은 지원하지 않습니다.")) }
            }
            return CodexPlan.stream(prompt: prompt, model: model, images: images, reasoning: reasoningLevel, conversation: conversation)
        }
        switch endpoint.apiStyle {
        case .anthropic:
            return AnthropicAPI.stream(baseURL: endpoint.baseURL, key: apiKey, model: model, prompt: prompt, images: images, conversation: conversation)
        case .gemini:
            return LLM.geminiStream(baseURL: endpoint.baseURL, apiKey: apiKey, model: model, prompt: prompt,
                                    images: images, temperature: temperature, reasoningLevel: reasoningLevel, conversation: conversation)
        case .openAICompatible:
            return LLM.openAIChatStream(baseURL: endpoint.baseURL, model: model, apiKey: apiKey, prompt: prompt,
                                        images: images, temperature: temperature, reasoningLevel: reasoningLevel,
                                        omitTemperature: endpoint.resolvedProvider == .openAI && !model.hasPrefix("gpt-4") && !model.hasPrefix("gpt-3.5"), conversation: conversation)
        case .ollama:
            guard let url = URL(string: endpoint.baseURL) else {
                return AsyncThrowingStream { $0.finish(throwing: connectionError("서버 주소를 확인하세요.")) }
            }
            if images.isEmpty && conversation == nil {
                return LLM.ollamaStream(baseURL: url, model: model, prompt: prompt, temperature: temperature, reasoningLevel: reasoningLevel)
            }
            return LLM.ollamaChatStream(baseURL: url, model: model, prompt: prompt, images: images,
                                        temperature: temperature, reasoningLevel: reasoningLevel, conversation: conversation)
        }
    }
}

enum AnthropicAPI {
    static func request(baseURL: String, path: String, key: String) throws -> URLRequest {
        guard !key.isEmpty else { throw connectionError("Anthropic API 키를 입력하세요.") }
        guard let base = URL(string: baseURL), ["http", "https"].contains(base.scheme ?? ""), base.host != nil else {
            throw connectionError("서버 주소를 확인하세요.")
        }
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 120)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    static func models(baseURL: String, key: String) async throws -> [String] {
        var models: [String] = []
        var cursor: String?
        repeat {
            var req = try request(baseURL: baseURL, path: "models", key: key)
            var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
            req.url = components.url
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw connectionError("Anthropic 연결 실패 (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). 키와 주소를 확인하세요.")
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            models += (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            cursor = object["has_more"] as? Bool == true ? object["last_id"] as? String : nil
        } while cursor != nil
        return models
    }

    static func stream(baseURL: String, key: String, model: String, prompt: String, images: [Data], conversation: ExplanationConversation? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let activityID = MemoryDiagnostics.begin("EndpointGenerator.anthropicStream")
                defer { MemoryDiagnostics.end(activityID) }
                do {
                    var req = try request(baseURL: baseURL, path: "messages", key: key)
                    req.httpMethod = "POST"
                    var content: [[String: Any]] = images.map {
                        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": $0.base64EncodedString()]]
                    }
                    content.append(["type": "text", "text": prompt])
                    var payload: [String: Any] = ["model": model, "max_tokens": 8192,
                        "stream": true, "messages": [["role": "user", "content": content]]]
                    if let conversation {
                        payload["system"] = conversation.system
                        payload["messages"] = conversation.anthropicMessages
                        // Official API automatic caching; do not impose this extension on third-party proxies.
                        if URL(string: baseURL)?.host == "api.anthropic.com" {
                            payload["cache_control"] = ["type": "ephemeral"]
                        }
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: payload)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw connectionError("Anthropic 생성 실패 (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                    }
                    var completed = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:"), let data = line.dropFirst(5).data(using: .utf8),
                              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if event["type"] as? String == "error" {
                            let error = event["error"] as? [String: Any]
                            throw connectionError(error?["message"] as? String ?? "Anthropic 스트림 오류")
                        }
                        if event["type"] as? String == "content_block_delta",
                           let delta = event["delta"] as? [String: Any], let text = delta["text"] as? String { continuation.yield(text) }
                        if event["type"] as? String == "message_delta", let delta = event["delta"] as? [String: Any],
                           delta["stop_reason"] as? String == "max_tokens" { throw connectionError("응답 길이 제한에 도달했습니다. 입력을 나눠 주세요.") }
                        if event["type"] as? String == "message_stop" { completed = true }
                    }
                    guard completed else { throw connectionError("응답이 완료되기 전에 연결이 끊겼습니다.") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
