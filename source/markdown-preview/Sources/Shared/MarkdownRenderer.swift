import Foundation

/// Dependency-free Markdown → HTML renderer covering CommonMark basics plus the
/// common GitHub extensions (tables, task lists, strikethrough, bare autolinks).
enum MarkdownRenderer {
    /// `imageResolver` may turn a relative image path into something the web view
    /// can load (e.g. a data: URI); returning nil keeps the original source.
    static func render(_ source: String, imageResolver: ((String) -> String?)? = nil) -> String {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n").map(expandLeadingTabs)
        var html = ""

        if let frontMatter = extractFrontMatter(&lines) {
            html += "<pre class=\"front-matter\"><code>\(escapeHTML(frontMatter))</code></pre>\n"
        }

        let refs = extractLinkReferences(&lines)
        let blocks = BlockParser().parse(lines)
        let writer = HTMLWriter(inline: InlineParser(refs: refs, imageResolver: imageResolver))
        html += writer.write(blocks)
        return html
    }

    private static func extractFrontMatter(_ lines: inout [String]) -> String? {
        guard lines.first == "---" else { return nil }
        guard let end = lines.indices.dropFirst().first(where: { lines[$0] == "---" || lines[$0] == "..." }) else { return nil }
        let body = lines[1..<end].joined(separator: "\n")
        lines.removeSubrange(0...end)
        return body
    }

