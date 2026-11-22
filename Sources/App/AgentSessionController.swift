import Combine
import CoreFoundation
import Darwin
import Foundation

/// The UI's name is descriptive only. The authenticated principal is a new
/// app-local ID tied to one verified live helper, for both disjoint grants.
@MainActor final class AgentSessionController: ObservableObject {
    enum SelectionStatus: String {
        case notSelected, waitingForHelper, active, canceled, expired, changed
        case legacySharing, catalogUnavailable, invalidInstruction, pairingUnavailable, instructionGrantFailed, draftGrantFailed

        var message: String {
            switch self {
            case .notSelected: return "아직 공유하지 않음 · 지시문을 선택하세요."
            case .waitingForHelper: return "선택 완료 · 에이전트에서 MCP를 시작하면 연결됩니다."
            case .active: return "지시 공유 및 대본 수신 중"
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
            case .legacySharing, .catalogUnavailable, .invalidInstruction, .pairingUnavailable, .instructionGrantFailed, .draftGrantFailed: return true
            default: return false
            }
        }
    }

    private struct PendingSelection {
        let id = UUID()
        let snapshot: AgentInstructionSnapshot
        let current: @MainActor (String) -> AgentInstructionSnapshot?
        let workspace: ExplanationDraftWorkspace
        let deliveryGate: (@escaping () -> Void) -> Void
        let deadline: ContinuousClock.Instant
    }

    struct Pair {
        let id = UUID()
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
    private var pendingSelection: PendingSelection?
    private var pendingTask: Task<Void, Never>?
    private let selectionWaiting: Duration
    private var pairingSocket: LocalApprovedSocket?
    private var shareSocket: LocalApprovedSocket?
    private var receiptSocket: LocalApprovedSocket?
    private var shareTask: Task<Void, Never>?
    private var receiptTask: Task<Void, Never>?
    private var watch: DispatchSourceProcess?
    private var rate = AgentRateLimit()
    private var receiveDeadline: ContinuousClock.Instant?
    private let directory: String
    private let bundledHelper: () -> Data?

    init(directory: String = LocalApprovedSocket.defaultDirectory,
         bundledHelper: @escaping () -> Data? = AgentPeerSigning.bundledHelperHash,
         selectionWaiting: Duration = .seconds(90)) {
        self.directory = directory
        self.bundledHelper = bundledHelper
        self.selectionWaiting = selectionWaiting
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
            guard let request = Self.decode(bytes), Set(request.keys) == ["schema_version"],
                  Self.isV2(request["schema_version"]) else { return Self.reply("invalid") }
            let response = Reply()
            let signal = DispatchSemaphore(value: 0)
            let deadline = DispatchTime.now() + .milliseconds(750)
            DispatchQueue.main.async {
                defer { signal.signal() }
                guard DispatchTime.now() < deadline, active(), let self else { return }
                if let previous = self.pair, LocalInstructionPeer.current(pid: previous.peer.pid) != previous.peer {
                    self.disconnect()
                }
                if let pair = self.pair, pair.peer != peer { response.set("other_agent"); return }
                if self.pair == nil && !self.bind(peer: peer, leaf: leaf, helperHash: hash) {
                    response.set("unavailable"); return
                }
                response.set(self.receiving
                             ? (self.shared == nil ? "receiving_only" : "ready")
                             : (self.shared == nil ? "approval_required" : "reading_only"))
            }
            guard signal.wait(timeout: deadline) == .success else { return Self.reply("unavailable") }
            return Self.reply(response.get())
        }
        guard socket.start() else {
            status = socket.requiresPathInspection ? LocalApprovedSocket.unknownPathMessage : "다른 앱 인스턴스가 자동 연결을 사용 중일 수 있습니다."
            return false
        }
        pairingSocket = socket
        return true
    }

    func stopPairing() {
        pairingSocket?.stop(); pairingSocket = nil
        disconnect()
    }

    private func bind(peer: LocalInstructionPeer, leaf: String, helperHash: Data) -> Bool {
        let pid = peer.pid
        guard LocalInstructionPeer.current(pid: pid) == peer else { return false }
        let label = "로컬 MCP"
        let next = Pair(label: label, peer: peer, hostPath: peer.parentExecutable(), leaf: leaf, helperHash: helperHash)
        pair = next
        let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watcher.setEventHandler { [weak self] in
            guard let self, self.pair?.id == next.id else { return }
            self.disconnect()
        }
        watch = watcher
        watcher.resume()
        if LocalInstructionPeer.current(pid: pid) != peer { disconnect(); return false }
        status = ""
        activatePending()
        return true
    }

