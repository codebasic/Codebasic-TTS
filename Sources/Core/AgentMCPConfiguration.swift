import CryptoKit
import Foundation

/// Format local stdio setup without reading, creating or modifying any client config.
struct AgentMCPConfiguration {
    let command: String
    let serverName: String

    static func bundled(in bundle: Bundle = .main, fileManager: FileManager = .default) -> Self? {
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/CodebasicAgentMCP")
        guard let values = try? helper.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              fileManager.isExecutableFile(atPath: helper.path),
              let identifier = bundle.bundleIdentifier else { return nil }
        return Self(command: helper.path, bundleID: identifier)
    }

    init?(command: String, bundleID: String) {
        guard command.hasPrefix("/"), !command.utf8.contains(0), !bundleID.isEmpty else { return nil }
        self.command = command
        if bundleID == TTSRuntime.productionAppID {
            serverName = "codebasic_tts_agent"
        } else {
            // Every review bundle gets a different key from production and other previews.
            let digest = SHA256.hash(data: Data(bundleID.utf8)).prefix(6)
            serverName = "codebasic_tts_preview_" + digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    var codexTOML: String {
        let quoted = command.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x22: return "\\\""
            case 0x5c: return "\\\\"
            case 0x00...0x1f, 0x7f: return String(format: "\\u%04X", scalar.value)
            default: return String(scalar)
            }
        }.joined()
        return "[mcp_servers.\(serverName)]\ncommand = \"\(quoted)\"\n"
    }

    var claudeCodeCommand: String? {
        guard let json = try? JSONSerialization.data(
            withJSONObject: ["type": "stdio", "command": command, "args": []],
            options: [.sortedKeys, .withoutEscapingSlashes]),
              let entry = String(data: json, encoding: .utf8) else { return nil }
        let quoted = "'" + entry.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "claude mcp add-json \(serverName) \(quoted) --scope user"
    }
}
