import Foundation

struct AgentInstructionEditBuffer {
    struct Entry {
        let expected: UUID
        let originalLabel: String
        let originalText: String
        var label: String
        var text: String

        var isDirty: Bool { !AgentBytes.same(label, originalLabel) || !AgentBytes.same(text, originalText) }
    }

    private(set) var drafts: [String: Entry] = [:]

    func entry(for selector: String, expected: UUID, label: String, text: String) -> Entry {
        drafts[selector] ?? Entry(expected: expected, originalLabel: label, originalText: text, label: label, text: text)
    }

    mutating func update(_ entry: Entry, for selector: String) {
        drafts[selector] = entry.isDirty ? entry : nil
    }

    mutating func revert(_ selector: String) {
        drafts[selector] = nil
    }
}

struct AgentInstructionChoice: Identifiable {
    let id: String
    let label: String

    static func matching(_ options: [Self], query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? options : options.filter { $0.label.localizedStandardContains(query) }
    }

    /// Enter in the filter is a choice only if it identifies one exact option.
    static func keyboardChoice(_ options: [Self], query: String) -> String? {
        let matches = matching(options, query: query)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, matches.count == 1 else { return nil }
        return matches[0].id
    }
}

enum AgentPresetInstructions {
    private static let selectors: Set<String> = ["explain", "continue", "normalize"]

    static func read(at url: URL) throws -> [String: String] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return [:]
        }
        let saved = try JSONDecoder().decode([String: String].self, from: data)
        guard saved.allSatisfy({ selectors.contains($0.key) && AgentBytes.textValid($0.value) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return saved
    }

    static func write(_ text: String, for selector: String, expectedOverride: String?, at url: URL) throws -> [String: String] {
        guard selectors.contains(selector), AgentBytes.textValid(text) else {
            throw AgentCatalog.Failure.invalid
        }
        var current = try read(at: url)
        let matches = current[selector].map { old in expectedOverride.map { AgentBytes.same($0, old) } == true }
            ?? (expectedOverride == nil)
        guard matches else { throw AgentCatalog.Failure.conflict }
        current[selector] = text
        let payload = try JSONEncoder().encode(current)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: url, options: .atomic)
        // Instruction text is private to this account, like the catalog beside it.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return current
    }
}
