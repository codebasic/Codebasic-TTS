import CryptoKit
import Foundation

/// Which explain instruction template/profile the user is inspecting, editing,
/// or permitting an external agent to read.
enum ExplainInstructionMode: String, CaseIterable, Identifiable, Equatable, Codable {
    case full = "explain"
    case delta = "continue"

    var id: String { rawValue }
    var profileName: String { rawValue }
    var label: String {
        switch self {
        case .full: return "전체 해설"
        case .delta: return "변경분만"
        }
    }
}

/// Single source of truth for assembling the final instruction string shown in
/// the preview, copied to the clipboard, and returned over read-only MCP.
enum ExplainInstructionComposer {
    static let maxProfileBytes = 8 * 1024

    static func finalInstruction(
        mode: ExplainInstructionMode,
        fullTemplate: String,
        deltaTemplate: String,
        outputStyleRules: String,
        defaultFull: String,
        defaultDelta: String
    ) -> String {
        let base = fullTemplate.isEmpty ? defaultFull : fullTemplate
        let full = base + "\n\n" + outputStyleRules
        switch mode {
        case .full:
            return full
        case .delta:
            let delta = deltaTemplate.isEmpty ? defaultDelta : deltaTemplate
            return full + "\n\n" + delta
        }
    }

    /// Matches `LocalInstructionProfile.revision` (`tts-profile-v1\0<profile>\0<text>`).
    static func revision(profileName: String, text: String) -> String {
        SHA256.hash(data: Data("tts-profile-v1\0\(profileName)\0\(text)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Active read-only MCP grant snapshot (in-memory only).
struct InstructionShareGrant: Equatable {
    let profileName: String
    let peerPID: Int32
    let revision: String
    let instructions: String
    let approvedAt: Date
    let expiresAt: Date

    var shortRevision: String { String(revision.prefix(8)) }

    var mode: ExplainInstructionMode? {
        ExplainInstructionMode(rawValue: profileName)
    }

    var profileLabel: String {
        switch profileName {
        case ExplainInstructionMode.full.profileName: return ExplainInstructionMode.full.label
        case ExplainInstructionMode.delta.profileName: return ExplainInstructionMode.delta.label
        default: return "음성 대본 정규화"
        }
    }
}

enum InstructionShareRevokeReason: Equatable {
    case manual
    case edited
    case expired
    case terminated
}

/// Explicit, pull-only MCP permission state.
/// Never describes a grant as "전송됨" (sent) or "생성 중" (generating).
enum InstructionShareState: Equatable {
    case inactive
    case allowed(InstructionShareGrant)
    case revoked(InstructionShareRevokeReason)

    var activeGrant: InstructionShareGrant? {
        if case .allowed(let grant) = self { return grant }
        return nil
    }

    func allows(mode: ExplainInstructionMode, revision: String) -> Bool {
        guard case .allowed(let grant) = self else { return false }
        return grant.profileName == mode.profileName && grant.revision == revision
    }

    func statusTitle(for viewingMode: ExplainInstructionMode) -> String {
        switch self {
        case .inactive:
            return "MCP 조회 비허용"
        case .allowed(let grant):
            if grant.profileName == viewingMode.profileName {
                return "MCP 조회 허용됨 (대기 중)"
            }
            return "현재 양식은 조회 비허용"
        case .revoked(.manual):
            return "MCP 조회 허용 취소됨"
        case .revoked(.edited):
            return "지시문 수정으로 조회 허용 철회됨"
        case .revoked(.expired):
            return "조회 허용 만료됨"
        case .revoked(.terminated):
            return "앱 종료로 조회 허용 종료됨"
        }
    }

    func statusDetail(for viewingMode: ExplainInstructionMode) -> String {
        switch self {
        case .inactive:
            return "에이전트 조회가 꺼져 있습니다. 아래에서 도우미 PID를 지정해 이 지시문만 읽기 허용할 수 있습니다."
        case .allowed(let grant):
            if grant.profileName == viewingMode.profileName {
                return "PID \(grant.peerPID)가 ‘\(grant.profileLabel)’ 지시문(#\(grant.shortRevision))을 읽을 수 있습니다. 에이전트가 직접 조회할 때까지 앱은 아무 것도 보내지 않습니다."
            }
            return "현재 PID \(grant.peerPID)에는 ‘\(grant.profileLabel)’(#\(grant.shortRevision))만 허용되어 있습니다. 현재 선택한 ‘\(viewingMode.label)’은 조회할 수 없습니다."
        case .revoked(.manual):
            return "사용자가 조회 허용을 취소했습니다."
        case .revoked(.edited):
            return "지시문이 바뀌어 기존 조회 허용이 자동 철회되었습니다. 다시 허용해야 조회할 수 있습니다."
        case .revoked(.expired):
            return "허용 시간(10분)이 지나 자동 종료되었습니다."
        case .revoked(.terminated):
            return "세션 종료로 조회 허용이 해제되었습니다."
        }
    }
}

/// Validated explain draft submitted by an external agent over `e.sock`.
struct ExplainDraftPayload: Equatable {
    static let maxTextBytes = 16 * 1024
    static let maxKeyBytes = 128

    let displayText: String
    let spokenText: String?
    let mode: ExplainInstructionMode
    let idempotencyKey: String
    let instructionRevision: String?

    init?(
        displayText: String,
        spokenText: String? = nil,
        mode: ExplainInstructionMode = .full,
        idempotencyKey: String,
        instructionRevision: String? = nil
    ) {
        guard Self.isValidText(displayText) else { return nil }
        if let spokenText, !Self.isValidText(spokenText) { return nil }
        guard Self.isValidKey(idempotencyKey) else { return nil }
        if let instructionRevision, !Self.isValidRevision(instructionRevision) { return nil }

        self.displayText = displayText
        self.spokenText = spokenText
        self.mode = mode
        self.idempotencyKey = idempotencyKey
        self.instructionRevision = instructionRevision
    }

    private static func isValidText(_ s: String) -> Bool {
        !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !s.contains("\0")
            && s.utf8.count <= maxTextBytes
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= maxKeyBytes else { return false }
        return key.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isValidRevision(_ rev: String) -> Bool {
        guard rev.utf8.count == 64 else { return false }
        return rev.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func canonicalDigest() -> Data {
        let spokenFlag = spokenText != nil ? "1" : "0"
        let revFlag = instructionRevision != nil ? "1" : "0"
        let canonical = "explain-draft-v1\0\(mode.rawValue)\0\(displayText)\0\(spokenFlag)\0\(spokenText ?? "")\0\(revFlag)\0\(instructionRevision ?? "")"
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }
}

/// An external-agent draft stored in the Explain inbox (separate from the editor).
struct ReceivedExplainDraft: Identifiable, Equatable {
    let id: UUID
    let idempotencyKey: String
    let receivedAt: Date
    let mode: ExplainInstructionMode
    let displayText: String
    let spokenText: String?
    let instructionRevision: String?

    var hasSeparateSpokenText: Bool {
        guard let spokenText else { return false }
        return !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isNoChangeSentinel: Bool {
        displayText.trimmingCharacters(in: .whitespacesAndNewlines) == "변경 없음"
    }
}

struct ExplainDraftReceipt: Equatable {
    enum Status: String, Equatable {
        case accepted
        case duplicate
        case conflict
        case invalid
    }

    let status: Status
    let draft: ReceivedExplainDraft?
}

enum ExplainPlaybackPlan: Equatable {
    case empty
    case ready(spokenText: String, displayText: String, usesSeparateSpoken: Bool)
    case requiresConfirmation(displayText: String, staleSpokenText: String)
}

/// Separate display (subtitle) vs spoken (TTS) editing state.
/// Editing `displayText` never rewrites `spokenText`; if `spokenText` was aligned
/// to an older `displayText`, `isSpokenStale` becomes true and playback pauses for confirmation.
struct ExplainEditorState: Equatable {
    private(set) var displayText: String = ""
    private(set) var spokenText: String = ""
    private(set) var spokenSyncedDisplayText: String? = nil
    private(set) var loadedDraftID: UUID? = nil
    private(set) var isDirty: Bool = false

    var hasDisplayText: Bool {
        !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasSpokenText: Bool {
        !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEmpty: Bool { !hasDisplayText && !hasSpokenText }

    var isSpokenStale: Bool {
        guard hasSpokenText else { return false }
        guard let synced = spokenSyncedDisplayText else { return true }
        return !displayText.utf8.elementsEqual(synced.utf8)
    }

    mutating func updateDisplayText(_ text: String) {
        guard !displayText.utf8.elementsEqual(text.utf8) else { return }
        displayText = text
        isDirty = true
    }

    mutating func updateSpokenText(_ text: String) {
        let sameBytes = spokenText.utf8.elementsEqual(text.utf8)
        spokenText = text
        if hasSpokenText {
            spokenSyncedDisplayText = displayText
        } else {
            spokenSyncedDisplayText = nil
        }
        if !sameBytes { isDirty = true }
    }

    mutating func clearSpokenText() {
        let changed = !spokenText.isEmpty || spokenSyncedDisplayText != nil
        spokenText = ""
        spokenSyncedDisplayText = nil
        if changed { isDirty = true }
    }

    mutating func acknowledgeSpokenMatchesDisplay() {
        guard hasSpokenText else { return }
        spokenSyncedDisplayText = displayText
    }

    mutating func load(_ draft: ReceivedExplainDraft) {
        displayText = draft.displayText
        if let spoken = draft.spokenText,
           !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            spokenText = spoken
            spokenSyncedDisplayText = draft.displayText
        } else {
            spokenText = ""
            spokenSyncedDisplayText = nil
        }
        loadedDraftID = draft.id
        isDirty = false
    }

    mutating func append(_ draft: ReceivedExplainDraft) {
        if isEmpty {
            load(draft)
            return
        }
        let wasStale = isSpokenStale
        let hadSpoken = hasSpokenText
        let previousDisplay = displayText
        let hadPreviousDisplay = !previousDisplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !hadPreviousDisplay {
            displayText = draft.displayText
        } else {
            displayText += "\n\n" + draft.displayText
        }

        if let newSpoken = draft.spokenText,
           !newSpoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !hadSpoken {
                spokenText = hadPreviousDisplay ? (previousDisplay + "\n\n" + newSpoken) : newSpoken
                spokenSyncedDisplayText = displayText
            } else {
                spokenText += "\n\n" + newSpoken
                if !wasStale {
                    spokenSyncedDisplayText = displayText
                }
            }
        }
        loadedDraftID = draft.id
        isDirty = true
    }

    mutating func clear() {
        displayText = ""
        spokenText = ""
        spokenSyncedDisplayText = nil
        loadedDraftID = nil
        isDirty = false
    }

    func playbackPlan(allowStaleSpoken: Bool = false) -> ExplainPlaybackPlan {
        guard !isEmpty else { return .empty }
        if !hasSpokenText {
            return .ready(spokenText: displayText, displayText: displayText, usesSeparateSpoken: false)
        }
        if isSpokenStale && !allowStaleSpoken {
            return .requiresConfirmation(displayText: displayText, staleSpokenText: spokenText)
        }
        let subtitle = hasDisplayText ? displayText : spokenText
        return .ready(spokenText: spokenText, displayText: subtitle, usesSeparateSpoken: true)
    }

    func displayOnlyPlaybackPlan() -> ExplainPlaybackPlan {
        guard hasDisplayText else { return .empty }
        return .ready(spokenText: displayText, displayText: displayText, usesSeparateSpoken: false)
    }
}

/// Coordinator for the Explain draft inbox and the separate editor.
/// Incoming MCP drafts land only in `receivedDrafts` (never overwrite `editor` or trigger playback).
struct ExplainWorkspaceState: Equatable {
    static let maxInboxCount = 50
    static let maxIdempotencyEntries = 128

    private(set) var receivedDrafts: [ReceivedExplainDraft] = []
    var selectedDraftID: UUID? = nil
    var editor = ExplainEditorState()

    private var seenKeys: [String: Data] = [:]
    private var seenDraftIDs: [String: UUID] = [:]
    private var seenOrder: [String] = []

    var selectedDraft: ReceivedExplainDraft? {
        if let selectedDraftID, let match = receivedDrafts.first(where: { $0.id == selectedDraftID }) {
            return match
        }
        return receivedDrafts.first
    }

    mutating func receive(_ payload: ExplainDraftPayload, now: Date = Date()) -> ExplainDraftReceipt {
        let digest = payload.canonicalDigest()
        if let existingDigest = seenKeys[payload.idempotencyKey] {
            if existingDigest == digest {
                let existing = seenDraftIDs[payload.idempotencyKey].flatMap { id in
                    receivedDrafts.first(where: { $0.id == id })
                }
                return ExplainDraftReceipt(status: .duplicate, draft: existing)
            }
            return ExplainDraftReceipt(status: .conflict, draft: nil)
        }

        if seenOrder.count >= Self.maxIdempotencyEntries {
            let oldest = seenOrder.removeFirst()
            seenKeys.removeValue(forKey: oldest)
            seenDraftIDs.removeValue(forKey: oldest)
        }

        let draft = ReceivedExplainDraft(
            id: UUID(),
            idempotencyKey: payload.idempotencyKey,
            receivedAt: now,
            mode: payload.mode,
            displayText: payload.displayText,
            spokenText: payload.spokenText,
            instructionRevision: payload.instructionRevision
        )
        seenKeys[payload.idempotencyKey] = digest
        seenDraftIDs[payload.idempotencyKey] = draft.id
        seenOrder.append(payload.idempotencyKey)

        receivedDrafts.insert(draft, at: 0)
        if receivedDrafts.count > Self.maxInboxCount {
            receivedDrafts.removeLast()
        }
        selectedDraftID = draft.id
        return ExplainDraftReceipt(status: .accepted, draft: draft)
    }

    @discardableResult
    mutating func loadDraftIntoEditor(id: UUID) -> Bool {
        guard let draft = receivedDrafts.first(where: { $0.id == id }) else { return false }
        editor.load(draft)
        selectedDraftID = id
        return true
    }

    @discardableResult
    mutating func appendDraftToEditor(id: UUID) -> Bool {
        guard let draft = receivedDrafts.first(where: { $0.id == id }) else { return false }
        editor.append(draft)
        selectedDraftID = id
        return true
    }

    mutating func dismissDraft(id: UUID) {
        receivedDrafts.removeAll { $0.id == id }
        if selectedDraftID == id {
            selectedDraftID = receivedDrafts.first?.id
        }
    }

    mutating func clearInbox() {
        receivedDrafts.removeAll()
        selectedDraftID = nil
    }

    /// Reset session idempotency tracking only when the MCP draft intake session stops.
    mutating func resetSessionIdempotency() {
        seenKeys.removeAll()
        seenDraftIDs.removeAll()
        seenOrder.removeAll()
    }
}
