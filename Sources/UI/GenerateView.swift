import SwiftUI

/// Direct text input → synthesize + play. The editor is bound to AppState.inputText
/// so text read via the Services menu also appears here.
struct GenerateView: View {
    @EnvironmentObject var app: AppState

    private var canPlay: Bool {
        !app.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("텍스트 입력").font(.headline)

            TextEditor(text: $app.inputText)
                .font(.body)
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack(spacing: 10) {
                Button {
                    app.synthesize(app.inputText)
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
                .disabled(!app.isBusy)

                if app.isBusy { ProgressView().controlSize(.small) }
                Text(statusLine).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }

            Text("보이스: \(app.voiceName) · 모델: \(app.modelId) · 캐시: \(app.useCache ? "켜짐" : "꺼짐")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
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
