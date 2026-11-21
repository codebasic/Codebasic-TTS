import AppKit
import Darwin
import Foundation
import ObjectiveC
import SwiftUI

/// Compiler fixture for the 해설 tab handoff. The runner copies the app sources and replaces
/// only the provider factories, the model-list fetch, the settings location and the socket
/// directory. Everything else is the production AppState / AppDelegate / sockets / view.
enum AgentScriptCase {
    static let visual = "as_frame 옵션을 켜면 데이터프레임을 반환합니다."
    static let spoken = "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다."
    static let log = Capture()

    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var speech: [String] = [], normalized = 0, explainers = 0, modelQueries = 0
        func recordSpeech(_ text: String) { lock.lock(); speech.append(text); lock.unlock() }
        func recordNormalize() { lock.lock(); normalized += 1; lock.unlock() }
        func recordExplainer() { lock.lock(); explainers += 1; lock.unlock() }
        func recordModelQuery() { lock.lock(); modelQueries += 1; lock.unlock() }
        var payloads: [String] { lock.lock(); defer { lock.unlock() }; return speech }
        var llmCalls: [Int] { lock.lock(); defer { lock.unlock() }; return [normalized, explainers, modelQueries] }
    }

    struct FakeNormalizer: Normalizing {
        func normalizeStream(_ text: String) -> AsyncThrowingStream<String, Error> {
            log.recordNormalize()
            return AsyncThrowingStream { $0.yield("REWRITTEN BY FAKE MODEL"); $0.finish() }
        }
    }

    struct CaptureOnlyEngine: TTSBackend {
        let identity = "capture-only-agent-script-case"
        enum End: Error { case payloadCaptured }
        func stream(segment: String, voice: VoiceConfig) -> AsyncThrowingStream<Data, Error> {
            log.recordSpeech(segment)   // no audio; tests inspect the exact synthesis input
            return AsyncThrowingStream { $0.finish(throwing: End.payloadCaptured) }
        }
    }

    @MainActor static var alertResponses: [(NSAlert) -> NSApplication.ModalResponse] = []

    /// One newline-terminated request to a unix socket; nil when nothing listens or nothing is answered.
    static func ask(_ path: String, _ object: [String: Any]) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in bytes.withUnsafeBytes { dst.copyBytes(from: $0) } }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var frame = try! JSONSerialization.data(withJSONObject: object)
        frame.append(10)
        _ = frame.withUnsafeBytes { send(fd, $0.baseAddress!, $0.count, 0) }
        shutdown(fd, SHUT_WR)
        var reply = Data(), chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            reply.append(contentsOf: chunk[..<n])
        }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }
}

extension NSAlert {
    @MainActor @objc func cbttsAgentFixtureModal() -> Int {
        guard !AgentScriptCase.alertResponses.isEmpty else { preconditionFailure("Unexpected alert: \(messageText)") }
        return AgentScriptCase.alertResponses.removeFirst()(self).rawValue
    }
}

@main struct AgentScriptCaseTests {
    typealias Case = AgentScriptCase

