import AppKit
import Darwin
import Foundation
import SwiftUI

enum ExplainWorkflowProbe {
    static let log = Capture()

    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var normalized: [String] = []
        private var synthesized: [(segment: String, subtitle: String)] = []

        func recordNormalizer(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            normalized.append(text)
        }

        func recordSpeech(segment: String, subtitle: String) {
            lock.lock(); defer { lock.unlock() }
            synthesized.append((segment, subtitle))
        }

        func snapshot() -> ([String], [(segment: String, subtitle: String)]) {
            lock.lock(); defer { lock.unlock() }
            return (normalized, synthesized)
        }
    }

    struct SpyNormalizer: Normalizing {
        let instruction: String
        func normalizeStream(_ text: String) -> AsyncThrowingStream<String, Error> {
            log.recordNormalizer(text)
            return AsyncThrowingStream { pipe in
                pipe.yield("NORMALIZED_SHOULD_NOT_RUN")
                pipe.finish()
            }
        }
    }

    struct CaptureOnlyBackend: TTSBackend {
        let identity = "explain-workflow-capture"
        enum End: Error { case captured }
        weak var app: AppState?

        func synthesizeTimed(segment: String, voice: VoiceConfig) async throws -> (data: Data, charStarts: [Double])? {
            nil
        }

        @MainActor
        private func currentSubtitle() -> String {
            app?.subtitleText ?? ""
        }

        func stream(segment: String, voice: VoiceConfig) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { continuation in
                Task { @MainActor in
                    let sub = currentSubtitle()
                    log.recordSpeech(segment: segment, subtitle: sub)
                    continuation.finish(throwing: End.captured)
                }
            }
        }
    }

    static func unixExchange(socketPath: String, requestLine: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            bytes.withUnsafeBytes { dst.copyBytes(from: $0) }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }

        let sent: Bool = requestLine.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return false }
            var offset = 0
            while offset < ptr.count {
                let n = Darwin.send(fd, base.advanced(by: offset), ptr.count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard sent else { throw POSIXError(.EIO) }
        Darwin.shutdown(fd, SHUT_WR)

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n > 0 {
                reply.append(contentsOf: chunk[0..<n])
            } else {
                break
            }
        }
        return reply
    }

    static func sendDraft(root: String, payload: [String: Any]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload) + Data([10])
        let path = root + "/e.sock"
        return try await Task.detached(priority: .userInitiated) {
            let raw = try unixExchange(socketPath: path, requestLine: data)
            guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let status = obj["status"] as? String else {
                return "malformed:\(String(data: raw, encoding: .utf8) ?? "")"
            }
            return status
        }.value
    }

    static func fetchInstruction(root: String, profile: String) async throws -> [String: Any]? {
        let data = try JSONSerialization.data(withJSONObject: ["profile": profile]) + Data([10])
        let path = root + "/i.sock"
        return try await Task.detached(priority: .userInitiated) {
            let raw = try unixExchange(socketPath: path, requestLine: data)
            guard !raw.isEmpty else { return nil }
            return try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        }.value
    }
}

