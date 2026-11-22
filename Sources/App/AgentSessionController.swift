import Darwin
import Foundation

/// Single-login, non-reusing Unix stream socket with OS-level peer authentication
/// before reading any payload bytes.
final class AgentUnixSocketListener {
    private let directory: String
    private let endpoint: String
    private var path: String { directory + "/" + endpoint }
    private let maxFrameBytes: Int
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let authenticatePeer: @Sendable (Int32) -> HelperPrincipal?
    private let handleFrame: @Sendable (HelperPrincipal, Data) -> Data?
    private var source: DispatchSourceRead?
    private var inode: ino_t = 0
    private var stopped = false

    init(
        directory: String,
        endpoint: String,
        maxFrameBytes: Int,
        authenticatePeer: @escaping @Sendable (Int32) -> HelperPrincipal?,
        handleFrame: @escaping @Sendable (HelperPrincipal, Data) -> Data?
    ) {
        self.directory = directory
        self.endpoint = endpoint
        self.maxFrameBytes = maxFrameBytes
        self.queue = DispatchQueue(label: "com.codebasic.tts.agent." + endpoint)
        self.authenticatePeer = authenticatePeer
        self.handleFrame = handleFrame
    }

    func start() -> Bool {
        guard source == nil else { return true }
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { return false }
        var st = stat()
        guard lstat(directory, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(),
              (st.st_mode & 0o777) == 0o700,
              lstat(path, &st) != 0,
              errno == ENOENT else {
            return false
        }

        var addr = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            bytes.withUnsafeBytes { dst.copyBytes(from: $0) }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); return false }
        guard lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFSOCK,
              st.st_uid == getuid() else {
            close(fd); return false
        }
        inode = st.st_ino
        guard chmod(path, 0o600) == 0,
              listen(fd, 4) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd); unlinkOwnSocket(); return false
        }

        let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setEventHandler { [weak self] in self?.acceptOne(fd) }
        listener.setCancelHandler { close(fd) }
        source = listener
        listener.resume()
        return true
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        source?.cancel()
        source = nil
        unlinkOwnSocket()
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func unlinkOwnSocket() {
        var st = stat()
        if inode != 0,
           lstat(path, &st) == 0,
           (st.st_mode & S_IFMT) == S_IFSOCK,
           st.st_uid == getuid(),
           st.st_ino == inode {
            unlink(path)
        }
    }

    private func acceptOne(_ listening: Int32) {
        let fd = accept(listening, nil, nil)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        guard !isStopped(),
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              let principal = authenticatePeer(fd) else {
            return
        }

        let readDeadline = DispatchTime.now() + .milliseconds(600)
        guard let frame = readFrame(fd, deadline: readDeadline),
              !isStopped(),
              var reply = handleFrame(principal, frame) else {
            return
        }
        reply.append(10)
        let sendDeadline = DispatchTime.now() + .milliseconds(150)
        _ = reply.withUnsafeBytes { (view: UnsafeRawBufferPointer) -> Bool in
            guard let base = view.baseAddress else { return false }
            var sent = 0
            while sent < view.count {
                guard !isStopped(), ready(fd, event: Int16(POLLOUT), deadline: sendDeadline) else { return false }
                let n = send(fd, base.advanced(by: sent), view.count - sent, 0)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }

    private func readFrame(_ fd: Int32, deadline: DispatchTime) -> Data? {
        var frame = Data()
        var terminated = false
        var chunk = [UInt8](repeating: 0, count: 4096)
        while ready(fd, event: Int16(POLLIN), deadline: deadline) {
            let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count == 0 { return terminated ? frame : nil }
            guard count > 0, !terminated else { return nil }
            let received = chunk.prefix(count)
            if let index = received.firstIndex(of: 10) {
                guard index == received.endIndex - 1 else { return nil }
                frame.append(contentsOf: received.prefix(upTo: index))
                terminated = true
            } else {
                frame.append(contentsOf: received)
            }
            guard frame.count < maxFrameBytes else { return nil }
        }
        return nil
    }

    private func ready(_ fd: Int32, event: Int16, deadline: DispatchTime) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { return false }
        let ms = Int32((deadline.uptimeNanoseconds - now + 999_999) / 1_000_000)
        var target = pollfd(fd: fd, events: event, revents: 0)
        return poll(&target, 1, ms) > 0 && target.revents & event != 0
    }
}

