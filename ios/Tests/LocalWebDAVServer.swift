import Foundation
import Network
import XCTest
@testable import SwashbucklerDiary

/// 进程内的最小 WebDAV 服务器。
///
/// 目的：在没有真实 WebDAV 凭据的情况下，把上传/下载/建目录/鉴权/大文件/取消
/// 这些路径都跑一遍，而不是"看起来应该没问题"。
/// 只实现测试需要的动词：PROPFIND / MKCOL / PUT / GET / DELETE。
final class LocalWebDAVServer {
    struct Credentials {
        var username: String
        var password: String
    }

    struct ReceivedFile {
        var path: String
        var data: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.webdav.server")
    private var connections: [NWConnection] = []

    private(set) var port: UInt16 = 0
    private(set) var receivedFiles: [String: ReceivedFile] = [:]
    private(set) var createdCollections: Set<String> = []
    private(set) var requestLog: [String] = []

    var credentials: Credentials?
    /// PUT 时故意返回 500，用于验证错误路径
    var failOnPut = false
    /// 延迟响应，用于测试取消
    var responseDelay: TimeInterval = 0
    /// 已有集合（模拟服务器上已存在的目录）
    var existingCollections: Set<String> = ["/", "/dav", "/dav/"]

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "LocalWebDAVServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "监听端口启动失败"])
        }
        port = listener.port?.rawValue ?? 0
        return URL(string: "http://127.0.0.1:\(port)/dav/")!
    }

    func stop() {
        for connection in connections { connection.cancel() }
        connections.removeAll()
        listener.cancel()
    }

    // MARK: - 连接处理

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let request = Self.parseRequest(accumulated) {
                if self.responseDelay > 0 {
                    self.queue.asyncAfter(deadline: .now() + self.responseDelay) {
                        self.respond(to: request, on: connection)
                    }
                } else {
                    self.respond(to: request, on: connection)
                }
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private static func parseRequest(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = rawPath.removingPercentEncoding ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        let available = data.count - bodyStart
        if available < contentLength { return nil }

        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return Request(method: method, path: path, headers: headers, body: body)
    }

    // MARK: - 响应

    private func respond(to request: Request, on connection: NWConnection) {
        requestLog.append("\(request.method) \(request.path)")

        if let credentials {
            let expected = "Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
            if request.headers["authorization"] != expected {
                send(connection, status: 401, reason: "Unauthorized", headers: [
                    "WWW-Authenticate": "Basic realm=\"test\"",
                ], body: Data())
                return
            }
        }

        switch request.method {
        case "PROPFIND":
            handlePropfind(request, connection: connection)
        case "MKCOL":
            handleMkcol(request, connection: connection)
        case "PUT":
            handlePut(request, connection: connection)
        case "GET":
            handleGet(request, connection: connection)
        case "DELETE":
            handleDelete(request, connection: connection)
        case "HEAD":
            let exists = receivedFiles[request.path] != nil
            send(connection, status: exists ? 200 : 404, reason: exists ? "OK" : "Not Found", headers: [:], body: Data())
        default:
            send(connection, status: 405, reason: "Method Not Allowed", headers: [:], body: Data())
        }
    }

    private func handlePropfind(_ request: Request, connection: NWConnection) {
        let normalized = request.path.hasSuffix("/") ? String(request.path.dropLast()) : request.path
        let existsAsCollection = existingCollections.contains(normalized) || existingCollections.contains(request.path)
        let isCollection = existsAsCollection
        guard existsAsCollection || receivedFiles[request.path] != nil else {
            send(connection, status: 404, reason: "Not Found", headers: [:], body: Data())
            return
        }

        var entries: [(href: String, collection: Bool, size: Int?, modified: String)] = []
        if isCollection {
            entries.append((request.path, true, nil, Self.httpDate()))
            if request.headers["depth"] != "0" {
                let prefix = request.path.hasSuffix("/") ? request.path : request.path + "/"
                for (path, file) in receivedFiles where path.hasPrefix(prefix) {
                    if path.dropFirst(prefix.count).contains("/") { continue }
                    entries.append((path, false, file.data.count, Self.httpDate()))
                }
            }
        } else {
            entries.append((request.path, false, receivedFiles[request.path]?.data.count, Self.httpDate()))
        }

        var xml = #"<?xml version="1.0" encoding="utf-8"?>"# + "\n<D:multistatus xmlns:D=\"DAV:\">"
        for entry in entries {
            xml += "<D:response><D:href>\(entry.href)</D:href><D:propstat><D:prop>"
            if entry.collection {
                xml += "<D:resourcetype><D:collection/></D:resourcetype>"
            } else {
                xml += "<D:resourcetype/>"
                xml += "<D:getcontentlength>\(entry.size ?? 0)</D:getcontentlength>"
                xml += "<D:getlastmodified>\(entry.modified)</D:getlastmodified>"
            }
            xml += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        }
        xml += "</D:multistatus>"
        send(connection, status: 207, reason: "Multi-Status", headers: [
            "Content-Type": "application/xml; charset=utf-8",
        ], body: Data(xml.utf8))
    }

    private func handleMkcol(_ request: Request, connection: NWConnection) {
        let path = request.path.hasSuffix("/") ? String(request.path.dropLast()) : request.path
        if existingCollections.contains(path) {
            send(connection, status: 405, reason: "Method Not Allowed", headers: [:], body: Data())
            return
        }
        // 模拟真实服务器：父目录不存在时返回 409
        let parent = (path as NSString).deletingLastPathComponent
        let parentWithSlash = parent.hasSuffix("/") ? parent : parent + "/"
        guard existingCollections.contains(parent) || existingCollections.contains(parentWithSlash) || parent == "/dav" else {
            send(connection, status: 409, reason: "Conflict", headers: [:], body: Data())
            return
        }
        existingCollections.insert(path)
        createdCollections.insert(path)
        send(connection, status: 201, reason: "Created", headers: [:], body: Data())
    }

    private func handlePut(_ request: Request, connection: NWConnection) {
        if failOnPut {
            send(connection, status: 500, reason: "Internal Server Error", headers: [:], body: Data("boom".utf8))
            return
        }
        // 父目录必须存在
        let parent = (request.path as NSString).deletingLastPathComponent
        let parentWithSlash = parent.hasSuffix("/") ? parent : parent + "/"
        guard existingCollections.contains(parentWithSlash) || existingCollections.contains(parent) else {
            send(connection, status: 409, reason: "Conflict", headers: [:], body: Data())
            return
        }
        let existed = receivedFiles[request.path] != nil
        receivedFiles[request.path] = ReceivedFile(path: request.path, data: request.body)
        send(connection, status: existed ? 204 : 201, reason: existed ? "No Content" : "Created", headers: [:], body: Data())
    }

    private func handleGet(_ request: Request, connection: NWConnection) {
        guard let file = receivedFiles[request.path] else {
            send(connection, status: 404, reason: "Not Found", headers: [:], body: Data())
            return
        }
        send(connection, status: 200, reason: "OK", headers: [
            "Content-Type": "application/octet-stream",
            "Content-Length": String(file.data.count),
        ], body: file.data)
    }

    private func handleDelete(_ request: Request, connection: NWConnection) {
        guard receivedFiles.removeValue(forKey: request.path) != nil else {
            send(connection, status: 404, reason: "Not Found", headers: [:], body: Data())
            return
        }
        send(connection, status: 204, reason: "No Content", headers: [:], body: Data())
    }

    // MARK: - 底层写响应

    private func send(_ connection: NWConnection, status: Int, reason: String,
                      headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func httpDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }
}
