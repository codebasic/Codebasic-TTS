import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The 해설 tab. By default it operates as a pure external-agent coordination workspace:
/// - Left pane: manage/preview/copy the final instruction and opt-in read-only MCP lookup.
/// - Right pane: inspect received MCP drafts (without overwriting or auto-playing) and
///   edit/play separate display (subtitle) vs spoken (TTS) text.
/// In-app LLM generation is separated under "고급: 앱 내 생성" and is not instantiated
/// unless explicitly opened, so opening the tab never queries models or starts generation.
struct CommentaryView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(app.showLegacyExplain ? "해설 (고급: 앱 내 생성)" : "해설 (외부 에이전트 대본)")
                    .font(.headline)
                Spacer()
                Toggle("고급: 앱 내 생성", isOn: $app.showLegacyExplain)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("기존 앱 내 LLM 해설 생성기를 엽니다. 기본 상태에서는 모델을 조회하거나 생성하지 않습니다.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if app.showLegacyExplain {
                LegacyInAppCommentaryView()
            } else {
                ExternalExplainWorkspaceView()
            }
        }
    }
}

private struct ExternalExplainWorkspaceView: View {
    @EnvironmentObject var app: AppState
    @State private var sharePIDText = ""
    @State private var pendingOverwriteDraftID: UUID? = nil

    private var border: some View { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }

    private var activeTemplateBinding: Binding<String> {
        Binding(
            get: {
                app.explainInstructionMode == .full ? app.explainPrompt : app.continuePrompt
            },
            set: { newValue in
                switch app.explainInstructionMode {
                case .full: app.explainPrompt = newValue
                case .delta: app.continuePrompt = newValue
                }
                app.saveSettings()
            }
        )
    }

    private var finalInstruction: String {
        app.finalExplainInstruction()
    }

    private var finalRevision: String {
        app.finalExplainInstructionRevision()
    }

    private var finalUTF8Bytes: Int {
        finalInstruction.utf8.count
    }

    private var editor: ExplainEditorState {
        app.explainWorkspace.editor
    }

    private var selectedDraft: ReceivedExplainDraft? {
        app.explainWorkspace.selectedDraft
    }

    private var shareStatusColor: Color {
        switch app.instructionShareState {
        case .inactive, .revoked:
            return .secondary
        case .allowed(let grant):
            return grant.profileName == app.explainInstructionMode.profileName ? .green : .orange
        }
    }

    var body: some View {
        HSplitView {
            instructionPane
            draftAndEditorPane
        }
        .alert("편집 중인 내용이 있습니다", isPresented: Binding(
            get: { pendingOverwriteDraftID != nil },
            set: { if !$0 { pendingOverwriteDraftID = nil } }
        )) {
            Button("덮어쓰기", role: .destructive) {
                if let id = pendingOverwriteDraftID {
                    app.loadExplainDraftIntoEditor(id)
                }
                pendingOverwriteDraftID = nil
            }
            Button("취소", role: .cancel) {
                pendingOverwriteDraftID = nil
            }
        } message: {
            Text("현재 편집기의 화면 문구 또는 음성 대본이 수정되었습니다. 선택한 받은 대본으로 덮어쓸까요?")
        }
        .alert("화면 문구가 수정되었습니다", isPresented: Binding(
            get: { app.pendingStaleExplainPlayback != nil },
            set: { if !$0 { app.pendingStaleExplainPlayback = nil } }
        )) {
            Button("화면 문구 그대로 재생") {
                _ = app.playExplainDisplayTextDirectly()
            }
            Button("이전 낭독 대본 그대로 재생") {
                _ = app.confirmPlayStaleExplainDraft()
            }
            Button("취소", role: .cancel) {
                app.pendingStaleExplainPlayback = nil
            }
        } message: {
            Text("화면 문구가 바뀐 뒤 음성 대본이 아직 갱신되지 않았습니다. 확인 없이 이전 음성 대본을 재생하지 않습니다. 어떤 문구로 합성할지 선택하세요.")
        }
    }

