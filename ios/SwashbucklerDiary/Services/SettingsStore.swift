import Foundation

/// 应用设置。
///
/// 属性名与原项目的 C# `Setting` 类逐一对应（通过 `CodingKeys` 映射成 PascalCase），
/// 因此 `settings.json` 里的字段可以被双方无损读写：从旧备份恢复时旧版本的偏好不会丢，
/// 新客户端写出的备份也能被 Android / Windows 端正常识别。
struct AppSettings: Codable, Equatable {
    var language: String = "zh-CN"
    var title: Bool = false
    var markdown: Bool = true
    var nickName: String = ""
    var sign: String = ""
    var avatar: String = ""
    var hidePrivacyModeEntrance: Bool = false
    var privacyModeEntrancePassword: String = ""
    var privacyModeFunctionSearchKey: String = ""
    var privacyModeDark: Bool = true
    var setPrivacyDiary: Bool = true
    var theme: Int = 0                     // 0 跟随系统 / 1 浅色 / 2 深色
    var firstSetLanguage: Bool = true
    var firstAgree: Bool = false
    var webDavConfig: String = ""
    var welcomeText: Bool = false
    var indexDate: Bool = false
    var diaryCardIcon: Bool = true
    var alertTimeout: Int = 2000
    var webDAVCopyResources: Bool = false
    var diaryCardTimeFormat: String = "MM/dd"
    var achievementsAlert: Bool = true
    var lanDeviceName: String = ""
    var lanScanPort: Int = 5299
    var lanTransmissionPort: Int = 52099
    var statisticsCard: Bool = true
    var editAutoSave: Int = 5              // 秒，0 表示关闭自动保存
    var diarySort: String = ""
    var tagSort: String = ""
    var locationSort: String = ""
    var updatePrompt: Bool = true
    var updatePromptIntervalDay: Int = 1
    var updateMethod: Int = 0
    var lastUpdatePromptTime: Date = Date(timeIntervalSince1970: -62135596800)
    var imageLazy: Bool = true
    var firstLineIndent: Bool = false
    var codeLineNumber: Bool = false
    var taskListLineThrough: Bool = false
    var diaryCardTags: Bool = false
    var diaryIconText: Bool = false
    var otherInfo: Bool = true
    var autoPlay: Bool = false
    var outline: Bool = false
    var rightOutline: Bool = true          // 原项目拼写为 RigthOutline，见 CodingKeys
    var diaryCardLocation: Bool = false
    var urlScheme: String = "swashbucklerdiary"
    var firstDayOfWeek: Int = 0
    var useTemplateMethod: Int = 0
    var selectTemplateWhenCreate: Bool = false
    var diaryTimeFormat: String = "yyyy/MM/dd dddd"
    var quickRecord: Bool = false
    var defaultTemplateId: String = ""
    var diaryCardMarkdown: Bool = false
    var diaryInsertTimeFormat: String = "yyyy/MM/dd HH:mm:ss"
    var appLockNumberPassword: String = ""
    var appLockBiometric: Bool = false
    var lockAppWhenLeave: Bool = false
    var appLockPatternPassword: String = ""
    var privacyModeEntrancePasswordSalt: String = ""
    var appLockNumberPasswordSalt: String = ""
    var appLockPatternPasswordSalt: String = ""
    var originalFileName: Bool = false
    var linkCard: Bool = true
    var diaryCardDefaultTitle: Bool = true

