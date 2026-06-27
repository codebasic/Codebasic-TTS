import SwiftUI

/// Right-side inspector for one generation stage: LLM 생성 매개변수 (temperature)
/// + the stage's prompt editor. Shared by the 해설 and TTS panels. Saves on edit.
struct StageInspector: View {
    let title: String
    @Binding var temperature: Double
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
        .onChange(of: prompt) { _, _ in onChange() }
    }
}
