import SwiftUI

/// 隐私空间设置。
struct PrivacySettingsPage: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @StateObject private var privacy = PrivacyModeController.shared

    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var showChangeForm = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section {
                if privacy.hasPassword && !showChangeForm {
                    Button("修改隐私空间密码") {
                        showChangeForm = true
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text("移除密码并退出隐私空间")
                    }
                } else {
                    SecureField("新密码（至少 4 位）", text: $newPassword)
                    SecureField("再次输入", text: $confirmPassword)
                    Button(privacy.hasPassword ? "保存新密码" : "设置密码") {
                        savePassword()
                    }
                    .disabled(newPassword.count < 4 || newPassword != confirmPassword)
                }
            } header: {
                Text("入口密码")
            } footer: {
                Text("进入隐私空间需要输入这个密码。密码以 PBKDF2-SHA256 加盐哈希保存在本机，不会写入备份。")
            }

            Section {
                Toggle("在「我的」页隐藏隐私空间入口", isOn: Binding(
                    get: { settingsStore.settings.hidePrivacyModeEntrance },
                    set: { value in settingsStore.update { $0.hidePrivacyModeEntrance = value } }
                ))
            } footer: {
                Text("隐藏后入口仍然存在，只是不在列表里显示，避免别人随手点进去。")
            }

            Section {
                Toggle("允许把日记移到隐私空间", isOn: Binding(
                    get: { settingsStore.settings.setPrivacyDiary },
                    set: { value in settingsStore.update { $0.setPrivacyDiary = value } }
                ))
            }

            Section {
                LabeledContent("普通空间日记", value: "\(countOfMain())")
                LabeledContent("隐私空间日记", value: "\(countOfPrivacy())")
                Button {
                    privacy.exit()
                    showMessage("已退出隐私空间", isError: false)
                } label: {
                    Text("退出隐私空间").foregroundStyle(Theme.accent)
                }
            } header: {
                Text("数据")
            } footer: {
                Text("两个空间使用独立的数据库文件（SwashbucklerDiary.db3 / SwashbucklerDiary.privacy.db3），普通模式下的查询不会命中隐私库。")
            }

            if let message {
                Section {
                    Text(message).font(.footnote).foregroundStyle(messageIsError ? .red : .secondary)
                }
            }
        }
        .navigationTitle("隐私空间")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { showChangeForm = !privacy.hasPassword }
        .confirmationDialog("确定移除隐私空间密码？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("移除并退出", role: .destructive) {
                privacy.clearPassword()
                newPassword = ""
                confirmPassword = ""
                showMessage("已移除密码，隐私数据仍然保留在设备上", isError: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后任何人都可以进入隐私空间，请谨慎操作。")
        }
    }

    private func savePassword() {
        guard newPassword == confirmPassword, newPassword.count >= 4 else { return }
        privacy.setPassword(newPassword)
        newPassword = ""
        confirmPassword = ""
        showChangeForm = false
        showMessage("密码已更新", isError: false)
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    private func countOfMain() -> Int {
        guard let db = try? DiaryDatabase.shared.main() else { return 0 }
        return (try? DiaryRepository(db: db).count()) ?? 0
    }

    private func countOfPrivacy() -> Int {
        guard let db = try? DiaryDatabase.shared.privacy() else { return 0 }
        return (try? DiaryRepository(db: db).count()) ?? 0
    }
}