/// Owns the local instruction catalog, the single pinned signed-helper session,
/// harness-initiated pairing discovery (`pair.sock`), read-only catalog socket (`i.sock`),
/// and proof-gated draft receipt socket (`d.sock`).
@MainActor
final class AgentSessionController: ObservableObject {
    @Published private(set) var isPairingOpen = false
    @Published private(set) var pendingCandidates: [PendingPairCandidate] = []
    @Published private(set) var pinnedSession: PinnedHelperSession? = nil
    @Published private(set) var activeReadGrant: ReadGrant? = nil
    @Published private(set) var activeReceiptGrant: ReceiptGrant? = nil
    @Published private(set) var proofCount: Int = 0
    @Published private(set) var remainingDraftsInGrant: Int = 0
    @Published private(set) var lastReadRevokeReason: ReadRevokeReason? = nil
    @Published var statusMessage: String = ""

    let catalog: AgentInstructionCatalogStore
    let drafts: ExplanationDraftWorkspace
    let policy: AgentSessionPolicy

    private let directory: String
    private let authenticatePeer: @Sendable (Int32) -> HelperPrincipal?
    private let builtinTextProvider: (String) -> String

    private var pairSocket: AgentUnixSocketListener?
    private var pairExpiry: DispatchWorkItem?
    private var readSocket: AgentUnixSocketListener?
    private var readExpiry: DispatchWorkItem?
    private var receiptSocket: AgentUnixSocketListener?
    private var receiptExpiry: DispatchWorkItem?

    var onBeforeOpenReadSocket: (() -> Void)?
    var onBeforeOpenReceiptSocket: (() -> Void)?
    var onReadGrantStateChanged: ((LocalInstructionProfile.Name?) -> Void)?
    var onReceiptGrantStateChanged: ((Int32?) -> Void)?

    init(
        catalog: AgentInstructionCatalogStore,
        drafts: ExplanationDraftWorkspace,
        directory: String = LocalApprovedSocket.defaultDirectory,
        clock: @escaping () -> Date = Date.init,
        authenticatePeer: @escaping @Sendable (Int32) -> HelperPrincipal? = {
            AgentPeerVerifier.verifyConnectedHelper(fd: $0)
        },
        builtinTextProvider: @escaping (String) -> String
    ) {
        self.catalog = catalog
        self.drafts = drafts
        self.policy = AgentSessionPolicy(clock: clock)
        self.directory = directory
        self.authenticatePeer = authenticatePeer
        self.builtinTextProvider = builtinTextProvider
    }

    // MARK: - Instruction assembly

    func approvedPayload(for target: InstructionTarget) -> ApprovedInstructionPayload? {
        switch target {
        case .builtin(let name):
            guard let profileName = LocalInstructionProfile.Name(rawValue: name) else { return nil }
            let text = builtinTextProvider(name)
            guard let profile = LocalInstructionProfile(name: profileName, text: text) else { return nil }
            let label: String
            switch profileName {
            case .explain: label = "전체 해설"
            case .continue: label = "변경분만"
            case .normalize: label = "음성 대본 정규화"
            }
            return ApprovedInstructionPayload(
                target: target,
                label: label,
                origin: "builtin",
                revision: profile.revision,
                instructions: profile.text
            )
        case .local(let id):
            guard let entry = catalog.entry(id: id) else { return nil }
            return ApprovedInstructionPayload(
                target: target,
                label: entry.label,
                origin: entry.origin,
                revision: entry.revision,
                instructions: entry.body
            )
        }
    }

    // MARK: - Harness-initiated pairing

    @discardableResult
    func startPairing(duration: TimeInterval = AgentSessionPolicy.maxPairingWindowSeconds) -> Bool {
        stopPairing()
        guard policy.startPairing(duration: duration) else { return false }
        let listener = AgentUnixSocketListener(
            directory: directory,
            endpoint: "pair.sock",
            maxFrameBytes: 4 * 1024,
            authenticatePeer: authenticatePeer
        ) { [weak self] principal, frame in
            Self.runOnMain { self?.handlePairKnock(principal: principal, frame: frame) }
        }
        guard listener.start() else {
            policy.stopPairing()
            statusMessage = "에이전트 연결 대기 소켓(pair.sock)을 열 수 없습니다."
            syncState()
            return false
        }
        pairSocket = listener
        let work = DispatchWorkItem { [weak self, weak listener] in
            guard let self, let listener, self.pairSocket === listener else { return }
            self.stopPairing()
        }
        pairExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        statusMessage = "에이전트 하네스의 연결 요청을 기다리는 중입니다 (최대 \(Int(duration))초)."
        syncState()
        return true
    }

