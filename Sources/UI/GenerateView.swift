import SwiftUI

/// Direct text input → synthesize + play.
struct GenerateView: View {
    @EnvironmentObject var app: AppState
    @State private var text = ""

    private var canPlay: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("텍스트 입력").font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack(spacing: 10) {
                Button {
                    app.synthesize(text)
                } label: {
                    Label("생성 / 재생", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canPlay)

                Button {
                    app.stop()
                } label: {
                    Label("중지", systemImage: "stop.fill")
                }
                .disabled(!app.isWorking)

                if app.isWorking { ProgressView().controlSize(.small) }
                Text(app.statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }

            Text("보이스: \(app.voiceName) · 모델: \(app.modelId) · 캐시: \(app.useCache ? "켜짐" : "꺼짐")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}
