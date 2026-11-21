// AgentWorkspaceController.swift
// Owns the Agent instruction catalog, the volatile session consent and the two v2 endpoints.
//
// Design decision record
// - ai.sock (instruction read) and ad.sock (draft receipt) are separate leases with separate revoke.
//   Every connection must be the paired PID + start time, the same real/effective UID, and carry a
//   live audit-token signature with the fixed bridge identifier and this app's own leaf certificate.
//   Ad hoc or unsigned builds have no leaf certificate and therefore can never pair.
// - Pairing scopes one locally signed bridge process. It lives in memory only; quitting, unpairing
//   or the bridge exiting closes every lease. It does not identify any remote agent.
// - Delivery proof is recorded only after the full reply was written, before the socket is closed.
// - A received draft is only queued in the inbox. Nothing here plays audio, calls a model, runs a
//   command or changes the editor. The legacy i.sock / d.sock endpoints are never started.

import AppKit
import Combine
import Darwin
import Foundation

/// Catalog store inside its own private directory (0700) as one private file (0600), replaced
/// atomically. Unexpected file types, owners, hard links or symlinks are refused, never repaired.
struct AgentCatalogSecureStorage: AgentInstructionCatalogStorage {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let fileName = "AgentInstructionCatalog.json"
    static let maxStoreBytes = 48 * 1024 * 1024
    let directory: URL?

    static func standard() -> AgentCatalogSecureStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let owner = Bundle.main.bundleIdentifier ?? "com.codebasic.tts"
        return AgentCatalogSecureStorage(directory: base?.appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent("AgentCatalog", isDirectory: true))
    }

    /// Returns false when the directory does not exist and `create` is false.
    private func prepareDirectory(create: Bool) throws -> Bool {
        guard let directory = directory else { throw Failure(description: "storage location unavailable") }
        var st = stat()
        if lstat(directory.path, &st) != 0 {
            guard errno == ENOENT else { throw Failure(description: "storage directory cannot be inspected") }
            guard create else { return false }
            do {
                try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true, attributes: nil)
            } catch {
                throw Failure(description: "storage directory cannot be created")
            }
            guard mkdir(directory.path, 0o700) == 0, lstat(directory.path, &st) == 0 else {
                throw Failure(description: "storage directory cannot be created")
            }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw Failure(description: "storage directory is not a private directory")
        }
        // Fail closed: an existing directory with any other mode is never repaired implicitly.
        guard (st.st_mode & 0o7777) == 0o700 else {
            throw Failure(description: "storage directory is not a private directory")
        }
        return true
    }

    private func path(_ name: String) throws -> String {
        guard let directory = directory else { throw Failure(description: "storage location unavailable") }
        return directory.appendingPathComponent(name).path
    }

    func load() throws -> Data? {
        guard try prepareDirectory(create: false) else { return nil }
        let file = try path(Self.fileName)
        var st = stat()
        if lstat(file, &st) != 0 {
            if errno == ENOENT { return nil }
            throw Failure(description: "catalog store cannot be inspected")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
              st.st_size >= 0, st.st_size <= off_t(Self.maxStoreBytes),
              (st.st_mode & 0o7777) == 0o600 else {
            throw Failure(description: "catalog store is not a private regular file")
        }
        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(description: "catalog store cannot be opened") }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == st.st_ino, opened.st_dev == st.st_dev,
              (opened.st_mode & S_IFMT) == S_IFREG else {
            throw Failure(description: "catalog store changed while opening")
        }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure(description: "catalog store cannot be read")
            }
            data.append(contentsOf: chunk[0..<count])
            guard data.count <= Self.maxStoreBytes else { throw Failure(description: "catalog store is too large") }
        }
        return data
    }

    func save(_ data: Data) throws {
        _ = try prepareDirectory(create: true)
        let file = try path(Self.fileName)
        var st = stat()
        if lstat(file, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
                  (st.st_mode & 0o7777) == 0o600 else {
                throw Failure(description: "catalog store is not a private regular file")
            }
        } else if errno != ENOENT {
            throw Failure(description: "catalog store cannot be inspected")
        }
        let temporary = try path("." + Self.fileName + ".tmp-" + UUID().uuidString)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(description: "catalog store could not be written") }
        var ok = data.withUnsafeBytes { (view: UnsafeRawBufferPointer) -> Bool in
            var sent = 0
            while sent < view.count {
                let count = write(fd, view.baseAddress?.advanced(by: sent), view.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
        ok = ok && fchmod(fd, 0o600) == 0 && fsync(fd) == 0
        ok = (close(fd) == 0) && ok
        guard ok, rename(temporary, file) == 0 else {
            unlink(temporary)
            throw Failure(description: "catalog store could not be written")
        }
    }

    func quarantine() throws -> URL? {
        guard try prepareDirectory(create: false), let directory = directory else { return nil }
        let file = directory.appendingPathComponent(Self.fileName)
        var st = stat()
        guard lstat(file.path, &st) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure(description: "catalog store cannot be inspected")
        }
        let destination = directory.appendingPathComponent(Self.fileName + ".unreadable-" + UUID().uuidString)
        guard rename(file.path, destination.path) == 0 else {
            throw Failure(description: "catalog store could not be moved aside")
        }
        return destination
    }
}

