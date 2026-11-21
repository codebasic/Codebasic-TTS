import CryptoKit
import Foundation

// 해설 탭(기본) 의 순수 로직. 해설 본문은 외부 에이전트가 만든다. 앱은
//   1) 에이전트에 줄 지시문(AgentPrompts)과 그 조회 허용(PromptGrant),
//   2) 에이전트가 돌려준 대본의 수신함(ScriptInbox),
//   3) 화면 문구/음성 대본 한 쌍을 담는 편집기(ScriptDraft)
// 만 다룬다. 이 파일은 모델·합성·파일·소켓을 호출하지 않는다 (Foundation + CryptoKit only).

// MARK: - 지시문

enum AgentPromptKind: String, CaseIterable, Identifiable {
    case full, delta
    var id: String { rawValue }
    var label: String { self == .full ? "전체 해설" : "변경분만" }
    /// `get_tts_instructions`의 기존 profile 이름. 어댑터 계약은 그대로 둔다.
    var profileName: String { self == .full ? "explain" : "continue" }

    var defaultTemplate: String {
        let returnRules = """

        [결과 전달]
        - 결과는 채팅에 붙이지 말고 Codebasic TTS의 submit_script 도구로 한 번 제출합니다. 제출은 수신함에 쌓일 뿐 재생되지 않습니다. 사용자가 앱에서 검토한 뒤 직접 재생합니다.
        - display_text: 화면 자막으로 읽히는 해설입니다. 숫자는 숫자 그대로, 함수·변수 이름은 코드 표기 그대로 씁니다(예: as_frame, np.mean, 0.5).
        - speech_text: 같은 내용을 귀로 듣기 좋게 옮긴 낭독 대본입니다. 문장 수와 순서는 display_text와 같게 두고 읽는 법만 바꿉니다(예: as_frame → 애즈 프레임, 0.5 → 영 점 오). 발음을 바꿀 곳이 없으면 생략합니다.
        - idempotency_key: 제출마다 새로 만들고, 접수 여부가 불확실해 다시 보낼 때는 같은 키와 같은 내용을 씁니다.
        - 즉시 재생 도구 speak_text는 사용자가 지금 읽어 달라고 직접 요청한 경우에만 따로 씁니다.
        """
        switch self {
        case .full:
            return """
            지금 대화에서 다루는 코드를 강의하듯 해설해 주세요.
            - 존대말(…입니다/…합니다)로 끝맺는 자연스러운 한국어 구어체로 씁니다. 청중을 직접 부르지 않습니다.
            - 코드의 목적, 작동 방식, 주요 구성 요소를 설명합니다. 코드를 한 줄씩 낭독하거나 실행문·전체 식을 옮겨 적지 않습니다.
            - 보이지 않는 실행 결과를 추측하지 않습니다. 주석은 참고만 합니다.
            - 마크다운·코드 블록·머리말·맺음말 없이 해설 본문만 씁니다.
            """ + "\n" + returnRules
        case .delta:
            return """
            직전에 해설한 코드와 비교해, 이번에 추가·변경·삭제된 부분만 이어서 해설해 주세요.
            - 이미 설명한 부분은 반복하지 않습니다. "이번에는", "여기에 …를 추가했고"처럼 흐름을 잇습니다.
            - 존대말로 끝맺는 한국어 구어체로, 변경의 의도와 동작을 설명합니다. 코드를 낭독하거나 재현하지 않습니다.
            - 마크다운·코드 블록·머리말·맺음말 없이 해설 본문만 씁니다.
            - 의미 있는 변경이 없으면 아무것도 제출하지 말고 '변경 없음'이라고만 답합니다.
            """ + "\n" + returnRules
        }
    }
}

struct AgentPrompts: Equatable {
    private var templates: [AgentPromptKind: String] = [:]

    subscript(kind: AgentPromptKind) -> String {
        get { templates[kind] ?? kind.defaultTemplate }
        set { templates[kind] = newValue == kind.defaultTemplate ? nil : newValue }
    }

    func isCustomized(_ kind: AgentPromptKind) -> Bool { templates[kind] != nil }
    mutating func reset(_ kind: AgentPromptKind) { templates[kind] = nil }

    /// 미리보기·복사·MCP 조회가 모두 이 한 함수의 결과를 쓴다. 숨은 접두/접미는 없다:
    /// 편집한 양식이 곧 최종 문구이고, 비워 두면 기본 양식이다.
    func finalText(_ kind: AgentPromptKind) -> String {
        let text = self[kind]
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.defaultTemplate : text
    }
}

/// 사용자가 미리 본 "그 문구"를 "그 도우미 프로세스"가 읽도록 허용한 상태.
/// 허용은 읽을 수 있다는 뜻일 뿐이다. 앱은 실제로 읽혔는지, 에이전트가 무엇을 하는지 모른다.
struct PromptGrant: Equatable {
    let kind: AgentPromptKind
    let text: String          // 승인 시점의 최종 문구 (바이트 단위로 비교)
    let peerPID: Int32
    let expires: Date

    func permits(_ kind: AgentPromptKind, currentText: String, now: Date) -> Bool {
        kind == self.kind && now < expires && currentText.utf8.elementsEqual(text.utf8)
    }

    /// 지시문 한 종류의 조회 허용 상태 문구. '전송됨'·'생성 중' 같은 진행 표현은 쓰지 않는다.
    static func statusLabel(_ grant: PromptGrant?, kind: AgentPromptKind, currentText: String, now: Date) -> String {
        guard let grant, grant.permits(kind, currentText: currentText, now: now) else { return "MCP 조회 허용 안 함" }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        return "MCP 조회 허용 중 · 도우미 PID \(grant.peerPID) · \(time.string(from: grant.expires))까지"
    }
}

