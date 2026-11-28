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
    /// How long one delivered instruction read stays provable. The share itself
    /// lasts until the selection changes; an expired proof is renewed by reading again.
    static let proofSeconds = 600
    static let acceptedPerMinute = 6
    static let acceptedPerHour = 60
    /// Most recent delivery keys remembered per client for duplicate detection.
    static let receiptKeys = 128
    static let frameBytes = 100 * 1024
    /// A draft's list title: user-perceived characters, and bytes as a backstop
    /// against long combining sequences.
    static let titleCharacters = 120
    static let titleBytes = 512
}

/// Compiled into both ends. The helper signs these bytes with its client key;
/// the app verifies them against the key the user approved.
enum AgentPairing {
    static let schema = 4
    static let slotCount = 8
    static let registeredHostPrefix = "registered-v1:"

    // A bounded slot is routing only. The app still verifies the
    // audit token, signer, bundled hash and approved peer on each data socket.
    static func draftEndpoint(slot: Int) -> String { "d\(slot).sock" }
    static func instructionEndpoint(slot: Int) -> String { "i\(slot).sock" }

    static func message(appID: String, nonce: String, keyID: String) -> Data {
        Data("codebasic-tts-pair-v1\n\(appID)\n\(nonce)\n\(keyID)".utf8)
    }

    /// A content-free wake-up the app posts whenever it can accept connections
    /// (launch, Agent tab opened, unlock, receipt turned on). Any local process can
    /// post it; it only makes live helpers run the normal status/hello/prove
    /// exchange again, so it never grants anything by itself.
    /// Scoped to this user, so another account's processes do not share it.
    static func readyNotification(appID: String, uid: uid_t = getuid()) -> String { "\(appID).agent.ready.\(uid)" }

    /// Display text sent by the MCP client.
    static func clientName(_ input: String?) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-".utf8)
        let name = String(decoding: (input ?? "").lowercased().utf8.filter(allowed.contains).prefix(48), as: UTF8.self)
        return name.isEmpty ? "default" : name
    }
}

/// What a live helper does after a pairing attempt that it started on its own
/// (session start, the app's ready signal, or a scheduled retry). Compiled into
/// the helper and the unit tests.
enum AgentReconnect {
    enum Next: Equatable {
        /// Bound to the app; the app watches the helper process from here on.
        case done
        /// Only the app can change this (lock, receipt off, approval, other session);
        /// it posts the ready signal when it does.
        case waitForSignal
        /// The app was not reachable; try again after this many seconds.
        case retry(after: Double)
        /// Nothing changes until the helper restarts.
        case stop
    }

    static let firstDelay = 2.0
    static let maxDelay = 300.0
    /// Ready signals closer together than this are folded into one attempt.
    static let signalInterval = 1.0

    static func next(after status: String, attempt: Int) -> Next {
        switch status {
        case "ready", "receiving_only", "instruction_required", "reading_only": return .done
        case "revoked", "signing_required", "upgrade_required": return .stop
        case "app_unavailable", "unavailable": return .retry(after: delay(attempt: attempt))
        default: return .waitForSignal
        }
    }

    /// 2, 4, 8 ... seconds, capped at five minutes.
    static func delay(attempt: Int) -> Double {
        min(maxDelay, firstDelay * Double(1 << min(max(attempt, 0), 16)))
    }

    /// Spreads helpers of several sessions apart: `unit` in 0...1 maps to ±20 %.
    static func jittered(_ seconds: Double, unit: Double) -> Double {
        seconds * (0.8 + 0.4 * min(max(unit, 0), 1))
    }
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

    enum Title: Equatable { case absent, valid(String), invalid }

