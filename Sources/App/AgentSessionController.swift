import Combine
import CryptoKit
import os
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
        case notSelected, waitingForHelper, active, canceled, expired, changed, chooseClient
        case legacySharing, catalogUnavailable, invalidInstruction, pairingUnavailable, instructionGrantFailed, draftGrantFailed

        var message: String {
            switch self {
            case .notSelected: return "공유하는 지시 없음 · 대본은 지시 없이 받습니다."
            case .waitingForHelper: return "선택됨 · 승인한 상대가 연결되면 공유됩니다."
            case .chooseClient: return "지시를 공유할 에이전트를 선택하세요."
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
            case .expired, .changed, .chooseClient, .legacySharing, .catalogUnavailable, .invalidInstruction, .pairingUnavailable,
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

    struct ApprovalRequest: Identifiable {
        let id = UUID()
        let label: String
        let host: String?
        let launcher: String?
        fileprivate let claim: Challenge
        fileprivate let leaf: String
        fileprivate let helperHash: Data
        fileprivate let deadline: ContinuousClock.Instant
        var helperPID: pid_t { claim.peer.pid }
    }

    struct Connection: Identifiable {
        enum State: String {
            case waiting, receiving, paused, locked, needsApproval
        }

        let id: UUID
        let label: String
        let host: String?
        let launcher: String?
        let helperPID: pid_t?
        let persistent: Bool
        let state: State
        let receiptEnabled: Bool
    }

    fileprivate struct Challenge {
        let peer: LocalInstructionPeer
        let publicKey: Data
        let keyID: String
        let label: String
        let host: String?
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

    private struct Pair {
        /// This binding of one live process.
        let id = UUID()
        /// The approved client; stable across reconnects when `persistent`.
        let client: UUID
        let persistent: Bool
        let label: String
        let peer: LocalInstructionPeer
        let hostPath: String?
        let host: String?
        let slot: Int
        let leaf: String
        let helperHash: Data
        let proofs = AgentDeliveryProofs()
    }

    private final class Binding {
        let pair: Pair
        let watch: DispatchSourceProcess
        var receipt: LocalApprovedSocket?
        var generation: UUID?
        var receiptEnabled = true

        init(pair: Pair, watch: DispatchSourceProcess) {
            self.pair = pair
            self.watch = watch
        }
    }

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var approvalRequests: [ApprovalRequest] = []
    @Published private(set) var shared: AgentInstructionSnapshot?
    @Published private(set) var receiving = false
    @Published private(set) var status = ""
    @Published private(set) var selectionStatus: SelectionStatus = .notSelected
    private(set) var selectionDiagnostics: [SelectionStatus] = []
    @Published private(set) var instructionScope: String?
    @Published private(set) var instructionClient: UUID?
    @Published private(set) var receiptNotice: String?
    private(set) lazy var pairingSupported = AgentPeerSigning.ownLeaf() != nil && bundledHelper() != nil

    var receiptBlockedBySelection: Bool {
        guard let client = instructionClient else { return false }
        return bindings[client]?.receipt != nil && instructionScope != nil && shared == nil
    }
    @Published private(set) var trusted: [AgentTrustedClient] = []
    @Published private(set) var autoReceive = false
    @Published private(set) var locked = false
    /// `off` only after the user turned receipt off; opening the Agent tab then
    /// leaves it off.
    @Published private(set) var receiptChoice: AgentReceiptChoice = .auto
    /// Receipt was saved as off by a version that could not tell why. Shown once.
    @Published private(set) var legacyReceiptOff = false
    @Published private(set) var pairingActive = false
    /// The Agent tab is selected and its window is on screen.
    @Published private(set) var presenceOpen = false
    /// The tab has been open for a while and no helper has shown up.
    @Published private(set) var noAgentSession = false

    struct Attempt {
        let at: Date
        let result: String
    }
    /// The latest reconnect result per remembered app, as the app saw it. Memory only.
    @Published private(set) var lastAttempts: [UUID: Attempt] = [:]
    private var readySequence = 0
    private var noSessionTask: Task<Void, Never>?
    private let noSessionDelay: Duration
    private let trust: AgentTrustStore
    private var context: ReceiveContext?
    private var challenges: [Challenge] = []
    private var approvalTasks: [UUID: Task<Void, Never>] = [:]
    private var blockedPeers: [LocalInstructionPeer] = []
    private var remembered: RememberedSelection?
    private var pendingSelection: PendingSelection?
    private var pendingTask: Task<Void, Never>?
    private let selectionWaiting: Duration
    private var pairingSocket: LocalApprovedSocket?
    private var shareSocket: LocalApprovedSocket?
    private var bindings: [UUID: Binding] = [:]
    private var rates: [UUID: AgentRateLimit] = [:]
    /// A stored draft also deduplicates after the app restarts.
    private var receiptKeys: [UUID: [(key: String, digest: SHA256.Digest)]] = [:]
    private let directory: String
    private let bundledHelper: () -> Data?

    init(directory: String = LocalApprovedSocket.defaultDirectory,
         bundledHelper: @escaping () -> Data? = AgentPeerSigning.bundledHelperHash,
         selectionWaiting: Duration = .seconds(90),
         noSessionDelay: Duration = .seconds(5),
         trust: AgentTrustStore = AgentTrustStore(
            url: TTSRuntime.applicationSupport().appendingPathComponent("agent-clients.json"))) {
        self.directory = directory
        self.bundledHelper = bundledHelper
        self.selectionWaiting = selectionWaiting
        self.noSessionDelay = noSessionDelay
        self.trust = trust
        trusted = trust.clients
        autoReceive = trust.autoReceive
        receiptChoice = trust.receiptChoice
        legacyReceiptOff = trust.legacyReceiptOff
        refreshConnections()
    }

    /// Where received drafts go. Needed before an approved client can resume
    /// without a click, so the app sets it at launch.
    func configure(current: @escaping @MainActor (String) -> AgentInstructionSnapshot?,
                   workspace: ExplanationDraftWorkspace) {
        let first = context == nil
        context = ReceiveContext(current: current, workspace: workspace)
        if first { postReady("configure") }
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
            // Identify the launching app here, off the main thread: validating a large
            // agent binary can take longer than the main-thread deadline below. The
            // main-thread checks then reuse the cached result.
            _ = AgentPeerSigning.registeredHost(pid: peer.pid)
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
            guard signal.wait(timeout: deadline) == .success else {
                let op = request["op"] as? String ?? "?"
                Log.agent.error("[AGENT-CONN] pairing op=\(op, privacy: .public) pid=\(peer.pid, privacy: .public) result=unavailable reason=main_deadline")
                return Self.reply("unavailable")
            }
            return response.data()
        }
        guard socket.start() else {
            status = socket.requiresPathInspection ? LocalApprovedSocket.unknownPathMessage : "다른 앱 인스턴스가 자동 연결을 사용 중일 수 있습니다."
            return false
        }
        pairingSocket = socket
        pairingActive = true
        if status == LocalApprovedSocket.unknownPathMessage || status.hasPrefix("다른 앱 인스턴스") { status = "" }
        postReady("launch")
        return true
    }

    /// Quitting drops live leases while preserving the user's saved choices.
    func stopPairing() {
        pairingSocket?.stop(); pairingSocket = nil
        pairingActive = false
        clearApprovals()
        for client in Array(bindings.keys) { dropBinding(client, keepSelection: false) }
    }

    private func refreshConnections() {
        let receivingPairs = bindings.values.filter { $0.receipt != nil }
        let hasReceipt = !receivingPairs.isEmpty
        if receiving != hasReceipt { receiving = hasReceipt }
        if noAgentSession, !bindings.isEmpty { noAgentSession = false }
        context?.workspace.setReceiver(receivingPairs.first?.pair.peer.pid)
        let remembered = trusted.map { record in
            let live = bindings[record.id]
            let state = Self.isRegisteredHost(record.host)
                ? connectionState(live, receiptEnabled: record.receiptEnabled) : .needsApproval
            return Connection(id: record.id, label: record.label, host: record.host,
                              launcher: live?.pair.hostPath, helperPID: live?.pair.peer.pid, persistent: true, state: state,
                              receiptEnabled: record.receiptEnabled)
        }
        let sessionOnly = bindings.values.filter { !$0.pair.persistent }.map { binding in
            Connection(id: binding.pair.client, label: binding.pair.label, host: nil,
                       launcher: binding.pair.hostPath, helperPID: binding.pair.peer.pid, persistent: false,
                       state: connectionState(binding, receiptEnabled: binding.receiptEnabled),
                       receiptEnabled: binding.receiptEnabled)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        connections = remembered + sessionOnly
    }

    private static func isRegisteredHost(_ host: String) -> Bool {
        host.hasPrefix(AgentPairing.registeredHostPrefix)
    }

    private func connectionState(_ binding: Binding?, receiptEnabled: Bool) -> Connection.State {
        if locked { return .locked }
        if !receiptEnabled || !autoReceive { return .paused }
        return binding?.receipt == nil ? .waiting : .receiving
    }

    private func dropIfGone() {
        for (client, binding) in Array(bindings) where LocalInstructionPeer.current(pid: binding.pair.peer.pid) != binding.pair.peer {
            dropBinding(client, keepSelection: binding.pair.persistent)
        }
        for request in approvalRequests where LocalInstructionPeer.current(pid: request.claim.peer.pid) != request.claim.peer {
            removeApproval(request.id)
        }
        blockedPeers.removeAll { LocalInstructionPeer.current(pid: $0.pid) != $0 }
    }

    private func binding(for peer: LocalInstructionPeer) -> Binding? {
        bindings.values.first { $0.pair.peer == peer }
    }

    private func bound(_ binding: Binding) -> [String: String] {
        guard binding.receipt != nil else { return ["status": "disabled"] }
        let status: String
        if instructionClient != binding.pair.client { status = "receiving_only" }
        else if shared != nil { status = "ready" }
        else { status = instructionScope != nil ? "instruction_required" : "receiving_only" }
        return ["status": status, "slot": String(binding.pair.slot)]
    }

    private func connectionStatus(for peer: LocalInstructionPeer) -> [String: String] {
        dropIfGone()
        if locked { return ["status": "locked"] }
        if blockedPeers.contains(peer) { return ["status": "revoked"] }
        guard let binding = binding(for: peer) else { return ["status": "identify"] }
        if let host = binding.pair.host, AgentPeerSigning.registeredHost(pid: peer.pid) != host {
            dropBinding(binding.pair.client, keepSelection: true)
            return ["status": "identify"]
        }
        return bound(binding)
    }

    /// A fresh nonce is bound to the verified live helper and its current host.
    private func challenge(peer: LocalInstructionPeer, publicKey: Data, label: String, persistent: Bool) -> [String: String] {
        dropIfGone()
        if locked { return ["status": "locked"] }
        if blockedPeers.contains(peer) { return ["status": "revoked"] }
        guard let keyID = AgentPairingProof.keyID(publicKey) else { return ["status": "invalid"] }
        let host = persistent ? AgentPeerSigning.registeredHost(pid: peer.pid) : nil
        if trust.lookup(keyID: keyID, host: host ?? "") == .revoked { return ["status": "revoked"] }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return ["status": "unavailable"] }
        let nonce = Data(bytes).base64EncodedString()
        let now = ContinuousClock.now
        challenges.removeAll { $0.peer == peer || $0.deadline <= now || LocalInstructionPeer.current(pid: $0.peer.pid) != $0.peer }
        guard challenges.count < AgentTrustStore.maxClients else { return ["status": "unavailable"] }
        challenges.append(Challenge(peer: peer, publicKey: publicKey, keyID: keyID, label: label, host: host,
                                    nonce: nonce, deadline: now.advanced(by: .seconds(5))))
        return ["status": "challenge", "nonce": nonce]
    }

    private func prove(peer: LocalInstructionPeer, nonce: String, signature: Data, leaf: String, helperHash: Data) -> [String: String] {
        guard let index = challenges.firstIndex(where: { $0.peer == peer && $0.nonce == nonce }) else { return ["status": "invalid"] }
        let claim = challenges.remove(at: index)
        guard ContinuousClock.now < claim.deadline,
              AgentPairingProof.verify(publicKey: claim.publicKey, signature: signature,
                                       message: AgentPairing.message(appID: AgentPeerSigning.appID, nonce: nonce,
                                                                     keyID: claim.keyID)),
              Self.sameHost(as: claim) else { return ["status": "invalid"] }
        dropIfGone()
        if locked { return ["status": "locked"] }
        if blockedPeers.contains(peer) { return ["status": "revoked"] }
        if let binding = binding(for: peer) { return bound(binding) }
        let lookup = trust.lookup(keyID: claim.keyID, host: claim.host ?? "")
        let outcome: [String: String]
        switch lookup {
        case .revoked: outcome = ["status": "revoked"]
        case .trusted(let record) where claim.host != nil:
            if !autoReceive || !record.receiptEnabled { outcome = ["status": "disabled"] }
            else if bindings[record.id] != nil { outcome = ["status": "other_agent"] }
            else if let binding = bind(claim, client: record.id, label: record.label, leaf: leaf, helperHash: helperHash) {
                trust.touch(record.id)
                trusted = trust.clients
                refreshConnections()
                outcome = bound(binding)
            } else { outcome = ["status": "unavailable"] }
        default:
            outcome = ["status": requestApproval(claim, leaf: leaf, helperHash: helperHash)]
        }
        Self.logConnect(claim: claim, lookup: lookup, result: outcome["status"] ?? "?")
        if case .trusted(let record) = lookup {
            lastAttempts[record.id] = Attempt(at: Date(), result: outcome["status"] ?? "?")
        }
        return outcome
    }

    private static func describe(_ lookup: AgentTrustStore.Lookup) -> String {
        switch lookup {
        case .trusted: return "trusted"
        case .unknown: return "unknown"
        case .revoked: return "revoked"
        case .hostChanged: return "host_changed"
        }
    }

    /// One line per reconnect: whether the app was recognized and what it got.
    private static func logConnect(claim: Challenge, lookup: AgentTrustStore.Lookup, result: String) {
        let host = claim.host ?? "unverified"
        let key = String(claim.keyID.prefix(12))
        Log.agent.info("[AGENT-CONN] connect host=\(host, privacy: .public) key=\(key, privacy: .public) lookup=\(describe(lookup), privacy: .public) result=\(result, privacy: .public)")
    }

    private static func sameHost(as claim: Challenge) -> Bool {
        guard LocalInstructionPeer.current(pid: claim.peer.pid) == claim.peer else { return false }
        if let host = claim.host { return AgentPeerSigning.registeredHost(pid: claim.peer.pid) == host }
        return true
    }

    private func requestApproval(_ claim: Challenge, leaf: String, helperHash: Data) -> String {
        if let previous = approvalRequests.first(where: { $0.claim.peer == claim.peer }) {
            if previous.claim.keyID == claim.keyID, previous.host == claim.host, previous.label == claim.label,
               ContinuousClock.now < previous.deadline { return "approval_required" }
            removeApproval(previous.id)
        }
        guard approvalRequests.count < AgentTrustStore.maxClients else { return "unavailable" }
        let request = ApprovalRequest(label: claim.label, host: claim.host, launcher: claim.peer.parentExecutable(),
                                      claim: claim, leaf: leaf, helperHash: helperHash,
                                      deadline: ContinuousClock.now.advanced(by: selectionWaiting))
        approvalRequests.append(request)
        approvalTasks[request.id] = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: request.deadline) } catch { return }
            self?.removeApproval(request.id)
        }
        return "approval_required"
    }

    private func removeApproval(_ id: UUID) {
        approvalTasks.removeValue(forKey: id)?.cancel()
        approvalRequests.removeAll { $0.id == id }
    }

    private func clearApprovals() {
        approvalTasks.values.forEach { $0.cancel() }
        approvalTasks.removeAll()
        approvalRequests.removeAll()
        challenges.removeAll()
    }

    @discardableResult
    func approve(_ id: UUID) -> Bool {
        dropIfGone()
        guard let request = approvalRequests.first(where: { $0.id == id }),
              autoReceive, !locked, context != nil else { return false }
        let attachToSelection = connections.allSatisfy { $0.state == .needsApproval } && approvalRequests.count == 1 &&
            instructionClient == nil && pendingSelection != nil
        removeApproval(id)
        let claim = request.claim
        guard ContinuousClock.now < request.deadline, Self.sameHost(as: claim),
              !blockedPeers.contains(claim.peer), binding(for: claim.peer) == nil,
              trust.lookup(keyID: claim.keyID, host: claim.host ?? "") != .revoked else { return false }
        var client = UUID()
        if let host = claim.host {
            switch trust.lookup(keyID: claim.keyID, host: host) {
            case .trusted(let record):
                client = record.id
                guard bindings[client] == nil, trust.setReceiptEnabled(true, for: client) else { return false }
            default:
                do {
                    let record = try trust.trust(publicKey: claim.publicKey, label: claim.label, host: host)
                    client = record.id
                    // A new approved key for this host replaces its previous live lease and share.
                    if let previous = bindings[client]?.pair {
                        block(previous.peer)
                        dropBinding(client, keepSelection: false)
                    } else {
                        clearSelection(for: client, keepSelection: false)
                    }
                    clearApprovals(for: record)
                } catch {
                    status = "이 에이전트의 승인을 저장하지 못했습니다. 기억한 연결과 저장 공간을 확인하세요."
                    Log.agent.error("[AGENT-CONN] approve host=\(host, privacy: .public) result=store_failed error=\(String(describing: error), privacy: .public)")
                    return false
                }
            }
            trusted = trust.clients
            for other in approvalRequests where other.claim.keyID == claim.keyID && other.host == host {
                removeApproval(other.id)
            }
        }
        if attachToSelection {
            instructionClient = client
            remembered?.client = client
        }
        guard bind(claim, client: client, label: request.label, leaf: request.leaf, helperHash: request.helperHash) != nil else {
            refreshConnections()
            return false
        }
        if claim.host == nil { status = "호스트를 확인할 수 없어 이번 실행 동안만 허용했습니다." }
        let scope = claim.host == nil ? "this_run" : "persistent"
        Log.agent.info("[AGENT-CONN] approve host=\(claim.host ?? "unverified", privacy: .public) client=\(client.uuidString, privacy: .public) scope=\(scope, privacy: .public) result=ok")
        return true
    }

    private func bind(_ claim: Challenge, client: UUID, label: String, leaf: String, helperHash: Data) -> Binding? {
        let peer = claim.peer
        let usedSlots = Set(bindings.values.map { $0.pair.slot })
        guard let slot = (0..<AgentTrustStore.maxClients).first(where: { !usedSlots.contains($0) }),
              bindings[client] == nil, LocalInstructionPeer.current(pid: peer.pid) == peer else { return nil }
        let next = Pair(client: client, persistent: claim.host != nil, label: label, peer: peer,
                        hostPath: peer.parentExecutable(), host: claim.host, slot: slot, leaf: leaf, helperHash: helperHash)
        let watcher = DispatchSource.makeProcessSource(identifier: peer.pid, eventMask: .exit, queue: .main)
        watcher.setEventHandler { [weak self] in
            guard let self, self.bindings[client]?.pair.id == next.id else { return }
            self.dropBinding(client, keepSelection: next.persistent)
            // Another session of the same app may have been told other_agent.
            self.postReady("binding_drop")
        }
        let binding = Binding(pair: next, watch: watcher)
        bindings[client] = binding
        watcher.resume()
        if LocalInstructionPeer.current(pid: peer.pid) != peer || !activateReceive(binding) {
            dropBinding(client, keepSelection: next.persistent)
            return nil
        }
        return binding
    }

    func chooseInstructionClient(_ client: UUID?) {
        guard client == nil || connections.contains(where: { $0.id == client && $0.state != .needsApproval }),
              instructionClient != client else { return }
        revokeSelection()
        instructionClient = client
    }

    /// One saved revision is scoped to the chosen client.
    @discardableResult
    func select(_ snapshot: AgentInstructionSnapshot,
                current: @escaping @MainActor (String) -> AgentInstructionSnapshot?,
                deliveryGate: @escaping (@escaping () -> Void) -> Void = { $0() }) -> Bool {
        let eligible = connections.filter { $0.state != .needsApproval }
        if instructionClient == nil, eligible.count > 1 {
            note(.chooseClient)
            return false
        }
        clearSelection()
        instructionClient = instructionClient ?? eligible.first?.id
        instructionScope = snapshot.selector
        guard snapshot.shareable else { note(.invalidInstruction); return false }
        guard pairingSocket != nil else { note(.pairingUnavailable); return false }
        let deadline = ContinuousClock.now.advanced(by: selectionWaiting)
        let pending = PendingSelection(snapshot: snapshot, current: current,
                                       deliveryGate: deliveryGate, deadline: deadline)
        pendingSelection = pending
        remembered = RememberedSelection(client: instructionClient, snapshot: snapshot, current: current,
                                         deliveryGate: deliveryGate)
        if let target = instructionClient, let binding = bindings[target], binding.receipt != nil {
            activatePending(binding)
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

    private func activatePending(_ binding: Binding) {
        let pair = binding.pair
        guard binding.receipt != nil, instructionClient == pair.client else { return }
        guard let pending = pendingSelection else { resumeSelection(for: pair); return }
        cancelPending()
        guard ContinuousClock.now < pending.deadline else { remembered = nil; note(.expired); return }
        guard pending.current(pending.snapshot.selector) == pending.snapshot else { remembered = nil; note(.changed); return }
        guard share(pending.snapshot, with: pair, deliveryGate: pending.deliveryGate) else {
            note(.instructionGrantFailed)
            return
        }
        note(.active)
    }

    private func resumeSelection(for pair: Pair) {
        guard shared == nil, pair.persistent, let kept = remembered, kept.client == pair.client,
              instructionScope == kept.snapshot.selector else { return }
        guard kept.current(kept.snapshot.selector) == kept.snapshot else { remembered = nil; note(.changed); return }
        guard share(kept.snapshot, with: pair, deliveryGate: kept.deliveryGate) else { note(.instructionGrantFailed); return }
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

    private func share(_ snapshot: AgentInstructionSnapshot, with pair: Pair,
                       deliveryGate: @escaping (@escaping () -> Void) -> Void) -> Bool {
        guard shared == nil, instructionClient == pair.client, snapshot.shareable else { return false }
        // Lasts until the selection is changed, cleared or invalidated, or the
        // client goes away. Each read is still proven separately and expires.
        let socket = LocalApprovedSocket(peer: pair.peer, endpoint: AgentPairing.instructionEndpoint(slot: pair.slot), directory: directory,
                                         lifetime: nil, maxFrame: 128,
                                         verified: Self.verifier(for: pair),
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

    /// The master switch pauses receipts for all clients while keeping their approvals.
    @discardableResult
    func enableReceive(current: @escaping @MainActor (String) -> AgentInstructionSnapshot?,
                       workspace: ExplanationDraftWorkspace) -> Bool {
        configure(current: current, workspace: workspace)
        guard turnOnReceive(byUser: true, reason: "user") else { return false }
        // Turning receipt back on by hand starts every client's allowance over.
        rates.removeAll()
        return true
    }

    private func turnOnReceive(byUser: Bool, reason: String) -> Bool {
        guard !locked, startPairing(), setAutoReceive(true, byUser: byUser) else { return false }
        Log.agent.info("[AGENT-CONN] receipt choice=\(self.receiptChoice.rawValue, privacy: .public) set=on reason=\(reason, privacy: .public)")
        dropIfGone()
        for binding in bindings.values { _ = activateReceive(binding) }
        refreshConnections()
        postReady(byUser ? "receipt_on" : reason)
        return true
    }

    private func setAutoReceive(_ value: Bool, byUser: Bool = true) -> Bool {
        let saved = trust.setAutoReceive(value, byUser: byUser)
        if !saved { status = "대본 받기 설정을 저장하지 못했습니다." }
        if saved || !value { autoReceive = value }
        receiptChoice = trust.receiptChoice
        legacyReceiptOff = trust.legacyReceiptOff
        return saved
    }

    /// The Agent tab opened or closed. Opening it is the user's sign to be
    /// connected: receipt turns on unless the user turned it off, and live helpers
    /// are asked to prove themselves again. Closing it changes nothing; approved
    /// apps keep sending while the window is closed.
    func setPresence(_ open: Bool, detail: String = "") {
        guard presenceOpen != open else { return }
        presenceOpen = open
        Log.agent.info("[AGENT-CONN] presence state=\(open ? "open" : "closed", privacy: .public) \(detail, privacy: .public)")
        noSessionTask?.cancel(); noSessionTask = nil
        noAgentSession = false
        guard open else { return }
        if pairingSocket == nil { _ = startPairing() }
        if !autoReceive {
            if locked {
                Log.agent.info("[AGENT-CONN] receipt choice=\(self.receiptChoice.rawValue, privacy: .public) skip reason=locked")
            } else if receiptChoice == .off {
                Log.agent.info("[AGENT-CONN] receipt choice=off skip reason=\(self.legacyReceiptOff ? "migration" : "user_off", privacy: .public)")
            } else if context != nil {
                _ = turnOnReceive(byUser: false, reason: "tab_open")
            }
        }
        postReady("tab_open")
        let delay = noSessionDelay
        noSessionTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(for: delay) } catch { return }
            guard let self, self.presenceOpen else { return }
            self.noAgentSession = self.bindings.isEmpty && self.approvalRequests.isEmpty
            if self.noAgentSession { Log.agent.info("[AGENT-CONN] presence no_session after_ms=\(delay.components.seconds * 1000, privacy: .public)") }
        }
    }

    /// Wakes every live helper of this app. Only sent when a helper could
    /// actually connect now.
    private func postReady(_ reason: String) {
        guard pairingSocket != nil, context != nil, autoReceive, !locked else { return }
        readySequence += 1
        let name = AgentPairing.readyNotification(appID: AgentPeerSigning.appID)
        let result = notify_post(name)
        Log.agent.info("[AGENT-CONN] ready post reason=\(reason, privacy: .public) seq=\(self.readySequence, privacy: .public) result=\(result == 0 ? "ok" : String(result), privacy: .public)")
    }

    @discardableResult
    private func activateReceive(_ binding: Binding) -> Bool {
        guard let context, autoReceive, !locked, binding.receiptEnabled else { return false }
        if binding.receipt != nil { return true }
        guard receive(binding, current: context.current, workspace: context.workspace) else { return false }
        activatePending(binding)
        return true
    }

    func disableReceive() {
        clearApprovals()
        status = ""
        _ = setAutoReceive(false)
        Log.agent.info("[AGENT-CONN] receipt choice=off set=off reason=user")
        for binding in bindings.values { stopReceipt(binding) }
        clearSelection()
        instructionScope = nil
        note(.notSelected)
        receiptNotice = nil
        refreshConnections()
    }

    /// Unlocking leaves each receipt stopped until the remembered peer proves its key.
    func setLocked(_ value: Bool) {
        guard locked != value else { return }
        locked = value
        defer { refreshConnections() }
        guard value else { status = ""; postReady("unlock"); return }
        clearApprovals()
        for (client, binding) in Array(bindings) { dropBinding(client, keepSelection: binding.pair.persistent) }
        status = "화면이 잠겨 대본 받기를 멈췄습니다."
    }

    @discardableResult
    func disconnect(_ client: UUID) -> Bool {
        guard connections.contains(where: { $0.id == client }) else { return false }
        if let record = trust.clients.first(where: { $0.id == client }) {
            clearApprovals(for: record)
            if !trust.setReceiptEnabled(false, for: client) {
                status = "이 에이전트의 받기 설정을 저장하지 못했습니다."
            }
            trusted = trust.clients
        }
        if let binding = bindings[client] {
            clearApprovals(for: binding.pair.peer)
            binding.receiptEnabled = false
            stopReceipt(binding)
        }
        clearSelection(for: client, keepSelection: false)
        refreshConnections()
        return true
    }

    @discardableResult
    func resume(_ client: UUID) -> Bool {
        guard !locked, autoReceive, let row = connections.first(where: { $0.id == client }),
              row.state != .needsApproval else { return false }
        if row.persistent {
            guard trust.setReceiptEnabled(true, for: client) else {
                status = "이 에이전트의 받기 설정을 저장하지 못했습니다."
                return false
            }
            trusted = trust.clients
        }
        defer { refreshConnections() }
        // Resuming this client by hand starts its allowance over.
        rates[client] = nil
        guard let binding = bindings[client] else {
            if row.persistent { postReady("resume") }
            return row.persistent
        }
        binding.receiptEnabled = true
        return activateReceive(binding)
    }

    private func clearApprovals(for record: AgentTrustedClient) {
        let registered = Self.isRegisteredHost(record.host)
        func matches(_ claim: Challenge) -> Bool {
            registered ? claim.host == record.host : claim.keyID == record.keyID
        }
        for request in approvalRequests where matches(request.claim) { removeApproval(request.id) }
        challenges.removeAll(where: matches)
    }

    private func clearApprovals(for peer: LocalInstructionPeer) {
        for request in approvalRequests where request.claim.peer == peer { removeApproval(request.id) }
        challenges.removeAll { $0.peer == peer }
    }

    private func block(_ peer: LocalInstructionPeer) {
        let limit = AgentTrustStore.maxRevoked
        if blockedPeers.count >= limit { blockedPeers.removeFirst() }
        blockedPeers.append(peer)
    }

    @discardableResult
    func forget(_ client: UUID) -> Bool {
        guard connections.contains(where: { $0.id == client }) else { return false }
        if let record = trust.clients.first(where: { $0.id == client }) {
            clearApprovals(for: record)
            let saved = trust.forget(client)
            if !saved {
                status = "잊은 내용을 저장하지 못했습니다. 앱을 다시 열면 이 에이전트가 다시 보일 수 있습니다."
            }
            Log.agent.info("[AGENT-CONN] revoke host=\(record.host, privacy: .public) client=\(client.uuidString, privacy: .public) result=\(saved ? "ok" : "unsaved", privacy: .public)")
            trusted = trust.clients
        }
        if let peer = bindings[client]?.pair.peer {
            block(peer)
            clearApprovals(for: peer)
        }
        dropBinding(client, keepSelection: false)
        receiptKeys[client] = nil
        rates[client] = nil
        if instructionClient == client { instructionClient = nil }
        return true
    }

    private func receive(_ binding: Binding, current: @escaping @MainActor (String) -> AgentInstructionSnapshot?,
                 workspace: ExplanationDraftWorkspace) -> Bool {
        let pair = binding.pair
        // No clock ends this: it lasts until the user turns it off, the screen
        // locks, the client is forgotten, or the client process goes away.
        let generation = UUID()
        let socket = LocalApprovedSocket(peer: pair.peer, endpoint: AgentPairing.draftEndpoint(slot: pair.slot), directory: directory,
                                         lifetime: nil, maxFrame: AgentLimits.frameBytes,
                                         verified: Self.verifier(for: pair)) { [weak self] bytes, active in
            guard let request = Self.decode(bytes) else { return Self.reply("invalid") }
            guard Self.isV2(request["schema_version"]) else { return Self.reply("upgrade_required") }
            let base: Set<String> = ["schema_version", "idempotency_key", "display_text"]
            let linkedKeys: Set<String> = ["profile", "revision", "body_sha256", "proof"]
            var keys = Set(request.keys)
            keys.remove("speech_text")
            keys.remove("title")
            let linked = keys == base.union(linkedKeys)
            guard (linked || keys == base),
                  let clientKey = request["idempotency_key"] as? String,
                  let display = request["display_text"] as? String,
                  (request["speech_text"] == nil || request["speech_text"] is String),
                  (request["title"] == nil || request["title"] is String),
                  ExplanationDraft(id: clientKey, display: display, speech: request["speech_text"] as? String,
                                   title: request["title"] as? String) != nil else {
                return Self.reply("invalid")
            }
            let speech = request["speech_text"] as? String
            let title = request["title"] as? String
            let response = Reply()
            let signal = DispatchSemaphore(value: 0)
            let responseDeadline = DispatchTime.now() + .milliseconds(750)
            DispatchQueue.main.async {
                defer { signal.signal() }
                guard DispatchTime.now() < responseDeadline, active(), let self,
                      let live = self.bindings[pair.client], live.pair.id == pair.id,
                      self.autoReceive, !self.locked, live.generation == generation,
                      Self.matchesLiveHost(pair) else { return }
                let origin: AgentDraftOrigin?
                if linked {
                    guard let selector = request["profile"] as? String, let revision = Self.uuid(request["revision"]),
                          let bodyHash = request["body_sha256"] as? String, let token = Self.uuid(request["proof"]),
                          let proof = pair.proofs.resolve(token, selector: selector, revision: revision, digest: bodyHash),
                          self.instructionClient == pair.client,
                          let shared = self.shared, shared.selector == selector,
                          let current = current(selector), current == shared,
                          current.generation == proof.revision, current.digest == proof.digest,
                          active() else {
                        response.set("unproven"); return
                    }
                    origin = AgentDraftOrigin(principal: pair.client, agentLabel: pair.label, selector: selector,
                                              revision: revision, bodyHash: bodyHash, older: false)
                } else {
                    // This is enforced here, not just by a potentially stale MCP tool status.
                    // A selected-but-not-yet-shareable request also cannot fall back generically.
                    guard self.instructionClient != pair.client || self.instructionScope == nil else {
                        self.receiptNotice = self.shared != nil
                            ? "에이전트가 지시를 읽지 않고 대본을 보내 받지 않았습니다."
                            : "선택한 지시가 공유되고 있지 않아 대본을 받지 않았습니다. 지시를 다시 선택하거나 ‘사용 안 함’으로 바꾸세요."
                        response.set("instruction_required"); return
                    }
                    origin = nil
                }
                let scopedKey = AgentBytes.hash(Data((pair.client.uuidString + "\0" + clientKey).utf8))
                guard let draft = ExplanationDraft(id: scopedKey, display: display, speech: speech,
                                                   provenance: origin, title: title) else {
                    response.set("invalid"); return
                }
                let fingerprint = draft.fingerprint
                if let previous = self.receiptKeys[pair.client]?.first(where: { $0.key == clientKey }) {
                    response.set(previous.digest == fingerprint ? "duplicate" : "conflict"); return
                }
                var rate = self.rates[pair.client] ?? AgentRateLimit()
                guard rate.canAccept() else {
                    self.receiptNotice = "대본이 너무 자주 와서 잠시 받지 않았습니다."
                    response.set("rate_limited"); return
                }
                let result = workspace.receiveDocument(draft)
                if result == .busy {
                    self.receiptNotice = "새 대본을 저장하지 못해 받지 않았습니다. 디스크 공간을 확인하세요."
                }
                if result == .accepted || result == .duplicate {
                    // A stored document also answers for its key after an app restart;
                    // remember it here so the answer stays the same if it is closed.
                    var known = self.receiptKeys[pair.client] ?? []
                    known.append((clientKey, fingerprint))
                    // Oldest keys fall out, so a connection kept open all day never fills up.
                    if known.count > AgentLimits.receiptKeys { known.removeFirst(known.count - AgentLimits.receiptKeys) }
                    self.receiptKeys[pair.client] = known
                }
                if result == .accepted {
                    rate.mark()
                    self.receiptNotice = nil
                }
                self.rates[pair.client] = rate
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
        binding.receipt = socket
        binding.generation = generation
        refreshConnections()
        return true
    }

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

    private func stopShare() {
        shareSocket?.stop(); shareSocket = nil
        if let instructionClient { bindings[instructionClient]?.pair.proofs.clear() }
        shared = nil
    }

    private func stopReceipt(_ binding: Binding) {
        binding.receipt?.stop(); binding.receipt = nil
        binding.generation = nil
        binding.pair.proofs.clear()
    }

    private func clearSelection(for client: UUID, keepSelection: Bool) {
        guard instructionClient == client else { return }
        if keepSelection, instructionScope != nil {
            stopShare()
            note(.waitingForHelper)
        } else {
            clearSelection()
            instructionScope = nil
            note(.notSelected)
        }
    }

    private func dropBinding(_ client: UUID, keepSelection: Bool) {
        clearSelection(for: client, keepSelection: keepSelection)
        if let binding = bindings.removeValue(forKey: client) {
            binding.watch.cancel()
            stopReceipt(binding)
            if !binding.pair.persistent {
                receiptKeys[client] = nil
                rates[client] = nil
                if instructionClient == client { instructionClient = nil }
            }
        }
        refreshConnections()
    }

    private nonisolated static func verifier(for pair: Pair) -> (Int32) -> Bool {
        let verify = verifier(leaf: pair.leaf, hash: pair.helperHash)
        return { fd in verify(fd) && matchesLiveHost(pair) }
    }

    private nonisolated static func matchesLiveHost(_ pair: Pair) -> Bool {
        guard let host = pair.host else { return true }
        return AgentPeerSigning.registeredHost(pid: pair.peer.pid) == host
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
