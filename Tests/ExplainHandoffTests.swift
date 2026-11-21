// Pure-logic tests for Core/ExplainHandoff.swift (no app, model, socket or synthesis).
import Foundation

var failures = 0, checks = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if cond { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name)  \(detail())") }
}
func eq<T: Equatable>(_ name: String, _ a: T, _ b: T) { check(name, a == b, "got \(a), want \(b)") }

@main struct ExplainHandoffTests {
    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let visual = "as_frame 옵션을 켜면 데이터프레임을 반환합니다."
        let spoken = "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다."

        print("지시문 — 편집·초기화, 하나의 최종 문구")
        var prompts = AgentPrompts()
        eq("기본값은 customized 아님", AgentPromptKind.allCases.map(prompts.isCustomized), [false, false])
        check("두 양식의 기본 문구는 다르다", prompts.finalText(.full) != prompts.finalText(.delta))
        check("기본 양식은 submit_script 반환 규칙을 눈에 보이게 포함", AgentPromptKind.allCases.allSatisfy {
            prompts.finalText($0).contains("submit_script") && prompts.finalText($0).contains("speech_text")
        })
        prompts[.full] = "SYNTHETIC 전체 해설 지시"
        eq("편집한 양식이 곧 최종 문구 (숨은 접두·접미 없음)", prompts.finalText(.full), "SYNTHETIC 전체 해설 지시")
        eq("다른 양식은 그대로", prompts.finalText(.delta), AgentPromptKind.delta.defaultTemplate)
        prompts[.full] = "  \n "
        eq("비우면 기본 양식", prompts.finalText(.full), AgentPromptKind.full.defaultTemplate)
        prompts[.full] = "SYNTHETIC"; prompts.reset(.full)
        check("초기화", !prompts.isCustomized(.full) && prompts[.full] == AgentPromptKind.full.defaultTemplate)
        eq("profile 이름은 기존 어댑터 계약 유지", AgentPromptKind.allCases.map(\.profileName), ["explain", "continue"])

        print("조회 허용 — 그 문구, 그 양식만; 진행 상태로 표시하지 않음")
        let approved = "SYNTHETIC 승인 문구 café"
        let grant = PromptGrant(kind: .full, text: approved, peerPID: 4242, expires: t0.addingTimeInterval(600))
        check("승인한 양식·문구는 허용", grant.permits(.full, currentText: approved, now: t0))
        check("다른 양식은 허용 안 함", !grant.permits(.delta, currentText: approved, now: t0))
        check("문구가 바뀌면 허용 안 함", !grant.permits(.full, currentText: approved + "!", now: t0))
        check("정준 등가여도 바이트가 다르면 허용 안 함",
              !grant.permits(.full, currentText: approved.replacingOccurrences(of: "caf\u{00E9}", with: "cafe\u{0301}"), now: t0))
        check("만료 후 허용 안 함", !grant.permits(.full, currentText: approved, now: t0.addingTimeInterval(600)))
        let labels = [
            PromptGrant.statusLabel(nil, kind: .full, currentText: approved, now: t0),
            PromptGrant.statusLabel(grant, kind: .full, currentText: approved, now: t0),
            PromptGrant.statusLabel(grant, kind: .delta, currentText: approved, now: t0),
            PromptGrant.statusLabel(grant, kind: .full, currentText: "changed", now: t0),
        ]
        check("허용 중 표시는 PID 포함", labels[1].contains("허용 중") && labels[1].contains("4242"))
        eq("미허용·다른 양식·바뀐 문구는 모두 ‘허용 안 함’", [labels[0], labels[2], labels[3]], Array(repeating: "MCP 조회 허용 안 함", count: 3))
        check("어떤 표시도 전송됨/생성 중/완료를 말하지 않음", labels.allSatisfy { label in
            ["전송", "생성", "보냄", "완료", "읽음"].allSatisfy { !label.contains($0) }
        })

