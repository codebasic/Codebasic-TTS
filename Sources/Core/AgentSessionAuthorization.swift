import CryptoKit
import Foundation

enum AgentSessionLimits {
    static let maxGrantLifetime: TimeInterval = 600
    static let maxProofLifetime: TimeInterval = 600
    static let maxProofs = 32
    static let maxRecentSubmissions = 128
    static let maxAcceptedPerReceiptGrant = 20
    static let maxAcceptedPerWindow = 6
    static let rateWindow: TimeInterval = 60
    static let maxFieldUTF8Bytes = 8 * 1024
    static let maxIdempotencyKeyBytes = 128
    static let maxOutstandingReadTickets = 16
    static let maxTombstones = 1024
}

/// The helper instance UUID must already be authenticated by the OS/transport.
/// The label is chosen by the owner locally and is never taken from the wire.
struct AgentHelperPrincipal: Hashable, Sendable {
    let instanceID: UUID
    let ownerLabel: String
}

enum AgentAuthorizationDenial: String, Error, Equatable, Sendable {
    case notPaired
    case wrongPrincipal
    case invalidOwnerLabel
    case invalidLifetime
    case unshareableSnapshot
    case noShareGrant
    case noReceiptGrant
    case profileDeleted
    case noDeliveryProof
    case invalidIdempotencyKey
    case invalidContent
    case grantQuotaExhausted
    case rateLimited
    case pairingChanged
    case staleTicket
}

/// One immutable share of one exact snapshot, addressed by an opaque identifier.
struct AgentShareGrant: Equatable, Sendable {
    let shareID: UUID
    let principal: AgentHelperPrincipal
    let snapshot: AgentInstructionShareSnapshot
    let grantedAt: TimeInterval
    let expiresAt: TimeInterval
}

struct AgentReceiptGrantInfo: Equatable, Sendable {
    let grantID: UUID
    let principal: AgentHelperPrincipal
    let grantedAt: TimeInterval
    let expiresAt: TimeInterval
    let acceptedCount: Int
}

/// Proof that one exact share version was fully written to the authorized helper.
struct AgentDeliveryProof: Equatable, Sendable {
    let instanceID: UUID
    let profileID: UUID
    let revision: AgentInstructionRevision
    let sha256: Data
    let recordedAt: TimeInterval
    let expiresAt: TimeInterval
}

/// Issued when a read is authorized, before sending. Single use.
struct AgentShareReadTicket: Sendable {
    let ticketID: UUID
    let grant: AgentShareGrant
    fileprivate let sessionToken: UUID
    fileprivate let pairingGeneration: UInt64
    fileprivate let receiptEpoch: UInt64
    fileprivate let issuedAt: TimeInterval

    /// The exact bytes the transport must write.
    var bytes: Data { grant.snapshot.bodyUTF8 }
}

enum AgentDeliveryRecordResult: Equatable, Sendable {
    case proofRecorded(AgentDeliveryProof)
    /// The write finished after the share was revoked, replaced or expired. The helper
    /// does hold this version, so the proof is recorded, but the share stays unreadable.
    case proofRecordedAfterShareEnded(AgentDeliveryProof)
    case rejected(AgentAuthorizationDenial)
}

struct AgentDraftSubmission: Sendable {
    let instanceID: UUID
    let profileID: UUID
    let revision: AgentInstructionRevision
    let instructionSHA256: Data
    let idempotencyKey: String
    let display: String
    let speech: String?

    init(instanceID: UUID, profileID: UUID, revision: AgentInstructionRevision, instructionSHA256: Data,
         idempotencyKey: String, display: String, speech: String?) {
        self.instanceID = instanceID
        self.profileID = profileID
        self.revision = revision
        self.instructionSHA256 = instructionSHA256
        self.idempotencyKey = idempotencyKey
        self.display = display
        self.speech = speech
    }
}

