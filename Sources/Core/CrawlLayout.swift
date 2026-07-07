import CoreGraphics

/// Pure geometry for the subtitle crawl and the HUD panel placement — kept free
/// of SwiftUI/AppKit so it's unit-testable (see `./build.sh test`).
enum CrawlLayout {
    /// Vertical offset of the subtitle column so the point at `progress` (0…1)
    /// through the content sits at `readingAnchor` (0…1 of the viewport). The
    /// content scrolls upward as progress grows; with readingAnchor 0.5 the
    /// current line stays vertically centered.
    static func crawlOffset(progress: Double, contentHeight: CGFloat,
                            viewportHeight: CGFloat, readingAnchor: CGFloat) -> CGFloat {
        readingAnchor * viewportHeight - CGFloat(progress) * contentHeight
    }

    /// How far through playback (0…1), weighted by spoken-chunk length (chars) so
    /// the crawl tracks the voice rather than lurching per paragraph. `chunkIndex`
    /// is 1-based (0 before playback starts); `chunkProgress` is the 0…1 position
    /// within the current chunk.
    static func fraction(chunkLengths: [Double], chunkIndex: Int, chunkProgress: Double) -> Double {
        let total = chunkLengths.reduce(0, +)
        guard total > 0 else { return 0 }
        let cur = chunkIndex - 1
        var read = 0.0
        for i in 0..<chunkLengths.count where i < cur { read += chunkLengths[i] }
        if chunkLengths.indices.contains(cur) { read += chunkProgress * chunkLengths[cur] }
        return Swift.min(1, read / total)
    }

    /// Clamp a panel of `size` to stay within `visible`, returning the adjusted
    /// bottom-left origin (Cocoa coords). Used so the HUD never drifts off-screen.
    static func clampOrigin(_ origin: CGPoint, size: CGSize, in visible: CGRect) -> CGPoint {
        let x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        let y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGPoint(x: x, y: y)
    }
}
