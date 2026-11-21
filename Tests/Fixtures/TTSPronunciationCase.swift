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
    }
}