    /// A missing or blank title is simply absent. Anything else is kept whole
    /// or refused whole; it is never shortened to fit.
    static func title(_ input: String?) -> Title {
        guard let input else { return .absent }
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return .absent }
        guard title.count <= AgentLimits.titleCharacters, title.utf8.count <= AgentLimits.titleBytes,
              // Control codes and line breaks only. Format characters stay: joined
              // emoji and several scripts need them.
              title.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control && !CharacterSet.newlines.contains($0) })
        else { return .invalid }
        return .valid(title)
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
        case unreadable, invalid, duplicate, full, conflict, busy
        var errorDescription: String? {
            switch self {
            case .unreadable: return "저장된 지시 목록을 읽지 못했습니다. 원본은 덮어쓰지 않습니다."
            case .invalid: return "이름과 지시 내용을 확인하세요. 지시 한도는 UTF-8 8KB입니다."
            case .duplicate: return "같은 이름의 지시가 이미 있습니다."
            case .full: return "저장할 수 있는 지시 수가 한도에 도달했습니다."
            case .conflict: return "다른 편집에서 지시가 바뀌었습니다. 다시 열어 확인하세요."
            case .busy: return "다른 앱 창이 지시 목록을 저장 중입니다. 잠시 후 다시 시도하세요."
            }
        }
    }

    @Published private(set) var records: [AgentCatalogRecord] = []
    @Published private(set) var readError = false
    private let url: URL
    private let write: (Data, URL) throws -> Void
    private var knownStore = false
    /// Only called after durable commit. On deletion, the selector no longer
    /// resolves; random IDs are never reused (the live proof is tombstoned).
    var didChange: ((String, Bool) -> Void)?

    init(url: URL, write: @escaping (Data, URL) throws -> Void = AgentCatalog.writeAtomically) {
        self.url = url
        self.write = write
        _ = refresh()
    }

    func record(_ selector: String) -> AgentCatalogRecord? {
        guard !readError else { return nil }
        return records.first { $0.selector == selector }
    }

    func filteredRecords(label query: String) -> [AgentCatalogRecord] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? records : records.filter { $0.label.localizedStandardContains(term) }
    }

    /// Refreshes before a new grant or provenance check, as well as on focus.
    @discardableResult
    func refresh() -> Bool {
        do {
            let latest = try Self.readFile(url)
            guard latest != nil || !knownStore else { throw Failure.unreadable }
            adopt(latest)
            return true
        } catch {
            markUnreadable()
            return false
        }
    }

    /// Hold a shared disk lease through the bounded final handoff. A body edit
    /// or delete in another process cannot commit between verification and send.
    func deliveryGate(for snapshot: AgentInstructionSnapshot) -> (@escaping () -> Void) -> Void {
        let url = self.url
        return { send in
            _ = try? Self.withLock(url, exclusive: false) {
                guard let record = try Self.readFile(url)?.records.first(where: { $0.selector == snapshot.selector }),
                      record.generation == snapshot.generation, AgentBytes.same(record.body, snapshot.text) else { return }
                send()
            }
        }
    }

    @discardableResult
    func save(id: UUID? = nil, expected: UUID? = nil, label: String, body: String) throws -> AgentCatalogRecord {
        guard let label = AgentBytes.label(label) else { throw Failure.invalid }
        return try transaction { latest in
            let index = id.flatMap { id in latest.firstIndex { $0.id == id } }
            let previous = index.map { latest[$0] }
            if id != nil, previous?.editVersion != expected || previous == nil { throw Failure.conflict }
            if id == nil, latest.count >= AgentLimits.profiles { throw Failure.full }
            guard AgentBytes.textValid(body) || previous.map({ AgentBytes.same($0.body, body) }) == true else {
                throw Failure.invalid
            }
            guard !latest.contains(where: { $0.id != id && $0.label.caseInsensitiveCompare(label) == .orderedSame }) else {
                throw Failure.duplicate
            }
            if let previous, AgentBytes.same(previous.label, label), AgentBytes.same(previous.body, body) {
                return (previous, nil)
            }
            // A label-only edit does not affect the active wire revision.
            let generation = previous.flatMap { AgentBytes.same($0.body, body) ? $0.generation : nil } ?? UUID()
            let record = AgentCatalogRecord(id: id ?? UUID(), generation: generation,
                                            label: label, body: body, editRecord: UUID())
            var next = latest
            if let index { next[index] = record } else { next.append(record) }
            return (record, next)
        }
    }

    func delete(_ id: UUID, expected: UUID) throws {
        try transaction { latest in
            guard latest.first(where: { $0.id == id })?.editVersion == expected else { throw Failure.conflict }
            return ((), latest.filter { $0.id != id })
        }
    }

    private func transaction<T>(_ change: ([AgentCatalogRecord]) throws -> (T, [AgentCatalogRecord]?)) throws -> T {
        var latest: File?
        var didRead = false
        do {
            let result = try Self.withLock(url, exclusive: true) {
                latest = try Self.readFile(url)
                guard latest != nil || !knownStore else { throw Failure.unreadable }
                didRead = true
                let (value, next) = try change(latest?.records ?? [])
                if let next {
                    let replacement = File(version: 1, records: next)
                    let bytes = try JSONEncoder().encode(replacement)
                    guard bytes.count <= Self.fileLimit else { throw Failure.full }
                    try write(bytes, url)
                    latest = replacement
                }
                return value
            }
            adopt(latest)
            return result
        } catch {
            if didRead { adopt(latest) }
            else if case Failure.unreadable = error { markUnreadable() }
            throw error
        }
    }

    private func adopt(_ file: File?) {
        knownStore = file != nil
        let next = file?.records ?? []
        let index = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        // Revoke before exposing the new values. No socket calls under disk lock.
        for old in records {
            let current = index[old.id]
            if current?.generation != old.generation || current.map({ !AgentBytes.same($0.body, old.body) }) == true {
                didChange?(old.selector, current == nil)
            }
        }
        if !zip(records, next).allSatisfy({ $0.id == $1.id && $0.editVersion == $1.editVersion &&
            $0.generation == $1.generation && AgentBytes.same($0.label, $1.label) && AgentBytes.same($0.body, $1.body) })
            || records.count != next.count { records = next }
        if readError { readError = false }
    }

    private func markUnreadable() {
        if !readError {
            // Unknown is not a deletion; stop active retrieval without treating it as durable data loss.
            for old in records { didChange?(old.selector, false) }
            readError = true
        }
    }

    private nonisolated static let fileLimit = 4 * 1024 * 1024

    private nonisolated static func readFile(_ url: URL) throws -> File? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Failure.unreadable
        }
        let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? reader.close() }
        var meta = stat()
        guard fstat(fd, &meta) == 0, privateFile(meta),
              meta.st_size > 0, meta.st_size <= fileLimit,
              let bytes = try? reader.read(upToCount: fileLimit + 1), bytes.count <= fileLimit,
              let loaded = try? JSONDecoder().decode(File.self, from: bytes),
              loaded.version == 1, Set(loaded.records.map(\.id)).count == loaded.records.count else {
            throw Failure.unreadable
        }
        return loaded // Preserve oversized old bodies without sharing or truncating them.
    }

    private nonisolated static func privateFile(_ st: stat) -> Bool {
        (st.st_mode & S_IFMT) == S_IFREG && st.st_uid == getuid() && st.st_nlink == 1 && st.st_mode & 0o777 == 0o600
    }

    private nonisolated static func withLock<T>(_ url: URL, exclusive: Bool, _ body: () throws -> T) throws -> T {
        let parent = url.deletingLastPathComponent()
        if exclusive { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        let directory = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unreadable }
        defer { close(directory) }
        var dirStat = stat()
        guard fstat(directory, &dirStat) == 0, dirStat.st_uid == getuid(), dirStat.st_mode & 0o022 == 0 else {
            throw Failure.unreadable
        }
        let name = "." + url.lastPathComponent + ".lock"
        // This stable lock is never unlinked by the app. The kernel releases it when a process dies.
        let fd = openat(directory, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unreadable }
        defer { close(fd) }
        var locked = stat(), current = stat()
        guard fstat(fd, &locked) == 0, privateFile(locked) else { throw Failure.unreadable }
        let deadline = DispatchTime.now() + .milliseconds(250)
        while flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw Failure.unreadable }
            guard DispatchTime.now() < deadline else { throw Failure.busy }
            usleep(5_000)
        }
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0, privateFile(current),
              locked.st_dev == current.st_dev, locked.st_ino == current.st_ino,
              lstat(parent.path, &current) == 0, dirStat.st_dev == current.st_dev,
              dirStat.st_ino == current.st_ino, (current.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unreadable }
        return try body()
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

}