    @MainActor static func settle(_ seconds: Double = 0.15) async {
        // Socket handlers hop to the main queue, so yield instead of blocking it.
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor static func awaitPayloads(_ app: AppState, _ count: Int) async {
        for _ in 0..<300 {
            if Case.log.payloads.count >= count && app.phase == .idle { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Expected \(count) synthesis payloads, have \(Case.log.payloads)")
    }

    /// The socket's handler needs the main queue, so the blocking client runs off it.
    static func ask(_ path: String, _ object: [String: Any]) async -> [String: Any]? {
        let frame = try! JSONSerialization.data(withJSONObject: object)
        return await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let request = try! JSONSerialization.jsonObject(with: frame) as! [String: Any]
                let reply = Case.ask(path, request).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                DispatchQueue.main.async {
                    done.resume(returning: reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                }
            }
        }
    }

    @MainActor static func expectStatus(_ path: String, _ object: [String: Any], _ status: String) async {
        let reply = await ask(path, object)
        precondition(reply?["status"] as? String == status, "want \(status), got \(String(describing: reply))")
    }

    @MainActor static func expectSilent(_ path: String, _ object: [String: Any]) async {
        let reply = await ask(path, object)
        precondition(reply == nil, "expected no answer, got \(String(describing: reply))")
    }

    @MainActor static func main() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let root = ProcessInfo.processInfo.environment["TTS_AGENT_FIXTURE_ROOT"]!
        let endpointID = "00000000-0000-4000-8000-0000000000E1"
        let settings: [String: Any] = [
            "backend": "local", "useCache": false, "normalize": true, "glossary": [],
            "explainEndpointID": endpointID, "scriptEndpointID": endpointID,
            // An enabled endpoint with no fetched models: any view that asks for the model
            // list would reach the (replaced) refreshEndpointModels and be counted.
            "endpoints": [["id": endpointID, "name": "SYNTHETIC", "baseURL": "http://127.0.0.1:9",
                           "apiStyle": "ollama", "isEnabled": true, "defaultModel": "synthetic-model"]],
        ]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: URL(fileURLWithPath: Secrets.appSupportDir).appendingPathComponent("settings.json"))
        guard let system = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal)),
              let fake = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.cbttsAgentFixtureModal)) else {
            preconditionFailure("NSAlert method unavailable")
        }
        method_exchangeImplementations(system, fake)

        let delegate = AppDelegate()
        let app = delegate.appState
        delegate.agentScriptFixtureSetUp()
        precondition(app.normalizeEnabled && app.endpoints.count == 1 && !app.inAppExplainShortcuts)
        precondition(Case.log.llmCalls == [0, 0, 0])

        // 1. 기본 탭을 여는 것만으로는 모델을 조회하지 않는다 (고급을 열면 조회 — 양성 대조).
        let host = NSHostingView(rootView: ExplainTabView().environmentObject(app))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await settle(0.4)
        precondition(Case.log.llmCalls == [0, 0, 0], "default tab queried a model: \(Case.log.llmCalls)")
        app.explainAdvancedVisible = true
        host.layoutSubtreeIfNeeded()
        await settle(0.4)
        let advancedQueries = Case.log.llmCalls[2]
        app.explainAdvancedVisible = false
        host.layoutSubtreeIfNeeded()
        await settle(0.2)
        window.contentView = nil
        precondition(!window.isVisible && application.windows.allSatisfy { !$0.isVisible })
        print(advancedQueries > 0
              ? "default tab: 0 model queries, 0 generations; opening 고급 queried the model list (positive control)"
              : "default tab: 0 model queries — UNVERIFIED: offscreen view never ran onAppear (positive control also 0)")
        let baseline = Case.log.llmCalls

        // 2. 무음 도착: 수신 소켓으로 들어온 대본은 쌓이기만 한다.
        let inboxSocket = root + "/r.sock"
        precondition(!FileManager.default.fileExists(atPath: inboxSocket) && !app.scriptInboxEnabled)
        app.onToggleScriptInbox?()
        precondition(app.scriptInboxEnabled && FileManager.default.fileExists(atPath: inboxSocket))
        let first: [String: Any] = ["display_text": Case.visual, "speech_text": Case.spoken, "idempotency_key": "fixture-1"]
        let arrival = await ask(inboxSocket, first)
        precondition(arrival?["status"] as? String == "received", "\(String(describing: arrival))")
        await settle()
        precondition(app.scriptInbox.items.count == 1 && app.agentDraft.isEmpty)
        precondition(app.phase == .idle && Case.log.payloads.isEmpty && app.subtitleText.isEmpty && app.currentText.isEmpty)
        precondition(Case.log.llmCalls == baseline)
        print("silent arrival: stored 1, synthesis payloads 0, phase idle, editor empty, no model call")

        // 3. 동일 요청 재시도는 한 건. 같은 키의 다른 내용은 거부.
        await expectStatus(inboxSocket, first, "duplicate")
        var changed = first; changed["speech_text"] = "다른 낭독"
        await expectStatus(inboxSocket, changed, "conflict")
        await expectStatus(inboxSocket, ["text": "읽어", "idempotency_key": "speak"], "invalid")
        precondition(app.scriptInbox.items.count == 1 && app.scriptInbox.items[0].speechText == Case.spoken)
        print("retry: same key+content → duplicate, still 1 item; changed content → conflict; speak_text frame → invalid")

        // 4. 편집 중 두 번째 도착은 편집기를 덮어쓰지 않는다.
        precondition(app.loadReceivedScript(app.scriptInbox.items[0].id))
        precondition(app.scriptInbox.items.isEmpty && app.agentDraft.speechState == .matched)
        let editing = Case.visual + " (편집 중)"
        app.setAgentDisplayText(editing)
        let second: [String: Any] = ["display_text": "두 번째로 도착한 해설입니다.", "idempotency_key": "fixture-2"]
        await expectStatus(inboxSocket, second, "received")
        await settle()
        precondition(app.agentDraft.displayText == editing && app.agentDraft.speechText == Case.spoken)
        precondition(app.scriptInbox.items.count == 1 && Case.log.payloads.isEmpty && app.phase == .idle)
        let secondID = app.scriptInbox.items[0].id
        precondition(!app.loadReceivedScript(secondID))                     // needs explicit replace
        precondition(app.agentDraft.displayText == editing && app.scriptInbox.items.count == 1)
        await expectStatus(inboxSocket, first, "duplicate")   // already moved to the editor
        precondition(app.scriptInbox.items.count == 1)
        print("second arrival while editing: editor untouched, load refused without replace, retry of moved item not re-added")

        // 5. 화면 문구 수정 후: 확인 없이는 이전 음성 대본을 재생하지 않는다.
        precondition(app.agentDraft.speechState == .stale)
        precondition(app.playAgentScript() == .needsConfirmation)
        await settle(0.2)
        precondition(Case.log.payloads.isEmpty && app.phase == .idle)
        app.setAgentDisplayText(Case.visual)                                 // back to the paired wording
        precondition(app.playAgentScript() == .speak(spoken: Case.spoken, display: Case.visual))
        await awaitPayloads(app, 1)
        precondition(Case.log.payloads == [Case.spoken] && app.subtitleText == Case.visual && app.playbackMode == .explain)
        precondition(!Case.log.payloads[0].contains("as_frame") && app.subtitleText.contains("as_frame"))
        app.setAgentDisplayText(editing)
        precondition(app.playAgentScript(staleChoice: .readDisplay) == .speak(spoken: editing, display: editing))
        await awaitPayloads(app, 2)
        precondition(app.playAgentScript(staleChoice: .keepOldSpeech) == .speak(spoken: Case.spoken, display: editing))
        await awaitPayloads(app, 3)
        precondition(Case.log.payloads == [Case.spoken, editing, Case.spoken] && app.subtitleText == editing)
        precondition(Case.log.llmCalls == baseline, "agent playback called a model: \(Case.log.llmCalls)")
        print("screen/speech: subtitle=as_frame, speech=애즈 프레임; stale speech not played without an explicit choice; no rewrite (normalize ON, 0 calls)")

        // 6. 직접 붙여넣기 (전용 pasteboard — 사용자 클립보드는 건드리지 않는다).
        let board = NSPasteboard(name: NSPasteboard.Name("cbtts-agent-fixture-\(getpid())"))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("  직접 붙여넣은\n해설입니다.  ", forType: .string)
        precondition(!app.pasteAgentScriptFromClipboard(from: board))        // editor has other content
        precondition(app.pasteAgentScriptFromClipboard(replace: true, from: board))
        precondition(app.agentDraft.speechState == .none)
        precondition(app.playAgentScript() == .speak(spoken: "  직접 붙여넣은\n해설입니다.  ", display: "  직접 붙여넣은\n해설입니다.  "))
        await awaitPayloads(app, 4)
        // The capture engine ends the run at the first paragraph chunk; that chunk is the literal text.
        precondition(Case.log.payloads[3] == "직접 붙여넣은" && app.subtitleText == "  직접 붙여넣은\n해설입니다.  ")
        print("direct paste: kept, replaced only with confirmation, read literally")

        // 7. 지시문: 미리보기 = 복사 = MCP 조회, 해당 양식만, 문구 수정·철회 시 차단.
        let instructionSocket = root + "/i.sock"
        app.setAgentPrompt(.delta, "SYNTHETIC 변경분만 지시: as_frame은 화면 표기 그대로 둡니다.\n")
        let final = app.agentPromptFinalText(.delta)
        app.copyAgentPrompt(.delta, to: board)
        precondition(board.string(forType: .string) == final)
        var previewed = ""
        let select: (NSAlert) -> NSApplication.ModalResponse = { alert in
            let fields = alert.accessoryView?.subviews ?? []
            guard let pid = fields.first(where: { $0 is NSTextField }) as? NSTextField,
                  let profile = fields.first(where: { $0 is NSPopUpButton }) as? NSPopUpButton else { preconditionFailure() }
            precondition(profile.indexOfSelectedItem == 1)                   // the tab's own kind is preselected
            pid.stringValue = String(getpid())
            return .alertFirstButtonReturn
        }
        let confirm: (NSAlert) -> NSApplication.ModalResponse = { alert in
            guard let scroll = alert.accessoryView as? NSScrollView, let view = scroll.documentView as? NSTextView else { preconditionFailure() }
            previewed = view.string
            return .alertFirstButtonReturn
        }
        func grantDelta() {
            Case.alertResponses = [select, confirm]
            app.onRequestPromptGrant?(.delta)
            precondition(Case.alertResponses.isEmpty)
        }
        precondition(app.promptGrant == nil && !FileManager.default.fileExists(atPath: instructionSocket))
        Case.alertResponses = [select, { _ in .alertSecondButtonReturn }]
        app.onRequestPromptGrant?(.delta)                                     // previewed, then cancelled
        precondition(app.promptGrant == nil && !FileManager.default.fileExists(atPath: instructionSocket))
        grantDelta()
        precondition(previewed == final && app.promptGrantActive(.delta) && !app.promptGrantActive(.full))
        let label = app.promptGrantLabel(.delta)
        precondition(label.contains("허용 중") && ["전송", "생성", "완료", "읽음"].allSatisfy { !label.contains($0) })
        precondition(app.promptGrantLabel(.full) == "MCP 조회 허용 안 함")
        let fetched = await ask(instructionSocket, ["profile": "continue"])
        precondition(fetched?["instructions"] as? String == final, "\(String(describing: fetched))")
        await expectSilent(instructionSocket, ["profile": "explain"])      // the other 양식 is not readable
        await expectSilent(instructionSocket, ["profile": "normalize"])
        precondition(app.phase == .idle && Case.log.llmCalls == baseline && Case.log.payloads.count == 4)
        print("prompt: preview == copy == MCP read; only the approved 양식; reading starts no model/synthesis")

        app.setAgentPrompt(.delta, final + "수정")                             // edit revokes
        precondition(app.promptGrant == nil && !FileManager.default.fileExists(atPath: instructionSocket))
        app.setAgentPrompt(.delta, final)                                     // undo does not restore consent
        precondition(app.promptGrant == nil && !FileManager.default.fileExists(atPath: instructionSocket))
        await expectSilent(instructionSocket, ["profile": "continue"])
        grantDelta()
        app.setAgentPrompt(.full, "SYNTHETIC 전체 해설 지시")                    // editing the OTHER 양식 keeps this grant
        precondition(app.promptGrantActive(.delta))
        app.onRevokePromptGrant?()                                            // 승인 철회
        precondition(app.promptGrant == nil && !FileManager.default.fileExists(atPath: instructionSocket))
        await expectSilent(instructionSocket, ["profile": "continue"])
        grantDelta()
        app.resetAgentPrompt(.delta)                                          // 초기화 also changes the wording
        precondition(app.promptGrant == nil && app.agentPromptFinalText(.delta) == AgentPromptKind.delta.defaultTemplate)
        print("revocation: edit, undo-after-edit, explicit revoke and reset all close the socket; reads then get nothing")

        // 8. 저장: 고친 양식만 저장되고 다시 읽힌다.
        let reloaded = AppState()
        precondition(reloaded.agentPromptFinalText(.full) == "SYNTHETIC 전체 해설 지시")
        precondition(!reloaded.agentPrompts.isCustomized(.delta) && !reloaded.inAppExplainShortcuts)
        precondition(reloaded.scriptInbox.items.isEmpty && reloaded.agentDraft.isEmpty && reloaded.promptGrant == nil)

        // 9. 단축키·Services ‘코드 해설’: 기본은 생성하지 않는다. 고급에서 켠 경우에만 생성 경로로 간다.
        precondition(!app.externalExplainRequest("print('synthetic')"))
        await settle(0.2)
        precondition(Case.log.llmCalls == baseline && app.phase == .idle && !app.explaining && app.codeText == "print('synthetic')")
        precondition(app.explanationText.isEmpty && Case.log.payloads.count == 4)
        app.inAppExplainShortcuts = true
        precondition(app.externalExplainRequest("print('synthetic')"))
        await settle(0.3)
        precondition(Case.log.llmCalls[1] == baseline[1] + 1)                 // reached the (stubbed-out) explainer factory
        precondition(app.phase == .idle && Case.log.payloads.count == 4)      // never speaks raw code
        app.inAppExplainShortcuts = false
        print("shortcut/service: default → no generation, code parked; advanced opt-in → reaches the explainer")

        // 10. 수신 끄기, 그리고 기존 TTS 회귀: 일반 재생·중지·MCP speak_text 게이트.
        app.onToggleScriptInbox?()
        precondition(!app.scriptInboxEnabled && !FileManager.default.fileExists(atPath: inboxSocket))
        await expectSilent(inboxSocket, second)
        precondition(app.scriptInbox.items.count == 1)
        let draftBefore = app.agentDraft
        app.normalizeEnabled = false
        app.inputText = "일반 TTS 문장입니다."
        app.scriptText = ""
        app.speakScript()
        await awaitPayloads(app, 5)
        precondition(Case.log.payloads.last == "일반 TTS 문장입니다." && app.playbackMode == .tts && app.subtitleText == "일반 TTS 문장입니다.")
        let gate = LocalSpeechGate()
        precondition(gate.accept(text: "즉시 재생 문장", key: "fixture-speak", app: app) == "accepted")
        await awaitPayloads(app, 6)
        precondition(gate.accept(text: "즉시 재생 문장", key: "fixture-speak", app: app) == "duplicate")
        app.normalizeEnabled = true
        app.speakSelected("선택한 문장")                                       // existing path still normalizes
        await awaitPayloads(app, 7)
        precondition(Case.log.payloads.last == "REWRITTEN BY FAKE MODEL" && Case.log.llmCalls[0] == baseline[0] + 1)
        app.synthesize("중지 확인")
        app.stop()
        precondition(app.phase == .idle)
        precondition(app.agentDraft == draftBefore && app.scriptInbox.items.count == 1)
        _ = app.historyPage(search: "", sort: .recent, limit: 5, offset: 0)   // history query still works
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: application))
        precondition(!FileManager.default.fileExists(atPath: inboxSocket) && !FileManager.default.fileExists(atPath: instructionSocket))
        print("regression: TTS play/stop, speak_text gate, selected-text normalization and history unchanged; editor and inbox untouched by them")
    }
}
