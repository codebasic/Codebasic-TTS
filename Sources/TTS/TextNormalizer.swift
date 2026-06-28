import Foundation

/// Rewrites text so the TTS engine pronounces it correctly (decimals, math
/// notation, subscripts, symbols). Implementations call an LLM (local or API);
/// callers fall back to the original text on failure so synthesis never blocks.
protocol Normalizing {
    /// Stream the normalized text as deltas. Callers fall back to the original on
    /// failure so synthesis never blocks.
    func normalizeStream(_ text: String) -> AsyncThrowingStream<String, Error>
}

func normalizationPrompt(_ instruction: String, _ text: String) -> String {
    let instr = instruction.isEmpty ? TextNormalizer.defaultInstruction : instruction
    return "\(instr)\n\n원문:\n\(text)\n\n변환:"
}

/// Shared LLM HTTP plumbing. Both the normalizer (원문→변환) and the explainer
/// (코드→해설) build their own prompt and call these — the prompt scaffold is
/// the caller's job, NOT baked in here.
enum LLM {
    /// Gemini streaming (`:streamGenerateContent?alt=sse`). Yields text deltas as
    /// they arrive; each `data:` line is a full response whose first part's text
    /// is the increment. Cancelling the consuming task tears down the request.
    static func geminiStream(baseURL: String = GeminiNormalizer.defaultBaseURL,
                             apiKey: String, model: String, prompt: String,
                             images: [Data] = [], temperature: Double = 0.2) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if base.isEmpty { base = GeminiNormalizer.defaultBaseURL }
                    while base.hasSuffix("/") { base.removeLast() }
                    guard let url = URL(string: "\(base)/models/\(model):streamGenerateContent?alt=sse") else {
                        throw NSError(domain: "Gemini", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "잘못된 Gemini 엔드포인트 URL"])
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    var parts: [[String: Any]] = [["text": prompt]]
                    for img in images {
                        parts.append(["inline_data": ["mime_type": "image/png",
                                                      "data": img.base64EncodedString()]])
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "contents": [["parts": parts]],
                        "generationConfig": ["temperature": temperature],
                    ])
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw NSError(domain: "Gemini",
                                      code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                                      userInfo: [NSLocalizedDescriptionKey:
                                        "Gemini 요청 실패 (\((response as? HTTPURLResponse)?.statusCode ?? -1))"])
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !json.isEmpty, json != "[DONE]",
                              let d = json.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let cands = obj["candidates"] as? [[String: Any]],
                              let content = cands.first?["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]],
                              let text = parts.first?["text"] as? String else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Ollama streaming (`api/generate`, stream:true → JSONL). Yields each
    /// `response` delta; stops at the `done:true` line. Cancellation tears down.
    static func ollamaStream(baseURL: URL, model: String, prompt: String,
                             temperature: Double = 0.2) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model, "prompt": prompt, "stream": true,
                        "options": ["temperature": temperature],
                    ])
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw NSError(domain: "Ollama",
                                      code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                                      userInfo: [NSLocalizedDescriptionKey: "Ollama 요청 실패"])
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let d = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }
                        if let resp = obj["response"] as? String, !resp.isEmpty {
                            continuation.yield(resp)
                        }
                        if obj["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Ollama multimodal streaming (`api/chat`, stream:true → JSONL). Needed for
    /// vision: image input is delivered via the chat message's `images` (base64),
    /// not `api/generate`. Yields each `message.content` delta.
    static func ollamaChatStream(baseURL: URL, model: String, prompt: String,
                                 images: [Data], temperature: Double = 0.2) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    var message: [String: Any] = ["role": "user", "content": prompt]
                    if !images.isEmpty { message["images"] = images.map { $0.base64EncodedString() } }
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model, "messages": [message], "stream": true,
                        "options": ["temperature": temperature],
                    ])
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw NSError(domain: "Ollama",
                                      code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                                      userInfo: [NSLocalizedDescriptionKey: "Ollama(chat) 요청 실패"])
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let d = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }
                        if let msg = obj["message"] as? [String: Any],
                           let resp = msg["content"] as? String, !resp.isEmpty {
                            continuation.yield(resp)
                        }
                        if obj["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

/// Local LLM via Ollama.
struct TextNormalizer: Normalizing {
    let baseURL: URL
    let model: String
    let instruction: String

    static let defaultInstruction = """
    당신은 TTS(음성 합성)가 자연스럽게 읽도록 텍스트를 다듬는 전처리기입니다.
    의미는 그대로 두고, 잘못 읽힐 수 있는 표기만 한국어 발음대로 풀어 씁니다. 변환된 텍스트만 출력합니다.
    규칙:
    - 함수·메서드·클래스·변수 등 코드 명칭은 영어로 두지 말고 발음나는 한국어로 적습니다. 예: fetch_california_housing → 페치 캘리포니아 하우징, plt.show → 피엘티 쇼.
    - 임포트된 패키지 별칭은 원래 패키지명으로 적습니다. 예: np → 넘파이, pd → 판다스, sklearn → 싸이킷런, plt → 매트플롯립, tf → 텐서플로우.
    - 카멜표기는 단어별로 끊어 발음나는 한국어로 적습니다. 예: MyCode → 마이 코드, YourClass → 유얼 클래스.
    - 영어 단어인 대문자 약어도 발음대로 적습니다. 예: AND → 엔드, NAND → 낸드, OR → 오알.
    - 영어 단어가 아닌 변수는 각 문자를 읽습니다. 예: xi → 엑스 아이, yi → 와이 아이.
    - 밑줄로 구분된 표기는 각 부분을 발음대로 적습니다. 예: y_or → 와이 오알, y_xor → 와이 엑스오알.
    - 속성 접근의 점은 '닷'으로 읽습니다. 예: self.w → 셀프 닷 더블유, self.b → 셀프 닷 비.
    - 기호가 섞인 인덱싱은 기호를 한국어로 읽습니다. 예: Xs[:, 0] → 엑스 에스 콜론 컴마 영, Xs[:, 1] → 엑스 에스 콜론 컴마 일.
    - 기호는 한국어 발음으로 적고 영문 병기는 하지 않습니다. 예: @ → 엣, % → 퍼센트, # → 샵, & → 엠퍼샌드.
    - 수식 기호는 발음대로 풉니다. 예: x^2 → 엑스 제곱, β → 베타, k=1 → 케이는 일, x>0 → 엑스는 영보다 큼.
    - 영어 원문 병기(괄호 안 영어)는 괄호째 삭제하고 한국어만 남깁니다. 예: 데이터프레임(DataFrame) → 데이터프레임.
    - 슬래시나 하이픈으로 길게 이어진 경로형 식별자(데이터셋·모델 경로 등)는 핵심 단어 한두 개만 골라 짧게 줄여 읽습니다. 예: codebasic/aihub-koen-translation-integrated-base-1m → 코드베이직 번역 데이터셋.
    - 함수 호출의 괄호쌍과 따옴표는 표기에서 생략합니다.
    - 숫자: 음수는 '마이너스', 소수점은 '쩜'으로 풉니다. 예: -1 → 마이너스 일, -1.234 → 마이너스 일 쩜 이삼사, 0.5 → 영 쩜 오.
    - 괄호로 묶인 숫자쌍은 같은 형식으로 읽습니다. 예: (0, 1) → 영 콤마 일.
    - 영문과 한글을 함께 적을 때는 공백으로 구분합니다.
    - 마크다운/수식을 복사하며 생긴 중복·깨짐은 자연스럽게 정리합니다.
    - 머리말 없이 변환된 텍스트만 출력합니다.
    """

    var temperature: Double = 0.2
    func normalizeStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        LLM.ollamaStream(baseURL: baseURL, model: model,
                         prompt: normalizationPrompt(instruction, text), temperature: temperature)
    }
}

