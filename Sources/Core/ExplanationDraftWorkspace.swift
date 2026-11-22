import Combine
import CryptoKit
import Foundation

/// The payload of a receive-only operation. The user may edit or discard it later.
struct ExplanationDraft: Identifiable, Sendable {
    static let maxTextBytes = 8 * 1024
    let id: String
    let display: String
    let speech: String?
    let provenance: AgentDraftOrigin?
    let sourceSession: UUID?
    var displayHash: String { AgentBytes.hash(Data(display.utf8)) }

    init?(id: String, display: String, speech: String?, provenance: AgentDraftOrigin? = nil, sourceSession: UUID? = nil) {
        guard (1...128).contains(id.utf8.count),
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }),
              Self.validText(display), speech.map(Self.validText) ?? true else { return nil }
        self.id = id
        self.display = display
        self.speech = speech
        self.provenance = provenance
        self.sourceSession = sourceSession
    }

    private static func validText(_ value: String) -> Bool {
        value.utf8.count <= maxTextBytes && !value.utf8.contains(0)
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var fingerprint: SHA256.Digest {
        // The separator cannot occur in either field. Missing speech is distinct
        // from every valid (nonblank) supplied speech string.
        let scope = provenance.map { "\($0.principal.uuidString)\0\($0.selector)\0\($0.revision.uuidString)\0" } ?? sourceSession.map { "\($0.uuidString)\0unassociated\0" } ?? ""
        return SHA256.hash(data: Data((scope + display + "\0" + (speech ?? "")).utf8))
    }
}

/// Owns only in-memory drafts and the editable selection. No provider dependency.
@MainActor
final class ExplanationDraftWorkspace: ObservableObject {
    enum Receipt: String { case accepted, duplicate, conflict, busy }
    enum Origin: String {
        case manual = "직접 입력"
        case pasted = "붙여넣음"
        case received = "받은 대본"
    }

    struct DocumentTab: Identifiable {
        let id: String
        let title: String
        let dirty: Bool
    }

    private struct ParkedDocument {
        let original: ExplanationDraft?
        let display: String
        let speech: String
        let speechNeedsReview: Bool
        let confirmedDisplayHash: String?
        let confirmedSpeechHash: String?
        let provenance: AgentDraftOrigin?
        let origin: Origin?
        let hasManualEdits: Bool

        var dirty: Bool {
            guard let original else { return !display.isEmpty || !speech.isEmpty }
            return !AgentBytes.same(display, original.display) || !AgentBytes.same(speech, original.speech ?? "")
        }
    }

    static let maxDocuments = 6
    private static let maxParkedBytes = 256 * 1024
    @Published private(set) var activeDocumentID: String?
    @Published private(set) var activeOriginal: ExplanationDraft?
    @Published private var parked: [String: ParkedDocument] = [:]
    @Published private var tabOrder: [String] = []

    var canRevertReceived: Bool { activeOriginal != nil && capturedDocument.dirty }
    var documentTabs: [DocumentTab] {
        tabOrder.compactMap { id in
            let document = id == activeDocumentID ? capturedDocument : parked[id]
            return document.map { value in
                let heading = value.original?.display.split(whereSeparator: \.isNewline).first
                let title = heading.map { String($0.prefix(32)) } ?? "직접 입력"
                return DocumentTab(id: id, title: title, dirty: value.dirty)
            }
        }
    }

    private var capturedDocument: ParkedDocument {
        ParkedDocument(original: activeOriginal, display: display, speech: speech,
                       speechNeedsReview: speechNeedsReview, confirmedDisplayHash: confirmedDisplayHash,
                       confirmedSpeechHash: confirmedSpeechHash, provenance: provenance,
                       origin: origin, hasManualEdits: hasManualEdits)
    }

    static let maxPending = 8
    private static let maxRecent = 128
    @Published private(set) var pending: [ExplanationDraft] = []
    @Published private(set) var display = ""
    @Published private(set) var speech = ""
    @Published private(set) var speechNeedsReview = false
    @Published private(set) var provenance: AgentDraftOrigin?
    private var confirmedDisplayHash: String?
    private var confirmedSpeechHash: String?
    @Published private(set) var origin: Origin?
    @Published private(set) var hasManualEdits = false
    @Published private(set) var receiverPID: Int32?
    private var recent: [String: SHA256.Digest] = [:]
    private var receiptOrder: [String] = []

    /// Immediately visible in the workspace, newest first; never replaces an editor.
    var immediatePreviews: [ExplanationDraft] { Array(pending.reversed()) }

    var hasEditorContent: Bool { !display.isEmpty || !speech.isEmpty }

    func setReceiver(_ pid: Int32?) { receiverPID = pid }

    func preflight(_ draft: ExplanationDraft) -> Receipt {
        let retained = parked.values.compactMap(\.original) + [activeOriginal].compactMap { $0 }
        let previous = recent[draft.id] ?? (retained + pending).first(where: { $0.id == draft.id })?.fingerprint
        if let previous { return previous == draft.fingerprint ? .duplicate : .conflict }
        if (draft.provenance != nil || draft.sourceSession != nil) && (recent.values.contains(draft.fingerprint)
            || (retained + pending).contains(where: { $0.fingerprint == draft.fingerprint })) { return .duplicate }
        return pending.count < Self.maxPending ? .accepted : .busy
    }

    func preflightDocument(_ draft: ExplanationDraft) -> Receipt {
        let result = preflight(draft)
        guard result == .accepted else { return result }
        let active = capturedDocument
        let preserve = active.dirty
        guard parked.count + (preserve ? 2 : 1) <= Self.maxDocuments else { return .busy }
        let bytes = parked.values.reduce(0) { $0 + $1.display.utf8.count + $1.speech.utf8.count }
        guard !preserve || bytes + active.display.utf8.count + active.speech.utf8.count <= Self.maxParkedBytes else {
            return .busy
        }
        return .accepted
    }

