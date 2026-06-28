import SwiftUI

/// Compact floating transport shown while synthesizing / playing. Shows WHAT is
/// playing (TTS vs 해설) rather than the script text, with standard paragraph
/// navigation.
struct PlayerOverlay: View {
    @ObservedObject var app: AppState

    private var tint: Color { app.playbackMode == .tts ? .blue : .purple }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(app.playbackMode.label, systemImage: app.playbackMode.icon)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(tint.opacity(0.18), in: Capsule())
                    .foregroundStyle(tint)
                if app.chunkCount > 1 {
                    Text("문단 \(app.chunkIndex)/\(app.chunkCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if app.phase == .synthesizing {
                    ProgressView().controlSize(.small)
                    Text("합성 중…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if app.showSubtitle, !app.currentChunkText.isEmpty {
                Text(app.currentChunkText)
                    .font(.callout)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 16) {
                Button { app.skipPrev() } label: { Image(systemName: "backward.fill") }
                    .disabled(!app.canSkipPrev)
                Button { app.togglePause() } label: {
                    Image(systemName: app.phase == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 18, weight: .semibold)).frame(width: 22)
                }
                .disabled(app.phase == .synthesizing)
                .help(app.phase == .paused ? "재개" : "일시정지")
                Button { app.skipNext() } label: { Image(systemName: "forward.fill") }
                    .disabled(!app.canSkipNext)

                ProgressView(value: app.progress).progressViewStyle(.linear)

                Button { app.stop() } label: { Image(systemName: "stop.fill") }
                    .foregroundStyle(.secondary).help("중지")
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }
}
