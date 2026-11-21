import AppKit
import Foundation

/// 해설 탭 기본 동작: 에이전트 지시문, 받은 대본, 화면/음성 한 쌍 재생.
/// 여기의 어떤 경로도 LLM(해설·정규화·모델 목록)을 호출하지 않는다. 합성은
/// 사용자가 재생을 누른 `playAgentScript`에서만 시작한다.
extension AppState {

    // MARK: 지시문

    /// 미리보기·복사·MCP 조회 공통의 최종 문구.
    func agentPromptFinalText(_ kind: AgentPromptKind) -> String { agentPrompts.finalText(kind) }

    func setAgentPrompt(_ kind: AgentPromptKind, _ text: String) {
        guard agentPrompts[kind] != text else { return }
        agentPrompts[kind] = text
        revokeGrantIfOutdated()
        saveSettings()
    }

    func resetAgentPrompt(_ kind: AgentPromptKind) {
        guard agentPrompts.isCustomized(kind) else { return }
        agentPrompts.reset(kind)
        revokeGrantIfOutdated()
        saveSettings()
    }

    func copyAgentPrompt(_ kind: AgentPromptKind, to board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(agentPromptFinalText(kind), forType: .string)
    }

    func promptGrantLabel(_ kind: AgentPromptKind, now: Date = Date()) -> String {
        PromptGrant.statusLabel(promptGrant, kind: kind, currentText: agentPromptFinalText(kind), now: now)
    }

    func promptGrantActive(_ kind: AgentPromptKind, now: Date = Date()) -> Bool {
        promptGrant?.permits(kind, currentText: agentPromptFinalText(kind), now: now) ?? false
    }

    /// 허용한 문구가 한 바이트라도 달라지면 허용을 거둔다. 되돌려도 다시 승인해야 한다.
    private func revokeGrantIfOutdated() {
        guard let grant = promptGrant,
              !agentPromptFinalText(grant.kind).utf8.elementsEqual(grant.text.utf8) else { return }
        promptGrant = nil
        onRevokePromptGrant?()
    }

    // MARK: 받은 대본

    /// `submit_script` 도착. 쌓기만 한다: 재생·편집기·재생 상태는 건드리지 않는다.
    func receiveAgentScript(displayText: String, speechText: String?, key: String, now: Date = Date()) -> String {
        scriptInbox.submit(displayText: displayText, speechText: speechText, key: key, now: now).rawValue
    }

    /// 수신함 항목을 편집기로 옮긴다. 편집 중인 다른 내용이 있으면 `replace: true`가
    /// 있어야만 덮어쓴다. 옮긴 항목은 수신함에서 빠진다.
    @discardableResult
    func loadReceivedScript(_ id: Int, replace: Bool = false) -> Bool {
        guard let item = scriptInbox.items.first(where: { $0.id == id }) else { return false }
        if agentDraft.wouldOverwrite(with: item) && !replace { return false }
        agentDraft.load(item)
        scriptInbox.remove(id)
        return true
    }

    func discardReceivedScript(_ id: Int) { scriptInbox.remove(id) }

    // MARK: 편집기

    func setAgentDisplayText(_ text: String) { if agentDraft.displayText != text { agentDraft.setDisplay(text) } }
    func setAgentSpeechText(_ text: String) { if agentDraft.speechText != text { agentDraft.setSpeech(text) } }
    func confirmAgentSpeechMatches() { agentDraft.confirmSpeechMatches() }
    func discardAgentSpeech() { agentDraft.discardSpeech() }
    func clearAgentDraft() { agentDraft.clear() }

    /// 직접 붙여넣기 (에이전트·MCP 없이도 쓸 수 있는 경로).
    @discardableResult
    func pasteAgentScriptFromClipboard(replace: Bool = false, from board: NSPasteboard = .general) -> Bool {
        guard let text = board.string(forType: .string), !ScriptDraft.blank(text) else { return false }
        if !agentDraft.isEmpty && agentDraft.displayText != text && !replace { return false }
        agentDraft.paste(text)
        return true
    }

    /// 사용자가 누른 재생. 화면 문구가 바뀌어 음성 대본이 어긋났으면 `staleChoice` 없이는
    /// 아무것도 합성하지 않고 `.needsConfirmation`을 돌려준다. 넘기는 문자열은 편집기에
    /// 보이는 그대로다 (정규화·정리 없음).
    @discardableResult
    func playAgentScript(staleChoice: ScriptDraft.StaleChoice? = nil) -> ScriptDraft.Plan {
        let plan = agentDraft.playbackPlan(staleChoice: staleChoice)
        if case let .speak(spoken, display) = plan {
            playbackMode = .explain
            synthesize(spoken, displayText: display, preserveLiteral: true)
        }
        return plan
    }

    // MARK: 고급 (앱 내 해설 생성)

    /// 단축키·Services ‘코드 해설’ 진입점. 고급 설정이 꺼져 있으면 생성하지 않고
    /// 선택한 코드만 고급 패널의 코드 칸에 둔다. 생성을 시작했으면 true.
    @discardableResult
    func externalExplainRequest(_ code: String) -> Bool {
        guard inAppExplainShortcuts else {
            codeText = code
            statusText = "앱 내 해설 생성은 꺼져 있습니다 — 선택한 코드는 해설 탭 ‘고급’에 옮겨 두었습니다"
            return false
        }
        explainAndSpeak(code)
        return true
    }
}
