import Foundation

/// The small Markdown subset the prompts ask for. Parsing is line-based so a half-streamed
/// answer always renders.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(text: String, indent: Int)
    case numbered(marker: String, text: String, indent: Int)
    case quote(String)
    case code(String)
    case paragraph(String)
}

enum Markdown {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(rawLine)
                }
                continue
            }
            if trimmed.hasPrefix("```") { flushParagraph(); flushQuote(); code = []; continue }
            if trimmed.isEmpty { flushParagraph(); flushQuote(); continue }

            let indent = leadingIndent(rawLine)
            if let (level, rest) = heading(trimmed) {
                flushParagraph(); flushQuote()
                blocks.append(.heading(level: level, text: rest))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            if let rest = bullet(trimmed) {
                flushParagraph()
                blocks.append(.bullet(text: rest, indent: min(indent / 2, 4)))
                continue
            }
            if let (marker, rest) = numbered(trimmed) {
                flushParagraph()
                blocks.append(.numbered(marker: marker, text: rest, indent: min(indent / 2, 4)))
                continue
            }
            // An indented line right after a list item continues that item.
            if indent > 0, paragraph.isEmpty, let last = blocks.last {
                switch last {
                case .bullet(let t, let i):
                    blocks[blocks.count - 1] = .bullet(text: t + "\n" + trimmed, indent: i)
                    continue
                case .numbered(let m, let t, let i):
                    blocks[blocks.count - 1] = .numbered(marker: m, text: t + "\n" + trimmed, indent: i)
                    continue
                default:
                    break
                }
            }
            paragraph.append(trimmed)
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        flushQuote()
        return blocks
    }

    private static func leadingIndent(_ line: String) -> Int {
        var count = 0
        for c in line {
            if c == " " { count += 1 } else if c == "\t" { count += 4 } else { break }
        }
        return count
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bullet(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...3).contains(digits.count) else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard let mark = afterDigits.first, mark == "." || mark == ")" else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.first == " " else { return nil }
        return (String(digits) + String(mark), rest.trimmingCharacters(in: .whitespaces))
    }

    // MARK: HTML (for the GoldenDict "Program" dictionary source)

    static func html(_ text: String) -> String {
        var out = ""
        var openList: String?
        func closeList() {
            if let list = openList { out += "</\(list)>"; openList = nil }
        }
        func open(_ list: String) {
            if openList != list { closeList(); out += "<\(list)>"; openList = list }
        }
        for block in parse(text) {
            switch block {
            case .bullet(let t, _):
                open("ul"); out += "<li>\(inlineHTML(t))</li>"
            case .numbered(_, let t, _):
                open("ol"); out += "<li>\(inlineHTML(t))</li>"
            case .heading(let level, let t):
                closeList(); out += "<h\(level)>\(inlineHTML(t))</h\(level)>"
            case .paragraph(let t):
                closeList(); out += "<p>\(inlineHTML(t))</p>"
            case .quote(let t):
                closeList(); out += "<blockquote>\(inlineHTML(t))</blockquote>"
            case .code(let t):
                closeList(); out += "<pre><code>\(escapeHTML(t))</code></pre>"
            }
        }
        closeList()
        return out
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func inlineHTML(_ s: String) -> String {
        var e = escapeHTML(s)
        e = e.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
        e = e.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
        e = e.replacingOccurrences(of: "(?<![*\\w])\\*(?![\\s*])(.+?)(?<![\\s*])\\*(?![*\\w])", with: "<i>$1</i>",
                                   options: .regularExpression)
        return e.replacingOccurrences(of: "\n", with: "<br>")
    }
}
