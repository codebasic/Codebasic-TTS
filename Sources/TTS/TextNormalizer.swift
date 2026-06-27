import Foundation

/// Rewrites text so the TTS engine pronounces it correctly (decimals, math
/// notation, subscripts, symbols) using a lightweight local LLM via Ollama.
/// Meaning is preserved; on any failure it returns the original text so
/// synthesis is never blocked.
struct TextNormalizer {
    let baseURL: URL
    let model: String

    private static let instruction = """
    당신은 TTS(음성 합성)가 정확히 읽도록 텍스트를 다듬는 전처리기입니다.
    의미와 문장 구조는 그대로 두고, 잘못 읽힐 수 있는 표기만 한국어 발음대로 풀어 씁니다.
    규칙:
    - 소수/숫자: 0.5 → 영 점 오, 3.14 → 삼 점 일사
    - 변수/첨자/수식: w1 → 더블유 일, x^2 → 엑스 제곱, a_i → 에이 아이, β → 베타
    - 기호/단위: % → 퍼센트, ± → 플러스 마이너스, ℃ → 도, ~ → 물결
    - 일반 영어 단어/문장과 한글 문장은 그대로 둡니다.
    - 설명·따옴표·머리말 없이, 변환된 텍스트만 출력합니다.
    """

    func normalize(_ text: String) async throws -> String {
        let prompt = "\(Self.instruction)\n\n원문:\n\(text)\n\n변환:"
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
