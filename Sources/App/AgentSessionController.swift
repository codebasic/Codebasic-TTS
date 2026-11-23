import Combine
import CryptoKit
import CoreFoundation
import Darwin
import Foundation
import Security

/// The UI's name is descriptive only. The authenticated principal is the client
/// key the user approved once in the app; each live helper process proves it holds
/// that key before it is bound. A helper without a durable key is bound for its own
/// lifetime only. Approval never includes reading an instruction.
@MainActor final class AgentSessionController: ObservableObject {
    enum SelectionStatus: String {
        case notSelected, waitingForHelper, active, canceled, expired, changed
        case legacySharing, catalogUnavailable, invalidInstruction, pairingUnavailable, instructionGrantFailed, draftGrantFailed

        var message: String {
            switch self {
            case .notSelected: return "공유하는 지시 없음 · 대본은 지시 없이 받습니다."
            case .waitingForHelper: return "선택됨 · 에이전트 연결을 켜면 공유됩니다."
            case .active: return "선택한 지시 공유 중"
            case .canceled: return "지시 공유를 취소했습니다."
            case .expired: return "선택 대기 시간이 지났습니다. 지시를 다시 선택하세요."
            case .changed: return "저장된 지시가 바뀌었습니다. 공유할 지시를 다시 선택하세요."
            case .legacySharing: return "기존 지시 공유를 끈 뒤 다시 선택하세요."
            case .catalogUnavailable: return "저장된 지시를 열 수 없습니다. 다른 지시를 선택하세요."
            case .invalidInstruction: return "빈 지시이거나 너무 깁니다. 저장본을 확인하세요."
            case .pairingUnavailable: return "MCP를 시작할 수 없습니다. 앱을 다시 여세요."
            case .instructionGrantFailed: return "지시 공유를 시작하지 못했습니다. 연결을 확인하고 다시 선택하세요."
            case .draftGrantFailed: return "대본 수신을 시작하지 못했습니다. 연결을 확인하고 다시 선택하세요."
            }
        }

        var isProblem: Bool {
            switch self {
            case .expired, .changed, .legacySharing, .catalogUnavailable, .invalidInstruction, .pairingUnavailable,
                 .instructionGrantFailed, .draftGrantFailed: return true
            default: return false
            }
        }
    }

    private struct PendingSelection {
        let id = UUID()
        let snapshot: AgentInstructionSnapshot
        let current: @MainActor (String) -> AgentInstructionSnapshot?
        let deliveryGate: (@escaping () -> Void) -> Void
        let deadline: ContinuousClock.Instant
    }

    private struct ReceiveContext {
        let current: @MainActor (String) -> AgentInstructionSnapshot?
        let workspace: ExplanationDraftWorkspace
    }

    /// One explicit click lets one not-yet-approved client in before the deadline.
    private struct ApprovalWindow {
        let id = UUID()
        let deadline: ContinuousClock.Instant
    }

    private struct Challenge {
        let peer: LocalInstructionPeer
        let publicKey: Data
        let keyID: String
        let label: String
        let persistent: Bool
        let nonce: String
        let deadline: ContinuousClock.Instant
    }

    /// The selection the user made, kept so the same approved client gets the
    /// same exact revision again after it restarts. Never written to disk.
    private struct RememberedSelection {
        var client: UUID?
        let snapshot: AgentInstructionSnapshot
        let current: @MainActor (String) -> AgentInstructionSnapshot?
        let deliveryGate: (@escaping () -> Void) -> Void
    }

    struct Pair {
        /// This binding of one live process.
        let id = UUID()
        /// The approved client; stable across reconnects when `persistent`.
        let client: UUID
        let persistent: Bool
        let label: String
        let peer: LocalInstructionPeer
        let hostPath: String?
        let leaf: String
        let helperHash: Data
        let proofs = AgentDeliveryProofs()
    }

