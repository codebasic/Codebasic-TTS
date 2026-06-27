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
    - 마크다운/수식을 복사하며 깨진 부분(같은 변수가 줄마다 중복되거나 'k = 1'처럼 토큰이 쪼개진 경우)은
      원래 의미로 합쳐 자연스러운 한 문장으로 정리합니다.
    - 일반 영어 단어/문장과 한글 문장은 그대로 둡니다.
    - 설명·따옴표·머리말 없이, 변환된 텍스트만 출력합니다.
    """

    func normalize(_ text: String) async throws -> String {
        let prompt = normalizationPrompt(instruction, text)
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.2],
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "request failed"
            throw NSError(domain: "Ollama", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let out = (obj?["response"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? text : out
    }
}

/// Google Gemini API normalizer.
struct GeminiNormalizer: Normalizing {
    let apiKey: String
    let model: String          // e.g. "gemini-2.0-flash"
    let instruction: String

    static let models = ["gemini-2.0-flash", "gemini-2.5-flash", "gemini-1.5-flash"]

    func normalize(_ text: String) async throws -> String {
        let prompt = normalizationPrompt(instruction, text)
        let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 60
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.2],
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
        let out = (parts?.first?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? text : out
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
