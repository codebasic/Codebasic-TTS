import Foundation

/// Rejects raw or encoded SSML tags before audio synthesis while preserving
/// ordinary prose, math expressions, and code identifiers (e.g. `x < 5`, `List<String>`).
enum SSMLGuard {
    private static let ssmlTagNames: Set<String> = [
        "speak", "break", "prosody", "phoneme", "say-as", "sub",
        "audio", "emphasis", "voice", "lang", "mark", "desc",
        "lexicon", "lookup", "p", "s",
    ]
    private static let invisibleTagChars: Set<UnicodeScalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}",
    ]
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"(?is)<\s*/?\s*(?:(ssml|amazon|mstts)\s*:\s*)?([a-z][a-z0-9-]*)(?=\s*>|\s*/\s*>|\s+[a-z_:][a-z0-9_.:-]*\s*=)"#,
        options: []
    )
    private static let synthesisNSRegex = try! NSRegularExpression(
        pattern: #"(?is)(?:https?://www\.w3\.org/\d{4}/\d{2}/synthesis|xmlns(?::[a-z0-9_-]+)?\s*=\s*['"][^'"]*synthesis)"#,
        options: []
    )

    static func containsSSML(_ text: String) -> Bool {
        guard text.contains("<") || text.contains("&") || text.contains("%")
            || text.contains("\\u") || text.contains("\\x")
            || text.contains("＜") || text.contains("﹤")
            || text.lowercased().contains("synthesis") else {
            return false
        }
        var current = text
        for _ in 0..<3 {
            let cleaned = stripInvisible(current)
            if matchesSSMLMarkup(cleaned) {
                return true
            }
            let decoded = canonicalDecodePass(cleaned)
            if decoded == current || decoded == cleaned {
                break
            }
            current = decoded
        }
        return matchesSSMLMarkup(stripInvisible(current))
    }

    private static func matchesSSMLMarkup(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        if synthesisNSRegex.firstMatch(in: s, options: [], range: range) != nil {
            return true
        }
        for match in tagRegex.matches(in: s, options: [], range: range) {
            let prefixRange = match.range(at: 1)
            if prefixRange.location != NSNotFound {
                return true
            }
            guard let nameRange = Range(match.range(at: 2), in: s) else { continue }
            let name = s[nameRange].lowercased()
            if name == "p" || name == "s" {
                // `<p>` and `<s>` are common outside SSML unless used with SSML namespaces or alongside `</speak>`/`xml:lang`.
                continue
            }
            if ssmlTagNames.contains(name) {
                return true
            }
        }
        return false
    }

    private static func stripInvisible(_ s: String) -> String {
        String(s.unicodeScalars.filter { !invisibleTagChars.contains($0) })
    }

    private static func canonicalDecodePass(_ s: String) -> String {
        var out = s
            .replacingOccurrences(of: "＜", with: "<")
            .replacingOccurrences(of: "＞", with: ">")
            .replacingOccurrences(of: "﹤", with: "<")
            .replacingOccurrences(of: "﹥", with: ">")
        out = decodePercentEscapes(out)
        out = decodeSlashEscapes(out)
        out = decodeXMLEntities(out)
        return out
    }

    private static func decodePercentEscapes(_ s: String) -> String {
        guard s.contains("%") else { return s }
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count,
               let hi = hexVal(bytes[i + 1]), let lo = hexVal(bytes[i + 2]) {
                out.append((hi << 4) | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(bytes: out, encoding: .utf8) ?? s
    }

    private static func decodeSlashEscapes(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\\" {
                let next = s.index(after: i)
                if next < s.endIndex {
                    if s[next] == "u" {
                        let afterU = s.index(after: next)
                        if afterU < s.endIndex, s[afterU] == "{",
                           let close = s[s.index(after: afterU)...].firstIndex(of: "}") {
                            let hex = String(s[s.index(after: afterU)..<close])
                            if (1...6).contains(hex.count),
                               let code = UInt32(hex, radix: 16),
                               let scalar = UnicodeScalar(code) {
                                out.unicodeScalars.append(scalar)
                                i = s.index(after: close)
                                continue
                            }
                        } else if let end = s.index(afterU, offsetBy: 4, limitedBy: s.endIndex) {
                            let hex = String(s[afterU..<end])
                            if let code = UInt32(hex, radix: 16),
                               let scalar = UnicodeScalar(code) {
                                out.unicodeScalars.append(scalar)
                                i = end
                                continue
                            }
                        }
                    } else if s[next] == "x" {
                        let afterX = s.index(after: next)
                        if let end = s.index(afterX, offsetBy: 2, limitedBy: s.endIndex) {
                            let hex = String(s[afterX..<end])
                            if let code = UInt32(hex, radix: 16),
                               let scalar = UnicodeScalar(code) {
                                out.unicodeScalars.append(scalar)
                                i = end
                                continue
                            }
                        }
                    }
                }
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }

    private static func decodeXMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&",
               let semi = s[s.index(after: i)...].firstIndex(of: ";"),
               s.distance(from: i, to: semi) <= 12 {
                let token = s[s.index(after: i)..<semi]
                if let replacement = decodeEntityToken(token) {
                    out.append(replacement)
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private static func decodeEntityToken(_ token: Substring) -> Character? {
        switch token.lowercased() {
        case "lt": return "<"
        case "gt": return ">"
        case "amp": return "&"
        case "quot": return "\""
        case "apos": return "'"
        default:
            if token.hasPrefix("#x") || token.hasPrefix("#X") {
                let hex = token.dropFirst(2)
                if !hex.isEmpty, let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) {
                    return Character(scalar)
                }
            } else if token.hasPrefix("#") {
                let dec = token.dropFirst()
                if !dec.isEmpty, let code = UInt32(dec, radix: 10), let scalar = UnicodeScalar(code) {
                    return Character(scalar)
                }
            }
            return nil
        }
    }

    private static func hexVal(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 65...70: return b - 55
        case 97...102: return b - 87
        default: return nil
        }
    }
}
