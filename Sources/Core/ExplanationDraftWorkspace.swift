import Combine
import CryptoKit
import Foundation

/// The payload of a receive-only operation. The user may edit or discard it later.
struct ExplanationDraft: Identifiable, Sendable {
    static let maxTextBytes = 8 * 1024
    let id: String
    let display: String
    let speech: String?

    init?(id: String, display: String, speech: String?) {
        guard (1...128).contains(id.utf8.count),
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }),
              Self.validText(display), speech.map(Self.validText) ?? true else { return nil }
        self.id = id
        self.display = display
        self.speech = speech
    }

    private static func validText(_ value: String) -> Bool {
        value.utf8.count <= maxTextBytes && !value.utf8.contains(0)
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var fingerprint: SHA256.Digest {
        // The separator cannot occur in either field. Missing speech is distinct
        // from every valid (nonblank) supplied speech string.
        SHA256.hash(data: Data((display + "\0" + (speech ?? "")).utf8))
    }
}

/// Owns only in-memory drafts and the editable selection. No provider dependency.
@MainActor
final class ExplanationDraftWorkspace: ObservableObject {
    enum Receipt: String { case accepted, duplicate, conflict, busy }
    enum Origin: String {
        case manual = "직접 입력"
        case pasted = "붙여넣음"
        case received = "받은 대본을 편집기에 열었음"
    }

    static let maxPending = 8
    private static let maxRecent = 128
    @Published private(set) var pending: [ExplanationDraft] = []
    @Published private(set) var display = ""
    @Published private(set) var speech = ""
    @Published private(set) var speechNeedsReview = false
    @Published private(set) var origin: Origin?
    @Published private(set) var hasManualEdits = false
    @Published private(set) var receiverPID: Int32?
    private var recent: [String: SHA256.Digest] = [:]
    private var receiptOrder: [String] = []

    var hasEditorContent: Bool { !display.isEmpty || !speech.isEmpty }

    func setReceiver(_ pid: Int32?) { receiverPID = pid }

    func receive(_ draft: ExplanationDraft) -> Receipt {
        if let known = recent[draft.id] ?? pending.first(where: { $0.id == draft.id })?.fingerprint {
            return known == draft.fingerprint ? .duplicate : .conflict
        }
        guard pending.count < Self.maxPending else { return .busy }
        recent[draft.id] = draft.fingerprint
        receiptOrder.append(draft.id)
        if receiptOrder.count > Self.maxRecent { recent.removeValue(forKey: receiptOrder.removeFirst()) }
        pending.append(draft)
        return .accepted
    }

    /// Deliberately invoked by the editor, never by the transport.
    @discardableResult
    func open(_ id: String, replace: Bool = false) -> Bool {
        guard (!hasEditorContent || replace), let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        let value = pending.remove(at: index)
        display = value.display
        speech = value.speech ?? ""
        speechNeedsReview = false
        origin = .received
        hasManualEdits = false
        return true
    }

    func discard(_ id: String) { pending.removeAll { $0.id == id } }

    func editDisplay(_ value: String, pasted: Bool = false) {
        guard !display.utf8.elementsEqual(value.utf8) else { return }
        if !speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { speechNeedsReview = true }
        display = value
        if pasted { origin = .pasted }
        else if origin == nil { origin = .manual }
        hasManualEdits = !pasted
    }

    func editSpeech(_ value: String) {
        guard !speech.utf8.elementsEqual(value.utf8) else { return }
        speech = value
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { speechNeedsReview = false }
        if origin == nil { origin = .manual }
        hasManualEdits = true
    }

    func confirmSpeech() { speechNeedsReview = false }

    func clearEditor() {
        display = ""
        speech = ""
        speechNeedsReview = false
        origin = nil
        hasManualEdits = false
    }

    /// When the screen text has changed, the old script cannot be read
    /// until reviewed. Reading the displayed text is a separate explicit choice.
    func playback(displayOnly: Bool = false) -> (display: String, speech: String)? {
        let screen = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !screen.isEmpty, !display.utf8.contains(0) else { return nil }
        if screen == CodeExplanation.noChange { return nil }
        guard !displayOnly else { return (display, display) }
        guard !speechNeedsReview else { return nil }
        if speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (display, display) }
        guard !speech.utf8.contains(0) else { return nil }
        return (display, speech)
    }
}
