import AppKit
import Foundation

/// Compiler fixture. The runner copies app sources, replacing only external
/// provider factories and the settings location; actual app state paths run here.
enum PronunciationCase {
    static let visual = "as_frame 옵션을 켜면 데이터프레임을 반환합니다."
    static let spoken = "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다."
    static let preferred = "애즈 프레임"
    static let hint = "SYNTHETIC HINT: as_frame은 애즈 프레임으로 한 번만 읽습니다."
    static let glossaryReading = "에이에스 프레임"
    static let base = "SYNTHETIC BASE: 영어 식별자와 값은 원래 철자로 둡니다."
    static let log = Capture()

    final class Capture: @unchecked Sendable {
        let lock = NSLock()
        private var normalized: [(text: String, instruction: String)] = []
        private var synthesized: [String] = []
        func record(_ text: String, _ instruction: String) {
            lock.lock(); defer { lock.unlock() }; normalized.append((text, instruction))
        }
        func recordSpeech(_ text: String) {
            lock.lock(); defer { lock.unlock() }; synthesized.append(text)
        }
        func snapshot() -> ([(text: String, instruction: String)], [String]) {
            lock.lock(); defer { lock.unlock() }; return (normalized, synthesized)
        }
    }

    struct FakeNormalizer: Normalizing {
        let instruction: String
        func normalizeStream(_ text: String) -> AsyncThrowingStream<String, Error> {
            log.record(text, instruction)
            return AsyncThrowingStream { pipe in
                pipe.yield(spoken) // controlled expected output, not a model result
                pipe.finish()
            }
        }
    }

    actor DelayedProvider {
        typealias ResultValue = (data: Data, charStarts: [Double])?
        static let shared = DelayedProvider()
        private var waiters: [String: CheckedContinuation<ResultValue, Error>] = [:]
        func wait(_ key: String) async throws -> ResultValue {
            try await withCheckedThrowingContinuation { waiter in waiters[key] = waiter }
        }
        func has(_ key: String) -> Bool { waiters[key] != nil }
        func fail(_ key: String) { waiters.removeValue(forKey: key)?.resume(throwing: CaptureOnlyEngine.End.payloadCaptured) }
    }

    struct CaptureOnlyEngine: TTSBackend {
        let identity = "capture-only-pronunciation-case"
        enum End: Error { case payloadCaptured }
        func synthesizeTimed(segment: String, voice: VoiceConfig) async throws -> (data: Data, charStarts: [Double])? {
            if segment.hasPrefix("SYNTHETIC_DELAY") { return try await DelayedProvider.shared.wait(segment) }
            return nil
        }
        func stream(segment: String, voice: VoiceConfig) -> AsyncThrowingStream<Data, Error> {
            // Deliberately emits no audio; tests inspect the exact synthesis inputs.
            log.recordSpeech(segment)
            return AsyncThrowingStream { $0.finish(throwing: End.payloadCaptured) }
        }
    }
}

