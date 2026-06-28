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
    var images: [Data]?       // attached screenshots (해설), PNG; optional for back-compat
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

    /// Flat record for export: image bytes are written as separate PNG files and
    /// referenced by filename here (so the JSON stays readable and the screenshots
    /// are openable for analysis, instead of base64 blobs).
    private struct ExportEntry: Codable {
        let id: String
        let createdAt: Date
        let tags: [String]
        let note, stage, provider, model, prompt, hint, input, output: String
        let imageFiles: [String]?
    }

    /// Export the given entries to a timestamped folder in ~/Downloads: a readable
    /// JSON plus the attached screenshots as PNG files. Returns the folder URL.
    func export(_ items: [BacklogEntry]) -> URL? {
        guard !items.isEmpty else { return nil }
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: Date())
        let name = items.count == 1 ? "backlog_\(items[0].stage)_\(stamp)" : "backlog_export_\(stamp)"
        let dir = downloads.appendingPathComponent(name, isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }

        var exported: [ExportEntry] = []
        for e in items {
            var files: [String]?
            if let imgs = e.images, !imgs.isEmpty {
                var names: [String] = []
                for (i, data) in imgs.enumerated() {
                    let name = "\(e.id)_\(i + 1).png"
                    try? data.write(to: dir.appendingPathComponent(name))
                    names.append(name)
                }
                files = names
            }
            exported.append(ExportEntry(id: e.id, createdAt: e.createdAt, tags: e.tags, note: e.note,
                                        stage: e.stage, provider: e.provider, model: e.model,
                                        prompt: e.prompt, hint: e.hint, input: e.input, output: e.output,
                                        imageFiles: files))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(exported) {
            try? data.write(to: dir.appendingPathComponent("backlog_export.json"))
        }
        return dir
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
