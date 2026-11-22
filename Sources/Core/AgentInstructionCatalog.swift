import Combine
import CryptoKit
import Darwin
import Foundation

struct AgentInstructionEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var label: String
    var body: String
    let origin: String
    let createdAt: Date
    var updatedAt: Date

    var revision: String {
        Self.computeRevision(id: id, label: label, body: body)
    }

    static func computeRevision(id: String, label: String, body: String) -> String {
        let material = "tts-agent-entry-v1\0\(id)\0\(label)\0\(body)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct AgentInstructionTombstone: Codable, Equatable, Sendable {
    let id: String
    let deletedAt: Date
    let lastRevision: String
}

struct AgentInstructionCatalogSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var entries: [AgentInstructionEntry]
    var tombstones: [AgentInstructionTombstone]

    init(schemaVersion: Int = 1, entries: [AgentInstructionEntry] = [], tombstones: [AgentInstructionTombstone] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.tombstones = tombstones
    }
}

enum AgentCatalogError: LocalizedError, Equatable {
    case invalidLabel
    case invalidBody
    case maxProfilesReached
    case notFound
    case tombstonedID
    case corruptStore(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidLabel:
            return "지시 이름은 비워 둘 수 없으며 제어 문자 없이 최대 80자(UTF-8 96바이트)여야 합니다."
        case .invalidBody:
            return "지시 본문은 비워 둘 수 없으며 널 문자 없이 UTF-8 8,192바이트 이하여야 합니다."
        case .maxProfilesReached:
            return "로컬 지시 프로필은 최대 32개까지만 저장할 수 있습니다."
        case .notFound:
            return "해당 로컬 지시 프로필을 찾을 수 없습니다."
        case .tombstonedID:
            return "삭제된 로컬 지시 ID는 다시 사용할 수 없습니다."
        case .corruptStore(let detail):
            return "로컬 지시 카탈로그 파일을 읽을 수 없어 보호 중입니다: \(detail)"
        case .writeFailed(let detail):
            return "로컬 지시 카탈로그 저장에 실패했습니다: \(detail)"
        }
    }
}

/// Separate atomic store for reusable local Agent instructions (`agent_instruction_catalog.json`).
/// Built-in profiles (`explain`, `continue`, `normalize`) never live here and keep their exact bytes.
@MainActor
final class AgentInstructionCatalogStore: ObservableObject {
    nonisolated static let maxProfiles = 32
    nonisolated static let maxLabelUTF8Bytes = 96
    nonisolated static let maxLabelCharacters = 80
    nonisolated static let maxBodyUTF8Bytes = 8 * 1024
    nonisolated static let fileName = "agent_instruction_catalog.json"

    @Published private(set) var entries: [AgentInstructionEntry] = []
    @Published private(set) var tombstones: [AgentInstructionTombstone] = []
    @Published private(set) var loadError: String? = nil

    let fileURL: URL
    private let clock: () -> Date

    init(directory: String, clock: @escaping () -> Date = Date.init) {
        self.fileURL = URL(fileURLWithPath: directory).appendingPathComponent(Self.fileName)
        self.clock = clock
        load()
    }

    nonisolated static func validateLabel(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maxLabelCharacters,
              trimmed.utf8.count <= maxLabelUTF8Bytes else { return nil }
        let hasForbiddenControl = trimmed.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
        return hasForbiddenControl ? nil : trimmed
    }

    nonisolated static func validateBody(_ raw: String) -> String? {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !raw.utf8.contains(0),
              raw.utf8.count <= maxBodyUTF8Bytes else { return nil }
        return raw
    }