// MARK: - 받은 대본

struct ReceivedScript: Identifiable, Equatable {
    let id: Int
    let key: String
    let displayText: String
    let speechText: String     // "" = 별도 낭독 대본 없음
    let receivedAt: Date
    var hasSeparateSpeech: Bool { !ScriptDraft.blank(speechText) && speechText != displayText }
}

/// 에이전트 제출을 쌓아 두기만 한다. 재생하지 않고 편집기를 건드리지 않는다.
struct ScriptInbox: Equatable {
    enum Status: String { case received, duplicate, conflict, full, invalid }
    static let maxTextBytes = 12 * 1024
    static let maxItems = 20
    static let maxKeys = 128

    private(set) var items: [ReceivedScript] = []
    private var digests: [String: Data] = [:]
    private var keyOrder: [String] = []
    private var nextID = 1

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 128 && key.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    static func validText(_ text: String) -> Bool {
        text.utf8.count <= maxTextBytes && !text.contains("\0") && !ScriptDraft.blank(text)
    }

    /// 같은 키 + 같은 내용의 재시도는 `duplicate`로 한 건만 남는다. 항목을 편집기로 옮기거나
    /// 지운 뒤의 재시도도 되살리지 않는다 (최근 128개 키, 이번 실행 한정).
    mutating func submit(displayText: String, speechText: String?, key: String, now: Date) -> Status {
        guard Self.validKey(key), Self.validText(displayText),
              speechText.map(Self.validText) ?? true else { return .invalid }
        let speech = speechText ?? ""
        let digest = Data(SHA256.hash(data: Data("script-v1\0\(displayText)\0\(speech)".utf8)))
        if let known = digests[key] { return known == digest ? .duplicate : .conflict }
        guard items.count < Self.maxItems else { return .full }   // 키를 기억하지 않아 나중에 재시도할 수 있다
        digests[key] = digest
        keyOrder.append(key)
        if keyOrder.count > Self.maxKeys { digests.removeValue(forKey: keyOrder.removeFirst()) }
        items.append(ReceivedScript(id: nextID, key: key, displayText: displayText, speechText: speech, receivedAt: now))
        nextID += 1
        return .received
    }

    mutating func remove(_ id: Int) { items.removeAll { $0.id == id } }
    mutating func removeAll() { items.removeAll() }
}

// MARK: - 편집기 (화면 문구 + 음성 대본)

/// 화면에는 `as_frame`, 음성에는 '애즈 프레임'. 음성 대본은 "어느 화면 문구에 맞춰
/// 쓰였는지"를 함께 기억한다. 화면 문구가 그와 달라지면 stale이고, stale인 음성
/// 대본은 사용자가 명시적으로 고르기 전에는 재생 계획에 들어가지 않는다.
struct ScriptDraft: Equatable {
    private(set) var displayText = ""
    private(set) var speechText = ""
    private(set) var pairedDisplay: String?

    enum SpeechState: Equatable { case none, matched, stale }
    enum StaleChoice: Equatable { case readDisplay, keepOldSpeech }
    enum Plan: Equatable {
        case nothing
        case needsConfirmation
        case speak(spoken: String, display: String)
    }

    static func blank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEmpty: Bool { Self.blank(displayText) && Self.blank(speechText) }

    var speechState: SpeechState {
        if Self.blank(speechText) { return .none }
        return pairedDisplay == displayText ? .matched : .stale
    }

    mutating func setDisplay(_ text: String) { displayText = text }

    /// 비어 있던 음성 대본을 사용자가 새로 쓰면 현재 화면 문구에 맞춘 것으로 본다.
    /// 이미 어긋난(stale) 대본을 고치는 것만으로는 맞춤 상태가 되지 않는다 — `confirmSpeechMatches()`.
    mutating func setSpeech(_ text: String) {
        let wasBlank = Self.blank(speechText)
        speechText = text
        if Self.blank(text) { pairedDisplay = nil } else if wasBlank { pairedDisplay = displayText }
    }

    mutating func confirmSpeechMatches() {
        if !Self.blank(speechText) { pairedDisplay = displayText }
    }

    mutating func discardSpeech() { speechText = ""; pairedDisplay = nil }

    func wouldOverwrite(with item: ReceivedScript) -> Bool {
        !isEmpty && !(displayText == item.displayText && speechText == item.speechText)
    }

    mutating func load(_ item: ReceivedScript) {
        displayText = item.displayText
        speechText = item.speechText
        pairedDisplay = Self.blank(item.speechText) ? nil : item.displayText
    }

    /// 직접 붙여넣기: 화면 문구만 들어오고 음성 대본은 없다.
    mutating func paste(_ text: String) { displayText = text; discardSpeech() }

    mutating func clear() { self = ScriptDraft() }

    /// 합성에 넘길 문자열을 그대로 정한다. 어떤 경우에도 문구를 다시 쓰지 않는다.
    func playbackPlan(staleChoice: StaleChoice? = nil) -> Plan {
        guard !Self.blank(displayText) else { return .nothing }
        switch speechState {
        case .none: return .speak(spoken: displayText, display: displayText)
        case .matched: return .speak(spoken: speechText, display: displayText)
        case .stale:
            switch staleChoice {
            case nil: return .needsConfirmation
            case .readDisplay?: return .speak(spoken: displayText, display: displayText)
            case .keepOldSpeech?: return .speak(spoken: speechText, display: displayText)
            }
        }
    }
}