        print("받은 대본 — 쌓기만, 재시도는 한 건")
        var inbox = ScriptInbox()
        eq("첫 제출", inbox.submit(displayText: visual, speechText: spoken, key: "k-1", now: t0), .received)
        eq("같은 키·같은 내용 재시도", inbox.submit(displayText: visual, speechText: spoken, key: "k-1", now: t0), .duplicate)
        eq("재시도 후에도 한 건", inbox.items.count, 1)
        eq("같은 키·다른 내용", inbox.submit(displayText: visual, speechText: nil, key: "k-1", now: t0), .conflict)
        eq("충돌은 저장된 내용을 바꾸지 않음", inbox.items.map(\.speechText), [spoken])
        eq("두 번째 제출", inbox.submit(displayText: "둘째 해설입니다.", speechText: nil, key: "k-2", now: t0), .received)
        eq("도착 순서 유지", inbox.items.map(\.key), ["k-1", "k-2"])
        check("음성 대본 유무 표시", inbox.items[0].hasSeparateSpeech && !inbox.items[1].hasSeparateSpeech)
        let firstID = inbox.items[0].id
        inbox.remove(firstID)
        eq("편집기로 옮기거나 지운 뒤의 재시도도 되살리지 않음", inbox.submit(displayText: visual, speechText: spoken, key: "k-1", now: t0), .duplicate)
        eq("…여전히 한 건", inbox.items.map(\.key), ["k-2"])
        for bad in [("", "ok"), ("  \n", "ok"), ("a\0b", "ok"), (visual, ""), (visual, "bad key"), (visual, String(repeating: "k", count: 129)),
                    (String(repeating: "가", count: ScriptInbox.maxTextBytes / 3 + 1), "ok")] {
            eq("거부: \(bad.0.prefix(6).debugDescription)/\(bad.1.prefix(8))", inbox.submit(displayText: bad.0, speechText: nil, key: bad.1, now: t0), .invalid)
        }
        eq("공백뿐인 음성 대본 거부", inbox.submit(displayText: visual, speechText: " ", key: "k-3", now: t0), .invalid)
        eq("거부된 제출은 쌓이지 않음", inbox.items.count, 1)
        var filling = ScriptInbox()
        for i in 0..<ScriptInbox.maxItems { _ = filling.submit(displayText: "항목 \(i)", speechText: nil, key: "f-\(i)", now: t0) }
        eq("가득 차면 full", filling.submit(displayText: "넘침", speechText: nil, key: "over", now: t0), .full)
        filling.remove(filling.items[0].id)
        eq("full이던 키는 자리가 나면 다시 받을 수 있음", filling.submit(displayText: "넘침", speechText: nil, key: "over", now: t0), .received)

        print("편집기 — 도착과 분리, 화면/음성 한 쌍")
        var draft = ScriptDraft()
        eq("빈 편집기는 재생할 것이 없음", draft.playbackPlan(), .nothing)
        var box = ScriptInbox()
        _ = box.submit(displayText: visual, speechText: spoken, key: "a", now: t0)
        check("빈 편집기에는 확인 없이 불러옴", !draft.wouldOverwrite(with: box.items[0]))
        draft.load(box.items[0])
        eq("불러온 직후 상태", draft.speechState, .matched)
        eq("화면에는 as_frame, 음성에는 애즈 프레임", draft.playbackPlan(), .speak(spoken: spoken, display: visual))
        _ = box.submit(displayText: "두 번째 도착", speechText: nil, key: "b", now: t0)
        draft.setDisplay(visual + " 수정")
        check("편집 중 두 번째 도착은 편집기를 바꾸지 않음", draft.displayText == visual + " 수정" && draft.speechText == spoken)
        check("편집 중인 내용이 있으면 불러오기는 확인이 필요", draft.wouldOverwrite(with: box.items[1]))

        print("화면 문구 수정 → 음성 대본 stale, 확인 없이는 재생 계획 없음")
        eq("화면 문구를 고치면 stale", draft.speechState, .stale)
        eq("확인 없이는 합성 대상이 없음", draft.playbackPlan(), .needsConfirmation)
        eq("명시 선택: 화면 문구 그대로", draft.playbackPlan(staleChoice: .readDisplay), .speak(spoken: visual + " 수정", display: visual + " 수정"))
        eq("명시 선택: 이전 음성 대본", draft.playbackPlan(staleChoice: .keepOldSpeech), .speak(spoken: spoken, display: visual + " 수정"))
        draft.setSpeech(spoken + " 수정")
        eq("stale 대본을 고치는 것만으로는 맞춤이 되지 않음", draft.speechState, .stale)
        draft.confirmSpeechMatches()
        eq("사용자가 맞다고 표시하면 matched", draft.playbackPlan(), .speak(spoken: spoken + " 수정", display: visual + " 수정"))
        draft.setDisplay(visual)
        eq("다시 고치면 다시 stale", draft.speechState, .stale)
        draft.setDisplay(visual + " 수정")
        eq("원래 문구로 되돌리면 matched", draft.speechState, .matched)
        draft.setDisplay("전혀 다른 문구")
        draft.discardSpeech()
        eq("음성 대본을 버리면 화면 문구를 읽음", draft.playbackPlan(), .speak(spoken: "전혀 다른 문구", display: "전혀 다른 문구"))
        draft.setSpeech("새로 쓴 낭독 대본")
        eq("비어 있던 음성 대본을 새로 쓰면 현재 문구에 맞춘 것", draft.speechState, .matched)
        draft.paste("붙여넣은 문구")
        check("직접 붙여넣기: 화면 문구만, 이전 음성 대본은 남지 않음", draft.displayText == "붙여넣은 문구" && draft.speechState == .none)
        eq("붙여넣은 문구는 그대로 읽힘", draft.playbackPlan(), .speak(spoken: "붙여넣은 문구", display: "붙여넣은 문구"))
        var literal = ScriptDraft()
        literal.paste("  k\nk는 0.5입니다  ")
        eq("문구를 다듬지 않음 (공백·줄바꿈 포함 그대로)", literal.playbackPlan(), .speak(spoken: "  k\nk는 0.5입니다  ", display: "  k\nk는 0.5입니다  "))

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("Explain handoff tests passed (\(checks) checks).")

    }
}