    private var instructionPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("지시문").font(.headline)
                Picker("", selection: $app.explainInstructionMode) {
                    ForEach(ExplainInstructionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 190)
                Spacer()
                Button("초기화") {
                    app.resetExplainInstructionTemplate()
                }
                .controlSize(.small)
                .help("현재 선택한 양식(\(app.explainInstructionMode.label))의 편집 문구를 기본값으로 되돌립니다")
            }

            Text(app.explainInstructionMode == .full
                 ? "전체 해설 양식 (아래 공통 출력 정책이 자동으로 합쳐집니다)"
                 : "변경분만 양식 (전체 해설 양식 + 공통 출력 정책 뒤에 합쳐집니다)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: activeTemplateBinding)
                .font(.callout.monospaced())
                .frame(minHeight: 120)
                .overlay(border)

            HStack(spacing: 8) {
                Text("최종 지시문 미리보기").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(finalUTF8Bytes) / \(ExplainInstructionComposer.maxProfileBytes) B")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(finalUTF8Bytes > ExplainInstructionComposer.maxProfileBytes ? .red : .secondary)
                Button {
                    app.copyFinalExplainInstruction()
                } label: {
                    Label("복사", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .help("미리보기·MCP 조회와 완전히 동일한 최종 지시문을 클립보드에 복사합니다")
            }

            ScrollView {
                Text(finalInstruction)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 110, maxHeight: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(border)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(shareStatusColor).frame(width: 8, height: 8)
                    Text(app.instructionShareState.statusTitle(for: app.explainInstructionMode))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("#\(String(finalRevision.prefix(8)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(app.instructionShareState.statusDetail(for: app.explainInstructionMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("지시 도우미 PID", text: $sharePIDText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    Button("이 지시문만 MCP 조회 허용") {
                        _ = app.requestApproveExplainInstruction(pidText: sharePIDText, expectedRevision: finalRevision)
                    }
                    .controlSize(.small)
                    .disabled(
                        sharePIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || finalUTF8Bytes > ExplainInstructionComposer.maxProfileBytes
                    )

                    if app.instructionShareState.activeGrant != nil {
                        Button("조회 허용 취소") {
                            app.revokeInstructionShare()
                        }
                        .controlSize(.small)
                    }
                }

                Text("원격 모델을 쓰는 에이전트는 조회한 지시문을 해당 모델 서비스로 보낼 수 있습니다. 지시문을 수정하면 기존 조회 허용은 자동 철회됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if !app.instructionShareError.isEmpty {
                    Text(app.instructionShareError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(border)
        }
        .padding()
        .frame(minWidth: 340, maxWidth: .infinity)
    }

    private var draftAndEditorPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            inboxSection

            Divider()

            editorSection
        }
        .padding()
        .frame(minWidth: 380, maxWidth: .infinity)
    }

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("받은 대본 (MCP 수신)").font(.headline)
                Text("\(app.explainWorkspace.receivedDrafts.count)건")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("수신 허용 (이번 실행)", isOn: Binding(
                    get: { app.explainDraftInboxEnabled },
                    set: { _ = app.setExplainDraftInboxEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("켜면 외부 에이전트가 submit_explain_draft로 보낸 대본을 수신함에 조용히 받습니다. 도착만으로 재생하거나 편집기를 덮어쓰지 않습니다.")
            }

            if !app.explainDraftInboxError.isEmpty {
                Text(app.explainDraftInboxError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if app.explainWorkspace.receivedDrafts.isEmpty {
                Text("수신함 비어 있음 — 에이전트가 보낸 대본은 여기에 따로 도착하며, 도착만으로 재생되거나 편집 중인 내용을 덮어쓰지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(app.explainWorkspace.receivedDrafts) { draft in
                            let selected = selectedDraft?.id == draft.id
                            Button {
                                app.explainWorkspace.selectedDraftID = draft.id
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(draft.mode.label)
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                            if draft.hasSeparateSpokenText {
                                                Text("화면/음성 분리")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if draft.isNoChangeSentinel {
                                                Text("변경 없음")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                            Spacer()
                                            Text(draft.receivedAt, style: .time)
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.tertiary)
                                        }
                                        Text(draft.displayText)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(6)
                                .background(
                                    selected ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 74, maxHeight: 118)
                .overlay(border)

                if let draft = selectedDraft {
                    HStack(spacing: 8) {
                        Button(editor.isEmpty ? "편집기로 불러오기" : "편집기 덮어쓰기") {
                            if editor.isDirty && !editor.isEmpty {
                                pendingOverwriteDraftID = draft.id
                            } else {
                                _ = app.loadExplainDraftIntoEditor(draft.id)
                            }
                        }
                        .controlSize(.small)

                        Button("이어 붙이기") {
                            _ = app.appendExplainDraftToEditor(draft.id)
                        }
                        .controlSize(.small)

                        Button("무시") {
                            app.dismissExplainDraft(draft.id)
                        }
                        .controlSize(.small)

                        Spacer()

                        Button("목록 비우기") {
                            app.clearExplainDraftInbox()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("화면 문구 (자막)").font(.headline)
                if editor.isDirty {
                    Text("· 편집 중").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        app.updateExplainDisplayText(text)
                    }
                } label: {
                    Label("붙여넣기", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)
                .help("직접 복사한 해설 문구를 화면 문구 편집기에 붙여넣습니다")

                Button {
                    app.clearExplainEditor()
                } label: {
                    Label("비우기", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(editor.isEmpty)
            }

            TextEditor(text: Binding(
                get: { editor.displayText },
                set: { app.updateExplainDisplayText($0) }
            ))
            .font(.body)
            .frame(minHeight: 100)
            .overlay(border)

            HStack(spacing: 8) {
                Text("음성 대본 (선택 — 비워 두면 화면 문구 그대로 읽음)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("비우기") {
                    app.clearExplainSpokenText()
                }
                .controlSize(.small)
                .disabled(!editor.hasSpokenText)
            }

            if editor.isSpokenStale {
                VStack(alignment: .leading, spacing: 6) {
                    Label("화면 문구가 수정되어 기존 낭독 대본이 더 이상 맞지 않습니다. 확인 없이 이전 음성 대본을 재생하지 않습니다.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    HStack(spacing: 8) {
                        Button("화면 문구 그대로 읽기") {
                            _ = app.playExplainDisplayTextDirectly()
                        }
                        .controlSize(.small)
                        .disabled(!editor.hasDisplayText || app.isBusy)

                        Button("현재 낭독 대본 유지 확인") {
                            app.acknowledgeExplainSpokenMatchesDisplay()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            TextEditor(text: Binding(
                get: { editor.spokenText },
                set: { app.updateExplainSpokenText($0) }
            ))
            .font(.body)
            .frame(minHeight: 85)
            .overlay(border)

            HStack(spacing: 10) {
                Button {
                    _ = app.playExplainDraft()
                } label: {
                    Label("재생", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(editor.isEmpty || app.isBusy)
                .help("사용자가 눌렀을 때만 합성을 시작합니다. 문구를 자동으로 다시 쓰지 않고 그대로 읽습니다.")

                Button {
                    app.stop()
                } label: {
                    Label("중지", systemImage: "stop.fill")
                }
                .disabled(!app.isBusy)

                Button {
                    app.sendExplainDraftToGenerate()
                } label: {
                    Label("TTS 탭으로 보내기", systemImage: "arrow.right.circle")
                }
                .disabled(editor.isEmpty)

                if app.isBusy { ProgressView().controlSize(.small) }
                Text(app.statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

/// Legacy in-app LLM explanation generator, separated under "고급: 앱 내 생성".
private struct LegacyInAppCommentaryView: View {
    @EnvironmentObject var app: AppState
    @State private var showPrompt = false

    private var codeEmpty: Bool {
        app.codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var explanationEmpty: Bool {
        app.explanationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var border: some View { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }

    // Vision bindings: show the effective endpoint+model (override, else follow
    // the 해설 role) and store a remembered override once the user picks one.
    private var visionEndpointBinding: Binding<String> {
        Binding(get: { app.visionOverridden ? app.visionEndpointID : app.explainEndpointID },
                set: { app.visionEndpointID = $0; app.visionOverridden = true })
    }
    private var visionRoleModelsBinding: Binding<[String: String]> {
        Binding(get: { app.visionOverridden ? app.visionRoleModels : app.explainRoleModels },
                set: { app.visionRoleModels = $0; app.visionOverridden = true })
    }

    var body: some View {
        HSplitView {
            main
            if showPrompt {
                StageInspector(title: "해설 설정",
                               temperature: $app.explainTemperature,
                               reasoningLevel: $app.explainReasoningLevel,
                               visionLevelTitle: "비전 생성 수준",
                               visionReasoningLevel: $app.visionReasoningLevel,
                               prompt: $app.explainPrompt,
                               promptCaption: "해설 지시문 — 코드를 어떻게 해설할지 LLM에게 주는 규칙",
                               restore: { app.explainPrompt = CodeExplanation.defaultInstruction },
                               onChange: { app.saveSettings() })
            }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("코드").font(.headline)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    let imgs = (pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage]) ?? []
                    attach(imgs)
                    if let s = pb.string(forType: .string) { app.codeText = s }
                } label: {
                    Label("붙여넣기", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)
                .help("클립보드의 코드/스크린샷을 붙여넣습니다 (텍스트는 코드로, 이미지는 첨부)")
                Button { showPrompt.toggle() } label: { Image(systemName: "sidebar.right") }
                    .controlSize(.small)
                    .help("프롬프트·생성 매개변수 패널 열기/닫기")
            }
            TextEditor(text: $app.codeText)
                .font(.body.monospaced()).frame(minHeight: 150)
                .overlay(border)
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in dropImages(providers); return true }
            Text("코드 입력창에 ⌘V — 텍스트는 코드로, 스크린샷은 이미지로 첨부됩니다.")
                .font(.caption2).foregroundStyle(.tertiary)

            if app.hasImages {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(app.codeImages.enumerated()), id: \.offset) { idx, data in
                            ZStack(alignment: .topTrailing) {
                                if let img = NSImage(data: data) {
                                    Image(nsImage: img).resizable().scaledToFill()
                                        .frame(width: 96, height: 64).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                                }
                                Button { app.removeImage(at: idx) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain).padding(2)
                            }
                        }
                        Button { app.clearImages() } label: { Label("모두 지우기", systemImage: "trash") }
                            .controlSize(.small)
                    }
                }
                .frame(height: 70)
            }

            HintField(placeholder: "추가 지시 (해설, 선택) — 맥락이나 재생성 방향. 예: 더 간결하게, 초보자 기준으로",
                      text: $app.explainHint,
                      help: "코드→해설 생성·이어서 해설·재생성에만 적용되는 일회성 지시 (프롬프트엔 저장 안 됨)")

            HStack(spacing: 8) {
                Button {
                    app.generateExplanation()
                } label: {
                    Label("해설 생성", systemImage: "wand.and.stars")
                }
                .disabled((codeEmpty && !app.hasImages) || app.explaining)
                .help("이전 코드·해설을 참고해 현재 입력을 해설합니다. 대화 기록은 비우기로 초기화합니다.")

                Button {
                    app.continueExplanation()
                } label: {
                    Label("이어서 해설", systemImage: "text.append")
                }
                .disabled(codeEmpty || app.explaining)
                .help("이전 해설 이후 추가·변경된 부분만 이어서 해설에 덧붙입니다")

                Button { app.generateExplanation(force: true) } label: {
                    Label("재생성", systemImage: "arrow.clockwise")
                }
                .disabled((codeEmpty && !app.hasImages) || app.explaining)
                .help("해설 캐시를 무시하고 전체를 다시 생성")

                if app.explaining {
                    ProgressView().controlSize(.small)
                    Text("해설 생성 중…").font(.caption).foregroundStyle(.secondary)
                    Button { app.cancelGeneration() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .controlSize(.small)
                    .help("해설 생성을 중단합니다 (지금까지 스트림된 부분은 유지)")
                }
                Spacer()
                Toggle("생성 후 바로 재생", isOn: $app.explainAutoPlay)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("단축키(⌃⌥⌘E)·Services ‘코드 해설’로 만든 해설을 바로 읽습니다. 끄면 생성만 하고 창을 띄워, 검토 후 ‘전체 재생’으로 읽습니다.")
                    .onChange(of: app.explainAutoPlay) { _, _ in app.saveSettings() }
            }
            HStack(spacing: 16) {
                Toggle("단축키(⌃⌥⌘E)·서비스에서 앱 내 해설 생성 허용", isOn: $app.allowLegacyShortcutExplain)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("기본값은 꺼짐입니다. 꺼두면 ⌃⌥⌘E나 macOS 서비스 ‘코드 해설’을 눌러도 자동으로 LLM 해설을 생성하지 않습니다.")
                    .onChange(of: app.allowLegacyShortcutExplain) { _, _ in app.saveSettings() }
                Spacer()
            }
            HStack(spacing: 16) {
                LLMModelPicker(label: "해설 모델",
                               endpointID: $app.explainEndpointID,
                               roleModels: $app.explainRoleModels,
                               onChange: { app.saveSettings() })
                LLMModelPicker(label: "비전 모델",
                               endpointID: visionEndpointBinding,
                               roleModels: visionRoleModelsBinding,
                               onChange: { app.saveSettings() })
                if app.visionOverridden {
                    Button {
                        app.visionOverridden = false; app.saveSettings()
                    } label: { Image(systemName: "arrow.uturn.backward") }
                        .controlSize(.small)
                        .help("비전 모델을 해설 모델로 되돌리기 (추종)")
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Text("해설").font(.headline)
                if app.canContinueExplain {
                    Text("· 이어쓰기 기준 설정됨").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { app.recordIssue(.explain) } label: { Label("이슈 기록", systemImage: "flag") }
                    .controlSize(.small)
                    .disabled(explanationEmpty)
                    .help("현재 해설 생성 컨텍스트(코드·프롬프트·추가 지시·해설)를 백로그에 기록")
                Button { app.clearCommentary() } label: { Label("비우기", systemImage: "trash") }
                    .controlSize(.small)
                    .disabled(explanationEmpty && !app.canContinueExplain)
                    .help("해설·대화 기록·이어쓰기 기준을 비웁니다")
            }

            TextEditor(text: $app.explanationText)
                .font(.body).frame(minHeight: 150)
                .overlay(border)

            HStack(spacing: 10) {
                Button { app.speakExplanation() } label: { Label("전체 재생", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(explanationEmpty || app.isBusy || app.explaining)
                    .help("해설을 재생합니다. 자막은 이 해설 그대로, 음성은 내부 대본(설정 → 음성 대본 정규화가 켜져 있으면 정규화)으로 읽습니다")
                Button { app.speakContinue() } label: { Label("이어서 읽기", systemImage: "forward.end.fill") }
                    .disabled(!app.hasLastSegment || app.explaining)
                    .help("마지막에 추가된 해설을 이어서 읽습니다 (재생 중이면 멈추고 그 부분을 재생)")
                Button { app.stop() } label: { Label("중지", systemImage: "stop.fill") }
                    .disabled(!app.isBusy && !app.explaining)

                Button { app.sendExplanationToGenerate() } label: {
                    Label("TTS로 보내기", systemImage: "arrow.right.circle")
                }
                .disabled(explanationEmpty)
                .help("해설을 TTS 탭으로 보내 음성 대본을 직접 보고 다듬은 뒤 재생합니다 (고급)")
                if app.isBusy { ProgressView().controlSize(.small) }
                Text(app.statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }

            Text("모델은 위에서 선택 (등록된 엔드포인트별 통합 목록) · 엔드포인트 추가·삭제는 설정 탭")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 420, maxWidth: .infinity)
    }

    // MARK: - Image input (screenshots)

    private func pngData(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Attach pasted/dropped images as PNG (skips zero-size).
    private func attach(_ imgs: [NSImage]) {
        for img in imgs where !img.size.equalTo(.zero) {
            if let d = pngData(img) { app.codeImages.append(d) }
        }
    }

    private func dropImages(_ providers: [NSItemProvider]) {
        for p in providers where p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage else { return }
                Task { @MainActor in attach([img]) }
            }
        }
    }
}
