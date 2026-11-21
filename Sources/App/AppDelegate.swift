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
    private var localInstructionSocket: LocalInstructionSocket?
    private var localInstructionMenu: NSMenuItem?
    private var localInstructionExpiry: DispatchWorkItem?
    private var localInstructionProfile: LocalInstructionProfile?
    private var scriptInboxSocket: LocalScriptInboxSocket?
    private var scriptInboxMenu: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        setUpMainMenu()
        registerServices()
        registerHotKeys()
        observeState()

        // Review-only 해설 (auto-play off): surface the window so it can be checked.
        appState.onRequestReview = { [weak self] in self?.mainWindow.show() }
        wireAgentHandoff()
        if appState.keyPresent { appState.refreshVoices() }
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

    // MARK: - Agent script inbox (submit_script) opt-in

    /// Third, separate consent: receiving scripts enables neither playback nor instruction reads.
    @objc private func toggleScriptInbox() {
        if let socket = scriptInboxSocket {
            socket.stop(); scriptInboxSocket = nil
            scriptInboxMenu?.state = .off; appState.scriptInboxEnabled = false
            return
        }
        let box = WeakSocket()
        let socket = LocalScriptInboxSocket { [weak self, box] submission in
            guard let self, let live = box.socket, self.scriptInboxSocket === live else { return "disabled" }
            return self.appState.receiveAgentScript(displayText: submission.displayText,
                                                    speechText: submission.speechText, key: submission.key)
        }
        box.socket = socket
        guard socket.start() else {
            let alert = NSAlert()
            alert.messageText = "로컬 MCP 대본 받기를 시작할 수 없습니다"
            alert.informativeText = "소켓 경로가 이미 있거나 안전하지 않습니다. 기존 실행과 경로를 확인하세요."
            alert.runModal()
            return
        }
        scriptInboxSocket = socket
        scriptInboxMenu?.state = .on; appState.scriptInboxEnabled = true
    }

    private final class WeakSocket { weak var socket: LocalScriptInboxSocket? }

    private func wireAgentHandoff() {
        appState.onToggleScriptInbox = { [weak self] in self?.toggleScriptInbox() }
        appState.onRevokePromptGrant = { [weak self] in self?.revokeLocalInstructions() }
        appState.onRequestPromptGrant = { [weak self] kind in
            guard let self else { return }
            self.revokeLocalInstructions()
            self.beginInstructionShare(preselect: kind == .full ? .explain : .continue)
        }
    }

    // Separate consent: enabling speech must never publish instructions.
    @objc private func toggleLocalInstructions() {
        if localInstructionSocket != nil { revokeLocalInstructions(); return }
        beginInstructionShare(preselect: nil)
    }

    private func beginInstructionShare(preselect: LocalInstructionProfile.Name?) {
        let selection = NSAlert()
        selection.messageText = "로컬 MCP 지시 공유 (이번 실행)"
        selection.informativeText = "연결하려는 지시 도우미의 PID와 공유할 프로필 한 개를 지정하세요. 자동 공유되지 않습니다."
        selection.addButton(withTitle: "미리 보기")
        selection.addButton(withTitle: "취소")
        let pidField = NSTextField(frame: NSRect(x: 0, y: 33, width: 390, height: 24))
        pidField.placeholderString = "지시 도우미 PID"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 390, height: 26))
        picker.addItems(withTitles: ["에이전트 지시문: 전체 해설", "에이전트 지시문: 변경분만", "음성 대본 정규화 (사전·힌트 제외)"])
        if let preselect, let index = LocalInstructionProfile.Name.allCases.firstIndex(of: preselect) {
            picker.selectItem(at: index)
        }
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 60))
        fields.addSubview(pidField); fields.addSubview(picker)
        selection.accessoryView = fields
        guard selection.runModal() == .alertFirstButtonReturn else { return }
        let names = LocalInstructionProfile.Name.allCases
        guard let pid = Int32(pidField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let peer = LocalInstructionPeer.current(pid: pid), names.indices.contains(picker.indexOfSelectedItem),
              let profile = instructionSnapshot(names[picker.indexOfSelectedItem]) else {
            showInstructionShareError("같은 계정에서 계속 실행 중인 도우미의 PID와 공유할 수 있는 길이의 지시가 필요합니다.")
            return
        }
        let approval = NSAlert()
        approval.messageText = "PID \(pid)에 아래 지시를 공유할까요?"
        approval.informativeText = "최대 10분, 이 프로필만 읽습니다. 원격 모델을 사용하는 에이전트는 지시를 해당 서비스로 보낼 수 있습니다. 비밀이나 외부 공개할 수 없는 내용이 있으면 취소하세요."
        approval.addButton(withTitle: "이 프로필만 공유")
        approval.addButton(withTitle: "취소")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 430, height: 214)
        guard let preview = scroll.documentView as? NSTextView else { return }
        preview.isRichText = false
        preview.string = profile.text; preview.isEditable = false; preview.isSelectable = true
        approval.accessoryView = scroll
        guard approval.runModal() == .alertFirstButtonReturn else { return }
        guard instructionSnapshot(profile.name)?.revision == profile.revision else {
            showInstructionShareError("미리 보는 동안 지시가 바뀌었습니다. 새 내용을 확인한 뒤 다시 공유하세요.")
            return
        }
        let socket = LocalInstructionSocket(peer: peer, profile: profile)
        guard socket.start() else {
            showInstructionShareError("도우미가 종료됐거나 이전 소켓 경로가 남아 있습니다. 새 도우미와 소켓 상태를 확인하세요.")
            return
        }
        localInstructionSocket = socket
        localInstructionProfile = profile
        localInstructionMenu?.state = .on
        // The tab shows only "reading is allowed" for this exact wording; never sent/generating.
        if let kind = agentPromptKind(profile.name) {
            appState.promptGrant = PromptGrant(kind: kind, text: profile.text, peerPID: pid,
                                               expires: Date().addingTimeInterval(600))
        }
        let expiry = DispatchWorkItem { [weak self, weak socket] in
            guard let self, let socket, self.localInstructionSocket === socket else { return }
            self.revokeLocalInstructions()
        }
        localInstructionExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(600), execute: expiry)
    }

    private func instructionSnapshot(_ name: LocalInstructionProfile.Name) -> LocalInstructionProfile? {
        let text: String
        switch name {
        // The agent prompts: the SAME final wording the tab previews and copies.
        case .explain:
            text = appState.agentPromptFinalText(.full)
        case .continue:
            text = appState.agentPromptFinalText(.delta)
        case .normalize:
            text = appState.normalizePrompt.isEmpty ? TextNormalizer.defaultInstruction : appState.normalizePrompt
        }
        return LocalInstructionProfile(name: name, text: text)
    }

    private func agentPromptKind(_ name: LocalInstructionProfile.Name) -> AgentPromptKind? {
        switch name {
        case .explain: return .full
        case .continue: return .delta
        case .normalize: return nil
        }
    }

    private func showInstructionShareError(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "로컬 MCP 지시를 공유하지 않았습니다"
        alert.informativeText = reason
        alert.runModal()
    }

    private func revokeLocalInstructions() {
        localInstructionExpiry?.cancel(); localInstructionExpiry = nil
        localInstructionSocket?.stop(); localInstructionSocket = nil
        localInstructionProfile = nil
        localInstructionMenu?.state = .off
        if appState.promptGrant != nil { appState.promptGrant = nil }
    }

    func applicationWillTerminate(_ notification: Notification) {
        localSpeechSocket?.stop()
        scriptInboxSocket?.stop()
        revokeLocalInstructions()
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
        // An approved agent prompt is one exact wording. Any byte-level change (even one later
        // undone) ends the approval. The in-app explainPrompt is no longer shared over MCP.
        appState.$agentPrompts.dropFirst()
            .sink { [weak self] prompts in
                guard let self, let active = self.localInstructionProfile,
                      let kind = self.agentPromptKind(active.name),
                      !prompts.finalText(kind).utf8.elementsEqual(active.text.utf8) else { return }
                self.revokeLocalInstructions()
            }.store(in: &cancellables)
        appState.$normalizePrompt.dropFirst()
            .removeDuplicates(by: { $0.utf8.elementsEqual($1.utf8) })
            .sink { [weak self] _ in self?.revokeLocalInstructions() }.store(in: &cancellables)
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

    /// ⌃⌥⌘E → explain the selection, ⌃⌥⌘R → read it aloud. The selection is
    /// grabbed via a clipboard-preserving copy, so it works even where the
    /// Services menu is hidden (VS Code). First use prompts for Accessibility.
    private func registerHotKeys() {
        let mods = controlKey | optionKey | cmdKey
        hotKeys.register(id: 1, keyCode: kVK_ANSI_E, modifiers: mods) { [weak self] in
            self?.appState.captureHUDTarget()   // before the async grab: mouse is still on the target screen
            SelectionGrabber.grab { text in
                guard let self, let text else { return }
                MainActor.assumeIsolated { self.handleCodeText(text, captureTarget: false) }
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
        if appState.selectedTab == 1 && appState.explainAdvancedVisible {
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
    /// the selected text (cache-first) and play it without opening the window.
    func handleSelectedText(_ text: String) {
        let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(60)
        Log.app.info("handleSelectedText: \(text.count) chars — \"\(preview, privacy: .public)\"")
        appState.captureHUDTarget()
        appState.speakSelected(text)
    }

    /// Called by ServiceProvider when the user picks "코드 해설": explain the
    /// selected code via the LLM, then speak the commentary (코드 → 해설 → 대본 →
    /// 음성). Surfaces the 해설 tab so the result is visible.
    /// In-app generation is an advanced opt-in: unless the user enabled it, this only
    /// parks the selection in the 고급 panel and shows the window — no model call.
    func handleCodeText(_ code: String, captureTarget: Bool = true) {
        let preview = code.replacingOccurrences(of: "\n", with: " ").prefix(60)
        Log.app.info("handleCodeText: \(code.count) chars — \"\(preview, privacy: .public)\"")
        if captureTarget { appState.captureHUDTarget() }
        appState.selectedTab = 1        // 해설 탭 (2번째)
        if appState.externalExplainRequest(code) {
            appState.explainAdvancedVisible = true
        } else {
            mainWindow.show()
        }
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
        let instructions = appMenu.addItem(withTitle: "로컬 MCP 지시 공유 (이번 실행)…",
                                           action: #selector(toggleLocalInstructions), keyEquivalent: "")
        instructions.target = self
        localInstructionMenu = instructions
        let inbox = appMenu.addItem(withTitle: "로컬 MCP 대본 받기 (이번 실행)",
                                    action: #selector(toggleScriptInbox), keyEquivalent: "")
        inbox.target = self
        scriptInboxMenu = inbox
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
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Codebasic TTS 열기", action: #selector(openWindow), keyEquivalent: "").target = self
        windowMenu.addItem(withTitle: "재생 기록", action: #selector(openHistory), keyEquivalent: "").target = self
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
