import Foundation

@MainActor final class AppState {
    enum Phase { case idle, synthesizing }
    enum PlaybackMode { case tts, explain }
    var phase: Phase = .idle
    var playbackMode: PlaybackMode = .explain
    var isBusy: Bool { phase != .idle }
    var explaining = false
    var normalizing = false
    var calls: [String] = []
    func synthesize(_ text: String, displayText: String? = nil, preserveLiteral: Bool = false) { precondition(preserveLiteral && displayText == text); calls.append(text) }
}

@main struct Tests {
    @MainActor static func main() {
        let app = AppState(), gate = LocalSpeechGate()
        precondition(gate.accept(text: "one", key: "1", app: app) == "accepted")
        precondition(app.phase == .synthesizing && app.calls == ["one"] && app.playbackMode == .tts)
        precondition(gate.accept(text: "one", key: "1", app: app) == "duplicate")
        precondition(gate.accept(text: "two", key: "1", app: app) == "conflict")
        precondition(gate.accept(text: "two", key: "2", app: app) == "busy")
        app.phase = .idle; app.playbackMode = .explain; app.explaining = true
        precondition(gate.accept(text: "two", key: "2", app: app) == "busy")
        precondition(app.playbackMode == .explain)
        app.explaining = false; app.normalizing = true
        precondition(gate.accept(text: "two", key: "2", app: app) == "busy")
        app.normalizing = false
        precondition(gate.accept(text: "two", key: "2", app: app) == "accepted")
        precondition(app.calls == ["one", "two"] && app.playbackMode == .tts)
        let literal = "k\nk는\n1 + 1 = 2"
        precondition(TextSplitter.paragraphs(literal).joined(separator: " ") == "k k는 1 + 1 = 2")
        precondition(TextSplitter.cleanInput(literal) == "k는 1 + 1 = 2")
        print("LocalSpeechGate tests passed")
    }
}
