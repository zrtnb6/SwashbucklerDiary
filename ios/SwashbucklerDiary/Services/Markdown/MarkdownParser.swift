import Foundation

// MARK: - AST

enum MarkdownBlock: Hashable {
    case heading(level: Int, text: [MarkdownInline])
    case paragraph([MarkdownInline])
    case bulletList([MarkdownListItem])
    case orderedList(start: Int, items: [MarkdownListItem])
    case taskList([MarkdownTaskItem])
    case codeBlock(language: String?, code: String)
    case quote([MarkdownBlock])
    case table(MarkdownTable)
    case divider
    case mathBlock(String)
    case image(alt: String, url: String, title: String?)
    case html(String)
}

struct MarkdownListItem: Hashable {
    var blocks: [MarkdownBlock]
    var depth: Int
}

struct MarkdownTaskItem: Hashable {
    var checked: Bool
    var blocks: [MarkdownBlock]
}

struct MarkdownTable: Hashable {
    enum Alignment: Hashable { case leading, center, trailing }
    var headers: [[MarkdownInline]]
    var alignments: [Alignment]
    var rows: [[[MarkdownInline]]]
}

indirect enum MarkdownInline: Hashable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(text: [MarkdownInline], url: String, title: String?)
    case image(alt: String, url: String, title: String?)
    case math(String)
    case lineBreak
    case footnoteRef(String)
}

extension Array where Element == MarkdownInline {
    var plainText: String {
        map { inline in
            switch inline {
            case .text(let value): return value
            case .emphasis(let children), .strong(let children), .strikethrough(let children):
                return children.plainText
            case .code(let value): return value
            case .link(let text, _, _): return text.plainText
            case .image(let alt, _, _): return alt
            case .math(let value): return value
            case .lineBreak: return "\n"
            case .footnoteRef(let value): return "[\(value)]"
            }
        }.joined()
    }
}

// MARK: - 解析器

/// 手写的 Markdown 解析器。
///
/// 不引入第三方渲染库的原因：原项目的编辑器是 Vditor（Web），
/// 若为了渲染再塞一个 WebView 或重量级依赖，就违背了“真正原生”的目标。
/// 这里覆盖日记场景实际会用到的语法：标题、列表（含任务列表）、代码块、引用、
/// 表格、分割线、行内强调/删除线/代码/链接/图片/数学公式。
enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var parser = BlockParser(lines: lines)
        return parser.parse()
    }

    /// 用于卡片摘要与搜索：剥离语法标记，只留文字。
    static func plainText(_ text: String) -> String {
        parse(text).map(plainText(of:)).joined(separator: "\n")
    }

    private static func plainText(of block: MarkdownBlock) -> String {
        switch block {
        case .heading(_, let text), .paragraph(let text):
            return text.plainText
        case .bulletList(let items), .orderedList(_, let items):
            return items.map { $0.blocks.map(plainText(of:)).joined(separator: " ") }.joined(separator: "\n")
        case .taskList(let items):
            return items.map { $0.blocks.map(plainText(of:)).joined(separator: " ") }.joined(separator: "\n")
        case .codeBlock(_, let code):
            return code
        case .quote(let blocks):
            return blocks.map(plainText(of:)).joined(separator: "\n")
        case .table(let table):
            var rows = [table.headers.map { $0.plainText }.joined(separator: " | ")]
            rows.append(contentsOf: table.rows.map { $0.map { $0.plainText }.joined(separator: " | ") })
            return rows.joined(separator: "\n")
        case .divider:
            return ""
        case .mathBlock(let latex), .html(let latex):
            return latex
        case .image(let alt, _, _):
            return alt
        }
    }
}

private struct BlockParser {
    let lines: [String]
    var index = 0

    init(lines: [String]) {
        self.lines = lines
    }

    mutating func parse() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fenceStart(trimmed) {
                blocks.append(consumeCodeBlock(fence: fence))
                continue
            }

            if let heading = headingBlock(line) {
                blocks.append(heading.block)
                index += heading.consumed
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" || trimmed == "- - -" {
                blocks.append(.divider)
                index += 1
                continue
            }

