import SwiftUI

/// Compact floating transport shown while synthesizing / playing. Shows WHAT is
/// playing (TTS vs 해설) rather than the script text, with standard paragraph
/// navigation.
struct PlayerOverlay: View {
    @ObservedObject var app: AppState
    /// The 10 Hz playback values (progress / crawl position) — observed here ONLY,
    /// so ticking doesn't re-render the whole app. crawlFraction on `app` reads
    /// telemetry.chunkProgress, so observing telemetry keeps the crawl live.
    @ObservedObject var telemetry: PlaybackTelemetry

    /// Measured natural height of the full subtitle column (for the crawl mapping).
    @State private var contentHeight: CGFloat = 0

    private var tint: Color { app.playbackMode == .tts ? .blue : .purple }

    /// Viewport height — a few lines tall so context shows above/below the
    /// current sentence.
    private var subtitleViewportHeight: CGFloat { max(160, app.subtitleFontSize * 6.5) }

    /// Where the currently-read position sits in the viewport (0.5 = center).
    private let readingAnchor: CGFloat = 0.5

    /// Continuous crawl: keep the point at `progress` through the script at the
    /// reading line, so the text rises smoothly in step with playback and the
    /// current sentence stays centered.
    private func crawlOffset(progress: Double, contentH: CGFloat, viewportH: CGFloat) -> CGFloat {
        CrawlLayout.crawlOffset(progress: progress, contentHeight: contentH,
                                viewportHeight: viewportH, readingAnchor: readingAnchor)
    }

    /// Centered reading line → fade both ends: upcoming text fades in at the
    /// bottom, read text fades out at the top; the middle (current sentence) is sharp.
    private var crawlFadeMask: LinearGradient {
        LinearGradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: .black, location: 0.30),
            .init(color: .black, location: 0.70),
            .init(color: .clear, location: 1.0),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// The subtitle area shows only once playback has actually started — never
    /// during 해설/대본 generation or synthesis — so a previous run's subtitle
    /// can't linger and the new one appears fresh as playback begins.
    private var showsSubtitleArea: Bool {
        app.showSubtitle && (app.phase == .playing || app.phase == .paused) && !app.crawlLines.isEmpty
    }

    /// Widen the HUD with the subtitle font so a line holds roughly the same
    /// number of characters at any size — bigger text → wider panel, fewer
    /// wraps. Stays compact (360) when no subtitle is showing; capped so it
    /// never runs off a normal screen.
    private var hudWidth: CGFloat {
        guard showsSubtitleArea else { return 360 }
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

            if showsSubtitleArea {
                // The WHOLE script is one column that scrolls continuously in step
                // with playback (paragraphs flow into each other), keeping the
                // current sentence centered.
                let currentLineID = app.currentCrawlLineID   // compute once per frame, not per line
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(app.crawlLines) { line in
                        let cur = line.id == currentLineID
                        Text(line.text)
                            .font(.system(size: app.subtitleFontSize))
                            // distinguish the current line by brightness only (no weight
                            // change — that snaps and reflows, which read as abrupt)
                            .foregroundStyle(cur ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .opacity(cur ? 1 : 0.4)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .animation(.easeInOut(duration: 0.5), value: cur)   // gently fade the emphasis in/out
                    }
                }
                .fixedSize(horizontal: false, vertical: true)   // full natural height (don't compress to the viewport)
                .background(GeometryReader { g in                // measure that height for the crawl mapping
                    Color.clear
                        .onAppear { contentHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in contentHeight = h }
                })
                .offset(y: crawlOffset(progress: app.crawlFraction, contentH: contentHeight, viewportH: subtitleViewportHeight))
                .animation(.linear(duration: 0.12), value: app.crawlFraction)   // smooth between 0.1s ticks
                .frame(height: subtitleViewportHeight, alignment: .top)         // fixed viewport the text scrolls through
                .clipped()
                .mask(crawlFadeMask)
            }

            // Transport + progress are one fixed-size, centered cluster, so the
            // progress bar keeps a fixed width and nothing stretches as the
            // subtitle/panel widen.
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

                ProgressView(value: telemetry.progress).progressViewStyle(.linear)
                    .frame(width: 140)

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
