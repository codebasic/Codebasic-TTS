import Foundation

/// Splits a selection into paragraph-sized chunks. Paragraphs are the cache +
/// request unit: long single-shot requests are unstable, and paragraph-level
/// cache hits are stable (sentence-level is too fine). A paragraph longer than
/// `maxChars` is split by a character budget (NOT sentence boundaries) so each
/// backend request stays bounded and chunk sizes are uniform; the cut lands on
/// the nearest preceding whitespace to avoid breaking a word.
enum TextSplitter {
    static let defaultMaxChars = 700

    /// Split a paragraph into sentences for the karaoke-style subtitle. Breaks on
    /// sentence terminators (. ! ? … and newlines); doesn't split a "." that sits
    /// inside a token (np.where, file.txt, self.x, a decimal like 0.5). Used for
    /// display only — audio stays chunked by paragraph.
    static func sentences(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var cur = ""
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            // A "." immediately followed by a letter or digit is inside a token
            // (np.where, file.txt, 0.5), not a sentence end. Real Korean sentence
            // periods are followed by space / newline / end / closing punctuation.
            let dotInsideToken = ch == "." && i + 1 < chars.count
                && (chars[i + 1].isLetter || chars[i + 1].isNumber)
            let isTerminator = (ch == "." || ch == "!" || ch == "?" || ch == "…" || ch == "\n")
                && !dotInsideToken
            if isTerminator {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.isEmpty ? [text] : out
    }

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
    /// into spaces (markdown/math copied with each token on its own line), drop
    /// math tokens a renderer (KaTeX) leaked just before the real text, and keep
    /// blank lines as paragraph breaks. Run on the original-text panel so the
    /// script-generation path downstream is unchanged.
    static func cleanInput(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        var paras: [String] = []
        var cur: [String] = []
        func flush() { if !cur.isEmpty { paras.append(dedupMathLeaks(cur)); cur = [] } }
        for line in t.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { flush() } else { cur.append(l) }
        }
        flush()
        return paras.joined(separator: "\n\n")
    }

    /// Within one paragraph's lines, a run of math-only lines (e.g. "k" or
    /// "k","=","1") that the following text line repeats as a prefix ("k는",
    /// "k=1은") is a renderer leak — drop the run, keep the text. Otherwise lines
    /// are joined with spaces.
    private static func dedupMathLeaks(_ lines: [String]) -> String {
        var out: [String] = []
        var i = 0
        while i < lines.count {
            if isMathOnly(lines[i]) {
                var j = i
                var run: [String] = []
                while j < lines.count, isMathOnly(lines[j]) { run.append(lines[j]); j += 1 }
                let mathNoSpace = run.joined().replacingOccurrences(of: " ", with: "")
                if j < lines.count,
                   !mathNoSpace.isEmpty,
                   lines[j].replacingOccurrences(of: " ", with: "").hasPrefix(mathNoSpace) {
                    out.append(lines[j]); i = j + 1            // leaked render → drop the run
                } else {
                    out.append(run.joined(separator: " ")); i = j
                }
            } else {
                out.append(lines[i]); i += 1
            }
        }
        return out.joined(separator: " ")
    }

    private static let mathChars = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 =+-*/^_().")

    private static func isMathOnly(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 12 && s.unicodeScalars.allSatisfy { mathChars.contains($0) }
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