    @Published private(set) var pair: Pair?
    @Published private(set) var shared: AgentInstructionSnapshot?
    @Published private(set) var receiving = false
    @Published private(set) var status = ""
    @Published private(set) var selectionStatus: SelectionStatus = .notSelected
    // Bounded in-memory event codes only, with no user strings or identifiers.
    private(set) var selectionDiagnostics: [SelectionStatus] = []
    @Published private(set) var waitingForReceiveHelper = false
    @Published private(set) var instructionScope: String?
    /// Why the last submission from the agent was not opened, in the user's terms.
    @Published private(set) var receiptNotice: String?
    /// False for an ad-hoc signed build, where a helper can never be verified.
    private(set) lazy var pairingSupported = AgentPeerSigning.ownLeaf() != nil && bundledHelper() != nil

    /// Receipt is on, but a chosen instruction is not being shared, so every
    /// submission is refused until the user picks it again or clears it.
    var receiptBlockedBySelection: Bool { receiving && instructionScope != nil && shared == nil }
    /// Approved clients stored on this Mac, for the list where the user can forget one.
    @Published private(set) var trusted: [AgentTrustedClient] = []
    /// The user's standing choice to receive from approved clients. Persisted.
    @Published private(set) var autoReceive = false
    @Published private(set) var locked = false
    /// A client that asked to connect and is waiting for the user's approval.
    @Published private(set) var awaitingApproval: String?
    private let trust: AgentTrustStore
    private var context: ReceiveContext?
    private var approval: ApprovalWindow?
    private var approvalTask: Task<Void, Never>?
    private var challenges: [Challenge] = []
    private var remembered: RememberedSelection?
    private var pendingSelection: PendingSelection?
    private var pendingTask: Task<Void, Never>?
    private let selectionWaiting: Duration
    private var pairingSocket: LocalApprovedSocket?
    private var shareSocket: LocalApprovedSocket?
    private var receiptSocket: LocalApprovedSocket?
    private var watch: DispatchSourceProcess?
    private var rate = AgentRateLimit()
    /// Per approved client, newest last. Survives a client restart, not an app restart.
    private var receiptKeys: [UUID: [(key: String, digest: SHA256.Digest)]] = [:]
    private var receiptGeneration: UUID?
    private let directory: String
    private let bundledHelper: () -> Data?

    init(directory: String = LocalApprovedSocket.defaultDirectory,
         bundledHelper: @escaping () -> Data? = AgentPeerSigning.bundledHelperHash,
         selectionWaiting: Duration = .seconds(90),
         trust: AgentTrustStore = AgentTrustStore(
            url: TTSRuntime.applicationSupport().appendingPathComponent("agent-clients.json"))) {
        self.directory = directory
        self.bundledHelper = bundledHelper
        self.selectionWaiting = selectionWaiting
        self.trust = trust
        trusted = trust.clients
        autoReceive = trust.autoReceive
    }

    /// Where received drafts go. Needed before an approved client can resume
    /// without a click, so the app sets it at launch.
    func configure(current: @escaping @MainActor (String) -> AgentInstructionSnapshot?,
                   workspace: ExplanationDraftWorkspace) {
        context = ReceiveContext(current: current, workspace: workspace)
    }

