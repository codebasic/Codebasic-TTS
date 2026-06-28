import AppKit
import Carbon
import ApplicationServices

/// System-wide hotkeys (Carbon `RegisterEventHotKey`, no special permission to
/// register). Each fires an action on the main thread. Used to grab the current
/// selection from any app — even ones whose context menu hides the Services menu
/// (e.g. VS Code) — without going through a menu.
final class HotKeyCenter {
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]   // hotKeyID.id → action

    init() { installHandler() }

    func register(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        actions[id] = action
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: 0x43425453 /* "CBTS" */, id: id)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetEventDispatcherTarget(), 0, &ref)
        refs.append(ref)
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData!).takeUnretainedValue()
            let id = hkID.id
            DispatchQueue.main.async { center.actions[id]?() }
            return noErr
        }, 1, &spec, ptr, &handler)
    }
}

/// Reads the current selection from the frontmost app by synthesizing ⌘C with the
/// clipboard saved and restored — the user never copies and never sees a
/// clipboard change. Synthesizing the keystroke needs Accessibility permission.
enum SelectionGrabber {
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Prompt for Accessibility permission (shows the system dialog once).
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Grab the selection. `completion` runs on the main thread; nil if no
    /// selection / no permission.
    static func grab(_ completion: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted() else {
            requestPermission()
            DispatchQueue.main.async { completion(nil) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let pb = NSPasteboard.general
            let saved = snapshot(pb)
            let before = pb.changeCount
            postCopy()
            var text: String?
            for _ in 0..<25 {                       // poll up to ~0.5s for the copy to land
                usleep(20_000)
                if pb.changeCount != before { text = pb.string(forType: .string); break }
            }
            DispatchQueue.main.async {
                restore(pb, saved)                  // put the user's clipboard back
                let t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                completion((t?.isEmpty ?? true) ? nil : t)
            }
        }
    }

    private static func postCopy() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func restore(_ pb: NSPasteboard, _ items: [NSPasteboardItem]) {
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
