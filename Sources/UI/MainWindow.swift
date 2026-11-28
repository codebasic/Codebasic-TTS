import AppKit
import SwiftUI

/// Owns the management window (a SwiftUI view hosted in an NSWindow). Created
/// lazily; reused across opens.
@MainActor
final class MainWindow {
    private let diagnosticID = MemoryDiagnostics.begin("mainWindow.instance")
    deinit { MemoryDiagnostics.end(diagnosticID) }
    private var window: NSWindow?
    private let appState: AppState

    init(appState: AppState) { self.appState = appState }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = TTSRuntime.displayName
            w.center()
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: RootView(app: appState).environmentObject(appState))
            window = w
            observeVisibility(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Feeds the Agent tab's "open" state. Focus does not matter; a window that
    /// is closed, minimized, hidden with the app or fully covered is not open.
    private func observeVisibility(_ window: NSWindow) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                                          NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        for name in names {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] note in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    let visible = note.name != NSWindow.willCloseNotification
                        && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
                    if self.appState.mainWindowVisible != visible { self.appState.mainWindowVisible = visible }
                }
            }
        }
    }
}