enum AgentSubmissionOutcome: Equatable, Sendable {
    case accepted(AgentDraftProvenance)
    case duplicate
    case conflict
    /// The inbox refused the draft (for example, it is full). Nothing was consumed.
    case refusedByQueue
    case denied(AgentAuthorizationDenial)
}

struct AgentSessionStatus: Equatable, Sendable {
    let principal: AgentHelperPrincipal?
    let share: AgentShareGrant?
    let receipt: AgentReceiptGrantInfo?
    let proofCount: Int
    let now: TimeInterval
}

/// Volatile, in-memory session consent and delivery proof. Nothing is persisted; create a
/// new instance per app session. No provider access. Thread-safe.
///
/// - One paired helper, at most one share and one independent receipt grant.
/// - Selecting a profile grants nothing; only `grantShare` and `grantReceipt` do.
/// - Transport: `beginShareRead` before sending, `completeShareRead` after the full write.
/// - Drafts: `submit(_:enqueue:)` validates, then runs `enqueue` while holding the lock.
///   Quota and dedupe are consumed only if `enqueue` returns true.
final class AgentSessionAuthorization: @unchecked Sendable {
    private struct ReceiptState {
        let grantID: UUID
        let principal: AgentHelperPrincipal
        let grantedAt: TimeInterval
        let expiresAt: TimeInterval
        var acceptedCount: Int

        var info: AgentReceiptGrantInfo {
            AgentReceiptGrantInfo(grantID: grantID, principal: principal, grantedAt: grantedAt, expiresAt: expiresAt, acceptedCount: acceptedCount)
        }
    }

    private struct RecentSubmission {
        let instanceID: UUID
        let profileID: UUID
        let revision: AgentInstructionRevision
        let contentHash: Data
        let idempotencyKey: Data
    }

    private let lock = NSRecursiveLock()
    private let clock: () -> TimeInterval
    private let sessionToken = UUID()
    private var pairingGeneration: UInt64 = 0
    /// Advances whenever a receipt grant ends (revoke, expiry, replacement).
    private var receiptEpoch: UInt64 = 0
    private var principal: AgentHelperPrincipal?
    private var share: AgentShareGrant?
    private var receipt: ReceiptState?
    private var proofs: [AgentDeliveryProof] = []
    private var outstandingTickets: [UUID] = []
    private var tombstones: [UUID] = []
    private var recent: [RecentSubmission] = []
    private var acceptedTimes: [TimeInterval] = []

    /// Monotonic seconds that keep counting while the machine sleeps.
    static func monotonicNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    init(clock: @escaping () -> TimeInterval = AgentSessionAuthorization.monotonicNow) {
        self.clock = clock
    }

    // MARK: Pairing

    /// Pairs exactly one helper. Any previous pairing, share, receipt grant and proofs are wiped.
    @discardableResult
    func pair(instanceID: UUID, ownerLabel: String) -> Result<AgentHelperPrincipal, AgentAuthorizationDenial> {
        _ = enter()
        defer { lock.unlock() }
        guard Self.validOwnerLabel(ownerLabel) else { return .failure(.invalidOwnerLabel) }
        wipePairing()
        let paired = AgentHelperPrincipal(instanceID: instanceID, ownerLabel: ownerLabel)
        principal = paired
        return .success(paired)
    }

    func unpair() {
        _ = enter()
        defer { lock.unlock() }
        wipePairing()
    }

    /// Wipes everything volatile, as a session restart would.
    func resetSession() {
        _ = enter()
        defer { lock.unlock() }
        wipePairing()
        recent.removeAll()
        acceptedTimes.removeAll()
    }

    // MARK: Share

