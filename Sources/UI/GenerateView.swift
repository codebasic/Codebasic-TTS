import SwiftUI

/// Two-panel generation: top = original (source) text, bottom = the TTS-friendly
/// script actually sent to the engine. A collapsible panel manages the
/// normalization prompt.
struct GenerateView: View {
    @EnvironmentObject var app: AppState
    @State private var showPrompt = false

    private var canPrepare: Bool {
        !app.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !app.normalizing
    }
    private var canPlay: Bool {
        let s = app.scriptText.isEmpty ? app.inputText : app.scriptText
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("원본 텍스트").font(.headline)
                Spacer()
                Button {
                    if let t = RichPaste.cleanText() { app.inputText = t }
                } label: {
                    Label("웹에서 붙여넣기 (정리)", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)
                .help("클립보드의 웹 서식(HTML)을 읽어 수식·마크다운 잔재를 정리해 붙여넣습니다")
            }
            TextEditor(text: $app.inputText)
                .font(.body).frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack(spacing: 8) {
                Button {
                    Task { await app.prepareScript() }
                } label: {
                    Label(app.normalizeEnabled ? "TTS 대본 생성" : "대본으로 복사",
                          systemImage: "wand.and.stars")
                }
                .disabled(!canPrepare)

                if app.normalizeEnabled {
                    Button { app.regenerateScript() } label: {
                        Label("재생성", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canPrepare)
                    .help("정규화 캐시를 무시하고 LLM으로 다시 생성")
                }

                if app.normalizing {
                    ProgressView().controlSize(.small)
                    Text("대본 생성 중…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !app.normalizeEnabled {
                    Text("정규화 꺼짐 (설정)").font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("TTS 대본 — 실제 합성에 사용").font(.headline)
            TextEditor(text: $app.scriptText)
                .font(.body).frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack(spacing: 10) {
                Button { app.speakScript() } label: { Label("재생", systemImage: "play.fill") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canPlay)
                Button { app.stop() } label: { Label("중지", systemImage: "stop.fill") }
                    .disabled(!app.isBusy)
                if app.isBusy { ProgressView().controlSize(.small) }
                Text(statusLine).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }

            DisclosureGroup("프롬프트 관리", isExpanded: $showPrompt) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("정규화 지시문 — LLM에게 주는 규칙").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $app.normalizePrompt)
                        .font(.callout.monospaced()).frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    HStack {
                        Button("기본값 복원") {
                            app.normalizePrompt = TextNormalizer.defaultInstruction
                            app.saveSettings()
                        }
                        Spacer()
                    }
                }
                .padding(.top, 4)
                .onChange(of: app.normalizePrompt) { _, _ in app.saveSettings() }
            }

            Text("보이스: \(app.voiceName) · 모델: \(app.modelId)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private var statusLine: String {
        if app.chunkCount > 1, app.isBusy {
            return "\(app.statusText) · 문단 \(app.chunkIndex)/\(app.chunkCount)"
        }
        return app.statusText
    }
}
