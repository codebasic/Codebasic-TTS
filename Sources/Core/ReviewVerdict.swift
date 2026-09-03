import Foundation

/// 검수 리포트의 판정 파싱 (순수 로직 — Foundation만, 테스트 대상).
///
/// 검수 프롬프트는 마지막 줄에 정확히 '판정: 통과' 또는 '판정: 수정 — <지시>'를
/// 쓰도록 요구한다. 이 파서가 그 줄을 읽어 자동 반영 여부를 결정한다.
/// 판정 줄이 없으면: 리포트가 '문제 없음'으로 시작할 때만 통과, 그 외엔 .none
/// (자동 반영하지 않고 리포트만 보여 준다 — 판정 없는 리포트로 재생성하지 않는다).
enum ReviewVerdict: Equatable {
    case pass
    case revise(String)     // 수정 지시 (명시 지시가 없으면 리포트 본문 전체)
    case none

    var label: String {
        switch self {
        case .pass: return "통과"
        case .revise: return "수정 필요"
        case .none: return "판정 없음"
        }
    }

    static func parse(_ report: String) -> ReviewVerdict {
        let lines = report.components(separatedBy: .newlines)
        for raw in lines.reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let rest = verdictTail(line) else { continue }
            let r = rest.trimmingCharacters(in: .whitespaces)
            if r.hasPrefix("통과") || r.lowercased().hasPrefix("pass") { return .pass }
            if r.hasPrefix("수정") || r.lowercased().hasPrefix("revise") {
                let keyword = r.hasPrefix("수정") ? "수정" : "revise"
                var instr = String(r.dropFirst(keyword.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t—–-:：*"))
                if instr.isEmpty {
                    // 지시가 비면 본문(판정 줄 제외)을 지시로 쓴다 — 지적 사항 자체가 지시다.
                    instr = lines
                        .filter { verdictTail($0.trimmingCharacters(in: .whitespaces)) == nil }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return instr.isEmpty ? .none : .revise(instr)
            }
            return .none
        }
        let t = report.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("문제 없음") ? .pass : .none
    }

    /// '판정:' 접두(마크다운 굵게·글머리 허용)를 떼고 나머지를 돌려준다. 아니면 nil.
    private static func verdictTail(_ line: String) -> String? {
        var l = line
        while let f = l.first, "*#-• \t".contains(f) { l.removeFirst() }
        guard l.hasPrefix("판정") else { return nil }
        l = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard let c = l.first, c == ":" || c == "：" else { return nil }
        return String(l.dropFirst()).replacingOccurrences(of: "**", with: "")
    }
}

/// 검수 단계를 거친 결과에 캐시와 함께 남기는 표시. 표시가 없는 캐시 항목은
/// "생성 당시 검수를 마치지 못한 결과"이므로 캐시 적중 시 그때 검수한다.
enum ReviewMark: String, Equatable {
    case pass                        // 첫 검수 통과
    case revisedPass = "revised"     // '수정' → 지시 반영 재생성 → 재검수 통과
    case revisedFlagged = "flagged"  // '수정' → 재생성 → 재검수도 '수정' → 원본 유지 + 플래그
    case reviseUnapplied = "revise"  // '수정' 판정이지만 반영 안 됨(자동 반영 꺼짐·재생성 실패) → 원본

    var summary: String {
        switch self {
        case .pass: return "통과"
        case .revisedPass: return "수정 반영 후 통과"
        case .revisedFlagged: return "재검수 미통과 — 원본 유지"
        case .reviseUnapplied: return "수정 필요 (미반영)"
        }
    }
    /// 캐시 적중 시 배지에 보일 판정.
    var verdict: ReviewVerdict {
        switch self {
        case .pass, .revisedPass: return .pass
        case .revisedFlagged, .reviseUnapplied: return .revise(summary)
        }
    }
    var flagged: Bool { self == .revisedFlagged }
}

/// 검수(+자동 반영) 단계의 최종 결과. `mark == nil`이면 판정을 얻지 못한 것
/// (키 없음·오류·취소·판정 줄 없음) — 캐시에 검수 표시를 남기지 않는다.
struct ReviewOutcome {
    var text: String
    var mark: ReviewMark?
    var notice: String = ""   // 호출자가 상태줄에 남길 최종 메시지 (빈 문자열이면 상태줄을 비운다)
}
