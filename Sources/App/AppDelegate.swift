import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Singleton-ish handle so the Services provider can reach the running app.
    static private(set) var shared: AppDelegate?

    private let serviceProvider = ServiceProvider()
    let appState = AppState()
    private lazy var mainWindow = MainWindow(appState: appState)
    private lazy var overlay = OverlayWindow(app: appState)
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        setUpMainMenu()
        registerServices()
        observeState()
        if appState.keyPresent { appState.refreshVoices() }
        mainWindow.show()                       // open the management window on launch

        Log.app.info("Codebasic TTS launched. Backend: \(self.appState.backendIdentity, privacy: .public)")
    }

    /// Keep running as a background TTS service after the window is closed, so the
    /// Services menu still works.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window reopens the management window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.show() }
        return true
    }

    // MARK: - State → overlay

    private func observeState() {
        appState.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                if phase == .idle { self?.overlay.hide() } else { self?.overlay.show() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Services

    private func registerServices() {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }

    /// Called by ServiceProvider when the user picks "Codebasic TTS": synthesize
    /// the selected text (cache-first) and play it. With the app idling as an
    /// .accessory agent (window closed), background playback never steals focus.
    func handleSelectedText(_ text: String) {
        let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(60)
        Log.app.info("handleSelectedText: \(text.count) chars — \"\(preview, privacy: .public)\"")
        appState.synthesize(text)
    }

    // MARK: - Main menu (regular app needs one for ⌘Q and text-editing shortcuts)

    private func setUpMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Codebasic TTS 가리기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "다른 항목 가리기",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "편집")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "다시 실행", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "윈도우")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