    /// Explicit owner action. Replaces any previous share; the old identifier stops working.
    @discardableResult
    func grantShare(_ snapshot: AgentInstructionShareSnapshot, to instanceID: UUID,
                    lifetime: TimeInterval = AgentSessionLimits.maxGrantLifetime) -> Result<AgentShareGrant, AgentAuthorizationDenial> {
        let now = enter()
        defer { lock.unlock() }
        guard let paired = principal else { return .failure(.notPaired) }
        guard paired.instanceID == instanceID else { return .failure(.wrongPrincipal) }
        guard lifetime > 0 else { return .failure(.invalidLifetime) }
        guard !tombstones.contains(snapshot.profileID) else { return .failure(.profileDeleted) }
        guard !snapshot.bodyUTF8.isEmpty,
              snapshot.bodyUTF8.count <= AgentInstructionLimits.maxBodyUTF8Bytes,
              !snapshot.bodyUTF8.contains(0),
              Data(SHA256.hash(data: snapshot.bodyUTF8)) == snapshot.sha256 else { return .failure(.unshareableSnapshot) }
        let grant = AgentShareGrant(shareID: UUID(), principal: paired, snapshot: snapshot, grantedAt: now,
                                    expiresAt: now + min(lifetime, AgentSessionLimits.maxGrantLifetime))
        share = grant
        return .success(grant)
    }

    func revokeShare() {
        _ = enter()
        defer { lock.unlock() }
        share = nil
    }

    /// Call for every body change, including a revert. Revokes reads only: recorded proofs
    /// and accepted drafts stay. Nothing re-enables the old share.
    @discardableResult
    func instructionBodyChanged(profileID: UUID) -> Bool {
        _ = enter()
        defer { lock.unlock() }
        guard let live = share, live.snapshot.profileID == profileID else { return false }
        share = nil
        return true
    }

    /// Tombstones the profile: no new share, proof or draft receipt for it in this session.
    /// Drafts that were already accepted are untouched.
    func profileDeleted(profileID: UUID) {
        _ = enter()
        defer { lock.unlock() }
        if !tombstones.contains(profileID) {
            tombstones.append(profileID)
            if tombstones.count > AgentSessionLimits.maxTombstones {
                tombstones.removeFirst(tombstones.count - AgentSessionLimits.maxTombstones)
            }
        }
        if let live = share, live.snapshot.profileID == profileID { share = nil }
        proofs.removeAll { $0.profileID == profileID }
    }

    /// Authorization check before sending. The transport writes `ticket.bytes` in full and
    /// then calls `completeShareRead`.
    func beginShareRead(shareID: UUID, instanceID: UUID) -> Result<AgentShareReadTicket, AgentAuthorizationDenial> {
        let now = enter()
        defer { lock.unlock() }
        guard let paired = principal else { return .failure(.notPaired) }
        guard paired.instanceID == instanceID else { return .failure(.wrongPrincipal) }
        guard let live = share, live.shareID == shareID, live.principal == paired else { return .failure(.noShareGrant) }
        guard !tombstones.contains(live.snapshot.profileID) else { return .failure(.profileDeleted) }
        let ticket = AgentShareReadTicket(ticketID: UUID(), grant: live, sessionToken: sessionToken,
                                          pairingGeneration: pairingGeneration, receiptEpoch: receiptEpoch, issuedAt: now)
        outstandingTickets.append(ticket.ticketID)
        if outstandingTickets.count > AgentSessionLimits.maxOutstandingReadTickets {
            outstandingTickets.removeFirst(outstandingTickets.count - AgentSessionLimits.maxOutstandingReadTickets)
        }
        return .success(ticket)
    }