    @discardableResult
    func startPairing() -> Bool {
        guard pairingSocket == nil else { return true }
        guard let leaf = AgentPeerSigning.ownLeaf(), let hash = bundledHelper() else {
            status = "자동 연결에는 이 앱과 함께 서명된 MCP 도우미가 필요합니다."
            return false
        }
        let socket = LocalApprovedSocket(pairingDirectory: directory,
                                        verified: Self.verifier(leaf: leaf, hash: hash)) { [weak self] bytes, peer, active in
            guard let request = Self.decode(bytes) else { return Self.reply("invalid") }
            guard Self.isSchema(request["schema_version"], AgentPairing.schema) else { return Self.reply("upgrade_required") }
            let keys = Set(request.keys)
            let response = Reply()
            let signal = DispatchSemaphore(value: 0)
            let deadline = DispatchTime.now() + .milliseconds(750)
            DispatchQueue.main.async {
                defer { signal.signal() }
                guard DispatchTime.now() < deadline, active(), let self else { return }
                switch request["op"] as? String {
                case "status" where keys == ["schema_version", "op"]:
                    response.set(self.connectionStatus(for: peer))
                case "hello" where keys == ["schema_version", "op", "public_key", "client", "persistent"]:
                    guard let key = (request["public_key"] as? String).flatMap({ Data(base64Encoded: $0) }),
                          let label = request["client"] as? String, AgentPairing.clientName(label) == label,
                          let persistent = request["persistent"] as? Bool else { response.set("invalid"); return }
                    response.set(self.challenge(peer: peer, publicKey: key, label: label, persistent: persistent))
                case "prove" where keys == ["schema_version", "op", "nonce", "signature"]:
                    guard let nonce = request["nonce"] as? String,
                          let signature = (request["signature"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                        response.set("invalid"); return
                    }
                    response.set(self.prove(peer: peer, nonce: nonce, signature: signature, leaf: leaf, helperHash: hash))
                default: response.set("invalid")
                }
            }
            guard signal.wait(timeout: deadline) == .success else { return Self.reply("unavailable") }
            return response.data()
        }
        guard socket.start() else {
            status = socket.requiresPathInspection ? LocalApprovedSocket.unknownPathMessage : "다른 앱 인스턴스가 자동 연결을 사용 중일 수 있습니다."
            return false
        }
        pairingSocket = socket
        return true
    }

    /// Quitting the app is not the user turning receipt off, so the standing
    /// choice and the approved clients are left as they are.
    func stopPairing() {
        pairingSocket?.stop(); pairingSocket = nil
        closeApprovalWindow()
        challenges.removeAll()
        if pair != nil { dropBinding(keepSelection: false) }
    }

    private func dropIfGone() {
        if let previous = pair, LocalInstructionPeer.current(pid: previous.peer.pid) != previous.peer {
            dropBinding(keepSelection: previous.persistent)
        }
    }

    private func bound(_ peer: LocalInstructionPeer) -> String {
        receiving
            ? (shared != nil ? "ready" : (instructionScope != nil ? "instruction_required" : "receiving_only"))
            : (shared == nil ? "approval_required" : "reading_only")
    }

    private func connectionStatus(for peer: LocalInstructionPeer) -> String {
        dropIfGone()
        if locked { return "locked" }
        guard let pair else { return "identify" }
        return pair.peer == peer ? bound(peer) : "other_agent"
    }

    /// Step one of a reconnect: bind a fresh nonce to this exact live process.
    private func challenge(peer: LocalInstructionPeer, publicKey: Data, label: String, persistent: Bool) -> [String: String] {
        dropIfGone()
        if locked { return ["status": "locked"] }
        if let pair, pair.peer != peer { return ["status": "other_agent"] }
        guard let keyID = AgentPairingProof.keyID(publicKey) else { return ["status": "invalid"] }
        if persistent, trust.lookup(keyID: keyID, host: "") == .revoked { return ["status": "revoked"] }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return ["status": "unavailable"] }
        let nonce = Data(bytes).base64EncodedString()
        let now = ContinuousClock.now
        challenges.removeAll { $0.peer == peer || $0.deadline <= now }
        if challenges.count >= 4 { challenges.removeFirst(challenges.count - 3) }
        challenges.append(Challenge(peer: peer, publicKey: publicKey, keyID: keyID, label: label, persistent: persistent,
                                    nonce: nonce, deadline: now.advanced(by: .seconds(5))))
        return ["status": "challenge", "nonce": nonce]
    }

