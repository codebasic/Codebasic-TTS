import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Singleton-ish handle so the Services provider can reach the running app.
    static private(set) var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private let serviceProvider = ServiceProvider()
    private var lastSelection: String = ""

    // Active backend. M1 just logs through it; later milestones swap in
    // ElevenLabsBackend / Qwen3MLXBackend behind this same protocol.
    private let backend: TTSBackend = StubBackend()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        setUpStatusItem()
        registerServices()

        Log.app.info("SelectedTextTTS launched. Active backend: \(self.backend.identity, privacy: .public)")
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔊"

        let menu = NSMenu()
        menu.addItem(withTitle: "SelectedTextTTS", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let lastItem = NSMenuItem(title: "Last selection: —", action: nil, keyEquivalent: "")
        lastItem.tag = MenuTag.lastSelection.rawValue
        lastItem.isEnabled = false
        menu.addItem(lastItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    private enum MenuTag: Int {
        case lastSelection = 100
    }

    // MARK: - Services

    private func registerServices() {
        // Wire the provider so the runtime can dispatch the Services menu item.
        NSApp.servicesProvider = serviceProvider
        // Force a refresh of the dynamic services so the menu item shows up
        // without requiring a logout/login on the very first run.
        NSUpdateDynamicServices()
    }

    // MARK: - Entry point from the Services menu

    /// Called by ServiceProvider when the user picks "Read with SelectedTextTTS".
    /// M1: log + reflect in the menu bar. M2+: hand to Segmenter → Cache → Player.
    func handleSelectedText(_ text: String) {
        lastSelection = text
        let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(60)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let item = self.statusItem.menu?.item(withTag: MenuTag.lastSelection.rawValue) {
                item.title = "Last selection: \(preview)\(text.count > 60 ? "…" : "")"
            }
            // Brief visual confirmation that the service fired.
            self.statusItem.button?.title = "🔈"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.statusItem.button?.title = "🔊"
            }
        }

        Log.app.info("handleSelectedText: \(text.count) chars — \"\(preview, privacy: .public)\"")
    }
}
