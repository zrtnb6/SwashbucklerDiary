import Foundation

/// 日记仓储。所有 SQL 都集中在这里，UI 层不出现任何字符串拼接的 SQL。
struct DiaryRepository {
    let db: SQLiteDatabase
    let map: TableMap

    init(db: SQLiteDatabase) {
        self.db = db
        self.map = TableMap(database: db)
    }

    // MARK: - 查询

    /// 一次性把日记、标签关联、资源关联全部读出来再在内存里拼装。
    /// 日记数量在个人使用场景下是千级，这种「少查询多内存」的策略比 N+1 查询快得多。
    func fetchAll(includeTemplates: Bool = true) throws -> [Diary] {
        var diaries = try db.query("SELECT * FROM \(map.quoted(Schema.Table.diary));").map(Self.diary(from:))

        let tagsByDiary = try loadTagRelations()
        let resourcesByDiary = try loadResourceRelations()
        for index in diaries.indices {
            diaries[index].tags = tagsByDiary[diaries[index].id] ?? []
            diaries[index].resources = resourcesByDiary[diaries[index].id] ?? []
        }
        if !includeTemplates {
            diaries = diaries.filter { !$0.template }
        }
        return diaries
    }

    func fetch(id: UUID) throws -> Diary? {
        let rows = try db.query("SELECT * FROM \(map.quoted(Schema.Table.diary)) WHERE \"Id\" = ? LIMIT 1;", [.uuid(id)])
        guard let row = rows.first else { return nil }
        var diary = Self.diary(from: row)
        diary.tags = try tags(for: id)
        diary.resources = try resources(for: id)
        return diary
    }

    func templates() throws -> [Diary] {
        try fetchAll(includeTemplates: true).filter { $0.template }
    }

