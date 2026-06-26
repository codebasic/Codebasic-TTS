import SwiftUI

/// Compact floating transport shown while synthesizing / playing.
struct PlayerOverlay: View {
    @ObservedObject var app: AppState

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if app.phase == .synthesizing {
                    ProgressView().controlSize(.small).frame(width: 22)
                } else {
                    Button { app.togglePause() } label: {
                        Image(systemName: app.phase == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 22)
                    }
                    .buttonStyle(.plain)
                    .help(app.phase == .paused ? "재개" : "일시정지")
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(app.currentText.isEmpty ? "Codebasic TTS" : app.currentText)
                    .lineLimit(1).font(.callout)
                ProgressView(value: app.progress).progressViewStyle(.linear)
            }

            Button { app.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("중지")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }
}
