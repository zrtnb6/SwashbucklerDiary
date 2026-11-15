import XCTest
@testable import SwashbucklerDiary

final class PersistenceTests: XCTestCase {
    private var directory: URL!
    private var database: SQLiteDatabase!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diary-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(url: directory.appendingPathComponent("test.db3"))
        try SchemaMigrator.prepare(database)
    }

    override func tearDownWithError() throws {
        database.close()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Schema

    func testSchemaMatchesOriginalTableNames() throws {
        let tables = Set(database.tableNames())
        for expected in [Schema.Table.diary, Schema.Table.tag, Schema.Table.diaryTag,
                         Schema.Table.resource, Schema.Table.diaryResource,
                         Schema.Table.location, Schema.Table.userState, Schema.Table.userAchievement] {
            XCTAssertTrue(tables.contains(expected), "缺少表 \(expected)")
        }
    }

    func testCreatesMissingLegacyColumn() throws {
        // 模拟 1.x 早期的库：没有 Template 列
        let legacyURL = directory.appendingPathComponent("legacy.db3")
        let legacy = try SQLiteDatabase(url: legacyURL)
        try legacy.execute("""
        CREATE TABLE "DiaryModel" (
            "Id" TEXT NOT NULL PRIMARY KEY, "CreateTime" TEXT, "UpdateTime" TEXT,
            "Title" TEXT, "Content" TEXT, "Mood" TEXT, "Weather" TEXT, "Location" TEXT, "Top" INTEGER
        );
        """)
        legacy.close()

        let reopened = try SQLiteDatabase(url: legacyURL)
        try SchemaMigrator.prepare(reopened)
        let columns = Set(reopened.columnNames(of: Schema.Table.diary).map { $0.lowercased() })
        XCTAssertTrue(columns.contains("template"), "启动后应自动补齐 Template 列")
        XCTAssertTrue(columns.contains("private"))
        reopened.close()
    }

    // MARK: - 兼容解析

    func testDateFormatsFromDotNetAreParsed() throws {
        let samples = [
            "2023-06-01 12:00:00.123",
            "2023-06-01 12:00:00",
            "2023-06-01T12:00:00.123",
            "2023/06/01 12:00:00",
        ]
        for sample in samples {
            XCTAssertNotNil(DateCompat.decode(sample), "无法解析 \(sample)")
        }
        XCTAssertNil(DateCompat.decode("not a date"))
    }

    func testEpochAndTicksFallback() {
        let epoch = DateCompat.decode(number: 1_700_000_000)
        XCTAssertNotNil(epoch)
        let millis = DateCompat.decode(number: 1_700_000_000_000)
        XCTAssertNotNil(millis)
        let ticks = DateCompat.decode(number: 638_300_000_000_000_000)
        XCTAssertNotNil(ticks)
    }

    func testDateRoundTripKeepsSecondPrecision() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let encoded = DateCompat.encode(date)
        let decoded = DateCompat.decode(encoded)
        XCTAssertEqual(decoded?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 0.01)
    }

    func testUUIDWithBracesAndUppercase() {
        let raw = "6F5B3C1A-9A2B-4F8E-8C1D-2B3A4C5D6E7F"
        XCTAssertNotNil(UUIDCompat.decode(raw))
        XCTAssertNotNil(UUIDCompat.decode("{\(raw)}"))
        XCTAssertNotNil(UUIDCompat.decode(raw.replacingOccurrences(of: "-", with: "")))
    }

    // MARK: - 仓储

    func testInsertAndFetchDiaryWithTagsAndResources() throws {
        let repository = DiaryRepository(db: database)
        var diary = Diary(title: "标题", content: "正文")
        diary.tags = [Tag(name: "技术"), Tag(name: "随笔")]
        diary.resources = [MediaResource(resourceUri: "appdata/Image/a.jpg", resourceType: .image)]

        try repository.insert(diary)

        let fetched = try XCTUnwrap(try repository.fetch(id: diary.id))
        XCTAssertEqual(fetched.title, "标题")
        XCTAssertEqual(fetched.tags.count, 2)
        XCTAssertEqual(fetched.resources.count, 1)
        XCTAssertEqual(fetched.resources.first?.resourceType, .image)
    }

    func testUpdatingTagsDoesNotDuplicate() throws {
        let repository = DiaryRepository(db: database)
        var diary = Diary(title: "A", content: "x")
        diary.tags = [Tag(name: "技术")]
        try repository.insert(diary)

        diary.tags.append(Tag(name: "生活"))
        try repository.update(diary)

        let fetched = try XCTUnwrap(try repository.fetch(id: diary.id))
        XCTAssertEqual(fetched.tags.count, 2)

        let tags = try TagRepository(db: database).fetchAll()
        XCTAssertEqual(tags.count, 2, "同名标签不应重复创建")
    }

    func testSameTagNameReusesExistingTag() throws {
        let repository = DiaryRepository(db: database)
        var first = Diary(title: "1")
        first.tags = [Tag(name: "重复")]
        try repository.insert(first)

        var second = Diary(title: "2")
        second.tags = [Tag(name: "重复")]
        try repository.insert(second)

        let tags = try TagRepository(db: database).fetchAll()
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags.first?.diaryCount, 2)
    }

    func testDeleteDiaryRemovesRelations() throws {
        let repository = DiaryRepository(db: database)
        var diary = Diary(title: "将被删除")
        diary.tags = [Tag(name: "临时")]
        diary.resources = [MediaResource(resourceUri: "appdata/Image/b.jpg", resourceType: .image)]
        try repository.insert(diary)

        try repository.delete(ids: [diary.id])

        XCTAssertNil(try repository.fetch(id: diary.id))
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM \"DiaryTagModel\";"), 0)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM \"DiaryResourceModel\";"), 0)
        // 资源记录与文件都保留，避免误删仍被其它日记引用的文件
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM \"ResourceModel\";"), 1)
    }

    func testCountsByDayGroupsCorrectly() throws {
        let repository = DiaryRepository(db: database)
        let calendar = Calendar.current
        for offset in 0..<3 {
            var diary = Diary(title: "第\(offset)篇")
            diary.createTime = calendar.date(byAdding: .day, value: -offset, to: Date())!
            try repository.insert(diary)
        }
        let counts = try repository.countsByDay()
        XCTAssertEqual(counts.values.reduce(0, +), 3)
        XCTAssertEqual(counts.count, 3)
    }

    func testTemplatesAreExcludedFromTimeline() throws {
        let repository = DiaryRepository(db: database)
        var normal = Diary(title: "普通")
        normal.template = false
        try repository.insert(normal)
        var template = Diary(title: "模板")
        template.template = true
        try repository.insert(template)

        let all = try repository.fetchAll(includeTemplates: false)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "普通")
    }

    func testChineseContentAndTagsRoundTrip() throws {
        let repository = DiaryRepository(db: database)
        var diary = Diary(title: "中文标题 🎐", content: "正文包含 emoji 😀 与换行\n第二行")
        diary.tags = [Tag(name: "中文标签")]
        try repository.insert(diary)

        let fetched = try XCTUnwrap(try repository.fetch(id: diary.id))
        XCTAssertEqual(fetched.title, "中文标题 🎐")
        XCTAssertEqual(fetched.content?.contains("😀"), true)
        XCTAssertEqual(fetched.tags.first?.name, "中文标签")
    }
}