    func stopPairing() {
        pairExpiry?.cancel(); pairExpiry = nil
        pairSocket?.stop(); pairSocket = nil
        policy.stopPairing()
        syncState()
    }

    @discardableResult
    func approveCandidate(fingerprint: String) -> Bool {
        switch policy.approvePairing(candidateFingerprint: fingerprint) {
        case .failure(let error):
            statusMessage = error.localizedDescription
            syncState()
            return false
        case .success(let session):
            stopPairing()
            stopReadSocket()
            stopReceiptSocket()
            statusMessage = "서명된 도우미 연결됨 (PID \(session.principal.pid)). 읽기 또는 받기는 별도로 허용하세요."
            syncState()
            return true
        }
    }

    func denyCandidate(fingerprint: String) {
        policy.denyPairing(candidateFingerprint: fingerprint)
        syncState()
    }

    @discardableResult
    func pinDirectPrincipal(_ principal: HelperPrincipal, clientName: String = "Pinned Helper") -> PinnedHelperSession {
        stopPairing()
        stopReadSocket()
        stopReceiptSocket()
        let session = policy.pinDirectPrincipal(principal, clientName: clientName)
        syncState()
        return session
    }

    func endSession() {
        stopPairing()
        stopReadSocket()
        stopReceiptSocket()
        policy.endSession()
        statusMessage = "에이전트 도우미 연결을 해제했습니다."
        syncState()
    }

    // MARK: - Separate Read Grant (`i.sock`)

    @discardableResult
    func grantRead(target: InstructionTarget, duration: TimeInterval = AgentSessionPolicy.maxLeaseSeconds) -> Bool {
        guard let payload = approvedPayload(for: target) else {
            statusMessage = "공유할 지시문이 비어 있거나 8,192바이트를 초과했습니다."
            return false
        }
        switch policy.grantRead(payload: payload, duration: duration) {
        case .failure(let error):
            statusMessage = error.localizedDescription
            syncState()
            return false
        case .success:
            stopReadSocket()
            onBeforeOpenReadSocket?()
            let listener = AgentUnixSocketListener(
                directory: directory,
                endpoint: "i.sock",
                maxFrameBytes: 1024,
                authenticatePeer: authenticatePeer
            ) { [weak self] principal, frame in
                Self.runOnMain { self?.handleReadRequest(principal: principal, frame: frame) }
            }
            guard listener.start() else {
                policy.revokeRead(reason: .manual)
                statusMessage = "지시 조회 소켓(i.sock)을 시작할 수 없습니다. 기존 소켓을 확인하세요."
                syncState()
                return false
            }
            readSocket = listener
            let work = DispatchWorkItem { [weak self, weak listener] in
                guard let self, let listener, self.readSocket === listener else { return }
                self.revokeRead(reason: .expired)
            }
            readExpiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
            statusMessage = "‘\(payload.label)’ 지시문 조회를 허용했습니다 (최대 10분)."
            syncState()
            return true
        }
    }

    func revokeRead(reason: ReadRevokeReason = .manual) {
        stopReadSocket()
        policy.revokeRead(reason: reason)
        if reason == .edited {
            statusMessage = "지시문이 수정되어 기존 조회 허용이 철회되었습니다."
        } else if reason == .deleted {
            statusMessage = "지시문이 삭제되어 조회 허용이 철회되었습니다."
        }
        syncState()
    }

    func revokeReadIfMutated(targetWireName: String) {
        if policy.revokeReadForContentMutation(targetWireName: targetWireName) {
            stopReadSocket()
            statusMessage = "지시문이 수정되어 기존 조회 허용이 철회되었습니다."
            syncState()
        }
    }

    func revokeReadIfDeleted(entryID: String) {
        if policy.revokeReadForDeletion(entryID: entryID) {
            stopReadSocket()
            statusMessage = "지시문이 삭제되어 조회 허용이 철회되었습니다."
            syncState()
        }
    }

