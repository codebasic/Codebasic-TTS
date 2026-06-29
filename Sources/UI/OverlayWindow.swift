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
/// WITHOUT stealing focus.
///
/// Placement rules:
/// - It lands on the screen the *command* targeted (`app.hudTargetScreenID`,
///   captured at trigger time) — so in a lecture it shows on the screen the
///   learners see, not the instructor's private display.
/// - The user can drag it; the position is remembered per screen
///   (`app.hudPositions`), stored as a bottom-left offset within that screen's
///   visible frame so it survives display rearrangement.
/// - It re-sizes to its content (the subtitle grows/shrinks per paragraph and
///   with the font size) and stays anchored by its BOTTOM edge, so growth is
///   upward and the saved position is preserved across resizes.
@MainActor
final class OverlayWindow {
    private var panel: NSPanel?
    private var host: NSHostingView<PlayerOverlay>?
    private let app: AppState
    private var cancellables = Set<AnyCancellable>()

    /// True while we move the panel ourselves — so the resulting didMove
    /// notification isn't mistaken for a user drag and persisted.
    private var isProgrammaticMove = false
    /// Coalesces the disk write across the burst of moves a single drag emits.
    private var persistPositionWork: DispatchWorkItem?

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

        // Persist the user's spot whenever they drag the HUD (ignore our own moves).
        NotificationCenter.default.addObserver(self, selector: #selector(panelMoved(_:)),
                                               name: NSWindow.didMoveNotification, object: p)

        // Content height changes per paragraph / mode / font size — re-anchor then.
        app.$chunkIndex
            .merge(with: app.$phase.map { _ in 0 },
                   app.$playbackMode.map { _ in 0 },
                   app.$subtitleFontSize.map { _ in 0 })
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.relayout() }   // after SwiftUI re-lays-out
            }
            .store(in: &cancellables)
    }

    /// The screen the HUD should appear on: the one the command targeted, falling
    /// back to the screen the panel is already on, then the main screen.
    private func targetScreen() -> NSScreen? {
        if let id = app.hudTargetScreenID,
           let s = NSScreen.screens.first(where: { AppState.displayID(of: $0) == id }) {
            return s
        }
        return panel?.screen ?? NSScreen.main
    }

    /// Size the panel to its content, then place it: at the user's remembered
    /// position for the target screen if any, else bottom-center. The bottom edge
    /// is the anchor, so the panel grows upward without drifting.
    private func relayout() {
        guard let p = panel, let h = host, p.isVisible || p.contentView === h else { return }
        let size = h.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        guard let screen = targetScreen() else { p.setContentSize(size); return }
        let vf = screen.visibleFrame
        p.setContentSize(size)

        let origin: CGPoint
        if let id = AppState.displayID(of: screen), let off = app.hudPositions[id] {
            origin = CGPoint(x: vf.minX + off.x, y: vf.minY + off.y)   // remembered bottom-left
        } else {
            origin = CGPoint(x: vf.midX - size.width / 2, y: vf.minY + bottomInset)  // default: bottom-center
        }

        isProgrammaticMove = true
        p.setFrameOrigin(clamp(origin, size: size, in: vf))
        isProgrammaticMove = false
    }

    /// Keep the whole panel within the screen's visible frame.
    private func clamp(_ origin: CGPoint, size: NSSize, in vf: NSRect) -> CGPoint {
        CrawlLayout.clampOrigin(origin, size: size, in: vf)
    }

    /// A genuine user drag ended — remember this spot for whichever screen the
    /// panel now sits on, as a bottom-left offset within that screen.
    @objc private func panelMoved(_ note: Notification) {
        guard !isProgrammaticMove, let p = panel,
              let screen = p.screen, let id = AppState.displayID(of: screen) else { return }
        app.hudTargetScreenID = id    // dragging to another monitor re-targets, so the
                                      // next relayout keeps it here (not @Published → no loop);
                                      // the next command still re-captures via the mouse.
        let vf = screen.visibleFrame
        let offset = CGPoint(x: p.frame.minX - vf.minX, y: p.frame.minY - vf.minY)
        app.setHUDPosition(offset, for: id)         // memory now…

        persistPositionWork?.cancel()               // …disk after the drag settles
        let work = DispatchWorkItem { [weak self] in self?.app.saveSettings() }
        persistPositionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
