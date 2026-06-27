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

            HStack(spacing: 6) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary).font(.caption)
                TextField("추가 지시 (선택) — 맥락이나 재생성 방향. 예: 더 간결하게, 초보자 기준으로",
                          text: $app.explainHint, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                if !app.explainHint.isEmpty {
                    Button { app.explainHint = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("추가 지시 지우기")
                }
            }
            .help("이번 해설 생성/재생성에만 적용되는 일회성 지시입니다 (프롬프트에는 저장 안 됨)")

            HStack(spacing: 8) {
                Button {
                    Task { await app.explainCode() }
                } label: {
                    Label("해설 생성", systemImage: "wand.and.stars")
                }
                .disabled(codeEmpty || app.explaining)
                .help("코드 전체를 처음부터 해설합니다 (기존 해설을 대체)")

                Button {
                    Task { await app.continueExplain() }
                } label: {
                    Label("이어서 해설", systemImage: "text.append")
                }
                .disabled(codeEmpty || app.explaining)
                .help("이전 해설 이후 추가·변경된 부분만 이어서 해설에 덧붙입니다")

                Button { Task { await app.explainCode(force: true) } } label: {
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

            HStack {
                Text("해설").font(.headline)
                if app.canContinueExplain {
                    Text("· 이어쓰기 기준 설정됨").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { app.clearCommentary() } label: { Label("비우기", systemImage: "trash") }
                    .controlSize(.small)
                    .disabled(explanationEmpty && !app.canContinueExplain)
                    .help("해설과 이어쓰기 기준을 비우고 처음부터 시작")
            }
            TextEditor(text: $app.explanationText)
                .font(.body).frame(minHeight: 150)
                .overlay(border)

            HStack(spacing: 10) {
                Button { app.sendExplanationToGenerate() } label: {
                    Label("생성 탭으로 보내기", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(explanationEmpty)
                .help("해설을 원본 텍스트로 보내 TTS 대본을 만들고 재생합니다")

                Button { app.speakExplanation() } label: { Label("전체 재생", systemImage: "play.fill") }
                    .disabled(explanationEmpty || app.isBusy)
                Button { app.speakContinue() } label: { Label("이어서 읽기", systemImage: "forward.end.fill") }
                    .disabled(!app.hasLastSegment)
                    .help("마지막에 추가된 해설을 이어서 읽습니다 · 재생 중이면 끊김 없이 큐에 이어붙입니다 (생성 탭은 그대로)")
                Button { app.stop() } label: { Label("중지", systemImage: "stop.fill") }
                    .disabled(!app.isBusy)
                if app.isBusy { ProgressView().controlSize(.small) }
                Text(app.statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }

            DisclosureGroup("해설 프롬프트", isExpanded: $showPrompt) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("해설 지시문 — LLM에게 주는 규칙").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $app.explainPrompt)
                        .font(.callout.monospaced()).frame(minHeight: 110)
                        .overlay(border)
                    HStack {
                        Button("기본값 복원") {
                            app.explainPrompt = CodeExplanation.defaultInstruction
                            app.saveSettings()
                        }
                        Spacer()
                    }
                }
                .padding(.top, 4)
                .onChange(of: app.explainPrompt) { _, _ in app.saveSettings() }
            }

            Text("제공자: \(app.normalizeProvider.label) (설정 탭) · 해설 모델은 위에서 따로 선택")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}