/// Google Gemini API normalizer.
struct GeminiNormalizer: Normalizing {
    let baseURL: String
    let apiKey: String
    let model: String          // e.g. "gemini-2.0-flash"
    let instruction: String

    static let models = ["gemini-2.0-flash", "gemini-2.5-flash", "gemini-1.5-flash"]
    static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta"

    var temperature: Double = 0.2
    func normalizeStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        LLM.geminiStream(baseURL: baseURL, apiKey: apiKey, model: model,
                         prompt: normalizationPrompt(instruction, text), temperature: temperature)
    }
}

// MARK: - Code explanation (코드 → 해설)

/// Turns source code into a spoken-style Korean commentary. Distinct from
/// `Normalizing`: the prompt frames the task as *explanation*, not 원문→변환,
/// and the caller surfaces failures instead of falling back to the raw code.
protocol Explaining {
    /// Stream the commentary as text deltas. `hint` is optional per-run steering.
    /// (Screenshots are transcribed to text by a vision model in a prior stage, so
    /// the explain step itself is text-only.)
    func stream(_ code: String, hint: String) -> AsyncThrowingStream<String, Error>
    /// Incremental stream: given the previously-explained code and the current
    /// code, explain ONLY what was added/changed, in a continuing narration tone.
    func streamContinuing(previous: String, current: String, hint: String) -> AsyncThrowingStream<String, Error>
}

