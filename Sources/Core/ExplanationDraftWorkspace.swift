import Combine
import CryptoKit
import Foundation

/// The payload of a receive-only operation. The user may edit or discard it later.
struct ExplanationDraft: Identifiable, Sendable, Codable {
    static let maxTextBytes = 8 * 1024
    let id: String
    let display: String
    let speech: String?
    let provenance: AgentDraftOrigin?
    /// A name for lists and headers only. It is never put into `display` or
    /// `speech`, so it is never edited, copied, captioned or read aloud.
    let title: String?
    var displayHash: String { AgentBytes.hash(Data(display.utf8)) }

    init?(id: String, display: String, speech: String?, provenance: AgentDraftOrigin? = nil, title: String? = nil) {
        guard (1...128).contains(id.utf8.count),
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }),
              Self.validText(display), speech.map(Self.validText) ?? true else { return nil }
        switch AgentBytes.title(title) {
        case .absent: self.title = nil
        case .valid(let value): self.title = value
        case .invalid: return nil
        }
        self.id = id
        self.display = display
        self.speech = speech
        self.provenance = provenance
    }

    private static func validText(_ value: String) -> Bool {
        value.utf8.count <= maxTextBytes && !value.utf8.contains(0)
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var fingerprint: SHA256.Digest {
        // The separator cannot occur in either field. Missing speech is distinct
        // from every valid (nonblank) supplied speech string.
        let scope = provenance.map { "\($0.principal.uuidString)\0\($0.selector)\0\($0.revision.uuidString)\0" } ?? ""
        // A title is part of what was sent: the same key with another title is a conflict.
        let named = title.map { "\0\0" + $0 } ?? ""
        return SHA256.hash(data: Data((scope + display + "\0" + (speech ?? "") + named).utf8))
    }

    var fingerprintHex: String { fingerprint.map { String(format: "%02x", $0) }.joined() }
}

/// Owns the editable selection and the list of documents. The document in the
/// editor is in memory; every other one is in the store, so the list has no size
/// limit and comes back after a restart. No provider dependency.
@MainActor
final class ExplanationDraftWorkspace: ObservableObject {
    enum Receipt: String { case accepted, duplicate, conflict, busy }
    enum Origin: String, Codable {
        case manual = "직접 입력"
        case pasted = "붙여넣음"
        case received = "받은 대본"
    }

    typealias DocumentTab = DraftSummary

    @Published private(set) var activeDocumentID: String?
    @Published private(set) var activeOriginal: ExplanationDraft?
    /// Arrival order, oldest first. The active document's row is refreshed from the editor.
    @Published private var index: [DraftSummary] = []
    /// While the user is searching the list, a new draft is added to it without
    /// taking over the editor.
    @Published var browsing = false
    private var untitledDocumentID = UUID().uuidString
    private var activeCreatedAt = Date()
    private let store: DraftStoring
    private var saveTask: Task<Void, Never>?

    init(store: DraftStoring = MemoryDraftStore()) {
        self.store = store
        index = store.summaries()
        if let id = store.activeID, let document = store.load(id) { activate(id, document) }
    }

    var editorDocumentID: String { activeDocumentID ?? untitledDocumentID }
    var hasInactiveDocuments: Bool { index.contains { $0.id != editorDocumentID } }
    var canRevertReceived: Bool { activeOriginal != nil && capturedDocument.dirty }
    var activeDocumentIsDirty: Bool { capturedDocument.dirty }
    /// Every document, oldest first, including a not-yet-listed manual one with content.
    var documentTabs: [DocumentTab] {
        let active = editorDocumentID
        var rows = index.map { row in
            row.id == active ? DraftSummary(id: active, document: capturedDocument) : row
        }
        if !rows.contains(where: { $0.id == active }), hasEditorContent {
            rows.append(DraftSummary(id: active, document: capturedDocument))
        }
        return rows
    }

