import SwiftUI
import AppKit

/// The 해설 panel: code → commentary. Top = source code, bottom = the generated
/// spoken-style explanation. From here you either hand the commentary to the
/// 생성 tab (코드 → 해설 → 대본 → 음성, each stage visible/editable) or speak it
/// directly. The actual 대본 + 음성 stages live in GenerateView.
struct CommentaryView: View {
    @EnvironmentObject var app: AppState
    @State private var showPrompt = false

    private var codeEmpty: Bool {
        app.codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var explanationEmpty: Bool {
        app.explanationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var border: some View { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("코드").font(.headline)
                Spacer()
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { app.codeText = s }
                } label: {
                    Label("붙여넣기", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)
                .help("클립보드의 코드를 그대로 붙여넣습니다")
            }
            TextEditor(text: $app.codeText)
                .font(.body.monospaced()).frame(minHeight: 150)
                .overlay(border)

            HintField(placeholder: "추가 지시 (해설, 선택) — 맥락이나 재생성 방향. 예: 더 간결하게, 초보자 기준으로",
                      text: $app.explainHint,
                      help: "코드→해설 생성·이어서 해설·재생성에만 적용되는 일회성 지시 (프롬프트엔 저장 안 됨)")

            HStack(spacing: 8) {
                Button {
                    app.generateExplanation()
                } label: {
                    Label("해설 생성", systemImage: "wand.and.stars")
                }
                .disabled(codeEmpty || app.explaining)
                .help("코드 전체를 처음부터 해설합니다 (기존 해설을 대체)")

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
                .disabled(codeEmpty || app.explaining)
                .help("해설 캐시를 무시하고 전체를 다시 생성")

                if app.explaining {
                    ProgressView().controlSize(.small)
                    Text("해설 생성 중…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                LLMModelPicker(label: "해설 모델",
                               ollamaModel: $app.explainOllamaModel,
                               geminiModel: $app.explainGeminiModel,
                               onChange: { app.saveSettings() })
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
                    .help("해설·이어쓰기 기준을 비우고 처음부터 시작")
            }

            TextEditor(text: $app.explanationText)
                .font(.body).frame(minHeight: 150)
                .overlay(border)

            HStack(spacing: 10) {
                Button { app.sendExplanationToGenerate() } label: {
                    Label("TTS로 보내기", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(explanationEmpty)
                .help("해설을 TTS 탭으로 보내 음성 대본(정규화)을 만들고 재생합니다")

                Button { app.speakExplanation() } label: { Label("전체 재생", systemImage: "play.fill") }
                    .disabled(explanationEmpty || app.isBusy || app.explaining)
                    .help("해설을 그대로 읽습니다 (음성 대본 정규화는 TTS 탭)")
                Button { app.speakContinue() } label: { Label("이어서 읽기", systemImage: "forward.end.fill") }
                    .disabled(!app.hasLastSegment || app.explaining)
                    .help("마지막에 추가된 해설을 이어서 읽습니다 (재생 중이면 멈추고 그 부분을 재생)")
                Button { app.stop() } label: { Label("중지", systemImage: "stop.fill") }
                    .disabled(!app.isBusy && !app.explaining)
                if app.isBusy { ProgressView().controlSize(.small) }
                Text(app.statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }

            DisclosureGroup("해설 프롬프트", isExpanded: $showPrompt) {
                promptEditor(caption: "해설 지시문 — 코드를 어떻게 해설할지 LLM에게 주는 규칙",
                             text: $app.explainPrompt,
                             restore: { app.explainPrompt = CodeExplanation.defaultInstruction })
            }

            Text("제공자: \(app.normalizeProvider.label) (설정 탭) · 해설 모델은 위에서 선택")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    /// One prompt editor (caption + monospace editor + 기본값 복원), saving on edit.
    @ViewBuilder
    private func promptEditor(caption: String, text: Binding<String>,
                              restore: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.callout.monospaced()).frame(minHeight: 110)
                .overlay(border)
            HStack {
                Button("기본값 복원") { restore(); app.saveSettings() }
                Spacer()
            }
        }
        .padding(.top, 4)
        .onChange(of: text.wrappedValue) { _, _ in app.saveSettings() }
    }
}