/// Shared default instruction + prompt scaffold for the explainers.
enum CodeExplanation {
    static let defaultInstruction = """
    당신은 코드를 음성으로 설명해 주는 해설자입니다.
    청중에게 강의하듯이, 작성된 해설이 그대로 읽혔을 때 자연스럽게 들리도록 한국어 구어체로 상세하고 명확하게 해설하세요.
    규칙:
    - 모든 문장은 존대말(…입니다/…합니다/…습니다)로 끝맺습니다.
    - 함께 짚어 나가는 느낌을 주기 위해 "이 코드에서 우리는 …"처럼 제시합니다. 다만 '여러분'처럼 청중을 직접 부르거나 지칭하지 않습니다.
    - 코드의 실행 결과를 예측하지 말고, 작성된 코드 자체를 해설합니다. 목적·작동 방식·주요 구성 요소와 기능을 설명하고, 필요하면 예제나 비유로 이해를 돕습니다.
    - 숫자 값은 그대로 읽기보다 그 값이 무슨 의미인지 해설합니다. 연산자 기호가 섞여 의미가 어려우면 코드 동작을 더 자세히 풀어 설명합니다.
    - 코드를 한 줄씩 낭독하거나 응답에서 코드를 재현하지 않습니다. 기술적인 부분에 집중합니다.
    - 명령줄 명령이면 '코드'가 아니라 '명령'이라고 부릅니다.
    - 코드에 제시된 부분만 충실히 해설합니다. 제시되지 않은 부분은 명시적 요청이 없으면 해설 본문이 아니라 후속 제안으로 다룹니다.
    - 주석은 해설하지 말고 참고만 합니다.
    - 음성으로 들을 것이므로 기호를 나열하지 말고 풀어서 말합니다. 예: i++ → 아이를 하나 증가, == → 같은지 비교.
    - 괄호 열고 닫기는 특별한 이유 없이 해설하지 않습니다. 슬래시(/, \\), 언더바(_), 하이픈(-)은 읽지 않습니다.
    - 해시값·커밋 ID처럼 사람에게 의미 없는 긴 무작위 문자열은 그 값을 읽지 말고 '커밋 해시값'처럼 무엇인지만 언급합니다.
    - 정규식 등의 별표(*) 같은 특수 기호는 발음대로 풀어 말하되 실제 기호는 표기하지 않습니다.
      예: **/*.jpg → "별표 두 개는 모든 폴더를, 별표 한 개는 모든 파일을 의미합니다".
    - 마크다운·코드 블록·머리말·맺음말 없이 해설 본문만 출력합니다.
    """

