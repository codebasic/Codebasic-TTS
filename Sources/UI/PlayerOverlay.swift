import SwiftUI

/// Compact floating transport shown while synthesizing / playing. Shows WHAT is
/// playing (TTS vs 해설) rather than the script text, with standard paragraph
/// navigation.
struct PlayerOverlay: View {
    @ObservedObject var app: AppState

    private var tint: Color { app.playbackMode == .tts ? .blue : .purple }

    /// Widen the HUD with the subtitle font so a line holds roughly the same
    /// number of characters at any size — bigger text → wider panel, fewer
    /// wraps. Stays compact (360) when no subtitle is showing; capped so it
    /// never runs off a normal screen.
    private var hudWidth: CGFloat {
        guard app.showSubtitle, !app.currentChunkText.isEmpty else { return 360 }
        return min(max(360, app.subtitleFontSize * 24), 760)
    }

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
                } else {
                    HStack(spacing: 10) {
                        Button { app.toggleSubtitle() } label: {
                            Image(systemName: app.showSubtitle ? "captions.bubble.fill" : "captions.bubble")
                        }
                        .help(app.showSubtitle ? "자막 끄기" : "자막 켜기")
                        if app.showSubtitle {
                            HStack(spacing: 2) {
                                Button { app.adjustSubtitleFont(by: -2) } label: { Image(systemName: "minus") }
                                    .disabled(app.subtitleFontSize <= AppState.subtitleFontRange.lowerBound)
                                    .help("자막 작게")
                                Image(systemName: "textformat.size").foregroundStyle(.secondary)
                                Button { app.adjustSubtitleFont(by: 2) } label: { Image(systemName: "plus") }
                                    .disabled(app.subtitleFontSize >= AppState.subtitleFontRange.upperBound)
                                    .help("자막 크게")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                }
            }

            if app.showSubtitle, !app.currentChunkText.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(app.currentSentences.enumerated()), id: \.offset) { i, s in
                                let cur = app.currentSentenceIndex
                                Text(s)
                                    .font(.system(size: app.subtitleFontSize))
                                    .fontWeight(i == cur ? .semibold : .regular)
                                    .foregroundStyle(i == cur ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                    .opacity(i == cur ? 1 : max(0.3, 1 - 0.25 * Double(abs(i - cur))))
                                    .padding(.horizontal, i == cur ? 6 : 0)
                                    .padding(.vertical, i == cur ? 3 : 0)
                                    .background(i == cur ? tint.opacity(0.22) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                    }
                    .frame(maxHeight: max(92, app.subtitleFontSize * 5))
                    .onChange(of: app.currentSentenceIndex) { _, idx in
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(idx, anchor: .center) }
                    }
                    .onChange(of: app.chunkIndex) { _, _ in
                        proxy.scrollTo(0, anchor: .top)   // new paragraph → back to top
                    }
                }
            }

            // Progress spans the width; transport stays a fixed-size, centered
            // cluster so it doesn't grow or spread out as the subtitle/panel widen.
            ProgressView(value: app.progress).progressViewStyle(.linear)

            HStack(spacing: 22) {
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
                Button { app.stop() } label: { Image(systemName: "stop.fill") }
                    .foregroundStyle(.secondary).help("중지")
            }
            .frame(maxWidth: .infinity)   // center the cluster in the (possibly wide) panel
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: hudWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }
}
