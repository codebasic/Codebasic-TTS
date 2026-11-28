import CryptoKit
import Darwin
import Foundation

/// A local MCP client the user approved once in the app. The client proves it
/// still holds the private key on every reconnect; nothing here grants access
/// to instructions, and no draft content or key material other than the public
/// key is stored.
struct AgentTrustedClient: Codable, Equatable, Identifiable {
    let id: UUID
    let keyID: String
    let publicKey: Data
    let label: String
    /// The program that launched the helper when it was approved. A different
    /// launcher presenting the same key needs a new approval.
    let host: String
    let created: Date
    var lastSeen: Date
    // The first trust-file format had only the global receipt switch.
    fileprivate var receivesDrafts: Bool? = nil
    var receiptEnabled: Bool { receivesDrafts ?? true }
}

/// Wire format shared by the app's verification and the unit tests. The helper
/// builds the same bytes in `AgentPairing.message`.
enum AgentPairingProof {
    static func keyID(_ publicKey: Data) -> String? {
        guard (try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil else { return nil }
        return AgentBytes.hash(publicKey)
    }

    static func verify(publicKey: Data, signature: Data, message: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(parsed, for: message)
    }
}

/// Whether draft receipt may turn itself on when the Agent tab opens. `off` is
/// only ever set by the user turning receipt off, and it outlives restarts.
enum AgentReceiptChoice: String, Codable {
    case auto, off
}

/// Persisted next to the app's other data, mode 0600. An unreadable or foreign
/// file is treated as no trust at all, so the worst case is a new approval.
final class AgentTrustStore {
    struct File: Codable {
        var version = 1
        var autoReceive = false
        /// Absent in files written before the Agent tab could connect by itself.
        var receiptChoice: AgentReceiptChoice? = nil
        var clients: [AgentTrustedClient] = []
        var revoked: [String] = []
    }

    enum Lookup: Equatable {
        case trusted(AgentTrustedClient)
        case unknown, revoked, hostChanged
    }

    enum Failure: Error { case invalid, full, revoked, hostChanged, unwritable }

    static let maxClients = AgentPairing.slotCount
    static let maxRevoked = 64
    // Approval does not expire. An approved app stays approved until the user
    // revokes it, its key changes, or it is launched by a different app.

    private let url: URL
    private let now: () -> Date
    private let write: (Data, URL) throws -> Void
    private(set) var file = File()
    private var hasUnsavedDenial = false
    /// The file existed and was ours when the app started.
    private let loadedExisting: Bool

    init(url: URL, now: @escaping () -> Date = Date.init,
         write: @escaping (Data, URL) throws -> Void = AgentTrustStore.writePrivately) {
        self.url = url
        self.now = now
        self.write = write
        if let loaded = Self.read(url) {
            file = loaded
            loadedExisting = true
        } else {
            file = File()
            loadedExisting = false
            // A first launch may connect by itself. A file that exists but is not
            // ours is no trust and no choice, so receipt stays off until asked.
            if !FileManager.default.fileExists(atPath: url.path) { file.receiptChoice = .auto }
        }
    }

    var clients: [AgentTrustedClient] { file.clients }
    var autoReceive: Bool { file.autoReceive }

    /// An older file only says whether receipt was on. If it was off, nobody can
    /// tell whether the user turned it off, so it stays off and the app says so once.
    var receiptChoice: AgentReceiptChoice { file.receiptChoice ?? (file.autoReceive ? .auto : .off) }

    /// True until the user turns receipt on or off once in this version.
    var legacyReceiptOff: Bool { loadedExisting && file.receiptChoice == nil && !file.autoReceive }

    /// `byUser: false` is the Agent tab turning receipt on by itself; it keeps the
    /// user's choice. A user's on/off also records the choice.
    @discardableResult
    func setAutoReceive(_ value: Bool, byUser: Bool = true) -> Bool {
        let choice: AgentReceiptChoice = byUser ? (value ? .auto : .off) : receiptChoice
        guard file.autoReceive != value || file.receiptChoice != choice || hasUnsavedDenial else { return true }
        var next = file
        next.autoReceive = value
        next.receiptChoice = choice
        return value ? commit(next) : commitDenial(next)
    }

    func lookup(keyID: String, host: String) -> Lookup {
        if file.revoked.contains(keyID) { return .revoked }
        guard let client = file.clients.first(where: { $0.keyID == keyID }) else { return .unknown }
        return client.host == host ? .trusted(client) : .hostChanged
    }

