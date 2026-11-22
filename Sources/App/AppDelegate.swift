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
    private var draftReceiptSocket: LocalExplanationDraftSocket?
    private var draftReceiptExpiry: DispatchWorkItem?
    private var draftReceiptMenu: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        setUpMainMenu()
        registerServices()
        registerHotKeys()
        observeState()

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

    // Separate consent: enabling speech must never publish instructions.
    @objc private func toggleLocalInstructions() { toggleInstructionSharing() }

    func toggleInstructionSharing(preselect: LocalInstructionProfile.Name? = nil) {
        if localInstructionSocket != nil { revokeLocalInstructions(); return }
        let selection = NSAlert()
        selection.messageText = "로컬 MCP 지시 공유 (이번 실행)"
        selection.informativeText = "연결하려는 지시 도우미의 PID와 공유할 프로필 한 개를 지정하세요. 자동 공유되지 않습니다."
        selection.addButton(withTitle: "미리 보기")
        selection.addButton(withTitle: "취소")
        let pidField = NSTextField(frame: NSRect(x: 0, y: 33, width: 390, height: 24))
        pidField.placeholderString = "지시 도우미 PID"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 390, height: 26))
        picker.addItems(withTitles: ["해설", "이어서 해설", "음성 대본 정규화 (사전·힌트 제외)"])
        if let preselect, let index = LocalInstructionProfile.Name.allCases.firstIndex(of: preselect) {
            picker.selectItem(at: index)
            picker.isEnabled = false
        }
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 60))
        fields.addSubview(pidField); fields.addSubview(picker)
        selection.accessoryView = fields
        guard selection.runModal() == .alertFirstButtonReturn else { return }
        let names = LocalInstructionProfile.Name.allCases
        guard let pid = Int32(pidField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let peer = LocalInstructionPeer.current(pid: pid), names.indices.contains(picker.indexOfSelectedItem),
              let profile = appState.instructionSnapshot(names[picker.indexOfSelectedItem]) else {
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
        guard approval.runModal() == .alertFirstButtonReturn, localInstructionSocket == nil else { return }
        guard appState.instructionSnapshot(profile.name)?.revision == profile.revision else {
            showInstructionShareError("미리 보는 동안 지시가 바뀌었습니다. 새 내용을 확인한 뒤 다시 공유하세요.")
            return
        }
        appState.agentSession.revokeRead(reason: .manual)
        let socket = LocalInstructionSocket(peer: peer, profile: profile)
        guard socket.start() else {
            showInstructionShareError("도우미가 종료됐거나 이전 소켓 경로가 남아 있습니다. 새 도우미와 소켓 상태를 확인하세요.")
            return
        }
        localInstructionSocket = socket
        appState.sharedInstructionProfile = profile.name
        localInstructionMenu?.state = .on
        let expiry = DispatchWorkItem { [weak self, weak socket] in
            guard let self, let socket, self.localInstructionSocket === socket else { return }
            self.revokeLocalInstructions()
        }
        localInstructionExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(600), execute: expiry)
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
        appState.sharedInstructionProfile = nil
        localInstructionMenu?.state = .off
    }

    @objc func toggleDraftReceipt() {
        if draftReceiptSocket != nil { revokeDraftReceipt(); return }
        let alert = NSAlert()
        alert.messageText = "외부 에이전트 대본 받기"
        alert.informativeText = "지정한 도우미의 대본만 최대 10분 동안 임시 보관함에 받습니다. 화면을 덮어쓰거나 재생하지 않으며, 지시문 조회도 허용하지 않습니다."
        alert.addButton(withTitle: "이 도우미만 허용")
        alert.addButton(withTitle: "취소")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "대본 도우미 PID"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn, draftReceiptSocket == nil else { return }
        guard let pid = Int32(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let peer = LocalInstructionPeer.current(pid: pid) else {
            showDraftReceiptError("같은 Mac 계정에서 현재 실행 중인 대본 도우미 PID가 필요합니다.")
            return
        }

        let workspace = appState.explanationDrafts
        appState.agentSession.revokeReceipt()
        let socket = LocalExplanationDraftSocket(peer: peer) { draft in workspace.receive(draft) }
        guard socket.start() else {
            showDraftReceiptError("도우미가 종료됐거나 대본 소켓 경로가 이미 사용 중입니다.")
            return
        }
        draftReceiptSocket = socket
        workspace.setReceiver(pid)
        draftReceiptMenu?.state = .on
        let expiry = DispatchWorkItem { [weak self, weak socket] in
            guard let self, let socket, self.draftReceiptSocket === socket else { return }
            self.revokeDraftReceipt()
        }
        draftReceiptExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(600), execute: expiry)
    }

    private func showDraftReceiptError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "대본 받기를 허용하지 않았습니다"
        alert.informativeText = message
        alert.runModal()
    }

    private func revokeDraftReceipt() {
        draftReceiptExpiry?.cancel(); draftReceiptExpiry = nil
        draftReceiptSocket?.stop(); draftReceiptSocket = nil
        appState.explanationDrafts.setReceiver(nil)
        draftReceiptMenu?.state = .off
    }

    func applicationWillTerminate(_ notification: Notification) {
        localSpeechSocket?.stop()
        revokeLocalInstructions()
        revokeDraftReceipt()
        appState.agentSession.endSession()
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
        let session = appState.agentSession
        session.onBeforeOpenReadSocket = { [weak self] in self?.revokeLocalInstructions() }
        session.onBeforeOpenReceiptSocket = { [weak self] in self?.revokeDraftReceipt() }
        session.onReadGrantStateChanged = { [weak self] profile in
            guard let self else { return }
            self.appState.sharedInstructionProfile = profile
            self.localInstructionMenu?.state = (profile != nil || self.localInstructionSocket != nil) ? .on : .off
        }
        session.onReceiptGrantStateChanged = { [weak self] pid in
            guard let self else { return }
            self.appState.explanationDrafts.setReceiver(pid)
            self.draftReceiptMenu?.state = (pid != nil || self.draftReceiptSocket != nil) ? .on : .off
        }

        appState.$explainPrompt.dropFirst()
            .removeDuplicates(by: { $0.utf8.elementsEqual($1.utf8) })
            .sink { [weak self] _ in
                self?.revokeLocalInstructions()
                self?.appState.agentSession.revokeReadIfMutated(targetWireName: "explain")
                self?.appState.agentSession.revokeReadIfMutated(targetWireName: "continue")
            }.store(in: &cancellables)
        appState.$normalizePrompt.dropFirst()
            .removeDuplicates(by: { $0.utf8.elementsEqual($1.utf8) })
            .sink { [weak self] _ in
                self?.revokeLocalInstructions()
                self?.appState.agentSession.revokeReadIfMutated(targetWireName: "normalize")
            }.store(in: &cancellables)
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
        let instructions = appMenu.addItem(withTitle: "로컬 MCP 지시 공유 (이번 실행)…",
                                           action: #selector(toggleLocalInstructions), keyEquivalent: "")
        instructions.target = self
        localInstructionMenu = instructions
        let draftReceipt = appMenu.addItem(withTitle: "외부 대본 받기 허용 (이번 실행)…",
                                           action: #selector(toggleDraftReceipt), keyEquivalent: "")
        draftReceipt.target = self
        draftReceiptMenu = draftReceipt
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