    /// Step two: the signature decides who this is; the stored approval decides
    /// whether that is enough, or whether the user has to say yes in the app.
    private func prove(peer: LocalInstructionPeer, nonce: String, signature: Data, leaf: String, helperHash: Data) -> String {
        guard let index = challenges.firstIndex(where: { $0.peer == peer && $0.nonce == nonce }) else { return "invalid" }
        let claim = challenges.remove(at: index)
        guard ContinuousClock.now < claim.deadline,
              AgentPairingProof.verify(publicKey: claim.publicKey, signature: signature,
                                       message: AgentPairing.message(appID: AgentPeerSigning.appID, nonce: nonce,
                                                                     keyID: claim.keyID)) else { return "invalid" }
        dropIfGone()
        if locked { return "locked" }
        if let pair { return pair.peer == peer ? bound(peer) : "other_agent" }
        let host = Self.hostIdentity(peer)
        let lookup: AgentTrustStore.Lookup = claim.persistent && host != nil
            ? trust.lookup(keyID: claim.keyID, host: host ?? "") : .unknown
        switch lookup {
        case .revoked: return "revoked"
        case .trusted(let client):
            // Approved earlier, but the user has receipt turned off right now.
            guard autoReceive, context != nil else { return "approval_required" }
            guard bind(peer: peer, client: client.id, persistent: true, label: client.label,
                       leaf: leaf, helperHash: helperHash) else { return "unavailable" }
            trust.touch(client.id)
            trusted = trust.clients
        case .unknown, .expired, .hostChanged:
            guard let window = approval, ContinuousClock.now < window.deadline, context != nil else {
                awaitingApproval = claim.label
                return "approval_required"
            }
            var client = UUID(), persistent = false
            if claim.persistent, let host {
                do {
                    client = try trust.trust(publicKey: claim.publicKey, label: claim.label, host: host).id
                    persistent = true
                } catch AgentTrustStore.Failure.full {
                    status = "기억한 에이전트가 \(AgentTrustStore.maxClients)곳이라 더 추가할 수 없습니다. 쓰지 않는 에이전트를 잊은 뒤 다시 연결하세요."
                    return "unavailable"
                } catch {
                    // Could not be stored: connected for this run only.
                }
                trusted = trust.clients
            }
            guard bind(peer: peer, client: client, persistent: persistent, label: claim.label,
                       leaf: leaf, helperHash: helperHash) else { return "unavailable" }
            if !persistent { status = "이 에이전트는 기억할 수 없어 이번 실행 동안만 연결됩니다." }
        }
        return bound(peer)
    }

    /// The program that launched the helper, as far as the system can tell.
    private static func hostIdentity(_ peer: LocalInstructionPeer) -> String? {
        guard let parent = peer.parentPID() else { return nil }
        if let signed = AgentPeerSigning.teamSignedIdentity(pid: parent) { return "signed:" + signed }
        return peer.parentExecutable().map { "path:" + $0 }
    }

    private func bind(peer: LocalInstructionPeer, client: UUID, persistent: Bool, label: String,
                      leaf: String, helperHash: Data) -> Bool {
        let pid = peer.pid
        guard LocalInstructionPeer.current(pid: pid) == peer else { return false }
        let next = Pair(client: client, persistent: persistent, label: label, peer: peer,
                        hostPath: peer.parentExecutable(), leaf: leaf, helperHash: helperHash)
        pair = next
        let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watcher.setEventHandler { [weak self] in
            guard let self, self.pair?.id == next.id else { return }
            self.dropBinding(keepSelection: next.persistent)
        }
        watch = watcher
        watcher.resume()
        if LocalInstructionPeer.current(pid: pid) != peer { dropBinding(keepSelection: persistent); return false }
        status = ""
        awaitingApproval = nil
        closeApprovalWindow()
        activateReceive()
        guard receiving else { dropBinding(keepSelection: persistent); return false }
        return true
    }

