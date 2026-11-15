import SwiftUI
import UniformTypeIdentifiers

/// 本地备份与恢复 / 导出。
struct BackupSettingsPage: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @EnvironmentObject private var store: DiaryStore

    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var includeResources = false
    @State private var pendingExportKind: BackupService.ExportKind = .markdown
    @State private var showExportConfirm = false
    @State private var importResult: BackupService.ImportResult?
    @State private var storageText = ""

    private let service = BackupService()

    var body: some View {
        Form {
            Section {
                Toggle("备份时包含媒体文件", isOn: $includeResources)
            } header: {
                Text("备份")
            } footer: {
                Text("不含媒体时体积很小，只包含日记正文、标签与设置；含媒体时会打包全部图片、音频、视频。")
            }

            Section {
                Button {
                    createBackup()
                } label: {
                    Label("生成备份文件", systemImage: "shippingbox")
                }
                .disabled(isWorking)

                Button {
                    showImporter = true
                } label: {
                    Label("从备份文件恢复", systemImage: "arrow.down.doc")
                }
                .disabled(isWorking)
            } footer: {
                Text("生成的备份是标准 zip，与官方 Android / Windows 版本完全兼容。恢复前会自动保存一份当前数据库副本，出错可以回到恢复前的状态。")
            }

            Section("导出为可读格式") {
                ForEach([BackupService.ExportKind.markdown, .json, .txt, .xlsx], id: \.rawValue) { kind in
                    Button {
                        pendingExportKind = kind
                        showExportConfirm = true
                    } label: {
                        HStack {
                            Label(exportTitle(kind), systemImage: exportIcon(kind))
                            Spacer()
                        }
                    }
                    .disabled(isWorking)
                }
            }

            Section("存储") {
                HStack {
                    Text("数据库与媒体")
                    Spacer()
                    Text(storageText).foregroundStyle(.secondary)
                }
            }

            if isWorking {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("处理中…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
            }
        }
        .navigationTitle("本地备份")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            includeResources = settingsStore.settings.webDAVCopyResources
            refreshStorage()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip, .data], allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .sheet(item: Binding(
            get: { exportURL.map { ExportPayload(url: $0) } },
            set: { if $0 == nil { exportURL = nil } }
        )) { payload in
            ShareSheet(items: [payload.url])
        }
        .confirmationDialog("导出全部日记？", isPresented: $showExportConfirm, titleVisibility: .visible) {
            Button("导出 \(store.diaries.count) 篇日记") { startExport() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("导出内容按日期命名，打包为 zip。附件会一并导出。")
        }
        .alert("恢复完成", isPresented: Binding(
            get: { importResult != nil },
            set: { if !$0 { importResult = nil } }
        )) {
            Button("好", role: .cancel) { importResult = nil }
        } message: {
            if let result = importResult {
                Text("""
                已恢复 \(result.diaryCount) 篇日记、\(result.resourceFileCount) 个媒体文件。
                \(result.warnings.isEmpty ? "" : "\n" + result.warnings.joined(separator: "\n"))
                """)
            }
        }
    }

    private func exportTitle(_ kind: BackupService.ExportKind) -> String {
        switch kind {
        case .markdown: return "Markdown（.md）"
        case .json: return "JSON（结构化）"
        case .txt: return "纯文本（.txt）"
        case .xlsx: return "表格（CSV，可用 Excel 打开）"
        }
    }

    private func exportIcon(_ kind: BackupService.ExportKind) -> String {
        switch kind {
        case .markdown: return "doc.plaintext"
        case .json: return "curlybraces"
        case .txt: return "text.alignleft"
        case .xlsx: return "tablecells"
        }
    }

    private func refreshStorage() {
        let usage = BackupService.storageUsage()
        storageText = ByteCountFormatter.string(fromByteCount: usage.database + usage.media, countStyle: .file)
    }

    private func createBackup() {
        isWorking = true
        statusMessage = nil
        Task {
            do {
                let url = try await service.exportBackup(includeResources: includeResources)
                await MainActor.run {
                    exportURL = url
                    isWorking = false
                    statusMessage = "备份已生成：\(url.lastPathComponent)"
                    statusIsError = false
                    refreshStorage()
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    statusMessage = "备份失败：\(error.localizedDescription)"
                    statusIsError = true
                }
            }
        }
    }

    private func startExport() {
        isWorking = true
        statusMessage = nil
        let diaries = store.diaries
        let kind = pendingExportKind
        Task {
            do {
                let url = try await service.export(diaries: diaries, kind: kind)
                await MainActor.run {
                    exportURL = url
                    isWorking = false
                    statusMessage = "已导出 \(diaries.count) 篇日记"
                    statusIsError = false
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    statusMessage = "导出失败：\(error.localizedDescription)"
                    statusIsError = true
                }
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isWorking = true
            statusMessage = nil
            Task {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                // 拷到沙盒内再解析，避免安全作用域在异步过程中失效
                let local = AppPaths.workingDirectory("ImportSource").appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: local)
                try? FileManager.default.copyItem(at: url, to: local)
                do {
                    let output = try await service.importBackup(from: local)
                    await MainActor.run {
                        isWorking = false
                        importResult = output
                        store.reload()
                        refreshStorage()
                    }
                } catch {
                    await MainActor.run {
                        isWorking = false
                        statusMessage = "恢复失败：\(error.localizedDescription)"
                        statusIsError = true
                    }
                }
            }
        case .failure(let error):
            statusMessage = "无法读取文件：\(error.localizedDescription)"
            statusIsError = true
        }
    }
}

struct ExportPayload: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 系统分享面板
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
