import Foundation

// 옵트인 스모크 테스트: `./build.sh smoke` — 실제 앱 소스(TextNormalizer.swift의
// 프롬프트·스트림, ReviewVerdict.swift의 파서, Secrets)를 그대로 컴파일해 **실제
// 엔드포인트**(App Support의 gemini_key)로 해설 → 검수 → 대본 → 검수를 돌리고,
// 오염된 해설에 '수정' 판정이 나와 재생성 후 '통과'로 바뀌는지 본다. 유료 호출이라
// 단위 테스트(`./build.sh test`)와 분리. 환경변수: EXPLAIN_MODEL, SCRIPT_MODEL,
// REVIEW=gemini|ollama, REVIEW_MODEL.

let sample = """
import numpy as np

def softmax(x):
    e = np.exp(x - np.max(x))
    return e / e.sum(axis=0)

scores = np.array([2.0, 1.0, 0.1])
probs = softmax(scores)
assert abs(probs.sum() - 1.0) < 1e-6
print(probs)
"""

// 오염된 해설: 마크다운 제목·타임코드·인사말·음성용 표기 — 검수가 '수정'을 내야 한다.
let contaminated = """
## 소프트맥스 함수 해설

1. **[00:00]** 안녕하세요, 여러분. 오늘은 소프트맥스를 알아보겠습니다.
2. **[00:10]** `np.exp`로 지수를 구하고, 영 점 일 같은 값도 확률로 바꿉니다.

감사합니다.
"""

func collect(_ s: AsyncThrowingStream<String, Error>) async throws -> String {
    var acc = ""
    for try await d in s { acc += d }
    return acc
}
func lastLine(_ s: String) -> String {
    s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        .last(where: { !$0.isEmpty }) ?? ""
}
func timed<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
    let t0 = Date()
    let r = try await body()
    print(String(format: "  [%@ %.1fs]", label, Date().timeIntervalSince(t0)))
    return r
}

@main struct Harness {
    static func main() async {
        guard let key = Secrets.geminiKey else { print("gemini_key 없음"); exit(1) }
        let base = "https://generativelanguage.googleapis.com/v1beta"
        let env = ProcessInfo.processInfo.environment
        let explainModel = env["EXPLAIN_MODEL"] ?? "gemini-flash-latest"
        let scriptModel  = env["SCRIPT_MODEL"]  ?? "gemini-flash-lite-latest"
        let reviewer: Reviewing
        if env["REVIEW"] == "ollama" {
            reviewer = OllamaReviewer(baseURL: URL(string: "http://localhost:11434")!,
                                      model: env["REVIEW_MODEL"] ?? "gemma4:31b-cloud", temperature: 0.2)
            print("검수 모델: ollama \(env["REVIEW_MODEL"] ?? "gemma4:31b-cloud")")
        } else {
            reviewer = GeminiReviewer(baseURL: base, apiKey: key,
                                      model: env["REVIEW_MODEL"] ?? "gemini-flash-lite-latest", temperature: 0.2)
            print("검수 모델: gemini \(env["REVIEW_MODEL"] ?? "gemini-flash-lite-latest")")
        }
        do {
            print("\n== 1. 해설 생성 (\(explainModel)) ==")
            let explainer = GeminiExplainer(baseURL: base, apiKey: key, model: explainModel,
                                            instruction: CodeExplanation.defaultInstruction, temperature: 0.4)
            let expl = CodeExplanation.stripMarkdown(try await timed("해설") { try await collect(explainer.stream(sample, hint: "")) })
            print("  \(expl.count)자 · 첫 문장: \(expl.prefix(90))…")

            print("\n== 2. 해설 검수 (코드 vs 해설) ==")
            let r1 = try await timed("검수") { try await collect(reviewer.stream(prompt: ExplanationReview.prompt(ExplanationReview.defaultInstruction, code: sample, explanation: expl))) }
            print("  리포트 마지막 줄: \(lastLine(r1))")
            print("  → 파싱 판정: \(ReviewVerdict.parse(r1))")

            print("\n== 3. 대본 생성 (\(scriptModel)) ==")
            let norm = GeminiNormalizer(baseURL: base, apiKey: key, model: scriptModel,
                                        instruction: TextNormalizer.defaultInstruction, temperature: 0.2)
            let script = try await timed("대본") { try await collect(norm.normalizeStream(expl)) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("  \(script.count)자 · 첫 문장: \(script.prefix(90))…")

            print("\n== 4. 대본 검수 (해설 vs 대본) ==")
            let r2 = try await timed("검수") { try await collect(reviewer.stream(prompt: ScriptReview.prompt(ScriptReview.defaultInstruction, script: script, narration: expl))) }
            print("  리포트 마지막 줄: \(lastLine(r2))")
            print("  → 파싱 판정: \(ReviewVerdict.parse(r2))")

            print("\n== 5. 오염된 해설 검수 (수정 판정이 나와야 함) ==")
            let r3 = try await timed("검수") { try await collect(reviewer.stream(prompt: ExplanationReview.prompt(ExplanationReview.defaultInstruction, code: sample, explanation: contaminated))) }
            print("  리포트:\n" + r3.components(separatedBy: .newlines).map { "    " + $0 }.joined(separator: "\n"))
            let v3 = ReviewVerdict.parse(r3)
            print("  → 파싱 판정: \(v3)")

            if case .revise(let instr) = v3 {
                print("\n== 6. 수정 지시 반영 재생성 → 재검수 (앱의 자동 반영 경로와 동일한 힌트 구성) ==")
                let hint = "\n\n[현재 해설]\n\(contaminated)\n\n[검수 리포트]\n\(r3)\n\n[수정 지시 — 반드시 반영]\n\(instr)\n현재 해설을 수정 지시에 따라 고쳐, 전체 해설을 처음부터 끝까지 다시 쓰세요."
                let revised = CodeExplanation.stripMarkdown(try await timed("재생성") { try await collect(explainer.stream(sample, hint: hint)) })
                print("  수정본 첫 문장: \(revised.prefix(90))…")
                let r4 = try await timed("재검수") { try await collect(reviewer.stream(prompt: ExplanationReview.prompt(ExplanationReview.defaultInstruction, code: sample, explanation: revised))) }
                print("  리포트 마지막 줄: \(lastLine(r4))")
                print("  → 파싱 판정: \(ReviewVerdict.parse(r4))")
                let bad = ["##", "**", "[00:", "안녕하세요", "여러분", "감사합니다", "영 점 일"].filter { revised.contains($0) }
                print("  수정본에 남은 오염 표식: \(bad.isEmpty ? "없음" : bad.description)")
            }
        } catch {
            print("오류: \(error)"); exit(1)
        }
    }
}