    enum CodingKeys: String, CodingKey {
        case language = "Language"
        case title = "Title"
        case markdown = "Markdown"
        case nickName = "NickName"
        case sign = "Sign"
        case avatar = "Avatar"
        case hidePrivacyModeEntrance = "HidePrivacyModeEntrance"
        case privacyModeEntrancePassword = "PrivacyModeEntrancePassword"
        case privacyModeFunctionSearchKey = "PrivacyModeFunctionSearchKey"
        case privacyModeDark = "PrivacyModeDark"
        case setPrivacyDiary = "SetPrivacyDiary"
        case theme = "Theme"
        case firstSetLanguage = "FirstSetLanguage"
        case firstAgree = "FirstAgree"
        case webDavConfig = "WebDavConfig"
        case welcomeText = "WelcomeText"
        case indexDate = "IndexDate"
        case diaryCardIcon = "DiaryCardIcon"
        case alertTimeout = "AlertTimeout"
        case webDAVCopyResources = "WebDAVCopyResources"
        case diaryCardTimeFormat = "DiaryCardTimeFormat"
        case achievementsAlert = "AchievementsAlert"
        case lanDeviceName = "LANDeviceName"
        case lanScanPort = "LANScanPort"
        case lanTransmissionPort = "LANTransmissionPort"
        case statisticsCard = "StatisticsCard"
        case editAutoSave = "EditAutoSave"
        case diarySort = "DiarySort"
        case tagSort = "TagSort"
        case locationSort = "LocationSort"
        case updatePrompt = "UpdatePrompt"
        case updatePromptIntervalDay = "UpdatePromptIntervalDay"
        case updateMethod = "UpdateMethod"
        case lastUpdatePromptTime = "LastUpdatePromptTime"
        case imageLazy = "ImageLazy"
        case firstLineIndent = "FirstLineIndent"
        case codeLineNumber = "CodeLineNumber"
        case taskListLineThrough = "TaskListLineThrough"
        case diaryCardTags = "DiaryCardTags"
        case diaryIconText = "DiaryIconText"
        case otherInfo = "OtherInfo"
        case autoPlay = "AutoPlay"
        case outline = "Outline"
        case rightOutline = "RigthOutline"
        case diaryCardLocation = "DiaryCardLocation"
        case urlScheme = "UrlScheme"
        case firstDayOfWeek = "FirstDayOfWeek"
        case useTemplateMethod = "UseTemplateMethod"
        case selectTemplateWhenCreate = "SelectTemplateWhenCreate"
        case diaryTimeFormat = "DiaryTimeFormat"
        case quickRecord = "QuickRecord"
        case defaultTemplateId = "DefaultTemplateId"
        case diaryCardMarkdown = "DiaryCardMarkdown"
        case diaryInsertTimeFormat = "DiaryInsertTimeFormat"
        case appLockNumberPassword = "AppLockNumberPassword"
        case appLockBiometric = "AppLockBiometric"
        case lockAppWhenLeave = "LockAppWhenLeave"
        case appLockPatternPassword = "AppLockPatternPassword"
        case privacyModeEntrancePasswordSalt = "PrivacyModeEntrancePasswordSalt"
        case appLockNumberPasswordSalt = "AppLockNumberPasswordSalt"
        case appLockPatternPasswordSalt = "AppLockPatternPasswordSalt"
        case originalFileName = "OriginalFileName"
        case linkCard = "LinkCard"
        case diaryCardDefaultTitle = "DiaryCardDefaultTitle"
    }

    init() {}

