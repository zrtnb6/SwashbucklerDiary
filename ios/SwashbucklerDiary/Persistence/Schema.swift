import Foundation

/// 表结构定义。
///
/// 这是整个迁移方案的地基：表名、列名、类型全部对齐原项目的 SqlSugar CodeFirst 输出
/// （表名 = C# 类名，列名 = 属性名，Guid/DateTime 为 TEXT，bool/int 为 INTEGER）。
/// 因此原生客户端可以直接读写老用户的 `SwashbucklerDiary.db3`，
/// 也能让自己的备份被 Android / Windows 端恢复。
enum Schema {
    enum Table {
        static let diary = "DiaryModel"
        static let tag = "TagModel"
        static let diaryTag = "DiaryTagModel"
        static let resource = "ResourceModel"
        static let diaryResource = "DiaryResourceModel"
        static let location = "LocationModel"
        static let userState = "UserStateModel"
        static let userAchievement = "UserAchievementModel"
    }

    /// 旧版本（1.x 早期）用过的别名，读取时按顺序探测。
    static let legacyAliases: [String: [String]] = [
        Table.diary: ["Diary", "Diaries"],
        Table.tag: ["Tag", "Tags"],
        Table.diaryTag: ["DiaryTag"],
        Table.resource: ["Resource", "Resources"],
        Table.diaryResource: ["DiaryResource"],
        Table.location: ["Location", "Locations"],
    ]

    static let createStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS "DiaryModel" (
            "Id" TEXT NOT NULL PRIMARY KEY,
            "CreateTime" TEXT NOT NULL,
            "UpdateTime" TEXT NOT NULL,
            "Title" TEXT,
            "Content" TEXT,
            "Mood" TEXT,
            "Weather" TEXT,
            "Location" TEXT,
            "Top" INTEGER NOT NULL DEFAULT 0,
            "Private" INTEGER NOT NULL DEFAULT 0,
            "Template" INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS "TagModel" (
            "Id" TEXT NOT NULL PRIMARY KEY,
            "CreateTime" TEXT NOT NULL,
            "UpdateTime" TEXT NOT NULL,
            "Name" TEXT
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS "DiaryTagModel" (
            "Id" TEXT NOT NULL PRIMARY KEY,
            "CreateTime" TEXT NOT NULL,
            "UpdateTime" TEXT NOT NULL,
            "DiaryId" TEXT NOT NULL,
            "TagId" TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS "ResourceModel" (
            "ResourceUri" TEXT NOT NULL PRIMARY KEY,
            "ResourceType" INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS "DiaryResourceModel" (
            "Id" TEXT NOT NULL PRIMARY KEY,
            "CreateTime" TEXT NOT NULL,
            "UpdateTime" TEXT NOT NULL,
            "DiaryId" TEXT NOT NULL,
            "ResourceUri" TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS "LocationModel" (
            "Id" TEXT NOT NULL PRIMARY KEY,
            "CreateTime" TEXT NOT NULL,
            "UpdateTime" TEXT NOT NULL,
            "Name" TEXT
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS "UserStateModel" (
            "Id" TEXT NOT NULL PRIMARY KEY,
            "CreateTime" TEXT NOT NULL,
            "UpdateTime" TEXT NOT NULL,
            "Type" INTEGER NOT NULL DEFAULT 0,
            "Count" INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS "UserAchievementModel" (
            "Id" TEXT NOT NULL PRIMARY KEY,
            "AchievementName" TEXT,
            "CompleteRate" INTEGER NOT NULL DEFAULT 0,
            "IsCompleted" INTEGER NOT NULL DEFAULT 0,
            "CompletedTime" TEXT
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS "idx_diary_createtime" ON "DiaryModel" ("CreateTime");
        """,
        """
        CREATE INDEX IF NOT EXISTS "idx_diary_tag_diary" ON "DiaryTagModel" ("DiaryId");
        """,
        """
        CREATE INDEX IF NOT EXISTS "idx_diary_tag_tag" ON "DiaryTagModel" ("TagId");
        """,
        """
        CREATE INDEX IF NOT EXISTS "idx_diary_resource_diary" ON "DiaryResourceModel" ("DiaryId");
        """,
    ]
}

/// 探测数据库里真实的表名，避免因历史版本命名差异导致读不到数据。
struct TableMap {
    private var resolved: [String: String] = [:]

    init(database: SQLiteDatabase) {
        let existing = database.tableNames()
        func match(_ candidates: [String]) -> String? {
            for candidate in candidates {
                if let hit = existing.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                    return hit
                }
            }
            return nil
        }
        let logical = [
            Schema.Table.diary, Schema.Table.tag, Schema.Table.diaryTag,
            Schema.Table.resource, Schema.Table.diaryResource, Schema.Table.location,
            Schema.Table.userState, Schema.Table.userAchievement,
        ]
        for name in logical {
            let candidates = [name] + (Schema.legacyAliases[name] ?? [])
            resolved[name] = match(candidates) ?? name
        }
    }

    subscript(_ logicalName: String) -> String {
        resolved[logicalName] ?? logicalName
    }

    func quoted(_ logicalName: String) -> String {
        SQLiteDatabase.quote(self[logicalName])
    }
}

enum SchemaMigrator {
    /// 建表 + 补列。对已存在的老库是幂等的：只做 `IF NOT EXISTS` 与 `ALTER TABLE ADD COLUMN`。
    static func prepare(_ database: SQLiteDatabase) throws {
        for statement in Schema.createStatements {
            try database.execute(statement)
        }
        try ensureLegacyColumns(database)
    }

    /// 老版本数据库可能缺少后加的列（如 `Template`），读取会因为 SELECT * 不报错但映射失败，
    /// 这里主动补齐，保证写入路径不会因为缺列而崩。
    private static func ensureLegacyColumns(_ database: SQLiteDatabase) throws {
        let map = TableMap(database: database)
        let diaryColumns = Set(database.columnNames(of: map[Schema.Table.diary]).map { $0.lowercased() })
        if !diaryColumns.isEmpty {
            if !diaryColumns.contains("template") {
                try database.execute("ALTER TABLE \(map.quoted(Schema.Table.diary)) ADD COLUMN \"Template\" INTEGER NOT NULL DEFAULT 0;")
            }
            if !diaryColumns.contains("private") {
                try database.execute("ALTER TABLE \(map.quoted(Schema.Table.diary)) ADD COLUMN \"Private\" INTEGER NOT NULL DEFAULT 0;")
            }
            if !diaryColumns.contains("top") {
                try database.execute("ALTER TABLE \(map.quoted(Schema.Table.diary)) ADD COLUMN \"Top\" INTEGER NOT NULL DEFAULT 0;")
            }
        }
    }
}
