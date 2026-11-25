import Darwin
import Foundation

/// Compiled into both ends of the local MCP connection.
enum TTSRuntime {
    static let productionAppID = "com.seongjoo.SelectedTextTTS"
    // Three builds, each with its own identity, data folder and sockets:
    //   product — the installed app.
    //   preview — agent workspace only; synthesis, accounts and system hooks are off.
    //   review  — the whole app for trying a change beside the installed one. Only the
    //             system-wide hooks (Services, global hotkeys) are left to the product.
    #if TTS_LOCAL_PREVIEW
    static let isPreview = true
    static let isReview = false
    static let appID = productionAppID + ".preview"
    static let displayName = "Codebasic TTS Preview"
    static let mcpServerName = "codebasic-tts-agent-preview"
    #elseif TTS_LOCAL_REVIEW
    static let isPreview = false
    static let isReview = true
    static let appID = productionAppID + ".review"
    static let displayName = "Codebasic TTS Review"
    static let mcpServerName = "codebasic-tts-agent-review"
    #else
    static let isPreview = false
    static let isReview = false
    static let appID = productionAppID
    static let displayName = "Codebasic TTS"
    static let mcpServerName = "codebasic-tts-agent"
    #endif
    static let helperID = appID + ".agent-helper"
    /// Services and global hotkeys are per-user singletons, so only the product claims them.
    static let registersSystemIntegration = !isPreview && !isReview

    static func applicationSupport(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(displayName, isDirectory: true)
    }

    static var socketDirectory: String { socketDirectory(uid: getuid()) }

    static func socketDirectory(uid: uid_t) -> String {
        let prefix = isPreview ? "codebasic-tts-preview-mcp" : isReview ? "codebasic-tts-review-mcp" : "codebasic-tts-mcp"
        return "/private/tmp/\(prefix)-\(uid)"
    }
}
