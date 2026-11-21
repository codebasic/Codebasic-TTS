import Combine
import CryptoKit
import Darwin
import Foundation

enum AgentLimits {
    static let profiles = 32
    static let textBytes = 8192
    static let labelBytes = 96
    static let labelCharacters = 80
    static let proofCount = 32
    static let grantSeconds = 600
    static let acceptedPerMinute = 6
    static let acceptedPerGrant = 20
}

enum AgentBytes {
    static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    static func textValid(_ text: String) -> Bool {
        text.utf8.count <= AgentLimits.textBytes && !text.utf8.contains(0)
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func label(_ input: String) -> String? {
        let label = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= AgentLimits.labelCharacters,
              label.utf8.count <= AgentLimits.labelBytes,
              label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return label
    }

    /// Do not rely on a provider interpreting its JSON "text" field literally.
    /// A spoken script containing raw delimiters, HTML/XML entities, or
    /// bracketed controls must be edited; the display text remains unchanged.
    static func safeForSpeech(_ value: String) -> Bool {
        let inspected = value.precomposedStringWithCompatibilityMapping
        guard !inspected.utf8.contains(where: { [0, 60, 62, 91, 93].contains($0) }) else { return false }
        // Reject names/numbers and nested ampersand references without decoding.
        // Percent/Unicode escape spellings of the same control delimiters are
        // also blocked to avoid relying on a backend's normalization behavior.
        let markup = #"&(?:#[xX]?[0-9a-fA-F]+;?|(?:lt|gt|amp|lbrack|rbrack)(?:;|\b)|[a-z]+;)|%(?:25)*(?:3c|3e|5b|5d)|\\[uU](?:00|000000)(?:3c|3e|5b|5d)"#
        return inspected.range(of: markup, options: [.regularExpression, .caseInsensitive]) == nil
    }
}

struct AgentCatalogRecord: Codable, Identifiable {
    let id: UUID
    let generation: UUID
    let label: String
    let body: String
    let editRecord: UUID?
    var editVersion: UUID { editRecord ?? generation }
    var selector: String { id.uuidString.lowercased() }
}

struct AgentInstructionSnapshot: Equatable, Sendable {
    let selector: String
    let generation: UUID
    let text: String
    var digest: String { AgentBytes.hash(Data(text.utf8)) }
    var shareable: Bool { AgentBytes.textValid(text) }
    static func == (a: Self, b: Self) -> Bool {
        a.selector == b.selector && a.generation == b.generation && AgentBytes.same(a.text, b.text)
    }
}

/// Separate from settings.json so older app builds cannot erase saved profiles.
@MainActor final class AgentCatalog: ObservableObject {
    struct File: Codable { let version: Int; let records: [AgentCatalogRecord] }
    enum Failure: LocalizedError {
        case unreadable, invalid, duplicate, full, conflict
        var errorDescription: String? {
            switch self {
            case .unreadable: return "저장된 지시 목록을 읽지 못했습니다. 원본은 덮어쓰지 않습니다."
            case .invalid: return "이름과 지시 내용을 확인하세요. 지시 한도는 UTF-8 8KB입니다."
            case .duplicate: return "같은 이름의 지시가 이미 있습니다."
            case .full: return "저장할 수 있는 지시 수가 한도에 도달했습니다."
            case .conflict: return "다른 편집에서 지시가 바뀌었습니다. 다시 열어 확인하세요."
            }
        }
    }

    @Published private(set) var records: [AgentCatalogRecord] = []
    private(set) var readError = false
    private let url: URL
    private let write: (Data, URL) throws -> Void
    /// Only called after durable commit. On deletion, the selector no longer
    /// resolves; random IDs are never reused (the live proof is tombstoned).
    var didChange: ((String, Bool) -> Void)?

    init(url: URL, write: @escaping (Data, URL) throws -> Void = AgentCatalog.writeAtomically) {
        self.url = url
        self.write = write
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            let bound = 4 * 1024 * 1024
            guard let bytes = try reader.read(upToCount: bound + 1), bytes.count <= bound else {
                throw Failure.unreadable
            }
            let loaded = try JSONDecoder().decode(File.self, from: bytes)
            guard loaded.version == 1, Set(loaded.records.map(\.id)).count == loaded.records.count else {
                throw Failure.unreadable
            }
            records = loaded.records // Never truncate or silently rewrite imported oversized data.
        } catch { readError = true }
    }

    func record(_ selector: String) -> AgentCatalogRecord? {
        records.first { $0.selector == selector }
    }

    @discardableResult
    func save(id: UUID? = nil, expected: UUID? = nil, label: String, body: String) throws -> AgentCatalogRecord {
        guard !readError else { throw Failure.unreadable }
        guard let label = AgentBytes.label(label) else { throw Failure.invalid }
        let index = id.flatMap { id in records.firstIndex { $0.id == id } }
        let previous = index.map { records[$0] }
        if id != nil, previous?.editVersion != expected || previous == nil { throw Failure.conflict }
        if id == nil, records.count >= AgentLimits.profiles { throw Failure.full }
        guard AgentBytes.textValid(body) || previous.map({ AgentBytes.same($0.body, body) }) == true else {
            throw Failure.invalid
        }
        guard !records.contains(where: { $0.id != id && $0.label.caseInsensitiveCompare(label) == .orderedSame }) else {
            throw Failure.duplicate
        }
        if let previous, AgentBytes.same(previous.label, label), AgentBytes.same(previous.body, body) { return previous }
        // Rename doesn't alter wire text/identity or silently retarget a grant.
        let bodyChanged = previous.map { !AgentBytes.same($0.body, body) } ?? true
        let record = AgentCatalogRecord(id: id ?? UUID(), generation: bodyChanged ? UUID() : previous!.generation,
                                        label: label, body: body, editRecord: UUID())
        var next = records
        if let index { next[index] = record } else { next.append(record) }
        try replace(next) {
            if bodyChanged { didChange?(record.selector, false) }
        }
        return record
    }

    func delete(_ id: UUID, expected: UUID) throws {
        guard !readError else { throw Failure.unreadable }
        guard let old = records.first(where: { $0.id == id }), old.editVersion == expected else { throw Failure.conflict }
        try replace(records.filter { $0.id != id }) { didChange?(old.selector, true) }
    }

    nonisolated static func writeAtomically(_ bytes: Data, _ destination: URL) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".agent-catalog-" + UUID().uuidString)
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = unlink(temp.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temp.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func replace(_ next: [AgentCatalogRecord], didWrite: () -> Void) throws {
        try write(JSONEncoder().encode(File(version: 1, records: next)), url)
        // Update grants before publishing the committed value to observers.
        didWrite()
        records = next
    }
}
