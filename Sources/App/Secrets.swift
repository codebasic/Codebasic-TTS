import Foundation

/// API key access. MVP reads a plaintext key file from Application Support
/// (user-readable only); build.sh installs it there from Sidecar/.eleven_key.
/// Keychain hardening is a later milestone.
enum Secrets {
    static let appSupportDir = ("~/Library/Application Support/Codebasic TTS V2"
        as NSString).expandingTildeInPath

    static var elevenLabsKey: String? { key(named: "eleven_key") }
    static var geminiKey: String? { key(named: "gemini_key") }
    static var zaiKey: String? { key(named: "zai_key") }

    static func key(named name: String) -> String? {
        let path = (appSupportDir as NSString).appendingPathComponent(name)
        let legacy = ("~/Library/Application Support/Codebasic TTS" as NSString).expandingTildeInPath
        let reuse = FileManager.default.fileExists(atPath: appSupportDir + "/reuse-v1-credentials")
        // Explicit opt-in, read-only fallback. Writes always remain in V2.
        guard let raw = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? (reuse ? try? String(contentsOfFile: legacy + "/" + name, encoding: .utf8) : nil) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func writeKey(named name: String, _ value: String) {
        try? FileManager.default.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
        let path = (appSupportDir as NSString).appendingPathComponent(name)
        try? value.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // Custom endpoints keep their key in its own file named after the endpoint
    // id (`<endpoint_id>.key`), never inside settings.json.
    static func endpointKey(_ id: UUID) -> String? { key(named: id.uuidString + ".key") }
    static func writeEndpointKey(_ id: UUID, _ value: String) { writeKey(named: id.uuidString + ".key", value) }
}
