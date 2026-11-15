import Foundation
import os

/// 统一日志。控制台走 os.Logger，同时写入 `logs.db3` 的同目录文本日志，便于用户在“设置 → 关于 → 导出日志”中回传。
enum Log {
    private static let subsystem = "com.yucore.swashbucklerdiary.native"

    private static let general = Logger(subsystem: subsystem, category: "app")
    private static let storage = Logger(subsystem: subsystem, category: "storage")
    private static let network = Logger(subsystem: subsystem, category: "network")

    enum Category: String {
        case app, storage, network

        var logger: Logger {
            switch self {
            case .app: return Log.general
            case .storage: return Log.storage
            case .network: return Log.network
            }
        }
    }

    static func debug(_ message: @autoclosure () -> String, _ category: Category = .app) {
        let text = message()
        category.logger.debug("\(text, privacy: .public)")
        LogFileStore.shared.append(level: "DEBUG", category: category.rawValue, message: text)
    }

    static func info(_ message: @autoclosure () -> String, _ category: Category = .app) {
        let text = message()
        category.logger.info("\(text, privacy: .public)")
        LogFileStore.shared.append(level: "INFO", category: category.rawValue, message: text)
    }

    static func warning(_ message: @autoclosure () -> String, _ category: Category = .app) {
        let text = message()
        category.logger.warning("\(text, privacy: .public)")
        LogFileStore.shared.append(level: "WARN", category: category.rawValue, message: text)
    }

    static func error(_ message: @autoclosure () -> String, _ category: Category = .app) {
        let text = message()
        category.logger.error("\(text, privacy: .public)")
        LogFileStore.shared.append(level: "ERROR", category: category.rawValue, message: text)
    }
}

/// 极简滚动文本日志。单文件上限 2 MB，超过后轮转一次。
final class LogFileStore {
    static let shared = LogFileStore()

    private let queue = DispatchQueue(label: "diary.log.file", qos: .utility)
    private let maxBytes = 2 * 1024 * 1024

    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private var directory: URL {
        AppPaths.logsDirectory
    }

    var currentLogURL: URL {
        directory.appendingPathComponent("app.log")
    }

    func append(level: String, category: String, message: String) {
        #if DEBUG
        // 开发期控制台已经足够，避免刷盘影响编辑体验。
        if level == "DEBUG" { return }
        #endif
        let line = "\(formatter.string(from: Date())) [\(level)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                let url = self.currentLogURL
                if !FileManager.default.fileExists(atPath: url.path) {
                    try data.write(to: url)
                    return
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > self.maxBytes {
                    let rotated = self.directory.appendingPathComponent("app.1.log")
                    try? FileManager.default.removeItem(at: rotated)
                    try? FileManager.default.moveItem(at: url, to: rotated)
                    try data.write(to: url)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
            } catch {
                // 日志失败不再向上抛出，避免递归。
            }
        }
    }
}
