import XCTest
@testable import SwashbucklerDiary

final class MarkdownParserTests: XCTestCase {
    func testHeadingLevels() {
        let blocks = MarkdownParser.parse("# 一级\n## 二级\n###### 六级")
        XCTAssertEqual(blocks.count, 3)
        if case .heading(let level, let text) = blocks[0] {
            XCTAssertEqual(level, 1)
            XCTAssertEqual(text.plainText, "一级")
        } else {
            XCTFail("第一个块应为标题")
        }
        if case .heading(let level, _) = blocks[2] {
            XCTAssertEqual(level, 6)
        }
    }

    func testUnorderedAndOrderedList() {
        let bullets = MarkdownParser.parse("- 甲\n- 乙\n- 丙")
        guard case .bulletList(let items) = bullets[0] else {
            return XCTFail("应为无序列表")
        }
        XCTAssertEqual(items.count, 3)

        let ordered = MarkdownParser.parse("3. 第三\n4. 第四")
        guard case .orderedList(let start, let orderedItems) = ordered[0] else {
            return XCTFail("应为有序列表")
        }
        XCTAssertEqual(start, 3)
        XCTAssertEqual(orderedItems.count, 2, "从 3 开始时也必须完整收集后续项")
    }

    func testTaskList() {
        let blocks = MarkdownParser.parse("- [x] 完成\n- [ ] 未完成")
        guard case .taskList(let items) = blocks[0] else {
            return XCTFail("应为任务列表")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].checked)
        XCTAssertFalse(items[1].checked)
    }

    func testTableWithSpacesInSeparator() {
        let text = """
        | 项目 | 状态 |
        | --- | --- |
        | 列表 | 完成 |
        """
        let blocks = MarkdownParser.parse(text)
        guard case .table(let table) = blocks[0] else {
            return XCTFail("带空格的分隔行也必须能识别成表格")
        }
        XCTAssertEqual(table.headers.count, 2)
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0][0].plainText, "列表")
    }

    func testCodeFenceWithLanguage() {
        let blocks = MarkdownParser.parse("```swift\nlet a = 1\nlet b = 2\n```")
        guard case .codeBlock(let language, let code) = blocks[0] else {
            return XCTFail("应为代码块")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let a = 1\nlet b = 2")
    }

    func testQuoteContainsNestedBlocks() {
        let blocks = MarkdownParser.parse("> 引用第一行\n> 引用第二行")
        guard case .quote(let inner) = blocks[0] else {
            return XCTFail("应为引用块")
        }
        XCTAssertEqual(inner.count, 1)
    }

    func testInlineStyles() {
        let inlines = InlineParser.parse("**粗** *斜* ~~删~~ `码` [链](https://a.com) ![图](appdata/Image/x.jpg)")
        XCTAssertTrue(inlines.contains { if case .strong = $0 { return true } else { return false } })
        XCTAssertTrue(inlines.contains { if case .emphasis = $0 { return true } else { return false } })
        XCTAssertTrue(inlines.contains { if case .strikethrough = $0 { return true } else { return false } })
        XCTAssertTrue(inlines.contains { if case .code = $0 { return true } else { return false } })
        XCTAssertTrue(inlines.contains { if case .link = $0 { return true } else { return false } })
        XCTAssertTrue(inlines.contains { if case .image = $0 { return true } else { return false } })
    }

    func testInlineMathAndSuperscript() {
        let blocks = MarkdownParser.parse("$E = mc^2$")
        guard case .paragraph(let inlines) = blocks[0] else {
            return XCTFail("应为段落")
        }
        guard case .math(let latex) = inlines.first else {
            return XCTFail("应为公式")
        }
        XCTAssertEqual(latex, "E = mc^2")
        XCTAssertTrue(MathRender.prettify(latex).contains("²"))
    }

    func testDollarSignNotMath() {
        // "$100 和 $200" 不应该被当成公式
        let inlines = InlineParser.parse("价格 $100 和 $200")
        XCTAssertFalse(inlines.contains { if case .math = $0 { return true } else { return false } })
    }

    func testPlainTextStripsSyntax() {
        let text = "# 标题\n\n- [x] 任务\n\n**加粗** 内容"
        let plain = MarkdownParser.plainText(text)
        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("[x]"))
        XCTAssertTrue(plain.contains("标题"))
        XCTAssertTrue(plain.contains("任务"))
    }

    func testUnclosedFenceDoesNotCrash() {
        let blocks = MarkdownParser.parse("```swift\nlet a = 1")
        XCTAssertFalse(blocks.isEmpty)
    }

    func testLargeDocumentPerformance() {
        let paragraph = String(repeating: "这是一段用来测试解析性能的正文，包含 **加粗** 与 `代码`。\n\n", count: 800)
        measure {
            _ = MarkdownParser.parse(paragraph)
        }
    }
}
