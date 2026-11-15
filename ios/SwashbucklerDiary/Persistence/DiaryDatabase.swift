import Foundation

/// 数据库连接中枢。
///
/// 保留原项目的「主库 / 隐私库」双库设计：隐私模式下所有读写自动切到
/// `SwashbucklerDiary.privacy.db3`，普通模式只碰 `SwashbucklerDiary.db3`。
/// 这样即使出现逻辑漏洞，普通模式下的查询也永远命中不到私密数据。
final class DiaryDatabase {
    static let shared = DiaryDatabase()

    private let lock = NSRecursiveLock()
    private var mainDatabase: SQLiteDatabase?
    private var privacyDatabase: SQLiteDatabase?

    /// 当前是否处于隐私模式。切换时不需要重连，只需改这个标记。
    private(set) var isPrivacyMode = false

    private init() {}

    // MARK: - 连接

    func main() throws -> SQLiteDatabase {
        lock.lock()
        defer { lock.unlock() }
        if let mainDatabase { return mainDatabase }
        let db = try SQLiteDatabase(url: AppPaths.mainDatabaseURL)
        try SchemaMigrator.prepare(db)
        mainDatabase = db
        Log.info("主库就绪：\(AppPaths.mainDatabaseURL.path)", .storage)
        return db
    }

    func privacy() throws -> SQLiteDatabase {
        lock.lock()
        defer { lock.unlock() }
        if let privacyDatabase { return privacyDatabase }
        let db = try SQLiteDatabase(url: AppPaths.privacyDatabaseURL)
        try SchemaMigrator.prepare(db)
        privacyDatabase = db
        Log.info("隐私库就绪：\(AppPaths.privacyDatabaseURL.path)", .storage)
        return db
    }

    /// 业务层一律通过这里取连接，不要在别处判断隐私模式。
    var current: SQLiteDatabase {
        get throws {
            isPrivacyMode ? try privacy() : try main()
        }
    }

    func setPrivacyMode(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard isPrivacyMode != enabled else { return }
        isPrivacyMode = enabled
        Log.info("隐私模式切换为 \(enabled)", .storage)
    }

    /// 用户手动触发「立即同步到磁盘」，同时用于导入导出前后释放文件句柄。
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        for db in [mainDatabase, privacyDatabase].compactMap({ $0 }) {
            try? db.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    /// 关闭连接。导入数据库文件前必须调用，否则旧句柄会继续指向被替换的 inode。
    func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        mainDatabase?.close()
        privacyDatabase?.close()
        mainDatabase = nil
        privacyDatabase = nil
    }

    /// 重新打开，用于数据文件被替换之后。
    func reopen() {
        closeAll()
        _ = try? main()
        _ = try? privacy()
    }

    func resetForTesting() {
        closeAll()
        isPrivacyMode = false
    }
}
