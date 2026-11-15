import XCTest
@testable import SwashbucklerDiary

/// WebDAV 客户端回归测试。
///
/// 全程跑在进程内模拟服务器上，覆盖需求里列出的必须测项：
/// 正常上传、正常下载、错误密码、不存在的远程目录、中文文件名、
/// 大体积备份、服务器错误、重复上传、上传后恢复。
final class WebDAVClientTests: XCTestCase {
    private var server: LocalWebDAVServer!
    private var baseURL: URL!
    private var workDirectory: URL!

    override func setUpWithError() throws {
        server = try LocalWebDAVServer()
        baseURL = try server.start()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webdav-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func makeClient(account: String = "user", password: String = "pass") throws -> WebDAVClient {
        try WebDAVClient(configuration: WebDAVConfiguration(
            serverAddress: baseURL.absoluteString,
            account: account,
            password: password
        ), useBackgroundSession: false)
    }

    private func makeFile(name: String, bytes: Int) throws -> URL {
        let url = workDirectory.appendingPathComponent(name)
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0) })
        try data.write(to: url)
        return url
    }

    // MARK: - 连接与目录

    func testConnectCreatesMissingFolder() async throws {
        server.credentials = .init(username: "user", password: "pass")
        let client = try makeClient()
        try await client.connect()
        XCTAssertTrue(server.createdCollections.contains("/dav/SwashbucklerDiary"),
                      "远程目录不存在时应自动 MKCOL 创建")
    }

    func testConnectFailsWithWrongPassword() async throws {
        server.credentials = .init(username: "user", password: "pass")
        let client = try makeClient(password: "wrong")
        do {
            try await client.connect()
            XCTFail("错误密码不应通过")
        } catch let error as WebDAVError {
            XCTAssertEqual(error.errorDescription, WebDAVError.unauthorized.errorDescription)
        }
    }

    func testInvalidAddressRejected() {
        XCTAssertThrowsError(try WebDAVClient(configuration: WebDAVConfiguration(
            serverAddress: "   ", account: "a", password: "b")))
        XCTAssertThrowsError(try WebDAVClient(configuration: WebDAVConfiguration(
            serverAddress: "https://ok.com/dav/", account: "", password: "b")))
    }

    // MARK: - 上传

    func testUploadCreatesRemoteFileAndVerifiesSize() async throws {
        server.credentials = .init(username: "user", password: "pass")
        let client = try makeClient()
        let file = try makeFile(name: "backup.zip", bytes: 4096)

        try await client.upload(fileURL: file, fileName: "SwashbucklerDiaryBackup_test.zip")

        let remote = try XCTUnwrap(server.receivedFiles["/dav/SwashbucklerDiary/SwashbucklerDiaryBackup_test.zip"])
        XCTAssertEqual(remote.data.count, 4096)
    }

    func testUploadWithChineseFileName() async throws {
        server.credentials = .init(username: "user", password: "pass")
        let client = try makeClient()
        let file = try makeFile(name: "cn.zip", bytes: 128)

        try await client.upload(fileURL: file, fileName: "备份 2026.zip")

        XCTAssertNotNil(server.receivedFiles["/dav/SwashbucklerDiary/备份 2026.zip"],
                        "中文文件名应使用百分号编码传输，并在服务端还原为原名")
    }

    func testUploadLargeFile() async throws {
        server.credentials = .init(username: "user", password: "pass")
        let client = try makeClient()
        let file = try makeFile(name: "large.zip", bytes: 8 * 1024 * 1024)

        try await client.upload(fileURL: file, fileName: "large.zip")

        XCTAssertEqual(server.receivedFiles["/dav/SwashbucklerDiary/large.zip"]?.data.count, 8 * 1024 * 1024)
    }

    func testUploadTwiceOverwrites() async throws {
        server.credentials = .init(username: "user", password: "pass")
        let client = try makeClient()
        let first = try makeFile(name: "v1.zip", bytes: 100)
        let second = try makeFile(name: "v2.zip", bytes: 200)

        try await client.upload(fileURL: first, fileName: "same.zip")
        try await client.upload(fileURL: second, fileName: "same.zip")

        XCTAssertEqual(server.receivedFiles["/dav/SwashbucklerDiary/same.zip"]?.data.count, 200)
    }

    func testUploadSurfacesServerError() async throws {
        server.credentials = .init(username: "user", password: "pass")
        server.failOnPut = true
        let client = try makeClient()
        let file = try makeFile(name: "x.zip", bytes: 64)

        do {
            try await client.upload(fileURL: file, fileName: "x.zip")
            XCTFail("服务器 500 时应抛出错误")
        } catch let error as WebDAVError {
            guard case .serverError(let status, _, _) = error else {
                return XCTFail("应为 serverError，实际 \(error)")
            }
            XCTAssertEqual(status, 500)
        }
    }

    // MARK: - 列表 / 下载 / 删除

    func testListBackupsReturnsZipOnly() async throws {
        server.credentials = .init(username: "user", password: "pass")
        let client = try makeClient()
        let file = try makeFile(name: "l.zip", bytes: 32)

        try await client.upload(fileURL: file, fileName: "a.zip")
        try await client.upload(fileURL: file, fileName: "b.zip")
        try await client.upload(fileURL: file, fileName: "ignore.txt")

        let list = try await client.listBackups()
        let names = Set(list.map(\.name))
        XCTAssertEqual(names, ["a.zip", "b.zip"])
    }

    func testDownloadReturnsSameBytes() async throws {
        server.credentials = .init(username: "user", password: "pass")
        let client = try makeClient()
        let file = try makeFile(name: "d.zip", bytes: 2048)
        let original = try Data(contentsOf: file)

        try await client.upload(fileURL: file, fileName: "d.zip")
        let downloaded = try await client.download(name: "d.zip")
        defer { try? FileManager.default.removeItem(at: downloaded) }

        XCTAssertEqual(try Data(contentsOf: downloaded), original)
    }

    func testDeleteRemovesRemoteFile() async throws {
        server.credentials = .init(username: "user", password: "pass")
        let client = try makeClient()
        let file = try makeFile(name: "e.zip", bytes: 16)

        try await client.upload(fileURL: file, fileName: "e.zip")
        try await client.delete(name: "e.zip")

        XCTAssertNil(server.receivedFiles["/dav/SwashbucklerDiary/e.zip"])
    }

    func testListWhenFolderExistsButEmpty() async throws {
        server.credentials = .init(username: "user", password: "pass")
        server.existingCollections.insert("/dav/SwashbucklerDiary")
        let client = try makeClient()
        let list = try await client.listBackups()
        XCTAssertTrue(list.isEmpty)
    }

    // MARK: - 上传后可恢复（端到端）

    func testUploadedZipIsValidArchive() async throws {
        server.credentials = .init(username: "user", password: "pass")
        let client = try makeClient()

        let zipURL = workDirectory.appendingPathComponent("payload.zip")
        let writer = try ZipWriter(url: zipURL)
        try writer.addFile(entryPath: "SwashbucklerDiary.db3", data: Data(repeating: 0x11, count: 512))
        try writer.addFile(entryPath: "settings.json", data: Data("{\"Language\":\"zh-CN\"}".utf8))
        try writer.finish()

        try await client.upload(fileURL: zipURL, fileName: "roundtrip.zip")
        let downloaded = try await client.download(name: "roundtrip.zip")
        defer { try? FileManager.default.removeItem(at: downloaded) }

        let reader = try ZipReader(url: downloaded)
        XCTAssertTrue(reader.contains("SwashbucklerDiary.db3"))
        XCTAssertEqual(try reader.read(named: "settings.json"), Data("{\"Language\":\"zh-CN\"}".utf8))
    }
}