    // MARK: - Separate Receipt Grant (`d.sock`)

    @discardableResult
    func grantReceipt(duration: TimeInterval = AgentSessionPolicy.maxLeaseSeconds) -> Bool {
        switch policy.grantReceipt(duration: duration) {
        case .failure(let error):
            statusMessage = error.localizedDescription
            syncState()
            return false
        case .success:
            stopReceiptSocket()
            onBeforeOpenReceiptSocket?()
            let listener = AgentUnixSocketListener(
                directory: directory,
                endpoint: "d.sock",
                maxFrameBytes: 100 * 1024,
                authenticatePeer: authenticatePeer
            ) { [weak self] principal, frame in
                Self.runOnMain { self?.handleDraftRequest(principal: principal, frame: frame) }
            }
            guard listener.start() else {
                policy.revokeReceipt()
                statusMessage = "대본 수신 소켓(d.sock)을 시작할 수 없습니다. 기존 소켓을 확인하세요."
                syncState()
                return false
            }
            receiptSocket = listener
            let work = DispatchWorkItem { [weak self, weak listener] in
                guard let self, let listener, self.receiptSocket === listener else { return }
                self.revokeReceipt()
            }
            receiptExpiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
            statusMessage = "외부 대본 받기를 허용했습니다 (최대 10분, 20건/임대)."
            syncState()
            return true
        }
    }

    func revokeReceipt() {
        stopReceiptSocket()
        policy.revokeReceipt()
        syncState()
    }

    // MARK: - IPC Handlers (MainActor)

    func handlePairKnock(principal: HelperPrincipal, frame: Data) -> Data {
        guard !frame.contains(0),
              let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              Set(object.keys).isSubset(of: ["op", "client_name"]),
              (object["op"] as? String) == "pair_knock" else {
            return Self.jsonReply(["status": "invalid"])
        }
        let clientName: String
        if let rawName = object["client_name"] {
            guard let s = rawName as? String else { return Self.jsonReply(["status": "invalid"]) }
            clientName = s
        } else {
            clientName = "MCP Client"
        }
        let outcome = policy.recordPairingKnock(principal, clientName: clientName)
        syncState()
        switch outcome {
        case .closed: return Self.jsonReply(["status": "closed"])
        case .invalidPrincipal: return Self.jsonReply(["status": "rejected"])
        case .alreadyPinned: return Self.jsonReply(["status": "already_pinned"])
        case .queued:
            statusMessage = "에이전트 연결 요청 도착 (PID \(principal.pid)) — 승인 또는 거절하세요."
            return Self.jsonReply(["status": "pending_approval"])
        }
    }

