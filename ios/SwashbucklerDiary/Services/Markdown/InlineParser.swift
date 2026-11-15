import Foundation

/// 行内语法解析。
///
/// 用一次自左向右的扫描完成，遇到成对标记就递归解析内部内容。
/// 复杂度是 O(n)，对长文本（数万字）也不会成为瓶颈。
enum InlineParser {
    static func parse(_ text: String) -> [MarkdownInline] {
        guard !text.isEmpty else { return [] }
        var result: [MarkdownInline] = []
        var buffer = ""
        var index = text.startIndex

        func flush() {
            if !buffer.isEmpty {
                result.append(.text(buffer))
                buffer = ""
            }
        }

        while index < text.endIndex {
            let char = text[index]

            // 硬换行
            if char == "\n" {
                flush()
                result.append(.lineBreak)
                index = text.index(after: index)
                continue
            }

            // 转义
            if char == "\\", let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex), next < text.endIndex {
                let escaped = text[next]
                if #"\\`*_{}[]()#+-.!|~$>"#.contains(escaped) {
                    buffer.append(escaped)
                    index = text.index(after: next)
                    continue
                }
            }

            // 行内代码
            if char == "`" {
                if let span = matchCodeSpan(text, from: index) {
                    flush()
                    result.append(.code(span.content))
                    index = span.end
                    continue
                }
            }

