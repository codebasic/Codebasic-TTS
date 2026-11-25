import Foundation

/// Text-only completed explanation events, independent of audio and disposable cache.
struct ExplanationJournal {
    enum Kind: String, Codable { case full, continuation }
    enum Origin: String, Codable { case generated, cache }
    struct Entry: Codable {
        let version: Int
        let id: UUID
        let createdAt: Date
        let kind: Kind
        let origin: Origin
        let text: String
    }
    let directory: URL
    @discardableResult func record(_ text: String, kind: Kind, origin: Origin,
                                   now: Date = Date()) throws -> URL? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            let a = try fm.attributesOfItem(atPath: directory.path)
            guard a[.type] as? FileAttributeType == .typeDirectory,
                  (a[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        }
        let entry = Entry(version: 1, id: UUID(), createdAt: now, kind: kind, origin: origin, text: text)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var value = encoder.singleValueContainer()
            try value.encode(formatter.string(from: date))
        }
        let data = try encoder.encode(entry)
        let file = directory.appendingPathComponent(entry.id.uuidString + ".json")
        // Unique immutable events: temporary file has restrictive mode before bytes are written.
        let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try fm.moveItem(at: temporary, to: file)
        return file
    }
}
