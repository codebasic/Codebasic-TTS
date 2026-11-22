import Darwin
import Foundation

/// Compiled into both ends of the local MCP connection.
enum TTSRuntime {
    static let productionAppID = "com.seongjoo.SelectedTextTTS"
    #if TTS_LOCAL_PREVIEW
    static let isPreview = true
    static let appID = productionAppID + ".preview"
    static let displayName = "Codebasic TTS Preview"
    static let mcpServerName = "codebasic-tts-agent-preview"
    #else
    static let isPreview = false
    static let appID = productionAppID
    static let displayName = "Codebasic TTS"
    static let mcpServerName = "codebasic-tts-agent"
    #endif
    static let helperID = appID + ".agent-helper"

    static func applicationSupport(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(displayName, isDirectory: true)
    }

    static var socketDirectory: String { socketDirectory(uid: getuid()) }

    static func socketDirectory(uid: uid_t) -> String {
        let prefix = isPreview ? "codebasic-tts-preview-mcp" : "codebasic-tts-mcp"
        return "/private/tmp/\(prefix)-\(uid)"
    }
}