    /// 宽松解码：旧备份里缺字段时用默认值补齐，不让升级把用户挡在门外。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        func decode<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        language = decode(.language, defaults.language)
        title = decode(.title, defaults.title)
        markdown = decode(.markdown, defaults.markdown)
        nickName = decode(.nickName, defaults.nickName)
        sign = decode(.sign, defaults.sign)
        avatar = decode(.avatar, defaults.avatar)
        hidePrivacyModeEntrance = decode(.hidePrivacyModeEntrance, defaults.hidePrivacyModeEntrance)
        privacyModeEntrancePassword = decode(.privacyModeEntrancePassword, defaults.privacyModeEntrancePassword)
        privacyModeFunctionSearchKey = decode(.privacyModeFunctionSearchKey, defaults.privacyModeFunctionSearchKey)
        privacyModeDark = decode(.privacyModeDark, defaults.privacyModeDark)
        setPrivacyDiary = decode(.setPrivacyDiary, defaults.setPrivacyDiary)
        theme = decode(.theme, defaults.theme)
        firstSetLanguage = decode(.firstSetLanguage, defaults.firstSetLanguage)
        firstAgree = decode(.firstAgree, defaults.firstAgree)
        webDavConfig = decode(.webDavConfig, defaults.webDavConfig)
        welcomeText = decode(.welcomeText, defaults.welcomeText)
        indexDate = decode(.indexDate, defaults.indexDate)
        diaryCardIcon = decode(.diaryCardIcon, defaults.diaryCardIcon)
        alertTimeout = decode(.alertTimeout, defaults.alertTimeout)
        webDAVCopyResources = decode(.webDAVCopyResources, defaults.webDAVCopyResources)
        diaryCardTimeFormat = decode(.diaryCardTimeFormat, defaults.diaryCardTimeFormat)
        achievementsAlert = decode(.achievementsAlert, defaults.achievementsAlert)
        lanDeviceName = decode(.lanDeviceName, defaults.lanDeviceName)
        lanScanPort = decode(.lanScanPort, defaults.lanScanPort)
        lanTransmissionPort = decode(.lanTransmissionPort, defaults.lanTransmissionPort)
        statisticsCard = decode(.statisticsCard, defaults.statisticsCard)
        editAutoSave = decode(.editAutoSave, defaults.editAutoSave)
        diarySort = decode(.diarySort, defaults.diarySort)
        tagSort = decode(.tagSort, defaults.tagSort)
        locationSort = decode(.locationSort, defaults.locationSort)
        updatePrompt = decode(.updatePrompt, defaults.updatePrompt)
        updatePromptIntervalDay = decode(.updatePromptIntervalDay, defaults.updatePromptIntervalDay)
        updateMethod = decode(.updateMethod, defaults.updateMethod)
        lastUpdatePromptTime = decode(.lastUpdatePromptTime, defaults.lastUpdatePromptTime)
        imageLazy = decode(.imageLazy, defaults.imageLazy)
        firstLineIndent = decode(.firstLineIndent, defaults.firstLineIndent)
        codeLineNumber = decode(.codeLineNumber, defaults.codeLineNumber)
        taskListLineThrough = decode(.taskListLineThrough, defaults.taskListLineThrough)
        diaryCardTags = decode(.diaryCardTags, defaults.diaryCardTags)
        diaryIconText = decode(.diaryIconText, defaults.diaryIconText)
        otherInfo = decode(.otherInfo, defaults.otherInfo)
        autoPlay = decode(.autoPlay, defaults.autoPlay)
        outline = decode(.outline, defaults.outline)
        rightOutline = decode(.rightOutline, defaults.rightOutline)
        diaryCardLocation = decode(.diaryCardLocation, defaults.diaryCardLocation)
        urlScheme = decode(.urlScheme, defaults.urlScheme)
        firstDayOfWeek = decode(.firstDayOfWeek, defaults.firstDayOfWeek)
        useTemplateMethod = decode(.useTemplateMethod, defaults.useTemplateMethod)
        selectTemplateWhenCreate = decode(.selectTemplateWhenCreate, defaults.selectTemplateWhenCreate)
        diaryTimeFormat = decode(.diaryTimeFormat, defaults.diaryTimeFormat)
        quickRecord = decode(.quickRecord, defaults.quickRecord)
        defaultTemplateId = decode(.defaultTemplateId, defaults.defaultTemplateId)
        diaryCardMarkdown = decode(.diaryCardMarkdown, defaults.diaryCardMarkdown)
        diaryInsertTimeFormat = decode(.diaryInsertTimeFormat, defaults.diaryInsertTimeFormat)
        appLockNumberPassword = decode(.appLockNumberPassword, defaults.appLockNumberPassword)
        appLockBiometric = decode(.appLockBiometric, defaults.appLockBiometric)
        lockAppWhenLeave = decode(.lockAppWhenLeave, defaults.lockAppWhenLeave)
        appLockPatternPassword = decode(.appLockPatternPassword, defaults.appLockPatternPassword)
        privacyModeEntrancePasswordSalt = decode(.privacyModeEntrancePasswordSalt, defaults.privacyModeEntrancePasswordSalt)
        appLockNumberPasswordSalt = decode(.appLockNumberPasswordSalt, defaults.appLockNumberPasswordSalt)
        appLockPatternPasswordSalt = decode(.appLockPatternPasswordSalt, defaults.appLockPatternPasswordSalt)
        originalFileName = decode(.originalFileName, defaults.originalFileName)
        linkCard = decode(.linkCard, defaults.linkCard)
        diaryCardDefaultTitle = decode(.diaryCardDefaultTitle, defaults.diaryCardDefaultTitle)
    }
}

/// 设置读写。真正落盘的是 UserDefaults 里的一份 JSON，方便整体导入导出。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private static let storageKey = "settings.json.v1"
    private let defaults = UserDefaults.standard

    @Published private(set) var settings: AppSettings

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
        persist()
    }

    func replace(with newValue: AppSettings) {
        settings = newValue
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// 供备份使用：原项目会把设置序列化成 `settings.json` 放进 zip。
    func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try? encoder.encode(settings)
    }

    func importJSON(_ data: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else { return false }
        replace(with: decoded)
        return true
    }
}
