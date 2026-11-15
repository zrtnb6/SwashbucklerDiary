import Foundation
import SQLite3

/// SQLite 允许的最长等待时间（秒），遇到锁竞争时自动重试。
private let busyTimeout: Int32 = 8

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue: Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
    static func date(_ value: Date) -> SQLValue { .text(DateCompat.encode(value)) }
    static func uuid(_ value: UUID) -> SQLValue { .text(value.uuidString.lowercased()) }
    static func optionalText(_ value: String?) -> SQLValue {
        guard let value else { return .null }
        return .text(value)
    }

    fileprivate func bind(to statement: OpaquePointer?, index: Int32) {
        switch self {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer(let value):
            sqlite3_bind_int64(statement, index, value)
        case .real(let value):
            sqlite3_bind_double(statement, index, value)
        case .text(let value):
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        case .blob(let data):
            if data.isEmpty {
                sqlite3_bind_zeroblob(statement, index, 0)
            } else {
                data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            }
        }
    }
}

struct Row {
    private let storage: [String: SQLValue]
    private let indexStorage: [Int: SQLValue]
    let columnNames: [String]

    init(columnNames: [String], values: [SQLValue]) {
        self.columnNames = columnNames
        var map: [String: SQLValue] = [:]
        var idx: [Int: SQLValue] = [:]
        for (i, name) in columnNames.enumerated() where i < values.count {
            // 列名大小写不敏感，兼容不同 ORM 的命名习惯。
            map[name.lowercased()] = values[i]
            idx[i] = values[i]
        }
        self.storage = map
        self.indexStorage = idx
    }

    subscript(_ column: String) -> SQLValue {
        storage[column.lowercased()] ?? .null
    }

    func string(_ column: String) -> String? {
        switch self[column] {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        default: return nil
        }
    }

    func int(_ column: String) -> Int? {
        switch self[column] {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        case .text(let value): return Int(value)
        default: return nil
        }
    }

    func bool(_ column: String) -> Bool {
        (int(column) ?? 0) != 0
    }

    func date(_ column: String) -> Date? {
        switch self[column] {
        case .text(let value): return DateCompat.decode(value)
        case .real(let value): return DateCompat.decode(number: value)
        case .integer(let value): return DateCompat.decode(number: Double(value))
        case .null: return nil
        case .blob(let data):
            guard data.count == 8 else { return nil }
            let bits = data.withUnsafeBytes { $0.load(as: UInt64.self) }
            return Date(timeIntervalSince1970: TimeInterval(bits) / 1000.0)
        }
    }

    func uuid(_ column: String) -> UUID? {
        switch self[column] {
        case .text(let value): return UUIDCompat.decode(value)
        case .blob(let data): return UUIDCompat.decode(blob: data)
        default: return nil
        }
    }
}

enum SQLiteError: LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .open(let message): return "数据库打开失败：\(message)"
        case .prepare(let message, let sql): return "SQL 解析失败：\(message) — \(sql)"
        case .step(let message, let sql): return "SQL 执行失败：\(message) — \(sql)"
        case .notFound: return "找不到数据"
        }
    }
}

/// 对 sqlite3 C API 的薄封装。
///
/// 刻意不引入任何第三方依赖：项目要求原生实现，且 SQLite 是系统库。
/// 所有访问都由一把递归锁串行化，避免多线程写入时踩到 sqlite 的连接级并发限制。
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0

    let url: URL

    var isOpen: Bool { handle != nil }

    init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.open(message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, busyTimeout * 1000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    private func errorMessage() -> String {
        guard let handle else { return "database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw SQLiteError.open("database is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage()
            if let errorPointer { sqlite3_free(errorPointer) }
            throw SQLiteError.step(message, sql: sql)
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.step(errorMessage(), sql: sql)
        }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        var columnNames: [String] = []
        let count = sqlite3_column_count(statement)
        for index in 0..<count {
            let name = sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "col\(index)"
            columnNames.append(name)
        }

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                var values: [SQLValue] = []
                values.reserveCapacity(Int(count))
                for index in 0..<count {
                    values.append(Self.readValue(statement: statement, index: index))
                }
                rows.append(Row(columnNames: columnNames, values: values))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.step(errorMessage(), sql: sql)
            }
        }
        return rows
    }

    func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        guard let row = try query(sql, params).first else { return 0 }
        return row.int(row.columnNames.first ?? "") ?? 0
    }

    private static func readValue(statement: OpaquePointer?, index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let cString = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: cString))
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, index))
            guard length > 0, let pointer = sqlite3_column_blob(statement, index) else {
                return .blob(Data())
            }
            return .blob(Data(bytes: pointer, count: length))
        default:
            return .null
        }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer? {
        guard let handle else { throw SQLiteError.open("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(errorMessage(), sql: sql)
        }
        for (offset, value) in params.enumerated() {
            value.bind(to: statement, index: Int32(offset + 1))
        }
        return statement
    }

    // MARK: - 事务

    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }

        try execute("BEGIN IMMEDIATE;")
        transactionDepth = 1
        do {
            let value = try body()
            transactionDepth = 0
            try execute("COMMIT;")
            return value
        } catch {
            transactionDepth = 0
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - 元信息

    func tableNames() -> [String] {
        (try? query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
            .compactMap { $0.string("name") }) ?? []
    }

    func columnNames(of table: String) -> [String] {
        (try? query("PRAGMA table_info(\(Self.quote(table)));").compactMap { $0.string("name") }) ?? []
    }

    func tableExists(_ table: String) -> Bool {
        tableNames().contains { $0.caseInsensitiveCompare(table) == .orderedSame }
    }

    static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