    private static let refDefRx = Rx(#"^ {0,3}\[([^\]]+)\]:[ \t]*<?([^\s>]+)>?(?:[ \t]+(?:"([^"]*)"|'([^']*)'|\(([^)]*)\)))?[ \t]*$"#)

    private static func extractLinkReferences(_ lines: inout [String]) -> [String: LinkRef] {
        var refs: [String: LinkRef] = [:]
        var kept: [String] = []
        var fence: String?
        for line in lines {
            if let open = fence {
                kept.append(line)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(open) { fence = nil }
                continue
            }
            if let m = BlockParser.fenceRx.match(line) {
                fence = String(m[2]!.prefix(3))
                kept.append(line)
                continue
            }
            if let m = refDefRx.match(line) {
                let key = normalizeLabel(m[1]!)
                if refs[key] == nil {
                    refs[key] = LinkRef(url: m[2]!, title: m[3] ?? m[4] ?? m[5])
                }
                continue
            }
            kept.append(line)
        }
        lines = kept
        return refs
    }
}

struct LinkRef {
    let url: String
    let title: String?
}

func normalizeLabel(_ label: String) -> String {
    label.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

// MARK: - Block structure

indirect enum Block {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, text: String)
    case quote([Block])
    case list(ordered: Bool, start: Int, tight: Bool, items: [ListItem])
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    case rule
    case html(String)
}

struct ListItem {
    var checked: Bool?   // nil = not a task item
    var blocks: [Block]
}

enum TableAlignment {
    case none, left, center, right
}

struct BlockParser {
    static let fenceRx = Rx(#"^( {0,3})(`{3,}|~{3,})[ \t]*([^`]*?)[ \t]*$"#)
    static let atxRx = Rx(#"^ {0,3}(#{1,6})(?=[ \t]|$)[ \t]*(.*?)(?:[ \t]+#+)?[ \t]*$"#)
    static let ruleRx = Rx(#"^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    static let setextRx = Rx(#"^ {0,3}(=+|-+)[ \t]*$"#)
    static let quoteRx = Rx(#"^ {0,3}> ?(.*)$"#)
    static let bulletRx = Rx(#"^( {0,3})([-+*])(?:([ \t]+)(.*))?$"#)
    static let orderedRx = Rx(#"^( {0,3})(\d{1,9})([.)])(?:([ \t]+)(.*))?$"#)
    static let tableDelimiterRx = Rx(#"^ {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
    static let htmlBlockRx = Rx(#"^ {0,3}<(?:!--|/?(?:address|article|aside|blockquote|body|center|details|dialog|dd|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|head|header|hr|html|iframe|li|main|nav|ol|p|picture|pre|section|source|style|summary|table|tbody|td|tfoot|th|thead|tr|ul|video|audio|img|br)(?:[ \t>/]|$))"#, caseInsensitive: true)

    func parse(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }

            if let m = Self.fenceRx.match(line) {
                blocks.append(parseFence(lines, &i, indent: m[1]!.count, fence: m[2]!, info: m[3]!))
                continue
            }
            if leadingSpaces(line) >= 4 {
                blocks.append(parseIndentedCode(lines, &i))
                continue
            }
            if let m = Self.atxRx.match(line) {
                blocks.append(.heading(level: m[1]!.count, text: m[2]!))
                i += 1
                continue
            }
            if Self.ruleRx.test(line) {
                blocks.append(.rule)
                i += 1
                continue
            }
            if Self.quoteRx.test(line) {
                blocks.append(parseQuote(lines, &i))
                continue
            }
            if listMarker(line) != nil {
                blocks.append(parseList(lines, &i))
                continue
            }
            if Self.htmlBlockRx.test(line) {
                var chunk: [String] = []
                while i < lines.count, !isBlank(lines[i]) { chunk.append(lines[i]); i += 1 }
                blocks.append(.html(chunk.joined(separator: "\n")))
                continue
            }
            if let table = parseTable(lines, &i) {
                blocks.append(table)
                continue
            }
            blocks.append(parseParagraph(lines, &i))
        }
        return blocks
    }

    // MARK: Leaf blocks

    private func parseFence(_ lines: [String], _ i: inout Int, indent: Int, fence: String, info: String) -> Block {
        let marker = fence.first!
        var body: [String] = []
        i += 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if leadingSpaces(line) < 4, trimmed.count >= fence.count, trimmed.allSatisfy({ $0 == marker }) {
                i += 1
                break
            }
            body.append(String(line.dropFirst(min(indent, leadingSpaces(line)))))
            i += 1
        }
        let language = info.split(separator: " ").first.map(String.init)
        return .code(language: language, text: body.joined(separator: "\n"))
    }

    private func parseIndentedCode(_ lines: [String], _ i: inout Int) -> Block {
        var body: [String] = []
        while i < lines.count, isBlank(lines[i]) || leadingSpaces(lines[i]) >= 4 {
            body.append(String(lines[i].dropFirst(min(4, leadingSpaces(lines[i])))))
            i += 1
        }
        while let last = body.last, isBlank(last) { body.removeLast() }
        return .code(language: nil, text: body.joined(separator: "\n"))
    }

    private func parseParagraph(_ lines: [String], _ i: inout Int) -> Block {
        var text: [String] = [lines[i].trimmingLeadingWhitespace()]
        i += 1
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { break }
            if let m = Self.setextRx.match(line) {
                i += 1
                return .heading(level: m[1]!.first == "=" ? 1 : 2, text: text.joined(separator: "\n").trimmingCharacters(in: .whitespaces))
            }
            if interruptsParagraph(line) { break }
            text.append(line.trimmingLeadingWhitespace())
            i += 1
        }
        return .paragraph(text.joined(separator: "\n").trimmingTrailingWhitespace())
    }

    private func interruptsParagraph(_ line: String) -> Bool {
        if Self.atxRx.test(line) || Self.fenceRx.test(line) || Self.ruleRx.test(line) || Self.quoteRx.test(line) || Self.htmlBlockRx.test(line) {
            return true
        }
        if let marker = listMarker(line), !marker.content.isEmpty {
            return !marker.ordered || marker.number == 1
        }
        return false
    }

    // MARK: Tables

    private func parseTable(_ lines: [String], _ i: inout Int) -> Block? {
        guard i + 1 < lines.count, lines[i].contains("|"), Self.tableDelimiterRx.test(lines[i + 1]) else { return nil }
        let header = splitTableRow(lines[i])
        let delimiters = splitTableRow(lines[i + 1])
        guard header.count == delimiters.count else { return nil }

        let alignments: [TableAlignment] = delimiters.map { cell in
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            switch (left, right) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            default: return .none
            }
        }
        i += 2
        var rows: [[String]] = []
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
            var cells = splitTableRow(lines[i])
            if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
            rows.append(Array(cells.prefix(header.count)))
            i += 1
        }
        return .table(header: header, alignments: alignments, rows: rows)
    }

    private func splitTableRow(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row.removeLast() }

        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in row {
            if escaped {
                current.append(ch == "|" ? "|" : "\\\(ch)")
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "`" {
                inCode.toggle()
                current.append(ch)
            } else if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Container blocks

    private func parseQuote(_ lines: [String], _ i: inout Int) -> Block {
        var inner: [String] = []
        while i < lines.count {
            let line = lines[i]
            if let m = Self.quoteRx.match(line) {
                inner.append(m[1]!)
            } else if !isBlank(line), let last = inner.last, !isBlank(last), !interruptsParagraph(line) {
                inner.append(line)  // lazy continuation
            } else {
                break
            }
            i += 1
        }
        return .quote(parse(inner))
    }

    struct Marker {
        let ordered: Bool
        let symbol: Character   // bullet char, or "." / ")" for ordered lists
        let number: Int
        let indent: Int
        let contentOffset: Int
        let content: String
    }

    func listMarker(_ line: String) -> Marker? {
        let indent: Int, symbol: Character, number: Int, markerWidth: Int, spacing: String?, content: String?
        if let m = Self.bulletRx.match(line) {
            if Self.ruleRx.test(line) { return nil }
            indent = m[1]!.count; symbol = m[2]!.first!; number = 0; markerWidth = 1
            spacing = m[3]; content = m[4]
        } else if let m = Self.orderedRx.match(line) {
            indent = m[1]!.count; symbol = m[3]!.first!; number = Int(m[2]!) ?? 1; markerWidth = m[2]!.count + 1
            spacing = m[4]; content = m[5]
        } else {
            return nil
        }
        let body = content ?? ""
        let gap = spacing?.count ?? 0
        if body.isEmpty || gap > 4 {
            // Empty item, or content that starts with an indented code block.
            let extra = gap > 4 ? String(repeating: " ", count: gap - 1) : ""
            return Marker(ordered: symbol == "." || symbol == ")", symbol: symbol, number: number, indent: indent,
                          contentOffset: indent + markerWidth + 1, content: extra + body)
        }
        return Marker(ordered: symbol == "." || symbol == ")", symbol: symbol, number: number, indent: indent,
                      contentOffset: indent + markerWidth + gap, content: body)
    }

    private func parseList(_ lines: [String], _ i: inout Int) -> Block {
        let first = listMarker(lines[i])!
        var items: [ListItem] = []
        var tight = true

        while i < lines.count, let marker = listMarker(lines[i]),
              marker.ordered == first.ordered, marker.symbol == first.symbol {
            var itemLines = [marker.content]
            i += 1
            var sawBlank = false
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    itemLines.append("")
                    sawBlank = true
                    i += 1
                    continue
                }
                let indent = leadingSpaces(line)
                if indent >= marker.contentOffset {
                    itemLines.append(String(line.dropFirst(marker.contentOffset)))
                    i += 1
                    continue
                }
                if sawBlank || listMarker(line) != nil || interruptsParagraph(line) { break }
                itemLines.append(line.trimmingLeadingWhitespace())  // lazy continuation
                i += 1
            }

            var trailingBlank = false
            while let last = itemLines.last, isBlank(last) {
                itemLines.removeLast()
                trailingBlank = true
            }
            let blocks = parse(itemLines)
            if blocks.count > 1 && hasInternalBlankLine(itemLines) { tight = false }
            if trailingBlank, i < lines.count, let next = listMarker(lines[i]),
               next.ordered == first.ordered, next.symbol == first.symbol {
                tight = false
            }
            items.append(makeItem(blocks))
        }
        return .list(ordered: first.ordered, start: first.number, tight: tight, items: items)
    }

    private func hasInternalBlankLine(_ lines: [String]) -> Bool {
        var inFence = false
        for line in lines.dropFirst() {
            if Self.fenceRx.test(line) { inFence.toggle() }
            if !inFence && isBlank(line) { return true }
        }
        return false
    }

    private func makeItem(_ blocks: [Block]) -> ListItem {
        guard case .paragraph(let text)? = blocks.first else { return ListItem(checked: nil, blocks: blocks) }
        let lower = text.prefix(4).lowercased()
        guard lower == "[ ] " || lower == "[x] " || text == "[ ]" || text.lowercased() == "[x]" else {
            return ListItem(checked: nil, blocks: blocks)
        }
        var rest = blocks
        rest[0] = .paragraph(String(text.dropFirst(min(4, text.count))))
        return ListItem(checked: lower.hasPrefix("[x]"), blocks: rest)
    }
}

// MARK: - HTML output

struct HTMLWriter {
    let inline: InlineParser
    private let slugs = SlugGenerator()

    init(inline: InlineParser) {
        self.inline = inline
    }

    func write(_ blocks: [Block], tight: Bool = false) -> String {
        blocks.map { write($0, tight: tight) }.joined(separator: "\n") + (blocks.isEmpty ? "" : "\n")
    }

    private func write(_ block: Block, tight: Bool) -> String {
        switch block {
        case .heading(let level, let text):
            let id = slugs.slug(for: text)
            return "<h\(level) id=\"\(escapeHTML(id))\">\(inline.render(text))</h\(level)>"
        case .paragraph(let text):
            return tight ? inline.render(text) : "<p>\(inline.render(text))</p>"
        case .code(let language, let text):
            let cls = language.map { " class=\"language-\(escapeHTML($0))\"" } ?? ""
            return "<pre><code\(cls)>\(escapeHTML(text))\n</code></pre>"
        case .quote(let blocks):
            return "<blockquote>\n\(write(blocks))</blockquote>"
        case .list(let ordered, let start, let tight, let items):
            let isTaskList = items.contains { $0.checked != nil }
            let tag = ordered ? "ol" : "ul"
            let startAttr = ordered && start != 1 ? " start=\"\(start)\"" : ""
            let cls = isTaskList ? " class=\"contains-task-list\"" : ""
            let body = items.map { item -> String in
                var content = write(item.blocks, tight: tight)
                if tight, content.hasSuffix("\n") { content.removeLast() }
                if let checked = item.checked {
                    let box = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                    return "<li class=\"task-list-item\">\(tight ? box + content : content.replacingFirst("<p>", with: "<p>" + box))</li>"
                }
                return "<li>\(content)</li>"
            }.joined(separator: "\n")
            return "<\(tag)\(startAttr)\(cls)>\n\(body)\n</\(tag)>"
        case .table(let header, let alignments, let rows):
            func cell(_ tag: String, _ text: String, _ idx: Int) -> String {
                let align: String
                switch alignments[idx] {
                case .left: align = " style=\"text-align:left\""
                case .center: align = " style=\"text-align:center\""
                case .right: align = " style=\"text-align:right\""
                case .none: align = ""
                }
                return "<\(tag)\(align)>\(inline.render(text))</\(tag)>"
            }
            let head = "<tr>" + header.enumerated().map { cell("th", $1, $0) }.joined() + "</tr>"
            let body = rows.map { "<tr>" + $0.enumerated().map { cell("td", $1, $0) }.joined() + "</tr>" }.joined(separator: "\n")
            return "<table>\n<thead>\(head)</thead>\n<tbody>\n\(body)\n</tbody>\n</table>"
        case .rule:
            return "<hr>"
        case .html(let raw):
            return raw
        }
    }
}

private final class SlugGenerator {
    private var used: [String: Int] = [:]

    func slug(for text: String) -> String {
        var base = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { base.append(ch) }
            else if ch == " " { base.append("-") }
        }
        if base.isEmpty { base = "section" }
        let n = used[base, default: 0]
        used[base] = n + 1
        return n == 0 ? base : "\(base)-\(n)"
    }
}

// MARK: - Inline parsing

final class InlineParser {
    private let refs: [String: LinkRef]
    private let imageResolver: ((String) -> String?)?

