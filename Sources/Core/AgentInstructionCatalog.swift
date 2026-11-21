import Combine
import CryptoKit
import Foundation

// Design decision record
// - The catalog never reads app settings. Legacy prompts are supplied once by the caller
//   (app state) as AgentLegacyPromptSeed values; the exact supplied bytes are recorded in
//   the store (legacySeedRecord) and are adopted at most once.
// - A share snapshot carries only the stable profile ID, a unique revision, the exact raw
//   UTF-8 body bytes and their SHA-256. Labels, voice files and preferences never leave.
// - Grants are not stored here and are never migrated; see AgentSessionAuthorization.
// - Every body change mints a new unique revision, so edit/revert can never match a
//   previously granted share again. Label-only edits keep the revision.

enum AgentInstructionLimits {
    static let maxLabelUTF8Bytes = 96
    static let maxLabelCharacters = 80
    static let maxBodyUTF8Bytes = 8192
    static let maxCustomProfiles = 32
    /// Imported text is kept untruncated up to this size; larger imports are rejected whole.
    static let maxImportedBodyUTF8Bytes = 256 * 1024
    static let maxEditorDrafts = 64
}

/// Unique and monotonic: `sequence` orders revisions, `nonce` makes each one unique.
struct AgentInstructionRevision: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    let sequence: UInt64
    let nonce: UUID

    init(sequence: UInt64, nonce: UUID) {
        self.sequence = sequence
        self.nonce = nonce
    }

    init?(wireString: String) {
        guard let dash = wireString.firstIndex(of: "-") else { return nil }
        let head = wireString[..<dash]
        guard !head.isEmpty, head.utf8.allSatisfy({ (48...57).contains($0) }),
              let sequence = UInt64(head),
              let nonce = UUID(uuidString: String(wireString[wireString.index(after: dash)...])) else { return nil }
        self.sequence = sequence
        self.nonce = nonce
    }

    var wireString: String { String(sequence) + "-" + nonce.uuidString }
    var description: String { wireString }

    static func < (lhs: AgentInstructionRevision, rhs: AgentInstructionRevision) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.nonce.uuidString < rhs.nonce.uuidString
    }
}

enum AgentInstructionCatalogError: Error, Equatable {
    case labelBlank, labelTooLong, labelContainsNUL
    case bodyBlank, bodyTooLarge, bodyContainsNUL
    case catalogFull, notFound, builtInImmutable
    case storeUnreadable
    case saveFailed(String)
}

/// Why a profile cannot be transmitted. The text itself stays visible and copyable.
enum AgentInstructionShareBlock: String, Error, Equatable, Sendable {
    case notFound, blank, containsNUL, oversize
}

enum AgentInstructionValidator {
    static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func labelError(_ label: String) -> AgentInstructionCatalogError? {
        if label.utf8.contains(0) { return .labelContainsNUL }
        if isBlank(label) { return .labelBlank }
        if label.utf8.count > AgentInstructionLimits.maxLabelUTF8Bytes
            || label.count > AgentInstructionLimits.maxLabelCharacters { return .labelTooLong }
        return nil
    }

    static func bodyError(_ body: String) -> AgentInstructionCatalogError? {
        if body.utf8.contains(0) { return .bodyContainsNUL }
        if isBlank(body) { return .bodyBlank }
        if body.utf8.count > AgentInstructionLimits.maxBodyUTF8Bytes { return .bodyTooLarge }
        return nil
    }

    static func shareBlock(forBody body: String) -> AgentInstructionShareBlock? {
        if body.utf8.contains(0) { return .containsNUL }
        if isBlank(body) { return .blank }
        if body.utf8.count > AgentInstructionLimits.maxBodyUTF8Bytes { return .oversize }
        return nil
    }
}

