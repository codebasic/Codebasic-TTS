import AppKit
import SwiftUI

/// Default Agent mode. External agents read explicitly approved instructions and
/// submit editable drafts; this view manages the local instruction catalog, the single
/// pinned signed-helper session, separate read/receipt grants, and local playback.
struct ExplainWorkspace: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var drafts: ExplanationDraftWorkspace

    @State private var selectedTarget: InstructionTarget = .builtin("explain")
    @State private var showBuiltinEditor = false
    @State private var showLocalEditor = false
    @State private var editingLocalEntry: AgentInstructionEntry? = nil
    @State private var pendingDeleteEntry: AgentInstructionEntry? = nil
    @State private var showExactPreview = false
    @State private var showSpeech = false
    @State private var showInbox = false
    @State private var showAdvanced = false
    @State private var pendingReplacement: String?
    @State private var confirmEditorChange = false
    @State private var copiedRevision: String?

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
                    AgentCatalogPanel(
                        app: app,
                        catalog: app.agentCatalog,
                        agent: app.agentSession,
                        selectedTarget: $selectedTarget,
                        showBuiltinEditor: $showBuiltinEditor,
                        showLocalEditor: $showLocalEditor,
                        editingLocalEntry: $editingLocalEntry,
                        pendingDeleteEntry: $pendingDeleteEntry,
                        showExactPreview: $showExactPreview,
                        copiedRevision: $copiedRevision
                    )
                    Divider()
                    AgentSessionPanel(
                        agent: app.agentSession,
                        drafts: drafts,
                        selectedTarget: selectedTarget
                    )
                    Divider()
                    inbox
                    editor
                    Divider()
                    HStack {
                        Text("외부 에이전트가 대본을 만들고, 여기서는 검토·편집하고 읽습니다.")
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
            .sheet(isPresented: $showBuiltinEditor) {
                ExplainInstructionEditor(initialValue: app.explainPrompt) { text in
                    guard !app.explainPrompt.utf8.elementsEqual(text.utf8) else { return }
                    app.explainPrompt = text
                    app.saveSettings()
                }
            }
            .sheet(isPresented: $showLocalEditor) {
                LocalCatalogEntryEditor(
                    entry: editingLocalEntry,
                    onSave: { label, body in
                        if let existing = editingLocalEntry {
                            return app.updateLocalInstruction(id: existing.id, label: label, body: body)
                                .map { entry in
                                    selectedTarget = .local(entry.id)
                                    return ()
                                }
                        } else {
                            return app.createLocalInstruction(label: label, body: body)
                                .map { entry in
                                    selectedTarget = .local(entry.id)
                                    return ()
                                }
                        }
                    }
                )
            }
            .confirmationDialog(
                "로컬 지시 ‘\(pendingDeleteEntry?.label ?? "")’을(를) 삭제할까요?",
                isPresented: Binding(
                    get: { pendingDeleteEntry != nil },
                    set: { if !$0 { pendingDeleteEntry = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("삭제", role: .destructive) {
                    if let target = pendingDeleteEntry {
                        _ = app.deleteLocalInstruction(id: target.id)
                        if selectedTarget == .local(target.id) {
                            selectedTarget = .builtin("explain")
                        }
                    }
                    pendingDeleteEntry = nil
                }
                Button("취소", role: .cancel) { pendingDeleteEntry = nil }
            } message: {
                Text("삭제된 ID는 영구적으로 재사용되지 않으며(tombstone), 이 지시에 부여된 조회 허용은 즉시 철회됩니다.")
            }
            .confirmationDialog(
                pendingReplacement == nil ? "편집기의 글을 비울까요?" : "편집기의 글을 받은 대본으로 바꿀까요?",
                isPresented: $confirmEditorChange,
                titleVisibility: .visible
            ) {
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

    private var canUsePlayer: Bool { !app.isBusy && !app.explaining && !app.normalizing }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("받은 대본").font(.headline)
                Text("\(drafts.pending.count)/\(ExplanationDraftWorkspace.maxPending)개 대기")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("레거시 PID 받기…") {
                    AppDelegate.shared?.toggleDraftReceipt()
                }
                .controlSize(.small)
                .help("구형 수동 PID 기반 대본 수신 메뉴를 엽니다.")
            }
            if let pid = drafts.receiverPID {
                Text("도구 PID \(pid) 대본 받기 허용됨 · 최대 10분")
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
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        if item.provenance?.verifiedLate == true {
                                            Text("전달 증명 확인됨")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6).padding(.vertical, 1)
                                                .background(Color.green.opacity(0.15), in: Capsule())
                                        }
                                        if item.speech != nil {
                                            Text("화면/음성 분리")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(verbatim: item.display).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("#\(drafts.displayHashHex.prefix(8))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                if let origin = drafts.origin {
                    Text(drafts.hasManualEdits && origin != .manual ? origin.rawValue + " · 직접 수정함" : origin.rawValue)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("화면 글 붙여넣기") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        let merged = drafts.display.isEmpty ? text : drafts.display + "\n\n" + text
                        drafts.editDisplay(merged, pasted: true)
                    }
                }
                .help("텍스트가 이미 있으면 끝에 추가합니다.")
                Button("비우기…") { pendingReplacement = nil; confirmEditorChange = true }
                    .disabled(!drafts.hasEditorContent)
            }
            TextEditor(text: Binding(get: { drafts.display }, set: { drafts.editDisplay($0) }))
                .font(.body).frame(minHeight: 165)
                .overlay(editorBorder)
                .accessibilityLabel("화면 글과 자막")

            DisclosureGroup("별도 음성 대본 (선택) · #\(drafts.speechHashHex.prefix(8))", isExpanded: $showSpeech) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("비워 두면 화면 글을 읽습니다. 발음용 대본은 여기에 따로 붙여넣거나 편집하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { drafts.speech }, set: { drafts.editSpeech($0) }))
                        .font(.body).frame(minHeight: 100)
                        .overlay(editorBorder)
                        .accessibilityLabel("별도 음성 대본")
                }
                .padding(.top, 5)
            }
            if drafts.speechNeedsReview {
                HStack {
                    Label("화면 글과 다른 음성 대본이거나 수정되었습니다. 재생 전에 확인하세요.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(showSpeech ? "검토 완료 · 이 음성 사용" : "음성 대본 열기") {
                        if showSpeech { drafts.confirmSpeech() }
                        else { showSpeech = true }
                    }
                }
            }
            if drafts.display.trimmingCharacters(in: .whitespacesAndNewlines) == CodeExplanation.noChange {
                Text("변경 없음 · 읽을 대본이 없습니다.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { app.playExplanationDraft() } label: { Label("그대로 재생", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canUsePlayer || drafts.playback() == nil)
                if !drafts.speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("화면 글 그대로 읽기") { app.playExplanationDraft(displayOnly: true) }
                        .disabled(!canUsePlayer || drafts.playback(displayOnly: true) == nil)
                }
                Button { app.stop() } label: { Label("중지", systemImage: "stop.fill") }
                    .disabled(!app.isBusy)
                if app.isBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let rejection = drafts.lastPlaybackError {
                Text(rejection).font(.caption).foregroundStyle(.red)
            } else if app.isBusy || app.statusText.hasPrefix("오류:") {
                Text(app.statusText.hasPrefix("오류:") ? app.statusText : "음성 재생 기능 사용 중")
                    .font(.caption).foregroundStyle(app.statusText.hasPrefix("오류:") ? Color.red : Color.secondary)
            }
        }
    }

    private var editorBorder: some View { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }

    private func openDraft(_ id: String, replace: Bool = false) {
        if drafts.open(id, replace: replace) { showSpeech = !drafts.speech.isEmpty }
    }
}