    /// An explicit choice is consumed by one verified live helper, never by a
    /// default highlight. It is not persisted or carried into another session.
    @discardableResult
    func select(_ snapshot: AgentInstructionSnapshot,
                current: @escaping @MainActor (String) -> AgentInstructionSnapshot?,
                workspace: ExplanationDraftWorkspace,
                deliveryGate: @escaping (@escaping () -> Void) -> Void = { $0() }) -> Bool {
        clearSelection()
        guard snapshot.shareable else { note(.invalidInstruction); return false }
        guard pairingSocket != nil else { note(.pairingUnavailable); return false }
        let deadline = ContinuousClock.now.advanced(by: selectionWaiting)
        let pending = PendingSelection(snapshot: snapshot, current: current, workspace: workspace,
                                       deliveryGate: deliveryGate, deadline: deadline)
        pendingSelection = pending
        if pair != nil {
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
        guard let pending = pendingSelection, pair != nil else { return }
        cancelPending()
        guard ContinuousClock.now < pending.deadline else { note(.expired); return }
        guard pending.current(pending.snapshot.selector) == pending.snapshot else { note(.changed); return }
        guard share(pending.snapshot, deliveryGate: pending.deliveryGate) else {
            note(.instructionGrantFailed)
            return
        }
        guard receive(current: pending.current, workspace: pending.workspace) else {
            stopShare()
            note(.draftGrantFailed)
            return
        }
        note(.active)
    }

    func rejectSelection(_ reason: SelectionStatus) {
        clearSelection()
        note(reason)
    }

    func revokeSelection() {
        clearSelection()
        note(.canceled)
    }

    private func clearSelection() {
        cancelPending()
        stopShare()
        stopReceipt()
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(AgentLimits.grantSeconds))
        let socket = LocalApprovedSocket(peer: pair.peer, endpoint: "i.sock", directory: directory,
                                         lifetime: .seconds(AgentLimits.grantSeconds), maxFrame: 128,
                                         verified: Self.verifier(leaf: pair.leaf, hash: pair.helperHash),
                                         deliveryGate: { send in
            deliveryGate {
                guard ContinuousClock.now < deadline else { return }
                send()
            }
        }, didDeliver: { bytes in
            guard let reply = Self.decode(bytes), let token = Self.uuid(reply["proof"]),
                  let epoch = Self.uuid(reply["proof_epoch"]) else { return }
            pair.proofs.delivered(token, snapshot: snapshot, epoch: epoch)
        }) { bytes, _ in
            guard ContinuousClock.now < deadline, let request = Self.decode(bytes),
                  Self.isV2(request["schema_version"]) else { return nil }
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
        shareTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            self?.clearSelection()
            self?.note(.expired)
        }
        return true
    }

    func receive(current: @escaping @MainActor (String) -> AgentInstructionSnapshot?,
                 workspace: ExplanationDraftWorkspace) -> Bool {
        guard !receiving, let pair else { return false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(AgentLimits.grantSeconds))
        let socket = LocalApprovedSocket(peer: pair.peer, endpoint: "d.sock", directory: directory,
                                         lifetime: .seconds(AgentLimits.grantSeconds), maxFrame: 100 * 1024,
                                         verified: Self.verifier(leaf: pair.leaf, hash: pair.helperHash)) { [weak self] bytes, active in
            guard let request = Self.decode(bytes) else { return Self.reply("invalid") }
            guard Self.isV2(request["schema_version"]) else { return Self.reply("upgrade_required") }
            let required: Set<String> = ["schema_version", "profile", "revision", "body_sha256", "proof",
                                         "idempotency_key", "display_text"]
            let keys = Set(request.keys)
            guard keys == required || keys == required.union(["speech_text"]),
                  let selector = request["profile"] as? String, let revision = Self.uuid(request["revision"]),
                  let bodyHash = request["body_sha256"] as? String,
                  let token = Self.uuid(request["proof"]),
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
                      self.pair?.id == pair.id, self.receiving,
                      self.receiveDeadline == deadline, ContinuousClock.now < deadline else { return }
                guard let proof = pair.proofs.resolve(token, selector: selector, revision: revision, digest: bodyHash),
                      let shared = self.shared, shared.selector == selector,
                      let current = current(selector), current == shared,
                      current.generation == proof.revision, current.digest == proof.digest,
                      self.receiving, self.receiveDeadline == deadline, active() else {
                    response.set("unproven"); return
                }
                let origin = AgentDraftOrigin(principal: pair.id, agentLabel: pair.label, selector: selector,
                                              revision: revision, bodyHash: bodyHash, older: false)
                let scopedKey = AgentBytes.hash(Data((pair.id.uuidString + "\0" + clientKey).utf8))
                guard let draft = ExplanationDraft(id: scopedKey, display: display, speech: speech,
                                                   provenance: origin) else { response.set("invalid"); return }
                let previous = workspace.preflight(draft)
                guard previous == .accepted else { response.set(previous.rawValue); return }
                guard self.rate.canAccept() else { response.set("rate_limited"); return }
                let result = workspace.receive(draft)
                if result == .accepted { self.rate.mark() }
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
        receiveDeadline = deadline
        rate = AgentRateLimit()
        workspace.setReceiver(pair.peer.pid)
        receiptTask = Task { [weak self, weak workspace] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            self?.stopReceipt(workspace: workspace)
        }
        receiptWorkspace = workspace
        return true
    }

    private weak var receiptWorkspace: ExplanationDraftWorkspace?

    func invalidate(_ selector: String, deleted: Bool) {
        if shared?.selector == selector || pendingSelection?.snapshot.selector == selector {
            clearSelection()
            note(.changed)
        }
        // Previously received previews remain, but cannot reactivate access.
    }

    func stopShare() {
        shareTask?.cancel(); shareTask = nil
        shareSocket?.stop(); shareSocket = nil
        pair?.proofs.clear()
        shared = nil
    }

    func stopReceipt(workspace: ExplanationDraftWorkspace? = nil) {
        receiptTask?.cancel(); receiptTask = nil
        receiptSocket?.stop(); receiptSocket = nil
        pair?.proofs.clear()
        receiving = false
        receiveDeadline = nil
        (workspace ?? receiptWorkspace)?.setReceiver(nil)
        receiptWorkspace = nil
    }

    func disconnect() {
        watch?.cancel(); watch = nil
        clearSelection()
        pair = nil
        status = ""
        note(.notSelected)
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

    private nonisolated static func isV2(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number == 2
    }

    private nonisolated static func reply(_ status: String) -> Data { Data("{\"status\":\"\(status)\"}".utf8) }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var status = "disabled"
        func set(_ value: String) { lock.lock(); defer { lock.unlock() }; status = value }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return status }
    }
}
