import Foundation

/// API key access. MVP reads a plaintext key file from Application Support
/// (user-readable only); build.sh installs it there from Sidecar/.eleven_key.
/// Keychain hardening is a later milestone.
enum Secrets {
    static let appSupportDir = ("~/Library/Application Support/Codebasic TTS"
        as NSString).expandingTildeInPath

    static var elevenLabsKey: String? {
        let path = (appSupportDir as NSString).appendingPathComponent("eleven_key")
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}
