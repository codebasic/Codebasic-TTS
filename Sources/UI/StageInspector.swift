import SwiftUI

/// Right-side inspector for one generation stage: LLM 생성 매개변수 (temperature,
/// reasoning 수준) + the stage's prompt editor. Shared by the 해설 and TTS panels.
/// Saves on edit. `visionReasoningLevel` is optional so the 해설 panel can also
/// expose the 비전 stage's reasoning 수준.
struct StageInspector: View {
    let title: String
    @Binding var temperature: Double
    @Binding var reasoningLevel: ReasoningLevel
    var visionLevelTitle: String? = nil
    var visionReasoningLevel: Binding<ReasoningLevel>? = nil
    @Binding var prompt: String
    let promptCaption: String
    let restore: () -> Void
    var onChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Temperature").font(.caption)
                    Spacer()
                    Text(String(format: "%.2f", temperature))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $temperature, in: 0...1, step: 0.05)
                Text("낮을수록 일관적·결정적, 높을수록 다양함").font(.caption2).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("생성 수준").font(.caption)
                    Spacer()
                    Picker("", selection: $reasoningLevel) {
                        ForEach(ReasoningLevel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    .help("thinking(reasoning) 노력 — 보통은 모델 기본값을 그대로 쓰고(파라미터 미전송), 낮음·높음일 때만 공급자별 파라미터로 변환해 보냅니다 (OpenAI 호환: reasoning_effort, GLM: thinking, Gemini: thinkingBudget, Ollama: think). thinking을 지원하지 않는 모델은 낮음·높음이 적용되지 않거나 요청이 거부될 수 있습니다.")
                }
                levelCaption
            }

            if let vision = visionReasoningLevel {
                HStack {
                    Text(visionLevelTitle ?? "비전 생성 수준").font(.caption)
                    Spacer()
                    Picker("", selection: vision) {
                        ForEach(ReasoningLevel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    .help("스크린샷 전사(비전) 호출에 쓰이는 reasoning 수준입니다")
                }
            }

            Divider()

            Text(promptCaption).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.callout.monospaced())
                .frame(maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("기본값 복원") { restore(); onChange() }
                Spacer()
            }
        }
        .padding(12)
        .frame(minWidth: 240, idealWidth: 320, maxWidth: 560)
        .background(.background)
        .onChange(of: temperature) { _, _ in onChange() }
        .onChange(of: reasoningLevel) { _, _ in onChange() }
        .onChange(of: visionReasoningLevel?.wrappedValue) { _, _ in onChange() }
        .onChange(of: prompt) { _, _ in onChange() }
    }

    private var levelCaption: some View {
        Text("보통 = 모델 기본값 그대로. 낮음·높음은 thinking 지원 모델에만 적용됩니다")
            .font(.caption2).foregroundStyle(.tertiary)
    }
}
