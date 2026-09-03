import Foundation

/// API key access. MVP reads a plaintext key file from Application Support
/// (user-readable only); build.sh installs it there from Sidecar/.eleven_key.
/// Keychain hardening is a later milestone.
enum Secrets {
    static let appSupportDir = ("~/Library/Application Support/Codebasic TTS"
        as NSString).expandingTildeInPath

    static var elevenLabsKey: String? { key(named: "eleven_key") }
    static var geminiKey: String? { key(named: "gemini_key") }
    static var openCodeKey: String? { key(named: "opencode_key") }
    /// OpenAI 호환 채널 키. 기본은 TTS 앱의 Gemini 키 공용(별도 발급 불필요) —
    /// `openai_key` 파일이 있으면 그것이 우선한다.
    static var openAIKey: String? { key(named: "openai_key") ?? geminiKey }

    static func key(named name: String) -> String? {
        let path = (appSupportDir as NSString).appendingPathComponent(name)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func writeKey(named name: String, _ value: String) {
        try? FileManager.default.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
        let path = (appSupportDir as NSString).appendingPathComponent(name)
        try? value.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