@main struct TTSPronunciationCaseTests {
    @MainActor static func awaitPayload(_ app: AppState, count: Int) async throws {
        for _ in 0..<200 {
            if PronunciationCase.log.snapshot().1.count >= count && app.phase == .idle { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("No captured synthesis payload or completion")
    }

    @MainActor static func writeSettings(_ glossary: [[String: String]]?) throws {
        var settings: [String: Any] = ["backend": "local", "endpoints": [], "useCache": false, "normalize": true]
        if let glossary { settings["glossary"] = glossary }
        let url = URL(fileURLWithPath: Secrets.appSupportDir).appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: settings).write(to: url)
    }

    @MainActor static func main() async throws {
        let appKit = NSApplication.shared
        appKit.setActivationPolicy(.prohibited)
        typealias Case = PronunciationCase
        try writeSettings([])
        let empty = AppState()
        precondition(empty.glossary.isEmpty)
        empty.saveSettings()
        precondition(AppState().glossary.isEmpty)
        try writeSettings(nil)
        precondition(AppState().glossary == AppState.seedGlossary)
        print("glossary: explicit empty survived save/reload; missing key seeded defaults")

        try writeSettings([[
            "id": "00000000-0000-4000-8000-000000000001", "term": "as_frame",
            "pronunciation": Case.glossaryReading, "note": "synthetic fixture only",
        ]])
        let app = AppState()
        precondition(app.normalizeEnabled && app.glossary.count == 1)
        app.normalizePrompt = Case.base
        app.scriptHint = Case.hint
        app.explanationText = Case.visual
        app.speakExplanation()
        try await awaitPayload(app, count: 1)
        let (normalized, nativePayloads) = Case.log.snapshot()
        precondition(normalized.count == 1 && normalized[0].text == Case.visual)
        let instruction = normalized[0].instruction
        let glossaryLine = "as_frame → \(Case.glossaryReading)"
        guard let hint = instruction.range(of: Case.hint), let glossary = instruction.range(of: glossaryLine),
              let base = instruction.range(of: Case.base) else { preconditionFailure("Missing parts") }
        precondition(hint.lowerBound < glossary.lowerBound && glossary.lowerBound < base.lowerBound)
        precondition(!instruction.contains("synthetic fixture only"))
        precondition(app.explanationText == Case.visual && app.subtitleText == Case.visual)
        precondition(nativePayloads == [Case.spoken])
        precondition(nativePayloads[0].components(separatedBy: Case.preferred).count == 2)
        precondition(!nativePayloads[0].contains("as_frame") && !nativePayloads[0].contains("(") && !nativePayloads[0].contains(")"))
        print("native: subtitle=as_frame; capture-only speech payload=Korean pronunciation once; hint > glossary > base")

        let gate = LocalSpeechGate()
        precondition(gate.accept(text: Case.spoken, key: "fixture-phonetic", app: app) == "accepted")
        try await awaitPayload(app, count: 2)
        precondition(app.subtitleText == Case.spoken)
        precondition(Case.log.snapshot().1 == [Case.spoken, Case.spoken])
        precondition(gate.accept(text: Case.visual, key: "fixture-source", app: app) == "accepted")
        try await awaitPayload(app, count: 3)
        precondition(app.subtitleText == Case.visual)
        let (finalNormalization, finalPayloads) = Case.log.snapshot()
        precondition(finalNormalization.count == 1)
        precondition(finalPayloads == [Case.spoken, Case.spoken, Case.visual])
        print("MCP gate: phonetic text becomes subtitle and speech; raw text stays raw; normalization bypassed")

        let old = "SYNTHETIC_DELAY old", new = "SYNTHETIC_DELAY new"
        let delayed = Case.DelayedProvider.shared
        func waitForProvider(_ key: String) async throws {
            for _ in 0..<100 {
                if await delayed.has(key) { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure("Stub never received " + key)
        }
        app.synthesize(old)
        try await waitForProvider(old)
        app.stop()
        precondition(gate.accept(text: new, key: "fixture-latest", app: app) == "accepted")
        try await waitForProvider(new)
        await delayed.fail(old) // a stopped backend reports a late, non-cancellation error
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 10_000_000)
            precondition(app.phase == .synthesizing && app.currentText == new)
        }
        await delayed.fail(new)
        try await awaitPayload(app, count: 3)
        print("playback: delayed error from stopped provider did not reset latest accepted request")

        let inbox = app.explanationDrafts
        inbox.editDisplay("User's unsaved manual draft")
        let item = ExplanationDraft(id: "fixture-draft", display: Case.visual, speech: Case.spoken)!
        precondition(inbox.receive(item) == .accepted && inbox.receive(item) == .duplicate)
        precondition(inbox.receive(ExplanationDraft(id: item.id, display: "달라진 대본", speech: nil)!) == .conflict)
        precondition(inbox.pending.count == 1 && inbox.display == "User's unsaved manual draft")
        precondition(app.phase == .idle && Case.log.snapshot().0.count == 1 && Case.log.snapshot().1.count == 3)
        precondition(!inbox.open(item.id) && inbox.pending.count == 1)
        precondition(inbox.open(item.id, replace: true) && inbox.pending.isEmpty)
        precondition(inbox.display == Case.visual && inbox.speech == Case.spoken)
        precondition(inbox.speechNeedsReview && inbox.playback() == nil)
        app.playExplanationDraft()
        precondition(app.phase == .idle && Case.log.snapshot().1.count == 3)
        inbox.confirmSpeech()
        precondition(!inbox.speechNeedsReview)
        precondition(inbox.receive(item) == .duplicate && inbox.pending.isEmpty)
        app.playExplanationDraft()
        try await awaitPayload(app, count: 4)
        precondition(app.subtitleText == Case.visual && Case.log.snapshot().1.last == Case.spoken)

        let edited = Case.visual + " 수정했습니다."
        inbox.editDisplay(edited)
        precondition(inbox.speechNeedsReview && inbox.playback() == nil)
        app.playExplanationDraft()
        precondition(app.phase == .idle && Case.log.snapshot().1.count == 4)
        app.playExplanationDraft(displayOnly: true)
        try await awaitPayload(app, count: 5)
        precondition(app.subtitleText == edited && Case.log.snapshot().1.last == edited)
        precondition(inbox.speechNeedsReview)
        let corrected = Case.spoken + " 수정했습니다."
        inbox.editSpeech(corrected)
        precondition(inbox.speechNeedsReview)
        inbox.confirmSpeech()
        app.playExplanationDraft()
        try await awaitPayload(app, count: 6)
        precondition(app.subtitleText == edited && Case.log.snapshot().1.last == corrected)
        precondition(Case.log.snapshot().0.count == 1) // normalization remains enabled, but never for these drafts.

        for i in 0..<ExplanationDraftWorkspace.maxPending {
            precondition(inbox.receive(ExplanationDraft(id: "queued-\(i)", display: "대본 \(i)", speech: nil)!) == .accepted)
        }
        precondition(inbox.receive(ExplanationDraft(id: "overflow", display: "가득 참", speech: nil)!) == .busy)
        inbox.discard("queued-0")
        precondition(inbox.receive(ExplanationDraft(id: "overflow", display: "빈 자리", speech: nil)!) == .accepted)
        precondition(inbox.display == edited && inbox.pending.count == ExplanationDraftWorkspace.maxPending)
        inbox.editDisplay(CodeExplanation.noChange)
        precondition(inbox.playback() == nil && inbox.playback(displayOnly: true) == nil)
        inbox.editDisplay("일반 비교식 x < 5 그리고 List<String>")
        precondition(inbox.playback(displayOnly: true) != nil)
        inbox.editDisplay("<speak>blocked</speak>")
        precondition(inbox.playback() == nil && inbox.playback(displayOnly: true) == nil)
        inbox.editDisplay("&lt;break time='1s'/&gt;")
        precondition(inbox.playback() == nil && inbox.playback(displayOnly: true) == nil)
        app.playExplanationDraft()
        precondition(app.phase == .idle && Case.log.snapshot().1.count == 6)
        precondition(gate.accept(text: "%3Cspeak%3Eencoded%3C/speak%3E", key: "ssml-rejected", app: app) == "invalid")
        print("draft workspace: queued/retried/no overwrite; first-diff & stale voice blocked; SSML blocked; explicit literal playback separates subtitle and speech, no normalizer")
    }
}
