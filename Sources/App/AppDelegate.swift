import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Singleton-ish handle so the Services provider can reach the running app.
    static private(set) var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private let serviceProvider = ServiceProvider()
    let appState = AppState()
    private lazy var mainWindow = MainWindow(appState: appState)
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        setUpStatusItem()
        registerServices()
        observeState()
        if appState.keyPresent { appState.refreshVoices() }

        Log.app.info("Codebasic TTS launched. Backend: \(self.appState.backendIdentity, privacy: .public)")
    }

    // MARK: - Menu bar

    private func setIcon(_ s: String) { statusItem.button?.title = s }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("🔊")

        let menu = NSMenu()
        let open = NSMenuItem(title: "Codebasic TTS 열기…", action: #selector(openWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let stop = NSMenuItem(title: "중지", action: #selector(stopSpeaking), keyEquivalent: ".")
        stop.target = self
        menu.addItem(stop)
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// Reflect synthesis/playback state in the menu-bar icon.
    private func observeState() {
        appState.$isWorking.combineLatest(appState.$statusText)
            .receive(on: RunLoop.main)
            .sink { [weak self] working, status in
                guard let self else { return }
                if status.hasPrefix("오류") { self.setIcon("⚠️") }
                else if status.contains("합성") { self.setIcon("⏳") }
                else if working { self.setIcon("🔈") }
                else { self.setIcon("🔊") }
            }
            .store(in: &cancellables)
    }

    @objc private func openWindow() { mainWindow.show() }
    @objc private func stopSpeaking() { appState.stop() }

    // MARK: - Services

    private func registerServices() {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }

    /// Called by ServiceProvider when the user picks "Codebasic TTS": synthesize
    /// the selected text (cache-first) and play it.
    func handleSelectedText(_ text: String) {
        let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(60)
        Log.app.info("handleSelectedText: \(text.count) chars — \"\(preview, privacy: .public)\"")
        appState.synthesize(text)
    }
}
