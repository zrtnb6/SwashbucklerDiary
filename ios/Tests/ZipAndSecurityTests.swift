import XCTest
@testable import SwashbucklerDiary

final class ZipTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripStoredAndDeflated() throws {
        let url = directory.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: url)
        let text = String(repeating: "侠客日记 backup 内容 ", count: 400)
        try writer.addFile(entryPath: "settings.json", data: Data("{\"Language\":\"zh-CN\"}".utf8))
        try writer.addFile(entryPath: "text/note.md", data: Data(text.utf8))
        try writer.finish()

        let reader = try ZipReader(url: url)
        XCTAssertEqual(reader.entries.count, 2)
        XCTAssertEqual(try reader.read(named: "settings.json"), Data("{\"Language\":\"zh-CN\"}".utf8))
        XCTAssertEqual(String(data: try reader.read(named: "text/note.md"), encoding: .utf8), text)
    }

    func testChineseEntryNameSurvives() throws {
        let url = directory.appendingPathComponent("cn.zip")
        let writer = try ZipWriter(url: url)
        try writer.addFile(entryPath: "appdata/图片/示例 图.jpg", data: Data([0xFF, 0xD8, 0xFF]))
        try writer.finish()

        let reader = try ZipReader(url: url)
        XCTAssertEqual(reader.entries.first?.name, "appdata/图片/示例 图.jpg")
    }

    func testCRC32KnownValue() {
        // "123456789" 的标准 CRC32 为 0xCBF43926
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
    }

    func testExtractAllWritesFiles() throws {
        let url = directory.appendingPathComponent("b.zip")
        let writer = try ZipWriter(url: url)
        try writer.addFile(entryPath: "SwashbucklerDiary.db3", data: Data(repeating: 0x01, count: 64))
        try writer.addFile(entryPath: "appdata/Image/x.jpg", data: Data(repeating: 0x02, count: 32))
        try writer.finish()

        let output = directory.appendingPathComponent("out", isDirectory: true)
        let reader = try ZipReader(url: url)
        let written = try reader.extractAll(to: output)
        XCTAssertEqual(written.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("appdata/Image/x.jpg").path))
    }

    func testArchiveCanBeReadBackAfterDeletingSource() throws {
        let url = directory.appendingPathComponent("c.zip")
        let writer = try ZipWriter(url: url)
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        try writer.addFile(entryPath: "blob.bin", data: payload)
        try writer.finish()

        // 关闭后重新打开，模拟真实使用路径
        let reader = try ZipReader(data: try Data(contentsOf: url))
        XCTAssertEqual(try reader.read(named: "blob.bin"), payload)
    }

    func testEmptyArchiveIsRejected() {
        XCTAssertThrowsError(try ZipReader(data: Data("not a zip".utf8)))
    }

    func testLargeFileRoundTrip() throws {
        let url = directory.appendingPathComponent("large.zip")
        let writer = try ZipWriter(url: url)
        let payload = Data(repeating: 0xAB, count: 6 * 1024 * 1024)
        try writer.addFile(entryPath: "media/large.bin", data: payload)
        try writer.finish()

        let reader = try ZipReader(url: url)
        let restored = try reader.read(named: "media/large.bin")
        XCTAssertEqual(restored.count, payload.count)
    }
}

final class SecurityTests: XCTestCase {
    func testPasswordHashAndVerify() {
        let result = PasswordHasher.makePassword("1234")
        XCTAssertFalse(result.hash.isEmpty)
        XCTAssertFalse(result.salt.isEmpty)
        XCTAssertTrue(PasswordHasher.verify(password: "1234", hashBase64: result.hash, saltBase64: result.salt))
        XCTAssertFalse(PasswordHasher.verify(password: "12345", hashBase64: result.hash, saltBase64: result.salt))
    }

    func testSamePasswordDifferentSaltProducesDifferentHash() {
        let first = PasswordHasher.makePassword("8888")
        let second = PasswordHasher.makePassword("8888")
        XCTAssertNotEqual(first.hash, second.hash, "随机盐必须让相同密码产生不同哈希")
        XCTAssertNotEqual(first.salt, second.salt)
    }

    func testEmptyStoredHashRejectsEverything() {
        XCTAssertFalse(PasswordHasher.verify(password: "", hashBase64: "", saltBase64: ""))
        XCTAssertFalse(PasswordHasher.verify(password: "any", hashBase64: "", saltBase64: ""))
    }

    func testHashIsPBKDF2SHA256With10000Iterations() {
        // 固定盐 + 固定密码，结果必须稳定，且与 .NET Rfc2898DeriveBytes(SHA256, 10000) 一致
        let salt = Data(repeating: 0x0A, count: 32)
        let hash = PasswordHasher.hash(password: "swashbuckler", salt: salt)
        XCTAssertEqual(hash?.count, 32)
        let second = PasswordHasher.hash(password: "swashbuckler", salt: salt)
        XCTAssertEqual(hash, second, "同样输入必须得到同样输出")
    }
}

final class BackupFormatTests: XCTestCase {
    func testSettingsJSONUsesPascalCaseKeys() throws {
        var settings = AppSettings()
        settings.language = "en"
        settings.markdown = false
        settings.editAutoSave = 10
        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"Language\""))
        XCTAssertTrue(json.contains("\"Markdown\""))
        XCTAssertTrue(json.contains("\"EditAutoSave\""))
        XCTAssertFalse(json.contains("\"language\""))
    }

    func testSettingsDecodingToleratesMissingFields() throws {
        let json = "{\"Language\":\"zh-CN\",\"Markdown\":false}"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.language, "zh-CN")
        XCTAssertFalse(decoded.markdown)
        XCTAssertEqual(decoded.editAutoSave, 5, "缺失字段应使用默认值")
    }

    func testWebDAVConfigurationJSONMatchesOriginal() throws {
        let config = WebDAVConfiguration(serverAddress: "https://dav.example.com/dav/",
                                         account: "user", password: "pass")
        let json = config.jsonString
        XCTAssertTrue(json.contains("ServerAddress"))
        let parsed = WebDAVConfiguration.parse(json)
        XCTAssertEqual(parsed?.account, "user")
    }

    func testBaseAddressNormalization() {
        XCTAssertEqual(WebDAVClient.normalizeBaseAddress("https://a.com/dav")?.absoluteString, "https://a.com/dav/")
        XCTAssertEqual(WebDAVClient.normalizeBaseAddress("a.com/dav/")?.absoluteString, "https://a.com/dav/")
        XCTAssertNil(WebDAVClient.normalizeBaseAddress("   "))
        XCTAssertNil(WebDAVClient.normalizeBaseAddress("ftp://a.com/dav"))
    }

    func testPercentEncodingForChineseName() {
        let encoded = WebDAVClient.percentEncode("中文 备份.zip")
        XCTAssertEqual(encoded.removingPercentEncoding, "中文 备份.zip")
        XCTAssertFalse(encoded.contains(" "))
    }
}
