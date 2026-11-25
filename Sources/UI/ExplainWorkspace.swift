import AppKit
import SwiftUI

/// Default Explain mode. Other agents write drafts; this view manages the
/// instruction and lets the user decide what to edit and actually read.
struct ExplainWorkspace: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var drafts: ExplanationDraftWorkspace
    @ObservedObject var catalog: AgentCatalog
    @ObservedObject var access: AgentSessionController
    @State private var editingProfile: String?
    @State private var showInstructions = false
    @State private var profileSearch = ""
    @State private var showProfileChooser = false
    @FocusState private var profileSearchFocused: Bool
    @State private var catalogEdit: AgentCatalogEditor.Target?
    @State private var removeProfile: AgentCatalogRecord?
    @State private var showRemove = false
    @State private var catalogError = ""
    @State private var showSpeech = false
    @State private var showAdvanced = false
    @State private var editorChange: EditorChange?
    @State private var confirmEditorChange = false
    @State private var instructionEdits = AgentInstructionEditBuffer()
    @State private var copiedMCPClient: String?
    @AppStorage("draftHistoryOpen") private var historyOpen = true
    @State private var historySearch = ""
    @State private var historyAnchor: String?

    private var sharingSelection: String { access.instructionScope ?? "" }
    private var editorSelection: String? {
        if let editingProfile,
           catalog.record(editingProfile) != nil || LocalInstructionProfile.Name(rawValue: editingProfile) != nil {
            return editingProfile
        }
        return access.instructionScope
    }
    private var canUsePlayer: Bool { !app.isBusy && !app.explaining && !app.normalizing }

    private enum EditorChange {
        case clear(String)
        case close(String, title: String)
        case closeActive(String, title: String)
        case revert(String)

        var question: String {
            switch self {
            case .clear: return "편집기의 글을 비울까요?"
            case .close(_, let title), .closeActive(_, let title): return "수정한 대본 ‘\(title)’을 닫을까요? 수정한 내용이 사라집니다."
            case .revert: return "받은 원문으로 되돌릴까요? 화면 글과 음성 대본의 수정이 사라집니다."
            }
        }

        var confirmation: String {
            switch self {
            case .clear: return "비우기"
            case .close, .closeActive: return "닫기"
            case .revert: return "되돌리기"
            }
        }
    }

    var body: some View {
        workspace
            .onChange(of: drafts.activeDocumentID) { _, _ in
                showSpeech = !drafts.speech.isEmpty
            }
            .onChange(of: drafts.arrivalCount) { _, _ in
                drafts.markArrivalsSeen()
                // The editor changed under the user; say so for VoiceOver as well.
                if let window = NSApp.keyWindow ?? NSApp.mainWindow, let notice = drafts.arrivalNotice {
                    NSAccessibility.post(element: window, notification: .announcementRequested,
                                         userInfo: [.announcement: notice, .priority: NSAccessibilityPriorityLevel.high.rawValue])
                }
            }
            .onAppear { drafts.markArrivalsSeen() }
    }

    @ViewBuilder private var workspace: some View {
        if showAdvanced {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button { showAdvanced = false } label: { Label("외부 에이전트 작업 공간", systemImage: "chevron.left") }
                    Spacer()
                    Text("고급 · 앱에서 직접 해설 생성").foregroundStyle(.secondary)
                }
                .padding([.top, .horizontal])
                CommentaryView()
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                connection.padding()
                Divider()
                GeometryReader { area in
                // Beside the editor when there is room. With the instruction panel
                // open in a narrow window the list folds away rather than squeeze either.
                let showHistory = historyOpen && (!showInstructions || area.size.width >= 900)
                HStack(alignment: .top, spacing: 0) {
                    if showHistory {
                        history.padding(10).frame(width: 230)
                        Divider()
                    } else {
                        historyHandle.padding(.vertical, 10).padding(.horizontal, 4)
                        Divider()
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            editor
                            if !TTSRuntime.isPreview {
                                Button("고급: 앱에서 직접 해설 생성…") { showAdvanced = true }
                                    .controlSize(.small)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if showInstructions {
                        Divider()
                        ScrollView {
                            instruction.padding()
                        }
                        .frame(width: 337)
                    }
                }
                }
            }
            .onAppear { _ = catalog.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                _ = catalog.refresh()
            }
            .sheet(item: $catalogEdit) { item in
                AgentCatalogEditor(target: item) { label, body in
                    let saved = try catalog.save(id: item.record?.id, expected: item.record?.editVersion,
                                                 label: label, body: body)
                    editingProfile = saved.selector
                    catalogError = ""
                }
            }
            .alert("이 지시문을 삭제할까요?", isPresented: $showRemove) {
                Button("삭제", role: .destructive) {
                    guard let old = removeProfile else { return }
                    do {
                        try catalog.delete(old.id, expected: old.editVersion)
                        instructionEdits.revert(old.selector)
                        if editingProfile == old.selector { editingProfile = nil }
                        catalogError = ""
                    } catch { catalogError = error.localizedDescription }
                    removeProfile = nil
                }
                Button("취소", role: .cancel) { removeProfile = nil }
            } message: {
                Text(removeProfile.flatMap { instructionEdits.drafts[$0.selector] } == nil
                     ? "이미 받은 대본은 목록에 그대로 남지만, 이 지시 버전의 새 대본은 받을 수 없습니다."
                     : "이 지시의 저장하지 않은 변경도 함께 사라집니다. 이미 받은 대본은 그대로 남습니다.")
            }
            .confirmationDialog(editorChange?.question ?? "", isPresented: $confirmEditorChange,
                                titleVisibility: .visible, presenting: editorChange) { change in
                Button(change.confirmation, role: .destructive) {
                    switch change {
                    case .clear(let id): drafts.clearEditor(expectedDocumentID: id)
                    case .close(let id, _): drafts.closeInactiveDocument(id)
                    case .closeActive(let id, _): drafts.closeActiveDocument(expectedDocumentID: id)
                    case .revert(let id): drafts.revertReceivedDocument(expectedDocumentID: id)
                    }
                    editorChange = nil
                }
                Button("취소", role: .cancel) { editorChange = nil }
            }
        }
    }

    private var connectionState: String {
        if access.locked { return "화면 잠금으로 멈춤" }
        if !access.autoReceive { return "전체 받기 꺼짐" }
        if access.receiving { return "대본 받는 중" }
        if !access.approvalRequests.isEmpty { return "앱 승인 대기 중" }
        return "앱 연결 대기 중"
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("에이전트 연결").font(.headline).accessibilityAddTraits(.isHeader)
                Text(connectionState).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("지시문") { showInstructions.toggle() }
                    .accessibilityValue(showInstructions ? "열림" : "닫힘")
                    .help("공유할 지시를 고르거나 편집하는 패널을 엽니다.")
            }
            HStack(alignment: .top) {
                mcpSetup
                Spacer(minLength: 8)
                Button(access.autoReceive ? "전체 받기 끄기" : "전체 받기 켜기") {
                    AppDelegate.shared?.toggleDraftReceipt()
                }
                .disabled(!access.pairingSupported || (access.locked && !access.autoReceive))
            }
            ForEach(access.approvalRequests) { request in
                let host = request.host.map { Self.hostName($0) + " · PID \(request.helperPID)" }
                    ?? Self.sessionOnlyDescription(request.launcher, pid: request.helperPID)
                HStack {
                    VStack(alignment: .leading) {
                        Text(request.label)
                        Text(host)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button("허용") { access.approve(request.id) }
                        .accessibilityLabel("‘\(request.label)’ 허용")
                        .accessibilityHint(host)
                        .disabled(!access.autoReceive || access.locked)
                }
                .font(.caption)
            }
            if !access.connections.isEmpty { agentConnections }
            if access.receiptBlockedBySelection {
                HStack(alignment: .firstTextBaseline) {
                    Label("선택한 지시를 공유할 수 없어 해당 앱의 대본을 기다리고 있습니다.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("지시문 열기") { showInstructions = true }.controlSize(.small)
                    Button("지시 없이 받기") { access.revokeSelection() }.controlSize(.small)
                }
            } else if let shared = access.shared,
                      let client = access.connections.first(where: { $0.id == access.instructionClient }) {
                Text("‘\(client.label)’에 공유 중: \(title(shared.selector))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = access.receiptNotice {
                Label(notice, systemImage: "tray.and.arrow.down").font(.caption).foregroundStyle(.orange)
            }
            if !access.status.isEmpty { Text(access.status).font(.caption).foregroundStyle(.orange) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-connection-section")
    }

    private var agentConnections: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(access.connections) { client in
                let host = client.host.map(Self.hostName) ?? Self.sessionOnlyDescription(client.launcher, pid: client.helperPID)
                HStack {
                    VStack(alignment: .leading) {
                        Text(client.label)
                        Text(host)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    let needsInstruction = access.instructionClient == client.id && access.receiptBlockedBySelection
                    Text(needsInstruction ? "지시 필요" : Self.connectionState(client.state))
                        .foregroundStyle(needsInstruction ? Color.orange : Color.secondary)
                    Spacer(minLength: 8)
                    if client.state != .needsApproval {
                        Button(client.receiptEnabled ? "이 앱 받기 끄기" : "이 앱 받기 켜기") {
                            if client.receiptEnabled { _ = access.disconnect(client.id) }
                            else { _ = access.resume(client.id) }
                        }
                        .disabled(!client.receiptEnabled && (!access.autoReceive || access.locked))
                        .accessibilityLabel("‘\(client.label)’ 받기 \(client.receiptEnabled ? "끄기" : "켜기")")
                        .accessibilityHint(host)
                    }
                    Button("승인 철회") { access.forget(client.id) }
                        .accessibilityLabel("‘\(client.label)’ 승인 철회")
                        .accessibilityHint(host)
                }
                .controlSize(.small)
            }
        }
        .font(.caption)
        .accessibilityIdentifier("agent-trusted-clients")
    }

    private static func connectionState(_ state: AgentSessionController.Connection.State) -> String {
        switch state {
        case .waiting: return "연결 대기"
        case .receiving: return "받는 중"
        case .paused: return "받기 꺼짐"
        case .locked: return "화면 잠금"
        case .needsApproval: return "재승인 필요"
        }
    }

    private static func sessionOnlyDescription(_ launcher: String?, pid: Int32?) -> String {
        let name = launcher.map { URL(fileURLWithPath: $0).lastPathComponent }
        let detail = [name, pid.map { "PID \($0)" }].compactMap { $0 }.joined(separator: " · ")
        return detail.isEmpty ? "호스트 미확인 · 이번 실행만" : "\(detail) · 호스트 미확인 · 이번 실행만"
    }

    private static func hostName(_ host: String) -> String {
        if host.hasPrefix("path:") { return URL(fileURLWithPath: String(host.dropFirst(5))).lastPathComponent }
        let fields = host.split(separator: ":", maxSplits: 2)
        if fields.count == 3, fields[0] == "registered-v1" {
            return "\(fields[2]) · 서명 \(fields[1].prefix(12))"
        }
        if fields.count == 3 { return String(fields[1]) }
        return "호스트 미확인"
    }

    private var instruction: some View {
        let editorSelection = self.editorSelection
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("지시문").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                profileChooser
                Button("새 지시…") { catalogEdit = .init(record: nil) }
                    .disabled(catalog.readError || catalog.records.count >= AgentLimits.profiles)
            }
            Text("공유 지시를 선택하지 않아도 대본을 받을 수 있습니다. 공유하면 연결된 에이전트가 저장된 지시 전문을 읽으며, 원격 모델을 쓰는 에이전트는 그 내용을 모델 서비스로 보낼 수 있습니다. 비밀은 넣지 마세요.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let recipients = access.connections.filter { $0.state != .needsApproval }
            if recipients.count > 1 {
                Picker("공유할 앱", selection: Binding(get: { access.instructionClient },
                                                   set: { access.chooseInstructionClient($0) })) {
                    Text("앱 선택").tag(UUID?.none)
                    ForEach(recipients) { client in
                        Text("\(client.label) · \(client.host.map(Self.hostName) ?? Self.sessionOnlyDescription(client.launcher, pid: client.helperPID))")
                            .tag(Optional(client.id))
                    }
                }
            }
            Text(access.shared.map { "공유 중: " + title($0.selector) } ?? access.selectionStatus.message)
                .font(.caption).foregroundStyle(access.selectionStatus.isProblem ? Color.orange : Color.secondary)
            if let legacy = app.sharedInstructionProfile {
                Text("기존 지시 공유 중: \(name(legacy))").font(.caption).foregroundStyle(.secondary)
            }
            if catalog.readError || !catalogError.isEmpty {
                Text(catalog.readError ? AgentCatalog.Failure.unreadable.localizedDescription : catalogError)
                    .font(.caption).foregroundStyle(.orange)
            }
            if let editorSelection, let snapshot = app.agentSnapshot(editorSelection) {
                if editorSelection != sharingSelection {
                    Text("편집 중: \(title(editorSelection)) · 공유 선택 안 됨")
                        .font(.caption).foregroundStyle(.secondary)
                }
                instructionEditor(snapshot)
            } else if let editorSelection, LocalInstructionProfile.Name(rawValue: editorSelection) != nil, app.agentPresetUnreadable {
                Text("기본 지시의 저장 파일을 읽을 수 없어 공유하거나 편집할 수 없습니다. 파일을 확인한 뒤 앱을 다시 여세요.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("선택된 지시문이 없습니다. ‘공유 지시’ 목록에서 공유하거나 편집할 지시를 고르세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let editorSelection, let entry = catalog.record(editorSelection) {
                Button("지시 삭제…", role: .destructive) { removeProfile = entry; showRemove = true }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-instruction-section")
    }

    private var profileChooser: some View {
        let currentTitle = sharingSelection.isEmpty ? "사용 안 함" : title(sharingSelection)
        return Button {
            profileSearch = ""
            showProfileChooser.toggle()
        } label: {
            HStack(spacing: 6) {
                Text("공유 지시: \(currentTitle)").lineLimit(1)
                Image(systemName: "chevron.down").accessibilityHidden(true)
            }
        }
        .accessibilityLabel("공유 지시 선택")
        .accessibilityValue(currentTitle)
        .accessibilityHint("열면 이름을 검색할 수 있습니다. 항목을 직접 선택해야 바뀝니다.")
        .popover(isPresented: $showProfileChooser, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("공유 지시 선택").font(.headline)
                Text("이름을 누르면 그 지시를 공유합니다. 공유를 바꾸지 않고 내용만 보려면 ‘편집’을 누르세요.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("지시 이름 검색", text: $profileSearch)
                    .textFieldStyle(.roundedBorder)
                    .focused($profileSearchFocused)
                    .accessibilityLabel("지시 이름 검색")
                    .accessibilityHint("검색 결과가 한 개일 때 Return 키로 선택합니다.")
                    .onSubmit {
                        if let id = AgentInstructionChoice.keyboardChoice(profileOptions, query: profileSearch) {
                            chooseProfile(id)
                        }
                    }
                let matches = AgentInstructionChoice.matching(profileOptions, query: profileSearch)
                if matches.isEmpty {
                    Text("일치하는 지시문이 없습니다. 다른 이름으로 검색해 보세요.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(matches) { option in
                                HStack(spacing: 6) {
                                    Button { chooseProfile(option.id) } label: {
                                        HStack {
                                            Text(option.label)
                                            Spacer()
                                            if option.id == sharingSelection { Image(systemName: "checkmark").accessibilityHidden(true) }
                                        }
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(option.id.isEmpty ? "공유 사용 안 함" : "‘\(option.label)’ 공유")
                                    .accessibilityAddTraits(option.id == sharingSelection ? .isSelected : [])
                                    if !option.id.isEmpty {
                                        Button("편집") {
                                            showProfileChooser = false
                                            editingProfile = option.id
                                        }
                                        .controlSize(.small)
                                        .accessibilityLabel("‘\(option.label)’ 편집만 하기")
                                        .accessibilityHint("공유 중인 지시는 바뀌지 않습니다.")
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 215)
                }
            }
            .padding(12)
            .frame(width: 325)
            .onAppear { profileSearchFocused = true }
            .onExitCommand { showProfileChooser = false }
        }
    }

    private var profileOptions: [AgentInstructionChoice] {
        [AgentInstructionChoice(id: "", label: "사용 안 함")]
            + LocalInstructionProfile.Name.allCases.map { AgentInstructionChoice(id: $0.rawValue, label: name($0)) }
            + (catalog.readError ? [] : catalog.records.map { AgentInstructionChoice(id: $0.selector, label: $0.label) })
    }

    private func instructionEditor(_ snapshot: AgentInstructionSnapshot) -> some View {
        let selector = snapshot.selector
        let record = catalog.record(selector)
        let entry = instructionEdits.entry(for: selector,
                                          expected: record?.editVersion ?? snapshot.generation,
                                          label: record?.label ?? title(selector),
                                          text: snapshot.text)
        let isValid = AgentBytes.textValid(entry.text)
        let wasDirty = entry.isDirty
        return VStack(alignment: .leading, spacing: 6) {
            if record == nil {
                Text(entry.label).font(.subheadline.weight(.semibold))
            } else {
                TextField("지시 이름", text: Binding(get: {
                    instructionEdits.drafts[selector]?.label ?? entry.label
                }, set: { label in
                    var edited = instructionEdits.drafts[selector] ?? entry
                    edited.label = label
                    instructionEdits.update(edited, for: selector)
                }))
                .accessibilityLabel("지시 이름")
            }
            TextEditor(text: Binding(get: {
                instructionEdits.drafts[selector]?.text ?? entry.text
            }, set: { text in
                var edited = instructionEdits.drafts[selector] ?? entry
                edited.text = text
                instructionEdits.update(edited, for: selector)
            }))
            .font(.callout.monospaced())
            .frame(height: 175)
            .overlay(editorBorder)
            .accessibilityLabel("선택한 에이전트 지시 편집기")
            .id(selector)
            HStack {
                Text(wasDirty ? "저장하지 않은 변경 · 에이전트에는 저장본만 공유됩니다." : "저장된 지시 · 여기에서 바로 편집할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("되돌리기") {
                    _ = catalog.refresh()
                    instructionEdits.revert(selector)
                    catalogError = ""
                }
                .disabled(!wasDirty)
                Button("저장") {
                    saveInstruction(selector, pending: entry, record: record)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!wasDirty || !isValid || (record != nil && AgentBytes.label(entry.label) == nil))
            }
            if !isValid {
                Text("빈 지시나 UTF-8 8KB를 넘는 지시는 저장할 수 없습니다. 저장본은 그대로입니다.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func saveInstruction(_ selector: String, pending: AgentInstructionEditBuffer.Entry, record: AgentCatalogRecord?) {
        do {
            if let record {
                _ = try catalog.save(id: record.id, expected: pending.expected, label: pending.label, body: pending.text)
            } else {
                try app.saveAgentPresetInstruction(selector, expected: pending.expected, text: pending.text)
            }
            instructionEdits.revert(selector)
            catalogError = ""
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private var mcpSetup: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !access.pairingSupported {
                Text("이 빌드는 안정 서명이 없어 에이전트 연결을 쓸 수 없습니다. README의 ‘Stable signing’대로 서명해 다시 빌드하세요.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let setup = AgentMCPConfiguration.bundled() {
                HStack {
                    Menu("MCP 설정 복사") {
                        Button("Codex · config.toml") {
                            copyMCP(setup.codexTOML, client: "Codex")
                        }
                        if let command = setup.claudeCodeCommand {
                            Button("Claude Code · 터미널 등록 명령") {
                                copyMCP(command, client: "Claude Code")
                            }
                        }
                    }
                    .accessibilityLabel("MCP 설정 복사")
                    .accessibilityHint("Codex 또는 Claude Code 설정을 클립보드에 복사합니다.")
                    if let copiedMCPClient {
                        Text("\(copiedMCPClient) 설정 복사됨").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let copiedMCPClient {
                    Text(copiedMCPClient == "Codex" ? "config.toml에 붙여넣으세요." : "터미널에 붙여넣고 실행하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("앱에 실행 가능한 MCP 도우미가 없어 설정을 복사할 수 없습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func copyMCP(_ text: String, client: String) {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        if clipboard.setString(text, forType: .string) { copiedMCPClient = client }
    }

    private func title(_ selector: String) -> String {
        if let builtIn = LocalInstructionProfile.Name(rawValue: selector) { return name(builtIn) }
        return catalog.record(selector)?.label ?? selector
    }

    private func chooseProfile(_ selector: String) {
        showProfileChooser = false
        editingProfile = nil
        if selector.isEmpty { access.revokeSelection() }
        else { AppDelegate.shared?.selectAgentInstruction(selector) }
    }

    /// Which instruction, if any, the open document was written against.
    private var sourceDescription: String? {
        guard drafts.activeOriginal != nil else { return drafts.origin?.rawValue }
        guard let source = drafts.provenance else { return "받은 대본 · 지시 없이 수신" }
        let known = LocalInstructionProfile.Name(rawValue: source.selector) != nil || catalog.record(source.selector) != nil
        return "받은 대본 · 지시 ‘\(known ? title(source.selector) : "삭제된 지시")’ · 버전 \(source.revision.uuidString.lowercased().prefix(8))"
    }

    private var editor: some View {
        let documentID = drafts.editorDocumentID
        return VStack(alignment: .leading, spacing: 8) {
            // The title names the document; it is not part of the text below.
            Text(verbatim: drafts.documentTabs.first { $0.id == documentID }?.title ?? "새 대본")
                .font(.headline).lineLimit(1).truncationMode(.tail)
                .help(drafts.documentTabs.first { $0.id == documentID }?.title ?? "새 대본")
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("draft-title")
            if let notice = drafts.arrivalNotice {
                HStack {
                    Label(notice, systemImage: "tray.and.arrow.down.fill").font(.caption)
                    Spacer()
                    Button("확인") { drafts.dismissArrivalNotice() }.controlSize(.small)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
            }
            HStack {
                Text("화면 글 · 자막").font(.subheadline.weight(.semibold))
                Spacer()
                Button("화면 글 붙여넣기") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        // Normal Cmd+V remains available for inserting or replacing
                        // selected text. The button does not replace a live draft.
                        let merged = drafts.display.isEmpty ? text : drafts.display + "\n\n" + text
                        drafts.editDisplay(merged, pasted: true)
                    }
                }
                .help("텍스트가 이미 있으면 끝에 추가합니다.")
                Button("비우기…") {
                    editorChange = .clear(documentID)
                    confirmEditorChange = true
                }
                    .disabled(!drafts.hasEditorContent)
            }
            if let sourceDescription {
                Text(drafts.canRevertReceived ? sourceDescription + " · 직접 수정함" : sourceDescription)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityLabel("대본 출처: " + sourceDescription)
            }
            // One editor per document: undo history and in-progress input never
            // carry over to a document that arrived or was selected afterwards.
            TextEditor(text: Binding(get: { drafts.display }, set: { drafts.editDisplay($0) }))
                .font(.body).frame(minHeight: 240)
                .overlay(editorBorder)
                .accessibilityLabel("받은 대본 및 화면 글")
                .id("display-" + documentID)
            if drafts.canRevertReceived {
                Button("받은 원문으로 되돌리기…") {
                    editorChange = .revert(documentID)
                    confirmEditorChange = true
                }
            }

            DisclosureGroup("별도 음성 대본 (선택)", isExpanded: $showSpeech) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("비워 두면 화면 글을 읽습니다. 발음용 대본은 여기에 따로 붙여넣거나 편집하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { drafts.speech }, set: { drafts.editSpeech($0) }))
                        .font(.body).frame(minHeight: 105)
                        .overlay(editorBorder)
                        .accessibilityLabel("별도 음성 대본")
                        .id("speech-" + drafts.editorDocumentID)
                }
                .padding(.top, 5)
            }
            if drafts.speechNeedsReview {
                HStack {
                    Label("음성 대본이 화면 글과 다르거나 수정되었습니다. 재생 전에 두 내용을 확인하세요.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(showSpeech ? "검토 완료 · 기존 음성 사용" : "음성 대본 열기") {
                        if showSpeech { drafts.confirmSpeech() }
                        else { showSpeech = true }
                    }
                }
            }
            if drafts.provenance?.selector == "continue",
               drafts.display.trimmingCharacters(in: .whitespacesAndNewlines) == CodeExplanation.noChange {
                Text("변경 없음 · 읽을 대본이 없습니다.").font(.caption).foregroundStyle(.secondary)
            }
            if !AgentBytes.safeForSpeech(drafts.display) || !AgentBytes.safeForSpeech(drafts.speech) {
                Text("재생할 글에서는 SSML·태그·인코딩된 태그를 제거하세요.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if TTSRuntime.isPreview {
                Text("프리뷰에서는 대본 수신과 편집을 확인할 수 있습니다. 음성 합성은 꺼져 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                playbackControls
            }
        }
    }

    private var playbackControls: some View {
        // Captured when drawn: a click that lands after another draft arrived is ignored.
        let documentID = drafts.editorDocumentID
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { app.playExplanationDraft(expectedDocumentID: documentID) } label: { Label("그대로 재생", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canUsePlayer || drafts.playback() == nil)
                if !drafts.speech.isEmpty {
                    Button("화면 글 그대로 읽기") { app.playExplanationDraft(displayOnly: true, expectedDocumentID: documentID) }
                        .disabled(!canUsePlayer || drafts.playback(displayOnly: true) == nil)
                }
                Button { app.stop() } label: { Label("중지", systemImage: "stop.fill") }
                    .disabled(!app.isBusy)
                if app.isBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if app.isBusy || app.statusText.hasPrefix("오류:") {
                Text(app.statusText.hasPrefix("오류:") ? app.statusText : "음성 재생 기능 사용 중")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var historyRows: [ExplanationDraftWorkspace.DocumentTab] {
        let term = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let newestFirst = drafts.documentTabs.reversed()
        return term.isEmpty ? Array(newestFirst) : newestFirst.filter { $0.title.localizedStandardContains(term) }
    }

    /// Shown in place of the list when it is folded away.
    private var historyHandle: some View {
        Button {
            historyOpen = true
            // In a narrow window the two side panels take turns.
            if showInstructions { showInstructions = false }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "sidebar.left")
                Text("\(drafts.documentTabs.count)").font(.caption2)
            }
        }
        .buttonStyle(.borderless)
        .help("대본 목록 펼치기")
        .accessibilityLabel("대본 목록 펼치기, \(drafts.documentTabs.count)건")
    }

    /// Every draft, newest first. Browsing only: folding, searching and new
    /// arrivals never close, remove or overwrite an entry.
    private var history: some View {
        let rows = historyRows
        let activeID = drafts.editorDocumentID
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("대본 목록").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("\(drafts.documentTabs.count)").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { _ = drafts.newDocument() } label: {
                    Image(systemName: "plus").accessibilityLabel("새 빈 대본")
                }
                .buttonStyle(.borderless)
                .disabled(!drafts.hasEditorContent && drafts.activeDocumentID == nil)
                .help("지금 글은 목록에 두고 빈 대본을 엽니다.")
                Button { historyOpen = false } label: {
                    Image(systemName: "sidebar.left").accessibilityLabel("대본 목록 접기")
                }
                .buttonStyle(.borderless)
                .help("목록을 접습니다. 대본은 그대로 있습니다.")
            }
            TextField("제목 검색", text: $historySearch)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .accessibilityLabel("대본 제목 검색")
            if rows.isEmpty {
                Text(drafts.documentTabs.isEmpty ? "아직 대본이 없습니다." : "제목에 ‘\(historySearch)’가 들어간 대본이 없습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in historyRow(row, isActive: row.id == activeID) }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $historyAnchor, anchor: .top)
            .focusable()
            .onMoveCommand { direction in
                guard let current = rows.firstIndex(where: { $0.id == activeID }) else {
                    if let first = rows.first { drafts.selectDocument(first.id) }
                    return
                }
                let next = direction == .up ? current - 1 : direction == .down ? current + 1 : current
                if next != current, rows.indices.contains(next) { drafts.selectDocument(rows[next].id) }
            }
            .accessibilityLabel("대본 목록")
        }
        .onChange(of: historySearch) { _, term in
            drafts.browsing = !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onChange(of: drafts.documentTabs.last?.id) { previous, newest in
            // Someone reading the top sees the new arrival; someone scrolled down stays put.
            if historyAnchor == nil || historyAnchor == previous { historyAnchor = newest }
        }
        .onDisappear { drafts.browsing = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("draft-history")
    }

    private func historyRow(_ row: ExplanationDraftWorkspace.DocumentTab, isActive: Bool) -> some View {
        let stamp = Calendar.current.isDateInToday(row.date)
            ? row.date.formatted(date: .omitted, time: .shortened)
            : row.date.formatted(date: .abbreviated, time: .shortened)
        let state = [row.unseen ? "새 대본" : nil, row.dirty ? "수정됨" : nil, row.received ? nil : "직접 입력"].compactMap { $0 }
        return HStack(spacing: 2) {
            Button { drafts.selectDocument(row.id) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if row.unseen { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                        Text(verbatim: row.title).lineLimit(1).truncationMode(.tail)
                            .fontWeight(isActive || row.unseen ? .semibold : .regular)
                        if row.dirty { Text("•").foregroundStyle(.orange) }
                    }
                    Text(([stamp] + state).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.title)
            .accessibilityLabel(([row.title, stamp] + state).joined(separator: ", "))
            .accessibilityAddTraits(isActive ? .isSelected : [])
            Button {
                if row.dirty {
                    editorChange = isActive ? .closeActive(row.id, title: row.title) : .close(row.id, title: row.title)
                    confirmEditorChange = true
                } else if isActive {
                    drafts.closeActiveDocument(expectedDocumentID: row.id)
                } else {
                    drafts.closeInactiveDocument(row.id)
                }
            } label: {
                Image(systemName: "xmark").font(.caption2).accessibilityLabel("‘\(row.title)’ 닫기")
            }
            .buttonStyle(.borderless)
            .help("이 대본을 목록에서 닫습니다.")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear))
        .id(row.id)
    }

    private var editorBorder: some View { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }

    private func name(_ profile: LocalInstructionProfile.Name) -> String {
        switch profile {
        case .explain: return "전체 해설"
        case .continue: return "변경분만"
        case .normalize: return "음성 대본 정규화"
        }
    }


}

private struct AgentCatalogEditor: View {
    struct Target: Identifiable { let id = UUID(); let record: AgentCatalogRecord? }
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var bodyText: String
    @State private var failure = ""
    let target: Target
    let save: (String, String) throws -> Void

    init(target: Target, save: @escaping (String, String) throws -> Void) {
        self.target = target
        self.save = save
        _label = State(initialValue: target.record?.label ?? "")
        _bodyText = State(initialValue: target.record?.body ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target.record == nil ? "새 지시문" : "지시문 편집").font(.headline)
            TextField("이름 (Mac에서만 표시)", text: $label)
            TextEditor(text: $bodyText).font(.callout.monospaced())
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("공유할 수 있는 지시문 원문")
            if !failure.isEmpty { Text(failure).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("\(bodyText.utf8.count) / \(AgentLimits.textBytes) UTF-8 바이트")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button("로컬에 저장") {
                    do { try save(label, bodyText); dismiss() }
                    catch { failure = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding().frame(minWidth: 540, minHeight: 355)
    }
}
