import Foundation

/// Rewrites text so the TTS engine pronounces it correctly (decimals, math
/// notation, subscripts, symbols). Implementations call an LLM (local or API);
/// callers fall back to the original text on failure so synthesis never blocks.
protocol Normalizing {
    func normalize(_ text: String) async throws -> String
}

func normalizationPrompt(_ instruction: String, _ text: String) -> String {
    let instr = instruction.isEmpty ? TextNormalizer.defaultInstruction : instruction
    return "\(instr)\n\n원문:\n\(text)\n\n변환:"
}

/// Shared LLM HTTP plumbing. Both the normalizer (원문→변환) and the explainer
/// (코드→해설) build their own prompt and call these — the prompt scaffold is
/// the caller's job, NOT baked in here.
enum LLM {
    /// Google Gemini `generateContent`. `baseURL` is the API root (default
    /// `https://generativelanguage.googleapis.com/v1beta`); the path
    /// `/models/{model}:generateContent` is appended. Returns the (trimmed) text.
    static func gemini(baseURL: String = GeminiNormalizer.defaultBaseURL,
                       apiKey: String, model: String, prompt: String,
                       temperature: Double = 0.2) async throws -> String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = GeminiNormalizer.defaultBaseURL }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/models/\(model):generateContent") else {
            throw NSError(domain: "Gemini", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "잘못된 Gemini 엔드포인트 URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["temperature": temperature],
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "request failed"
            throw NSError(domain: "Gemini", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cands = obj?["candidates"] as? [[String: Any]]
        let content = cands?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        return (parts?.first?["text"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Local Ollama `api/generate` (non-streaming). Returns the (trimmed) text.
    static func ollama(baseURL: URL, model: String, prompt: String,
                       temperature: Double = 0.2) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": temperature],
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "request failed"
            throw NSError(domain: "Ollama", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["response"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Local LLM via Ollama.
struct TextNormalizer: Normalizing {
    let baseURL: URL
    let model: String
    let instruction: String

    static let defaultInstruction = """
    당신은 TTS(음성 합성)가 정확히 읽도록 텍스트를 다듬는 전처리기입니다.
    의미는 그대로 두고, 잘못 읽힐 수 있는 표기만 한국어 발음대로 풀어 씁니다.
    규칙:
    - 소수/숫자: 0.5 → 영 점 오, 3.14 → 삼 점 일사
    - 변수/첨자/수식: w1 → 더블유 일, x^2 → 엑스 제곱, a_i → 에이 아이, β → 베타, k → 케이, n → 엔
    - 등식/부등식: k=1 → 케이는 일, x>0 → 엑스는 영보다 큼
    - 기호/단위: % → 퍼센트, ± → 플러스 마이너스, ℃ → 도, ~ → 물결
    - 마크다운/수식을 복사하며 생긴 중복·깨짐을 정리합니다. 같은 변수/수식이 바로 이어서 중복되면 하나로 합칩니다.
      예: 'k k는' → '케이는', 'k = 1 k=1은' → '케이는 일은', 쪼개진 'k = 1' → '케이는 일'.
    - 일반 영어 단어/문장과 한글 문장은 그대로 둡니다.
    - 설명·따옴표·머리말 없이, 변환된 텍스트만 출력합니다.
    """

    func normalize(_ text: String) async throws -> String {
        let out = try await LLM.ollama(baseURL: baseURL, model: model,
                                       prompt: normalizationPrompt(instruction, text))
        return out.isEmpty ? text : out
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

    func normalize(_ text: String) async throws -> String {
        let out = try await LLM.gemini(baseURL: baseURL, apiKey: apiKey, model: model,
                                       prompt: normalizationPrompt(instruction, text))
        return out.isEmpty ? text : out
    }
}

// MARK: - Code explanation (코드 → 해설)

/// Turns source code into a spoken-style Korean commentary. Distinct from
/// `Normalizing`: the prompt frames the task as *explanation*, not 원문→변환,
/// and the caller surfaces failures instead of falling back to the raw code.
protocol Explaining {
    /// `hint` is optional per-run steering (context or a regeneration direction).
    func explain(_ code: String, hint: String) async throws -> String
    /// Incremental: given the previously-explained code and the current code,
    /// explain ONLY what was added/changed, in a continuing narration tone.
    func explainContinuing(previous: String, current: String, hint: String) async throws -> String
}

/// Shared default instruction + prompt scaffold for the explainers.
enum CodeExplanation {
    static let defaultInstruction = """
    당신은 코드를 음성으로 설명해 주는 해설자입니다.
    주어진 코드를 듣는 사람이 머릿속으로 그릴 수 있도록 한국어 구어체로 해설하세요.
    규칙:
    - 코드를 한 줄씩 그대로 낭독하지 말고, 무엇을 하는 코드인지 목적과 전체 동작 흐름을 자연스럽게 설명합니다.
    - 핵심 개념, 사용된 기법, 주의할 점이 있으면 짚어 줍니다.
    - 음성으로 들을 것이므로 기호를 나열하지 말고 풀어서 말합니다.
      예: i++ → 아이를 하나 증가, == → 같은지 비교, => → 화살표 함수, [] → 배열.
    - 변수·함수 이름은 자연스럽게 읽되, 필요하면 영어 그대로 말합니다.
    - 마크다운, 코드 블록, 머리말·맺음말 없이 해설 본문만 출력합니다.
    - 장황하지 않게, 핵심 위주로 설명합니다.
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
    - 코드를 한 줄씩 낭독하지 말고, 변경의 의도와 동작을 풀어서 설명합니다.
    - 음성으로 들을 것이므로 기호를 나열하지 말고 말로 풀어 씁니다.
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
    func explain(_ code: String, hint: String) async throws -> String {
        try await LLM.gemini(baseURL: baseURL, apiKey: apiKey, model: model,
                             prompt: CodeExplanation.prompt(instruction, code, hint: hint), temperature: 0.4)
    }
    func explainContinuing(previous: String, current: String, hint: String) async throws -> String {
        try await LLM.gemini(baseURL: baseURL, apiKey: apiKey, model: model,
                             prompt: CodeExplanation.continuePrompt(previous: previous, current: current, hint: hint),
                             temperature: 0.4)
    }
}

/// Code explanation via local Ollama.
struct OllamaExplainer: Explaining {
    let baseURL: URL
    let model: String
    let instruction: String
    func explain(_ code: String, hint: String) async throws -> String {
        try await LLM.ollama(baseURL: baseURL, model: model,
                             prompt: CodeExplanation.prompt(instruction, code, hint: hint), temperature: 0.4)
    }
    func explainContinuing(previous: String, current: String, hint: String) async throws -> String {
        try await LLM.ollama(baseURL: baseURL, model: model,
                             prompt: CodeExplanation.continuePrompt(previous: previous, current: current, hint: hint),
                             temperature: 0.4)
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
