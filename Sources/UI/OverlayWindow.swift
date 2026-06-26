import AppKit
import SwiftUI

/// A borderless, floating, non-activating HUD panel that hosts PlayerOverlay.
/// Appears over whatever app the user is in while audio is synthesizing/playing.
@MainActor
final class OverlayWindow {
    private var panel: NSPanel?
    private let app: AppState

    init(app: AppState) { self.app = app }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
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
            let host = NSHostingView(rootView: PlayerOverlay(app: app))
            p.contentView = host
            p.setContentSize(host.fittingSize)
            panel = p
        }
        if let p = panel { position(p); p.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }

    private func position(_ p: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 48))
    }
}
