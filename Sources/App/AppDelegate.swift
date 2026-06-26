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
    private lazy var overlay = OverlayWindow(app: appState)
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
        menu.autoenablesItems = false        // we manage enablement; avoids validation quirks
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

    /// Reflect playback phase in the menu-bar icon and the floating overlay.
    private func observeState() {
        appState.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .idle:
                    self.overlay.hide()
                    self.setIcon(self.appState.statusText.hasPrefix("오류") ? "⚠️" : "🔊")
                case .synthesizing: self.setIcon("⏳"); self.overlay.show()
                case .playing:      self.setIcon("🔈"); self.overlay.show()
                case .paused:       self.setIcon("⏸"); self.overlay.show()
                }
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
