import SwiftUI

/// 해설 탭. 기본 화면은 에이전트 지시문과 받은 대본만 다룬다 — 이 화면을 여는 것만으로는
/// 모델 목록 조회도 생성도 일어나지 않는다 (LLMModelPicker가 있는 CommentaryView는
/// ‘고급’을 고를 때만 만들어진다).
struct ExplainTabView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $app.explainAdvancedVisible) {
                Text("에이전트 대본").tag(false)
                Text("고급: 앱 내 해설 생성").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340)
            .padding(.top, 8)
            if app.explainAdvancedVisible {
                HStack {
                    Toggle("단축키(⌃⌥⌘E)·Services ‘코드 해설’로 앱 내 생성 시작 허용", isOn: $app.inAppExplainShortcuts)
                        .toggleStyle(.checkbox).controlSize(.small)
                        .help("꺼져 있으면 단축키·서비스는 선택한 코드를 아래 코드 칸에 옮기기만 하고 모델을 호출하지 않습니다.")
                        .onChange(of: app.inAppExplainShortcuts) { _, _ in app.saveSettings() }
                    Spacer()
                }
                .padding(.horizontal).padding(.top, 6)
                CommentaryView()
            } else {
                AgentScriptView()
            }
        }
    }
}

struct AgentScriptView: View {
    @EnvironmentObject var app: AppState
    @State private var kind: AgentPromptKind = .full
    @State private var showPreview = false
    @State private var pendingLoad: ReceivedScript?
    @State private var confirmPaste = false
    @State private var confirmStale = false
    @State private var note = ""

