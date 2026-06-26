import AppKit

// Programmatic entry point (no storyboard / no @NSApplicationMain).
// LSUIElement in Info.plist already makes this an agent app, but we also set
// the activation policy explicitly as belt-and-suspenders so it never grabs a
// Dock icon even when launched directly during development.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
