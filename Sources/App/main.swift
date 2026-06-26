import AppKit

// Programmatic entry point (no storyboard / no @NSApplicationMain).
// LSUIElement in Info.plist already makes this an agent app, but we also set
// the activation policy explicitly as belt-and-suspenders so it never grabs a
// Dock icon even when launched directly during development.
// Program start runs on the main thread; assume the main actor so we can touch
// the @MainActor AppDelegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Agent by default so background (Services-triggered) playback never steals
    // focus; MainWindow flips to .regular (Dock icon) while its window is open.
    app.setActivationPolicy(.accessory)
    app.run()
}
