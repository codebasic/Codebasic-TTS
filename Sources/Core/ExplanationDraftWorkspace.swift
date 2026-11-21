import Combine
import CryptoKit
import Foundation

/// Frozen at acceptance time: which helper (as labelled by the owner) sent the draft and
/// which exact instruction version it was written for.
struct AgentDraftProvenance: Equatable, Sendable {
    let helperInstanceID: UUID
    let helperLabel: String
    let profileID: UUID
    let revision: AgentInstructionRevision
    let instructionSHA256: Data
    let receiptGrantID: UUID

    init(helperInstanceID: UUID, helperLabel: String, profileID: UUID, revision: AgentInstructionRevision,
         instructionSHA256: Data, receiptGrantID: UUID) {
        self.helperInstanceID = helperInstanceID
        self.helperLabel = helperLabel
        self.profileID = profileID
        self.revision = revision
        self.instructionSHA256 = instructionSHA256
        self.receiptGrantID = receiptGrantID
    }
}

/// Detects raw or encoded markup. It only detects; it never rewrites or interprets text.
/// Deliberately fail closed: anything that could become a tag after decoding is refused.
enum SpeechMarkupGuard {
    private static let entityNames: [[UInt32]] = [
        [0x6C, 0x74], [0x67, 0x74], [0x61, 0x6D, 0x70], [0x71, 0x75, 0x6F, 0x74], [0x61, 0x70, 0x6F, 0x73]
    ]

    static func containsMarkup(_ text: String) -> Bool {
        let s = text.unicodeScalars.map { $0.value }
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == 0x3C || c == 0xFF1C || c == 0xFE64 {
                // A less-than sign directly followed by a letter, slash, bang or question mark.
                if i + 1 < s.count, opensTag(s[i + 1]) { return true }
            } else if c == 0x26 || c == 0xFF06 || c == 0xFE60 {
                if entityFollows(s, i + 1) { return true }
            } else if c == 0x25 {
                // Percent-encoded less-than.
                // Nested encodings of the percent sign itself (%253c, %25253c) are skipped first.
                var j = i + 1
                while matches(s, j, [0x32, 0x35]) { j += 2 }
                if matches(s, j, [0x33, 0x63]) { return true }
                if matches(s, j, [0x32, 0x36]), entityFollows(s, j + 2) { return true }
                if matches(s, j, [0x35, 0x63]), escapeFollows(s, j + 2) { return true }
            } else if c == 0x5C {
                // Backslash escapes of less-than (u003c, x3c).
                // Also escapes of the ampersand, percent sign or backslash that could nest one.
                if escapeFollows(s, i + 1) { return true }
            }
            i += 1
        }
        return false
    }

    /// What may follow a backslash: u003c, x3c, u{3c}, and the same forms for 26, 25 and 5c.
    private static let escapedDelimiters: [[UInt32]] = [
        [0x75, 0x30, 0x30, 0x33, 0x63], [0x78, 0x33, 0x63], [0x75, 0x7B, 0x33, 0x63, 0x7D],
        [0x75, 0x30, 0x30, 0x32, 0x36], [0x78, 0x32, 0x36], [0x75, 0x7B, 0x32, 0x36, 0x7D],
        [0x75, 0x30, 0x30, 0x32, 0x35], [0x78, 0x32, 0x35], [0x75, 0x7B, 0x32, 0x35, 0x7D],
        [0x75, 0x30, 0x30, 0x35, 0x63], [0x78, 0x35, 0x63], [0x75, 0x7B, 0x35, 0x63, 0x7D]
    ]

    private static func escapeFollows(_ s: [UInt32], _ at: Int) -> Bool {
        for literal in escapedDelimiters where matches(s, at, literal) { return true }
        return false
    }

    private static func lower(_ v: UInt32) -> UInt32 { (0x41...0x5A).contains(v) ? v + 0x20 : v }
    private static func isLetter(_ v: UInt32) -> Bool { (0x61...0x7A).contains(lower(v)) }
    private static func isDigit(_ v: UInt32) -> Bool { (0x30...0x39).contains(v) }
    private static func isHex(_ v: UInt32) -> Bool { isDigit(v) || (0x61...0x66).contains(lower(v)) }
    private static func opensTag(_ v: UInt32) -> Bool { isLetter(v) || v == 0x2F || v == 0x21 || v == 0x3F }

    private static func matches(_ s: [UInt32], _ at: Int, _ literal: [UInt32]) -> Bool {
        guard at + literal.count <= s.count else { return false }
        for k in 0..<literal.count where lower(s[at + k]) != literal[k] { return false }
        return true
    }

    private static func entityFollows(_ s: [UInt32], _ at: Int) -> Bool {
        guard at < s.count else { return false }
        if s[at] == 0x23 {
            // Any numeric character reference, decimal or hexadecimal.
            guard at + 1 < s.count else { return false }
            if isDigit(s[at + 1]) { return true }
            return lower(s[at + 1]) == 0x78 && at + 2 < s.count && isHex(s[at + 2])
        }
        // Markup-significant names count even without the semicolon (covers nested forms).
        for name in entityNames where matches(s, at, name) { return true }
        guard isLetter(s[at]) else { return false }
        var j = at + 1
        while j < s.count, j - at <= 32, isLetter(s[j]) || isDigit(s[j]) { j += 1 }
        return j < s.count && s[j] == 0x3B
    }
}

/// The payload of a receive-only operation. The user may edit or discard it later.
struct ExplanationDraft: Identifiable, Sendable {
    static let maxTextBytes = 8 * 1024
    let id: String
    let display: String
    let speech: String?
    /// Present only for drafts accepted through the authorized Agent path.
    let provenance: AgentDraftProvenance?