            if trimmed.hasPrefix("$$") {
                if let math = consumeMathBlock() {
                    blocks.append(.mathBlock(math))
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                blocks.append(consumeQuote())
                continue
            }

            if let table = tryConsumeTable() {
                blocks.append(.table(table))
                continue
            }

            if isBulletLine(trimmed) || isOrderedLine(trimmed) {
                blocks.append(consumeList())
                continue
            }

            blocks.append(consumeParagraph())
        }
        return blocks
    }

    // MARK: 代码块

    private func fenceStart(_ trimmed: String) -> (marker: String, language: String?)? {
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let marker = trimmed.hasPrefix("```") ? "```" : "~~~"
        var language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        if language.isEmpty { language = "" }
        return (marker, language.isEmpty ? nil : language)
    }

    private mutating func consumeCodeBlock(fence: (marker: String, language: String?)) -> MarkdownBlock {
        index += 1
        var code: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence.marker) {
                index += 1
                break
            }
            code.append(lines[index])
            index += 1
        }
        return .codeBlock(language: fence.language, code: code.joined(separator: "\n"))
    }

    // MARK: 标题

    private func headingBlock(_ line: String) -> (block: MarkdownBlock, consumed: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else {
            // Setext 风格：下一行是 === 或 ---
            if index + 1 < lines.count {
                let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, next.count >= 2, next.allSatisfy({ $0 == "=" }) {
                    return (.heading(level: 1, text: InlineParser.parse(trimmed)), 2)
                }
                if !trimmed.isEmpty, next.count >= 2, next.allSatisfy({ $0 == "-" }) {
                    return (.heading(level: 2, text: InlineParser.parse(trimmed)), 2)
                }
            }
            return nil
        }
        var level = 0
        for char in trimmed {
            if char == "#" { level += 1 } else { break }
        }
        guard level <= 6 else { return nil }
        let content = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        return (.heading(level: level, text: InlineParser.parse(content)), 1)
    }

    // MARK: 数学块

    private mutating func consumeMathBlock() -> String? {
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        let afterFence = String(first.dropFirst(2))
        if afterFence.hasSuffix("$$"), afterFence.count > 2 {
            index += 1
            return String(afterFence.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        index += 1
        var body: [String] = []
        while index < lines.count {
            let current = lines[index].trimmingCharacters(in: .whitespaces)
            if current.hasPrefix("$$") {
                index += 1
                return body.joined(separator: "\n")
            }
            body.append(lines[index])
            index += 1
        }
        // 没有闭合，退回成普通段落
        return nil
    }

    // MARK: 引用

    private mutating func consumeQuote() -> MarkdownBlock {
        var inner: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var content = String(trimmed.dropFirst())
            if content.hasPrefix(" ") { content.removeFirst() }
            inner.append(content)
            index += 1
        }
        var nested = BlockParser(lines: inner)
        return .quote(nested.parse())
    }

    // MARK: 表格

    private mutating func tryConsumeTable() -> MarkdownTable? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index]
        let separatorLine = lines[index + 1]
        guard headerLine.contains("|"), isTableSeparator(separatorLine) else { return nil }

        let headers = splitTableRow(headerLine)
        let separators = splitTableRow(separatorLine)
        guard headers.count == separators.count, headers.count >= 1 else { return nil }

        let alignments: [MarkdownTable.Alignment] = separators.map { spec in
            let left = spec.hasPrefix(":")
            let right = spec.hasSuffix(":")
            if left && right { return .center }
            if right { return .trailing }
            return .leading
        }

        index += 2
        var rows: [[[MarkdownInline]]] = []
        while index < lines.count {
            let line = lines[index]
            guard line.contains("|") else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            var cells = splitTableRow(line)
            if cells.count < headers.count {
                cells.append(contentsOf: Array(repeating: "", count: headers.count - cells.count))
            }
            if cells.count > headers.count {
                cells = Array(cells.prefix(headers.count))
            }
            rows.append(cells.map { InlineParser.parse($0.trimmingCharacters(in: .whitespaces)) })
            index += 1
        }

        return MarkdownTable(
            headers: headers.map { InlineParser.parse($0.trimmingCharacters(in: .whitespaces)) },
            alignments: alignments,
            rows: rows
        )
    }

    private func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let allowed = CharacterSet(charactersIn: "-:| \t")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return splitTableRow(trimmed).allSatisfy { cell in
            let spec = cell
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            return !spec.isEmpty && spec.allSatisfy { $0 == "-" }
        }
    }

    private func splitTableRow(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for char in text {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                current.append(char)
                continue
            }
            if char == "`" { inCode.toggle() }
            if char == "|" && !inCode {
                cells.append(current)
                current = ""
                continue
            }
            current.append(char)
        }
        cells.append(current)
        return cells
    }

    // MARK: 列表

    private func isBulletLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
    }

    private func isOrderedLine(_ trimmed: String) -> Bool {
        guard let dotIndex = trimmed.firstIndex(of: ".") ?? trimmed.firstIndex(of: ")") else { return false }
        let prefix = trimmed[trimmed.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return false }
        let after = trimmed.index(after: dotIndex)
        return after < trimmed.endIndex && trimmed[after] == " "
    }

    private mutating func consumeList() -> MarkdownBlock {
        let firstTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
        let ordered = isOrderedLine(firstTrimmed)

        var taskItems: [MarkdownTaskItem] = []
        var plainItems: [MarkdownListItem] = []
        var detectedTask = false

        if ordered {
            var start = 1
            if let dotIndex = firstTrimmed.firstIndex(where: { $0 == "." || $0 == ")" }),
               let value = Int(firstTrimmed[firstTrimmed.startIndex..<dotIndex]) {
                start = value
            }
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard isOrderedLine(trimmed) else { break }
                let content = stripListMarker(trimmed)
                var itemLines = [content]
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty || isOrderedLine(nextTrimmed) || isBulletLine(nextTrimmed) { break }
                    if !next.hasPrefix("  ") && !next.hasPrefix("\t") { break }
                    itemLines.append(nextTrimmed)
                    index += 1
                }
                var nested = BlockParser(lines: itemLines)
                plainItems.append(MarkdownListItem(blocks: normalize(nested.parse()), depth: 0))
            }
            return .orderedList(start: start, items: plainItems)
        }

        // 无序列表：先收集，若第一项是任务项则整体按任务列表处理
        var collected: [(checked: Bool?, lines: [String])] = []
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard isBulletLine(trimmed) else { break }
            var content = stripListMarker(trimmed)
            var checked: Bool?
            if content.hasPrefix("[ ] ") {
                checked = false
                content = String(content.dropFirst(4))
            } else if content.lowercased().hasPrefix("[x] ") {
                checked = true
                content = String(content.dropFirst(4))
            }
            var itemLines = [content]
            index += 1
            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty || isBulletLine(nextTrimmed) || isOrderedLine(nextTrimmed) { break }
                if !next.hasPrefix("  ") && !next.hasPrefix("\t") { break }
                itemLines.append(nextTrimmed)
                index += 1
            }
            collected.append((checked, itemLines))
        }

        if collected.contains(where: { $0.checked != nil }) {
            detectedTask = true
        }

        if detectedTask {
            for item in collected {
                var nested = BlockParser(lines: item.lines)
                taskItems.append(MarkdownTaskItem(checked: item.checked ?? false, blocks: normalize(nested.parse())))
            }
            return .taskList(taskItems)
        }

        for item in collected {
            var nested = BlockParser(lines: item.lines)
            plainItems.append(MarkdownListItem(blocks: normalize(nested.parse()), depth: 0))
        }
        return .bulletList(plainItems)
    }

    /// 列表项内如果只解析出段落，直接展开成段落；否则保留块结构。
    private func normalize(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        blocks.isEmpty ? [.paragraph([])] : blocks
    }

    private func stripListMarker(_ trimmed: String) -> String {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return String(trimmed.dropFirst(2))
        }
        if let dotIndex = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) {
            let after = trimmed.index(after: dotIndex)
            if after < trimmed.endIndex {
                return String(trimmed[after...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed
    }

    // MARK: 段落

    private mutating func consumeParagraph() -> MarkdownBlock {
        var collected: [String] = []
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if fenceStart(trimmed) != nil { break }
            if headingBlock(raw) != nil { break }
            if trimmed.hasPrefix(">") || isBulletLine(trimmed) || isOrderedLine(trimmed) { break }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { break }
            collected.append(raw)
            index += 1
        }
        if collected.isEmpty {
            index += 1
            return .paragraph([])
        }

        // 独占一行的图片，提升为块级图片，便于做全宽渲染
        if collected.count == 1,
           let image = InlineParser.singleImage(collected[0].trimmingCharacters(in: .whitespaces)) {
            return .image(alt: image.alt, url: image.url, title: image.title)
        }

        let joined = collected.joined(separator: "\n")
        return .paragraph(InlineParser.parse(joined))
    }
}