private struct AgentCatalogPanel: View {
    let app: AppState
    @ObservedObject var catalog: AgentInstructionCatalogStore
    @ObservedObject var agent: AgentSessionController

    @Binding var selectedTarget: InstructionTarget
    @Binding var showBuiltinEditor: Bool
    @Binding var showLocalEditor: Bool
    @Binding var editingLocalEntry: AgentInstructionEntry?
    @Binding var pendingDeleteEntry: AgentInstructionEntry?
    @Binding var showExactPreview: Bool
    @Binding var copiedRevision: String?

    private var payload: ApprovedInstructionPayload? {
        agent.approvedPayload(for: selectedTarget)
    }

    private var selectedLocalEntry: AgentInstructionEntry? {
        guard case .local(let id) = selectedTarget else { return nil }
        return catalog.entry(id: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("에이전트 지시 카탈로그").font(.headline)
                Text("로컬 \(catalog.entries.count)/\(AgentInstructionCatalogStore.maxProfiles)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("새 로컬 지시…") {
                    editingLocalEntry = nil
                    showLocalEditor = true
                }
                .controlSize(.small)
                .disabled(catalog.entries.count >= AgentInstructionCatalogStore.maxProfiles || catalog.loadError != nil)
            }

            if let loadError = catalog.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Picker("지시 선택", selection: $selectedTarget) {
                    Section("기본 프로필 (기존 규격 유지)") {
                        Text("전체 해설 (기본)").tag(InstructionTarget.builtin("explain"))
                        Text("변경분만 (기본)").tag(InstructionTarget.builtin("continue"))
                    }
                    if !catalog.entries.isEmpty {
                        Section("로컬 지시 (명시적 공유 전용)") {
                            ForEach(catalog.entries) { entry in
                                Text("\(entry.label) · 로컬").tag(InstructionTarget.local(entry.id))
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)

                if let payload {
                    Text(payload.origin == "local" ? "로컬" : "기본")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((payload.origin == "local" ? Color.blue : Color.secondary).opacity(0.15), in: Capsule())
                    Text("#\(payload.revision.prefix(8)) · \(payload.instructions.utf8.count) B")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                if case .local = selectedTarget, let localEntry = selectedLocalEntry {
                    Button("로컬 지시 편집…") {
                        editingLocalEntry = localEntry
                        showLocalEditor = true
                    }
                    Button("삭제…", role: .destructive) {
                        pendingDeleteEntry = localEntry
                    }
                } else {
                    Button("기본 해설 지시 편집…") { showBuiltinEditor = true }
                }

                Button(showExactPreview ? "미리 보기 닫기" : "정확한 지시 미리 보기") {
                    showExactPreview.toggle()
                }
                .disabled(payload == nil)

                Button(copiedRevision == payload?.revision && payload != nil ? "복사됨" : "지시 복사") {
                    guard let payload else { return }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    if pb.setString(payload.instructions, forType: .string) {
                        copiedRevision = payload.revision
                    }
                }
                .disabled(payload == nil)

                Spacer()

                Button("레거시 메뉴 공유…") {
                    if case .builtin(let name) = selectedTarget,
                       let profile = LocalInstructionProfile.Name(rawValue: name) {
                        AppDelegate.shared?.toggleInstructionSharing(preselect: profile)
                    } else {
                        AppDelegate.shared?.toggleInstructionSharing(preselect: nil)
                    }
                }
                .controlSize(.small)
                .help("구형 수동 PID 기반 지시 공유 메뉴를 엽니다.")
            }

            if payload == nil {
                Text("이 지시는 공유 한도(UTF-8 8,192바이트)를 초과했거나 유효하지 않습니다.")
                    .font(.caption).foregroundStyle(.orange)
            }

            if showExactPreview, let payload {
                ScrollView {
                    Text(verbatim: payload.instructions)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 165)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("복사 및 MCP 조회에 사용되는 정확한 지시문")
            }
        }
    }
}

private struct AgentSessionPanel: View {
    @ObservedObject var agent: AgentSessionController
    @ObservedObject var drafts: ExplanationDraftWorkspace
    let selectedTarget: InstructionTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("서명된 MCP 서버 세션 (에이전트 하네스 주도 연결)").font(.headline)
                Spacer()
                if agent.pinnedSession == nil {
                    Button(agent.isPairingOpen ? "연결 대기 중지" : "에이전트 연결 대기 시작") {
                        if agent.isPairingOpen { agent.stopPairing() }
                        else { _ = agent.startPairing() }
                    }
                } else {
                    Button("세션 해제", role: .destructive) {
                        agent.endSession()
                    }
                }
            }

            if let session = agent.pinnedSession {
                HStack(spacing: 8) {
                    Label("고정된 세션: \(session.clientName) · PID \(session.principal.pid)", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Text("ID \(session.principal.signingIdentifier) · CDHash \(session.principal.shortCDHash)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 12) {
                    // Separate Read Grant control
                    VStack(alignment: .leading, spacing: 4) {
                        if let read = agent.activeReadGrant {
                            Text("조회 허용됨 (대기 중): \(read.payload.label) · #\(read.payload.revision.prefix(8))")
                                .font(.caption)
                            Button("조회 허용 해제") { agent.revokeRead() }
                                .controlSize(.small)
                        } else {
                            Text(readInactiveLabel)
                                .font(.caption).foregroundStyle(.secondary)
                            Button("선택한 지시문만 조회 허용 (10분)") {
                                _ = agent.grantRead(target: selectedTarget)
                            }
                            .controlSize(.small)
                            .disabled(agent.approvedPayload(for: selectedTarget) == nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().frame(height: 36)

                    // Separate Receipt Grant control
                    VStack(alignment: .leading, spacing: 4) {
                        if agent.activeReceiptGrant != nil {
                            Text("대본 받기 허용됨 · 잔여 \(agent.remainingDraftsInGrant)/20 · 증명 \(agent.proofCount)/32")
                                .font(.caption)
                            Button("대본 받기 중지") { agent.revokeReceipt() }
                                .controlSize(.small)
                        } else {
                            Text("대본 받기 비허용")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("대본 받기 허용 (10분)") {
                                _ = agent.grantReceipt()
                            }
                            .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text(agent.isPairingOpen
                     ? "연결 대기 중: 외부 에이전트 하네스에서 `pair_tts_session`을 실행하면 아래에 서명 확인 후 표시됩니다."
                     : "연결된 도우미 없음 — 앱은 에이전트를 먼저 찾지 않으며, 하네스가 `pair_tts_session`으로 연결을 시작해야 합니다.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(agent.pendingCandidates) { candidate in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(candidate.clientName) (PID \(candidate.principal.pid))")
                                .font(.caption.weight(.semibold))
                            Text("ID: \(candidate.principal.signingIdentifier) · Cert: \(candidate.principal.shortCert) · CDHash: \(candidate.principal.shortCDHash)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("연결 승인") {
                            _ = agent.approveCandidate(fingerprint: candidate.principal.fingerprint)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("거절") {
                            agent.denyCandidate(fingerprint: candidate.principal.fingerprint)
                        }
                        .controlSize(.small)
                    }
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            if !agent.statusMessage.isEmpty {
                Text(agent.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readInactiveLabel: String {
        switch agent.lastReadRevokeReason {
        case .edited: return "지시문 수정으로 조회 허용이 철회됨"
        case .deleted: return "지시문 삭제로 조회 허용이 철회됨"
        case .expired: return "조회 허용(10분) 만료됨"
        case .manual, .sessionEnded, .none: return "지시 조회 비허용 (조회 시에만 응답)"
        }
    }
}

private struct LocalCatalogEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let entry: AgentInstructionEntry?
    let onSave: (String, String) -> Result<Void, AgentCatalogError>

    @State private var label: String
    @State private var bodyText: String
    @State private var errorMessage: String?

    init(entry: AgentInstructionEntry?, onSave: @escaping (String, String) -> Result<Void, AgentCatalogError>) {
        self.entry = entry
        self.onSave = onSave
        _label = State(initialValue: entry?.label ?? "")
        _bodyText = State(initialValue: entry?.body ?? "")
    }

    private var labelBytes: Int { label.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count }
    private var labelChars: Int { label.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var bodyBytes: Int { bodyText.utf8.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry == nil ? "새 로컬 지시 추가" : "로컬 지시 편집").font(.headline)
            Text("저장되는 지시는 로컬 카탈로그에만 보관되며 자동으로 에이전트에게 공개되지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("이름").font(.caption.weight(.semibold))
                Spacer()
                Text("\(labelChars)/80자 · \(labelBytes)/96 B")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle((labelChars > 80 || labelBytes > 96) ? .red : .secondary)
            }
            TextField("예: Python 데이터 프레임 해설", text: $label)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("지시 내용").font(.caption.weight(.semibold))
                Spacer()
                Text("\(bodyBytes)/\(AgentInstructionCatalogStore.maxBodyUTF8Bytes) B")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(bodyBytes > AgentInstructionCatalogStore.maxBodyUTF8Bytes ? .red : .secondary)
            }
            TextEditor(text: $bodyText)
                .font(.callout.monospaced())
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button("저장") {
                    switch onSave(label, bodyText) {
                    case .success: dismiss()
                    case .failure(let err): errorMessage = err.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 540, minHeight: 390)
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
