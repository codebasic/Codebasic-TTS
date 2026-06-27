import Foundation

/// One flagged generation case, captured with its full stage context so prompt
/// failures can be analyzed (and the prompts fixed) later. Separate from the
/// audio history (HistoryEntry), which only stores cached clips.
struct BacklogEntry: Codable, Identifiable, Hashable {
    let id: String
    let createdAt: Date
    var tags: [String]        // editable; default ["이슈"]
    var note: String          // user note about the problem
    let stage: String         // "해설" / "대본"
    let provider: String
    let model: String
    let prompt: String        // base instruction used (explainPrompt / normalizePrompt)
    let hint: String          // per-run 추가 지시
    let input: String         // code (해설) or source prose (대본)
    let output: String        // generated 해설 / 대본
}

/// Persists flagged cases to backlog.json in Application Support.
final class BacklogStore {
    private let url: URL
    private(set) var entries: [BacklogEntry] = []

    init() {
        let dir = Secrets.appSupportDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("backlog.json"))
        load()
    }

    func add(_ e: BacklogEntry) { entries.insert(e, at: 0); persist() }
    func update(_ e: BacklogEntry) {
        if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i] = e; persist() }
    }
    func delete(_ id: String) { entries.removeAll { $0.id == id }; persist() }
    func clear() { entries.removeAll(); persist() }

    /// Distinct tags across all entries, for the filter picker.
    var allTags: [String] {
        var seen = Set<String>(); var out: [String] = []
        for e in entries { for t in e.tags where !seen.contains(t) { seen.insert(t); out.append(t) } }
        return out.sorted()
    }

    /// Write a pretty-printed JSON export and return its URL (for Finder reveal).
    func export() -> URL? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(entries) else { return nil }
        let out = URL(fileURLWithPath:
            (Secrets.appSupportDir as NSString).appendingPathComponent("backlog_export.json"))
        try? data.write(to: out)
        return out
    }

    private func load() {
        guard let d = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        entries = (try? dec.decode([BacklogEntry].self, from: d)) ?? []
    }
    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(entries) { try? d.write(to: url) }
    }
}