    private var capturedDocument: DraftDocument {
        DraftDocument(original: activeOriginal, display: display, speech: speech,
                      speechNeedsReview: speechNeedsReview, confirmedDisplayHash: confirmedDisplayHash,
                      confirmedSpeechHash: confirmedSpeechHash, provenance: provenance,
                      origin: origin, hasManualEdits: hasManualEdits, createdAt: activeCreatedAt)
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
    /// Receipts the user has not looked at yet. Cleared by the workspace view.
    @Published private(set) var unseenArrivals = 0
    /// Monotonic; lets the view announce each receipt exactly once.
    @Published private(set) var arrivalCount = 0
    @Published private(set) var arrivalNotice: String?
    private var recent: [String: SHA256.Digest] = [:]
    private var receiptOrder: [String] = []

    /// Immediately visible in the workspace, newest first; never replaces an editor.
    var immediatePreviews: [ExplanationDraft] { Array(pending.reversed()) }

    var hasEditorContent: Bool { !display.isEmpty || !speech.isEmpty }
    private var shouldParkActiveDocument: Bool { activeDocumentID != nil || hasEditorContent }

    func setReceiver(_ pid: Int32?) { receiverPID = pid }

    func preflight(_ draft: ExplanationDraft) -> Receipt {
        let listed = documentTabs.compactMap(\.fingerprint)
        if let known = documentTabs.first(where: { $0.id == draft.id })?.fingerprint {
            return known == draft.fingerprintHex ? .duplicate : .conflict
        }
        let previous = recent[draft.id] ?? pending.first(where: { $0.id == draft.id })?.fingerprint
        if let previous { return previous == draft.fingerprint ? .duplicate : .conflict }
        if draft.provenance != nil && (recent.values.contains(draft.fingerprint) || listed.contains(draft.fingerprintHex)
            || pending.contains(where: { $0.fingerprint == draft.fingerprint })) { return .duplicate }
        return pending.count < Self.maxPending ? .accepted : .busy
    }

    func markArrivalsSeen() {
        if unseenArrivals != 0 { unseenArrivals = 0 }
    }

    func dismissArrivalNotice() {
        if arrivalNotice != nil { arrivalNotice = nil }
    }

    /// Live agent receipt never starts playback and never closes, replaces or
    /// trims another document. The new draft is written to the store first; if
    /// that fails nothing else changes and the sender is told it was not taken.
    func receiveDocument(_ draft: ExplanationDraft) -> Receipt {
        if let known = documentTabs.first(where: { $0.id == draft.id }) {
            // Also true after a restart: the stored original answers for its key.
            return known.fingerprint == draft.fingerprintHex ? .duplicate : .conflict
        }
        let arrived = DraftDocument(original: draft, display: draft.display, speech: draft.speech ?? "",
                                    speechNeedsReview: draft.speech.map { !AgentBytes.same(draft.display, $0) } ?? false,
                                    provenance: draft.provenance, origin: .received, hasManualEdits: false)
        guard store.save(draft.id, arrived) else { return .busy }
        let kept = shouldParkActiveDocument
        unseenArrivals += 1
        arrivalCount += 1
        if browsing && kept {
            index.append(DraftSummary(id: draft.id, document: arrived, unseen: true))
            arrivalNotice = "새 대본이 목록에 추가되었습니다. 보던 글은 그대로입니다."
            return .accepted
        }
        parkActiveDocument()
        index.append(DraftSummary(id: draft.id, document: arrived))
        activate(draft.id, arrived)
        arrivalNotice = kept ? "새 대본을 받았습니다. 보던 글은 목록에 그대로 있습니다." : "새 대본을 받았습니다."
        return .accepted
    }

    /// Writes the document in the editor to the store and lists it.
    private func parkActiveDocument() {
        saveTask?.cancel(); saveTask = nil
        guard shouldParkActiveDocument else { return }
        let id = editorDocumentID, document = capturedDocument
        // A failed write keeps the text in the editor's place in the list; the
        // stored copy is then the older one.
        _ = store.save(id, document)
        let row = DraftSummary(id: id, document: document)
        if let position = index.firstIndex(where: { $0.id == id }) { index[position] = row }
        else { index.append(row) }
    }

    /// Makes what is on screen durable. Called shortly after edits and at quit.
    func flush() { parkActiveDocument() }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            self?.flush()
        }
    }

    func selectDocument(_ id: String) {
        guard id != editorDocumentID, index.contains(where: { $0.id == id }), let next = store.load(id) else { return }
        parkActiveDocument()
        activate(id, next)
    }

    private func activate(_ id: String, _ next: DraftDocument) {
        arrivalNotice = nil
        if let position = index.firstIndex(where: { $0.id == id }) { index[position].unseen = false }
        activeDocumentID = id
        activeOriginal = next.original
        activeCreatedAt = next.createdAt
        display = next.display
        speech = next.speech
        speechNeedsReview = next.speechNeedsReview
        confirmedDisplayHash = next.confirmedDisplayHash
        confirmedSpeechHash = next.confirmedSpeechHash
        provenance = next.provenance
        origin = next.origin
        hasManualEdits = next.hasManualEdits
        store.activeID = id
    }

    func closeInactiveDocument(_ id: String) {
        guard id != editorDocumentID else { return }
        store.delete(id)
        index.removeAll { $0.id == id }
    }

    /// Closes the document in the editor, discarding it. The most recently
    /// arrived remaining document comes forward, or a blank one when none is left.
    func closeActiveDocument(expectedDocumentID: String) {
        guard expectedDocumentID == editorDocumentID else { return }
        saveTask?.cancel(); saveTask = nil
        store.delete(expectedDocumentID)
        index.removeAll { $0.id == expectedDocumentID }
        if let id = index.last?.id, let next = store.load(id) { activate(id, next) }
        else { resetToBlank() }
    }

    /// Keeps the current document in the list and starts an empty manual one.
    @discardableResult
    func newDocument() -> Bool {
        guard shouldParkActiveDocument else { return true }
        parkActiveDocument()
        resetToBlank()
        return true
    }

    /// `expectedDocumentID` pins a delayed confirmation to the document it was shown for.
    func revertReceivedDocument(expectedDocumentID: String? = nil) {
        guard expectedDocumentID.map({ $0 == editorDocumentID }) ?? true,
              let original = activeOriginal, canRevertReceived else { return }
        installReceived(original)
    }

    private func installReceived(_ value: ExplanationDraft) {
        activeDocumentID = value.id
        activeOriginal = value
        display = value.display
        speech = value.speech ?? ""
        confirmedDisplayHash = nil
        confirmedSpeechHash = nil
        speechNeedsReview = value.speech.map { !AgentBytes.same(value.display, $0) } ?? false
        provenance = value.provenance
        origin = .received
        hasManualEdits = false
        parkActiveDocument()
        store.activeID = value.id
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
        if let old = activeDocumentID {
            store.delete(old)
            self.index.removeAll { $0.id == old }
        }
        activeCreatedAt = Date()
        installReceived(value)
        return true
    }

    func discard(_ id: String) { pending.removeAll { $0.id == id } }

    func editDisplay(_ value: String, pasted: Bool = false) {
        guard !display.utf8.elementsEqual(value.utf8) else { return }
        arrivalNotice = nil
        if !speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { speechNeedsReview = true }
        confirmedDisplayHash = nil
        confirmedSpeechHash = nil
        display = value
        if pasted { if activeOriginal == nil { origin = .pasted } }
        else if origin == nil { origin = .manual }
        hasManualEdits = !pasted
        scheduleSave()
    }

    func editSpeech(_ value: String) {
        guard !speech.utf8.elementsEqual(value.utf8) else { return }
        arrivalNotice = nil
        speech = value
        confirmedDisplayHash = nil
        confirmedSpeechHash = nil
        let nonblank = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        speechNeedsReview = nonblank && (speechNeedsReview || !AgentBytes.same(value, display))
        if origin == nil { origin = .manual }
        hasManualEdits = true
        scheduleSave()
    }

    func confirmSpeech() {
        confirmedDisplayHash = AgentBytes.hash(Data(display.utf8))
        confirmedSpeechHash = AgentBytes.hash(Data(speech.utf8))
        speechNeedsReview = false
        scheduleSave()
    }

    func clearEditor(expectedDocumentID: String) {
        guard expectedDocumentID == editorDocumentID else { return }
        if activeOriginal != nil {
            editDisplay("")
            editSpeech("")
            return
        }
        saveTask?.cancel(); saveTask = nil
        store.delete(expectedDocumentID)
        index.removeAll { $0.id == expectedDocumentID }
        resetToBlank()
    }

    private func resetToBlank() {
        arrivalNotice = nil
        untitledDocumentID = UUID().uuidString
        activeCreatedAt = Date()
        store.activeID = nil
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
    func playback(displayOnly: Bool = false, expectedDocumentID: String? = nil) -> (display: String, speech: String)? {
        // A control drawn for one document must not read another that arrived since.
        if let expectedDocumentID, expectedDocumentID != editorDocumentID { return nil }
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
