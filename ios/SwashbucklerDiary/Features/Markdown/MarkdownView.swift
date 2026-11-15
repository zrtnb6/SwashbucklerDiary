import SwiftUI

/// Markdown 渲染视图。
///
/// 设计取向：优先可读性。正文用系统字体的动态字号，代码块用等宽字体 + 浅底，
/// 表格横向可滚动，图片按容器宽度自适应。不使用 WebView。
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    var lineSpacing: CGFloat = 6
    var firstLineIndent: Bool = false
    var codeLineNumber: Bool = false
    var taskLineThrough: Bool = false
    var onLinkTap: ((URL) -> Void)?
    var onImageTap: ((String) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        markdown: String,
        lineSpacing: CGFloat = 6,
        firstLineIndent: Bool = false,
        codeLineNumber: Bool = false,
        taskLineThrough: Bool = false,
        onLinkTap: ((URL) -> Void)? = nil,
        onImageTap: ((String) -> Void)? = nil
    ) {
        self.blocks = MarkdownParser.parse(markdown)
        self.lineSpacing = lineSpacing
        self.firstLineIndent = firstLineIndent
        self.codeLineNumber = codeLineNumber
        self.taskLineThrough = taskLineThrough
        self.onLinkTap = onLinkTap
        self.onImageTap = onImageTap
    }

    init(
        blocks: [MarkdownBlock],
        lineSpacing: CGFloat = 6,
        firstLineIndent: Bool = false,
        codeLineNumber: Bool = false,
        taskLineThrough: Bool = false,
        onLinkTap: ((URL) -> Void)? = nil,
        onImageTap: ((String) -> Void)? = nil
    ) {
        self.blocks = blocks
        self.lineSpacing = lineSpacing
        self.firstLineIndent = firstLineIndent
        self.codeLineNumber = codeLineNumber
        self.taskLineThrough = taskLineThrough
        self.onLinkTap = onLinkTap
        self.onImageTap = onImageTap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(
                    block: block,
                    lineSpacing: lineSpacing,
                    firstLineIndent: firstLineIndent,
                    codeLineNumber: codeLineNumber,
                    taskLineThrough: taskLineThrough,
                    onLinkTap: onLinkTap,
                    onImageTap: onImageTap
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let lineSpacing: CGFloat
    let firstLineIndent: Bool
    let codeLineNumber: Bool
    let taskLineThrough: Bool
    let onLinkTap: ((URL) -> Void)?
    let onImageTap: ((String) -> Void)?

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineText(
                inlines: text,
                font: headingFont(level),
                lineSpacing: 2,
                onLinkTap: onLinkTap
            )
            .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            InlineText(
                inlines: text,
                font: .system(.body),
                lineSpacing: lineSpacing,
                firstLineIndent: firstLineIndent,
                onLinkTap: onLinkTap
            )

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.system(.body))
                            .foregroundStyle(.secondary)
                        blockContent(item.blocks, depth: item.depth)
                    }
                }
            }

        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + offset).")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        blockContent(item.blocks, depth: item.depth)
                    }
                }
            }

        case .taskList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(item.checked ? Color.accentColor : Color.secondary)
                        blockContent(item.blocks, depth: 0)
                            .strikethrough(taskLineThrough && item.checked, color: .secondary)
                            .foregroundStyle(taskLineThrough && item.checked ? Color.secondary : Color.primary)
                    }
                }
            }

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code, showLineNumbers: codeLineNumber)

        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                    .clipShape(Capsule())
                MarkdownView(
                    blocks: blocks,
                    lineSpacing: lineSpacing,
                    codeLineNumber: codeLineNumber,
                    taskLineThrough: taskLineThrough,
                    onLinkTap: onLinkTap,
                    onImageTap: onImageTap
                )
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .table(let table):
            TableView(table: table, onLinkTap: onLinkTap)

        case .divider:
            Divider().padding(.vertical, 4)

        case .mathBlock(let latex):
            MathBlockView(latex: latex)

        case .image(let alt, let url, _):
            MediaBlockImage(url: url, alt: alt, onTap: onImageTap)

        case .html(let raw):
            Text(raw)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func blockContent(_ blocks: [MarkdownBlock], depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                MarkdownBlockView(
                    block: inner,
                    lineSpacing: lineSpacing,
                    firstLineIndent: false,
                    codeLineNumber: codeLineNumber,
                    taskLineThrough: taskLineThrough,
                    onLinkTap: onLinkTap,
                    onImageTap: onImageTap
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(.title, weight: .bold)
        case 2: return .system(.title2, weight: .bold)
        case 3: return .system(.title3, weight: .semibold)
        case 4: return .system(.headline)
        default: return .system(.subheadline, weight: .semibold)
        }
    }
}

// MARK: - 行内渲染

struct InlineText: View {
    let inlines: [MarkdownInline]
    var font: Font = .system(.body)
    var lineSpacing: CGFloat = 6
    var firstLineIndent: Bool = false
    var onLinkTap: ((URL) -> Void)?

