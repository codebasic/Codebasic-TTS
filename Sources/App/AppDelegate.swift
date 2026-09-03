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
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        setUpMainMenu()
        setUpStatusItem()
        registerServices()
        registerHotKeys()
        observeState()

        // Review-only 해설 (auto-play off): surface the window so it can be checked.
        appState.onRequestReview = { [weak self] in
            self?.mainWindow.show()
            NSApp.activate(ignoringOtherApps: true)
        }
        if appState.keyPresent { appState.refreshVoices() }
        mainWindow.show()                       // open the management window on launch

        Log.app.info("Codebasic TTS launched. Backend: \(self.appState.backendIdentity, privacy: .public)")
    }

    // MARK: - Status item (persistent, focus-safe affordance to reopen the UI)

    /// Menu-bar glyph: a monochrome SF Symbol template (adapts to light/dark
    /// menu bar), swapped per playback phase.
    private func setStatusSymbol(_ name: String) {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Codebasic TTS")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.title = ""
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusSymbol("waveform")

        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Codebasic TTS 열기", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let stop = NSMenuItem(title: "재생 중지", action: #selector(stopSpeaking), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openWindow() { mainWindow.show() }
    @objc private func stopSpeaking() { appState.stop() }

    /// Keep running as a background TTS service after the window is closed, so the
    /// Services menu still works.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window reopens the management window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.show() }
        return true
    }

    // MARK: - State → status icon + overlay

    private func observeState() {
        appState.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .idle:         self.setStatusSymbol("waveform"); self.overlay.hide()
                case .synthesizing: self.setStatusSymbol("ellipsis"); self.overlay.show()
                case .playing:      self.setStatusSymbol("speaker.wave.2.fill"); self.overlay.show()
                case .paused:       self.setStatusSymbol("pause.fill"); self.overlay.show()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Global hotkeys (read/explain the selection from any app)

    private let hotKeys = HotKeyCenter()

    /// ⌃⌥⌘E → explain the selection, ⌃⌥⌘R → read it aloud. The selection is
    /// grabbed via a clipboard-preserving copy, so it works even where the
    /// Services menu is hidden (VS Code). First use prompts for Accessibility.
    private func registerHotKeys() {
        let mods = controlKey | optionKey | cmdKey
        hotKeys.register(id: 1, keyCode: kVK_ANSI_E, modifiers: mods) { [weak self] in
            self?.appState.captureHUDTarget()   // before the async grab: mouse is still on the target screen
            SelectionGrabber.grab { text in
                guard let self, let text else { return }
                MainActor.assumeIsolated {
                    self.appState.selectedTab = 1
                    self.appState.explainAndSpeak(text)
                }
            }
        }
        hotKeys.register(id: 2, keyCode: kVK_ANSI_R, modifiers: mods) { [weak self] in
            self?.appState.captureHUDTarget()   // before the async grab: mouse is still on the target screen
            SelectionGrabber.grab { text in
                guard let self, let text else { return }
                MainActor.assumeIsolated { self.appState.speakSelected(text) }
            }
        }
    }

    // MARK: - ⌘V paste (intercept to attach screenshots in the 해설 탭)

    /// The Edit-menu 붙여넣기 (⌘V) routes here. In the 해설 탭, an image on the
    /// clipboard is attached as a screenshot; otherwise (and for text) the paste
    /// is forwarded to the first responder for normal handling.
    @objc func handlePaste(_ sender: Any?) {
        if appState.selectedTab == 1 {
            let pb = NSPasteboard.general
            let hasImage = (pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?
                .contains { !$0.size.equalTo(.zero) } ?? false
            if hasImage {
                appState.pasteImagesFromClipboard()
                if !pb.canReadObject(forClasses: [NSString.self], options: nil) { return }  // image-only → done
            }
        }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)   // normal text paste
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
        appState.captureHUDTarget()
        appState.speakSelected(text)
    }

    /// Called by ServiceProvider when the user picks "코드 해설": explain the
    /// selected code via the LLM, then speak the commentary (코드 → 해설 → 대본 →
    /// 음성). Surfaces the 해설 tab so the result is visible.
    func handleCodeText(_ code: String) {
        let preview = code.replacingOccurrences(of: "\n", with: " ").prefix(60)
        Log.app.info("handleCodeText: \(code.count) chars — \"\(preview, privacy: .public)\"")
        appState.captureHUDTarget()
        appState.selectedTab = 1        // 해설 탭 (2번째)
        appState.explainAndSpeak(code)
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
        let pasteItem = NSMenuItem(title: "붙여넣기", action: #selector(handlePaste(_:)), keyEquivalent: "v")
        pasteItem.target = self
        editMenu.addItem(pasteItem)
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
