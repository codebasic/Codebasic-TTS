import AppKit
import SwiftUI

/// Default Explain mode. Other agents write drafts; this view manages the
/// instruction and lets the user decide what to edit and actually read.
struct ExplainWorkspace: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var drafts: ExplanationDraftWorkspace
    @ObservedObject var catalog: AgentCatalog
    @ObservedObject var access: AgentSessionController
    @State private var profile = "explain"
    @State private var profileSearch = ""
    @State private var catalogEdit: AgentCatalogEditor.Target?
    @State private var removeProfile: AgentCatalogRecord?
    @State private var showRemove = false
    @State private var catalogError = ""
    @State private var showInstructionEditor = false
    @State private var showExactPreview = false
    @State private var showSpeech = false
    @State private var showInbox = false
    @State private var showAdvanced = false
    @State private var pendingReplacement: String?
    @State private var confirmEditorChange = false
    @State private var copiedRevision: String?

    private var selectedSnapshot: AgentInstructionSnapshot? { app.agentSnapshot(profile) }
    private var canUsePlayer: Bool { !app.isBusy && !app.explaining && !app.normalizing }
    private var selectedRecord: AgentCatalogRecord? { catalog.record(profile) }

    var body: some View {
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
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    instruction
                    Divider()
                    inbox
                    editor
                    Divider()
                    HStack {
                        Text("외부 에이전트가 대본을 만들고, 여기서는 편집하고 읽습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("고급: 앱에서 직접 해설 생성…") { showAdvanced = true }
                            .controlSize(.small)
                            .help("이 기능은 외부 대본 작업 공간과 분리됩니다. 생성 버튼을 누르면 선택한 AI 서비스가 사용됩니다.")
                    }
                }
                .padding()
                .frame(maxWidth: 1050)
                .frame(maxWidth: .infinity)
            }
            .onAppear { _ = catalog.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                _ = catalog.refresh()
            }
            .sheet(isPresented: $showInstructionEditor) {
                ExplainInstructionEditor(initialValue: app.explainPrompt) { text in
                    guard !app.explainPrompt.utf8.elementsEqual(text.utf8) else { return }
                    app.explainPrompt = text
                    app.saveSettings()
                }
            }
            .sheet(item: $catalogEdit) { item in
                AgentCatalogEditor(target: item) { label, body in
                    let saved = try catalog.save(id: item.record?.id, expected: item.record?.editVersion,
                                                 label: label, body: body)
                    profile = saved.selector
                    copiedRevision = nil
                    catalogError = ""
                }
            }
            .alert("이 지시문을 삭제할까요?", isPresented: $showRemove) {
                Button("삭제", role: .destructive) {
                    guard let old = removeProfile else { return }
                    do {
                        try catalog.delete(old.id, expected: old.editVersion)
                        profile = "explain"
                        catalogError = ""
                    } catch { catalogError = error.localizedDescription }
                    removeProfile = nil
                }
                Button("취소", role: .cancel) { removeProfile = nil }
            } message: {
                Text("이미 받은 대본은 보관함에 남지만, 이 지시 버전의 새 대본은 받을 수 없습니다.")
            }
            .confirmationDialog(pendingReplacement == nil ? "편집기의 글을 비울까요?" : "편집기의 글을 받은 대본으로 바꿀까요?",
                                isPresented: $confirmEditorChange, titleVisibility: .visible) {
                Button(pendingReplacement == nil ? "비우기" : "바꾸기", role: .destructive) {
                    if let id = pendingReplacement { openDraft(id, replace: true) }
                    else { drafts.clearEditor() }
                    pendingReplacement = nil
                }
                Button("취소", role: .cancel) { pendingReplacement = nil }
            } message: {
                if pendingReplacement != nil {
                    Text("지금 편집 중인 화면 글과 음성 대본이 바뀝니다. 취소하면 받은 대본은 보관함에 남습니다.")
                }
            }
        }
    }

    private var instruction: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("에이전트 지시문").font(.headline)
                Spacer()
                Picker("지시문 프로필", selection: $profile) {
                    Text("전체 해설").tag("explain")
                    Text("변경분만").tag("continue")
                    Text("음성 대본 정규화").tag("normalize")
                    ForEach(catalog.records) { record in Text(record.label).tag(record.selector) }
                }
                .labelsHidden().frame(width: 218)
                Button("새 지시…") { catalogEdit = .init(record: nil) }
                    .disabled(catalog.readError || catalog.records.count >= AgentLimits.profiles)
            }
            if !catalog.records.isEmpty && !catalog.readError {
                HStack {
                    TextField("이름으로 저장된 지시 찾기", text: $profileSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 270)
                    if !profileSearch.isEmpty {
                        Button("검색 지우기") { profileSearch = "" }
                    }
                    Spacer(minLength: 0)
                }
                if !profileSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let matches = catalog.filteredRecords(label: profileSearch)
                    if matches.isEmpty {
                        Text("일치하는 이름이 없습니다.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Menu("\(matches.count)개 검색 결과") {
                            ForEach(matches) { match in
                                Button(match.label) { profile = match.selector; profileSearch = "" }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            Text("선택은 이 앱 안에서만 바뀝니다. 도우미가 볼 수 있게 하려면 지시의 정확한 버전을 따로 허용하세요.")
                .font(.caption).foregroundStyle(.secondary)
            if catalog.readError || !catalogError.isEmpty {
                Text(catalog.readError ? AgentCatalog.Failure.unreadable.localizedDescription : catalogError)
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if let entry = selectedRecord {
                    Button("편집…") { catalogEdit = .init(record: entry) }
                    Button("삭제…") { removeProfile = entry; showRemove = true }
                } else if profile == "explain" || profile == "continue" {
                    Button("기본 해설 지시 편집…") { showInstructionEditor = true }
                }
                Button(showExactPreview ? "미리 보기 닫기" : "정확한 지시 미리 보기") { showExactPreview.toggle() }
                    .disabled(selectedSnapshot == nil)
                Button(copiedRevision == selectedSnapshot?.generation.uuidString && selectedSnapshot != nil ? "복사됨" : "지시 복사") {
                    guard let snapshot = selectedSnapshot else { return }
                    let clipboard = NSPasteboard.general
                    clipboard.clearContents()
                    if clipboard.setString(snapshot.text, forType: .string) { copiedRevision = snapshot.generation.uuidString }
                }
                .disabled(selectedSnapshot == nil)
                Spacer()
                Button(access.shared == nil ? "이 지시 공유…" : "조회 허용 해제") {
                    AppDelegate.shared?.toggleAgentSharing(profile)
                }
                .disabled(access.shared == nil && (selectedSnapshot?.shareable != true || access.pair == nil))
            }
            HStack {
                if access.pair != nil {
                    Text("MCP 자동 연결됨").font(.caption)
                    Button("권한 해제") { access.disconnect() }
                } else {
                    Text("연결 대기 중 · MCP 클라이언트에서 Codebasic TTS 도우미를 시작하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let active = access.shared {
                Text("조회 허용: \(title(active.selector)) · 이 버전만 · 최대 10분")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let legacy = app.sharedInstructionProfile {
                Text("호환용 기본 조회 허용: \(name(legacy)) · 앱 메뉴에서 해제할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("MCP 조회 허용 안 함").font(.caption).foregroundStyle(.secondary)
            }
            if !access.status.isEmpty { Text(access.status).font(.caption).foregroundStyle(.secondary) }
            if let snapshot = selectedSnapshot {
                if !snapshot.shareable {
                    Text("이 지시는 공유 한도(UTF-8 8KB)를 초과했거나 유효하지 않습니다. 원문은 그대로 보존됩니다.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if showExactPreview {
                    Text("ID: " + snapshot.selector + " · SHA-256: " + snapshot.digest)
                        .font(.caption2.monospaced()).textSelection(.enabled)
                    ScrollView {
                        Text(verbatim: snapshot.text)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 170)
                    .overlay(editorBorder)
                    .accessibilityLabel("복사 및 MCP 조회에 사용되는 정확한 지시문")
                }
            }
        }
    }

    private func title(_ selector: String) -> String {
        if let builtIn = LocalInstructionProfile.Name(rawValue: selector) { return name(builtIn) }
        return catalog.record(selector)?.label ?? selector
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("받은 대본").font(.headline)
                if !drafts.pending.isEmpty {
                    Text("\(drafts.pending.count)개 대기").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(access.receiving ? "대본 받기 중지" : "대본 받기 허용…") {
                    AppDelegate.shared?.toggleDraftReceipt()
                }
                .disabled(access.pair == nil)
            }
            if access.receiving {
                Text("연결된 MCP의 대본 받기 허용됨 · 최대 10분")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("자동 수신 꺼짐 · 붙여넣기와 직접 편집은 언제든 가능합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !drafts.pending.isEmpty {
                DisclosureGroup("받은 대본 확인", isExpanded: $showInbox) {
                    VStack(spacing: 6) {
                        ForEach(drafts.pending) { item in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading) {
                                    Text(verbatim: item.display).lineLimit(2)
                                    if let from = item.provenance {
                                        Text("\(from.agentLabel) · \(title(from.selector)) · \(from.older ? "이전 버전" : "받은 버전") \(from.revision.uuidString.prefix(8))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button("열기…") {
                                    if drafts.hasEditorContent {
                                        pendingReplacement = item.id
                                        confirmEditorChange = true
                                    } else { openDraft(item.id) }
                                }
                                Button("제거") { drafts.discard(item.id) }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("화면 글 · 자막").font(.subheadline.weight(.semibold))
                if let origin = drafts.origin {
                    Text(drafts.hasManualEdits && origin != .manual ? origin.rawValue + " · 직접 수정함" : origin.rawValue)
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
                Button("비우기…") { pendingReplacement = nil; confirmEditorChange = true }
                    .disabled(!drafts.hasEditorContent)
            }
            TextEditor(text: Binding(get: { drafts.display }, set: { drafts.editDisplay($0) }))
                .font(.body).frame(minHeight: 175)
                .overlay(editorBorder)
                .accessibilityLabel("화면 글과 자막")

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

    private var editorBorder: some View { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }

    private func name(_ profile: LocalInstructionProfile.Name) -> String {
        switch profile {
        case .explain: return "전체 해설"
        case .continue: return "변경분만"
        case .normalize: return "음성 대본 정규화"
        }
    }

    private func openDraft(_ id: String, replace: Bool = false) {
        if drafts.open(id, replace: replace) { showSpeech = !drafts.speech.isEmpty }
    }
}

private struct ExplainInstructionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    let save: (String) -> Void

    init(initialValue: String, save: @escaping (String) -> Void) {
        _text = State(initialValue: initialValue)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("기본 해설 지시 편집").font(.headline)
            Text("전체 해설과 변경분만 프로필에 함께 적용됩니다. 저장 후 공통 규칙을 포함한 실제 지시를 미리 볼 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("저장할 기본 해설 지시")
            HStack {
                Button("기본값 복원") { text = CodeExplanation.defaultInstruction }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button("저장") { save(text); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 540, minHeight: 355)
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