    init?(id: String, display: String, speech: String?, provenance: AgentDraftProvenance? = nil) {
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

    var fingerprint: SHA256.Digest {
        // The separator cannot occur in either field. Missing speech is distinct
        // from every valid (nonblank) supplied speech string.
        SHA256.hash(data: Data((display + "\0" + (speech ?? "")).utf8))
    }
}

/// Owns only in-memory drafts and the editable selection. No provider dependency.
/// Receiving a draft only appends to `pending`; it never plays, focuses or changes the editor.
@MainActor
final class ExplanationDraftWorkspace: ObservableObject {
    enum Receipt: String { case accepted, duplicate, conflict, busy }
    enum Origin: String {
        case manual = "직접 입력"
        case pasted = "붙여넣음"
        case received = "받은 대본을 편집기에 열었음"
    }
    enum PlaybackBlock: String {
        case empty, noChange, containsNUL, tooLarge, speechNeedsReview, markup
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
    /// Provenance of the draft that was opened into the editor, if any.
    @Published private(set) var editorProvenance: AgentDraftProvenance?
    /// SHA-256 of the exact display bytes that were on screen when the speech was confirmed.
    @Published private(set) var confirmedDisplaySHA256: Data?
    private var confirmedSpeechSHA256: Data?
    private var recent: [String: SHA256.Digest] = [:]
    private var receiptOrder: [String] = []

    var hasEditorContent: Bool { !display.isEmpty || !speech.isEmpty }

    /// True when a nonblank speech script differs from the display text byte for byte.
    var hasSeparateSpeech: Bool {
        !speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !speech.utf8.elementsEqual(display.utf8)
    }

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

    /// Agent path: queues only drafts with typed provenance, and only when a slot is free.
    /// Returns true only if the draft was actually queued. Never touches the editor.
    func enqueueAgentDraft(_ draft: ExplanationDraft) -> Bool {
        guard draft.provenance != nil else { return false }
        return receive(draft) == .accepted
    }

    /// Deliberately invoked by the editor, never by the transport.
    @discardableResult
    func open(_ id: String, replace: Bool = false) -> Bool {
        guard (!hasEditorContent || replace), let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        let value = pending.remove(at: index)
        display = value.display
        speech = value.speech ?? ""
        clearConfirmation()
        // Incoming speech that differs from the display starts blocked.
        speechNeedsReview = hasSeparateSpeech
        origin = .received
        hasManualEdits = false
        editorProvenance = value.provenance
        return true
    }

    func discard(_ id: String) { pending.removeAll { $0.id == id } }

    func editDisplay(_ value: String, pasted: Bool = false) {
        guard !display.utf8.elementsEqual(value.utf8) else { return }
        display = value
        // Any edit voids the previous confirmation, even if the text is later edited back.
        clearConfirmation()
        speechNeedsReview = hasSeparateSpeech
        if pasted { origin = .pasted }
        else if origin == nil { origin = .manual }
        hasManualEdits = !pasted
    }

    func editSpeech(_ value: String) {
        guard !speech.utf8.elementsEqual(value.utf8) else { return }
        speech = value
        clearConfirmation()
        speechNeedsReview = hasSeparateSpeech
        if origin == nil { origin = .manual }
        hasManualEdits = true
    }

    /// Explicit user confirmation of the current speech for the current display bytes.
    func confirmSpeech() {
        guard hasSeparateSpeech else {
            clearConfirmation()
            speechNeedsReview = false
            return
        }
        confirmedDisplaySHA256 = Self.sha(display)
        confirmedSpeechSHA256 = Self.sha(speech)
        speechNeedsReview = false
    }

    func clearEditor() {
        display = ""
        speech = ""
        clearConfirmation()
        speechNeedsReview = false
        origin = nil
        hasManualEdits = false
        editorProvenance = nil
    }

    /// Why the Agent tab may not hand text to the voice engine right now, if anything.
    func playbackBlock(displayOnly: Bool = false) -> PlaybackBlock? {
        let screen = display.trimmingCharacters(in: .whitespacesAndNewlines)
        if screen.isEmpty { return .empty }
        if display.utf8.contains(0) { return .containsNUL }
        if screen == CodeExplanation.noChange { return .noChange }
        if display.utf8.count > ExplanationDraft.maxTextBytes { return .tooLarge }
        if displayOnly || speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SpeechMarkupGuard.containsMarkup(display) ? .markup : nil
        }
        if hasSeparateSpeech {
            guard !speechNeedsReview,
                  let confirmedDisplay = confirmedDisplaySHA256, let confirmedSpeech = confirmedSpeechSHA256,
                  confirmedDisplay == Self.sha(display), confirmedSpeech == Self.sha(speech) else { return .speechNeedsReview }
        }
        if speech.utf8.contains(0) { return .containsNUL }
        if speech.utf8.count > ExplanationDraft.maxTextBytes { return .tooLarge }
        return SpeechMarkupGuard.containsMarkup(speech) ? .markup : nil
    }

    /// When the screen text has changed, the old script cannot be read
    /// until reviewed. Reading the displayed text is a separate explicit choice.
    /// The returned text is exact; nothing is stripped or decoded.
    func playback(displayOnly: Bool = false) -> (display: String, speech: String)? {
        guard playbackBlock(displayOnly: displayOnly) == nil else { return nil }
        if displayOnly || speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (display, display) }
        return (display, speech)
    }

    private func clearConfirmation() {
        confirmedDisplaySHA256 = nil
        confirmedSpeechSHA256 = nil
    }

    private static func sha(_ value: String) -> Data {
        Data(SHA256.hash(data: Data(value.utf8)))
    }
}
