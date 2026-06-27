import AppKit

/// Entry point for the macOS Services menu.
///
/// The selector MUST match `NSMessage` in Info.plist. For `NSMessage =
/// "readSelectedText"`, the runtime invokes `readSelectedText:userData:error:`,
/// which maps to the Swift method below. Do not rename one without the other.
final class ServiceProvider: NSObject {

    @objc func readSelectedText(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else {
            Log.service.error("Service fired but pasteboard held no plain text")
            error?.pointee = "No selectable text was provided." as NSString
            return
        }

        Log.service.info("Service fired: received \(text.count) chars")
        Task { @MainActor in
            AppDelegate.shared?.handleSelectedText(text)
        }
    }

    /// Second Services entry ("코드 해설"). NSMessage = "explainSelectedText" maps
    /// to this selector. Explains the selected code, then speaks it end-to-end.
    @objc func explainSelectedText(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else {
            Log.service.error("Explain service fired but pasteboard held no plain text")
            error?.pointee = "No selectable text was provided." as NSString
            return
        }

        Log.service.info("Explain service fired: received \(text.count) chars")
        Task { @MainActor in
            AppDelegate.shared?.handleCodeText(text)
        }
    }
}
