import Foundation

/// 备份 / 导入导出服务。
///
/// 产出物结构与原项目 `DiaryFileManager` 完全一致：
/// ```
/// SwashbucklerDiaryBackup_<yyyyMMddHHmmss>_v<version>.zip
///   ├── SwashbucklerDiary.db3      （主库或隐私库，文件名保持固定）
///   ├── settings.json              （设置；敏感项按原逻辑排除）
///   ├── version.json               （{"Version":"...","FileSuffix":".db3","Platform":"...","DateTime":"..."}）
///   └── appdata/
///         ├── Image/…  Audio/…  Video/…
///         └── Avatar/…
/// ```
/// 这样官方 Android / Windows / Web 版本可以直接恢复我们产出的备份。
struct BackupService {
    struct ExportVersionInfo: Codable {
        var version: String
        var fileSuffix: String
        var platform: String
        var dateTime: Date

        enum CodingKeys: String, CodingKey {
            case version = "Version"
            case fileSuffix = "FileSuffix"
            case platform = "Platform"
            case dateTime = "DateTime"
        }
    }

    struct ImportResult {
        var diaryCount: Int
        var resourceFileCount: Int
        var warnings: [String]
        var restoredSettings: Bool
    }

    enum BackupError: LocalizedError {
        case databaseMissing
        case noDatabaseInArchive
        case rollbackFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseMissing: return "找不到本地数据库文件，无法备份"
            case .noDatabaseInArchive: return "备份包内没有 .db3 数据库文件，可能不是侠客日记的备份"
            case .rollbackFailed(let message): return "导入失败且回滚异常：\(message)"
            }
        }
    }

    static let backupPrefix = "SwashbucklerDiaryBackup"
    static let exportPrefix = "SwashbucklerDiaryExport"
    static let databaseFilename = AppPaths.mainDatabaseFilename
    static let settingsFilename = "settings.json"
    static let versionFilename = "version.json"

    /// 与原项目一致的敏感设置排除列表：这些不会被写进备份。
    static let excludedSettings: Set<String> = [
        "WebDavConfig", "PrivacyModeEntrancePassword", "PrivacyModeDark",
        "PrivacyModeFunctionSearchKey", "HidePrivacyModeEntrance", "SetPrivacyDiary",
        "AppLockNumberPassword", "AppLockPatternPassword", "AppLockBiometric",
        "LockAppWhenLeave", "PrivacyModeEntrancePasswordSalt",
        "AppLockNumberPasswordSalt", "AppLockPatternPasswordSalt",
    ]

    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    // MARK: - 命名

    func backupFileName(at date: Date = Date()) -> String {
        "\(Self.backupPrefix)_\(DateCompat.fileStamp(date))_v\(appVersion).zip"
    }

    func exportFileName(kind: ExportKind, at date: Date = Date()) -> String {
        let suffix = kind == .xlsx ? ".xlsx" : ".zip"
        return "\(Self.exportPrefix)\(kind.rawValue)_\(DateCompat.fileStamp(date))_v\(appVersion)\(suffix)"
    }

    // MARK: - 导出备份

    func exportBackup(includeResources: Bool) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try Self.buildBackup(includeResources: includeResources, appVersion: self.appVersion)
        }.value
    }

    private static func buildBackup(includeResources: Bool, appVersion: String) throws -> URL {
        let working = AppPaths.workingDirectory("Backup")
        AppPaths.clear(working)
        DiaryDatabase.shared.flush()

        let databaseURL = DiaryDatabase.shared.isPrivacyMode ? AppPaths.privacyDatabaseURL : AppPaths.mainDatabaseURL
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw BackupError.databaseMissing
        }
        let databaseCopy = working.appendingPathComponent(databaseFilename)
        try FileManager.default.copyItem(at: databaseURL, to: databaseCopy)

        var files: [(path: String, url: URL)] = [("SwashbucklerDiary.db3", databaseCopy)]

        if includeResources {
            for kind in [MediaKind.image, .audio, .video] {
                let directory = AppPaths.assetsDirectory(for: kind)
                for file in contents(of: directory) {
                    files.append(("appdata/\(kind.directoryName)/\(file.lastPathComponent)", file))
                }
            }
            for file in contents(of: AppPaths.avatarDirectory) {
                files.append(("appdata/Avatar/\(file.lastPathComponent)", file))
            }
        }

        let settingsURL = working.appendingPathComponent(Self.settingsFilename)
        try writeSettings(to: settingsURL)
        files.append((settingsFilename, settingsURL))

        let versionURL = working.appendingPathComponent(versionFilename)
        let info = ExportVersionInfo(version: appVersion, fileSuffix: ".db3", platform: "iOS", dateTime: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: versionURL)
        files.append((versionFilename, versionURL))

        let zipURL = AppPaths.cacheDirectory.appendingPathComponent(
            "\(backupPrefix)_\(DateCompat.fileStamp(Date()))_v\(appVersion).zip"
        )
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }

        let writer = try ZipWriter(url: zipURL)
        for file in files {
            try writer.addFile(at: file.url, entryPath: file.path)
        }
        try writer.finish()
        Log.info("备份已生成：\(zipURL.lastPathComponent)（\(files.count) 个文件）", .storage)
        return zipURL
    }

    static func writeSettings(to url: URL) throws {
        // 复用 AppSettings 的 PascalCase 编码，并剔除敏感字段。
        var settings = SettingsStore.shared.settings
        settings.webDavConfig = ""
        settings.privacyModeEntrancePassword = ""
        settings.privacyModeEntrancePasswordSalt = ""
        settings.appLockNumberPassword = ""
        settings.appLockNumberPasswordSalt = ""
        settings.appLockPatternPassword = ""
        settings.appLockPatternPasswordSalt = ""
        settings.privacyModeFunctionSearchKey = ""
        settings.hidePrivacyModeEntrance = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(settings).write(to: url)
    }

    // MARK: - 导入备份

    /// 从备份 zip 恢复全部数据。失败时保证原数据完好：先落一份安全副本，出错自动回滚。
    func importBackup(from zipURL: URL) async throws -> ImportResult {
        let working = AppPaths.workingDirectory("Import")
        AppPaths.clear(working)

        let reader = try ZipReader(url: zipURL)
        let extracted = try reader.extractAll(to: working)
        Log.info("备份解包完成，共 \(extracted.count) 个条目", .storage)

        guard let databaseEntry = reader.firstEntry(withExtension: "db3") else {
            throw BackupError.noDatabaseInArchive
        }
        let extractedDatabase = working.appendingPathComponent(databaseEntry.name)
        guard FileManager.default.fileExists(atPath: extractedDatabase.path) else {
            throw BackupError.noDatabaseInArchive
        }

        var warnings: [String] = []
        let version = try readVersion(from: working)
        if version == nil {
            warnings.append("备份来自较旧版本，已自动转换资源路径（appdata:/// → appdata/）")
        }

        // 1. 安全副本：导入失败要能回到导入前
        DiaryDatabase.shared.flush()
        let rollbackCopy = AppPaths.appDataDirectory
            .appendingPathComponent("Rollback-\(DateCompat.fileStamp(Date())).db3")
        let targetDatabase = DiaryDatabase.shared.isPrivacyMode ? AppPaths.privacyDatabaseURL : AppPaths.mainDatabaseURL
        if FileManager.default.fileExists(atPath: targetDatabase.path) {
            try? FileManager.default.copyItem(at: targetDatabase, to: rollbackCopy)
        }

        // 2. 校验新库可读，避免把坏文件覆盖到正式库
        let probe = try SQLiteDatabase(url: extractedDatabase, readOnly: true)
        let probeMap = TableMap(database: probe)
        let diaryCount = (try? probe.scalarInt("SELECT COUNT(*) FROM \(probeMap.quoted(Schema.Table.diary));")) ?? 0
        probe.close()

        // 3. 替换数据库文件（必须先断开连接，否则 WAL 会写回旧库）
        DiaryDatabase.shared.closeAll()
        do {
            if FileManager.default.fileExists(atPath: targetDatabase.path) {
                try FileManager.default.removeItem(at: targetDatabase)
            }
            try FileManager.default.copyItem(at: extractedDatabase, to: targetDatabase)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: targetDatabase.path + suffix)
                try? FileManager.default.removeItem(at: sidecar)
            }
        } catch {
            DiaryDatabase.shared.reopen()
            if FileManager.default.fileExists(atPath: rollbackCopy.path) {
                try? FileManager.default.copyItem(at: rollbackCopy, to: targetDatabase)
                DiaryDatabase.shared.reopen()
            }
            throw BackupError.rollbackFailed(error.localizedDescription)
        }
        DiaryDatabase.shared.reopen()

        // 4. 资源文件
        let resourceCount = restoreResources(from: working, legacy: version == nil, warnings: &warnings)

        // 5. 设置
        var restoredSettings = false
        let settingsURL = working.appendingPathComponent(Self.settingsFilename)
        if FileManager.default.fileExists(atPath: settingsURL.path),
           let data = try? Data(contentsOf: settingsURL) {
            restoredSettings = SettingsStore.shared.importJSON(data)
            if !restoredSettings {
                warnings.append("settings.json 无法解析，已保留当前设置")
            }
        }

        // 6. 旧格式资源 URI 修正
        if version == nil {
            try? migrateLegacyResourceUris()
        }

        AppPaths.clear(working)
        try? FileManager.default.removeItem(at: rollbackCopy)

        Log.info("备份导入完成：\(diaryCount) 条日记，\(resourceCount) 个资源文件", .storage)
        return ImportResult(
            diaryCount: diaryCount,
            resourceFileCount: resourceCount,
            warnings: warnings,
            restoredSettings: restoredSettings
        )
    }

    private func readVersion(from folder: URL) throws -> ExportVersionInfo? {
        let url = folder.appendingPathComponent(Self.versionFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let info = try? decoder.decode(ExportVersionInfo.self, from: data) {
            return info
        }
        // 部分版本 DateTime 不是标准 ISO，退化成宽松解析
        struct Lenient: Codable {
            var version: String?
            var fileSuffix: String?
            var platform: String?
            enum CodingKeys: String, CodingKey {
                case version = "Version", fileSuffix = "FileSuffix", platform = "Platform"
            }
        }
        guard let lenient = try? JSONDecoder().decode(Lenient.self, from: data) else { return nil }
        return ExportVersionInfo(version: lenient.version ?? "unknown",
                                 fileSuffix: lenient.fileSuffix ?? ".db3",
                                 platform: lenient.platform ?? "unknown",
                                 dateTime: Date())
    }

    @discardableResult
    private func restoreResources(from folder: URL, legacy: Bool, warnings: inout [String]) -> Int {
        let fm = FileManager.default
        var count = 0
        let appdataFolder = folder.appendingPathComponent(AppPaths.appDataVirtualDirectoryName)
        for kind in [MediaKind.image, .audio, .video] {
            let source = appdataFolder.appendingPathComponent(kind.directoryName)
            count += merge(source, into: AppPaths.assetsDirectory(for: kind))
        }
        count += merge(appdataFolder.appendingPathComponent("Avatar"), into: AppPaths.avatarDirectory)

        if legacy {
            // 1.3.9 之前的备份把图片平铺在 `Image/` 下
            let legacySource = folder.appendingPathComponent("Image")
            count += merge(legacySource, into: AppPaths.assetsDirectory(for: .image))
        }

        if count == 0 {
            warnings.append("备份中没有媒体文件，或备份时未勾选「包含媒体文件」")
        }
        return count
    }

    private func merge(_ source: URL, into destination: URL) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return 0 }
        AppPaths.ensure(destination)
        var count = 0
        let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey])
        while let item = enumerator?.nextObject() as? URL {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relative = item.path.replacingOccurrences(of: source.path + "/", with: "")
            let target = destination.appendingPathComponent(relative)
            if isDirectory {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                if (try? fm.copyItem(at: item, to: target)) != nil {
                    count += 1
                }
            }
        }
        return count
    }

    /// 把 `appdata:///Image/x.jpg` 统一改成 `appdata/Image/x.jpg`（原项目 1.3.9 的迁移动作）。
    func migrateLegacyResourceUris() throws {
        let db = try DiaryDatabase.shared.current
        let repository = DiaryRepository(db: db)
        let diaries = try repository.fetchAll()
        var changed = 0
        for var diary in diaries {
            guard let content = diary.content, content.contains("appdata:///") else { continue }
            diary.content = content.replacingOccurrences(of: "appdata:///", with: "appdata/")
            try repository.update(diary, touchUpdateTime: false)
            changed += 1
        }
        if changed > 0 {
            Log.info("已修正 \(changed) 条日记的旧资源路径", .storage)
        }
    }

    // MARK: - 其它导出格式

    enum ExportKind: String {
        case json = "Json"
        case markdown = "Markdown"
        case txt = "Txt"
        case xlsx = "Xlsx"
    }

    /// 导出为 JSON / Markdown / TXT 压缩包，结构与原项目一致（按日期命名的单文件 + 媒体目录）。
    func export(diaries: [Diary], kind: ExportKind) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try Self.buildExport(diaries: diaries, kind: kind, appVersion: self.appVersion)
        }.value
    }

    private static func buildExport(diaries: [Diary], kind: ExportKind, appVersion: String) throws -> URL {
        let working = AppPaths.workingDirectory("Export-\(kind.rawValue)")
        AppPaths.clear(working)
        var files: [(path: String, url: URL)] = []

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        var usedNames = Set<String>()

        for diary in diaries.sorted(by: { $0.createTime < $1.createTime }) {
            let baseName: String
            let extensionName: String
            switch kind {
            case .json:
                baseName = DateFormatter.yyyyMMdd.string(from: diary.createTime)
                extensionName = "json"
            case .markdown:
                baseName = DateCompat.fileStamp(diary.createTime)
                extensionName = "md"
            case .txt:
                baseName = DateCompat.fileStamp(diary.createTime)
                extensionName = "txt"
            case .xlsx:
                baseName = DateCompat.fileStamp(diary.createTime)
                extensionName = "csv"
            }
            var name = "\(baseName).\(extensionName)"
            var suffix = 2
            while usedNames.contains(name) {
                name = "\(baseName)(\(suffix)).\(extensionName)"
                suffix += 1
            }
            usedNames.insert(name)

            let url = working.appendingPathComponent(name)
            switch kind {
            case .json:
                try encoder.encode(ExportDiary(diary: diary)).write(to: url)
            case .markdown:
                var text = diary.content ?? ""
                if let title = diary.title, !title.isEmpty, !text.hasPrefix("#") {
                    text = "# \(title)\n\n" + text
                }
                try text.write(to: url, atomically: true, encoding: .utf8)
            case .txt:
                try MarkdownParser.plainText(diary.content ?? "").write(to: url, atomically: true, encoding: .utf8)
            case .xlsx:
                // 无第三方表格库时导出为 CSV，Excel / Numbers 可直接打开
                var lines = ["时间,天气,心情,地点,标签,标题,内容"]
                let tags = diary.tags.map(\.name).joined(separator: " ")
                let fields = [
                    diary.createTime.formatted(date: .numeric, time: .shortened),
                    diary.weather ?? "", diary.mood ?? "", diary.location ?? "",
                    tags, diary.title ?? "", diary.content ?? "",
                ]
                lines.append(fields.map(Self.csvEscape).joined(separator: ","))
                try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            files.append((name, url))

            for resource in diary.resources {
                guard let source = resource.fileURL, FileManager.default.fileExists(atPath: source.path) else { continue }
                let entry = resource.resourceUri
                let target = working.appendingPathComponent(entry)
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: source, to: target)
                files.append((entry, target))
            }
        }

        let versionURL = working.appendingPathComponent(versionFilename)
        let info = ExportVersionInfo(version: appVersion, fileSuffix: ".\(kind == .json ? "json" : "md")",
                                    platform: "iOS", dateTime: Date())
        try encoder.encode(info).write(to: versionURL)
        files.append((versionFilename, versionURL))

        let zipURL = AppPaths.cacheDirectory.appendingPathComponent(
            "\(exportPrefix)\(kind.rawValue)_\(DateCompat.fileStamp(Date()))_v\(appVersion).zip"
        )
        try? FileManager.default.removeItem(at: zipURL)
        let writer = try ZipWriter(url: zipURL)
        for file in files {
            try writer.addFile(at: file.url, entryPath: file.path)
        }
        try writer.finish()
        return zipURL
    }

    private static func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// JSON 导出结构与原项目保持一致（属性名为 PascalCase）。
    private struct ExportDiary: Codable {
        var id: UUID
        var createTime: Date
        var updateTime: Date
        var title: String?
        var content: String?
        var mood: String?
        var weather: String?
        var location: String?
        var top: Bool
        var isPrivate: Bool
        var template: Bool
        var tags: [ExportTag]?
        var resources: [ExportResource]?

        enum CodingKeys: String, CodingKey {
            case id = "Id", createTime = "CreateTime", updateTime = "UpdateTime"
            case title = "Title", content = "Content", mood = "Mood", weather = "Weather"
            case location = "Location", top = "Top", isPrivate = "Private", template = "Template"
            case tags = "Tags", resources = "Resources"
        }

        init(diary: Diary) {
            id = diary.id
            createTime = diary.createTime
            updateTime = diary.updateTime
            title = diary.title
            content = diary.content
            mood = diary.mood
            weather = diary.weather
            location = diary.location
            top = diary.top
            isPrivate = diary.privateLegacy
            template = diary.template
            tags = diary.tags.isEmpty ? nil : diary.tags.map(ExportTag.init)
            resources = diary.resources.isEmpty ? nil : diary.resources.map(ExportResource.init)
        }
    }

    private struct ExportTag: Codable {
        var id: UUID
        var name: String
        enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
        init(_ tag: Tag) { id = tag.id; name = tag.name }
    }

    private struct ExportResource: Codable {
        var resourceUri: String
        var resourceType: Int
        enum CodingKeys: String, CodingKey { case resourceUri = "ResourceUri", resourceType = "ResourceType" }
        init(_ resource: MediaResource) {
            resourceUri = resource.resourceUri
            resourceType = resource.resourceType.rawValue
        }
    }

    // MARK: - 辅助

    private static func contents(of directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var files: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory { files.append(item) }
        }
        return files
    }

    /// 存储占用情况，用于「关于」页面。
    static func storageUsage() -> (database: Int64, media: Int64) {
        let fm = FileManager.default
        let dbSize = [AppPaths.mainDatabaseURL, AppPaths.privacyDatabaseURL]
            .compactMap { try? fm.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }
            .reduce(Int64(0)) { $0 + $1.int64Value }

        var mediaSize: Int64 = 0
        if let enumerator = fm.enumerator(at: AppPaths.assetsDirectory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
            while let item = enumerator.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if values?.isDirectory == true { continue }
                mediaSize += Int64(values?.fileSize ?? 0)
            }
        }
        return (dbSize, mediaSize)
    }
}

extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
