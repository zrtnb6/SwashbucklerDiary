import SwiftUI

/// 关于页：版本、存储占用、开源信息、日志、危险操作。
struct AboutPage: View {
    @EnvironmentObject private var store: DiaryStore

    @State private var showLog = false
    @State private var showResetConfirm = false
    @State private var message: String?

    private var versionText: String {
        "\(Bundle.main.appVersion) (\(Bundle.main.buildNumber))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 74, height: 74)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.accentSoft))
                    Text("侠客日记").font(.title3.weight(.semibold))
                    Text("原生 iOS 重构版 · \(versionText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("日记数量", value: "\(store.statistics.diaryCount)")
                LabeledContent("累计字数", value: "\(store.statistics.wordCount)")
                LabeledContent("媒体文件", value: "\(store.statistics.mediaCount)")
                LabeledContent("占用空间", value: storageText)
            } header: {
                Text("数据")
            }

            Section {
                Button {
                    showLog = true
                } label: {
                    Label("运行日志", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("诊断")
            } footer: {
                Text("遇到问题时可以把日志发给开发者。日志只记录操作与错误，不包含日记正文。")
            }

            Section {
                Link(destination: URL(string: "https://github.com/Yu-Core/SwashbucklerDiary")!) {
                    Label("原项目 SwashbucklerDiary", systemImage: "link")
                }
                Link(destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!) {
                    Label("AGPL-3.0 许可证", systemImage: "doc.badge.gearshape")
                }
                LabeledContent("技术栈", value: "SwiftUI · Swift Concurrency · SQLite")
            } header: {
                Text("开源")
            } footer: {
                Text("本项目基于原作者的 SwashbucklerDiary 重构，遵循 AGPL-3.0。iOS 客户端为原生 Swift 实现，不再使用 Blazor WebView。")
            }

            if let message {
                Section {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLog) {
            LogViewerPage()
        }
    }

    private var storageText: String {
        let usage = BackupService.storageUsage()
        return ByteCountFormatter.string(fromByteCount: usage.database + usage.media, countStyle: .file)
    }
}

/// 日志查看器，可导出分享。
struct LogViewerPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content.isEmpty ? "暂无日志" : content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let url = logURL, FileManager.default.fileExists(atPath: url.path) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .task {
                guard let url = logURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                // 只显示最后 400 行
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                content = lines.suffix(400).joined(separator: "\n")
            }
        }
    }

    private var logURL: URL? {
        LogFileStore.shared.currentLogURL
    }
}