    nonisolated static func isValidLocalID(_ id: String) -> Bool {
        guard id.hasPrefix("local-"), (7...80).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95
        }
    }

    func entry(id: String) -> AgentInstructionEntry? {
        entries.first { $0.id == id }
    }

    func isTombstoned(id: String) -> Bool {
        tombstones.contains { $0.id == id }
    }

    func load() {
        loadError = nil
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            entries = []
            tombstones = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(AgentInstructionCatalogSnapshot.self, from: data)
            guard snapshot.schemaVersion == 1 else {
                throw AgentCatalogError.corruptStore("지원하지 않는 스키마 버전(\(snapshot.schemaVersion))")
            }
            guard snapshot.entries.count <= Self.maxProfiles else {
                throw AgentCatalogError.corruptStore("프로필 상한(\(Self.maxProfiles)개) 초과")
            }
            let tombstoneIDs = Set(snapshot.tombstones.map(\.id))
            var seenIDs = Set<String>()
            for item in snapshot.entries {
                guard Self.isValidLocalID(item.id),
                      !seenIDs.contains(item.id),
                      !tombstoneIDs.contains(item.id),
                      item.origin == "local",
                      Self.validateLabel(item.label) == item.label,
                      Self.validateBody(item.body) != nil else {
                    throw AgentCatalogError.corruptStore("잘못된 로컬 프로필 항목(\(item.id))")
                }
                seenIDs.insert(item.id)
            }
            entries = snapshot.entries
            tombstones = snapshot.tombstones
        } catch let error as AgentCatalogError {
            entries = []
            tombstones = []
            loadError = error.localizedDescription
        } catch {
            entries = []
            tombstones = []
            loadError = AgentCatalogError.corruptStore(error.localizedDescription).localizedDescription
        }
    }

    @discardableResult
    func create(label: String, body: String) -> Result<AgentInstructionEntry, AgentCatalogError> {
        if let loadError { return .failure(.corruptStore(loadError)) }
        guard entries.count < Self.maxProfiles else { return .failure(.maxProfilesReached) }
        guard let cleanLabel = Self.validateLabel(label) else { return .failure(.invalidLabel) }
        guard let validBody = Self.validateBody(body) else { return .failure(.invalidBody) }

        let now = clock()
        let entry = AgentInstructionEntry(
            id: "local-" + UUID().uuidString.lowercased(),
            label: cleanLabel,
            body: validBody,
            origin: "local",
            createdAt: now,
            updatedAt: now
        )
        var nextEntries = entries
        nextEntries.append(entry)
        switch persist(entries: nextEntries, tombstones: tombstones) {
        case .success:
            entries = nextEntries
            return .success(entry)
        case .failure(let error):
            return .failure(error)
        }
    }

    @discardableResult
    func update(id: String, label: String, body: String) -> Result<(entry: AgentInstructionEntry, changed: Bool), AgentCatalogError> {
        if let loadError { return .failure(.corruptStore(loadError)) }
        if isTombstoned(id: id) { return .failure(.tombstonedID) }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }
        guard let cleanLabel = Self.validateLabel(label) else { return .failure(.invalidLabel) }
        guard let validBody = Self.validateBody(body) else { return .failure(.invalidBody) }

        var updated = entries[idx]
        let changed = !updated.label.utf8.elementsEqual(cleanLabel.utf8)
            || !updated.body.utf8.elementsEqual(validBody.utf8)
        guard changed else {
            return .success((updated, false))
        }
        updated.label = cleanLabel
        updated.body = validBody
        updated.updatedAt = clock()

        var nextEntries = entries
        nextEntries[idx] = updated
        switch persist(entries: nextEntries, tombstones: tombstones) {
        case .success:
            entries = nextEntries
            return .success((updated, true))
        case .failure(let error):
            return .failure(error)
        }
    }

    @discardableResult
    func delete(id: String) -> Result<AgentInstructionTombstone, AgentCatalogError> {
        if let loadError { return .failure(.corruptStore(loadError)) }
        if isTombstoned(id: id) { return .failure(.tombstonedID) }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }

        let removed = entries[idx]
        let tombstone = AgentInstructionTombstone(
            id: removed.id,
            deletedAt: clock(),
            lastRevision: removed.revision
        )
        var nextEntries = entries
        nextEntries.remove(at: idx)
        var nextTombstones = tombstones
        nextTombstones.append(tombstone)
        switch persist(entries: nextEntries, tombstones: nextTombstones) {
        case .success:
            entries = nextEntries
            tombstones = nextTombstones
            return .success(tombstone)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func persist(entries: [AgentInstructionEntry], tombstones: [AgentInstructionTombstone]) -> Result<Void, AgentCatalogError> {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let snapshot = AgentInstructionCatalogSnapshot(schemaVersion: 1, entries: entries, tombstones: tombstones)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
            _ = chmod(fileURL.path, 0o600)
            return .success(())
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }
}
