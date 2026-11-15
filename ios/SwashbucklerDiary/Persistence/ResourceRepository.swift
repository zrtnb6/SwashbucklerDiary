import Foundation

struct ResourceRepository {
    let db: SQLiteDatabase
    let map: TableMap

    init(db: SQLiteDatabase, map: TableMap? = nil) {
        self.db = db
        self.map = map ?? TableMap(database: db)
    }

    func typeIndex() throws -> [String: MediaKind] {
        let rows = try db.query("SELECT \"ResourceUri\",\"ResourceType\" FROM \(map.quoted(Schema.Table.resource));")
        var index: [String: MediaKind] = [:]
        for row in rows {
            guard let uri = row.string("ResourceUri") else { continue }
            let raw = row.int("ResourceType") ?? 0
            index[uri] = MediaKind(rawValue: raw) ?? .unknown
        }
        return index
    }

    func fetchAll() throws -> [MediaResource] {
        let types = try typeIndex()
        let rows = try db.query("""
        SELECT r."ResourceUri" AS uri, COUNT(dr."DiaryId") AS refs
        FROM \(map.quoted(Schema.Table.resource)) r
        LEFT JOIN \(map.quoted(Schema.Table.diaryResource)) dr ON dr."ResourceUri" = r."ResourceUri"
        GROUP BY r."ResourceUri";
        """)
        return rows.compactMap { row -> MediaResource? in
            guard let uri = row.string("uri") else { return nil }
            let kind = types[uri] ?? MediaKind.from(fileExtension: (uri as NSString).pathExtension)
            return MediaResource(resourceUri: uri, resourceType: kind)
        }
    }

    func fetchAll(of kind: MediaKind) throws -> [MediaResource] {
        try fetchAll().filter { $0.resourceType == kind }
    }

    func ensureRegistered(uri: String, type: MediaKind) throws {
        try db.run("INSERT OR IGNORE INTO \(map.quoted(Schema.Table.resource)) (\"ResourceUri\",\"ResourceType\") VALUES (?,?);",
                   [.text(uri), .integer(Int64(type.rawValue))])
    }

    func referenceCount(uri: String) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM \(map.quoted(Schema.Table.diaryResource)) WHERE \"ResourceUri\" = ?;", [.text(uri)])
    }

    /// 删除资源记录（连同关联行）。文件是否删除由调用方决定，避免误删还在被引用的文件。
    func delete(uri: String) throws {
        try db.run("DELETE FROM \(map.quoted(Schema.Table.diaryResource)) WHERE \"ResourceUri\" = ?;", [.text(uri)])
        try db.run("DELETE FROM \(map.quoted(Schema.Table.resource)) WHERE \"ResourceUri\" = ?;", [.text(uri)])
    }

    /// 找出没有任何日记引用的资源记录，供「清理未被引用的文件」使用。
    func orphanUris() throws -> [String] {
        try db.query("""
        SELECT r."ResourceUri" AS uri
        FROM \(map.quoted(Schema.Table.resource)) r
        LEFT JOIN \(map.quoted(Schema.Table.diaryResource)) dr ON dr."ResourceUri" = r."ResourceUri"
        WHERE dr."ResourceUri" IS NULL;
        """).compactMap { $0.string("uri") }
    }

    func totalBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: AppPaths.assetsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