struct AgentInstructionProfile: Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case builtIn, custom, legacySeed, imported }

    let id: UUID
    let label: String
    /// Exact text. Never cleaned, normalized or truncated.
    let body: String
    let kind: Kind
    let revision: AgentInstructionRevision

    var isBuiltIn: Bool { kind == .builtIn }
    var bodyUTF8: Data { Data(body.utf8) }
    var shareBlock: AgentInstructionShareBlock? { AgentInstructionValidator.shareBlock(forBody: body) }
    var canTransmit: Bool { shareBlock == nil }

    /// Byte-exact comparison (not Unicode canonical equivalence).
    static func == (lhs: AgentInstructionProfile, rhs: AgentInstructionProfile) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.revision == rhs.revision
            && lhs.label.utf8.elementsEqual(rhs.label.utf8) && lhs.body.utf8.elementsEqual(rhs.body.utf8)
    }
}

/// Frozen, immutable share payload. The label is intentionally absent.
struct AgentInstructionShareSnapshot: Equatable, Sendable {
    let profileID: UUID
    let revision: AgentInstructionRevision
    /// The exact raw bytes that are transmitted.
    let bodyUTF8: Data
    /// SHA-256 of `bodyUTF8`.
    let sha256: Data

    init?(profileID: UUID, revision: AgentInstructionRevision, body: String) {
        guard AgentInstructionValidator.shareBlock(forBody: body) == nil else { return nil }
        let bytes = Data(body.utf8)
        self.profileID = profileID
        self.revision = revision
        self.bodyUTF8 = bytes
        self.sha256 = Data(SHA256.hash(data: bytes))
    }

    /// Exact preview/copy text of what would be transmitted.
    var text: String { String(decoding: bodyUTF8, as: UTF8.self) }
    var sha256Hex: String { sha256.map { String(format: "%02x", $0) }.joined() }
}

struct AgentInstructionBuiltIn: Sendable {
    let id: UUID
    let label: String
    let body: String
    /// Bump when the preset text changes. The nonce is derived from the body hash, so an
    /// updated preset under the same ID is distinguishable even if the bump is forgotten.
    let sequence: UInt64

    var revision: AgentInstructionRevision {
        AgentInstructionRevision(sequence: sequence, nonce: Self.nonce(forBody: body))
    }

    var profile: AgentInstructionProfile {
        AgentInstructionProfile(id: id, label: label, body: body, kind: .builtIn, revision: revision)
    }