/// 应用锁设置。
struct AppLockSettingsPage: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @StateObject private var lockService = AppLockService.shared

    @State private var numberPassword = ""
    @State private var confirmNumber = ""
    @State private var message: String?
    @State private var messageIsError = false
    @State private var showPatternSetup = false
    @State private var confirmPatternStage = false
    @State private var firstPattern = ""
    @State private var patternError: String?

    private var hasNumber: Bool { !settingsStore.settings.appLockNumberPassword.isEmpty }
    private var hasPattern: Bool { !settingsStore.settings.appLockPatternPassword.isEmpty }

    var body: some View {
        Form {
            Section {
                if hasNumber {
                    HStack {
                        Label("数字密码", systemImage: "number")
                        Spacer()
                        Text("已设置").foregroundStyle(.secondary)
                    }
                    Button("修改数字密码") {
                        settingsStore.update {
                            $0.appLockNumberPassword = ""
                            $0.appLockNumberPasswordSalt = ""
                        }
                        message = "请输入并保存新密码"
                    }
                } else {
                    SecureField("设置数字密码（至少 4 位）", text: $numberPassword)
                        .keyboardType(.numberPad)
                    SecureField("再次输入", text: $confirmNumber)
                        .keyboardType(.numberPad)
                    Button("保存密码") {
                        guard numberPassword.count >= 4, numberPassword == confirmNumber else {
                            message = "两次输入不一致，或长度不足 4 位"
                            messageIsError = true
                            return
                        }
                        lockService.setPassword(numberPassword, kind: .number)
                        numberPassword = ""
                        confirmNumber = ""
                        message = "数字密码已保存"
                        messageIsError = false
                    }
                }
            } header: {
                Text("解锁密码")
            } footer: {
                Text("密码只在本机以加盐哈希形式保存，不会进入备份，也无法被还原成明文。")
            }

            Section {
                HStack {
                    Label("图案密码", systemImage: "square.grid.3x3")
                    Spacer()
                    Text(hasPattern ? "已设置" : "未设置").foregroundStyle(.secondary)
                }
                Button(hasPattern ? "修改图案密码" : "设置图案密码") {
                    firstPattern = ""
                    confirmPatternStage = false
                    patternError = nil
                    showPatternSetup = true
                }
                if hasPattern {
                    Button(role: .destructive) {
                        lockService.clearPassword(kind: .pattern)
                        message = "图案密码已移除"
                        messageIsError = false
                    } label: {
                        Text("移除图案密码")
                    }
                }
            } header: {
                Text("图案解锁")
            } footer: {
                Text("至少连接 4 个点。图案与数字密码可以同时存在，锁屏时任一方式都可以解锁。")
            }

            Section {
                Toggle("使用\(lockService.biometricName)解锁", isOn: Binding(
                    get: { settingsStore.settings.appLockBiometric },
                    set: { value in settingsStore.update { $0.appLockBiometric = value } }
                ))
                .disabled(!hasNumber)
                Toggle("离开应用后立即锁定", isOn: Binding(
                    get: { settingsStore.settings.lockAppWhenLeave },
                    set: { value in settingsStore.update { $0.lockAppWhenLeave = value } }
                ))
                .disabled(!hasNumber)
            } header: {
                Text("生物识别")
            } footer: {
                if !hasNumber {
                    Text("先设置数字密码，才能开启生物识别与自动锁定。")
                } else {
                    Text("开启后，切到后台再回来会要求重新解锁。")
                }
            }

            Section {
                Button {
                    lockService.lock()
                } label: {
                    Text("立即锁定").foregroundStyle(Theme.accent)
                }
                .disabled(!hasNumber)
            }

            if let message {
                Section {
                    Text(message).font(.footnote).foregroundStyle(messageIsError ? .red : .secondary)
                }
            }
        }
        .navigationTitle("应用锁")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPatternSetup) {
            patternSetupSheet
                .presentationDetents([.large])
        }
    }

    /// 图案密码设置：连续绘制两次，一致才保存。
    private var patternSetupSheet: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(confirmPatternStage ? "再次绘制以确认" : "绘制新图案")
                    .font(.headline)
                if let patternError {
                    Text(patternError).font(.footnote).foregroundStyle(.red)
                } else {
                    Text("至少连接 4 个点").font(.caption).foregroundStyle(.secondary)
                }
                PatternLockView { value in
                    if confirmPatternStage {
                        if value == firstPattern {
                            lockService.setPassword(value, kind: .pattern)
                            showPatternSetup = false
                            firstPattern = ""
                            confirmPatternStage = false
                            message = "图案密码已保存"
                            messageIsError = false
                            Haptics.success()
                        } else {
                            patternError = "两次绘制不一致，请重新设置"
                            confirmPatternStage = false
                            firstPattern = ""
                            Haptics.error()
                        }
                    } else {
                        firstPattern = value
                        confirmPatternStage = true
                        patternError = nil
                        Haptics.light()
                    }
                }
                .frame(width: 280, height: 280)
                .padding(.vertical, 8)
                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("图案密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showPatternSetup = false
                        confirmPatternStage = false
                        firstPattern = ""
                    }
                }
            }
        }
    }
}

/// 外观与阅读设置。
struct AppearanceSettingsPage: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @EnvironmentObject private var store: DiaryStore

    var body: some View {
        Form {
            Section("主题") {
                Picker("外观", selection: Binding(
                    get: { settingsStore.settings.theme },
                    set: { value in settingsStore.update { $0.theme = value } }
                )) {
                    Text("跟随系统").tag(0)
                    Text("浅色").tag(1)
                    Text("深色").tag(2)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("使用 Markdown 渲染", isOn: binding(\.markdown))
                Toggle("正文首行缩进", isOn: binding(\.firstLineIndent))
                Toggle("代码块显示行号", isOn: binding(\.codeLineNumber))
                Toggle("已完成待办显示删除线", isOn: binding(\.taskListLineThrough))
            } header: {
                Text("阅读")
            } footer: {
                Text("关闭 Markdown 渲染后，正文按原始文本显示，适合查看代码或不想被格式干扰的场景。")
            }

            Section {
                Toggle("卡片显示心情 / 天气图标", isOn: binding(\.diaryCardIcon))
                Toggle("卡片显示标签", isOn: binding(\.diaryCardTags))
                Toggle("卡片显示地点", isOn: binding(\.diaryCardLocation))
                Toggle("显示统计卡片", isOn: binding(\.statisticsCard))
                Toggle("显示欢迎语", isOn: binding(\.welcomeText))
            } header: {
                Text("列表")

            }

            Section {
                Picker("自动保存间隔", selection: Binding(
                    get: { settingsStore.settings.editAutoSave },
                    set: { value in settingsStore.update { $0.editAutoSave = value } }
                )) {
                    Text("关闭").tag(0)
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                    Text("10 秒").tag(10)
                    Text("30 秒").tag(30)
                }
                Toggle("新建日记时选择模板", isOn: binding(\.selectTemplateWhenCreate))
                Toggle("导入媒体时保留原始文件名", isOn: binding(\.originalFileName))
            } header: {
                Text("编辑器")
            } footer: {
                Text("关闭自动保存后，仍会在关闭编辑器、切到后台时保存。")
            }

            Section {
                Picker("每周第一天", selection: Binding(
                    get: { settingsStore.settings.firstDayOfWeek },
                    set: { value in settingsStore.update { $0.firstDayOfWeek = value } }
                )) {
                    Text("周日").tag(0)
                    Text("周一").tag(1)
                }
                Picker("默认排序", selection: Binding(
                    get: { store.sort },
                    set: { store.sort = $0; store.reload() }
                )) {
                    ForEach(DiarySort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } header: {
                Text("日历与排序")
            }
        }
        .navigationTitle("外观与阅读")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings[keyPath: keyPath] },
            set: { value in settingsStore.update { $0[keyPath: keyPath] = value } }
        )
    }
}