            // 图片 ![alt](url "title")
            if char == "!", let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex), next < text.endIndex, text[next] == "[" {
                if let image = matchImage(text, from: index) {
                    flush()
                    result.append(.image(alt: image.alt, url: image.url, title: image.title))
                    index = image.end
                    continue
                }
            }

            // 链接 [text](url "title")
            if char == "[" {
                if let link = matchLink(text, from: index) {
                    flush()
                    result.append(.link(text: parse(link.text), url: link.url, title: link.title))
                    index = link.end
                    continue
                }
            }

            // 脚注引用 [^1]
            if char == "[", let footnote = matchFootnote(text, from: index) {
                flush()
                result.append(.footnoteRef(footnote.label))
                index = footnote.end
                continue
            }

            // 行内数学 $...$
            if char == "$" {
                if let math = matchInlineMath(text, from: index) {
                    flush()
                    result.append(.math(math.content))
                    index = math.end
                    continue
                }
            }

            // 加粗 / 斜体 / 删除线
            if char == "*" || char == "_" || char == "~" {
                if let emphasis = matchEmphasis(text, from: index) {
                    flush()
                    result.append(emphasis.inline)
                    index = emphasis.end
                    continue
                }
            }

            // 裸链接
            if char == "<", let autolink = matchAutolink(text, from: index) {
                flush()
                result.append(.link(text: [.text(autolink.url)], url: autolink.url, title: nil))
                index = autolink.end
                continue
            }

            buffer.append(char)
            index = text.index(after: index)
        }

        flush()
        return mergeAdjacentText(result)
    }

    /// 独占一行且只有一个图片时返回该图片信息，供块级解析提升使用。
    static func singleImage(_ line: String) -> (alt: String, url: String, title: String?)? {
        guard line.hasPrefix("![") else { return nil }
        guard let image = matchImage(line, from: line.startIndex) else { return nil }
        return image.end == line.endIndex ? (image.alt, image.url, image.title) : nil
    }

    // MARK: - 匹配器

    private static func matchCodeSpan(_ text: String, from start: String.Index) -> (content: String, end: String.Index)? {
        var tickCount = 0
        var cursor = start
        while cursor < text.endIndex, text[cursor] == "`" {
            tickCount += 1
            cursor = text.index(after: cursor)
        }
        let fence = String(repeating: "`", count: tickCount)
        guard let closeRange = text.range(of: fence, range: cursor..<text.endIndex) else { return nil }
        var content = String(text[cursor..<closeRange.lowerBound])
        if content.hasPrefix(" ") && content.hasSuffix(" ") && content.count > 2 {
            content.removeFirst()
            content.removeLast()
        }
        return (content, closeRange.upperBound)
    }

    private static func matchImage(_ text: String, from start: String.Index) -> (alt: String, url: String, title: String?, end: String.Index)? {
        let afterBang = text.index(after: start)
        guard afterBang < text.endIndex, text[afterBang] == "[" else { return nil }
        guard let altEnd = findClosingBracket(text, from: text.index(after: afterBang)) else { return nil }
        let alt = String(text[text.index(after: afterBang)..<altEnd])
        let afterAlt = text.index(after: altEnd)
        guard afterAlt < text.endIndex, text[afterAlt] == "(" else { return nil }
        guard let parsed = parseDestination(text, from: text.index(after: afterAlt)) else { return nil }
        return (alt, parsed.url, parsed.title, parsed.end)
    }

    private static func matchLink(_ text: String, from start: String.Index) -> (text: String, url: String, title: String?, end: String.Index)? {
        guard let labelEnd = findClosingBracket(text, from: text.index(after: start)) else { return nil }
        let label = String(text[text.index(after: start)..<labelEnd])
        let afterLabel = text.index(after: labelEnd)
        guard afterLabel < text.endIndex, text[afterLabel] == "(" else { return nil }
        guard let parsed = parseDestination(text, from: text.index(after: afterLabel)) else { return nil }
        return (label, parsed.url, parsed.title, parsed.end)
    }

    private static func matchFootnote(_ text: String, from start: String.Index) -> (label: String, end: String.Index)? {
        guard let close = findClosingBracket(text, from: text.index(after: start)) else { return nil }
        let label = String(text[text.index(after: start)..<close])
        guard label.hasPrefix("^") else { return nil }
        return (String(label.dropFirst()), text.index(after: close))
    }

    private static func matchInlineMath(_ text: String, from start: String.Index) -> (content: String, end: String.Index)? {
        var cursor = text.index(after: start)
        guard cursor < text.endIndex else { return nil }
        // 避免把 "$100 和 $200" 误判成公式：要求相邻非空白
        if text[cursor].isWhitespace { return nil }
        var content = ""
        while cursor < text.endIndex {
            let char = text[cursor]
            if char == "\\" {
                content.append(char)
                cursor = text.index(after: cursor)
                if cursor < text.endIndex {
                    content.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                continue
            }
            if char == "$" {
                // 闭合 $ 后面紧跟数字时，多半是价格（"$100 和 $200"）而不是公式
                let next = text.index(after: cursor)
                if next < text.endIndex, text[next].isNumber { return nil }
                return (content, next)
            }
            if char == "\n" { return nil }
            content.append(char)
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func matchEmphasis(_ text: String, from start: String.Index) -> (inline: MarkdownInline, end: String.Index)? {
        let marker = text[start]
        var markerCount = 0
        var cursor = start
        while cursor < text.endIndex, text[cursor] == marker {
            markerCount += 1
            cursor = text.index(after: cursor)
            if marker == "~" && markerCount == 2 { break }
        }

        let token: String
        let build: ([MarkdownInline]) -> MarkdownInline
        if marker == "~" {
            guard markerCount >= 2 else { return nil }
            token = "~~"
            build = { .strikethrough($0) }
        } else if markerCount >= 2 {
            token = String(repeating: marker, count: 2)
            build = { .strong($0) }
        } else {
            token = String(marker)
            build = { .emphasis($0) }
        }

        guard cursor < text.endIndex else { return nil }
        guard let closeRange = text.range(of: token, range: cursor..<text.endIndex) else { return nil }
        // 内容不能以空白开头，否则多半不是强调（例如 "2 * 3 * 4"）
        guard let first = text[cursor..<closeRange.lowerBound].first, !first.isWhitespace else { return nil }
        let inner = String(text[cursor..<closeRange.lowerBound])
        guard !inner.isEmpty else { return nil }
        return (build(parse(inner)), closeRange.upperBound)
    }

    private static func matchAutolink(_ text: String, from start: String.Index) -> (url: String, end: String.Index)? {
        guard let close = text[start...].firstIndex(of: ">") else { return nil }
        let inner = String(text[text.index(after: start)..<close])
        guard inner.contains("://") || inner.contains("@") else { return nil }
        let url = inner.contains("://") ? inner : "mailto:\(inner)"
        return (url, text.index(after: close))
    }

    private static func findClosingBracket(_ text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var cursor = start
        while cursor < text.endIndex {
            let char = text[cursor]
            if char == "\\" {
                cursor = text.index(cursor, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if char == "[" { depth += 1 }
            if char == "]" {
                if depth == 0 { return cursor }
                depth -= 1
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func parseDestination(_ text: String, from start: String.Index) -> (url: String, title: String?, end: String.Index)? {
        var cursor = start
        var depth = 1
        var raw = ""
        while cursor < text.endIndex {
            let char = text[cursor]
            if char == "\\" {
                raw.append(char)
                cursor = text.index(after: cursor)
                if cursor < text.endIndex {
                    raw.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                continue
            }
            if char == "(" { depth += 1 }
            if char == ")" {
                depth -= 1
                if depth == 0 {
                    let parsed = splitURLAndTitle(raw)
                    return (parsed.url, parsed.title, text.index(after: cursor))
                }
            }
            if char == "\n" && depth > 0 { return nil }
            raw.append(char)
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func splitURLAndTitle(_ raw: String) -> (url: String, title: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quoteStart = trimmed.firstIndex(where: { $0 == "\"" || $0 == "'" }) else {
            return (trimmed, nil)
        }
        let url = String(trimmed[trimmed.startIndex..<quoteStart]).trimmingCharacters(in: .whitespaces)
        let quoteChar = trimmed[quoteStart]
        if let quoteEnd = trimmed[trimmed.index(after: quoteStart)...].lastIndex(of: quoteChar) {
            let title = String(trimmed[trimmed.index(after: quoteStart)..<quoteEnd])
            return (url, title.isEmpty ? nil : title)
        }
        return (url, nil)
    }

    private static func mergeAdjacentText(_ input: [MarkdownInline]) -> [MarkdownInline] {
        var output: [MarkdownInline] = []
        for item in input {
            if case .text(let value) = item, case .text(let previous)? = output.last {
                output[output.count - 1] = .text(previous + value)
            } else {
                output.append(item)
            }
        }
        return output
    }
}
