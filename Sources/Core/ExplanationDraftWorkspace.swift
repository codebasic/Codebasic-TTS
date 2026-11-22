import Combine
import CryptoKit
import Foundation

/// The payload of a receive-only operation. The user may edit or discard it later.
struct ExplanationDraft: Identifiable, Sendable {
    struct Provenance: Equatable, Sendable {
        let target: String?
        let revision: String?
        let verifiedLate: Bool
    }

    static let maxTextBytes = 8 * 1024
    let id: String
    let display: String
    let speech: String?
    let provenance: Provenance?

    init?(id: String, display: String, speech: String?, provenance: Provenance? = nil) {
        guard (1...128).contains(id.utf8.count),
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }),
              Self.validText(display), speech.map(Self.validText) ?? true else { return nil }
        self.id = id
        self.display = display
        self.speech = speech
        self.provenance = provenance
    }

    private static func validText(_ value: String) -> Bool {
        value.utf8.count <= maxTextBytes && !value.utf8.contains(0)
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayHash: SHA256.Digest {
        SHA256.hash(data: Data(display.utf8))
    }

    var speechHash: SHA256.Digest? {
        speech.map { SHA256.hash(data: Data($0.utf8)) }
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
    @Published private(set) var displayHashHex = ExplanationDraftWorkspace.hexDigest(Data())
    @Published private(set) var speechHashHex = ExplanationDraftWorkspace.hexDigest(Data())
    @Published private(set) var speechNeedsReview = false
    @Published private(set) var origin: Origin?
    @Published private(set) var activeProvenance: ExplanationDraft.Provenance?
    @Published private(set) var hasManualEdits = false
    @Published private(set) var receiverPID: Int32?
    @Published private(set) var lastPlaybackError: String?

    private var recent: [String: SHA256.Digest] = [:]
    private var receiptOrder: [String] = []
    private var confirmedPair: (display: Data, speech: Data)?

    var hasEditorContent: Bool { !display.isEmpty || !speech.isEmpty }

    var hasDifferentSpeech: Bool {
        !speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayHashHex != speechHashHex
    }

    func setReceiver(_ pid: Int32?) { receiverPID = pid }

    func peekReceiptStatus(for draft: ExplanationDraft) -> Receipt {
        if let known = recent[draft.id] ?? pending.first(where: { $0.id == draft.id })?.fingerprint {
            return known == draft.fingerprint ? .duplicate : .conflict
        }
        return pending.count < Self.maxPending ? .accepted : .busy
    }

    func receive(_ draft: ExplanationDraft) -> Receipt {
        if let known = recent[draft.id] ?? pending.first(where: { $0.id == draft.id })?.fingerprint {
            return known == draft.fingerprint ? .duplicate : .conflict
        }
        // Never drop existing inbox items when full.
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
        displayHashHex = Self.hexDigest(Data(display.utf8))
        speechHashHex = Self.hexDigest(Data(speech.utf8))
        confirmedPair = nil
        speechNeedsReview = hasDifferentSpeech
        origin = .received
        activeProvenance = value.provenance
        hasManualEdits = false
        lastPlaybackError = nil
        return true
    }

    func discard(_ id: String) { pending.removeAll { $0.id == id } }

    func editDisplay(_ value: String, pasted: Bool = false) {
        guard !display.utf8.elementsEqual(value.utf8) else { return }
        display = value
        displayHashHex = Self.hexDigest(Data(value.utf8))
        confirmedPair = nil
        speechNeedsReview = hasDifferentSpeech
        lastPlaybackError = nil
        if pasted { origin = .pasted }
        else if origin == nil { origin = .manual }
        hasManualEdits = !pasted
    }

    func editSpeech(_ value: String) {
        guard !speech.utf8.elementsEqual(value.utf8) else { return }
        speech = value
        speechHashHex = Self.hexDigest(Data(value.utf8))
        confirmedPair = nil
        speechNeedsReview = hasDifferentSpeech
        lastPlaybackError = nil
        if origin == nil { origin = .manual }
        hasManualEdits = true
    }

    func confirmSpeech() {
        confirmedPair = (Data(SHA256.hash(data: Data(display.utf8))), Data(SHA256.hash(data: Data(speech.utf8))))
        speechNeedsReview = false
        lastPlaybackError = nil
    }

    func clearEditor() {
        display = ""
        speech = ""
        displayHashHex = Self.hexDigest(Data())
        speechHashHex = Self.hexDigest(Data())
        confirmedPair = nil
        speechNeedsReview = false
        origin = nil
        activeProvenance = nil
        hasManualEdits = false
        lastPlaybackError = nil
    }

    /// When the screen text has changed or differs from separate spoken text,
    /// the spoken script cannot be read until explicitly confirmed.
    /// Raw or encoded SSML is rejected before synthesis.
    func playback(displayOnly: Bool = false) -> (display: String, speech: String)? {
        lastPlaybackError = nil
        let screen = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !screen.isEmpty, !display.utf8.contains(0) else { return nil }
        if screen == CodeExplanation.noChange { return nil }
        if SSMLGuard.containsSSML(display) {
            lastPlaybackError = "오류: 화면 문구에 포함된 SSML 태그는 합성할 수 없습니다."
            return nil
        }
        guard !displayOnly else { return (display, display) }
        if hasDifferentSpeech {
            let pair: (display: Data, speech: Data) = (
                Data(SHA256.hash(data: Data(display.utf8))),
                Data(SHA256.hash(data: Data(speech.utf8)))
            )
            guard !speechNeedsReview, let confirmedPair,
                  confirmedPair.display == pair.display, confirmedPair.speech == pair.speech else {
                lastPlaybackError = "화면 글과 다른 음성 대본은 확인 후 재생할 수 있습니다."
                return nil
            }
        }
        if speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (display, display)
        }
        guard !speech.utf8.contains(0) else { return nil }
        if SSMLGuard.containsSSML(speech) {
            lastPlaybackError = "오류: 음성 대본에 포함된 SSML 태그는 합성할 수 없습니다."
            return nil
        }
        return (display, speech)
    }

    private static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
