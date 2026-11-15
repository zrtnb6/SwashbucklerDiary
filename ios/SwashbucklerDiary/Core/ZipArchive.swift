import Foundation
import Compression

/// 原生 ZIP 读写。
///
/// 原项目的备份是 `.NET ZipFile.CreateFromDirectory` 产出的标准 zip，
/// 为了保持双向兼容（新客户端生成的备份能被 Android/Windows 恢复，反之亦然），
/// 这里手写 ZIP 容器：支持 store / deflate 两种方法，文件名使用 UTF-8 标志位，
/// 结构遵循 PKWARE APPNOTE，不做任何私有扩展。
enum ZipError: LocalizedError {
    case cannotCreate(String)
    case invalidArchive(String)
    case unsupportedMethod(UInt16)
    case inflateFailed
    case entryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreate(let path): return "无法创建压缩包：\(path)"
        case .invalidArchive(let reason): return "压缩包格式异常：\(reason)"
        case .unsupportedMethod(let method): return "不支持的压缩方法（\(method)），请使用标准 zip"
        case .inflateFailed: return "解压失败，压缩包可能已损坏"
        case .entryNotFound(let name): return "压缩包内找不到 \(name)"
        }
    }
}

// MARK: - CRC32

struct CRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                if value & 1 == 1 {
                    value = 0xEDB88320 ^ (value >> 1)
                } else {
                    value >>= 1
                }
            }
            table[index] = value
        }
        return table
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { buffer in
            guard let bytes = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<data.count {
                crc = table[Int((crc ^ UInt32(bytes[index])) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - 写入

final class ZipWriter {
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [CentralEntry] = []
    private let dosTime: (time: UInt16, date: UInt16)

    private struct CentralEntry {
        var name: Data
        var crc: UInt32
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var method: UInt16
        var localOffset: UInt32
    }

    init(url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw ZipError.cannotCreate(url.path)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw ZipError.cannotCreate(url.path)
        }
        self.handle = handle
        self.dosTime = ZipWriter.dosComponents(Date())
    }

    deinit {
        try? handle.close()
    }

    func addFile(entryPath: String, data: Data, compress: Bool = true) throws {
        let name = Self.normalize(entryPath)
        guard let nameData = name.data(using: .utf8) else {
            throw ZipError.invalidArchive("文件名无法编码为 UTF-8")
        }

        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var payload = data
        if compress, !data.isEmpty, let deflated = Self.deflate(data), deflated.count < data.count {
            method = 8
            payload = deflated
        }

        let localOffset = UInt32(offset)
        var header = Data()
        header.append(uint32: 0x04034b50)          // local file header signature
        header.append(uint16: 20)                   // version needed
        header.append(uint16: 0x0800)               // flag: UTF-8 文件名
        header.append(uint16: method)
        header.append(uint16: dosTime.time)
        header.append(uint16: dosTime.date)
        header.append(uint32: crc)
        header.append(uint32: UInt32(payload.count))
        header.append(uint32: UInt32(data.count))
        header.append(uint16: UInt16(nameData.count))
        header.append(uint16: 0)                    // extra length
        header.append(nameData)

        try write(header)
        try write(payload)

        entries.append(CentralEntry(
            name: nameData,
            crc: crc,
            compressedSize: UInt32(payload.count),
            uncompressedSize: UInt32(data.count),
            method: method,
            localOffset: localOffset
        ))
    }

    func addFile(at url: URL, entryPath: String) throws {
        let data = try Data(contentsOf: url)
        try addFile(entryPath: entryPath, data: data)
    }

    func addDirectoryIfNeeded(entryPath: String) throws {
        // 标准 zip 允许省略目录条目，这里显式写入以兼容部分只认目录项的 WebDAV 客户端。
        let name = Self.normalize(entryPath)
        guard name.hasSuffix("/") else { return }
        guard let nameData = name.data(using: .utf8) else { return }
        let crc: UInt32 = 0
        let localOffset = UInt32(offset)
        var header = Data()
        header.append(uint32: 0x04034b50)
        header.append(uint16: 20)
        header.append(uint16: 0x0800)
        header.append(uint16: 0)
        header.append(uint16: dosTime.time)
        header.append(uint16: dosTime.date)
        header.append(uint32: crc)
        header.append(uint32: 0)
        header.append(uint32: 0)
        header.append(uint16: UInt16(nameData.count))
        header.append(uint16: 0)
        header.append(nameData)
        try write(header)
        entries.append(CentralEntry(name: nameData, crc: crc, compressedSize: 0,
                                    uncompressedSize: 0, method: 0, localOffset: localOffset))
    }

    func finish() throws {
        let centralStart = UInt32(offset)
        for entry in entries {
            var header = Data()
            header.append(uint32: 0x02014b50)       // central directory signature
            header.append(uint16: 20)                // version made by
            header.append(uint16: 20)                // version needed
            header.append(uint16: 0x0800)
            header.append(uint16: entry.method)
            header.append(uint16: dosTime.time)
            header.append(uint16: dosTime.date)
            header.append(uint32: entry.crc)
            header.append(uint32: entry.compressedSize)
            header.append(uint32: entry.uncompressedSize)
            header.append(uint16: UInt16(entry.name.count))
            header.append(uint16: 0)                 // extra
            header.append(uint16: 0)                 // comment
            header.append(uint16: 0)                 // disk number
            header.append(uint16: 0)                 // internal attrs
            header.append(uint32: 0)                 // external attrs
            header.append(uint32: entry.localOffset)
            header.append(entry.name)
            try write(header)
        }
        let centralSize = UInt32(offset) - centralStart

        var end = Data()
        end.append(uint32: 0x06054b50)
        end.append(uint16: 0)
        end.append(uint16: 0)
        end.append(uint16: UInt16(entries.count))
        end.append(uint16: UInt16(entries.count))
        end.append(uint32: centralSize)
        end.append(uint32: centralStart)
        end.append(uint16: 0)
        try write(end)
        try handle.synchronize()
        try handle.close()
    }

    // MARK: 内部

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private static func normalize(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }

    private static func deflate(_ data: Data) -> Data? {
        let capacity = max(64, data.count + (data.count / 8) + 64)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationAddress = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceAddress = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(destinationAddress, capacity,
                                                 sourceAddress, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }

    static func dosComponents(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        // 全部用 Int 计算再转 UInt16。
        // 直接写混合类型的长表达式会让 Swift 的类型检查器爆炸（Release 下实测超时）。
        let yearValue = max(1980, parts.year ?? 1980)
        let monthValue = parts.month ?? 1
        let dayValue = parts.day ?? 1
        let hourValue = parts.hour ?? 0
        let minuteValue = parts.minute ?? 0
        let secondValue = (parts.second ?? 0) / 2

        let dateBits = ((yearValue - 1980) << 9) | (monthValue << 5) | dayValue
        let timeBits = (hourValue << 11) | (minuteValue << 5) | secondValue
        return (UInt16(truncatingIfNeeded: timeBits), UInt16(truncatingIfNeeded: dateBits))
    }
}

// MARK: - 读取

struct ZipEntry {
    let name: String
    let crc: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let method: UInt16
    let localHeaderOffset: Int

    var isDirectory: Bool { name.hasSuffix("/") }
}

final class ZipReader {
    private let data: Data
    private let centralDirectory: [(entry: ZipEntry, localHeaderOffset: Int)]
    let entries: [ZipEntry]

    init(url: URL) throws {
        self.data = try Data(contentsOf: url, options: .mappedIfSafe)
        let parsed = try ZipReader.parseCentralDirectory(data)
        self.centralDirectory = parsed.map { ($0, $0.localHeaderOffset) }
        self.entries = parsed
    }

    init(data: Data) throws {
        self.data = data
        let parsed = try ZipReader.parseCentralDirectory(data)
        self.centralDirectory = parsed.map { ($0, $0.localHeaderOffset) }
        self.entries = parsed
    }

    func contains(_ name: String) -> Bool {
        entries.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// 按扩展名找文件，用于定位 `*.db3`。
    func firstEntry(withExtension ext: String) -> ZipEntry? {
        entries.first { !$0.isDirectory && ($0.name as NSString).pathExtension.lowercased() == ext.lowercased() }
    }

    func read(_ entry: ZipEntry) throws -> Data {
        let nameSizeOffset = entry.localHeaderOffset + 26
        guard nameSizeOffset + 4 <= data.count else {
            throw ZipError.invalidArchive("本地文件头越界")
        }
        let nameLength = Int(readUInt16(data, nameSizeOffset))
        let extraLength = Int(readUInt16(data, nameSizeOffset + 2))
        let payloadStart = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard payloadStart + entry.compressedSize <= data.count else {
            throw ZipError.invalidArchive("数据段越界（\(entry.name)）")
        }
        let payload = data.subdata(in: payloadStart..<(payloadStart + entry.compressedSize))

        switch entry.method {
        case 0:
            return payload
        case 8:
            guard let inflated = Self.inflate(payload, expectedSize: entry.uncompressedSize) else {
                throw ZipError.inflateFailed
            }
            return inflated
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    func read(named name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ZipError.entryNotFound(name)
        }
        return try read(entry)
    }

    /// 解压全部内容到指定目录，返回解压出的相对路径列表。
    @discardableResult
    func extractAll(to directory: URL) throws -> [String] {
        var written: [String] = []
        let fm = FileManager.default
        for entry in entries {
            // 防目录穿越：拒绝绝对路径与 ..
            let safeName = entry.name.replacingOccurrences(of: "\\", with: "/")
            guard !safeName.hasPrefix("/"), !safeName.split(separator: "/").contains("..") else {
                throw ZipError.invalidArchive("非法路径：\(entry.name)")
            }
            let target = directory.appendingPathComponent(safeName)
            if entry.isDirectory {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = try read(entry)
            try payload.write(to: target, options: .atomic)
            written.append(safeName)
        }
        return written
    }

    // MARK: 解析

    private static func parseCentralDirectory(_ data: Data) throws -> [ZipEntry] {
        guard data.count > 22 else { throw ZipError.invalidArchive("文件过小") }

        // 从尾部向前找 EOCD（注释最长 65535 字节）
        let maxComment = 65535
        let searchStart = max(0, data.count - 22 - maxComment)
        var eocdOffset: Int?
        var cursor = data.count - 22
        while cursor >= searchStart {
            if readUInt32(data, cursor) == 0x06054b50 {
                eocdOffset = cursor
                break
            }
            cursor -= 1
        }
        guard let eocd = eocdOffset else {
            throw ZipError.invalidArchive("找不到中央目录结束标记")
        }

        let totalEntries = Int(readUInt16(data, eocd + 10))
        let centralOffset = Int(readUInt32(data, eocd + 16))

        var result: [ZipEntry] = []
        var pointer = centralOffset
        for _ in 0..<totalEntries {
            guard pointer + 46 <= data.count, readUInt32(data, pointer) == 0x02014b50 else {
                throw ZipError.invalidArchive("中央目录条目损坏")
            }
            let method = readUInt16(data, pointer + 10)
            let crc = readUInt32(data, pointer + 16)
            let compressedSize = Int(readUInt32(data, pointer + 20))
            let uncompressedSize = Int(readUInt32(data, pointer + 24))
            let nameLength = Int(readUInt16(data, pointer + 28))
            let extraLength = Int(readUInt16(data, pointer + 30))
            let commentLength = Int(readUInt16(data, pointer + 32))
            let localOffset = Int(readUInt32(data, pointer + 42))
            let nameStart = pointer + 46
            guard nameStart + nameLength <= data.count else {
                throw ZipError.invalidArchive("文件名越界")
            }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .macOSRoman)
                ?? "unknown"
            result.append(ZipEntry(
                name: name,
                crc: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                method: method,
                localHeaderOffset: localOffset
            ))
            pointer = nameStart + nameLength + extraLength + commentLength
        }
        guard !result.isEmpty else { throw ZipError.invalidArchive("压缩包为空") }
        return result
    }

    private static func inflate(_ payload: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationAddress = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return payload.withUnsafeBytes { source -> Int in
                guard let sourceAddress = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationAddress, expectedSize,
                                                 sourceAddress, payload.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { return nil }
        return output
    }
}

// MARK: - 字节工具

private func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    guard offset + 2 <= data.count else { return 0 }
    return data.withUnsafeBytes { buffer in
        let base = buffer.bindMemory(to: UInt8.self)
        return UInt16(base[offset]) | (UInt16(base[offset + 1]) << 8)
    }
}

private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return data.withUnsafeBytes { buffer in
        let base = buffer.bindMemory(to: UInt8.self)
        return UInt32(base[offset])
            | (UInt32(base[offset + 1]) << 8)
            | (UInt32(base[offset + 2]) << 16)
            | (UInt32(base[offset + 3]) << 24)
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
