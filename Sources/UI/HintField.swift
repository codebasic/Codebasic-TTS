import SwiftUI

/// Optional per-run instruction field (icon + growing TextField + clear button).
/// Shared by the 해설 panel (explainHint) and the TTS panel (scriptHint).
struct HintField: View {
    let placeholder: String
    @Binding var text: String
    var help: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary).font(.caption)
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("추가 지시 지우기")
            }
        }
        .help(help)
    }
}
