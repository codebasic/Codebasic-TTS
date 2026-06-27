import SwiftUI

/// Optional per-run instruction field. Uses a TextEditor (wraps by character, so
/// long unbroken tokens like dataset paths still wrap) that grows with content
/// up to a cap, with a placeholder overlay and clear button. Shared by the 해설
/// panel (explainHint) and the TTS panel (scriptHint).
struct HintField: View {
    let placeholder: String
    @Binding var text: String
    var help: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary).font(.caption).padding(.top, 6)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body).foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 26, maxHeight: 90)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 5)
                    .help("추가 지시 지우기")
            }
        }
        .help(help)
    }
}
