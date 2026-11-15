import SwiftUI
import PhotosUI

/// 「我的」页：个人信息、统计、各类设置的入口。
struct MinePage: View {
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @StateObject private var privacy = PrivacyModeController.shared

    @State private var path = NavigationPath()
    @State private var showProfileEditor = false
    @State private var showPrivacyPrompt = false
    @State private var privacyPassword = ""
    @State private var privacyError: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                profileSection
                statisticsSection
                contentSection
                syncSection
                securitySection
                appearanceSection
                aboutSection
                Color.clear.frame(height: 30).listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: MineRoute.self) { route in
                switch route {
                case .templates:
                    TemplateListPage { id in path.append(MineRoute.detail(id)) }
                case .detail(let id):
                    DiaryDetailPage(diaryID: id) {}
                case .media:
                    MediaLibraryPage()
                case .backup:
                    BackupSettingsPage()
                case .webdav:
                    WebDAVSettingsPage()
                case .privacy:
                    PrivacySettingsPage()
                case .appLock:
                    AppLockSettingsPage()
                case .appearance:
                    AppearanceSettingsPage()
                case .about:
                    AboutPage()
                }
            }
            .sheet(isPresented: $showProfileEditor) {
                ProfileEditorSheet()
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showPrivacyPrompt) {
                privacyPrompt
                    .presentationDetents([.height(280)])
            }
        }
    }

    // MARK: 顶部信息

    private var profileSection: some View {
        Section {
            Button {
                showProfileEditor = true
            } label: {
                HStack(spacing: 14) {
                    avatar
                    VStack(alignment: .leading, spacing: 3) {
                        Text(settingsStore.settings.nickName.isEmpty ? "未设置昵称" : settingsStore.settings.nickName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(settingsStore.settings.sign.isEmpty ? "点击编辑个人资料" : settingsStore.settings.sign)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    private var avatar: some View {
        Group {
            if let url = AppPaths.fileURL(forURI: settingsStore.settings.avatar),
               FileManager.default.fileExists(atPath: url.path),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Theme.accentSoft)
                    Image(systemName: "person.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(Circle())
    }

    private var statisticsSection: some View {
        Section {
            let stats = store.statistics
            HStack(spacing: 0) {
                statItem("\(stats.diaryCount)", "日记")
                statItem("\(stats.wordCount)", "字数")
                statItem("\(stats.activeDays)", "记录天数")
                statItem("\(stats.streak)", "连续")
            }
            .padding(.vertical, 6)
            if let first = stats.firstDiaryDate {
                Text("从 \(DateText.dayTitle(first)) 开始，已经记录了 \(stats.activeDays) 天。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("统计")
        }
    }

    private func statItem(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.headline, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 分组

    private var contentSection: some View {
        Section {
            Button { path.append(MineRoute.templates) } label: {
                row(icon: "square.stack.3d.up", title: "模板", detail: "\(store.templates.count)")
            }
            Button { path.append(MineRoute.media) } label: {
                row(icon: "photo.on.rectangle", title: "媒体文件", detail: "\(store.statistics.mediaCount)")
            }
        } header: {
            Text("内容")
        }
    }

    private var syncSection: some View {
        Section {
            Button { path.append(MineRoute.backup) } label: {
                row(icon: "externaldrive", title: "本地备份与恢复")
            }
            Button { path.append(MineRoute.webdav) } label: {
                row(icon: "arrow.triangle.2.circlepath.icloud", title: "WebDAV 同步",
                    detail: WebDAVConfiguration.parse(settingsStore.settings.webDavConfig)?.isConfigured == true ? "已配置" : "未配置")
            }
        } header: {
            Text("备份与同步")
        } footer: {
            Text("备份文件格式与官方 Android / Windows 版本一致，可以互相恢复。")
        }
    }

    private var securitySection: some View {
        Section {
            Button {
                if privacy.isActive {
                    privacy.exit()
                    ToastCenter.shared.show("已退出隐私空间")
                } else if privacy.hasPassword {
                    showPrivacyPrompt = true
                } else {
                    path.append(MineRoute.privacy)
                }
            } label: {
                row(icon: "lock.shield", title: privacy.isActive ? "退出隐私空间" : "隐私空间",
                    detail: privacy.isActive ? "已进入" : (privacy.hasPassword ? "" : "未设置"))
            }
            Button { path.append(MineRoute.appLock) } label: {
                row(icon: "faceid", title: "应用锁",
                    detail: AppLockService.shared.hasPassword ? "已开启" : "未开启")
            }
        } header: {
            Text("隐私与安全")
        } footer: {
            Text("隐私空间使用独立的数据库文件，普通模式下不会读取到其中的内容。")
        }
    }

    private var appearanceSection: some View {
        Section {
            Button { path.append(MineRoute.appearance) } label: {
                row(icon: "circle.lefthalf.filled", title: "外观与阅读")
            }
        } header: {
            Text("个性化")
        }
    }

    private var aboutSection: some View {
        Section {
            Button { path.append(MineRoute.about) } label: {
                row(icon: "info.circle", title: "关于侠客日记", detail: "v\(Bundle.main.appVersion)")
            }
        }
    }

    private func row(icon: String, title: String, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accentSoft))
            Text(title).foregroundStyle(.primary)
            Spacer()
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var privacyPrompt: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("输入隐私空间密码")
                    .font(.headline)
                SecureField("密码", text: $privacyPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                if let privacyError {
                    Text(privacyError).font(.footnote).foregroundStyle(.red)
                }
                Button {
                    if privacy.enter(password: privacyPassword) {
                        privacyPassword = ""
                        privacyError = nil
                        showPrivacyPrompt = false
                        ToastCenter.shared.show("已进入隐私空间")
                    } else {
                        privacyError = "密码错误"
                    }
                } label: {
                    Text("进入").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                Spacer()
            }
            .padding(Theme.pagePadding)
            .navigationTitle("隐私空间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showPrivacyPrompt = false }
                }
            }
        }
    }
}

enum MineRoute: Hashable {
    case templates
    case detail(UUID)
    case media
    case backup
    case webdav
    case privacy
    case appLock
    case appearance
    case about
}

/// 个人资料编辑。
struct ProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settingsStore = SettingsStore.shared
    @State private var nickName = ""
    @State private var sign = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var avatarPreview: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Group {
                                if let avatarPreview {
                                    Image(uiImage: avatarPreview).resizable().scaledToFill()
                                } else if let url = AppPaths.fileURL(forURI: settingsStore.settings.avatar),
                                          let image = UIImage(contentsOfFile: url.path) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    ZStack {
                                        Circle().fill(Theme.accentSoft)
                                        Image(systemName: "person.fill").foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .frame(width: 82, height: 82)
                            .clipShape(Circle())
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                Section("昵称") {
                    TextField("怎么称呼你", text: $nickName)
                }
                Section("签名") {
                    TextField("写一句给自己的话", text: $sign, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("个人资料")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                nickName = settingsStore.settings.nickName
                sign = settingsStore.settings.sign
            }
            .onChange(of: photoItem) { _, item in
                Task { await loadAvatar(item) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        settingsStore.update {
                            $0.nickName = nickName.trimmingCharacters(in: .whitespacesAndNewlines)
                            $0.sign = sign
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    private func loadAvatar(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
        do {
            let resource = try MediaImporter.shared.importData(jpeg, fileExtension: "jpg", suggestedName: "avatar.jpg")
            // 头像单独放一份到 Avatar 目录并在设置里记录 URI
            if let source = resource.fileURL {
                let target = AppPaths.avatarDirectory.appendingPathComponent(source.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: source, to: target)
                let uri = AppPaths.relativeURI(for: target)
                await MainActor.run {
                    settingsStore.update { $0.avatar = uri }
                    avatarPreview = image
                }
            }
        } catch {
            await MainActor.run { ToastCenter.shared.show("头像保存失败", isError: true) }
        }
    }
}
