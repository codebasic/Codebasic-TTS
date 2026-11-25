import AppKit
import SwiftUI

private struct InstructionEditTarget: Identifiable {
    let id = UUID()
    let profileID: UUID?
    let label: String
    let body: String
}

private enum CatalogConfirm: Equatable {
    case delete(UUID)
    case freshStore
}

/// Default Agent mode. Other agents write drafts; this view manages the local instruction
/// catalog and lets the user decide what to share, edit and actually read.
struct ExplainWorkspace: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var agent: AgentWorkspaceController
    @ObservedObject private var rendezvous: AgentBridgeRendezvous
    @ObservedObject private var catalog: AgentInstructionCatalog
    @ObservedObject private var drafts: ExplanationDraftWorkspace
    @State private var query = ""
    @State private var editTarget: InstructionEditTarget?
    @State private var catalogConfirm: CatalogConfirm?
    @State private var showCatalogConfirm = false
    @State private var catalogError: String?
    @State private var showExactPreview = false
    @State private var showSpeech = false
    @State private var showPicker = false
    @State private var editID: UUID?
    @State private var editLabel = ""
    @State private var editBody = ""
    @State private var copiedSetup: String?
    @State private var showAdvanced = false
    @State private var pendingReplacement: String?
    @State private var confirmEditorChange = false
    @State private var copiedRevision: AgentInstructionRevision?

    @MainActor
    init(agent: AgentWorkspaceController) {
        _agent = ObservedObject(wrappedValue: agent)
        _rendezvous = ObservedObject(wrappedValue: agent.rendezvous)
        _catalog = ObservedObject(wrappedValue: agent.catalog)
        _drafts = ObservedObject(wrappedValue: agent.drafts)
    }

    private var selected: AgentInstructionProfile? {
        catalog.selectedProfileID.flatMap { catalog.profile(id: $0) }
    }
    private var canUsePlayer: Bool { !app.isBusy && !app.explaining && !app.normalizing }
    /// Unsaved inline edits exist. They stay in this view only; sharing always uses the saved body.
    private var dirty: Bool {
        guard let profile = selected, !profile.isBuiltIn, editID == profile.id else { return false }
        return editLabel != profile.label || !editBody.utf8.elementsEqual(profile.body.utf8)
    }

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
                    pairingSection
                    Divider()
                    catalogSection
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
            .onAppear { loadBuffer() }
            .onChange(of: catalog.selectedProfileID) { _ in loadBuffer() }
            .sheet(item: $editTarget) { target in
                InstructionProfileEditor(target: target) { label, text in save(target, label: label, body: text) }
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

    // MARK: Pairing

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("에이전트 브리지").font(.headline)
            if agent.pairing != nil {
                HStack {
                    Text("서명 확인된 브리지 연결됨 · 이번 실행 동안만").font(.callout)
                    Spacer()
                    Button("연결 해제") { agent.unpair() }
                }
                Text("연결을 해제하거나 앱 또는 브리지가 종료되면 지시 제공과 대본 받기가 모두 끝납니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                pendingBridges
            }
            mcpSetup
            if let notice = agent.notice {
                Text(verbatim: notice).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// One approval per bridge process. Every value shown comes from the kernel and the code
    /// signature check of the live peer; there is nothing to type in.
    @ViewBuilder private var pendingBridges: some View {
        switch rendezvous.availability {
        case .unsigned:
            Text("이 앱은 안정적인 서명 인증서 없이 빌드되어 브리지를 연결할 수 없습니다. 지시 복사와 대본 붙여넣기는 그대로 사용할 수 있습니다.")
                .font(.caption).foregroundStyle(.orange)
        case .identifierMismatch, .endpointUnavailable, .stopped:
            Text("이 실행에서는 브리지 연결을 받을 수 없습니다. 앱을 다시 시작해 보세요. 지시 복사와 대본 붙여넣기는 그대로 사용할 수 있습니다.")
                .font(.caption).foregroundStyle(.orange)
        case .listening:
            if rendezvous.candidates.isEmpty {
                Text("연결 요청 없음 · 아래 명령으로 한 번 등록한 에이전트가 도구를 호출하면 여기에 요청이 나타납니다. 승인 전에는 아무것도 공유되지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if rendezvous.candidates.count > 1 {
                    Text("여러 브리지가 연결을 요청했습니다. 연결할 하나를 직접 고르세요.")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(rendezvous.candidates) { candidate in
                    HStack {
                        (Text("서명 확인된 브리지 · 시작 ")
                            + Text(Date(timeIntervalSince1970: TimeInterval(candidate.identity.startSeconds)), style: .time))
                            .font(.callout)
                        Spacer()
                        Button("연결 승인") { agent.approve(candidate) }
                        Button("거절") { agent.decline(candidate) }
                    }
                }
                Text("승인은 이 브리지 하나에 이번 실행 동안만 적용됩니다. 승인만으로는 아무것도 공유되지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Copies a registration command only when asked. The app never registers or edits any config.
    private var mcpSetup: some View {
        let helper = AgentMCPSetup.helperPath
        return HStack(spacing: 8) {
            Text("에이전트 등록 명령 복사:").font(.caption).foregroundStyle(.secondary)
            ForEach(AgentMCPSetup.Client.allCases, id: \.self) { client in
                Button(copiedSetup == client.rawValue ? "복사됨" : client.rawValue) {
                    guard let helper else { return }
                    let clipboard = NSPasteboard.general
                    clipboard.clearContents()
                    if clipboard.setString(client.command(helperPath: helper), forType: .string) { copiedSetup = client.rawValue }
                }
                .controlSize(.small).disabled(helper == nil)
            }
            Text(helper == nil ? "이 앱 번들에 브리지 도구가 없어 등록할 수 없습니다."
                 : "복사만 합니다. 터미널에서 직접 실행하세요.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Catalog

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("에이전트 지시문").font(.headline)
                Button { showPicker.toggle() } label: {
                    Label(selected?.label ?? "지시 고르기", systemImage: "chevron.up.chevron.down")
                }
                .disabled(dirty)
                .help(dirty ? "저장하거나 되돌린 뒤 다른 지시를 고를 수 있습니다." : "목록을 엽니다. 여는 것만으로는 아무것도 바뀌지 않습니다.")
                .popover(isPresented: $showPicker, arrowEdge: .bottom) { pickerPopover }
                Spacer()
                Button("새 지시…") { editTarget = InstructionEditTarget(profileID: nil, label: "", body: "") }
                    .disabled(!catalog.canAddCustomProfile || dirty)
            }
            persistenceBanner
            if let profile = selected {
                profileDetail(profile)
            } else {
                Text("목록에서 지시를 고르세요. 앱을 열거나 목록을 살펴보는 것만으로는 아무것도 제공되지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            shareStatus
            if let catalogError {
                Text(verbatim: catalogError).font(.caption).foregroundStyle(.orange)
            }
        }
        .confirmationDialog(catalogConfirm == .freshStore ? "읽을 수 없는 저장 파일을 보존하고 새로 시작할까요?" : "이 지시를 삭제할까요?",
                            isPresented: $showCatalogConfirm, titleVisibility: .visible) {
            Button(catalogConfirm == .freshStore ? "보존하고 새로 시작" : "삭제", role: .destructive) { performCatalogConfirm() }
            Button("취소", role: .cancel) { catalogConfirm = nil }
        } message: {
            Text(catalogConfirm == .freshStore
                 ? "기존 파일은 지우지 않고 같은 폴더에 다른 이름으로 남깁니다. 지금 보이는 목록이 새로 저장됩니다."
                 : "삭제하면 되돌릴 수 없고, 이 지시에 대한 읽기 허용과 새 대본 받기가 끝납니다. 이미 받은 대본은 남습니다.")
        }
    }

    @ViewBuilder private var persistenceBanner: some View {
        switch catalog.persistenceState {
        case .clean:
            EmptyView()
        case .saveFailed:
            HStack {
                Label("지시 목록을 저장하지 못했습니다. 마지막으로 저장된 상태를 유지합니다.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("다시 저장") {
                    catalogError = catalog.retrySave().map { Self.message($0) }
                }
                .controlSize(.small)
            }
        case .storeUnreadable:
            HStack {
                Label("저장된 지시 목록을 읽을 수 없습니다. 기존 파일은 건드리지 않았고, 지금 바꾸는 내용은 저장되지 않습니다.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("기존 파일을 보존하고 새로 시작…") {
                    catalogConfirm = .freshStore
                    showCatalogConfirm = true
                }
                .controlSize(.small)
            }
        }
    }

    /// The filter only narrows this list. Nothing changes until a row is deliberately chosen.
    private var pickerPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("이름·내용으로 목록 거르기", text: $query).textFieldStyle(.roundedBorder)
            Text(agent.pairing == nil
                 ? "연결된 브리지가 없어, 골라도 아무것도 제공되지 않습니다."
                 : "지시를 직접 고르면 저장된 그 버전 그대로를 승인한 브리지가 최대 10분 동안 읽을 수 있고, 이전에 제공하던 지시는 바로 해제됩니다. 원격 모델을 쓰는 에이전트는 이 내용을 해당 서비스로 보낼 수 있습니다. 목록을 열거나 거르는 것만으로는 아무것도 바뀌지 않습니다.")
                .font(.caption).foregroundStyle(agent.pairing == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            profileList
        }
        .padding(10)
        .frame(width: 380)
    }

    /// The one deliberate act that makes a saved revision readable by the approved bridge.
    private func choose(_ profile: AgentInstructionProfile) {
        catalog.selectedProfileID = profile.id
        showPicker = false
        showExactPreview = false
        catalogError = nil
        if agent.pairing != nil { agent.activateShare(profileID: profile.id) }
    }

    private var profileList: some View {
        let matches = catalog.search(query)
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(matches) { profile in profileRow(profile) }
                if matches.isEmpty {
                    Text("일치하는 지시가 없습니다.").font(.caption).foregroundStyle(.secondary).padding(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 132)
        .overlay(editorBorder)
    }

    private func profileRow(_ profile: AgentInstructionProfile) -> some View {
        let isSelected = catalog.selectedProfileID == profile.id
        return Button {
            choose(profile)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                Text(verbatim: profile.label).lineLimit(1)
                Text(kindName(profile.kind)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if agent.shareLease?.profileID == profile.id {
                    Text("브리지에 제공 중").font(.caption).foregroundStyle(.green)
                }
                if !profile.canTransmit {
                    Text("공유 불가").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func profileDetail(_ profile: AgentInstructionProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(showExactPreview ? "미리 보기 닫기" : "정확한 내용 미리 보기") { showExactPreview.toggle() }
                Button(copiedRevision == profile.revision ? "복사됨" : "지시 복사") {
                    let clipboard = NSPasteboard.general
                    clipboard.clearContents()
                    if clipboard.setString(profile.body, forType: .string) { copiedRevision = profile.revision }
                }
                Button("복제") {
                    switch catalog.duplicateProfile(id: profile.id) {
                    case .success(let copy): catalog.selectedProfileID = copy.id; catalogError = nil
                    case .failure(let error): catalogError = Self.message(error)
                    }
                }
                .disabled(!catalog.canAddCustomProfile || dirty)
                if !profile.isBuiltIn {
                    Button("삭제…") {
                        catalogConfirm = .delete(profile.id)
                        showCatalogConfirm = true
                    }
                }
                Spacer()
                if agent.shareLease?.profileID == profile.id {
                    Button("제공 중지") { agent.revokeShare() }
                } else {
                    Button("저장된 이 버전을 브리지에 제공") { agent.activateShare(profileID: profile.id) }
                        .disabled(agent.pairing == nil || !profile.canTransmit || dirty)
                        .help("다시 묻지 않고, 저장된 이 버전 그대로를 승인한 브리지가 최대 10분 동안 읽을 수 있게 합니다. 저장하지 않은 편집 내용은 제공되지 않습니다.")
                }
            }
            Text(verbatim: detailCaption(profile))
                .font(.caption).foregroundStyle(profile.canTransmit ? Color.secondary : Color.orange)
            if !profile.isBuiltIn, editID == profile.id { inlineEditor(profile) }
            if showExactPreview {
                ScrollView {
                    Text(verbatim: profile.body)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 170)
                .overlay(editorBorder)
                .accessibilityLabel("복사와 공유에 사용되는 정확한 지시문")
            }
        }
    }

    /// Edits stay in this buffer until Save. Saving ends any share of the old revision and never
    /// shares the new bytes; providing them again is a separate deliberate act.
    private func inlineEditor(_ profile: AgentInstructionProfile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("이름 (이 Mac에만 표시되고 전송되지 않습니다)", text: $editLabel).textFieldStyle(.roundedBorder)
            TextEditor(text: $editBody)
                .font(.callout.monospaced()).frame(minHeight: 120, maxHeight: 220)
                .overlay(editorBorder)
                .accessibilityLabel("지시 내용 편집")
            HStack {
                Text(verbatim: "UTF-8 \(editBody.utf8.count) / \(AgentInstructionLimits.maxBodyUTF8Bytes)바이트"
                     + (dirty ? " · 저장하지 않은 변경은 어디에도 제공되지 않습니다." : ""))
                    .font(.caption).foregroundStyle(dirty ? Color.orange : Color.secondary)
                Spacer()
                Button("되돌리기") {
                    editLabel = profile.label
                    editBody = profile.body
                    catalogError = nil
                }
                .disabled(!dirty)
                Button("저장") {
                    switch catalog.updateProfile(id: profile.id, label: editLabel, body: editBody) {
                    case .success(let saved): editLabel = saved.label; editBody = saved.body; catalogError = nil
                    case .failure(let error): catalogError = Self.message(error)
                    }
                }
                .disabled(!dirty)
            }
            if agent.pairing != nil, agent.shareLease?.profileID != profile.id, !dirty {
                Text("저장된 내용은 「저장된 이 버전을 브리지에 제공」을 눌러야 브리지에 제공됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func loadBuffer() {
        guard let profile = selected, !profile.isBuiltIn else { editID = nil; return }
        guard editID != profile.id else { return }
        editID = profile.id
        editLabel = profile.label
        editBody = profile.body
    }

    @ViewBuilder private var shareStatus: some View {
        if let lease = agent.shareLease, agent.pairing != nil {
            HStack {
                (Text(verbatim: "브리지에 제공 중: 「\(catalog.profile(id: lease.profileID)?.label ?? "지시")」 r\(lease.revision.sequence) · ")
                    + Text(lease.expires, style: .time) + Text("까지"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("제공 중지") { agent.revokeShare() }.controlSize(.small)
            }
        } else {
            Text("브리지에 제공 중인 지시 없음 · 복사해서 에이전트에 직접 붙여넣을 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func kindName(_ kind: AgentInstructionProfile.Kind) -> String {
        switch kind {
        case .builtIn: return "기본 · 읽기 전용"
        case .custom: return "내 지시"
        case .legacySeed: return "기존 설정에서 복사"
        case .imported: return "가져옴"
        }
    }

    private func detailCaption(_ profile: AgentInstructionProfile) -> String {
        var text = "UTF-8 \(profile.body.utf8.count)바이트 · r\(profile.revision.sequence)"
        if profile.isBuiltIn { text += " · 기본 지시는 바꿀 수 없습니다. 복제해서 편집하세요." }
        switch profile.shareBlock {
        case .oversize?: text += " · 공유 한도(8KB)를 넘어 전송할 수 없습니다. 내용은 잘리지 않았고 미리 보기와 복사는 가능합니다."
        case .containsNUL?: text += " · NUL 문자가 있어 전송할 수 없습니다."
        case .blank?, .notFound?: text += " · 전송할 내용이 없습니다."
        case nil: break
        }
        return text
    }

    private func save(_ target: InstructionEditTarget, label: String, body: String) -> String? {
        let result: Result<AgentInstructionProfile, AgentInstructionCatalogError>
        if let id = target.profileID {
            result = catalog.updateProfile(id: id, label: label, body: body)
        } else {
            result = catalog.addProfile(label: label, body: body)
        }
        switch result {
        case .success(let profile):
            catalog.selectedProfileID = profile.id
            catalogError = nil
            return nil
        case .failure(let error):
            return Self.message(error)
        }
    }

    private func performCatalogConfirm() {
        switch catalogConfirm {
        case .delete(let id)?:
            catalogError = catalog.deleteProfile(id: id).map { Self.message($0) }
            showExactPreview = false
        case .freshStore?:
            catalogError = catalog.quarantineUnreadableStoreAndStartFresh().map { Self.message($0) }
        case nil:
            break
        }
        catalogConfirm = nil
    }

    private static func message(_ error: AgentInstructionCatalogError) -> String {
        switch error {
        case .labelBlank: return "이름을 입력하세요."
        case .labelTooLong: return "이름이 너무 깁니다 (80자 이하)."
        case .labelContainsNUL, .bodyContainsNUL: return "NUL 문자는 저장할 수 없습니다."
        case .bodyBlank: return "지시 내용을 입력하세요."
        case .bodyTooLarge: return "지시 내용이 한도(UTF-8 8KB)를 넘습니다. 입력한 내용은 그대로 두었습니다."
        case .catalogFull: return "내 지시는 32개까지 만들 수 있습니다."
        case .notFound: return "지시를 찾을 수 없습니다."
        case .builtInImmutable: return "기본 지시는 바꿀 수 없습니다. 복제해서 편집하세요."
        case .storeUnreadable: return "저장된 지시 목록을 읽을 수 없어 변경하지 않았습니다."
        case .saveFailed: return "저장하지 못해 변경하지 않았습니다."
        }
    }

    // MARK: Inbox

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("받은 대본").font(.headline)
                if !drafts.pending.isEmpty {
                    Text("\(drafts.pending.count)개 대기").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(agent.receiptLease == nil ? "대본 받기 허용…" : "대본 받기 중지") {
                    if agent.receiptLease == nil { agent.requestReceipt() } else { agent.revokeReceipt() }
                }
                .disabled(agent.receiptLease == nil && agent.pairing == nil)
            }
            if let lease = agent.receiptLease, agent.pairing != nil {
                (Text("연결된 브리지에서 받기 허용됨 · ")
                    + Text(lease.expires, style: .time) + Text("까지 · 지시 읽기 허용과 별개"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("자동 수신 꺼짐 · 붙여넣기와 직접 편집은 언제든 가능합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !drafts.pending.isEmpty {
                Group {
                    VStack(spacing: 6) {
                        ForEach(drafts.pending) { item in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: item.display).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let provenance = item.provenance {
                                        Text(verbatim: originText(provenance)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button("편집기에서 사용…") {
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

    /// Owner-chosen bridge label plus the instruction version the draft was written for.
    private func originText(_ provenance: AgentDraftProvenance) -> String {
        var text = "보낸 곳 「\(provenance.helperLabel)」 · 지시 "
        if let profile = catalog.profile(id: provenance.profileID) {
            text += "「\(profile.label)」 r\(provenance.revision.sequence)"
            if profile.revision != provenance.revision { text += " (이후 지시가 바뀜)" }
        } else {
            text += "삭제된 지시 r\(provenance.revision.sequence)"
        }
        return text
    }

    // MARK: Editor

    private var playbackNotice: String? {
        for block in [drafts.playbackBlock(), drafts.playbackBlock(displayOnly: true)] {
            switch block {
            case .markup?: return "태그나 마크업처럼 읽힐 수 있는 내용이 있어 재생하지 않습니다. 해당 부분을 직접 고친 뒤 재생하세요."
            case .tooLarge?: return "대본이 재생 한도(UTF-8 8KB)를 넘습니다."
            case .containsNUL?: return "NUL 문자가 있어 재생할 수 없습니다."
            default: continue
            }
        }
        return nil
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
            if let provenance = drafts.editorProvenance {
                Text(verbatim: originText(provenance)).font(.caption).foregroundStyle(.secondary)
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
                    Label("화면 글과 다른 음성 대본이 있습니다. 재생하기 전에 음성 대본을 확인하세요.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(showSpeech ? "검토 완료 · 이 음성 대본 사용" : "음성 대본 열기") {
                        if showSpeech { drafts.confirmSpeech() }
                        else { showSpeech = true }
                    }
                }
            }
            if drafts.display.trimmingCharacters(in: .whitespacesAndNewlines) == CodeExplanation.noChange {
                Text("변경 없음 · 읽을 대본이 없습니다.").font(.caption).foregroundStyle(.secondary)
            }
            if let playbackNotice {
                Label(playbackNotice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
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

    private func openDraft(_ id: String, replace: Bool = false) {
        if drafts.open(id, replace: replace) { showSpeech = !drafts.speech.isEmpty }
    }
}

private struct InstructionProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var text: String
    @State private var failure: String?
    private let isNew: Bool
    private let save: (String, String) -> String?

    init(target: InstructionEditTarget, save: @escaping (String, String) -> String?) {
        _label = State(initialValue: target.label)
        _text = State(initialValue: target.body)
        isNew = target.profileID == nil
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "새 지시" : "지시 편집").font(.headline)
            TextField("이름 (이 Mac에만 표시되고 전송되지 않습니다)", text: $label)
                .textFieldStyle(.roundedBorder)
            Text("내용은 입력한 그대로 저장됩니다. 내용을 바꾸면 이 지시에 대한 읽기 허용이 해제되고 새 버전이 됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("저장할 지시 내용")
            Text(verbatim: "UTF-8 \(text.utf8.count) / \(AgentInstructionLimits.maxBodyUTF8Bytes)바이트")
                .font(.caption)
                .foregroundStyle(text.utf8.count > AgentInstructionLimits.maxBodyUTF8Bytes ? Color.orange : Color.secondary)
            if let failure {
                Text(verbatim: failure).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button("저장") {
                    failure = save(label, text)
                    if failure == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 540, minHeight: 380)
    }
}

/// User-initiated registration commands for the fixed bundled helper. Pure text: nothing here runs,
/// registers or edits configuration, and no process ID or environment option is ever included.
enum AgentMCPSetup {
    static let serverName = "codebasic-tts-agent"
    enum Client: String, CaseIterable {
        case codex = "Codex CLI"
        case claude = "Claude Code"

        func command(helperPath: String) -> String {
            let helper = AgentMCPSetup.shellQuoted(helperPath)
            switch self {
            case .codex: return "codex mcp add \(AgentMCPSetup.serverName) -- \(helper)"
            case .claude: return "claude mcp add --scope local \(AgentMCPSetup.serverName) -- \(helper)"
            }
        }
    }

    /// The bundled helper only; nil (fail closed) when it is missing, not executable or oddly named.
    static var helperPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/codebasic-tts-agent-bridge").path
        guard FileManager.default.isExecutableFile(atPath: path),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return path
    }

    /// POSIX single quoting: every byte is literal; an embedded quote becomes '\''.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