    func handleReadRequest(principal: HelperPrincipal, frame: Data) -> Data? {
        guard !frame.contains(0),
              let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: String],
              object.count == 1,
              let wireName = object["target"] ?? object["profile"],
              InstructionTarget(wireName: wireName) != nil else {
            return nil
        }
        let outcome = policy.serveRead(from: principal, targetWireName: wireName)
        syncState()
        switch outcome {
        case .unauthorizedPeer, .readDisabled, .wrongTarget:
            return nil
        case .served(let payload, let proof):
            let response: [String: Any] = [
                "schema_version": 2,
                "target": payload.target.wireName,
                "profile": payload.target.wireName,
                "label": payload.label,
                "origin": payload.origin,
                "revision": payload.revision,
                "instructions": payload.instructions,
                "delivery_proof": proof,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes]),
                  data.count < 52 * 1024 else {
                return nil
            }
            return data
        }
    }

    func handleDraftRequest(principal: HelperPrincipal, frame: Data) -> Data {
        guard !frame.contains(0),
              String(data: frame, encoding: .utf8) != nil,
              let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else {
            return Self.jsonReply(["status": "invalid"])
        }
        let allowedKeys: Set<String> = [
            "idempotency_key", "display_text", "speech_text",
            "late_draft", "instruction_target", "instruction_revision", "delivery_proof",
        ]
        guard Set(object.keys).isSubset(of: allowedKeys),
              let id = object["idempotency_key"] as? String,
              let display = object["display_text"] as? String else {
            return Self.jsonReply(["status": "invalid"])
        }

        let speech: String?
        if let rawSpeech = object["speech_text"] {
            guard let s = rawSpeech as? String else { return Self.jsonReply(["status": "invalid"]) }
            speech = s
        } else {
            speech = nil
        }

        let lateFlag: Bool
        if let rawLate = object["late_draft"] {
            guard let flag = rawLate as? Bool else { return Self.jsonReply(["status": "invalid"]) }
            lateFlag = flag
        } else {
            lateFlag = false
        }

        func optString(_ key: String) -> (valid: Bool, value: String?) {
            guard let raw = object[key] else { return (true, nil) }
            guard let str = raw as? String, !str.isEmpty else { return (false, nil) }
            return (true, str)
        }
        let targetField = optString("instruction_target")
        let revField = optString("instruction_revision")
        let proofField = optString("delivery_proof")
        guard targetField.valid, revField.valid, proofField.valid else {
            return Self.jsonReply(["status": "invalid"])
        }

        let meta = DraftSubmissionMeta(
            lateDraft: lateFlag,
            instructionTarget: targetField.value,
            instructionRevision: revField.value,
            deliveryProof: proofField.value
        )
        let provenance = meta.isMarkedLate
            ? ExplanationDraft.Provenance(
                target: meta.instructionTarget,
                revision: meta.instructionRevision,
                verifiedLate: true
            )
            : nil
        guard let draft = ExplanationDraft(id: id, display: display, speech: speech, provenance: provenance) else {
            return Self.jsonReply(["status": "invalid"])
        }

        let peek = drafts.peekReceiptStatus(for: draft)
        let auth = policy.authorizeDraft(
            from: principal,
            meta: meta,
            isKnownDuplicateOrConflict: (peek == .duplicate || peek == .conflict)
        )
        switch auth {
        case .unauthorizedPeer, .receiptDisabled:
            return Self.jsonReply(["status": "disabled"])
        case .unprovenLateDraft:
            return Self.jsonReply(["status": "unproven"])
        case .rateLimited:
            return Self.jsonReply(["status": "rate_limited"])
        case .grantLimitReached:
            return Self.jsonReply(["status": "grant_limit"])
        case .authorized:
            let receipt = drafts.receive(draft)
            if receipt == .accepted {
                policy.recordAcceptedDraft()
            }
            syncState()
            return Self.jsonReply(["status": receipt.rawValue])
        }
    }

    // MARK: - Private helpers

    private func stopReadSocket() {
        readExpiry?.cancel(); readExpiry = nil
        readSocket?.stop(); readSocket = nil
    }

    private func stopReceiptSocket() {
        receiptExpiry?.cancel(); receiptExpiry = nil
        receiptSocket?.stop(); receiptSocket = nil
    }

    private func syncState() {
        policy.pruneExpired()
        isPairingOpen = policy.isPairingOpen
        pendingCandidates = policy.pendingCandidates
        pinnedSession = policy.pinnedSession
        activeReadGrant = policy.readGrant
        activeReceiptGrant = policy.receiptGrant
        proofCount = policy.deliveryProofs.count
        remainingDraftsInGrant = policy.remainingDraftsInGrant
        lastReadRevokeReason = policy.lastReadRevokeReason

        let builtinName: LocalInstructionProfile.Name?
        if case .builtin(let name) = activeReadGrant?.payload.target {
            builtinName = LocalInstructionProfile.Name(rawValue: name)
        } else {
            builtinName = nil
        }
        onReadGrantStateChanged?(builtinName)
        onReceiptGrantStateChanged?(activeReceiptGrant != nil ? pinnedSession?.principal.pid : nil)
    }

    private nonisolated static func jsonReply(_ dict: [String: String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{\"status\":\"invalid\"}".utf8)
    }

    private nonisolated static func runOnMain(_ work: @escaping @MainActor () -> Data?) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        let deadline = DispatchTime.now() + .milliseconds(750)
        DispatchQueue.main.async {
            defer { semaphore.signal() }
            guard DispatchTime.now() < deadline else { return }
            box.store(work())
        }
        guard semaphore.wait(timeout: deadline) == .success else { return nil }
        return box.load()
    }

    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?
        func store(_ data: Data?) { lock.lock(); defer { lock.unlock() }; value = data }
        func load() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