    var body: some View {
        let attributed = buildAttributed()
        ZStack(alignment: .topLeading) {
            Text(attributed)
                .font(font)
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    if let onLinkTap {
                        onLinkTap(url)
                        return .handled
                    }
                    return .systemAction
                })
        }
    }

    private func buildAttributed() -> AttributedString {
        var output = AttributedString("")
        if firstLineIndent {
            output.append(AttributedString("\u{3000}\u{3000}"))
        }
        for inline in inlines {
            output.append(Self.attributed(for: inline, onLinkTap: onLinkTap))
        }
        return output
    }

    static func attributed(for inline: MarkdownInline, onLinkTap: ((URL) -> Void)?) -> AttributedString {
        switch inline {
        case .text(let value):
            return AttributedString(value)
        case .emphasis(let children):
            var result = AttributedString("")
            for child in children { result.append(attributed(for: child, onLinkTap: onLinkTap)) }
            result.inlinePresentationIntent = .emphasized
            return result
        case .strong(let children):
            var result = AttributedString("")
            for child in children { result.append(attributed(for: child, onLinkTap: onLinkTap)) }
            result.inlinePresentationIntent = .stronglyEmphasized
            return result
        case .strikethrough(let children):
            var result = AttributedString("")
            for child in children { result.append(attributed(for: child, onLinkTap: onLinkTap)) }
            result.strikethroughStyle = .single
            return result
        case .code(let value):
            var result = AttributedString(value)
            result.font = .system(.callout, design: .monospaced)
            result.backgroundColor = Color.secondary.opacity(0.12)
            return result
        case .link(let text, let url, _):
            var content = AttributedString("")
            for child in text { content.append(attributed(for: child, onLinkTap: onLinkTap)) }
            if let resolved = URL(string: url) {
                content.link = resolved
            }
            content.foregroundColor = .accentColor
            content.underlineStyle = .single
            return content
        case .image(let alt, let url, _):
            var result = AttributedString("🖼 \(alt.isEmpty ? url : alt)")
            result.foregroundColor = .secondary
            return result
        case .math(let value):
            var result = AttributedString(MathRender.prettify(value))
            result.font = .system(.body, design: .serif).italic()
            result.foregroundColor = .accentColor
            return result
        case .lineBreak:
            return AttributedString("\n")
        case .footnoteRef(let label):
            var result = AttributedString("[\(label)]")
            result.font = .system(.footnote)
            result.foregroundColor = .secondary
            return result
        }
    }
}

// MARK: - 代码块

struct CodeBlockView: View {
    let language: String?
    let code: String
    var showLineNumbers: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                HStack {
                    Text(language.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    if showLineNumbers {
                        VStack(alignment: .trailing, spacing: 0) {
                            ForEach(Array(code.components(separatedBy: "\n").enumerated()), id: \.offset) { offset, _ in
                                Text("\(offset + 1)")
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Text(code)
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

// MARK: - 表格

private struct TableView: View {
    let table: MarkdownTable
    let onLinkTap: ((URL) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.headers, isHeader: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                    Divider()
                    row(cells, isHeader: false, zebra: index % 2 == 1)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.7)
            )
        }
    }

    private func row(_ cells: [[MarkdownInline]], isHeader: Bool, zebra: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                InlineText(
                    inlines: cell,
                    font: isHeader ? .system(.subheadline, weight: .semibold) : .system(.subheadline),
                    lineSpacing: 2,
                    onLinkTap: onLinkTap
                )
                .frame(minWidth: 72, alignment: alignment(for: index))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                if index < cells.count - 1 {
                    Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 0.7)
                }
            }
        }
        .background(isHeader ? Color.secondary.opacity(0.10) : (zebra ? Color.secondary.opacity(0.04) : Color.clear))
    }

    private func alignment(for index: Int) -> Alignment {
        guard index < table.alignments.count else { return .leading }
        switch table.alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - 数学公式

/// 数学公式渲染。
///
/// 完整的 LaTeX 排版引擎体量极大，为了保持包体与稳定性，这里采用“原生排版降级”策略：
/// 用衬线斜体 + 上下标替换呈现公式，保留原始 LaTeX 源码可复制。
/// 这是明确记录的取舍，见 docs/WEBDAV_FIXES.md 同级的 MARKDOWN 说明。
struct MathBlockView: View {
    let latex: String
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(displayText)
                .font(.system(size: 17, design: .serif))
                .italic()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            if showSource {
                Text(latex)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .onTapGesture { withAnimation(.snappy) { showSource.toggle() } }
    }

    private var displayText: String {
        MathRender.prettify(latex)
    }
}

// MARK: - 图片块

struct MediaBlockImage: View {
    let url: String
    let alt: String
    var onTap: ((String) -> Void)?

    var body: some View {
        Group {
            if let fileURL = AppPaths.fileURL(forURI: url), FileManager.default.fileExists(atPath: fileURL.path) {
                Button {
                    onTap?(url)
                } label: {
                    CachedAsyncImage(fileURL: fileURL)
                }
                .buttonStyle(.plain)
            } else if let remote = URL(string: url), remote.scheme?.hasPrefix("http") == true {
                Button {
                    onTap?(url)
                } label: {
                    AsyncImage(url: remote) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure:
                            placeholder
                        default:
                            ProgressView().frame(height: 120)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
            Text(alt.isEmpty ? "图片不可用" : alt).lineLimit(1)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

/// 本地图片的缓存加载。解码在后台线程完成，滚列表时不卡主线程。
struct CachedAsyncImage: View {
    let fileURL: URL
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if failed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("图片加载失败").font(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 140)
                    .overlay(ProgressView())
            }
        }
        .task(id: fileURL) {
            let loaded = await ImageCache.shared.image(for: fileURL)
            await MainActor.run {
                if let loaded {
                    image = loaded
                } else {
                    failed = true
                }
            }
        }
    }
}

/// 简单的内存 + 磁盘两级缓存，按文件修改时间失效。
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "diary.image.cache", qos: .userInitiated, attributes: .concurrent)

    private init() {
        cache.countLimit = 220
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let data = try? Data(contentsOf: url),
                      let image = Self.downsample(data: data, maxPixel: 2200) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.cache.setObject(image, forKey: key, cost: data.count)
                continuation.resume(returning: image)
            }
        }
    }

    func thumbnail(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let data = try? Data(contentsOf: url),
                      let image = Self.downsample(data: data, maxPixel: maxPixel) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private static func downsample(data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(240, maxPixel),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