    /// Optional per-run steering (context the model needs, or a direction for
    /// regeneration) — applied to THIS generation only, not saved to the prompt.
    /// Re-asserts the output style AFTER the hint so steering the *content* can't
    /// drag the *format* into markdown / a separate "review" section.
    static func hintBlock(_ hint: String) -> String {
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return "" }
        return "\n\n[추가 지시 — 이번 생성의 내용·방향에만 반영]\n\(h)\n"
            + "(단, 출력 형식은 위 규칙을 그대로 따릅니다: 마크다운·제목·머리말·강조 기호(**, `, #, ---) 없이, "
            + "전체 해설과 같은 구어체 음성 해설 문장으로만 작성하고, 별도 제목이나 '리뷰' 같은 섹션을 만들지 마세요.)"
    }

    /// Strip markdown artifacts the explainer sometimes emits despite the rules
    /// (bold/code markers, headings, horizontal rules, list bullets) — they read
    /// as noise in speech. Conservative: only removes well-known markers, keeps
    /// all word content.
    static func stripMarkdown(_ s: String) -> String {
        let kept = s.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { return nil }  // hrule → drop
            var l = line.replacingOccurrences(of: #"^\s*#{1,6}\s+"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)  // bullet
            return l
        }
        return kept.joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prompt(_ instruction: String, _ code: String, hint: String = "") -> String {
        let instr = instruction.isEmpty ? defaultInstruction : instruction
        return "\(instr)\(hintBlock(hint))\n\n코드:\n\(code)\n\n해설:"
    }

    /// Sentinel the model returns when the current code has no meaningful change
    /// over the previous version — callers skip appending it.
    static let noChange = "변경 없음"

    static let continueInstruction = """
    당신은 코드를 음성으로 이어서 설명해 주는 해설자입니다.
    아래 '이전 코드'는 이미 해설을 마쳤습니다. 이번에는 '현재 코드'에서 이전 대비
    새로 추가되거나 변경된(또는 삭제된) 부분만 이어서 설명하세요.
    규칙:
    - 이미 설명한 부분은 다시 설명하지 마세요.
    - "이번에는", "여기에 …를 추가했고", "앞서 만든 …를 …로 바꿨습니다"처럼 흐름을 잇는 말투로.
    - 코드를 한 줄씩 낭독하거나 코드를 재현하지 말고, 변경의 의도와 동작을 풀어서 설명합니다. 주석은 참고만 합니다.
    - 음성으로 들을 것이므로 기호를 나열하지 말고 말로 풀어 씁니다. 괄호·슬래시·언더바·하이픈은 읽지 않고, 해시값은 그 값을 읽지 않으며, 정규식 별표(*) 등은 발음대로 풀어 말합니다.
    - 마크다운·코드 블록·머리말·맺음말 없이 해설 본문만 출력합니다.
    - 의미 있는 변경이 없으면 다른 말 없이 정확히 '변경 없음'만 출력하세요.
    """

    static func continuePrompt(previous: String, current: String, hint: String = "") -> String {
        """
        \(continueInstruction)\(hintBlock(hint))

        [이전 코드 — 이미 해설함]
        \(previous)

        [현재 코드]
        \(current)

        [이어지는 해설]
        """
    }
}

/// Code explanation via Google Gemini.
struct GeminiExplainer: Explaining {
    let baseURL: String
    let apiKey: String
    let model: String
    let instruction: String
    var temperature: Double = 0.4
    func stream(_ code: String, hint: String) -> AsyncThrowingStream<String, Error> {
        LLM.geminiStream(baseURL: baseURL, apiKey: apiKey, model: model,
                         prompt: CodeExplanation.prompt(instruction, code, hint: hint), temperature: temperature)
    }
    func streamContinuing(previous: String, current: String, hint: String) -> AsyncThrowingStream<String, Error> {
        LLM.geminiStream(baseURL: baseURL, apiKey: apiKey, model: model,
                         prompt: CodeExplanation.continuePrompt(previous: previous, current: current, hint: hint),
                         temperature: temperature)
    }
}

/// Code explanation via local Ollama.
struct OllamaExplainer: Explaining {
    let baseURL: URL
    let model: String
    let instruction: String
    var temperature: Double = 0.4
    func stream(_ code: String, hint: String) -> AsyncThrowingStream<String, Error> {
        LLM.ollamaStream(baseURL: baseURL, model: model,
                         prompt: CodeExplanation.prompt(instruction, code, hint: hint), temperature: temperature)
    }
    func streamContinuing(previous: String, current: String, hint: String) -> AsyncThrowingStream<String, Error> {
        LLM.ollamaStream(baseURL: baseURL, model: model,
                         prompt: CodeExplanation.continuePrompt(previous: previous, current: current, hint: hint),
                         temperature: temperature)
    }
}

/// Gemini helpers for the UI.
enum Gemini {
    /// Models the endpoint exposes that support `generateContent`, as short ids
    /// (e.g. "gemini-2.0-flash"). `baseURL` is the same API root as generation.
    static func models(baseURL: String, apiKey: String) async throws -> [String] {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = GeminiNormalizer.defaultBaseURL }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/models") else {
            throw NSError(domain: "Gemini", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "잘못된 Gemini 엔드포인트 URL"])
        }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Gemini에 연결할 수 없음"
            throw NSError(domain: "Gemini", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = (obj?["models"] as? [[String: Any]]) ?? []
        return arr.compactMap { m -> String? in
            let methods = m["supportedGenerationMethods"] as? [String]
            guard methods?.contains("generateContent") ?? true else { return nil }
            guard let name = m["name"] as? String else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }
    }
}

/// Ollama helpers for the UI.
enum Ollama {
    static func models(baseURL: URL) async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("api/tags"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Ollama", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Ollama에 연결할 수 없음"])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = (obj?["models"] as? [[String: Any]]) ?? []
        return arr.compactMap { $0["name"] as? String }
    }
}
