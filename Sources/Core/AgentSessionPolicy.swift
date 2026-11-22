import CryptoKit
import Foundation
import Security

struct HelperPrincipal: Equatable, Hashable, Sendable {
    let uid: UInt32
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let signingIdentifier: String
    let leafCertSHA1: String
    let cdHashHex: String

    var fingerprint: String {
        let material = "helper-principal-v1\0\(uid)\0\(pid)\0\(startSeconds)\0\(startMicroseconds)\0\(signingIdentifier)\0\(leafCertSHA1)\0\(cdHashHex)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var shortCDHash: String { String(cdHashHex.prefix(8)) }
    var shortCert: String { String(leafCertSHA1.prefix(8)) }
}

struct PendingPairCandidate: Equatable, Identifiable, Sendable {
    let principal: HelperPrincipal
    let clientName: String
    let discoveredAt: Date

    var id: String { principal.fingerprint }
}

struct PinnedHelperSession: Equatable, Sendable {
    let sessionID: UUID
    let principal: HelperPrincipal
    let clientName: String
    let pinnedAt: Date
}

enum InstructionTarget: Equatable, Hashable, Sendable {
    case builtin(String)
    case local(String)

    init?(wireName: String) {
        if wireName == "explain" || wireName == "continue" || wireName == "normalize" {
            self = .builtin(wireName)
        } else if AgentInstructionCatalogStore.isValidLocalID(wireName) {
            self = .local(wireName)
        } else {
            return nil
        }
    }