    /// An explicit choice is consumed by one verified live helper, never by a
    /// default highlight. It is not persisted or carried into another session.
    @discardableResult
    func select(_ snapshot: AgentInstructionSnapshot,
                current: @escaping @MainActor (String) -> AgentInstructionSnapshot?,
                deliveryGate: @escaping (@escaping () -> Void) -> Void = { $0() }) -> Bool {
        clearSelection()
        instructionScope = snapshot.selector
        guard snapshot.shareable else { note(.invalidInstruction); return false }
        guard pairingSocket != nil else { note(.pairingUnavailable); return false }
        let deadline = ContinuousClock.now.advanced(by: selectionWaiting)
        let pending = PendingSelection(snapshot: snapshot, current: current,
                                       deliveryGate: deliveryGate, deadline: deadline)
        pendingSelection = pending
        remembered = RememberedSelection(client: pair?.client, snapshot: snapshot, current: current,
                                         deliveryGate: deliveryGate)
        if receiving {
            activatePending()
            return selectionStatus == .active
        }
        note(.waitingForHelper)
        pendingTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, self.pendingSelection?.id == pending.id else { return }
            self.clearSelection()
            self.note(.expired)
        }
        return true
    }

    private func activatePending() {
        guard receiving, let pair else { return }
        guard let pending = pendingSelection else { resumeSelection(for: pair); return }
        cancelPending()
        guard ContinuousClock.now < pending.deadline else { remembered = nil; note(.expired); return }
        guard pending.current(pending.snapshot.selector) == pending.snapshot else { remembered = nil; note(.changed); return }
        guard share(pending.snapshot, deliveryGate: pending.deliveryGate) else {
            note(.instructionGrantFailed)
            return
        }
        remembered?.client = pair.client
        note(.active)
    }

    /// The same approved client is back. It may read again only the exact saved
    /// revision the user chose for it; anything else stays blocked and visible.
    private func resumeSelection(for pair: Pair) {
        guard shared == nil, let kept = remembered, instructionScope == kept.snapshot.selector else { return }
        guard pair.persistent, kept.client == pair.client else { note(.waitingForHelper); return }
        guard kept.current(kept.snapshot.selector) == kept.snapshot else { remembered = nil; note(.changed); return }
        guard share(kept.snapshot, deliveryGate: kept.deliveryGate) else { note(.instructionGrantFailed); return }
        note(.active)
    }

    func rejectSelection(_ selector: String, reason: SelectionStatus) {
        clearSelection()
        instructionScope = selector
        note(reason)
    }

    func revokeSelection() {
        clearSelection()
        instructionScope = nil
        note(.canceled)
    }

    private func clearSelection() {
        cancelPending()
        stopShare()
        remembered = nil
        receiptNotice = nil
    }

    private func cancelPending() {
        pendingTask?.cancel(); pendingTask = nil
        pendingSelection = nil
    }

    private func note(_ change: SelectionStatus) {
        selectionStatus = change
        selectionDiagnostics.append(change)
        if selectionDiagnostics.count > 12 { selectionDiagnostics.removeFirst(selectionDiagnostics.count - 12) }
    }

    func share(_ snapshot: AgentInstructionSnapshot,
               deliveryGate: @escaping (@escaping () -> Void) -> Void = { $0() }) -> Bool {
        guard shared == nil, let pair, snapshot.shareable else { return false }
        // Lasts until the selection is changed, cleared or invalidated, or the
        // client goes away. Each read is still proven separately and expires.
        let socket = LocalApprovedSocket(peer: pair.peer, endpoint: "i.sock", directory: directory,
                                         lifetime: nil, maxFrame: 128,
                                         verified: Self.verifier(leaf: pair.leaf, hash: pair.helperHash),
                                         deliveryGate: deliveryGate, didDeliver: { bytes in
            guard let reply = Self.decode(bytes), let token = Self.uuid(reply["proof"]),
                  let epoch = Self.uuid(reply["proof_epoch"]) else { return }
            pair.proofs.delivered(token, snapshot: snapshot, epoch: epoch)
        }) { bytes, _ in
            guard let request = Self.decode(bytes), Self.isV2(request["schema_version"]) else { return nil }
            let keys = Set(request.keys)
            guard keys == ["schema_version"] ||
                  (keys == ["profile", "schema_version"] && request["profile"] as? String == snapshot.selector) else {
                return nil
            }
            let reply: [String: Any] = [
                "schema_version": 2, "profile": snapshot.selector, "revision": snapshot.generation.uuidString.lowercased(),
                "body_sha256": snapshot.digest, "instructions": snapshot.text, "proof": UUID().uuidString,
                "proof_epoch": pair.proofs.epochForSend().uuidString,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]),
                  data.count + 1 <= 52 * 1024 else { return nil }
            return data
        }
        guard socket.start() else {
            status = socket.requiresPathInspection ? LocalApprovedSocket.unknownPathMessage : "지시 조회 소켓을 시작할 수 없습니다."
            return false
        }
        status = ""
        shareSocket = socket
        shared = snapshot
        return true
    }

    /// The explicit approval. It turns receipt on for clients approved earlier
    /// and lets one new client in before the waiting time runs out.
    @discardableResult
    func enableReceive(current: @escaping @MainActor (String) -> AgentInstructionSnapshot?,
                       workspace: ExplanationDraftWorkspace) -> Bool {
        // startPairing() leaves the specific reason in `status`; keep it visible.
        if pairingSocket == nil, !startPairing() {
            if status.isEmpty { status = "MCP 연결을 시작할 수 없습니다." }
            return false
        }
        guard !locked, !receiving, approval == nil else { return false }
        context = ReceiveContext(current: current, workspace: workspace)
        dropIfGone()
        setAutoReceive(true)
        // Only the user's own click starts a fresh allowance; a client that
        // reconnects by itself keeps the one it had.
        rate = AgentRateLimit()
        if pair != nil {
            activateReceive()
            return receiving
        }
        openApprovalWindow()
        return true
    }

    /// While waiting for an approved client, let a different, new one in instead.
    func allowNewAgent() {
        guard autoReceive, !locked, pair == nil, context != nil, approval == nil else { return }
        openApprovalWindow()
    }

    private func openApprovalWindow() {
        let window = ApprovalWindow(deadline: ContinuousClock.now.advanced(by: selectionWaiting))
        approval = window
        waitingForReceiveHelper = true
        status = ""
        approvalTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: window.deadline) } catch { return }
            guard let self, self.approval?.id == window.id else { return }
            self.closeApprovalWindow()
            // Approved clients may still come back; with none there is nothing to wait for.
            guard self.trusted.isEmpty else { return }
            self.setAutoReceive(false)
            self.clearSelection()
            self.instructionScope = nil
            self.note(.notSelected)
            self.status = "연결 대기 시간이 지났습니다."
        }
    }

    private func closeApprovalWindow() {
        approvalTask?.cancel(); approvalTask = nil
        approval = nil
        waitingForReceiveHelper = false
    }

    private func setAutoReceive(_ value: Bool) {
        trust.setAutoReceive(value)
        autoReceive = value
    }

    private func activateReceive() {
        guard let context, pair != nil, autoReceive, !locked, !receiving else { return }
        guard receive(current: context.current, workspace: context.workspace) else { return }
        activatePending()
    }

    /// The user turning receipt off. It stays off, also for approved clients and
    /// after a restart, until the user turns it on again.
    func disableReceive() {
        closeApprovalWindow()
        setAutoReceive(false)
        stopReceipt()
        clearSelection()
        instructionScope = nil
        note(.notSelected)
        status = ""
        receiptNotice = nil
        awaitingApproval = nil
    }

    /// Stop receiving while the screen is locked or another user is active.
    /// Afterwards a client has to prove its key again before anything resumes.
    func setLocked(_ value: Bool) {
        guard locked != value else { return }
        locked = value
        guard value else { status = ""; return }
        challenges.removeAll()
        closeApprovalWindow()
        if let pair { dropBinding(keepSelection: pair.persistent) }
        status = "화면이 잠겨 대본 받기를 멈췄습니다. 잠금을 풀면 기억한 에이전트가 다시 연결됩니다."
    }

    /// Forget an approved client on this Mac: stop it now, refuse anything of
    /// its still in flight, and refuse its key from here on.
    func forget(_ client: UUID) {
        guard let record = trust.clients.first(where: { $0.id == client }) else { return }
        challenges.removeAll { $0.keyID == record.keyID }
        if pair?.client == client { dropBinding(keepSelection: false) }
        if remembered?.client == client {
            clearSelection()
            instructionScope = nil
            note(.notSelected)
        }
        receiptKeys[client] = nil
        if !trust.forget(client) { status = "잊은 내용을 저장하지 못했습니다. 앱을 다시 열면 이 에이전트가 다시 보일 수 있습니다." }
        trusted = trust.clients
    }

    private func receive(current: @escaping @MainActor (String) -> AgentInstructionSnapshot?,
                 workspace: ExplanationDraftWorkspace) -> Bool {
        guard !receiving, let pair else { return false }
        // No clock ends this: it lasts until the user turns it off, the screen
        // locks, the client is forgotten, or the client process goes away.
        let generation = UUID()
        let socket = LocalApprovedSocket(peer: pair.peer, endpoint: "d.sock", directory: directory,
                                         lifetime: nil, maxFrame: AgentLimits.frameBytes,
                                         verified: Self.verifier(leaf: pair.leaf, hash: pair.helperHash)) { [weak self] bytes, active in
            guard let request = Self.decode(bytes) else { return Self.reply("invalid") }
            guard Self.isV2(request["schema_version"]) else { return Self.reply("upgrade_required") }
            let base: Set<String> = ["schema_version", "idempotency_key", "display_text"]
            let linkedKeys: Set<String> = ["profile", "revision", "body_sha256", "proof"]
            var keys = Set(request.keys)
            keys.remove("speech_text")
            let linked = keys == base.union(linkedKeys)
            guard (linked || keys == base),
                  let clientKey = request["idempotency_key"] as? String,
                  let display = request["display_text"] as? String,
                  (request["speech_text"] == nil || request["speech_text"] is String),
                  ExplanationDraft(id: clientKey, display: display, speech: request["speech_text"] as? String) != nil else {
                return Self.reply("invalid")
            }
            let speech = request["speech_text"] as? String
            let response = Reply()
            let signal = DispatchSemaphore(value: 0)
            let responseDeadline = DispatchTime.now() + .milliseconds(750)
            DispatchQueue.main.async {
                defer { signal.signal() }
                guard DispatchTime.now() < responseDeadline, active(), let self,
                      self.pair?.id == pair.id, self.receiving, !self.locked,
                      self.receiptGeneration == generation else { return }
                let origin: AgentDraftOrigin?
                if linked {
                    guard let selector = request["profile"] as? String, let revision = Self.uuid(request["revision"]),
                          let bodyHash = request["body_sha256"] as? String, let token = Self.uuid(request["proof"]),
                          let proof = pair.proofs.resolve(token, selector: selector, revision: revision, digest: bodyHash),
                          let shared = self.shared, shared.selector == selector,
                          let current = current(selector), current == shared,
                          current.generation == proof.revision, current.digest == proof.digest,
                          self.receiving, self.receiptGeneration == generation, active() else {
                        response.set("unproven"); return
                    }
                    origin = AgentDraftOrigin(principal: pair.client, agentLabel: pair.label, selector: selector,
                                              revision: revision, bodyHash: bodyHash, older: false)
                } else {
                    // This is enforced here, not just by a potentially stale MCP tool status.
                    // A selected-but-not-yet-shareable request also cannot fall back generically.
                    guard self.instructionScope == nil, self.shared == nil, self.pendingSelection == nil else {
                        self.receiptNotice = self.shared != nil
                            ? "에이전트가 지시를 읽지 않고 대본을 보내 받지 않았습니다."
                            : "선택한 지시가 공유되고 있지 않아 대본을 받지 않았습니다. 지시를 다시 선택하거나 ‘사용 안 함’으로 바꾸세요."
                        response.set("instruction_required"); return
                    }
                    origin = nil
                }
                let scopedKey = AgentBytes.hash(Data((pair.client.uuidString + "\0" + clientKey).utf8))
                guard let draft = ExplanationDraft(id: scopedKey, display: display, speech: speech,
                                                   provenance: origin) else {
                    response.set("invalid"); return
                }
                let fingerprint = draft.fingerprint
                if let previous = self.receiptKeys[pair.client]?.first(where: { $0.key == clientKey }) {
                    response.set(previous.digest == fingerprint ? "duplicate" : "conflict"); return
                }
                switch workspace.receiveBlock() {
                case .documents:
                    self.receiptNotice = "열린 대본이 \(ExplanationDraftWorkspace.maxDocuments)개라 새 대본을 받지 않았습니다. 탭을 닫으면 에이전트가 다시 보낼 수 있습니다."
                    response.set("busy"); return
                case .bytes:
                    self.receiptNotice = "열어 둔 글이 너무 커서 새 대본을 받지 않았습니다. 글을 줄이거나 다른 곳에 옮긴 뒤 다시 받으세요."
                    response.set("editor_full"); return
                case nil: break
                }
                guard self.rate.canAccept() else {
                    self.receiptNotice = "대본이 너무 자주 와서 잠시 받지 않았습니다."
                    response.set("rate_limited"); return
                }
                let result = workspace.receiveDocument(draft)
                if result == .accepted {
                    var known = self.receiptKeys[pair.client] ?? []
                    known.append((clientKey, fingerprint))
                    // Oldest keys fall out, so a connection kept open all day never fills up.
                    if known.count > AgentLimits.receiptKeys { known.removeFirst(known.count - AgentLimits.receiptKeys) }
                    self.receiptKeys[pair.client] = known
                    self.rate.mark()
                    self.receiptNotice = nil
                }
                response.set(result.rawValue)
            }
            guard signal.wait(timeout: responseDeadline) == .success else { return Self.reply("unconfirmed") }
            return Self.reply(response.get())
        }
        guard socket.start() else {
            status = socket.requiresPathInspection ? LocalApprovedSocket.unknownPathMessage : "대본 받기 소켓을 시작할 수 없습니다."
            return false
        }
        status = ""
        receiptSocket = socket
        receiving = true
        receiptGeneration = generation
        workspace.setReceiver(pair.peer.pid)
        receiptWorkspace = workspace
        return true
    }

    private weak var receiptWorkspace: ExplanationDraftWorkspace?

    func invalidate(_ selector: String, deleted: Bool) {
        guard instructionScope == selector else { return }
        if deleted {
            clearSelection()
            instructionScope = nil
            note(.notSelected)
            // Receipt widens to unlinked drafts here, so say so where the user is looking.
            if receiving { status = "선택한 지시가 삭제되어 이제 지시 없이 대본을 받습니다." }
            return
        }
        if shared?.selector == selector || pendingSelection?.snapshot.selector == selector {
            clearSelection()
            note(.changed)
        }
        // Previously received documents remain editable.
    }

    func stopShare() {
        shareSocket?.stop(); shareSocket = nil
        pair?.proofs.clear()
        shared = nil
    }

    func stopReceipt(workspace: ExplanationDraftWorkspace? = nil) {
        receiptSocket?.stop(); receiptSocket = nil
        pair?.proofs.clear()
        receiving = false
        receiptGeneration = nil
        (workspace ?? receiptWorkspace)?.setReceiver(nil)
        receiptWorkspace = nil
    }

    /// The user disconnecting: receipt stops now and stays off. The approval is
    /// kept, so turning receipt on again needs no new pairing. See `forget`.
    func disconnect() {
        closeApprovalWindow()
        setAutoReceive(false)
        awaitingApproval = nil
        dropBinding(keepSelection: false)
    }

    /// The live process is gone or may no longer be served. For an approved
    /// client the user's instruction choice is kept in memory for its return.
    private func dropBinding(keepSelection: Bool) {
        watch?.cancel(); watch = nil
        let gone = pair
        stopReceipt()
        if keepSelection, instructionScope != nil {
            cancelPending()
            stopShare()
            note(.waitingForHelper)
        } else {
            clearSelection()
            instructionScope = nil
            note(.notSelected)
        }
        if let gone, !gone.persistent { receiptKeys[gone.client] = nil }
        pair = nil
        status = ""
        receiptNotice = nil
    }

    private nonisolated static func verifier(leaf: String, hash: Data) -> (Int32) -> Bool {
        { AgentPeerSigning.matches(socket: $0, identifier: AgentPeerSigning.helperID, leaf: leaf, expectedHash: hash) }
    }

    private nonisolated static func decode(_ bytes: Data) -> [String: Any]? {
        guard !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    private nonisolated static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    private nonisolated static func isV2(_ value: Any?) -> Bool { isSchema(value, 2) }

    private nonisolated static func isSchema(_ value: Any?, _ expected: Int) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number == NSNumber(value: expected)
    }

    private nonisolated static func reply(_ status: String) -> Data { Data("{\"status\":\"\(status)\"}".utf8) }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var fields = ["status": "disabled"]
        func set(_ value: String) { set(["status": value]) }
        func set(_ value: [String: String]) { lock.lock(); defer { lock.unlock() }; fields = value }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return fields["status"] ?? "disabled" }
        func data() -> Data {
            lock.lock(); defer { lock.unlock() }
            return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data("{\"status\":\"unavailable\"}".utf8)
        }
    }
}