    /// Call only after the full write succeeded. Records proof of exactly that version.
    @discardableResult
    func completeShareRead(_ ticket: AgentShareReadTicket) -> AgentDeliveryRecordResult {
        let now = enter()
        defer { lock.unlock() }
        guard ticket.sessionToken == sessionToken,
              let index = outstandingTickets.firstIndex(of: ticket.ticketID) else { return .rejected(.staleTicket) }
        outstandingTickets.remove(at: index)
        guard let paired = principal, ticket.pairingGeneration == pairingGeneration,
              paired == ticket.grant.principal else { return .rejected(.pairingChanged) }
        guard now - ticket.issuedAt < AgentSessionLimits.maxGrantLifetime else { return .rejected(.staleTicket) }
        // A receipt grant ended after this read was authorized: its proof must not come back.
        guard ticket.receiptEpoch == receiptEpoch else { return .rejected(.staleTicket) }
        let snapshot = ticket.grant.snapshot
        guard !tombstones.contains(snapshot.profileID) else { return .rejected(.profileDeleted) }
        let proof = AgentDeliveryProof(instanceID: paired.instanceID, profileID: snapshot.profileID,
                                       revision: snapshot.revision, sha256: snapshot.sha256, recordedAt: now,
                                       expiresAt: now + AgentSessionLimits.maxProofLifetime)
        proofs.removeAll {
            $0.instanceID == proof.instanceID && $0.profileID == proof.profileID
                && $0.revision == proof.revision && $0.sha256 == proof.sha256
        }
        proofs.append(proof)
        if proofs.count > AgentSessionLimits.maxProofs {
            proofs.removeFirst(proofs.count - AgentSessionLimits.maxProofs)
        }
        if let live = share, live.shareID == ticket.grant.shareID { return .proofRecorded(proof) }
        return .proofRecordedAfterShareEnded(proof)
    }

    // MARK: Receipt

    /// Independent of any share. Replacing an existing grant ends it, which clears proofs.
    @discardableResult
    func grantReceipt(to instanceID: UUID,
                      lifetime: TimeInterval = AgentSessionLimits.maxGrantLifetime) -> Result<AgentReceiptGrantInfo, AgentAuthorizationDenial> {
        let now = enter()
        defer { lock.unlock() }
        guard let paired = principal else { return .failure(.notPaired) }
        guard paired.instanceID == instanceID else { return .failure(.wrongPrincipal) }
        guard lifetime > 0 else { return .failure(.invalidLifetime) }
        if receipt != nil {
            proofs.removeAll()
            receiptEpoch &+= 1
        }
        let state = ReceiptState(grantID: UUID(), principal: paired, grantedAt: now,
                                 expiresAt: now + min(lifetime, AgentSessionLimits.maxGrantLifetime), acceptedCount: 0)
        receipt = state
        return .success(state.info)
    }

    /// Ends the receipt grant and clears proofs. The share, if any, is unaffected.
    func revokeReceipt() {
        _ = enter()
        defer { lock.unlock() }
        if receipt != nil {
            receipt = nil
            proofs.removeAll()
            receiptEpoch &+= 1
        }
    }

    // MARK: Draft gate

