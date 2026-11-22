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

    private var sharingSelection: String { access.instructionScope ?? "" }
    private var editorSelection: String? {
        if let editingProfile, catalog.record(editingProfile) != nil { return editingProfile }
        return access.instructionScope
    }
    private var canUsePlayer: Bool { !app.isBusy && !app.explaining && !app.normalizing }

    private enum EditorChange {
        case clear(String)
        case close(String)

        var isClosing: Bool {
            if case .close = self { return true }
            return false
        }
    }

    var body: some View {
        workspace
            .onChange(of: drafts.activeDocumentID) { _, _ in
                showSpeech = !drafts.speech.isEmpty
            }
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
                HStack(alignment: .top, spacing: 0) {
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
                     ? "이미 받은 대본은 보관함에 남지만, 이 지시 버전의 새 대본은 받을 수 없습니다."
                     : "이 지시의 저장하지 않은 변경도 함께 사라집니다. 이미 받은 대본은 그대로 남습니다.")
            }
            .confirmationDialog(editorChange?.isClosing == true ? "저장하지 않은 대본을 닫을까요?" : "편집기의 글을 비울까요?",
                                isPresented: $confirmEditorChange, titleVisibility: .visible, presenting: editorChange) { change in
                Button(change.isClosing ? "닫기" : "비우기", role: .destructive) {
                    switch change {
                    case .clear(let id): drafts.clearEditor(expectedDocumentID: id)
                    case .close(let id): drafts.closeInactiveDocument(id)
                    }
                    editorChange = nil
                }
                Button("취소", role: .cancel) { editorChange = nil }
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("에이전트 연결").font(.headline).accessibilityAddTraits(.isHeader)
                Text(access.receiving ? "대본 받는 중" : access.waitingForReceiveHelper
                     ? "MCP 시작 대기 중" : access.pair != nil ? "사용 가능" : "연결 안 됨")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("지시문") { showInstructions.toggle() }
                    .accessibilityValue(showInstructions ? "열림" : "닫힘")
            }
            HStack(alignment: .top) {
                mcpSetup
                Spacer(minLength: 8)
                Button(access.receiving ? "연결 끄기" : access.waitingForReceiveHelper ? "연결 취소" : "연결 켜기") {
                    AppDelegate.shared?.toggleDraftReceipt()
                }
                if access.pair != nil {
                    Button("연결 해제") { access.disconnect() }
                }
            }
            if !access.status.isEmpty { Text(access.status).font(.caption).foregroundStyle(.orange) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-connection-section")
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
            Text("공유 지시를 선택하지 않아도 대본을 받을 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
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
            } else {
                Text("선택된 지시문이 없습니다.")
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
                                .accessibilityAddTraits(option.id == sharingSelection ? .isSelected : [])
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
            if let setup = AgentMCPConfiguration.bundled() {
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

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("대본").font(.headline).accessibilityAddTraits(.isHeader)
            if drafts.hasInactiveDocuments { documentTabs }
            HStack {
                Text("화면 글 · 자막").font(.subheadline.weight(.semibold))
                if let origin = drafts.origin {
                    Text(drafts.canRevertReceived ? origin.rawValue + " · 직접 수정함" : origin.rawValue)
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                    editorChange = .clear(drafts.editorDocumentID)
                    confirmEditorChange = true
                }
                    .disabled(!drafts.hasEditorContent)
            }
            TextEditor(text: Binding(get: { drafts.display }, set: { drafts.editDisplay($0) }))
                .font(.body).frame(minHeight: 240)
                .overlay(editorBorder)
                .accessibilityLabel("받은 대본 및 화면 글")
            if drafts.canRevertReceived {
                Button("받은 원문으로 되돌리기") { drafts.revertReceivedDocument() }
            }

            DisclosureGroup("별도 음성 대본 (선택)", isExpanded: $showSpeech) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("비워 두면 화면 글을 읽습니다. 발음용 대본은 여기에 따로 붙여넣거나 편집하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { drafts.speech }, set: { drafts.editSpeech($0) }))
                        .font(.body).frame(minHeight: 105)
                        .overlay(editorBorder)
                        .accessibilityLabel("별도 음성 대본")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { app.playExplanationDraft() } label: { Label("그대로 재생", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canUsePlayer || drafts.playback() == nil)
                if !drafts.speech.isEmpty {
                    Button("화면 글 그대로 읽기") { app.playExplanationDraft(displayOnly: true) }
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

    private var documentTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(drafts.documentTabs) { tab in
                    HStack(spacing: 2) {
                        Button {
                            drafts.selectDocument(tab.id)
                        } label: {
                            Text(verbatim: tab.title + (tab.dirty ? " •" : "")).lineLimit(1)
                        }
                        .accessibilityAddTraits(tab.id == drafts.activeDocumentID ? .isSelected : [])
                        if tab.id != drafts.activeDocumentID {
                            Button {
                                if tab.dirty {
                                    editorChange = .close(tab.id)
                                    confirmEditorChange = true
                                }
                                else { drafts.closeInactiveDocument(tab.id) }
                            } label: {
                                Image(systemName: "xmark").accessibilityLabel("대본 탭 닫기")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .accessibilityLabel("열린 대본")
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
