import Foundation

/// Splits a selection into paragraph-sized chunks. Paragraphs are the cache +
/// request unit: long single-shot requests are unstable, and paragraph-level
/// cache hits are stable (sentence-level is too fine). A paragraph longer than
/// `maxChars` is split by a character budget (NOT sentence boundaries) so each
/// backend request stays bounded and chunk sizes are uniform; the cut lands on
/// the nearest preceding whitespace to avoid breaking a word.
enum TextSplitter {
    static let defaultMaxChars = 700

    static func paragraphs(_ text: String, maxChars: Int = defaultMaxChars) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Newline(s) delimit paragraphs.
        let paras = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var out: [String] = []
        for p in paras {
            if p.count <= maxChars {
                out.append(p)
            } else {
                out.append(contentsOf: splitByChars(p, maxChars: maxChars))
            }
        }
        return out
    }

    /// Clean pasted source text: collapse single line breaks WITHIN a paragraph
    /// into spaces (markdown/math copied with each token on its own line), while
    /// keeping blank lines as paragraph breaks. Run on the original-text panel so
    /// the script-generation path downstream is unchanged.
    static func cleanInput(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        var paras: [String] = []
        var cur: [String] = []
        for line in t.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty {
                if !cur.isEmpty { paras.append(cur.joined(separator: " ")); cur = [] }
            } else {
                cur.append(l)
            }
        }
        if !cur.isEmpty { paras.append(cur.joined(separator: " ")) }
        return paras.joined(separator: "\n\n")
    }

    /// Split a long paragraph into <= maxChars windows, cutting at the last
    /// whitespace at/before the limit (hard cut if a token is longer than the
    /// window).
    private static func splitByChars(_ p: String, maxChars: Int) -> [String] {
        var chunks: [String] = []
        var s = Substring(p)
        while s.count > maxChars {
            let limit = s.index(s.startIndex, offsetBy: maxChars)
            var cut = limit
            var idx = limit
            var found = false
            while idx > s.startIndex {
                let prev = s.index(before: idx)
                if s[prev].isWhitespace { cut = prev; found = true; break }
                idx = prev
            }
            if !found { cut = limit }                       // no space: hard cut
            let piece = s[s.startIndex..<cut].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { chunks.append(piece) }
            var next = cut
            while next < s.endIndex, s[next].isWhitespace { next = s.index(after: next) }
            s = s[next...]
        }
        let tail = s.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }
}