@main struct ExplainTabWorkflowTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if !condition() {
            fputs("FAILED: \(name)\n", stderr)
            exit(1)
        }
        checks += 1
    }

    @MainActor
    static func awaitIdle(_ app: AppState, expectedSpeechCount: Int) async throws {
        for _ in 0..<250 {
            if ExplainWorkflowProbe.log.snapshot().1.count >= expectedSpeechCount && app.phase == .idle {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Timed out waiting for speech count \(expectedSpeechCount); got \(ExplainWorkflowProbe.log.snapshot().1.count), phase=\(app.phase)")
    }

    @MainActor
    static func main() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let root = ProcessInfo.processInfo.environment["TTS_WORKFLOW_FIXTURE_ROOT"]!
        let delegate = AppDelegate()
        delegate.explainWorkflowFixtureSetUp()
        let app = delegate.appState

        // 1. Default state & zero unintended model lookup / generation when opening default Explain tab
        check(app.showLegacyExplain == false, "legacy explain hidden by default")
        check(app.allowLegacyShortcutExplain == false, "legacy shortcut/service explain disabled by default")
        check(app.explainDraftInboxEnabled == false, "MCP draft inbox off by default")
        check(app.instructionShareState == .inactive, "instruction share inactive by default")

        // Add an enabled synthetic endpoint pointing at a closed local port; opening default CommentaryView must not query it.
        let syntheticEP = CustomEndpoint(
            id: UUID(),
            name: "Synthetic Closed Endpoint",
            baseURL: "http://127.0.0.1:9",
            apiStyle: .ollama,
            isEnabled: true,
            defaultModel: "synthetic-model"
        )
        app.endpoints = [syntheticEP]
        app.selectedTab = 1
        let offscreen = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        offscreen.contentView = NSHostingView(rootView: CommentaryView().environmentObject(app))
        offscreen.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        check(app.endpointStatus.isEmpty, "default Explain tab triggered zero endpoint model fetches")
        check(!app.explaining && !app.normalizing && app.phase == .idle, "default Explain tab started zero generation/playback")
        check(ExplainWorkflowProbe.log.snapshot().0.isEmpty && ExplainWorkflowProbe.log.snapshot().1.isEmpty, "zero calls on tab open")

        // 2. Instruction single source, status wording, real i.sock approval, TOCTOU, edit-revoke & manual-revoke
        app.explainInstructionMode = .full
        app.explainPrompt = "SYNTHETIC_FULL: caf\u{00E9} 규칙을 따릅니다."
        app.continuePrompt = "SYNTHETIC_DELTA: 바뀐 부분만 설명합니다."
        let fullPreview = app.finalExplainInstruction(for: .full)
        let fullRev = app.finalExplainInstructionRevision(for: .full)
        app.copyFinalExplainInstruction(for: .full)
        check(NSPasteboard.general.string(forType: .string) == fullPreview, "copied full instruction matches preview")

        for mode in ExplainInstructionMode.allCases {
            let title = app.instructionShareState.statusTitle(for: mode)
            let detail = app.instructionShareState.statusDetail(for: mode)
            check(!title.contains("전송됨") && !detail.contains("전송됨"), "no 전송됨 in inactive status")
            check(!title.contains("생성 중") && !detail.contains("생성 중"), "no 생성 중 in inactive status")
        }

        // Stale preview revision rejected before opening socket
        check(!app.requestApproveExplainInstruction(pidText: String(getpid()), expectedRevision: String(repeating: "0", count: 64)),
              "stale preview revision denied")
        check(app.instructionShareState == .inactive, "failed approval kept share inactive")

        // Approve current full instruction for our PID
        check(app.requestApproveExplainInstruction(pidText: String(getpid()), expectedRevision: fullRev),
              "approved full instruction for self PID")
        check(app.instructionShareState.allows(mode: .full, revision: fullRev), "share state allows exact full revision")
        check(!app.instructionShareState.statusTitle(for: .full).contains("전송됨")
              && !app.instructionShareState.statusTitle(for: .full).contains("생성 중"),
              "allowed status never claims 전송됨 or 생성 중")
        check(app.instructionShareState.statusTitle(for: .delta) == "현재 양식은 조회 비허용",
              "switching viewed mode reflects non-shared state for delta")

        // Fetch over real i.sock
        let deniedDelta = try await ExplainWorkflowProbe.fetchInstruction(root: root, profile: "continue")
        check(deniedDelta == nil, "wrong profile denied over real i.sock")
        let fetchedFull = try await ExplainWorkflowProbe.fetchInstruction(root: root, profile: "explain")
        check(fetchedFull?["instructions"] as? String == fullPreview, "real i.sock returned exact preview text")
        check(fetchedFull?["revision"] as? String == fullRev, "real i.sock returned exact revision")

        // Byte-level NFC->NFD edit revokes immediately; reverting does not restore consent
        app.explainPrompt = "SYNTHETIC_FULL: cafe\u{0301} 규칙을 따릅니다."
        try await Task.sleep(nanoseconds: 50_000_000)
        check(app.instructionShareState == .revoked(.edited), "NFC->NFD edit auto-revoked MCP lookup")
        check(!FileManager.default.fileExists(atPath: root + "/i.sock"), "i.sock unlinked on edit revoke")
        app.explainPrompt = "SYNTHETIC_FULL: caf\u{00E9} 규칙을 따릅니다."
        try await Task.sleep(nanoseconds: 50_000_000)
        check(app.instructionShareState == .revoked(.edited), "reverting edit did not restore approval")

        // Delta mode approval + manual revoke + reset
        app.explainInstructionMode = .delta
        let deltaPreview = app.finalExplainInstruction(for: .delta)
        let deltaRev = app.finalExplainInstructionRevision(for: .delta)
        check(app.requestApproveExplainInstruction(pidText: String(getpid()), expectedRevision: deltaRev),
              "approved delta instruction")
        let fetchedDelta = try await ExplainWorkflowProbe.fetchInstruction(root: root, profile: "continue")
        check(fetchedDelta?["instructions"] as? String == deltaPreview, "real i.sock returned exact delta instruction")
        app.continuePrompt = "SYNTHETIC_DELTA: 수정 후 자동 철회 검증"
        try await Task.sleep(nanoseconds: 50_000_000)
        check(app.instructionShareState == .revoked(.edited), "editing continuePrompt auto-revoked MCP lookup")
        check(!FileManager.default.fileExists(atPath: root + "/i.sock"), "i.sock unlinked after continuePrompt edit")

        // Re-approve delta and verify manual revoke + reset
        let editedDeltaRev = app.finalExplainInstructionRevision(for: .delta)
        check(app.requestApproveExplainInstruction(pidText: String(getpid()), expectedRevision: editedDeltaRev),
              "re-approved delta instruction")
        app.revokeInstructionShare()
        check(app.instructionShareState == .revoked(.manual), "manual revoke updated share state")
        check(!FileManager.default.fileExists(atPath: root + "/i.sock"), "i.sock unlinked on manual revoke")
        app.resetExplainInstructionTemplate(for: .delta)
        check(app.continuePrompt == CodeExplanation.continueInstruction, "delta reset restored default template")

        // 3. Silent arrival over real e.sock + second arrival while editing + idempotent retry & conflict
        check(app.setExplainDraftInboxEnabled(true), "enabled MCP explain draft inbox")
        check(FileManager.default.fileExists(atPath: root + "/e.sock"), "e.sock created on enable")

        let draft1Payload: [String: Any] = [
            "display_text": "as_frame 옵션을 켜면 데이터프레임을 반환합니다.",
            "spoken_text": "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다.",
            "mode": "explain",
            "idempotency_key": "wf-req-1",
            "instruction_revision": fullRev,
        ]
        let s1 = try await ExplainWorkflowProbe.sendDraft(root: root, payload: draft1Payload)
        check(s1 == "accepted", "first draft accepted over e.sock")
        check(app.explainWorkspace.receivedDrafts.count == 1, "inbox holds first draft")
        check(app.explainWorkspace.editor.isEmpty, "silent arrival left editor untouched")
        check(app.phase == .idle && ExplainWorkflowProbe.log.snapshot().1.isEmpty, "silent arrival started zero playback")

        // Load draft 1 and start editing
        let draft1ID = app.explainWorkspace.receivedDrafts[0].id
        check(app.loadExplainDraftIntoEditor(draft1ID), "loaded draft 1 into editor")
        app.updateExplainDisplayText("사용자 편집 중: as_frame 옵션을 켜면 반환합니다.")
        check(app.explainWorkspace.editor.isDirty && app.explainWorkspace.editor.isSpokenStale,
              "editing display marked editor dirty and spoken stale")

        // Second arrival while editing must not overwrite editor or start playback
        let draft2Payload: [String: Any] = [
            "display_text": "두 번째 도착 문구입니다.",
            "spoken_text": "두 번째 도착 낭독 문구입니다.",
            "mode": "continue",
            "idempotency_key": "wf-req-2",
        ]
        let s2 = try await ExplainWorkflowProbe.sendDraft(root: root, payload: draft2Payload)
        check(s2 == "accepted", "second draft accepted while editing")
        check(app.explainWorkspace.receivedDrafts.count == 2, "inbox now has two drafts")
        check(app.explainWorkspace.editor.displayText == "사용자 편집 중: as_frame 옵션을 켜면 반환합니다.",
              "second arrival preserved user's edited display text")
        check(app.explainWorkspace.editor.spokenText == "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다.",
              "second arrival preserved editor spoken text")
        check(app.explainWorkspace.editor.isDirty && ExplainWorkflowProbe.log.snapshot().1.isEmpty,
              "second arrival preserved dirty flag and triggered zero playback")

        // Retry wf-req-2 -> duplicate (still 2 items); conflict on different text
        let s2Retry = try await ExplainWorkflowProbe.sendDraft(root: root, payload: draft2Payload)
        check(s2Retry == "duplicate", "retry wf-req-2 returned duplicate")
        check(app.explainWorkspace.receivedDrafts.count == 2, "duplicate retry kept single item")
        let s2Conflict = try await ExplainWorkflowProbe.sendDraft(root: root, payload: [
            "display_text": "충돌 텍스트",
            "idempotency_key": "wf-req-2",
        ])
        check(s2Conflict == "conflict", "reused key with different payload returned conflict")
        check(app.explainWorkspace.receivedDrafts.count == 2, "conflict did not alter inbox")

        // 4. Stale playback protection + display/spoken split + no silent rewrite (normalizeEnabled = true)
        app.normalizeEnabled = true
        app.useCache = false

        // Stale spoken blocks normal playback without confirmation
        check(!app.playExplainDraft(), "stale spoken blocked playExplainDraft without confirmation")
        check(app.pendingStaleExplainPlayback != nil, "pending stale playback confirmation surfaced")
        check(app.phase == .idle && ExplainWorkflowProbe.log.snapshot().1.isEmpty, "blocked playback made zero synthesis calls")

        // Explicit choice: play display text directly without mutating spokenText
        check(app.playExplainDisplayTextDirectly(), "display-only playback started")
        try await Task.sleep(nanoseconds: 50_000_000)
        // Wait for capture-only backend completion
        try await awaitIdle(app, expectedSpeechCount: 1)
        let snap1 = ExplainWorkflowProbe.log.snapshot()
        check(snap1.0.isEmpty, "Explain playback never called LLM normalizer even with normalizeEnabled=true")
        check(snap1.1.last?.segment == "사용자 편집 중: as_frame 옵션을 켜면 반환합니다.",
              "display-only playback synthesized exact edited display text")
        check(snap1.1.last?.subtitle == "사용자 편집 중: as_frame 옵션을 켜면 반환합니다.",
              "display-only playback kept exact display subtitle")
        check(app.explainWorkspace.editor.spokenText == "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다."
              && app.explainWorkspace.editor.isSpokenStale,
              "display-only playback did not mutate spokenText")

        // Explicit confirmation: play stale spoken text
        check(app.confirmPlayStaleExplainDraft(), "confirmed stale playback started")
        try await awaitIdle(app, expectedSpeechCount: 2)
        let snap2 = ExplainWorkflowProbe.log.snapshot()
        check(snap2.0.isEmpty, "confirmed stale playback did not call normalizer")
        check(snap2.1.last?.segment == "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다.",
              "confirmed stale playback used spoken text")
        check(snap2.1.last?.subtitle == "사용자 편집 중: as_frame 옵션을 켜면 반환합니다.",
              "confirmed stale playback showed edited display subtitle")

        // Fresh load of split draft 1: plays spoken verbatim with display subtitle verbatim
        check(app.loadExplainDraftIntoEditor(draft1ID), "reloaded draft 1 cleanly")
        check(!app.explainWorkspace.editor.isSpokenStale, "reloaded draft 1 is synced")
        check(app.playExplainDraft(), "synced split draft played immediately on user click")
        try await awaitIdle(app, expectedSpeechCount: 3)
        let snap3 = ExplainWorkflowProbe.log.snapshot()
        check(snap3.0.isEmpty, "synced Explain playback did not call normalizer")
        check(snap3.1.last?.segment == "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다.",
              "TTS synthesized 애즈 프레임 verbatim")
        check(snap3.1.last?.subtitle == "as_frame 옵션을 켜면 데이터프레임을 반환합니다.",
              "HUD subtitle retained as_frame verbatim")

        // 5. Guarded shortcut/service entry + general TTS / stop / subtitle / LocalSpeechGate regressions
        app.handleExplainShortcutOrService("x = as_frame()\nprint(x)") { }
        try await Task.sleep(nanoseconds: 50_000_000)
        check(app.selectedTab == 1 && !app.explaining && app.phase == .idle,
              "shortcut/service did not start in-app LLM explanation when disabled")
        check(ExplainWorkflowProbe.log.snapshot().1.count == 3,
              "shortcut/service did not trigger speech synthesis")
        check(app.explainWorkspace.editor.displayText == "as_frame 옵션을 켜면 데이터프레임을 반환합니다.",
              "shortcut/service did not clobber Explain draft editor")

        // General TTS regression
        app.normalizeEnabled = false
        app.inputText = "일반 TTS 회귀 테스트 문장입니다."
        app.scriptText = ""
        app.speakScript()
        try await awaitIdle(app, expectedSpeechCount: 4)
        let snap4 = ExplainWorkflowProbe.log.snapshot()
        check(app.playbackMode == .tts && snap4.1.last?.segment == "일반 TTS 회귀 테스트 문장입니다.",
              "general TTS speakScript regression passed")

        // Subtitle toggle per mode + stop
        let prevTTS = app.subtitleTTS
        app.toggleSubtitle()
        check(app.subtitleTTS != prevTTS, "subtitleTTS toggled for .tts mode")
        app.stop()
        check(app.phase == .idle && app.chunkIndex == 0 && app.chunkCount == 0, "stop reset playback state")

        // LocalSpeechGate (speak_text) regression
        let speechGate = LocalSpeechGate()
        check(speechGate.accept(text: "MCP 즉시 재생 회귀", key: "speech-reg-1", app: app) == "accepted",
              "LocalSpeechGate accepted speak_text")
        try await awaitIdle(app, expectedSpeechCount: 5)
        check(ExplainWorkflowProbe.log.snapshot().1.last?.segment == "MCP 즉시 재생 회귀",
              "LocalSpeechGate synthesized literal text")

        // Turn off MCP draft inbox cleanly
        check(app.setExplainDraftInboxEnabled(false), "disabled MCP draft inbox")
        check(!FileManager.default.fileExists(atPath: root + "/e.sock"), "e.sock removed on disable")

        print("ExplainTabWorkflowTests passed (\(checks) checks).")
    }
}
