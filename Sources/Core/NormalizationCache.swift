import Foundation
import CryptoKit

/// Maps original text (+ normalization config) → normalized script, so the LLM
/// isn't re-run for text it has already normalized. Stored as a JSON dict.
/// (The TTS audio cache is separate — keyed on the script.)
final class NormalizationCache {
    private var map: [String: String] = [:]
    private let url: URL

    init() {
        let dir = Secrets.appSupportDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("norm_cache.json"))
        load()
    }

    static func key(text: String, provider: String, model: String, prompt: String) -> String {
        let raw = [text, provider, model, prompt].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func script(forKey key: String) -> String? { map[key] }
    func put(key: String, script: String) { map[key] = script; persist() }
    func clear() { map.removeAll(); persist() }
    var count: Int { map.count }

    private func load() {
        guard let d = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return }
        map = m
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(map) { try? d.write(to: url) }
    }
}
