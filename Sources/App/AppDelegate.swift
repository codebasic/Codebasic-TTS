import AppKit
import Combine
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Singleton-ish handle so the Services provider can reach the running app.
    static private(set) var shared: AppDelegate?

    private let serviceProvider = ServiceProvider()
    let appState = AppState()
    private lazy var mainWindow = MainWindow(appState: appState)
    private lazy var overlay = OverlayWindow(app: appState)
    private var cancellables = Set<AnyCancellable>()
    private var localSpeechSocket: LocalSpeechSocket?
    private var localSpeechGate: LocalSpeechGate?
    private var localSpeechMenu: NSMenuItem?
    private var agentWorkspaceStorage: AgentWorkspaceController?
    /// Consent rendezvous for the bundled agent bridge. Listening grants nothing by itself.
    private let agentRendezvous = AgentBridgeRendezvous()

    /// Created on first use (the Agent tab). Owns the instruction catalog, pairing and both leases.
    var agentWorkspace: AgentWorkspaceController {
        if let existing = agentWorkspaceStorage { return existing }
        let created = AgentWorkspaceController(app: appState, rendezvous: agentRendezvous)
        agentWorkspaceStorage = created
        return created
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        setUpMainMenu()
        registerServices()
        registerHotKeys()
        observeState()
        // Lets the bundled bridge find this running app. Nothing is shared or granted until the
        // owner approves one listed bridge process in the Agent tab.
        agentRendezvous.start()

        // Opening the app does not refresh cloud voices. Settings already
        // loads voice/model inventory when the user opens it.
        mainWindow.show()                       // open the management window on launch

        Log.app.info("Codebasic TTS launched. Backend: \(self.appState.backendIdentity, privacy: .public)")
    }

    // MARK: - Local MCP opt-in

    @objc private func toggleLocalSpeech() {
        if let socket = localSpeechSocket {
            socket.stop(); localSpeechSocket = nil; localSpeechGate = nil
            localSpeechMenu?.state = .off
            return
        }
        let gate = LocalSpeechGate()
        let socket = LocalSpeechSocket { [weak self, gate] text, key in
            guard let self, self.localSpeechGate === gate else { return "disabled" }
            return gate.accept(text: text, key: key, app: self.appState)
        }
        guard socket.start() else {
            let alert = NSAlert()
            alert.messageText = "로컬 MCP 음성 입력을 시작할 수 없습니다"
            alert.informativeText = "소켓 경로가 이미 있거나 안전하지 않습니다. 기존 실행과 경로를 확인하세요."
            alert.runModal()
            return
        }
        localSpeechGate = gate; localSpeechSocket = socket; localSpeechMenu?.state = .on
    }

    // Instruction reads (ai.sock) and draft receipt (ad.sock) are owned by AgentWorkspaceController.
    // The legacy i.sock / d.sock endpoints are never started by the app.

    func applicationWillTerminate(_ notification: Notification) {
        localSpeechSocket?.stop()
        agentWorkspaceStorage?.shutdown()
        agentRendezvous.shutdown()
    }

    @objc private func openWindow() { mainWindow.show() }
    @objc private func openSettings() { appState.selectedTab = 4; mainWindow.show() }
    @objc private func openHistory() { appState.selectedTab = 2; mainWindow.show() }
    @objc private func stopSpeaking() { appState.stop() }

    /// Close hides only the window; the same Dock process keeps Services and MCP available.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Route Dock reopen to the management window, even when only the HUD is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false // window ordering was handled here
    }

    // MARK: - Playback overlay

    private func observeState() {
        appState.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .idle: self.overlay.hide()
                case .synthesizing, .playing, .paused: self.overlay.show()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Global hotkeys (read/explain the selection from any app)

    private let hotKeys = HotKeyCenter()

    /// ⌃⌥⌘R → read the selection aloud. The selection is
    /// grabbed via a clipboard-preserving copy, so it works even where the
    /// Services menu is hidden (VS Code). First use prompts for Accessibility.
    private func registerHotKeys() {
        let mods = controlKey | optionKey | cmdKey
        hotKeys.register(id: 2, keyCode: kVK_ANSI_R, modifiers: mods) { [weak self] in
            self?.appState.captureHUDTarget()   // before the async grab: mouse is still on the target screen
            SelectionGrabber.grab { text in
                guard let self, let text else { return }
                MainActor.assumeIsolated { self.appState.speakSelected(text) }
            }
        }
    }

    // MARK: - Services

    private func registerServices() {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }

    /// Called by ServiceProvider when the user picks "Codebasic TTS": synthesize
    /// the selected text (cache-first) and play it without opening the window.
    func handleSelectedText(_ text: String) {
        let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(60)
        Log.app.info("handleSelectedText: \(text.count) chars — \"\(preview, privacy: .public)\"")
        appState.captureHUDTarget()
        appState.speakSelected(text)
    }

    // MARK: - Main menu (regular app needs one for ⌘Q and text-editing shortcuts)

    private func setUpMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Codebasic TTS")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "설정…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "재생 중지", action: #selector(stopSpeaking), keyEquivalent: "").target = self
        let local = appMenu.addItem(withTitle: "로컬 MCP 음성 입력 허용 (이번 실행)",
                                    action: #selector(toggleLocalSpeech), keyEquivalent: "")
        local.target = self
        localSpeechMenu = local
        appMenu.addItem(.separator())
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
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Codebasic TTS 열기", action: #selector(openWindow), keyEquivalent: "").target = self
        windowMenu.addItem(withTitle: "재생 기록", action: #selector(openHistory), keyEquivalent: "").target = self
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