    /// Explicit approval can renew or rotate the credential for one registered
    /// host. Other hosts keep their records even when the labels match.
    func trust(publicKey: Data, label: String, host: String) throws -> AgentTrustedClient {
        guard let keyID = AgentPairingProof.keyID(publicKey) else { throw Failure.invalid }
        guard !file.revoked.contains(keyID) else { throw Failure.revoked }
        var next = file
        let time = now()
        let client: AgentTrustedClient
        if let existing = next.clients.first(where: { $0.keyID == keyID }), existing.host != host {
            throw Failure.hostChanged
        }
        if let index = next.clients.firstIndex(where: { $0.host == host }) {
            let prior = next.clients[index]
            if prior.keyID != keyID { Self.revoke(prior.keyID, in: &next) }
            client = AgentTrustedClient(id: prior.id, keyID: keyID, publicKey: publicKey, label: label,
                                        host: host, created: prior.created, lastSeen: time, receivesDrafts: true)
            next.clients[index] = client
        } else {
            guard next.clients.count < Self.maxClients else { throw Failure.full }
            client = AgentTrustedClient(id: UUID(), keyID: keyID, publicKey: publicKey, label: label,
                                        host: host, created: time, lastSeen: time, receivesDrafts: true)
            next.clients.append(client)
        }
        guard commit(next) else { throw Failure.unwritable }
        return client
    }

    @discardableResult
    func setReceiptEnabled(_ enabled: Bool, for id: UUID) -> Bool {
        guard let index = file.clients.firstIndex(where: { $0.id == id }) else { return false }
        guard file.clients[index].receiptEnabled != enabled || hasUnsavedDenial else { return true }
        var next = file
        next.clients[index].receivesDrafts = enabled
        return enabled ? commit(next) : commitDenial(next)
    }

    /// A reconnect that cannot be recorded is still valid for this run.
    func touch(_ id: UUID) {
        guard let index = file.clients.firstIndex(where: { $0.id == id }) else { return }
        var next = file
        next.clients[index].lastSeen = now()
        _ = commit(next)
    }

    /// Forgetting tombstones the key, so the same credential cannot come back
    /// even inside a later approval window. Fails closed in memory if the disk
    /// write fails.
    @discardableResult
    func forget(_ id: UUID) -> Bool {
        guard let client = file.clients.first(where: { $0.id == id }) else { return false }
        var next = file
        next.clients.removeAll { $0.id == id }
        Self.revoke(client.keyID, in: &next)
        return commitDenial(next)
    }

    private static func revoke(_ keyID: String, in file: inout File) {
        file.revoked.append(keyID)
        if file.revoked.count > maxRevoked { file.revoked.removeFirst(file.revoked.count - maxRevoked) }
    }

    private func commitDenial(_ next: File) -> Bool {
        guard !commit(next) else { return true }
        file = next
        hasUnsavedDenial = true
        return false
    }

    private func commit(_ next: File) -> Bool {
        guard let bytes = try? JSONEncoder().encode(next), (try? write(bytes, url)) != nil else { return false }
        file = next
        hasUnsavedDenial = false
        return true
    }

    private static func read(_ url: URL) -> File? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? reader.close() }
        var meta = stat()
        guard fstat(fd, &meta) == 0, (meta.st_mode & S_IFMT) == S_IFREG, meta.st_uid == getuid(),
              meta.st_nlink == 1, meta.st_mode & 0o777 == 0o600, meta.st_size > 0, meta.st_size <= 256 * 1024,
              let bytes = try? reader.read(upToCount: 256 * 1024 + 1), bytes.count <= 256 * 1024,
              let loaded = try? JSONDecoder().decode(File.self, from: bytes), loaded.version == 1,
              loaded.clients.count <= maxClients,
              loaded.clients.allSatisfy({ AgentPairingProof.keyID($0.publicKey) == $0.keyID }),
              Set(loaded.clients.map(\.keyID)).count == loaded.clients.count,
              Set(loaded.clients.map(\.id)).count == loaded.clients.count else { return nil }
        let registeredHosts = loaded.clients.map(\.host).filter { $0.hasPrefix(AgentPairing.registeredHostPrefix) }
        guard Set(registeredHosts).count == registeredHosts.count else { return nil }
        return loaded
    }

    static func writePrivately(_ bytes: Data, _ destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".agent-clients-" + UUID().uuidString)
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
