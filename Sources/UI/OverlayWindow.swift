import AppKit
import SwiftUI
import Combine

/// A panel that never becomes key or main, so showing it cannot pull keyboard
/// focus away from the app the user is working in. Its buttons still receive
/// mouse clicks.
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A borderless, floating, non-activating HUD panel that hosts PlayerOverlay.
/// Appears over whatever app the user is in while audio is synthesizing/playing,
/// WITHOUT stealing focus. Re-sizes to its content (the subtitle grows/shrinks
/// per paragraph) and stays anchored by its BOTTOM edge so it never drifts off
/// the bottom of the screen.
@MainActor
final class OverlayWindow {
    private var panel: NSPanel?
    private var host: NSHostingView<PlayerOverlay>?
    private let app: AppState
    private var cancellables = Set<AnyCancellable>()

    private let bottomInset: CGFloat = 60

    init(app: AppState) { self.app = app }

    func show() {
        ensurePanel()
        relayout()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func ensurePanel() {
        guard panel == nil else { return }
        let h = NSHostingView(rootView: PlayerOverlay(app: app))
        let p = NonKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = h
        host = h
        panel = p

        // Content height changes per paragraph (subtitle) / mode — re-anchor then.
        app.$chunkIndex
            .merge(with: app.$phase.map { _ in 0 }, app.$playbackMode.map { _ in 0 })
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.relayout() }   // after SwiftUI re-lays-out
            }
            .store(in: &cancellables)
    }

    /// Size the panel to its current content and pin the bottom edge above the
    /// screen's bottom (grows upward, never downward off-screen).
    private func relayout() {
        guard let p = panel, let h = host, p.isVisible || p.contentView === h else { return }
        let size = h.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        guard let screen = NSScreen.main else { p.setContentSize(size); return }
        let f = screen.visibleFrame
        p.setContentSize(size)
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + bottomInset))
    }
}
