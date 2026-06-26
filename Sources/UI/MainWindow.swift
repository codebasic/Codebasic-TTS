import AppKit
import SwiftUI

/// Owns the management window (a SwiftUI view hosted in an NSWindow). Created
/// lazily; reused across opens.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let appState: AppState

    init(appState: AppState) { self.appState = appState }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "Codebasic TTS"
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: RootView().environmentObject(appState))
            window = w
        }
        NSApp.setActivationPolicy(.regular)        // show in Dock while window is open
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only agent when the window is dismissed.
        NSApp.setActivationPolicy(.accessory)
    }
}
