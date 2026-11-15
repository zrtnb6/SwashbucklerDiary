import Foundation

/// 时间字段兼容层。
///
/// 原项目用 SqlSugar + Microsoft.Data.Sqlite，DateTime 落库是 TEXT。
/// 历史版本之间格式并不完全一致（是否带毫秒、是否带 T、是否带时区都出现过），
/// 这里统一按“宽松读取、严格写入”处理：
/// - 读取时依次尝试多种常见布局，再退化成 Unix 时间戳；
/// - 写入时固定 `yyyy-MM-dd HH:mm:ss.fff`，与 SqlSugar 的默认输出一致，
///   保证 .NET 端（Android / Windows / WebDAV 备份）仍能正确解析。
enum DateCompat {
    private static let writeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let readFormatters: [DateFormatter] = {
        let layouts = [
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss.S",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd",
            "MM/dd/yyyy HH:mm:ss",
        ]
        return layouts.map { layout in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = layout
            return f
        }
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func encode(_ date: Date) -> String {
        writeFormatter.string(from: date)
    }

    static func decode(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "0001-01-01 00:00:00" || text.hasPrefix("0001-01-01") {
            return Date(timeIntervalSince1970: -62135596800)
        }
        for formatter in readFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        if let date = isoFormatter.date(from: text) { return date }
        if let date = isoFormatterNoFraction.date(from: text) { return date }
        // 纯数字：可能是 Unix 秒或毫秒
        if let number = Double(text) { return decode(number: number) }
        return nil
    }

    /// SqlSugar 在部分版本里把 DateTime 存成 ticks（100ns 为单位）或毫秒数。
    static func decode(number: Double) -> Date? {
        guard number.isFinite, number != 0 else { return nil }
        if number > 1e17 {
            // .NET DateTime.Ticks（自 0001-01-01 起的 100 纳秒数）
            let secondsSinceDotNetEpoch = number / 10_000_000
            let dotNetEpochOffset: TimeInterval = 62_135_596_800
            return Date(timeIntervalSince1970: secondsSinceDotNetEpoch - dotNetEpochOffset)
        }
        if number > 1e11 {
            return Date(timeIntervalSince1970: number / 1000)
        }
        if number > 1e8 {
            return Date(timeIntervalSince1970: number)
        }
        return nil
    }

    /// 用于文件名的时间串，与原项目一致：yyyyMMddHHmmss
    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: date)
    }
}

/// Guid 字段兼容层：SqlSugar 写 TEXT（36 位带连字符，小写），少数路径可能写 BLOB。
enum UUIDCompat {
    static func decode(_ raw: String) -> UUID? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("{") && text.hasSuffix("}") {
            text.removeFirst()
            text.removeLast()
        }
        if let uuid = UUID(uuidString: text) { return uuid }
        // 去掉连字符的 32 位写法，按 8-4-4-4-12 重新分组
        if text.count == 32, text.allSatisfy({ $0.isHexDigit }) {
            let chars = Array(text)
            func slice(_ from: Int, _ to: Int) -> String { String(chars[from..<to]) }
            let formatted = [slice(0, 8), slice(8, 12), slice(12, 16), slice(16, 20), slice(20, 32)]
                .joined(separator: "-")
            return UUID(uuidString: formatted)
        }
        return nil
    }

    static func decode(blob: Data) -> UUID? {
        guard blob.count == 16 else { return nil }
        let bytes = [UInt8](blob)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return decode(hex)
    }
}
