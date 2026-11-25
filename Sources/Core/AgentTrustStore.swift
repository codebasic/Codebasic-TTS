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

/// Persisted next to the app's other data, mode 0600. An unreadable or foreign
/// file is treated as no trust at all, so the worst case is a new approval.
final class AgentTrustStore {
    struct File: Codable {
        var version = 1
        var autoReceive = false
        var clients: [AgentTrustedClient] = []
        var revoked: [String] = []
    }

    enum Lookup: Equatable {
        case trusted(AgentTrustedClient)
        case unknown, revoked, hostChanged, expired
    }

    enum Failure: Error { case invalid, full, revoked, unwritable }

    static let maxClients = 8
    static let maxRevoked = 64
    /// Sliding: a client that has not reconnected for this long must be approved again.
    static let idleLimit: TimeInterval = 30 * 24 * 3600

    private let url: URL
    private let now: () -> Date
    private let write: (Data, URL) throws -> Void
    private(set) var file = File()

    init(url: URL, now: @escaping () -> Date = Date.init,
         write: @escaping (Data, URL) throws -> Void = AgentTrustStore.writePrivately) {
        self.url = url
        self.now = now
        self.write = write
        file = Self.read(url) ?? File()
    }

    var clients: [AgentTrustedClient] { file.clients }
    var autoReceive: Bool { file.autoReceive }

    @discardableResult
    func setAutoReceive(_ value: Bool) -> Bool {
        guard file.autoReceive != value else { return true }
        var next = file
        next.autoReceive = value
        return commit(next)
    }

    func lookup(keyID: String, host: String) -> Lookup {
        if file.revoked.contains(keyID) { return .revoked }
        guard let client = file.clients.first(where: { $0.keyID == keyID }) else { return .unknown }
        if now().timeIntervalSince(client.lastSeen) > Self.idleLimit { return .expired }
        return client.host == host ? .trusted(client) : .hostChanged
    }

    /// Called only for an explicit approval in the app. Replaces the record for
    /// the same key or the same named client; never evicts a different one.
    func trust(publicKey: Data, label: String, host: String) throws -> AgentTrustedClient {
        guard let keyID = AgentPairingProof.keyID(publicKey) else { throw Failure.invalid }
        guard !file.revoked.contains(keyID) else { throw Failure.revoked }
        var next = file
        // A client that lost or replaced its key comes back under the same name from
        // the same launcher; the user's new approval supersedes the old record.
        next.clients.removeAll { $0.keyID == keyID || ($0.label == label && $0.host == host) }
        guard next.clients.count < Self.maxClients else { throw Failure.full }
        let time = now()
        let client = AgentTrustedClient(id: UUID(), keyID: keyID, publicKey: publicKey, label: label,
                                        host: host, created: time, lastSeen: time)
        next.clients.append(client)
        guard commit(next) else { throw Failure.unwritable }
        return client
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
        next.revoked.append(client.keyID)
        if next.revoked.count > Self.maxRevoked { next.revoked.removeFirst(next.revoked.count - Self.maxRevoked) }
        let saved = commit(next)
        if !saved { file = next }
        return saved
    }

    private func commit(_ next: File) -> Bool {
        guard let bytes = try? JSONEncoder().encode(next), (try? write(bytes, url)) != nil else { return false }
        file = next
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
              Set(loaded.clients.map(\.keyID)).count == loaded.clients.count else { return nil }
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
