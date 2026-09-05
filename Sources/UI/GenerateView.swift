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
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !app.normalizing
    }

    var body: some View {
        HSplitView {
            main
            if showPrompt {
                StageInspector(title: "대본 설정",
                               temperature: $app.scriptTemperature,
                               prompt: $app.normalizePrompt,
                               promptCaption: "정규화 지시문 — 대본을 어떻게 다듬을지 LLM에게 주는 규칙",
                               restore: { app.normalizePrompt = TextNormalizer.defaultInstruction },
                               onChange: { app.saveSettings() })
            }
        }
    }

    private var main: some View {
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
                Button { showPrompt.toggle() } label: { Image(systemName: "sidebar.right") }
                    .controlSize(.small)
                    .help("프롬프트·생성 매개변수 패널 열기/닫기")
            }
            TextEditor(text: $app.inputText)
                .font(.body).frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack(spacing: 8) {
                Button {
                    app.generateScript()
                } label: {
                    Label(app.normalizeEnabled ? "TTS 대본 생성" : "대본으로 복사",
                          systemImage: "wand.and.stars")
                }
                .disabled(!canPrepare)

                if app.normalizeEnabled {
                    Button { app.regenerateScript() } label: {
                        Label(app.scriptText.isEmpty ? "재생성" : "다듬기",
                              systemImage: app.scriptText.isEmpty ? "arrow.clockwise" : "wand.and.stars")
                    }
                    .disabled(!canPrepare)
                    .help(app.scriptText.isEmpty
                          ? "정규화 캐시를 무시하고 원본에서 새로 생성"
                          : "원본 + 현재 대본 + 추가 지시로 미흡한 부분만 다듬기 (현재 대본을 덮어씀)")
                }

                if app.normalizing {
                    ProgressView().controlSize(.small)
                    Text("대본 생성 중…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if app.normalizeEnabled {
                    LLMModelPicker(label: "대본 모델",
                                   provider: $app.scriptProvider,
                                   geminiModel: $app.geminiModel,
                                   ollamaModel: $app.ollamaModel,
                                   zaiModel: $app.scriptZAIModel,
                                   onChange: { app.saveSettings() })
                } else {
                    Text("정규화 꺼짐 (설정)").font(.caption).foregroundStyle(.secondary)
                }
            }

            if app.normalizeEnabled {
                HintField(placeholder: "추가 지시 (대본, 선택) — 발음·표기 방향. 예: 영어 약자는 한글 발음으로",
                          text: $app.scriptHint,
                          help: "원문→대본 생성·재생성에만 적용되는 일회성 지시 (프롬프트엔 저장 안 됨)")
            }

            HStack {
                Text("TTS 대본 — 실제 합성에 사용").font(.headline)
                if app.scriptStale {
                    Label("원본·지시가 바뀜 — 재생성/다듬기 필요", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button { app.recordIssue(.script) } label: { Label("이슈 기록", systemImage: "flag") }
                    .controlSize(.small)
                    .disabled(app.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("현재 대본 생성 컨텍스트(원본·프롬프트·추가 지시·대본)를 백로그에 기록")
            }
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

            Text("보이스: \(app.voiceName) · 모델: \(app.modelId)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 420, maxWidth: .infinity)
    }

    private var statusLine: String {
        if app.chunkCount > 1, app.isBusy {
            return "\(app.statusText) · 문단 \(app.chunkIndex)/\(app.chunkCount)"
        }
        return app.statusText
    }
}