    func count() throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM \(map.quoted(Schema.Table.diary));")
    }

    /// 按天统计，用于日历页的圆点标记。返回 `yyyy-MM-dd` → 条数。
    func countsByDay() throws -> [String: Int] {
        let rows = try db.query("""
        SELECT substr("CreateTime", 1, 10) AS day, COUNT(*) AS total
        FROM \(map.quoted(Schema.Table.diary))
        GROUP BY day;
        """)
        var result: [String: Int] = [:]
        for row in rows {
            guard let day = row.string("day") else { continue }
            result[day] = row.int("total") ?? 0
        }
        return result
    }

    // MARK: - 写入

    func insert(_ diary: Diary) throws {
        try db.run("""
        INSERT OR REPLACE INTO \(map.quoted(Schema.Table.diary))
        ("Id","CreateTime","UpdateTime","Title","Content","Mood","Weather","Location","Top","Private","Template")
        VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """, [
            .uuid(diary.id),
            .date(diary.createTime),
            .date(diary.updateTime),
            .optionalText(diary.title),
            .optionalText(diary.content),
            .optionalText(diary.mood),
            .optionalText(diary.weather),
            .optionalText(diary.location),
            .bool(diary.top),
            .bool(diary.privateLegacy),
            .bool(diary.template),
        ])
        try replaceTags(diary)
        try replaceResources(diary)
    }

    func update(_ diary: Diary, touchUpdateTime: Bool = true) throws {
        var value = diary
        if touchUpdateTime { value.updateTime = Date() }
        try db.run("""
        UPDATE \(map.quoted(Schema.Table.diary)) SET
            "CreateTime" = ?, "UpdateTime" = ?, "Title" = ?, "Content" = ?,
            "Mood" = ?, "Weather" = ?, "Location" = ?, "Top" = ?, "Private" = ?, "Template" = ?
        WHERE "Id" = ?;
        """, [
            .date(value.createTime),
            .date(value.updateTime),
            .optionalText(value.title),
            .optionalText(value.content),
            .optionalText(value.mood),
            .optionalText(value.weather),
            .optionalText(value.location),
            .bool(value.top),
            .bool(value.privateLegacy),
            .bool(value.template),
            .uuid(value.id),
        ])
        try replaceTags(value)
        try replaceResources(value)
    }

    func setTop(_ id: UUID, top: Bool) throws {
        try db.run("UPDATE \(map.quoted(Schema.Table.diary)) SET \"Top\" = ?, \"UpdateTime\" = ? WHERE \"Id\" = ?;",
                   [.bool(top), .date(Date()), .uuid(id)])
    }

    func setTemplate(_ id: UUID, template: Bool) throws {
        try db.run("UPDATE \(map.quoted(Schema.Table.diary)) SET \"Template\" = ?, \"UpdateTime\" = ? WHERE \"Id\" = ?;",
                   [.bool(template), .date(Date()), .uuid(id)])
    }

    func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let params = ids.map { SQLValue.uuid($0) }
        try db.run("DELETE FROM \(map.quoted(Schema.Table.diaryTag)) WHERE \"DiaryId\" IN (\(placeholders));", params)
        try db.run("DELETE FROM \(map.quoted(Schema.Table.diaryResource)) WHERE \"DiaryId\" IN (\(placeholders));", params)
        try db.run("DELETE FROM \(map.quoted(Schema.Table.diary)) WHERE \"Id\" IN (\(placeholders));", params)
    }

    // MARK: - 标签关联

    private func replaceTags(_ diary: Diary) throws {
        try db.run("DELETE FROM \(map.quoted(Schema.Table.diaryTag)) WHERE \"DiaryId\" = ?;", [.uuid(diary.id)])
        for tag in diary.tags {
            let resolvedId = try ensureTag(name: tag.name, preferredId: tag.id)
            try db.run("""
            INSERT INTO \(map.quoted(Schema.Table.diaryTag)) ("Id","CreateTime","UpdateTime","DiaryId","TagId")
            VALUES (?,?,?,?,?);
            """, [
                .uuid(UUID()),
                .date(Date()),
                .date(Date()),
                .uuid(diary.id),
                .uuid(resolvedId),
            ])
        }
    }

    private func ensureTag(name: String, preferredId: UUID) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return preferredId }
        if let existing = try db.query("SELECT \"Id\" FROM \(map.quoted(Schema.Table.tag)) WHERE lower(\"Name\") = lower(?) LIMIT 1;",
                                       [.text(trimmed)]).first,
           let id = existing.uuid("Id") {
            return id
        }
        try db.run("INSERT OR REPLACE INTO \(map.quoted(Schema.Table.tag)) (\"Id\",\"CreateTime\",\"UpdateTime\",\"Name\") VALUES (?,?,?,?);",
                   [.uuid(preferredId), .date(Date()), .date(Date()), .text(trimmed)])
        return preferredId
    }

    // MARK: - 资源关联

    private func replaceResources(_ diary: Diary) throws {
        try db.run("DELETE FROM \(map.quoted(Schema.Table.diaryResource)) WHERE \"DiaryId\" = ?;", [.uuid(diary.id)])
        for resource in diary.resources {
            try db.run("INSERT OR IGNORE INTO \(map.quoted(Schema.Table.resource)) (\"ResourceUri\",\"ResourceType\") VALUES (?,?);",
                       [.text(resource.resourceUri), .integer(Int64(resource.resourceType.rawValue))])
            try db.run("""
            INSERT INTO \(map.quoted(Schema.Table.diaryResource)) ("Id","CreateTime","UpdateTime","DiaryId","ResourceUri")
            VALUES (?,?,?,?,?);
            """, [
                .uuid(UUID()),
                .date(Date()),
                .date(Date()),
                .uuid(diary.id),
                .text(resource.resourceUri),
            ])
        }
    }

    private func loadTagRelations() throws -> [UUID: [Tag]] {
        let tags = try TagRepository(db: db, map: map).fetchAll()
        var tagIndex: [UUID: Tag] = [:]
        for tag in tags { tagIndex[tag.id] = tag }

        let rows = try db.query("SELECT \"DiaryId\",\"TagId\" FROM \(map.quoted(Schema.Table.diaryTag));")
        var result: [UUID: [Tag]] = [:]
        for row in rows {
            guard let diaryId = row.uuid("DiaryId"), let tagId = row.uuid("TagId") else { continue }
            guard let tag = tagIndex[tagId] else { continue }
            result[diaryId, default: []].append(tag)
        }
        for key in result.keys {
            result[key]?.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return result
    }

    private func loadResourceRelations() throws -> [UUID: [MediaResource]] {
        let types = try ResourceRepository(db: db, map: map).typeIndex()
        let rows = try db.query("SELECT \"DiaryId\",\"ResourceUri\" FROM \(map.quoted(Schema.Table.diaryResource));")
        var result: [UUID: [MediaResource]] = [:]
        for row in rows {
            guard let diaryId = row.uuid("DiaryId"), let uri = row.string("ResourceUri") else { continue }
            let kind = types[uri] ?? MediaKind.from(fileExtension: (uri as NSString).pathExtension)
            result[diaryId, default: []].append(MediaResource(resourceUri: uri, resourceType: kind))
        }
        return result
    }

    func tags(for diaryId: UUID) throws -> [Tag] {
        let rows = try db.query("""
        SELECT t."Id" AS Id, t."CreateTime" AS CreateTime, t."UpdateTime" AS UpdateTime, t."Name" AS Name
        FROM \(map.quoted(Schema.Table.diaryTag)) dt
        JOIN \(map.quoted(Schema.Table.tag)) t ON t."Id" = dt."TagId"
        WHERE dt."DiaryId" = ?;
        """, [.uuid(diaryId)])
        return rows.compactMap(Self.tag(from:))
    }

    func resources(for diaryId: UUID) throws -> [MediaResource] {
        let types = try ResourceRepository(db: db, map: map).typeIndex()
        let rows = try db.query("SELECT \"ResourceUri\" FROM \(map.quoted(Schema.Table.diaryResource)) WHERE \"DiaryId\" = ?;",
                                [.uuid(diaryId)])
        return rows.compactMap { row -> MediaResource? in
            guard let uri = row.string("ResourceUri") else { return nil }
            let kind = types[uri] ?? MediaKind.from(fileExtension: (uri as NSString).pathExtension)
            return MediaResource(resourceUri: uri, resourceType: kind)
        }
    }

    func diaries(usingResource uri: String) throws -> [UUID] {
        try db.query("SELECT \"DiaryId\" FROM \(map.quoted(Schema.Table.diaryResource)) WHERE \"ResourceUri\" = ?;", [.text(uri)])
            .compactMap { $0.uuid("DiaryId") }
    }

    // MARK: - 行映射

    static func diary(from row: Row) -> Diary {
        Diary(
            id: row.uuid("Id") ?? UUID(),
            createTime: row.date("CreateTime") ?? Date(),
            updateTime: row.date("UpdateTime") ?? Date(),
            title: row.string("Title"),
            content: row.string("Content"),
            mood: row.string("Mood"),
            weather: row.string("Weather"),
            location: row.string("Location"),
            top: row.bool("Top"),
            privateLegacy: row.bool("Private"),
            template: row.bool("Template")
        )
    }

    static func tag(from row: Row) -> Tag? {
        guard let id = row.uuid("Id") else { return nil }
        return Tag(
            id: id,
            createTime: row.date("CreateTime") ?? Date(),
            updateTime: row.date("UpdateTime") ?? Date(),
            name: row.string("Name") ?? ""
        )
    }
}
