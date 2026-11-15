import Foundation

/// 应用沙盒路径约定。
///
/// 目录布局刻意与原 .NET MAUI 版本保持一致，目的有两个：
/// 1. `SwashbucklerDiary.db3` 的表结构与文件名不变，备份 zip 可以双向互换；
/// 2. `Assets/Image|Audio|Video` 与 `appdata/Image/xxx.jpg` 这种正文内的资源 URI 不变，
///    老日记里的图片链接在新客户端里仍然能解析。
enum AppPaths {
    /// 与原项目 `AppFileSystem.AppDataVirtualDirectoryName` 对应的虚拟目录名前缀。
    static let appDataVirtualDirectoryName = "appdata"
    static let cacheVirtualDirectoryName = "cache"

    static let mainDatabaseFilename = "SwashbucklerDiary.db3"
    static let privacyDatabaseFilename = "SwashbucklerDiary.privacy.db3"
    static let logDatabaseFilename = "logs.db3"

    private static let fm = FileManager.default

    /// `~/Library/Application Support/<bundle id>/`
    static var appDataDirectory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "SwashbucklerDiary", isDirectory: true)
        ensure(dir)
        return dir
    }

    /// `~/Library/Caches/<bundle id>/`
    static var cacheDirectory: URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "SwashbucklerDiary", isDirectory: true)
        ensure(dir)
        return dir
    }

    static var assetsDirectory: URL {
        let dir = appDataDirectory.appendingPathComponent("Assets", isDirectory: true)
        ensure(dir)
        return dir
    }

    static func assetsDirectory(for kind: MediaKind) -> URL {
        let dir = assetsDirectory.appendingPathComponent(kind.directoryName, isDirectory: true)
        ensure(dir)
        return dir
    }

    static var avatarDirectory: URL {
        let dir = assetsDirectory.appendingPathComponent("Avatar", isDirectory: true)
        ensure(dir)
        return dir
    }

    static var mainDatabaseURL: URL {
        appDataDirectory.appendingPathComponent(mainDatabaseFilename)
    }

    static var privacyDatabaseURL: URL {
        appDataDirectory.appendingPathComponent(privacyDatabaseFilename)
    }

    static var logsDirectory: URL {
        let dir = appDataDirectory.appendingPathComponent("Logs", isDirectory: true)
        ensure(dir)
        return dir
    }

    /// 导出 / 备份的临时工作区，导入完成后立即清空。
    static func workingDirectory(_ name: String) -> URL {
        let dir = cacheDirectory.appendingPathComponent(name, isDirectory: true)
        ensure(dir)
        return dir
    }

    static func clear(_ url: URL) {
        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for item in contents {
            try? fm.removeItem(at: item)
        }
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// 把沙盒内的绝对路径转换为正文里使用的相对 URI，例如
    /// `.../Assets/Image/abc.jpg` → `appdata/Image/abc.jpg`
    static func relativeURI(for fileURL: URL) -> String {
        let path = fileURL.standardizedFileURL.path
        let assets = assetsDirectory.standardizedFileURL.path
        if path.hasPrefix(assets) {
            var tail = String(path.dropFirst(assets.count))
            if tail.hasPrefix("/") { tail.removeFirst() }
            return "appdata/\(tail)"
        }
        let cache = cacheDirectory.standardizedFileURL.path
        if path.hasPrefix(cache) {
            var tail = String(path.dropFirst(cache.count))
            if tail.hasPrefix("/") { tail.removeFirst() }
            return "cache/\(tail)"
        }
        return path
    }

    /// 相对 URI → 沙盒绝对路径。同时兼容 1.3.9 之前的 `appdata:///Image/x.jpg` 写法。
    static func fileURL(forURI uri: String) -> URL? {
        var text = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "appdata:///", with: "appdata/")
        text = text.replacingOccurrences(of: "appdata://", with: "appdata/")
        if text.hasPrefix("/") { text.removeFirst() }
        if text.hasPrefix("appdata/") {
            let tail = String(text.dropFirst("appdata/".count))
            return appDataDirectory.appendingPathComponent(tail)
        }
        if text.hasPrefix("cache/") {
            let tail = String(text.dropFirst("cache/".count))
            return cacheDirectory.appendingPathComponent(tail)
        }
        if text.hasPrefix("file://"), let url = URL(string: text) {
            return url
        }
        return nil
    }
}
