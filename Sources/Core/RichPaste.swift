import AppKit

/// Clean text from a web copy by reading the clipboard's HTML flavor instead of
/// the lossy plain text. Math renderers (KaTeX, MathJax) emit a visually-hidden
/// screen-reader MathML copy of every formula, which the plain-text copy
/// duplicates ("k k는"). We drop those assistive-MathML nodes, then convert the
/// remaining (visual) HTML to text — so duplication is gone at the source.
enum RichPaste {
    /// Best-effort clean text from the pasteboard. Falls back to plain text (with
    /// heuristic cleanup) when there is no HTML flavor. nil if the clipboard is empty.
    @MainActor
    static func cleanText() -> String? {
        let pb = NSPasteboard.general
        if let html = htmlString(pb) {
            let stripped = stripAssistiveMathML(html)
            if let data = stripped.data(using: .utf8) {
                let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ]
                if let attr = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) {
                    return TextSplitter.cleanInput(attr.string)
                }
            }
        }
        if let s = pb.string(forType: .string) { return TextSplitter.cleanInput(s) }
        return nil
    }

    private static func htmlString(_ pb: NSPasteboard) -> String? {
        if let s = pb.string(forType: .html) { return s }
        if let d = pb.data(forType: .html) { return String(data: d, encoding: .utf8) }
        return nil
    }

    /// Remove the hidden screen-reader MathML that renderers add (the duplicate).
    private static func stripAssistiveMathML(_ html: String) -> String {
        var h = html
        let patterns = [
            #"(?s)<span class="katex-mathml"[^>]*>.*?</span>"#,        // KaTeX
            #"(?s)<mjx-assistive-mml[^>]*>.*?</mjx-assistive-mml>"#,   // MathJax 3
        ]
        for p in patterns {
            h = h.replacingOccurrences(of: p, with: "", options: [.regularExpression])
        }
        return h
    }
}
