import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Singleton-ish handle so the Services provider can reach the running app.
    static private(set) var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private let serviceProvider = ServiceProvider()
    private let player = AudioPlayer()
    private var lastSelection: String = ""
    private var speakTask: Task<Void, Never>?

    // Active backend: ElevenLabs (cloud) when a key is present, else a no-op stub.
    private var backend: TTSBackend = StubBackend()

    // The user's cloned ElevenLabs voice (성주) + the low-latency model.
    private let voice = VoiceConfig(voiceId: "Yp1WZJMrN7OSdP8PG9sm",
                                    modelId: "eleven_flash_v2_5",
                                    settingsHash: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        if let key = Secrets.elevenLabsKey {
            backend = ElevenLabsBackend(apiKey: key)
        } else {
            Log.app.error("No ElevenLabs key at \(Secrets.appSupportDir)/eleven_key — speech disabled")
        }

        setUpStatusItem()
        registerServices()
        player.onFinish = { [weak self] in self?.setIcon(.idle) }

        Log.app.info("Codebasic TTS launched. Backend: \(self.backend.identity, privacy: .public)")
    }

    // MARK: - Menu bar

    private enum Icon: String { case idle = "🔊", working = "⏳", speaking = "🔈", error = "⚠️" }
    private enum MenuTag: Int { case lastSelection = 100 }

    private func setIcon(_ icon: Icon) { statusItem.button?.title = icon.rawValue }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(.idle)

        let menu = NSMenu()
        menu.addItem(withTitle: "Codebasic TTS", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let lastItem = NSMenuItem(title: "Last selection: —", action: nil, keyEquivalent: "")
        lastItem.tag = MenuTag.lastSelection.rawValue
        lastItem.isEnabled = false
        menu.addItem(lastItem)

        menu.addItem(withTitle: "Stop", action: #selector(stopSpeaking), keyEquivalent: ".")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    @objc private func stopSpeaking() {
        speakTask?.cancel()
        player.stop()
        setIcon(.idle)
    }

    // MARK: - Services

    private func registerServices() {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }

    // MARK: - Entry point from the Services menu

    /// Called by ServiceProvider when the user picks "Codebasic TTS": synthesize
    /// the selected text and play it.
    func handleSelectedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastSelection = trimmed

        let preview = trimmed.replacingOccurrences(of: "\n", with: " ").prefix(60)
        if let item = statusItem.menu?.item(withTag: MenuTag.lastSelection.rawValue) {
            item.title = "Last selection: \(preview)\(trimmed.count > 60 ? "…" : "")"
        }
        Log.app.info("handleSelectedText: \(trimmed.count) chars — \"\(preview, privacy: .public)\"")

        speak(trimmed)
    }

    private func speak(_ text: String) {
        speakTask?.cancel()
        player.stop()
        setIcon(.working)

        speakTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in self.backend.stream(segment: text, voice: self.voice) {
                    try Task.checkCancellation()
                    self.setIcon(.speaking)
                    try self.player.play(chunk)
                }
            } catch is CancellationError {
                // user pressed Stop / new selection
            } catch {
                Log.app.error("speak failed: \(error.localizedDescription)")
                self.setIcon(.error)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.setIcon(.idle)
            }
        }
    }
}
