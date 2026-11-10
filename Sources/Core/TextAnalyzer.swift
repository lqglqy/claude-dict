import Foundation

enum InputLanguage: String, Codable {
    case english, chinese, other
}

enum InputKind: String, Codable {
    case word, phrase, sentence, paragraph
}

struct TextInput: Equatable {
    var text: String
    var language: InputLanguage
    var kind: InputKind
}

/// Cleans up selected text and decides what kind of lookup it is.
enum TextAnalyzer {
    /// Longer selections are cut off; a pop-up is not the place for whole documents.
    static let maxLength = 8000

    static func analyze(_ raw: String) -> TextInput {
        let text = normalize(raw)
        let language = detectLanguage(text)
        return TextInput(text: text, language: language, kind: classify(text, language: language))
    }

    /// Normalizes text copied from apps and PDFs: unifies line endings and spaces, re-joins
    /// soft-wrapped lines and hyphenation, keeps paragraph breaks and list lines, and strips
    /// quotes or punctuation around a single selected word.
    static func normalize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: "[\u{200B}\u{200C}\u{200D}\u{FEFF}]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[\u{00A0}\u{2000}-\u{200A}\u{202F}\u{205F}\u{3000}\t]", with: " ",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "([a-z])- *\n *([a-z])", with: "$1$2", options: .regularExpression)

        var lines: [String] = []
        for rawLine in s.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let last = lines.last, !last.isEmpty { lines.append("") }
                continue
            }
            if let last = lines.last, !last.isEmpty, let glue = joiner(between: last, and: line) {
                lines[lines.count - 1] = last + glue + line
            } else {
                lines.append(line)
            }
        }
        while lines.last == "" { lines.removeLast() }

        var result = lines.joined(separator: "\n")
        // A single token is a word lookup, except that Chinese sentences have no spaces either:
        // only very short CJK selections count as words.
        if !result.contains(where: { $0.isWhitespace }), !result.contains(where: isCJK) || result.count <= 8 {
            result = stripWrapping(result)
        }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
        }
        return result
    }

    static func detectLanguage(_ text: String) -> InputLanguage {
        var cjk = 0, latin = 0, otherScript = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2EBEF:
                cjk += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F:
                latin += 1
            case 0x3040...0x30FF, 0xAC00...0xD7AF, 0x1100...0x11FF, 0x0400...0x04FF, 0x0600...0x06FF, 0x0E00...0x0E7F:
                otherScript += 1 // kana, hangul, cyrillic, arabic, thai
            default:
                break
            }
        }
        if otherScript > 0, Double(otherScript) >= Double(cjk) * 0.5, Double(otherScript) >= Double(latin) / 4 {
            return .other
        }
        if cjk == 0 && latin == 0 { return .other }
        // A CJK character carries roughly a word; an English word is about four letters.
        return Double(cjk) >= Double(latin) / 4 ? .chinese : .english
    }

    static func classify(_ text: String, language: InputLanguage) -> InputKind {
        if text.contains("\n\n") { return .paragraph }
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        switch language {
        case .chinese:
            let punctuation = "，。！？；：、,.!?;:"
            if tokens.count == 1, text.count <= 6, !text.contains(where: { punctuation.contains($0) }) {
                return .word
            }
            return sentenceOrParagraph(text)
        case .english, .other:
            if tokens.count <= 1 { return .word }
            if tokens.count <= 5, let last = text.last, !".!?。！？".contains(last) { return .phrase }
            return sentenceOrParagraph(text)
        }
    }

    private static let sentenceEnd = try! NSRegularExpression(pattern: "[.!?]+(?=\\s|$)|[。！？]+")

    private static func sentenceOrParagraph(_ text: String) -> InputKind {
        let range = NSRange(text.startIndex..., in: text)
        let sentences = max(1, sentenceEnd.numberOfMatches(in: text, range: range))
        return (text.count <= 280 && sentences <= 2) ? .sentence : .paragraph
    }

    /// How to glue two lines that a PDF or a narrow column wrapped: nil keeps the line break.
    private static func joiner(between previous: String, and next: String) -> String? {
        guard let p = previous.last, let n = next.first else { return nil }
        if "。！？；：.!?;:".contains(p) { return nil }
        if n.isLetter, n.isLowercase, n.isASCII { return " " }
        if isCJK(p), isCJK(n) { return "" }
        return nil
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    private static let wrapping = CharacterSet(charactersIn: "\"'“”‘’()[]{}<>«»「」『』《》【】,.;:!?，。；：！？…、")

    /// "“ubiquitous,”" -> "ubiquitous", but "U.S." keeps its final period.
    static func stripWrapping(_ token: String) -> String {
        let view = token.unicodeScalars
        var start = view.startIndex
        var end = view.endIndex
        while start < end, wrapping.contains(view[start]) { start = view.index(after: start) }
        var strippedDot = false
        while end > start {
            let before = view.index(before: end)
            guard wrapping.contains(view[before]) else { break }
            if view[before] == "." { strippedDot = true }
            end = before
        }
        guard start < end else { return token }
        var core = String(String.UnicodeScalarView(view[start..<end]))
        if strippedDot, core.contains(".") { core += "." }
        return core
    }
}
