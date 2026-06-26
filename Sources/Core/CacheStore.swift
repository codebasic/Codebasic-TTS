import Foundation
import CryptoKit

/// One cached/generated clip.
struct HistoryEntry: Codable, Identifiable, Hashable {
    let id: String            // cache key
    let text: String
    let backend: String       // "elevenlabs" / "qwen3-..."
    let voiceId: String
    let voiceName: String
    let modelId: String
    let createdAt: Date
    let audioFile: String     // filename within the cache dir
    let bytes: Int
}

/// History + audio cache. Generated audio (text+voice+model) is stored so the
/// same request replays from disk instead of re-calling the API (the caching the
/// project wanted, now cost-saving for the cloud backend). Index is JSON; audio
/// files sit beside it.
final class CacheStore {
    static let dir: URL = {
        let base = (Secrets.appSupportDir as NSString).appendingPathComponent("cache")
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return URL(fileURLWithPath: base)
    }()
    private var indexURL: URL { Self.dir.appendingPathComponent("index.json") }

    private(set) var entries: [HistoryEntry] = []

    init() { load() }

    static func key(text: String, backend: String, voiceId: String,
                    modelId: String, settingsHash: String) -> String {
        let raw = [text, backend, voiceId, modelId, settingsHash].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func entry(forKey key: String) -> HistoryEntry? {
        entries.first { $0.id == key }
    }

    func audioURL(_ e: HistoryEntry) -> URL { Self.dir.appendingPathComponent(e.audioFile) }

    func data(forKey key: String) -> Data? {
        guard let e = entry(forKey: key) else { return nil }
        return try? Data(contentsOf: audioURL(e))
    }

    /// File URL for a cached key, only if the audio file actually exists.
    func fileURL(forKey key: String) -> URL? {
        guard let e = entry(forKey: key) else { return nil }
        let url = audioURL(e)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func save(key: String, text: String, backend: String, voiceId: String,
              voiceName: String, modelId: String, ext: String, data: Data) -> HistoryEntry {
        let file = "\(key).\(ext)"
        try? data.write(to: Self.dir.appendingPathComponent(file))
        let e = HistoryEntry(id: key, text: text, backend: backend, voiceId: voiceId,
                             voiceName: voiceName, modelId: modelId, createdAt: Date(),
                             audioFile: file, bytes: data.count)
        entries.removeAll { $0.id == key }        // move-to-front on re-generate
        entries.insert(e, at: 0)
        persist()
        return e
    }

    /// Bump an existing entry to the top (on cache-hit replay).
    func touch(_ key: String) {
        guard let i = entries.firstIndex(where: { $0.id == key }), i != 0 else { return }
        let e = entries.remove(at: i)
        entries.insert(e, at: 0)
        persist()
    }

    func delete(_ id: String) {
        if let e = entry(forKey: id) { try? FileManager.default.removeItem(at: audioURL(e)) }
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        for e in entries { try? FileManager.default.removeItem(at: audioURL(e)) }
        entries.removeAll()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decoded([HistoryEntry].self, from: data) else { return }
        entries = list
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(entries) { try? data.write(to: indexURL) }
    }
}

private extension JSONDecoder {
    func decoded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        dateDecodingStrategy = .iso8601
        return try decode(type, from: data)
    }
}
