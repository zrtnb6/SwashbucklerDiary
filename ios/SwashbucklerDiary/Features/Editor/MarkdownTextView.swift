import SwiftUI
import UIKit

/// 编辑器的文本视图代理。
///
/// 通过它把「在光标处插入 Markdown 片段」这件事从 SwiftUI 里解耦出来：
/// 工具栏按钮只需要调 `insert(...)`，不用关心 UITextView 的细节。
@MainActor
final class MarkdownEditorProxy: ObservableObject {
    weak var textView: UITextView?
    var onChange: ((String) -> Void)?

    /// 在光标处插入文本；`wrapping` 不为空时用它将选中内容包裹起来。
    func insert(_ snippet: String, wrapping: (prefix: String, suffix: String)? = nil, linePrefix: String? = nil) {
        guard let textView else { return }
        let range = textView.selectedRange
        let nsText = textView.text as NSString
        let selected = nsText.substring(with: range)

        let replacement: String
        let newSelection: NSRange

        if let wrapping {
            if selected.isEmpty {
                replacement = wrapping.prefix + wrapping.suffix
                newSelection = NSRange(location: range.location + (wrapping.prefix as NSString).length, length: 0)
            } else {
                replacement = wrapping.prefix + selected + wrapping.suffix
                newSelection = NSRange(location: range.location + (wrapping.prefix as NSString).length,
                                       length: (selected as NSString).length)
            }
        } else if let linePrefix {
            // 行首插入：找到当前行起点
            let lineStart = nsText.lineRange(for: NSRange(location: range.location, length: 0)).location
            let lineText = nsText.substring(with: nsText.lineRange(for: NSRange(location: range.location, length: 0)))
            let already = lineText.hasPrefix(linePrefix)
            replacement = already ? "" : linePrefix
            newSelection = NSRange(location: range.location + (already ? 0 : (linePrefix as NSString).length), length: 0)
            if !already {
                textView.textStorage.replaceCharacters(in: NSRange(location: lineStart, length: 0), with: replacement)
                textView.selectedRange = newSelection
                notifyChange()
                return
            }
            return
        } else {
            replacement = snippet
            newSelection = NSRange(location: range.location + (snippet as NSString).length, length: 0)
        }

        textView.textStorage.replaceCharacters(in: range, with: replacement)
        textView.selectedRange = newSelection
        notifyChange()
    }

    /// 在当前行末尾另起一行插入（用于表格、代码块这类块级片段）。
    func insertBlock(_ snippet: String) {
        guard let textView else { return }
        let nsText = textView.text as NSString
        let range = textView.selectedRange
        let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        let needsLeadingNewline = lineRange.location + lineRange.length > 0
            && !nsText.substring(with: lineRange).hasSuffix("\n\n")
        let prefix = needsLeadingNewline ? "\n" : ""
        let text = prefix + snippet
        textView.textStorage.replaceCharacters(in: range, with: text)
        textView.selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
        notifyChange()
    }

    func focus() {
        textView?.becomeFirstResponder()
    }

    func undo() {
        textView?.undoManager?.undo()
        notifyChange()
    }

    func redo() {
        textView?.undoManager?.redo()
        notifyChange()
    }

    private func notifyChange() {
        guard let textView else { return }
        onChange?(textView.text)
        textView.undoManager?.setActionName("编辑")
    }
}

/// 原生 Markdown 文本编辑视图。
///
/// 用 UITextView 而不是 SwiftUI 的 TextEditor，原因很实际：
/// 需要精确控制光标、撤销栈、插入位置，以及长文本下的滚动性能。
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    let proxy: MarkdownEditorProxy
    var placeholder: String = "写点什么…"
    var fontSize: CGFloat = 17
    var lineSpacing: CGFloat = 5
    var autoFocus: Bool = false

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.systemFont(ofSize: fontSize)
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .default
        textView.spellCheckingType = .default
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.allowsEditingTextAttributes = false
        textView.typingAttributes = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor.label,
            .paragraphStyle: Self.paragraphStyle(lineSpacing: lineSpacing),
        ]
        textView.text = text
        textView.isEditable = true
        textView.isSelectable = true

        // 撤销/重做依赖 UndoManager，显式打开
        textView.undoManager?.levelsOfUndo = 200

        proxy.textView = textView
        context.coordinator.placeholderLabel.isHidden = !text.isEmpty
        textView.addSubview(context.coordinator.placeholderLabel)
        context.coordinator.layoutPlaceholder(in: textView)

        if autoFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                textView.becomeFirstResponder()
                textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            let selected = textView.selectedRange
            textView.text = text
            let length = (text as NSString).length
            textView.selectedRange = NSRange(location: min(selected.location, length), length: 0)
        }
        proxy.textView = textView
        proxy.onChange = { newValue in
            if text != newValue { text = newValue }
        }
        textView.typingAttributes = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor.label,
            .paragraphStyle: Self.paragraphStyle(lineSpacing: lineSpacing),
        ]
        context.coordinator.placeholderLabel.isHidden = !textView.text.isEmpty
        context.coordinator.layoutPlaceholder(in: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func paragraphStyle(lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = 6
        return style
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: MarkdownTextView
        let placeholderLabel: UILabel = {
            let label = UILabel()
            label.textColor = .placeholderText
            label.font = UIFont.systemFont(ofSize: 17)
            label.numberOfLines = 0
            return label
        }()

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            super.init()
            placeholderLabel.text = parent.placeholder
        }

        func layoutPlaceholder(in textView: UITextView) {
            let inset = textView.textContainerInset
            placeholderLabel.frame = CGRect(
                x: inset.left,
                y: inset.top,
                width: max(0, textView.bounds.width - inset.left - inset.right),
                height: 28
            )
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.proxy.onChange?(textView.text)
            placeholderLabel.isHidden = !textView.text.isEmpty
            layoutPlaceholder(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // 保持代理指向最新光标位置
            parent.proxy.textView = textView
        }
    }
}