    /// Live agent receipt updates the visible editor and never starts playback.
    /// Only a clean active document may be replaced. Dirty documents turn into tabs.
    func receiveDocument(_ draft: ExplanationDraft) -> Receipt {
        let result = preflightDocument(draft)
        guard result == .accepted else { return result }
        let active = capturedDocument
        let preserve = active.dirty
        if preserve {
            let id = activeDocumentID ?? UUID().uuidString
            if !tabOrder.contains(id) { tabOrder.append(id) }
            parked[id] = active
        } else if let id = activeDocumentID {
            tabOrder.removeAll { $0 == id }
        }
        recordReceipt(draft)
        installReceived(draft)
        return .accepted
    }

    func selectDocument(_ id: String) {
        guard id != activeDocumentID, let next = parked[id] else { return }
        let active = capturedDocument
        let currentID = activeDocumentID ?? UUID().uuidString
        parked.removeValue(forKey: id)
        if activeDocumentID != nil || active.dirty {
            parked[currentID] = active
            if !tabOrder.contains(currentID) { tabOrder.append(currentID) }
        }
        activeDocumentID = id
        activeOriginal = next.original
        display = next.display
        speech = next.speech
        speechNeedsReview = next.speechNeedsReview
        confirmedDisplayHash = next.confirmedDisplayHash
        confirmedSpeechHash = next.confirmedSpeechHash
        provenance = next.provenance
        origin = next.origin
        hasManualEdits = next.hasManualEdits
    }

    func closeInactiveDocument(_ id: String) {
        guard id != activeDocumentID else { return }
        parked.removeValue(forKey: id)
        tabOrder.removeAll { $0 == id }
    }

    func revertReceivedDocument() {
        guard let original = activeOriginal, canRevertReceived else { return }
        installReceived(original)
    }

    private func installReceived(_ value: ExplanationDraft) {
        activeDocumentID = value.id
        activeOriginal = value
        if !tabOrder.contains(value.id) { tabOrder.append(value.id) }
        display = value.display
        speech = value.speech ?? ""
        confirmedDisplayHash = nil
        confirmedSpeechHash = nil
        speechNeedsReview = value.speech.map { !AgentBytes.same(value.display, $0) } ?? false
        provenance = value.provenance
        origin = .received
        hasManualEdits = false
    }

    private func recordReceipt(_ draft: ExplanationDraft) {
        recent[draft.id] = draft.fingerprint
        receiptOrder.append(draft.id)
        if receiptOrder.count > Self.maxRecent { recent.removeValue(forKey: receiptOrder.removeFirst()) }
    }

    func receive(_ draft: ExplanationDraft) -> Receipt {
        let preview = preflight(draft)
        guard preview == .accepted else { return preview }
        recordReceipt(draft)
        pending.append(draft)
        return .accepted
    }

    /// Deliberately invoked by the editor, never by the transport.
    @discardableResult
    func open(_ id: String, replace: Bool = false) -> Bool {
        guard (!hasEditorContent || replace), let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        let value = pending.remove(at: index)
        if let id = activeDocumentID { tabOrder.removeAll { $0 == id } }
        installReceived(value)
        return true
    }

    func discard(_ id: String) { pending.removeAll { $0.id == id } }

    func editDisplay(_ value: String, pasted: Bool = false) {
        guard !display.utf8.elementsEqual(value.utf8) else { return }
        if !speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { speechNeedsReview = true }
        confirmedDisplayHash = nil
        confirmedSpeechHash = nil
        display = value
        if pasted { origin = .pasted }
        else if origin == nil { origin = .manual }
        hasManualEdits = !pasted
    }

    func editSpeech(_ value: String) {
        guard !speech.utf8.elementsEqual(value.utf8) else { return }
        speech = value
        confirmedDisplayHash = nil
        confirmedSpeechHash = nil
        let nonblank = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        speechNeedsReview = nonblank && (speechNeedsReview || !AgentBytes.same(value, display))
        if origin == nil { origin = .manual }
        hasManualEdits = true
    }

    func confirmSpeech() {
        confirmedDisplayHash = AgentBytes.hash(Data(display.utf8))
        confirmedSpeechHash = AgentBytes.hash(Data(speech.utf8))
        speechNeedsReview = false
    }

    func clearEditor() {
        if let id = activeDocumentID { tabOrder.removeAll { $0 == id } }
        activeDocumentID = nil
        activeOriginal = nil
        display = ""
        speech = ""
        speechNeedsReview = false
        confirmedDisplayHash = nil
        confirmedSpeechHash = nil
        provenance = nil
        origin = nil
        hasManualEdits = false
    }

    /// When the screen text has changed, the old script cannot be read
    /// until reviewed. Reading the displayed text is a separate explicit choice.
    func playback(displayOnly: Bool = false) -> (display: String, speech: String)? {
        let screen = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !screen.isEmpty, !display.utf8.contains(0) else { return nil }
        if screen == CodeExplanation.noChange, provenance?.selector == "continue" { return nil }
        let hasSpeech = !speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let spoken = displayOnly || !hasSpeech ? display : speech
        if !displayOnly && hasSpeech {
            guard !speechNeedsReview else { return nil }
            if !AgentBytes.same(display, speech) {
                guard confirmedDisplayHash == AgentBytes.hash(Data(display.utf8)),
                      confirmedSpeechHash == AgentBytes.hash(Data(speech.utf8)) else { return nil }
            }
        }
        guard AgentBytes.safeForSpeech(spoken) else { return nil }
        return (display, spoken)
    }
}