    private var border: some View { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
    private var draft: ScriptDraft { app.agentDraft }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prompts
                Divider()
                inbox
                Divider()
                editor
            }
            .padding()
        }
        .frame(minWidth: 420, maxWidth: .infinity)
        .alert("편집 중인 대본을 바꿀까요?", isPresented: Binding(get: { pendingLoad != nil },
                                                          set: { if !$0 { pendingLoad = nil } })) {
            Button("바꾸기", role: .destructive) {
                if let item = pendingLoad { app.loadReceivedScript(item.id, replace: true) }
                pendingLoad = nil
            }
            Button("취소", role: .cancel) { pendingLoad = nil }
        } message: {
            Text("편집기의 화면 문구와 음성 대본이 받은 대본으로 대체됩니다. 받은 대본은 취소해도 수신함에 남습니다.")
        }
        .alert("편집 중인 대본을 클립보드 내용으로 바꿀까요?", isPresented: $confirmPaste) {
            Button("바꾸기", role: .destructive) { app.pasteAgentScriptFromClipboard(replace: true) }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("화면 문구가 바뀌어 음성 대본이 맞지 않을 수 있습니다", isPresented: $confirmStale,
                            titleVisibility: .visible) {
            Button("화면 문구 그대로 읽기") { app.playAgentScript(staleChoice: .readDisplay) }
            Button("이전 음성 대본으로 재생") { app.playAgentScript(staleChoice: .keepOldSpeech) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("음성 대본은 바뀌기 전 화면 문구에 맞춰 쓰였습니다. 앱은 대본을 자동으로 다시 쓰지 않습니다.")
        }
    }

    // MARK: 지시문

    private var prompts: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("에이전트 지시문").font(.headline)
                Picker("", selection: $kind) {
                    ForEach(AgentPromptKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                Spacer()
                Button("초기화") { app.resetAgentPrompt(kind) }
                    .controlSize(.small).disabled(!app.agentPrompts.isCustomized(kind))
                    .help("이 양식을 기본값으로 되돌립니다")
            }
            TextEditor(text: Binding(get: { app.agentPrompts[kind] }, set: { app.setAgentPrompt(kind, $0) }))
                .font(.callout).frame(minHeight: 90, idealHeight: 110, maxHeight: 160)
                .overlay(border)
            HStack(spacing: 8) {
                Button { app.copyAgentPrompt(kind); note = "‘\(kind.label)’ 지시문을 클립보드에 복사했습니다" } label: {
                    Label("복사", systemImage: "doc.on.doc")
                }
                .help("아래 미리보기와 같은 최종 문구를 복사합니다. 에이전트 대화에 붙여넣어 쓰세요.")
                if app.promptGrantActive(kind) {
                    Button("MCP 조회 허용 해제") { app.onRevokePromptGrant?() }
                } else {
                    Button("MCP 조회 허용…") { app.onRequestPromptGrant?(kind) }
                        .help("지정한 도우미 프로세스가 이 지시문 하나만 읽도록 최대 10분 허용합니다. 다른 양식·설정은 읽을 수 없습니다.")
                }
                Text(app.promptGrantLabel(kind)).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Text("허용은 ‘읽을 수 있음’만 뜻합니다. 앱은 에이전트가 읽었는지, 해설을 쓰고 있는지 알지 못합니다. 문구를 고치면 허용이 해제됩니다.")
                .font(.caption2).foregroundStyle(.tertiary)
            DisclosureGroup("미리보기 — 복사와 MCP 조회에 쓰이는 최종 문구", isExpanded: $showPreview) {
                Text(app.agentPromptFinalText(kind))
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .font(.caption)
        }
    }

    // MARK: 받은 대본

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("받은 대본").font(.headline)
                Text(app.scriptInbox.items.isEmpty ? "없음" : "\(app.scriptInbox.items.count)건")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("에이전트 대본 받기 (이번 실행)", isOn: Binding(get: { app.scriptInboxEnabled },
                                                              set: { _ in app.onToggleScriptInbox?() }))
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("켜 둔 동안 submit_script 도구의 제출을 수신함에 쌓습니다. 도착해도 재생하지 않고 편집기를 바꾸지 않습니다.")
            }
            ForEach(app.scriptInbox.items) { item in
                HStack(spacing: 8) {
                    Text(item.receivedAt, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(item.displayText.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1).truncationMode(.tail)
                    if item.hasSeparateSpeech {
                        Text("음성 대본 포함").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary).clipShape(Capsule())
                    }
                    Spacer()
                    Button("편집기로") {
                        if !app.loadReceivedScript(item.id) { pendingLoad = item }
                    }
                    .controlSize(.small)
                    Button { app.discardReceivedScript(item.id) } label: { Image(systemName: "trash") }
                        .controlSize(.small).help("이 받은 대본을 지웁니다")
                }
            }
            if app.scriptInbox.items.isEmpty {
                Text("에이전트가 제출한 대본이 여기에 쌓입니다. 아래 편집기에 직접 붙여넣어도 됩니다.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 편집기

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("화면 문구").font(.headline)
                Text("자막에 그대로 표시 (예: as_frame)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if !app.pasteAgentScriptFromClipboard() {
                        if NSPasteboard.general.string(forType: .string).map({ !ScriptDraft.blank($0) }) ?? false {
                            confirmPaste = true
                        } else { note = "클립보드에 텍스트가 없습니다" }
                    }
                } label: { Label("붙여넣기", systemImage: "doc.on.clipboard") }
                    .controlSize(.small).help("클립보드의 텍스트를 화면 문구로 붙여넣습니다 (음성 대본은 비움)")
                Button { app.clearAgentDraft() } label: { Label("비우기", systemImage: "trash") }
                    .controlSize(.small).disabled(draft.isEmpty)
            }
            TextEditor(text: Binding(get: { app.agentDraft.displayText }, set: { app.setAgentDisplayText($0) }))
                .font(.body).frame(minHeight: 110).overlay(border)

            HStack {
                Text("음성 대본").font(.headline)
                Text("실제로 읽는 문구 (예: 애즈 프레임) · 비우면 화면 문구를 읽음").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if draft.speechState == .stale {
                HStack(spacing: 8) {
                    Label("화면 문구가 바뀜 — 이 음성 대본은 이전 문구에 맞춰 쓰였습니다", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Button("지금 문구에 맞음") { app.confirmAgentSpeechMatches() }.controlSize(.small)
                        .help("음성 대본을 직접 확인·수정했고 현재 화면 문구와 맞다고 표시합니다")
                    Button("음성 대본 버리기") { app.discardAgentSpeech() }.controlSize(.small)
                }
            }
            TextEditor(text: Binding(get: { app.agentDraft.speechText }, set: { app.setAgentSpeechText($0) }))
                .font(.body).frame(minHeight: 90).overlay(border)

            HStack(spacing: 10) {
                Button {
                    if app.playAgentScript() == .needsConfirmation { confirmStale = true }
                } label: { Label("재생", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(ScriptDraft.blank(draft.displayText) || app.isBusy)
                    .help("편집기에 보이는 문구 그대로 합성합니다. 앱이 대본을 다시 쓰지 않습니다.")
                Button { app.stop() } label: { Label("중지", systemImage: "stop.fill") }
                    .disabled(!app.isBusy)
                if app.isBusy { ProgressView().controlSize(.small) }
                Text(app.statusText.isEmpty ? note : app.statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