    /// Validates the submission and, only if everything passes, calls `enqueue` while the
    /// lock is held. Return true from `enqueue` only when the draft was actually queued.
    /// There is no fallback to another revision. `enqueue` must not block on other threads.
    func submit(_ submission: AgentDraftSubmission, enqueue: (AgentDraftProvenance) -> Bool) -> AgentSubmissionOutcome {
        let now = enter()
        defer { lock.unlock() }
        guard let paired = principal else { return .denied(.notPaired) }
        guard paired.instanceID == submission.instanceID else { return .denied(.wrongPrincipal) }
        guard let grant = receipt, grant.principal == paired else { return .denied(.noReceiptGrant) }
        guard !tombstones.contains(submission.profileID) else { return .denied(.profileDeleted) }
        let proven = proofs.contains {
            $0.instanceID == paired.instanceID && $0.profileID == submission.profileID
                && $0.revision == submission.revision && $0.sha256 == submission.instructionSHA256
        }
        guard proven else { return .denied(.noDeliveryProof) }
        let keyBytes = Data(submission.idempotencyKey.utf8)
        guard !keyBytes.isEmpty, keyBytes.count <= AgentSessionLimits.maxIdempotencyKeyBytes,
              !keyBytes.contains(0) else { return .denied(.invalidIdempotencyKey) }
        guard Self.validField(submission.display),
              submission.speech.map(Self.validField) ?? true else { return .denied(.invalidContent) }

        let hash = Self.contentHash(display: submission.display, speech: submission.speech)
        var sameData = false
        for entry in recent where entry.instanceID == paired.instanceID {
            let same = entry.profileID == submission.profileID && entry.revision == submission.revision
                && entry.contentHash == hash
            if entry.idempotencyKey == keyBytes && !same { return .conflict }
            if same { sameData = true }
        }
        if sameData { return .duplicate }

        guard grant.acceptedCount < AgentSessionLimits.maxAcceptedPerReceiptGrant else { return .denied(.grantQuotaExhausted) }
        acceptedTimes.removeAll { $0 <= now - AgentSessionLimits.rateWindow }
        guard acceptedTimes.count < AgentSessionLimits.maxAcceptedPerWindow else { return .denied(.rateLimited) }

        let provenance = AgentDraftProvenance(helperInstanceID: paired.instanceID, helperLabel: paired.ownerLabel,
                                              profileID: submission.profileID, revision: submission.revision,
                                              instructionSHA256: submission.instructionSHA256, receiptGrantID: grant.grantID)
        guard enqueue(provenance) else { return .refusedByQueue }

        recent.append(RecentSubmission(instanceID: paired.instanceID, profileID: submission.profileID,
                                       revision: submission.revision, contentHash: hash, idempotencyKey: keyBytes))
        if recent.count > AgentSessionLimits.maxRecentSubmissions {
            recent.removeFirst(recent.count - AgentSessionLimits.maxRecentSubmissions)
        }
        acceptedTimes.append(now)
        if var live = receipt, live.grantID == grant.grantID {
            live.acceptedCount += 1
            receipt = live
        }
        return .accepted(provenance)
    }

    // MARK: Inspection

    func status() -> AgentSessionStatus {
        let now = enter()
        defer { lock.unlock() }
        return AgentSessionStatus(principal: principal, share: share, receipt: receipt?.info, proofCount: proofs.count, now: now)
    }

    func hasProof(instanceID: UUID, profileID: UUID, revision: AgentInstructionRevision, sha256: Data) -> Bool {
        _ = enter()
        defer { lock.unlock() }
        return proofs.contains {
            $0.instanceID == instanceID && $0.profileID == profileID && $0.revision == revision && $0.sha256 == sha256
        }
    }

    /// SHA-256 over an unambiguous length-prefixed framing of display and optional speech.
    static func contentHash(display: String, speech: String?) -> Data {
        var frame = Data()
        appendField(&frame, display)
        if let speech = speech {
            frame.append(1)
            appendField(&frame, speech)
        } else {
            frame.append(0)
        }
        return Data(SHA256.hash(data: frame))
    }

    // MARK: Private

    /// Takes the lock, reads the clock and expires stale state. Callers must unlock.
    private func enter() -> TimeInterval {
        lock.lock()
        let now = clock()
        if let live = share, now >= live.expiresAt { share = nil }
        if let live = receipt, now >= live.expiresAt {
            receipt = nil
            proofs.removeAll()
            receiptEpoch &+= 1
        }
        proofs.removeAll { now >= $0.expiresAt }
        return now
    }

    private func wipePairing() {
        principal = nil
        share = nil
        receipt = nil
        proofs.removeAll()
        outstandingTickets.removeAll()
        pairingGeneration = pairingGeneration &+ 1
    }

    private static func appendField(_ data: inout Data, _ value: String) {
        let length = UInt64(value.utf8.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(contentsOf: value.utf8)
    }

    private static func validField(_ value: String) -> Bool {
        value.utf8.count <= AgentSessionLimits.maxFieldUTF8Bytes && !value.utf8.contains(0)
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validOwnerLabel(_ label: String) -> Bool {
        !label.utf8.contains(0) && label.utf8.count <= 96 && label.count <= 80
            && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