    static func nonce(forBody body: String) -> UUID {
        let d = Array(SHA256.hash(data: Data(body.utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                           d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    static let standard: [AgentInstructionBuiltIn] = [
        AgentInstructionBuiltIn(
            id: UUID(uuidString: "6F0C2B5E-3A41-4D7B-9C1E-0A5D8E2F7B10")!,
            label: "Spoken code explanation",
            body: "Explain the selected code or text for a listener, not a reader. Use short plain sentences. Do not read symbols literally; describe what they do. Provide a display text and, when pronunciation differs, a separate speech text written exactly as it should be spoken. Do not include markup of any kind.",
            sequence: 1),
        AgentInstructionBuiltIn(
            id: UUID(uuidString: "6F0C2B5E-3A41-4D7B-9C1E-0A5D8E2F7B11")!,
            label: "한국어 낭독 대본",
            body: "선택한 내용을 한국어로 듣기 좋게 설명해 주세요. 화면용 문장과 낭독용 문장을 따로 작성하고, 식별자와 기호는 낭독용 문장에서 소리 나는 대로 풀어 써 주세요. 예: as_frame 은 애즈 프레임. 마크업이나 태그는 넣지 마세요.",
            sequence: 1),
        AgentInstructionBuiltIn(
            id: UUID(uuidString: "6F0C2B5E-3A41-4D7B-9C1E-0A5D8E2F7B12")!,
            label: "Brief summary",
            body: "Summarize the selection in at most three short sentences suitable for text to speech. Avoid lists, symbols, and markup.",
            sequence: 1)
    ]
}

/// A legacy prompt handed over by app state. The catalog does not read settings itself.
struct AgentLegacyPromptSeed: Sendable {
    let key: String
    let suggestedLabel: String
    let body: String

    init(key: String, suggestedLabel: String, body: String) {
        self.key = key
        self.suggestedLabel = suggestedLabel
        self.body = body
    }
}

/// Exact record of what the app state supplied as the legacy seed.
struct AgentLegacySeedRecord: Codable, Equatable, Sendable {
    let key: String
    let bodyUTF8: Data
    let adoptedProfileID: UUID?
}

struct AgentInstructionEditorDraft: Equatable, Sendable {
    var label: String
    var body: String

    init(label: String, body: String) {
        self.label = label
        self.body = body
    }
}

enum AgentInstructionCatalogChange: Equatable, Sendable {
    case added(profileID: UUID)
    case labelChanged(profileID: UUID)
    case bodyChanged(profileID: UUID, previous: AgentInstructionRevision, current: AgentInstructionRevision)
    case deleted(profileID: UUID, lastRevision: AgentInstructionRevision)
}

protocol AgentInstructionCatalogStorage {
    /// Returns nil when nothing has been saved yet.
    func load() throws -> Data?
    /// Must replace the saved state atomically.
    func save(_ data: Data) throws
    /// Moves unreadable saved state aside without destroying it.
    func quarantine() throws -> URL?
}

struct AgentInstructionCatalogFileStorage: AgentInstructionCatalogStorage {
    let url: URL

    init(url: URL) { self.url = url }

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true, attributes: nil)
        try data.write(to: url, options: .atomic)
    }

    func quarantine() throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let name = url.lastPathComponent + ".unreadable-" + UUID().uuidString
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

fileprivate struct AgentInstructionPersistedProfile: Codable {
    var id: UUID
    var label: String
    var bodyUTF8: Data
    var kind: AgentInstructionProfile.Kind
    var revision: AgentInstructionRevision
}

fileprivate struct AgentInstructionPersistedStore: Codable {
    static let currentVersion = 1
    var formatVersion: Int
    var nextRevisionSequence: UInt64
    var legacySeedApplied: Bool
    var legacySeedRecord: [AgentLegacySeedRecord]
    var customProfiles: [AgentInstructionPersistedProfile]
}

fileprivate struct AgentInstructionStoreFormatError: Error, CustomStringConvertible {
    let description: String
}

/// Built-in presets plus up to 32 custom profiles, persisted independently of app settings.
@MainActor
final class AgentInstructionCatalog: ObservableObject {
    enum PersistenceState: Equatable {
        case clean
        /// The last save failed. Memory holds the last good state.
        case saveFailed(String)
        /// Saved state exists but could not be read. It is never overwritten implicitly.
        case storeUnreadable(String)
    }

    @Published private(set) var builtInProfiles: [AgentInstructionProfile] = []
    @Published private(set) var customProfiles: [AgentInstructionProfile] = []
    @Published private(set) var persistenceState: PersistenceState = .clean
    /// Unsaved editor drafts keyed by profile ID (or a caller-chosen key for new profiles).
    @Published private(set) var editorDrafts: [UUID: AgentInstructionEditorDraft] = [:]
    /// UI selection only. Selecting a profile never grants or shares anything.
    @Published var selectedProfileID: UUID?

    /// Emits after each successfully persisted change. Wire `.bodyChanged`/`.deleted`
    /// to AgentSessionAuthorization.instructionBodyChanged/profileDeleted.
    let changes = PassthroughSubject<AgentInstructionCatalogChange, Never>()

    private(set) var legacySeedRecord: [AgentLegacySeedRecord] = []
    private(set) var legacySeedApplied = false
    private var nextSequence: UInt64 = 1
    private let storage: AgentInstructionCatalogStorage

    static func storeURL(inApplicationSupportDirectory directory: URL) -> URL {
        directory.appendingPathComponent("AgentInstructionCatalog.json")
    }

    convenience init(storeURL: URL,
                     builtIns: [AgentInstructionBuiltIn] = AgentInstructionBuiltIn.standard,
                     legacySeed: [AgentLegacyPromptSeed] = []) {
        self.init(storage: AgentInstructionCatalogFileStorage(url: storeURL), builtIns: builtIns, legacySeed: legacySeed)
    }

    init(storage: AgentInstructionCatalogStorage,
         builtIns: [AgentInstructionBuiltIn] = AgentInstructionBuiltIn.standard,
         legacySeed: [AgentLegacyPromptSeed] = []) {
        self.storage = storage
        builtInProfiles = builtIns.map { $0.profile }
        let builtInIDs = Set(builtIns.map { $0.id })
        do {
            if let data = try storage.load() {
                let loaded = try Self.decode(data, builtInIDs: builtInIDs)
                customProfiles = loaded.customs
                legacySeedApplied = loaded.store.legacySeedApplied
                legacySeedRecord = loaded.store.legacySeedRecord
                let highest = loaded.customs.map { $0.revision.sequence }.max() ?? 0
                nextSequence = Swift.max(1, loaded.store.nextRevisionSequence, highest &+ 1)
            }
        } catch {
            persistenceState = .storeUnreadable(String(describing: error))
        }
        if !legacySeedApplied && !legacySeed.isEmpty {
            applyLegacySeed(legacySeed)
        }
    }

    // MARK: Reading

    var profiles: [AgentInstructionProfile] { builtInProfiles + customProfiles }
    var canAddCustomProfile: Bool { customProfiles.count < AgentInstructionLimits.maxCustomProfiles }

    func profile(id: UUID) -> AgentInstructionProfile? {
        profiles.first { $0.id == id }
    }

    /// Exact text for preview/copy, including text that is too large to transmit.
    func exactText(for id: UUID) -> String? { profile(id: id)?.body }

    func search(_ query: String) -> [AgentInstructionProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return profiles }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return profiles.filter {
            $0.label.range(of: needle, options: options) != nil || $0.body.range(of: needle, options: options) != nil
        }
    }

    /// Frozen snapshot of exactly what would be transmitted. Creating one grants nothing.
    func shareSnapshot(for id: UUID) -> Result<AgentInstructionShareSnapshot, AgentInstructionShareBlock> {
        guard let found = profile(id: id) else { return .failure(.notFound) }
        if let block = found.shareBlock { return .failure(block) }
        guard let snapshot = AgentInstructionShareSnapshot(profileID: found.id, revision: found.revision, body: found.body) else {
            return .failure(.blank)
        }
        return .success(snapshot)
    }

    // MARK: CRUD

    @discardableResult
    func addProfile(label: String, body: String) -> Result<AgentInstructionProfile, AgentInstructionCatalogError> {
        if let error = AgentInstructionValidator.labelError(label) { return .failure(error) }
        if let error = AgentInstructionValidator.bodyError(body) { return .failure(error) }
        return insert(label: label, body: body, kind: .custom)
    }

    /// Imported text may exceed the transmit limit. It is stored untruncated and stays
    /// visible/copyable, but `shareSnapshot` refuses it.
    @discardableResult
    func importProfile(label: String, body: String) -> Result<AgentInstructionProfile, AgentInstructionCatalogError> {
        if let error = AgentInstructionValidator.labelError(label) { return .failure(error) }
        if AgentInstructionValidator.isBlank(body) { return .failure(.bodyBlank) }
        if body.utf8.count > AgentInstructionLimits.maxImportedBodyUTF8Bytes { return .failure(.bodyTooLarge) }
        return insert(label: label, body: body, kind: .imported)
    }

    @discardableResult
    func duplicateProfile(id: UUID) -> Result<AgentInstructionProfile, AgentInstructionCatalogError> {
        guard let source = profile(id: id) else { return .failure(.notFound) }
        let suffix = " copy"
        var base = source.label
        while !base.isEmpty, AgentInstructionValidator.labelError(base + suffix) == .labelTooLong {
            base.removeLast()
        }
        let kind: AgentInstructionProfile.Kind = AgentInstructionValidator.bodyError(source.body) == nil ? .custom : .imported
        return insert(label: base + suffix, body: source.body, kind: kind)
    }

    /// A body change (including a revert to earlier text) always mints a new revision.
    /// A label-only change keeps the revision.
    @discardableResult
    func updateProfile(id: UUID, label: String? = nil, body: String? = nil) -> Result<AgentInstructionProfile, AgentInstructionCatalogError> {
        if builtInProfiles.contains(where: { $0.id == id }) { return .failure(.builtInImmutable) }
        guard let index = customProfiles.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }
        let old = customProfiles[index]
        let newLabel = label ?? old.label
        let newBody = body ?? old.body
        let labelChanged = !newLabel.utf8.elementsEqual(old.label.utf8)
        let bodyChanged = !newBody.utf8.elementsEqual(old.body.utf8)
        if !labelChanged && !bodyChanged { return .success(old) }
        if labelChanged, let error = AgentInstructionValidator.labelError(newLabel) { return .failure(error) }
        if bodyChanged, let error = AgentInstructionValidator.bodyError(newBody) { return .failure(error) }
        let revision = bodyChanged ? makeRevision() : old.revision
        let kind: AgentInstructionProfile.Kind = bodyChanged ? .custom : old.kind
        let updated = AgentInstructionProfile(id: old.id, label: newLabel, body: newBody, kind: kind, revision: revision)
        var customs = customProfiles
        customs[index] = updated
        if let error = write(customs: customs) { return .failure(error) }
        customProfiles = customs
        if bodyChanged { changes.send(.bodyChanged(profileID: id, previous: old.revision, current: revision)) }
        if labelChanged { changes.send(.labelChanged(profileID: id)) }
        return .success(updated)
    }

    @discardableResult
    func deleteProfile(id: UUID) -> AgentInstructionCatalogError? {
        if builtInProfiles.contains(where: { $0.id == id }) { return .builtInImmutable }
        guard let index = customProfiles.firstIndex(where: { $0.id == id }) else { return .notFound }
        var customs = customProfiles
        let removed = customs.remove(at: index)
        if let error = write(customs: customs) { return error }
        customProfiles = customs
        editorDrafts.removeValue(forKey: id)
        if selectedProfileID == id { selectedProfileID = nil }
        changes.send(.deleted(profileID: id, lastRevision: removed.revision))
        return nil
    }

    // MARK: Editor drafts

    @discardableResult
    func setEditorDraft(_ draft: AgentInstructionEditorDraft, for key: UUID) -> Bool {
        if editorDrafts[key] == nil && editorDrafts.count >= AgentInstructionLimits.maxEditorDrafts { return false }
        editorDrafts[key] = draft
        return true
    }

    func discardEditorDraft(for key: UUID) {
        editorDrafts.removeValue(forKey: key)
    }

    /// Saves one draft. On any failure every draft, including this one, is kept.
    @discardableResult
    func commitEditorDraft(for key: UUID) -> Result<AgentInstructionProfile, AgentInstructionCatalogError> {
        guard let draft = editorDrafts[key] else { return .failure(.notFound) }
        let result: Result<AgentInstructionProfile, AgentInstructionCatalogError>
        if profile(id: key) != nil {
            result = updateProfile(id: key, label: draft.label, body: draft.body)
        } else {
            result = addProfile(label: draft.label, body: draft.body)
        }
        if case .success = result { editorDrafts.removeValue(forKey: key) }
        return result
    }

    // MARK: Persistence recovery

    @discardableResult
    func retrySave() -> AgentInstructionCatalogError? {
        write(customs: customProfiles)
    }

    /// Explicit user action: moves the unreadable store aside (kept on disk) and starts
    /// persisting the current in-memory state.
    @discardableResult
    func quarantineUnreadableStoreAndStartFresh() -> AgentInstructionCatalogError? {
        guard case .storeUnreadable(let reason) = persistenceState else { return nil }
        do {
            _ = try storage.quarantine()
        } catch {
            return .saveFailed(String(describing: error))
        }
        persistenceState = .saveFailed(reason)
        return write(customs: customProfiles)
    }

    // MARK: Private

    private func makeRevision() -> AgentInstructionRevision {
        let revision = AgentInstructionRevision(sequence: nextSequence, nonce: UUID())
        nextSequence = nextSequence &+ 1
        return revision
    }

    private func insert(label: String, body: String, kind: AgentInstructionProfile.Kind) -> Result<AgentInstructionProfile, AgentInstructionCatalogError> {
        guard customProfiles.count < AgentInstructionLimits.maxCustomProfiles else { return .failure(.catalogFull) }
        let created = AgentInstructionProfile(id: UUID(), label: label, body: body, kind: kind, revision: makeRevision())
        if let error = write(customs: customProfiles + [created]) { return .failure(error) }
        customProfiles.append(created)
        changes.send(.added(profileID: created.id))
        return .success(created)
    }

    private func applyLegacySeed(_ seeds: [AgentLegacyPromptSeed]) {
        var customs = customProfiles
        var record: [AgentLegacySeedRecord] = []
        var ordinal = 0
        for seed in seeds.prefix(AgentInstructionLimits.maxCustomProfiles) {
            ordinal += 1
            var adopted: UUID?
            let duplicate = customs.contains { $0.body.utf8.elementsEqual(seed.body.utf8) }
            if !AgentInstructionValidator.isBlank(seed.body), !duplicate,
               customs.count < AgentInstructionLimits.maxCustomProfiles {
                let label = AgentInstructionValidator.labelError(seed.suggestedLabel) == nil
                    ? seed.suggestedLabel : "Legacy prompt " + String(ordinal)
                let created = AgentInstructionProfile(id: UUID(), label: label, body: seed.body, kind: .legacySeed, revision: makeRevision())
                customs.append(created)
                adopted = created.id
            }
            record.append(AgentLegacySeedRecord(key: String(seed.key.prefix(128)), bodyUTF8: Data(seed.body.utf8), adoptedProfileID: adopted))
        }
        legacySeedRecord = record
        legacySeedApplied = true
        customProfiles = customs
        // With an unreadable store the seed is held in memory only; nothing is written.
        if case .storeUnreadable = persistenceState { return }
        _ = write(customs: customs)
    }

    private func write(customs: [AgentInstructionProfile]) -> AgentInstructionCatalogError? {
        if case .storeUnreadable = persistenceState { return .storeUnreadable }
        do {
            let store = AgentInstructionPersistedStore(
                formatVersion: AgentInstructionPersistedStore.currentVersion,
                nextRevisionSequence: nextSequence,
                legacySeedApplied: legacySeedApplied,
                legacySeedRecord: legacySeedRecord,
                customProfiles: customs.map {
                    AgentInstructionPersistedProfile(id: $0.id, label: $0.label, bodyUTF8: Data($0.body.utf8), kind: $0.kind, revision: $0.revision)
                })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(store)
            try storage.save(data)
            persistenceState = .clean
            return nil
        } catch {
            let reason = String(describing: error)
            persistenceState = .saveFailed(reason)
            return .saveFailed(reason)
        }
    }

    private static func decode(_ data: Data, builtInIDs: Set<UUID>) throws -> (customs: [AgentInstructionProfile], store: AgentInstructionPersistedStore) {
        let store = try JSONDecoder().decode(AgentInstructionPersistedStore.self, from: data)
        guard store.formatVersion == AgentInstructionPersistedStore.currentVersion else {
            throw AgentInstructionStoreFormatError(description: "unsupported catalog format version")
        }
        guard store.customProfiles.count <= AgentInstructionLimits.maxCustomProfiles else {
            throw AgentInstructionStoreFormatError(description: "too many custom profiles")
        }
        var seen = builtInIDs
        var customs: [AgentInstructionProfile] = []
        for item in store.customProfiles {
            guard seen.insert(item.id).inserted else {
                throw AgentInstructionStoreFormatError(description: "duplicate profile identifier")
            }
            guard item.kind != .builtIn else {
                throw AgentInstructionStoreFormatError(description: "built-in profile in custom store")
            }
            let body = String(decoding: item.bodyUTF8, as: UTF8.self)
            guard Data(body.utf8) == item.bodyUTF8 else {
                throw AgentInstructionStoreFormatError(description: "profile body is not valid UTF-8")
            }
            guard AgentInstructionValidator.labelError(item.label) == nil else {
                throw AgentInstructionStoreFormatError(description: "invalid profile label")
            }
            customs.append(AgentInstructionProfile(id: item.id, label: item.label, body: body, kind: item.kind, revision: item.revision))
        }
        return (customs, store)
    }
}
