import Foundation

struct AgentDraftOrigin: Equatable, Sendable {
    let principal: UUID
    let agentLabel: String
    let selector: String
    let revision: UUID
    let bodyHash: String
    let older: Bool
}

/// Only the transport sees the opaque proof. The helper stores it privately.
/// A fully written reply is the sole event that may enter this bounded ledger.
final class AgentDeliveryProofs: @unchecked Sendable {
    struct Entry: Sendable {
        let token: UUID
        let selector: String
        let revision: UUID
        let digest: String
        let expiry: ContinuousClock.Instant
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var epoch = UUID()

    func epochForSend() -> UUID {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    func delivered(_ token: UUID, snapshot: AgentInstructionSnapshot, epoch expected: UUID,
                   now: ContinuousClock.Instant = .now) {
        lock.lock(); defer { lock.unlock() }
        guard epoch == expected else { return }
        entries.removeAll { $0.expiry <= now }
        entries.append(Entry(token: token, selector: snapshot.selector, revision: snapshot.generation,
                             digest: snapshot.digest, expiry: now.advanced(by: .seconds(AgentLimits.grantSeconds))))
        if entries.count > AgentLimits.proofCount { entries.removeFirst(entries.count - AgentLimits.proofCount) }
    }

    func resolve(_ token: UUID, selector: String, revision: UUID, digest: String,
                 now: ContinuousClock.Instant = .now) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.expiry <= now }
        return entries.first { $0.token == token && $0.selector == selector
            && $0.revision == revision && $0.digest == digest }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        epoch = UUID()
    }
}

struct AgentRateLimit {
    private var recent: [ContinuousClock.Instant] = []
    private var accepted = 0

    mutating func canAccept(now: ContinuousClock.Instant = .now) -> Bool {
        recent.removeAll { $0.advanced(by: .seconds(60)) <= now }
        return accepted < AgentLimits.acceptedPerGrant && recent.count < AgentLimits.acceptedPerMinute
    }

    mutating func mark(now: ContinuousClock.Instant = .now) {
        accepted += 1
        recent.append(now)
    }
}