/// One bounded socket-queue to main-actor handoff. Either the main block starts and its result is
/// awaited, or the waiter cancels first and the main block never touches any state.
private final class AgentDraftHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var state = 0
    private var value = "busy"
    let done = DispatchSemaphore(value: 0)

    private func move(to next: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == 0 else { return false }
        state = next
        return true
    }

    func begin() -> Bool { move(to: 1) }
    func cancel() -> Bool { move(to: 2) }

    func finish(_ status: String) {
        lock.lock()
        value = status
        lock.unlock()
        done.signal()
    }

    var status: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class AgentWorkspaceController: ObservableObject {
    /// One locally signed bridge process, labelled by the owner. Never a remote agent identity.
    struct Pairing: Equatable {
        let pid: Int32
        let label: String
        let instanceID: UUID
        fileprivate let peer: LocalInstructionPeer
        fileprivate let leafSHA1: String
    }

    struct ShareLease: Equatable {
        let shareID: UUID
        let profileID: UUID
        let revision: AgentInstructionRevision
        let expires: Date
    }

    struct ReceiptLease: Equatable {
        let grantID: UUID
        let expires: Date
    }

    private struct DraftRequest: Sendable {
        let profileID: UUID
        let revision: AgentInstructionRevision
        let sha256: Data
        let key: String
        let display: String
        let speech: String?
    }

    typealias Responder = (Data, @escaping () -> Bool) -> (Data, ((Bool) -> Void)?)?

    /// Read-only presets under the stable catalog IDs, carrying the exact legacy built-in texts.
    static let builtIns: [AgentInstructionBuiltIn] = {
        let explain = CodeExplanation.effectiveInstruction(CodeExplanation.defaultInstruction)
        func preset(_ suffix: String, _ label: String, _ body: String) -> AgentInstructionBuiltIn {
            AgentInstructionBuiltIn(id: UUID(uuidString: "6F0C2B5E-3A41-4D7B-9C1E-0A5D8E2F7B" + suffix)!,
                                    label: label, body: body, sequence: 2)
        }
        return [preset("10", "전체 해설", explain),
                preset("11", "변경분만", explain + "\n\n" + CodeExplanation.continueInstruction),
                preset("12", "음성 대본 정규화", TextNormalizer.defaultInstruction)]
    }()

    let catalog: AgentInstructionCatalog
    let drafts: ExplanationDraftWorkspace
    /// Public leaf certificate SHA-1 of this app's own valid signature; nil for ad hoc builds.
    let ownSignerSHA1: String?

    @Published private(set) var pairing: Pairing?
    @Published private(set) var shareLease: ShareLease?
    @Published private(set) var receiptLease: ReceiptLease?
    @Published var notice: String?

    private let session = AgentSessionAuthorization()
    private var shareSocket: LocalApprovedSocket?
    private var receiptSocket: LocalApprovedSocket?
    private var catalogChanges: AnyCancellable?
    private var timer: Timer?

    init(app: AppState) {
        drafts = app.explanationDrafts
        // Legacy prompts are copied once, exactly, and only when their bytes differ from the presets.
        var seeds: [AgentLegacyPromptSeed] = []
        // The raw stored bytes are seeded, blank included; common rules are never appended here.
        let explain = app.explainPrompt
        if !explain.utf8.elementsEqual(CodeExplanation.defaultInstruction.utf8) {
            seeds.append(AgentLegacyPromptSeed(key: "explainPrompt", suggestedLabel: "내 해설 지시 (기존 설정)", body: explain))
        }
        let normalize = app.normalizePrompt
        if !normalize.utf8.elementsEqual(TextNormalizer.defaultInstruction.utf8) {
            seeds.append(AgentLegacyPromptSeed(key: "normalizePrompt", suggestedLabel: "내 정규화 지시 (기존 설정)", body: normalize))
        }
        catalog = AgentInstructionCatalog(storage: AgentCatalogSecureStorage.standard(),
                                          builtIns: Self.builtIns, legacySeed: seeds)
        ownSignerSHA1 = AgentPeerSignature.ownSignerSHA1()
        catalogChanges = catalog.changes.sink { [weak self] change in self?.catalogChanged(change) }
    }

    /// Values the owner copies into the MCP client configuration. Public information only.
    var setupSummary: String? {
        guard let leaf = ownSignerSHA1, let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return "CODEBASIC_TTS_APP_BUNDLE_ID=\(bundleID)  CODEBASIC_TTS_SIGNER_SHA1=\(leaf)"
    }

    // MARK: Pairing

    @discardableResult
    func pair(pidText: String, label: String) -> Bool {
        guard let leaf = ownSignerSHA1 else {
            return fail("이 앱은 안정적인 서명 인증서 없이 빌드되어 브리지를 확인할 수 없습니다. 지시는 복사해서 직접 붙여넣으세요.")
        }
        guard getuid() == geteuid(),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), pid != getpid(),
              let peer = LocalInstructionPeer.current(pid: pid) else {
            return fail("같은 계정에서 지금 실행 중인 브리지의 PID가 필요합니다.")
        }
        // Selection aid only. Every connection is verified again by its kernel audit token.
        guard let signer = AgentPeerSignature.informationalSigner(pid: pid), signer.currentlyValid,
              signer.identifier == AgentPeerSignature.bridgeIdentifier, signer.leafSHA1 == leaf,
              LocalInstructionPeer.current(pid: pid) == peer else {
            return fail("이 PID는 이 앱과 같은 인증서로 서명된 에이전트 브리지가 아닙니다.")
        }
        let instanceID = UUID()
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .success = session.pair(instanceID: instanceID, ownerLabel: trimmed) else {
            return fail("이름은 비워 둘 수 없고 80자를 넘을 수 없습니다.")
        }
        revokeShare()
        revokeReceipt()
        pairing = Pairing(pid: pid, label: trimmed, instanceID: instanceID, peer: peer, leafSHA1: leaf)
        notice = nil
        startTimer()
        return true
    }

    func unpair() {
        revokeShare()
        revokeReceipt()
        session.unpair()
        if pairing != nil { pairing = nil }
        timer?.invalidate()
        timer = nil
    }

    /// Quit: every lease and the pairing end with the process.
    func shutdown() { unpair() }

    // MARK: Instruction reads (ai.sock)

    /// The only way an instruction leaves the app: one modal showing the exact bytes.
    func requestShare(profileID: UUID) {
        guard let current = pairing else { notice = "먼저 에이전트 브리지를 연결하세요."; return }
        let snapshot: AgentInstructionShareSnapshot
        switch catalog.shareSnapshot(for: profileID) {
        case .success(let value): snapshot = value
        case .failure(let block): notice = Self.describe(block); return
        }
        let alert = NSAlert()
        alert.messageText = "「\(current.label)」(PID \(current.pid)) 브리지에 아래 지시를 공유할까요?"
        alert.informativeText = "아래에 보이는 \(snapshot.bodyUTF8.count)바이트 그대로, 이 지시 하나만 최대 10분 동안 읽을 수 있습니다. 지시 이름은 전송되지 않습니다. 원격 모델을 사용하는 에이전트는 이 내용을 해당 서비스로 보낼 수 있습니다. 비밀이나 외부에 공개할 수 없는 내용이 있으면 취소하세요."
        alert.addButton(withTitle: "이 지시만 공유")
        alert.addButton(withTitle: "취소")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 430, height: 214)
        guard let preview = scroll.documentView as? NSTextView else { return }
        preview.isRichText = false
        preview.string = snapshot.text
        preview.isEditable = false
        preview.isSelectable = true
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard pairing == current, case .success(let fresh) = catalog.shareSnapshot(for: profileID), fresh == snapshot else {
            notice = "미리 보는 동안 지시나 연결이 바뀌었습니다. 새 내용을 확인한 뒤 다시 공유하세요."
            return
        }
        revokeShare()
        guard case .success(let grant) = session.grantShare(snapshot, to: current.instanceID) else {
            notice = "이 지시는 지금 공유할 수 없습니다."
            return
        }
        let socket = LocalApprovedSocket(
            peer: current.peer, endpoint: "ai.sock", directory: LocalApprovedSocket.defaultDirectory,
            lifetime: .seconds(Int(AgentSessionLimits.maxGrantLifetime)), maxFrame: 64,
            verifier: Self.verifier(pid: current.pid, leafSHA1: current.leafSHA1),
            respond: Self.shareResponder(session: session, shareID: grant.shareID, instanceID: current.instanceID))
        guard socket.start() else {
            session.revokeShare()
            notice = "읽기 소켓을 열 수 없습니다. 브리지가 종료됐거나 이전 소켓 경로가 남아 있습니다."
            return
        }
        shareSocket = socket
        shareLease = ShareLease(shareID: grant.shareID, profileID: snapshot.profileID, revision: snapshot.revision,
                                expires: Date().addingTimeInterval(grant.expiresAt - grant.grantedAt))
        notice = nil
    }

    /// Ends reads only. A receipt grant and already delivered versions are unaffected.
    func revokeShare() {
        shareSocket?.stop()
        shareSocket = nil
        session.revokeShare()
        if shareLease != nil { shareLease = nil }
    }

    // MARK: Draft receipt (ad.sock)

    func requestReceipt() {
        guard let current = pairing else { notice = "먼저 에이전트 브리지를 연결하세요."; return }
        let alert = NSAlert()
        alert.messageText = "「\(current.label)」(PID \(current.pid)) 브리지의 대본을 받을까요?"
        alert.informativeText = "최대 10분 동안, 이 브리지가 실제로 읽어 간 지시 버전에 대한 대본만 보관함에 받습니다. 편집기를 덮어쓰거나 재생하지 않으며, 지시 읽기 허용과는 별개입니다."
        alert.addButton(withTitle: "대본 받기 허용")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn, pairing == current else { return }
        revokeReceipt()
        guard case .success(let info) = session.grantReceipt(to: current.instanceID) else {
            notice = "대본 받기를 허용할 수 없습니다."
            return
        }
        let socket = LocalApprovedSocket(
            peer: current.peer, endpoint: "ad.sock", directory: LocalApprovedSocket.defaultDirectory,
            lifetime: .seconds(Int(AgentSessionLimits.maxGrantLifetime)), maxFrame: 100 * 1024,
            verifier: Self.verifier(pid: current.pid, leafSHA1: current.leafSHA1),
            respond: Self.draftResponder(controller: self, grantID: info.grantID))
        guard socket.start() else {
            session.revokeReceipt()
            notice = "대본 소켓을 열 수 없습니다. 브리지가 종료됐거나 이전 소켓 경로가 남아 있습니다."
            return
        }
        receiptSocket = socket
        receiptLease = ReceiptLease(grantID: info.grantID, expires: Date().addingTimeInterval(info.expiresAt - info.grantedAt))
        drafts.setReceiver(current.pid)
        notice = nil
    }

    /// Ends receipt only. Drafts that were already accepted stay in the inbox.
    func revokeReceipt() {
        receiptSocket?.stop()
        receiptSocket = nil
        session.revokeReceipt()
        if receiptLease != nil { receiptLease = nil }
        if drafts.receiverPID != nil { drafts.setReceiver(nil) }
    }

    // MARK: Private (main actor)

    private func fail(_ message: String) -> Bool {
        notice = message
        return false
    }

    private func catalogChanged(_ change: AgentInstructionCatalogChange) {
        switch change {
        case .bodyChanged(let profileID, _, _):
            _ = session.instructionBodyChanged(profileID: profileID)
            if shareLease?.profileID == profileID { revokeShare() }
        case .deleted(let profileID, _):
            session.profileDeleted(profileID: profileID)
            if shareLease?.profileID == profileID { revokeShare() }
        case .added, .labelChanged:
            break
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let created = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    /// Expiry and liveness: nothing stays presented as shared after it has ended.
    private func tick() {
        guard let current = pairing else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard LocalInstructionPeer.current(pid: current.pid) == current.peer else {
            unpair()
            notice = "연결한 브리지 프로세스가 종료되어 연결과 모든 허용을 해제했습니다."
            return
        }
        let status = session.status()
        if let lease = shareLease, status.share?.shareID != lease.shareID { revokeShare() }
        if let lease = receiptLease, status.receipt?.grantID != lease.grantID { revokeReceipt() }
    }

    private func acceptDraft(_ request: DraftRequest, grantID: UUID, stillAllowed: () -> Bool) -> String {
        guard stillAllowed(), let current = pairing, receiptLease?.grantID == grantID else { return "denied" }
        let submission = AgentDraftSubmission(instanceID: current.instanceID, profileID: request.profileID,
                                              revision: request.revision, instructionSHA256: request.sha256,
                                              idempotencyKey: request.key, display: request.display, speech: request.speech)
        let workspace = drafts
        let outcome = session.submit(submission) { provenance in
            // The inbox ID is internal and unrelated to the wire key; the session scopes idempotency.
            guard let draft = ExplanationDraft(id: UUID().uuidString, display: request.display,
                                               speech: request.speech, provenance: provenance) else { return false }
            return workspace.enqueueAgentDraft(draft)
        }
        switch outcome {
        case .accepted: return "accepted"
        case .duplicate: return "duplicate"
        case .conflict: return "conflict"
        case .refusedByQueue: return "busy"
        case .denied(let reason):
            switch reason {
            case .notPaired, .wrongPrincipal: return "not_paired"
            case .rateLimited, .grantQuotaExhausted: return "rate_limited"
            case .noDeliveryProof, .profileDeleted: return "stale_revision"
            default: return "denied"
            }
        }
    }

    private static func describe(_ block: AgentInstructionShareBlock) -> String {
        switch block {
        case .notFound: return "지시를 찾을 수 없습니다."
        case .blank: return "빈 지시는 공유할 수 없습니다."
        case .containsNUL: return "NUL 문자가 있는 지시는 공유할 수 없습니다."
        case .oversize: return "공유 한도(UTF-8 8KB)를 넘는 지시입니다. 내용은 그대로이며 복사해서 직접 붙여넣을 수 있습니다."
        }
    }

    // MARK: Wire helpers (run on the socket queue; no main-actor state)

    /// Opaque to the helper: profile UUID, catalog revision and body SHA-256 joined by dots.
    nonisolated static func wireRevision(profileID: UUID, revision: AgentInstructionRevision, sha256: Data) -> String {
        profileID.uuidString + "." + revision.description + "." + sha256.map { String(format: "%02x", $0) }.joined()
    }

    /// Accepts only the exact canonical form produced by `wireRevision`.
    nonisolated static func parseWireRevision(_ text: String) -> (profileID: UUID, revision: AgentInstructionRevision, sha256: Data)? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard text.utf8.count <= 256, parts.count == 3,
              let profileID = UUID(uuidString: String(parts[0])),
              let revision = AgentInstructionRevision(wireString: String(parts[1])),
              parts[2].utf8.count == 64 else { return nil }
        var sha = Data()
        var high: UInt8?
        for c in parts[2].utf8 {
            let v: UInt8
            switch c {
            case 48...57: v = c - 48
            case 97...102: v = c - 87
            default: return nil
            }
            if let h = high {
                sha.append(h << 4 | v)
                high = nil
            } else {
                high = v
            }
        }
        let canonical = wireRevision(profileID: profileID, revision: revision, sha256: sha)
        guard canonical.utf8.elementsEqual(text.utf8) else { return nil }
        return (profileID, revision, sha)
    }

    private nonisolated static func verifier(pid: pid_t, leafSHA1: String) -> (Int32) -> Bool {
        { fd in
            guard getuid() == geteuid(),
                  let peer = AgentPeerSignature.verifyConnectedPeer(fd: fd, expectedUID: getuid(),
                                                                    identifier: AgentPeerSignature.bridgeIdentifier,
                                                                    leafSHA1: leafSHA1) else { return false }
            return peer.pid == pid
        }
    }

    /// ai.sock v2: exactly {"operation":"get"}. Anything else is closed without a reply.
    private nonisolated static func shareResponder(session: AgentSessionAuthorization, shareID: UUID, instanceID: UUID) -> Responder {
        { bytes, stillAllowed in
            guard let args = try? JSONDecoder().decode([String: String].self, from: bytes),
                  args == ["operation": "get"], stillAllowed(),
                  case .success(let ticket) = session.beginShareRead(shareID: shareID, instanceID: instanceID) else { return nil }
            let snapshot = ticket.grant.snapshot
            let object: [String: Any] = [
                "schema_version": 2,
                "profile_id": snapshot.profileID.uuidString,
                "revision": wireRevision(profileID: snapshot.profileID, revision: snapshot.revision, sha256: snapshot.sha256),
                "instructions": String(decoding: ticket.bytes, as: UTF8.self)
            ]
            guard let reply = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
                  reply.count < 52 * 1024 else { return nil }
            // Proof only for a complete write to the verified live peer; never for a partial send.
            let completion: ((Bool) -> Void)? = { written in
                if written { _ = session.completeShareRead(ticket) }
            }
            return (reply, completion)
        }
    }

    private nonisolated static func draftStatus(_ status: String) -> (Data, ((Bool) -> Void)?)? {
        guard let reply = try? JSONSerialization.data(withJSONObject: ["status": status]) else { return nil }
        return (reply, nil)
    }

    private nonisolated static func validField(_ value: String) -> Bool {
        !value.utf8.contains(0) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Text fields are data only. They are never decoded or interpreted as commands.
    private nonisolated static func parseDraft(_ bytes: Data) -> (request: DraftRequest?, status: String) {
        guard bytes.count < 100 * 1024,
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              Set(object.keys).isSubset(of: ["revision", "display_text", "speech_text", "idempotency_key"]),
              let revisionText = object["revision"] as? String,
              let display = object["display_text"] as? String,
              let key = object["idempotency_key"] as? String else { return (nil, "denied") }
        var speech: String?
        if let raw = object["speech_text"] {
            guard let text = raw as? String else { return (nil, "denied") }
            speech = text
        }
        guard key.utf8.count >= 1, key.utf8.count <= AgentSessionLimits.maxIdempotencyKeyBytes,
              key.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else { return (nil, "denied") }
        let limit = AgentSessionLimits.maxFieldUTF8Bytes
        guard display.utf8.count <= limit, (speech?.utf8.count ?? 0) <= limit else { return (nil, "too_large") }
        guard validField(display), speech.map(validField) ?? true,
              let parsed = parseWireRevision(revisionText) else { return (nil, "denied") }
        return (DraftRequest(profileID: parsed.profileID, revision: parsed.revision, sha256: parsed.sha256,
                             key: key, display: display, speech: speech), "accepted")
    }

    /// ad.sock v2. Replies carry only a bounded status word.
    private nonisolated static func draftResponder(controller: AgentWorkspaceController, grantID: UUID) -> Responder {
        { [weak controller] bytes, stillAllowed in
            let parsed = parseDraft(bytes)
            guard let request = parsed.request else { return draftStatus(parsed.status) }
            guard stillAllowed() else { return nil }
            let handoff = AgentDraftHandoff()
            DispatchQueue.main.async { [weak controller] in
                guard handoff.begin() else { return }
                let status = MainActor.assumeIsolated {
                    controller?.acceptDraft(request, grantID: grantID, stillAllowed: stillAllowed) ?? "denied"
                }
                handoff.finish(status)
            }
            if handoff.done.wait(timeout: .now() + .milliseconds(400)) == .timedOut {
                // Not started yet: cancel so nothing is queued later. Started: the work is short.
                if handoff.cancel() { return draftStatus("busy") }
                handoff.done.wait()
            }
            return draftStatus(handoff.status)
        }
    }
}
