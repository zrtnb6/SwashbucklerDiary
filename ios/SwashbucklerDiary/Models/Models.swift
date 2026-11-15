import Foundation

// MARK: - 媒体类型

/// 与原项目 `MediaResource` 枚举顺序保持一致（写入数据库的是 Int）。
enum MediaKind: Int, Codable, CaseIterable, Hashable {
    case unknown = 0
    case image = 1
    case audio = 2
    case video = 3

    var directoryName: String {
        switch self {
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .unknown: return "Other"
        }
    }

    var displayName: String {
        switch self {
        case .image: return "图片"
        case .audio: return "音频"
        case .video: return "视频"
        case .unknown: return "文件"
        }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "video"
        case .unknown: return "doc"
        }
    }

    static func from(fileExtension ext: String) -> MediaKind {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg":
            return .image
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "caf", "aiff", "amr":
            return .audio
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp":
            return .video
        default:
            return .unknown
        }
    }
}

// MARK: - 日记

struct Diary: Identifiable, Hashable {
    var id: UUID = UUID()
    var createTime: Date = Date()
    var updateTime: Date = Date()
    var title: String?
    var content: String?
    var mood: String?
    var weather: String?
    var location: String?
    var top: Bool = false
    /// 1.3.9 之前用于标记私密日记，现已由独立数据库承担，仅为兼容旧备份保留。
    var privateLegacy: Bool = false
    var template: Bool = false
    var tags: [Tag] = []
    var resources: [MediaResource] = []

    /// 日记在列表/详情中展示的标题：优先显式标题，其次正文首行。
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        guard let content, !content.isEmpty else { return "无标题" }
        for rawLine in content.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                line = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("![") || line.hasPrefix("---") || line.hasPrefix("```") { continue }
            if !line.isEmpty { return String(line.prefix(80)) }
        }
        return "无标题"
    }

    /// 卡片摘要：交给 Markdown 解析器剥离语法，避免出现 `- [x]`、`**` 这类残留。
    var plainSummary: String {
        guard let content, !content.isEmpty else { return "" }
        let text = MarkdownParser.plainText(content)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(120))
    }

    var wordCount: Int {
        guard let content else { return 0 }
        let text = content.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return text.count
    }
}

// MARK: - 标签

struct Tag: Identifiable, Hashable {
    var id: UUID = UUID()
    var createTime: Date = Date()
    var updateTime: Date = Date()
    var name: String = ""

    /// 列表展示用，由仓储按需填充。
    var diaryCount: Int = 0
}

// MARK: - 资源

/// 原项目 `ResourceModel` 的主键是 `ResourceUri` 字符串而不是 Guid。
struct MediaResource: Identifiable, Hashable {
    var resourceUri: String
    var resourceType: MediaKind

    var id: String { resourceUri }

    var fileName: String {
        (resourceUri as NSString).lastPathComponent
    }

    var fileURL: URL? {
        AppPaths.fileURL(forURI: resourceUri)
    }

    var exists: Bool {
        guard let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
}

// MARK: - 关联表

struct DiaryTag: Hashable {
    var id: UUID = UUID()
    var createTime: Date = Date()
    var updateTime: Date = Date()
    var diaryId: UUID
    var tagId: UUID
}

struct DiaryResource: Hashable {
    var id: UUID = UUID()
    var createTime: Date = Date()
    var updateTime: Date = Date()
    var diaryId: UUID
    var resourceUri: String
}

// MARK: - 地点

struct DiaryLocation: Identifiable, Hashable {
    var id: UUID = UUID()
    var createTime: Date = Date()
    var updateTime: Date = Date()
    var name: String = ""
    var diaryCount: Int = 0
}

// MARK: - 成就（读取旧库时保留，UI 中用“统计”呈现）

enum AchievementKind: Int, CaseIterable {
    case diary = 0
    case word = 1
    case tag = 2
    case avatar = 3
    case nickName = 4
    case sign = 5
    case sourceCode = 6
    case log = 7
    case share = 8
    case export = 9
}

struct UserAchievement: Identifiable, Hashable {
    var id: UUID
    var achievementName: String?
    var completeRate: Int
    var isCompleted: Bool
    var completedTime: Date
}

struct UserState: Identifiable, Hashable {
    var id: UUID
    var type: AchievementKind
    var count: Int
}

// MARK: - 排序

enum DiarySort: String, CaseIterable, Identifiable {
    case timeDescending = "Time - Reverse order"
    case timeAscending = "Time - Positive order"
    case updateDescending = "Update Time - Reverse order"
    case updateAscending = "Update Time - Positive order"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeDescending: return "时间 · 倒序"
        case .timeAscending: return "时间 · 正序"
        case .updateDescending: return "编辑时间 · 倒序"
        case .updateAscending: return "编辑时间 · 正序"
        }
    }

    /// 原项目把排序选项以本地化 key 字符串存进 `Setting.DiarySort`，这里做一次容错映射，
    /// 保证从旧版本升级过来的用户不会丢失排序偏好。
    static func parse(_ raw: String?) -> DiarySort {
        guard let raw, !raw.isEmpty else { return .timeDescending }
        if let exact = DiarySort(rawValue: raw) { return exact }
        switch raw {
        case "Time - Reverse order", "时间-倒序", "时间 · 倒序": return .timeDescending
        case "Time - Positive order", "时间-正序", "时间 · 正序": return .timeAscending
        case "Update Time - Reverse order", "编辑时间-倒序": return .updateDescending
        case "Update Time - Positive order", "编辑时间-正序": return .updateAscending
        default: return .timeDescending
        }
    }
}
