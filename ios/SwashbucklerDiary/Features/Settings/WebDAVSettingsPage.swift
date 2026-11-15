import SwiftUI

/// WebDAV 配置与备份同步。
///
/// 这一页承载了原项目 WebDAV 上传问题的主要修复：
/// 目录不存在自动递归创建、地址末尾斜杠规范化、预认证、后台大文件上传、
/// 上传后尺寸校验、明确的错误文案。
struct WebDAVSettingsPage: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @EnvironmentObject private var store: DiaryStore

    @State private var serverAddress = ""
    @State private var account = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var includeResources = false

    @State private var client: WebDAVClient?
    @State private var isBusy = false
    @State private var busyText = ""
    @State private var progress: Double = 0
    @State private var message: String?
    @State private var messageIsError = false

    @State private var remoteFiles: [WebDAVFileInfo] = []
    @State private var isLoadingList = false
    @State private var pendingRestore: WebDAVFileInfo?
    @State private var pendingDelete: WebDAVFileInfo?

    private let backupService = BackupService()

    var body: some View {
        Form {
            Section {
                TextField("https://example.com/dav/", text: $serverAddress)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("账号", text: $account)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    if showPassword {
                        TextField("密码 / 应用密码", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("密码 / 应用密码", text: $password)
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    testConnection()
                } label: {
                    HStack {
                        Label("测试连接并保存", systemImage: "network")
                        Spacer()
                        if isBusy && busyText.contains("连接") { ProgressView() }
                    }
                }
                .disabled(isBusy || serverAddress.isEmpty || account.isEmpty || password.isEmpty)
            } header: {
                Text("服务器")
            } footer: {
                Text("地址需要包含 WebDAV 根路径（例如坚果云为 https://dav.jianguoyun.com/dav/）。建议使用服务商提供的「应用密码」，而不是登录密码。")
            }

            if let message {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(messageIsError ? .red : .secondary)
                        if messageIsError {
                            Text("常见原因：地址缺少路径、账号需要应用密码、服务器要求 HTTPS、或该账号没有写入权限。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section {
                Toggle("上传时包含媒体文件", isOn: $includeResources)

                Button {
                    uploadBackup()
                } label: {
                    Label("立即上传备份", systemImage: "arrow.up.to.line")
                }
                .disabled(isBusy || client == nil)

                if isBusy && progress > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                        Text("\(busyText) \(Int(progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("上传")
            } footer: {
                Text("远程目录固定为 SwashbucklerDiary/，文件名沿用官方格式 SwashbucklerDiaryBackup_时间_v版本.zip，因此桌面端与 Android 端都能识别。")
            }

            Section {
                if isLoadingList {
                    HStack { ProgressView(); Text("读取远程列表…").font(.footnote).foregroundStyle(.secondary) }
                } else if remoteFiles.isEmpty {
                    Button {
                        loadRemoteList()
                    } label: {
                        Label("读取远程备份列表", systemImage: "arrow.clockwise")
                    }
                    .disabled(isBusy || client == nil)
                } else {
                    ForEach(remoteFiles) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text(file.readableSize)
                                if let date = file.lastModified {
                                    Text(DateText.full(date))
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Button("恢复到此设备") { pendingRestore = file }
                                    .font(.caption.weight(.medium))
                                    .tint(Theme.accent)
                                Button("删除") { pendingDelete = file }
                                    .font(.caption)
                                    .tint(.red)
                                Spacer()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button {
                        loadRemoteList()
                    } label: {
                        Label("刷新列表", systemImage: "arrow.clockwise")
                    }
                    .disabled(isBusy)
                }
            } header: {
                Text("远程备份")
            }
        }
        .navigationTitle("WebDAV")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadConfiguration)
        .onChange(of: includeResources) { _, value in
            settingsStore.update { $0.webDAVCopyResources = value }
        }
        .confirmationDialog(
            "从此备份恢复？",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("恢复", role: .destructive) {
                if let file = pendingRestore { restore(file) }
                pendingRestore = nil
            }
            Button("取消", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("当前设备上的日记会被这份备份替换。恢复前会自动保存一份当前数据副本。")
        }
        .confirmationDialog(
            "删除远程备份？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let file = pendingDelete { deleteRemote(file) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只会删除服务器上的这一份 zip，不影响本地数据。")
        }
    }

    // MARK: - 操作

    private func loadConfiguration() {
        includeResources = settingsStore.settings.webDAVCopyResources
        guard let config = WebDAVConfiguration.parse(settingsStore.settings.webDavConfig) else { return }
        serverAddress = config.serverAddress
        account = config.account
        password = config.password
        if config.isConfigured {
            prepareClient(silently: true)
        }
    }

    private func prepareClient(silently: Bool = false) -> Bool {
        do {
            let config = WebDAVConfiguration(serverAddress: serverAddress, account: account, password: password)
            let newClient = try WebDAVClient(configuration: config)
            newClient.progressHandler = { value in
                self.progress = value
            }
            client = newClient
            return true
        } catch {
            if !silently {
                message = error.localizedDescription
                messageIsError = true
            }
            return false
        }
    }

    private func testConnection() {
        guard prepareClient() else { return }
        isBusy = true
        busyText = "连接中"
        message = nil
        Task {
            do {
                try await client?.connect()
                let config = WebDAVConfiguration(serverAddress: serverAddress, account: account, password: password)
                await MainActor.run {
                    settingsStore.update { $0.webDavConfig = config.jsonString }
                    isBusy = false
                    message = "连接成功，远程目录已就绪"
                    messageIsError = false
                }
                await reloadList()
            } catch {
                await MainActor.run {
                    isBusy = false
                    message = describe(error)
                    messageIsError = true
                }
            }
        }
    }

    private func uploadBackup() {
        guard let client else { return }
        isBusy = true
        busyText = "上传中"
        progress = 0
        message = nil
        Task {
            do {
                let url = try await backupService.exportBackup(includeResources: includeResources)
                await MainActor.run { busyText = "上传中" }
                let fileName = backupService.backupFileName()
                try await client.upload(fileURL: url, fileName: fileName)
                await MainActor.run {
                    isBusy = false
                    progress = 0
                    message = "上传成功：\(fileName)"
                    messageIsError = false
                }
                try? FileManager.default.removeItem(at: url)
                await reloadList()
            } catch {
                await MainActor.run {
                    isBusy = false
                    progress = 0
                    message = describe(error)
                    messageIsError = true
                }
            }
        }
    }

    private func loadRemoteList() {
        guard let client else { return }
        isLoadingList = true
        message = nil
        Task {
            do {
                let files = try await client.listBackups()
                await MainActor.run {
                    remoteFiles = files
                    isLoadingList = false
                }
            } catch {
                await MainActor.run {
                    isLoadingList = false
                    message = describe(error)
                    messageIsError = true
                }
            }
        }
    }

    private func reloadList() async {
        await MainActor.run { isLoadingList = true }
        do {
            let files = try await client?.listBackups() ?? []
            await MainActor.run {
                remoteFiles = files
                isLoadingList = false
            }
        } catch {
            await MainActor.run {
                isLoadingList = false
                message = describe(error)
                messageIsError = true
            }
        }
    }

    private func restore(_ file: WebDAVFileInfo) {
        guard let client else { return }
        isBusy = true
        busyText = "下载中"
        progress = 0
        message = nil
        Task {
            do {
                let localURL = try await client.download(name: file.name)
                await MainActor.run { busyText = "恢复中" }
                let result = try await backupService.importBackup(from: localURL)
                try? FileManager.default.removeItem(at: localURL)
                await MainActor.run {
                    isBusy = false
                    progress = 0
                    message = "已恢复 \(result.diaryCount) 篇日记、\(result.resourceFileCount) 个媒体文件" +
                        (result.warnings.isEmpty ? "" : "（\(result.warnings.joined(separator: "；"))）")
                    messageIsError = false
                    store.reload()
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    progress = 0
                    message = describe(error)
                    messageIsError = true
                }
            }
        }
    }

    private func deleteRemote(_ file: WebDAVFileInfo) {
        guard let client else { return }
        isBusy = true
        busyText = "删除中"
        Task {
            do {
                try await client.delete(name: file.name)
                await MainActor.run {
                    remoteFiles.removeAll { $0.href == file.href }
                    isBusy = false
                    message = "已删除 \(file.name)"
                    messageIsError = false
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    message = describe(error)
                    messageIsError = true
                }
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if let webdav = error as? WebDAVError {
            return webdav.errorDescription ?? "操作失败"
        }
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorTimedOut: return "连接超时，请检查网络或服务器地址"
        case NSURLErrorCannotFindHost: return "找不到服务器，请检查地址拼写"
        case NSURLErrorCannotConnectToHost: return "无法连接到服务器端口"
        case NSURLErrorSecureConnectionFailed: return "HTTPS 证书校验失败"
        case NSURLErrorNotConnectedToInternet: return "设备当前没有网络"
        default:
            return error.localizedDescription
        }
    }
}
