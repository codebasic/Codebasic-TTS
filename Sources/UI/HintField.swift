import SwiftUI

/// Optional per-run instruction field. A compact, fixed-height TextEditor (wraps
/// by character, so long unbroken tokens like dataset paths wrap) styled to match
/// the other editor boxes (default background + stroke), with a placeholder
/// overlay and clear button. Shared by the 해설 (explainHint) and TTS (scriptHint).
struct HintField: View {
    let placeholder: String
    @Binding var text: String
    var help: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary).font(.caption).padding(.top, 6)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 48)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.body).foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 6)
                    .help("추가 지시 지우기")
            }
        }
        .help(help)
    }
}