    init(refs: [String: LinkRef], imageResolver: ((String) -> String?)?) {
        self.refs = refs
        self.imageResolver = imageResolver
    }

    private final class Node {
        var text: String
        let delimiter: Character?
        var count: Int
        let originalCount: Int
        var canOpen: Bool
        var canClose: Bool
        var openTags: [String] = []
        var closeTags: [String] = []

        init(text: String) {
            self.text = text
            delimiter = nil; count = 0; originalCount = 0; canOpen = false; canClose = false
        }

        init(delimiter: Character, count: Int, canOpen: Bool, canClose: Bool) {
            text = ""
            self.delimiter = delimiter
            self.count = count
            originalCount = count
            self.canOpen = canOpen
            self.canClose = canClose
        }

        var html: String {
            guard let d = delimiter else { return text }
            return closeTags.joined() + String(repeating: d, count: count) + openTags.joined()
        }
    }

    private static let autolinkRx = Rx(#"^<([A-Za-z][A-Za-z0-9+.\-]{1,31}:[^<>\s]*)>"#)
    private static let emailRx = Rx(#"^<([A-Za-z0-9.!#$%&'*+/=?^_`{|}~\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)*)>"#)
    private static let tagRx = Rx(#"^(?:<!--[\s\S]*?-->|</?[A-Za-z][A-Za-z0-9\-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:\-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*/?>)"#)
    private static let entityRx = Rx(#"^&(?:#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});"#)
    private static let bareURLRx = Rx(#"^(?:https?://|www\.)[^\s<]+"#)

    func render(_ text: String, insideLink: Bool = false) -> String {
        let chars = Array(text)
        var nodes: [Node] = []
        var buffer = ""

        func flush() {
            if !buffer.isEmpty { nodes.append(Node(text: buffer)); buffer = "" }
        }
        func rest(from i: Int) -> String { String(chars[i...]) }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "\n" {
                        buffer += "<br>\n"
                        i += 2
                        continue
                    }
                    if next.isASCII && (next.isPunctuation || next.isSymbol) {
                        buffer += escapeHTML(String(next))
                        i += 2
                        continue
                    }
                }
                buffer += "\\"
                i += 1

            case "`":
                let run = runLength(chars, i)
                if let close = findClosingBackticks(chars, from: i + run, length: run) {
                    var code = String(chars[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.first == " ", code.last == " ", code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    buffer += "<code>\(escapeHTML(code))</code>"
                    i = close + run
                } else {
                    buffer += String(repeating: "`", count: run)
                    i += run
                }

            case "*", "_", "~":
                let run = runLength(chars, i)
                if c == "~" && run > 2 {
                    buffer += String(repeating: "~", count: run)
                    i += run
                    continue
                }
                let before: Character = i == 0 ? " " : chars[i - 1]
                let after: Character = i + run < chars.count ? chars[i + run] : " "
                let beforeSpace = before.isWhitespace, afterSpace = after.isWhitespace
                let beforePunct = isPunctuation(before), afterPunct = isPunctuation(after)
                let leftFlanking = !afterSpace && (!afterPunct || beforeSpace || beforePunct)
                let rightFlanking = !beforeSpace && (!beforePunct || afterSpace || afterPunct)
                let canOpen: Bool, canClose: Bool
                if c == "_" {
                    canOpen = leftFlanking && (!rightFlanking || beforePunct)
                    canClose = rightFlanking && (!leftFlanking || afterPunct)
                } else {
                    canOpen = leftFlanking
                    canClose = rightFlanking
                }
                flush()
                nodes.append(Node(delimiter: c, count: run, canOpen: canOpen, canClose: canClose))
                i += run

            case "!" where i + 1 < chars.count && chars[i + 1] == "[":
                if let (html, end) = parseLink(chars, open: i + 1, image: true) {
                    buffer += html
                    i = end
                } else {
                    buffer += "!"
                    i += 1
                }

            case "[":
                if !insideLink, let (html, end) = parseLink(chars, open: i, image: false) {
                    buffer += html
                    i = end
                } else {
                    buffer += "["
                    i += 1
                }

            case "<":
                let tail = rest(from: i)
                if let m = Self.autolinkRx.match(tail) {
                    let url = m[1]!
                    buffer += insideLink ? escapeHTML(url) : "<a href=\"\(escapeAttribute(safeURL(url)))\">\(escapeHTML(url))</a>"
                    i += m[0]!.count
                } else if let m = Self.emailRx.match(tail) {
                    let email = m[1]!
                    buffer += insideLink ? escapeHTML(email) : "<a href=\"mailto:\(escapeAttribute(email))\">\(escapeHTML(email))</a>"
                    i += m[0]!.count
                } else if let m = Self.tagRx.match(tail) {
                    buffer += m[0]!
                    i += m[0]!.count
                } else {
                    buffer += "&lt;"
                    i += 1
                }

            case "&":
                if let m = Self.entityRx.match(rest(from: i)) {
                    buffer += m[0]!
                    i += m[0]!.count
                } else {
                    buffer += "&amp;"
                    i += 1
                }

            case ">":
                buffer += "&gt;"
                i += 1

            case "\"":
                buffer += "&quot;"
                i += 1

            case "\n":
                let hardBreak = buffer.hasSuffix("  ")
                while buffer.hasSuffix(" ") { buffer.removeLast() }
                buffer += hardBreak ? "<br>\n" : "\n"
                i += 1

            case "h", "w":
                let atWordStart = i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber)
                if !insideLink, atWordStart, let (html, length) = bareURL(rest(from: i)) {
                    buffer += html
                    i += length
                } else {
                    buffer.append(c)
                    i += 1
                }

            default:
                buffer.append(c)
                i += 1
            }
        }
        flush()
        processEmphasis(nodes)
        return nodes.map(\.html).joined()
    }

    // MARK: Emphasis (CommonMark delimiter algorithm, simplified)

    private func processEmphasis(_ nodes: [Node]) {
        var ci = 0
        while ci < nodes.count {
            let closer = nodes[ci]
            guard let d = closer.delimiter, closer.canClose, closer.count > 0 else { ci += 1; continue }

            var openerIndex: Int?
            var oi = ci - 1
            while oi >= 0 {
                let o = nodes[oi]
                if o.delimiter == d, o.canOpen, o.count > 0 {
                    let ruleOfThree = (o.canClose || closer.canOpen)
                        && (o.originalCount + closer.originalCount) % 3 == 0
                        && !(o.originalCount % 3 == 0 && closer.originalCount % 3 == 0)
                    if d == "~" || !ruleOfThree { openerIndex = oi; break }
                }
                oi -= 1
            }

            guard let found = openerIndex else {
                ci += 1
                continue
            }
            let opener = nodes[found]
            let use = (opener.count >= 2 && closer.count >= 2) ? 2 : 1
            let tag = d == "~" ? "del" : (use == 2 ? "strong" : "em")
            opener.openTags.insert("<\(tag)>", at: 0)
            closer.closeTags.append("</\(tag)>")
            opener.count -= use
            closer.count -= use
            for k in (found + 1)..<ci where nodes[k].delimiter != nil {
                nodes[k].canOpen = false
                nodes[k].canClose = false
            }
            if closer.count == 0 { ci += 1 }
        }
    }

    // MARK: Links & images

    private func parseLink(_ chars: [Character], open: Int, image: Bool) -> (String, Int)? {
        guard let closeBracket = matchingBracket(chars, open) else { return nil }
        let label = String(chars[(open + 1)..<closeBracket])
        var k = closeBracket + 1
        var url: String?
        var title: String?

        if k < chars.count, chars[k] == "(", let (dest, t, end) = parseInlineDestination(chars, from: k + 1) {
            url = dest
            title = t
            k = end
        } else {
            var refLabel = label
            if k < chars.count, chars[k] == "[", let close = matchingBracket(chars, k) {
                let inner = String(chars[(k + 1)..<close])
                if !inner.isEmpty { refLabel = inner }
                if let ref = refs[normalizeLabel(refLabel)] {
                    url = ref.url; title = ref.title; k = close + 1
                }
            } else if let ref = refs[normalizeLabel(refLabel)] {
                url = ref.url; title = ref.title
            }
        }

        guard let destination = url else { return nil }
        let titleAttr = title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""

        if image {
            let alt = stripTags(render(label, insideLink: true))
            var src = safeURL(destination)
            if let resolved = imageResolver?(destination) { src = resolved }
            return ("<img src=\"\(escapeAttribute(src))\" alt=\"\(escapeAttribute(alt))\"\(titleAttr)>", k)
        }
        return ("<a href=\"\(escapeAttribute(safeURL(destination)))\"\(titleAttr)>\(render(label, insideLink: true))</a>", k)
    }

    private func matchingBracket(_ chars: [Character], _ open: Int) -> Int? {
        var depth = 0
        var j = open
        while j < chars.count {
            let ch = chars[j]
            if ch == "\\" { j += 2; continue }
            if ch == "`" {
                let run = runLength(chars, j)
                if let close = findClosingBackticks(chars, from: j + run, length: run) { j = close + run; continue }
                j += run
                continue
            }
            if ch == "[" { depth += 1 }
            if ch == "]" {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }

    /// Parses `dest "title")` starting just after the opening parenthesis.
    private func parseInlineDestination(_ chars: [Character], from start: Int) -> (String, String?, Int)? {
        var j = start
        func skipSpace() { while j < chars.count, chars[j].isWhitespace { j += 1 } }
        skipSpace()
        var dest = ""
        if j < chars.count, chars[j] == "<" {
            j += 1
            while j < chars.count, chars[j] != ">" {
                if chars[j] == "\n" { return nil }
                dest.append(chars[j]); j += 1
            }
            guard j < chars.count else { return nil }
            j += 1
        } else {
            var depth = 0
            while j < chars.count {
                let ch = chars[j]
                if ch.isWhitespace { break }
                if ch == "\\", j + 1 < chars.count, chars[j + 1].isPunctuation || chars[j + 1].isSymbol {
                    dest.append(chars[j + 1]); j += 2; continue
                }
                if ch == "(" { depth += 1 }
                if ch == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                dest.append(ch)
                j += 1
            }
        }
        skipSpace()
        var title: String?
        if j < chars.count, let closing: Character = ["\"": "\"", "'": "'", "(": ")"][chars[j]] {
            j += 1
            var t = ""
            while j < chars.count, chars[j] != closing {
                if chars[j] == "\\", j + 1 < chars.count { t.append(chars[j + 1]); j += 2; continue }
                t.append(chars[j]); j += 1
            }
            guard j < chars.count else { return nil }
            j += 1
            title = t
            skipSpace()
        }
        guard j < chars.count, chars[j] == ")" else { return nil }
        return (dest, title, j + 1)
    }

    private func bareURL(_ text: String) -> (String, Int)? {
        guard text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("www.") else { return nil }
        guard let m = Self.bareURLRx.match(text) else { return nil }
        var url = m[0]!
        // Trim trailing punctuation and unbalanced closing parentheses, like GitHub does.
        while let last = url.last {
            if "?!.,:*_~'\";".contains(last) {
                url.removeLast()
            } else if last == ")" && url.filter({ $0 == ")" }).count > url.filter({ $0 == "(" }).count {
                url.removeLast()
            } else {
                break
            }
        }
        guard url.count > (url.hasPrefix("www.") ? 4 : 8) else { return nil }
        let href = url.hasPrefix("www.") ? "http://" + url : url
        return ("<a href=\"\(escapeAttribute(href))\">\(escapeHTML(url))</a>", url.count)
    }

    private func runLength(_ chars: [Character], _ i: Int) -> Int {
        var n = 0
        while i + n < chars.count, chars[i + n] == chars[i] { n += 1 }
        return n
    }

    private func findClosingBackticks(_ chars: [Character], from start: Int, length: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "`" {
                let run = runLength(chars, j)
                if run == length { return j }
                j += run
            } else {
                j += 1
            }
        }
        return nil
    }

    private func isPunctuation(_ c: Character) -> Bool {
        c.isPunctuation || c.isSymbol
    }

    private func safeURL(_ url: String) -> String {
        let lowered = url.trimmingCharacters(in: .whitespaces).lowercased()
        if lowered.hasPrefix("javascript:") || lowered.hasPrefix("vbscript:") { return "#" }
        return url.replacingOccurrences(of: " ", with: "%20")
    }

    private func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

// MARK: - Helpers

final class Rx {
    private let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Capture groups of the first match (index 0 = whole match), or nil.
    func match(_ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, options: [.anchored], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map {
            let r = m.range(at: $0)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    func test(_ s: String) -> Bool {
        regex.firstMatch(in: s, options: [.anchored], range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

func escapeHTML(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(ch)
        }
    }
    return out
}

func escapeAttribute(_ s: String) -> String {
    escapeHTML(s).replacingOccurrences(of: "'", with: "&#39;")
}

private func isBlank(_ line: String) -> Bool {
    line.allSatisfy { $0 == " " || $0 == "\t" }
}

private func leadingSpaces(_ line: String) -> Int {
    line.prefix(while: { $0 == " " }).count
}

private func expandLeadingTabs(_ line: String) -> String {
    guard line.contains("\t") else { return line }
    var out = ""
    var column = 0
    var inLeading = true
    for ch in line {
        if inLeading && ch == "\t" {
            let width = 4 - (column % 4)
            out += String(repeating: " ", count: width)
            column += width
        } else {
            if ch != " " { inLeading = false }
            out.append(ch)
            column += 1
        }
    }
    return out
}

extension String {
    func trimmingLeadingWhitespace() -> String {
        String(drop(while: { $0 == " " || $0 == "\t" }))
    }

    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return s
    }

    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let range = range(of: target) else { return self }
        return replacingCharacters(in: range, with: replacement)
    }
}