    var wireName: String {
        switch self {
        case .builtin(let name): return name
        case .local(let id): return id
        }
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

struct ApprovedInstructionPayload: Equatable, Sendable {
    let target: InstructionTarget
    let label: String
    let origin: String
    let revision: String
    let instructions: String
}

struct ReadGrant: Equatable, Sendable {
    let sessionID: UUID
    let payload: ApprovedInstructionPayload
    let grantedAt: Date
    let expiresAt: Date
}

struct ReceiptGrant: Equatable, Sendable {
    let grantID: UUID
    let sessionID: UUID
    let grantedAt: Date
    let expiresAt: Date
    var acceptedCount: Int
}

struct DeliveryProof: Equatable, Sendable {
    let token: String
    let sessionID: UUID
    let principalFingerprint: String
    let targetWireName: String
    let revision: String
    let deliveredAt: Date
    let expiresAt: Date
}

struct DraftSubmissionMeta: Equatable, Sendable {
    let lateDraft: Bool
    let instructionTarget: String?
    let instructionRevision: String?
    let deliveryProof: String?

    init(
        lateDraft: Bool = false,
        instructionTarget: String? = nil,
        instructionRevision: String? = nil,
        deliveryProof: String? = nil
    ) {
        self.lateDraft = lateDraft
        self.instructionTarget = instructionTarget
        self.instructionRevision = instructionRevision
        self.deliveryProof = deliveryProof
    }

    var isMarkedLate: Bool {
        lateDraft || instructionTarget != nil || instructionRevision != nil || deliveryProof != nil
    }
}

enum ReadRevokeReason: Equatable, Sendable {
    case manual
    case edited
    case deleted
    case expired
    case sessionEnded
}

/// Deterministic security & lifecycle policy for the single pinned MCP helper session,
/// harness-initiated pairing discovery, separate 10-minute read/receipt leases,
/// sticky mutation revocation, delivery proofs, and rate caps.
final class AgentSessionPolicy {
    static let maxLeaseSeconds: TimeInterval = 600
    static let maxPairingWindowSeconds: TimeInterval = 120
    static let maxPendingCandidates = 8
    static let maxProofs = 32
    static let maxDraftsPerMinute = 6
    static let maxDraftsPerGrant = 20

    enum KnockOutcome: Equatable {
        case closed
        case invalidPrincipal
        case alreadyPinned
        case queued(PendingPairCandidate)
    }

    enum ReadServeOutcome: Equatable {
        case unauthorizedPeer
        case readDisabled
        case wrongTarget
        case served(ApprovedInstructionPayload, deliveryProof: String)
    }

    enum DraftAuthOutcome: Equatable {
        case unauthorizedPeer
        case receiptDisabled
        case unprovenLateDraft
        case rateLimited
        case grantLimitReached
        case authorized(verifiedLate: Bool)
    }

    enum PolicyError: LocalizedError, Equatable {
        case noPinnedSession
        case invalidDuration
        case invalidInstructionPayload
        case candidateNotFound

        var errorDescription: String? {
            switch self {
            case .noPinnedSession: return "먼저 에이전트 도우미 세션을 연결 승인해야 합니다."
            case .invalidDuration: return "허용 시간은 0초 초과 10분 이하여야 합니다."
            case .invalidInstructionPayload: return "공유할 지시문이 비어 있거나 8,192바이트를 초과했습니다."
            case .candidateNotFound: return "대기 중인 연결 후보를 찾을 수 없습니다."
            }
        }
    }

    private let clock: () -> Date
    private(set) var pairingExpiresAt: Date? = nil
    private(set) var pendingCandidates: [PendingPairCandidate] = []
    private(set) var pinnedSession: PinnedHelperSession? = nil
    private(set) var readGrant: ReadGrant? = nil
    private(set) var receiptGrant: ReceiptGrant? = nil
    private(set) var deliveryProofs: [DeliveryProof] = []
    private(set) var lastReadRevokeReason: ReadRevokeReason? = nil
    private var draftTimestamps: [Date] = []

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    var isPairingOpen: Bool {
        pruneExpired()
        return pairingExpiresAt != nil
    }

    var remainingDraftsInGrant: Int {
        pruneExpired()
        guard let receiptGrant else { return 0 }
        return max(0, Self.maxDraftsPerGrant - receiptGrant.acceptedCount)
    }

    @discardableResult
    func startPairing(duration: TimeInterval = maxPairingWindowSeconds) -> Bool {
        pruneExpired()
        guard duration > 0, duration <= Self.maxPairingWindowSeconds else { return false }
        pairingExpiresAt = clock().addingTimeInterval(duration)
        return true
    }

    func stopPairing() {
        pairingExpiresAt = nil
        pendingCandidates.removeAll()
    }

    func recordPairingKnock(_ principal: HelperPrincipal, clientName: String) -> KnockOutcome {
        pruneExpired()
        guard let expiresAt = pairingExpiresAt, clock() < expiresAt else {
            return .closed
        }
        guard !principal.signingIdentifier.isEmpty,
              !principal.leafCertSHA1.isEmpty,
              !principal.cdHashHex.isEmpty else {
            return .invalidPrincipal
        }
        if pinnedSession?.principal == principal {
            return .alreadyPinned
        }
        let cleanName = String(clientName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let candidate = PendingPairCandidate(
            principal: principal,
            clientName: cleanName.isEmpty ? "MCP Client" : cleanName,
            discoveredAt: clock()
        )
        pendingCandidates.removeAll { $0.principal.fingerprint == principal.fingerprint }
        pendingCandidates.insert(candidate, at: 0)
        if pendingCandidates.count > Self.maxPendingCandidates {
            pendingCandidates.removeLast()
        }
        return .queued(candidate)
    }

    @discardableResult
    func approvePairing(candidateFingerprint: String) -> Result<PinnedHelperSession, PolicyError> {
        pruneExpired()
        guard let candidate = pendingCandidates.first(where: { $0.principal.fingerprint == candidateFingerprint }) else {
            return .failure(.candidateNotFound)
        }
        endSession()
        let session = PinnedHelperSession(
            sessionID: UUID(),
            principal: candidate.principal,
            clientName: candidate.clientName,
            pinnedAt: clock()
        )
        pinnedSession = session
        lastReadRevokeReason = nil
        stopPairing()
        return .success(session)
    }

    func denyPairing(candidateFingerprint: String) {
        pendingCandidates.removeAll { $0.principal.fingerprint == candidateFingerprint }
    }

    /// Useful for explicit menu/PID single-session binding when user provides a verified helper PID.
    func pinDirectPrincipal(_ principal: HelperPrincipal, clientName: String = "Pinned Helper") -> PinnedHelperSession {
        endSession()
        let session = PinnedHelperSession(
            sessionID: UUID(),
            principal: principal,
            clientName: clientName,
            pinnedAt: clock()
        )
        pinnedSession = session
        lastReadRevokeReason = nil
        stopPairing()
        return session
    }

    func endSession() {
        pinnedSession = nil
        if readGrant != nil {
            lastReadRevokeReason = .sessionEnded
        }
        readGrant = nil
        receiptGrant = nil
        deliveryProofs.removeAll()
        draftTimestamps.removeAll()
    }

    @discardableResult
    func grantRead(
        payload: ApprovedInstructionPayload,
        duration: TimeInterval = maxLeaseSeconds
    ) -> Result<ReadGrant, PolicyError> {
        pruneExpired()
        guard let session = pinnedSession else { return .failure(.noPinnedSession) }
        guard duration > 0, duration <= Self.maxLeaseSeconds else { return .failure(.invalidDuration) }
        guard payload.instructions.utf8.count <= AgentInstructionCatalogStore.maxBodyUTF8Bytes,
              !payload.instructions.utf8.contains(0),
              !payload.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidInstructionPayload)
        }
        let now = clock()
        let grant = ReadGrant(
            sessionID: session.sessionID,
            payload: payload,
            grantedAt: now,
            expiresAt: now.addingTimeInterval(duration)
        )
        readGrant = grant
        lastReadRevokeReason = nil
        return .success(grant)
    }

    func revokeRead(reason: ReadRevokeReason = .manual) {
        if readGrant != nil || reason == .manual {
            lastReadRevokeReason = reason
        }
        readGrant = nil
    }

    /// Sticky revocation: editing (or editing and reverting) revokes the active read grant permanently.
    @discardableResult
    func revokeReadForContentMutation(targetWireName: String) -> Bool {
        pruneExpired()
        guard let active = readGrant, active.payload.target.wireName == targetWireName else {
            return false
        }
        readGrant = nil
        lastReadRevokeReason = .edited
        return true
    }

    @discardableResult
    func revokeReadForDeletion(entryID: String) -> Bool {
        pruneExpired()
        guard let active = readGrant, active.payload.target == .local(entryID) else {
            return false
        }
        readGrant = nil
        lastReadRevokeReason = .deleted
        return true
    }

    @discardableResult
    func grantReceipt(duration: TimeInterval = maxLeaseSeconds) -> Result<ReceiptGrant, PolicyError> {
        pruneExpired()
        guard let session = pinnedSession else { return .failure(.noPinnedSession) }
        guard duration > 0, duration <= Self.maxLeaseSeconds else { return .failure(.invalidDuration) }
        let now = clock()
        let grant = ReceiptGrant(
            grantID: UUID(),
            sessionID: session.sessionID,
            grantedAt: now,
            expiresAt: now.addingTimeInterval(duration),
            acceptedCount: 0
        )
        receiptGrant = grant
        draftTimestamps.removeAll()
        return .success(grant)
    }

    func revokeReceipt() {
        receiptGrant = nil
        draftTimestamps.removeAll()
        // Proofs cannot outlive their receipt.
        deliveryProofs.removeAll()
    }

    func serveRead(from principal: HelperPrincipal, targetWireName: String) -> ReadServeOutcome {
        pruneExpired()
        guard let session = pinnedSession, session.principal == principal else {
            return .unauthorizedPeer
        }
        guard let grant = readGrant, grant.sessionID == session.sessionID else {
            return .readDisabled
        }
        guard grant.payload.target.wireName == targetWireName else {
            return .wrongTarget
        }
        let now = clock()
        let tenMin = now.addingTimeInterval(Self.maxLeaseSeconds)
        let expiry = receiptGrant.map { min(tenMin, $0.expiresAt) } ?? tenMin
        let token = Self.randomProofToken()
        let proof = DeliveryProof(
            token: token,
            sessionID: session.sessionID,
            principalFingerprint: principal.fingerprint,
            targetWireName: targetWireName,
            revision: grant.payload.revision,
            deliveredAt: now,
            expiresAt: expiry
        )
        deliveryProofs.append(proof)
        if deliveryProofs.count > Self.maxProofs {
            deliveryProofs.removeFirst(deliveryProofs.count - Self.maxProofs)
        }
        return .served(grant.payload, deliveryProof: token)
    }

    func authorizeDraft(
        from principal: HelperPrincipal,
        meta: DraftSubmissionMeta,
        isKnownDuplicateOrConflict: Bool
    ) -> DraftAuthOutcome {
        pruneExpired()
        guard let session = pinnedSession, session.principal == principal else {
            return .unauthorizedPeer
        }
        guard let receipt = receiptGrant, receipt.sessionID == session.sessionID else {
            return .receiptDisabled
        }
        let now = clock()
        let verifiedLate: Bool
        if meta.isMarkedLate {
            guard let target = meta.instructionTarget,
                  let revision = meta.instructionRevision,
                  let token = meta.deliveryProof,
                  deliveryProofs.contains(where: {
                      $0.token == token
                          && $0.sessionID == session.sessionID
                          && $0.principalFingerprint == principal.fingerprint
                          && $0.targetWireName == target
                          && $0.revision == revision
                          && now < $0.expiresAt
                  }) else {
                return .unprovenLateDraft
            }
            verifiedLate = true
        } else {
            verifiedLate = false
        }

        if !isKnownDuplicateOrConflict {
            if receipt.acceptedCount >= Self.maxDraftsPerGrant {
                return .grantLimitReached
            }
            draftTimestamps.removeAll { now.timeIntervalSince($0) >= 60.0 }
            if draftTimestamps.count >= Self.maxDraftsPerMinute {
                return .rateLimited
            }
        }
        return .authorized(verifiedLate: verifiedLate)
    }

    func recordAcceptedDraft() {
        let now = clock()
        draftTimestamps.removeAll { now.timeIntervalSince($0) >= 60.0 }
        draftTimestamps.append(now)
        if var receipt = receiptGrant {
            receipt.acceptedCount += 1
            receiptGrant = receipt
        }
    }

    func pruneExpired() {
        let now = clock()
        if let pairingExpiresAt, now >= pairingExpiresAt {
            self.pairingExpiresAt = nil
            pendingCandidates.removeAll()
        }
        if let grant = readGrant, now >= grant.expiresAt {
            readGrant = nil
            lastReadRevokeReason = .expired
        }
        if let receipt = receiptGrant, now >= receipt.expiresAt {
            receiptGrant = nil
            draftTimestamps.removeAll()
            deliveryProofs.removeAll()
        }
        deliveryProofs.removeAll { now >= $0.expiresAt }
        draftTimestamps.removeAll { now.timeIntervalSince($0) >= 60.0 }
    }

    private static func randomProofToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
