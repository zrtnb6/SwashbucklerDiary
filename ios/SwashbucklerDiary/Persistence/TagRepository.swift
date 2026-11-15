import Foundation

struct TagRepository {
    let db: SQLiteDatabase
    let map: TableMap

    init(db: SQLiteDatabase, map: TableMap? = nil) {
        self.db = db
        self.map = map ?? TableMap(database: db)
    }

    func fetchAll(withCounts: Bool = true) throws -> [Tag] {
        var tags = try db.query("SELECT * FROM \(map.quoted(Schema.Table.tag));").compactMap(DiaryRepository.tag(from:))
        if withCounts {
            let rows = try db.query("""
            SELECT "TagId", COUNT(*) AS total
            FROM \(map.quoted(Schema.Table.diaryTag))
            GROUP BY "TagId";
            """)
            var counts: [UUID: Int] = [:]
            for row in rows {
                guard let id = row.uuid("TagId") else { continue }
                counts[id] = row.int("total") ?? 0
            }
            for index in tags.indices {
                tags[index].diaryCount = counts[tags[index].id] ?? 0
            }
        }
        return tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 通过标签名找标签；不存在则创建。导入日记时用得到。
    func ensure(name: String) throws -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let row = try db.query("SELECT * FROM \(map.quoted(Schema.Table.tag)) WHERE lower(\"Name\") = lower(?) LIMIT 1;",
                                  [.text(trimmed)]).first,
           let tag = DiaryRepository.tag(from: row) {
            return tag
        }
        let tag = Tag(name: trimmed)
        try db.run("INSERT INTO \(map.quoted(Schema.Table.tag)) (\"Id\",\"CreateTime\",\"UpdateTime\",\"Name\") VALUES (?,?,?,?);",
                   [.uuid(tag.id), .date(tag.createTime), .date(tag.updateTime), .text(tag.name)])
        return tag
    }

    func rename(_ id: UUID, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try db.run("UPDATE \(map.quoted(Schema.Table.tag)) SET \"Name\" = ?, \"UpdateTime\" = ? WHERE \"Id\" = ?;",
                   [.text(trimmed), .date(Date()), .uuid(id)])
    }

    /// 删除标签只删关联与标签本体，不动日记。
    func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let params = ids.map { SQLValue.uuid($0) }
        try db.run("DELETE FROM \(map.quoted(Schema.Table.diaryTag)) WHERE \"TagId\" IN (\(placeholders));", params)
        try db.run("DELETE FROM \(map.quoted(Schema.Table.tag)) WHERE \"Id\" IN (\(placeholders));", params)
    }

    func count() throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM \(map.quoted(Schema.Table.tag));")
    }
}

struct LocationRepository {
    let db: SQLiteDatabase
    let map: TableMap

    init(db: SQLiteDatabase, map: TableMap? = nil) {
        self.db = db
        self.map = map ?? TableMap(database: db)
    }

    /// 原项目的地点列表来自 `LocationModel` 表，但日记里存的是文本。
    /// 为兼容起见，统计时以日记表的 `Location` 字段为准，缺了再回落到地点表。
    func fetchAllFromDiaries() throws -> [DiaryLocation] {
        let rows = try db.query("""
        SELECT "Location" AS name, COUNT(*) AS total, MIN("CreateTime") AS firstTime
        FROM \(map.quoted(Schema.Table.diary))
        WHERE "Location" IS NOT NULL AND trim("Location") <> ''
        GROUP BY "Location"
        ORDER BY total DESC;
        """)
        return rows.compactMap { row in
            guard let name = row.string("name"), !name.isEmpty else { return nil }
            return DiaryLocation(
                id: UUID(),
                createTime: row.date("firstTime") ?? Date(),
                updateTime: row.date("firstTime") ?? Date(),
                name: name,
                diaryCount: row.int("total") ?? 0
            )
        }
    }

    func ensureInCatalog(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = try db.scalarInt("SELECT COUNT(*) FROM \(map.quoted(Schema.Table.location)) WHERE lower(\"Name\") = lower(?);",
                                        [.text(trimmed)])
        guard existing == 0 else { return }
        try db.run("INSERT INTO \(map.quoted(Schema.Table.location)) (\"Id\",\"CreateTime\",\"UpdateTime\",\"Name\") VALUES (?,?,?,?);",
                   [.uuid(UUID()), .date(Date()), .date(Date()), .text(trimmed)])
    }
}
