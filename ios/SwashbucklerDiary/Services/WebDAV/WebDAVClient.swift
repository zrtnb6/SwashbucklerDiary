import Foundation

/// 原生 WebDAV 客户端。
///
/// 行为对齐原项目（远程根目录固定为 `SwashbucklerDiary/`，文件名格式不变），
/// 但把原来基于 `WebDav.Client` 的实现换成了 URLSession，并逐条修掉了已知缺陷：
///
/// 1. **相对路径拼接**：原实现用 `PutFile("文件名")` 相对 `BaseAddress`，当服务器地址
///    不以 `/` 结尾时会把最后一段路径替换掉。这里统一规范化 base 并在每次请求前
///    重新拼出绝对 URL，不依赖任何「相对路径语义」。
/// 2. **递归建目录**：`MKCOL SwashbucklerDiary` 在父目录不存在时返回 409，原实现直接失败。
///    这里遇到 409 会自底向上补齐父级。
/// 3. **预认证**：始终带上 `Authorization: Basic`，同时保留 challenge 兜底，
///    避免部分服务端在第一个请求上返回 401 导致误判「配置失败」。
/// 4. **大文件内存**：上传走 `uploadTask(fromFile:)`、下载走 `downloadTask`，
///    整个备份文件不会读进内存；并且交给系统后台会话，App 进入后台仍可继续。
/// 5. **超时**：元数据请求 30s，传输请求不设资源上限（默认 100s 对大备份必然超时）。
/// 6. **状态码语义**：PUT 接受 200/201/204，PROPFIND 必须 207，MKCOL 接受 201/405。
///    不看 `isSuccess` 这种模糊判断。
/// 7. **上传后校验**：PUT 成功后回读 Content-Length，尺寸不一致就报错，
///    既避免「假成功」，也避免把真成功误判成失败。
final class WebDAVClient: NSObject {
    static let remoteFolderName = "SwashbucklerDiary"

    private let baseURL: URL
    private let credential: URLCredential
    private let authorizationHeader: String

    private let metadataSession: URLSession
    private var transferSession: URLSession!

    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]

    var progressHandler: ((Double) -> Void)?

    // MARK: - 初始化

    init(configuration: WebDAVConfiguration, useBackgroundSession: Bool = true) throws {
        guard let url = WebDAVClient.normalizeBaseAddress(configuration.serverAddress) else {
            throw WebDAVError.invalidAddress
        }
        let account = configuration.account.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty, !configuration.password.isEmpty else {
            throw WebDAVError.missingCredentials
        }
        baseURL = url
        credential = URLCredential(user: account, password: configuration.password, persistence: .none)
        let raw = "\(account):\(configuration.password)"
        authorizationHeader = "Basic " + Data(raw.utf8).base64EncodedString()

        let metadataConfig = URLSessionConfiguration.ephemeral
        metadataConfig.timeoutIntervalForRequest = 30
        metadataConfig.timeoutIntervalForResource = 60
        metadataConfig.httpAdditionalHeaders = ["User-Agent": "SwashbucklerDiary-iOS/1.0"]
        metadataSession = URLSession(configuration: metadataConfig)

        super.init()

        let transferConfig: URLSessionConfiguration
        if useBackgroundSession {
            // 生产环境用后台会话：上传大备份时切到后台也不会被系统挂起
            transferConfig = URLSessionConfiguration.background(withIdentifier: "com.yucore.swashbucklerdiary.webdav")
        } else {
            // 单元测试环境没有后台调度器，用默认会话保持行为一致但可即时回调
            transferConfig = URLSessionConfiguration.default
        }
        transferConfig.timeoutIntervalForRequest = 120
        transferConfig.timeoutIntervalForResource = 60 * 60 * 6
        transferConfig.isDiscretionary = false
        transferConfig.sessionSendsLaunchEvents = true
        transferConfig.httpAdditionalHeaders = ["User-Agent": "SwashbucklerDiary-iOS/1.0"]
        transferSession = URLSession(configuration: transferConfig, delegate: self, delegateQueue: nil)
    }

    // MARK: - 公开接口

    /// 校验服务器可达性与认证，并确保远程目录存在。
    func connect() async throws {
        let response = try await propfind(path: WebDAVClient.remoteFolderName + "/", depth: "0")
        if response.statusCode == 207 { return }
        if response.statusCode == 404 {
            try await ensureFolder()
            return
        }
        throw mapFailure(response, path: WebDAVClient.remoteFolderName)
    }

    /// 列出远程备份 zip，按修改时间倒序。
    func listBackups() async throws -> [WebDAVFileInfo] {
        var response = try await propfind(path: WebDAVClient.remoteFolderName + "/", depth: "1")
        if response.statusCode == 404 {
            try await ensureFolder()
            response = try await propfind(path: WebDAVClient.remoteFolderName + "/", depth: "1")
        }
        guard response.statusCode == 207 else {
            throw mapFailure(response, path: WebDAVClient.remoteFolderName)
        }
        let items = WebDAVMultistatusParser.parse(response.data, basePath: baseURL.path)
        let folderPrefix = WebDAVClient.remoteFolderName.lowercased()
        return items
            .filter { !$0.isCollection }
            .filter { $0.name.lowercased().hasSuffix(".zip") }
            .filter { $0.href.lowercased().contains(folderPrefix) }
            .map { WebDAVFileInfo(name: $0.name, length: $0.contentLength, lastModified: $0.lastModified, href: $0.href) }
            .sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
    }

    /// 上传本地文件到 `SwashbucklerDiary/<fileName>`。
    /// - Parameter verify: 上传后回读远程大小做校验，默认开启。
    func upload(fileURL: URL, fileName: String, verify: Bool = true) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let localSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        try await ensureFolder()

        let path = "\(WebDAVClient.remoteFolderName)/\(fileName)"
        guard let url = url(for: path) else { throw WebDAVError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applyHeaders(&request, contentType: "application/zip")
        request.setValue(String(localSize), forHTTPHeaderField: "Content-Length")

        Log.info("WebDAV 上传开始：\(path)（\(localSize) 字节）", .network)
        let started = Date()
        _ = try await transfer(request: request, fileURL: fileURL)
        let elapsed = Date().timeIntervalSince(started)
        Log.info("WebDAV 上传完成：\(path) 用时 \(String(format: "%.1f", elapsed))s", .network)

        if verify {
            try await verifyUpload(path: path, expectedSize: localSize)
        }
    }

    /// 下载远程备份到本地临时文件。返回文件 URL 由调用方负责清理。
    func download(name: String) async throws -> URL {
        let path = "\(WebDAVClient.remoteFolderName)/\(name)"
        guard let url = url(for: path) else { throw WebDAVError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(&request)
        Log.info("WebDAV 下载开始：\(path)", .network)
        return try await transfer(request: request, fileURL: nil)
    }

    /// 删除远程备份。用于清理空间，不改变目录结构。
    func delete(name: String) async throws {
        let path = "\(WebDAVClient.remoteFolderName)/\(name)"
        guard let url = url(for: path) else { throw WebDAVError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyHeaders(&request)
        let (data, response) = try await metadataSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse("非 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) || http.statusCode == 404 else {
            throw WebDAVError.serverError(status: http.statusCode, path: path,
                                          body: String(data: data, encoding: .utf8))
        }
    }

    func cancelAll() {
        transferSession.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    // MARK: - 目录

    /// 逐级确保 `SwashbucklerDiary` 目录存在。父级缺失（409）时递归补建。
    private func ensureFolder() async throws {
        try await ensureCollection(path: WebDAVClient.remoteFolderName, depth: 0)
    }

    private func ensureCollection(path: String, depth: Int) async throws {
        guard depth < 6 else { throw WebDAVError.folderCreationFailed(status: 409) }

        let probe = try await propfind(path: path + "/", depth: "0")
        if probe.statusCode == 207 || probe.statusCode == 200 { return }
        if probe.statusCode != 404 {
            // 401 等认证问题直接抛出，不要盲目 MKCOL
            if probe.statusCode == 401 || probe.statusCode == 403 {
                throw WebDAVError.unauthorized
            }
        }

        guard let mkcolURL = url(for: path) else { throw WebDAVError.invalidAddress }
        var request = URLRequest(url: mkcolURL)
        request.httpMethod = "MKCOL"
        applyHeaders(&request)
        let (data, response) = try await metadataSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse("非 HTTP 响应")
        }
        switch http.statusCode {
        case 200, 201, 204:
            Log.info("已创建远程目录：\(path)", .network)
        case 405:
            // Method Not Allowed 通常表示目录已存在，视为成功
            return
        case 409:
            // 父目录不存在，先补父级再重试
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else {
                throw WebDAVError.folderCreationFailed(status: 409)
            }
            try await ensureCollection(path: parent, depth: depth + 1)
            try await ensureCollection(path: path, depth: depth + 1)
        case 401, 403:
            throw WebDAVError.unauthorized
        default:
            throw WebDAVError.serverError(status: http.statusCode, path: path,
                                          body: String(data: data, encoding: .utf8))
        }
    }

    private func verifyUpload(path: String, expectedSize: Int64) async throws {
        // 少量服务器不支持对文件做 depth 0 的 PROPFIND，此时跳过校验而不是误报失败。
        guard let response = try? await propfind(path: path, depth: "0"), response.statusCode == 207 else {
            Log.warning("上传校验被跳过（服务器不支持 PROPFIND 单文件）：\(path)", .network)
            return
        }
        let items = WebDAVMultistatusParser.parse(response.data, basePath: baseURL.path)
        guard let remote = items.first(where: { !$0.isCollection }) else {
            Log.warning("上传校验被跳过（响应无文件信息）：\(path)", .network)
            return
        }
        guard let remoteSize = remote.contentLength else {
            Log.warning("上传校验被跳过（服务器未返回 Content-Length）：\(path)", .network)
            return
        }
        guard remoteSize == expectedSize else {
            throw WebDAVError.uploadVerificationFailed(expected: expectedSize, actual: remoteSize)
        }
        Log.info("上传校验通过：\(path) \(remoteSize) 字节", .network)
    }

    // MARK: - 请求构造

    private func applyHeaders(_ request: inout URLRequest, contentType: String? = nil) {
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("SwashbucklerDiary-iOS/1.0", forHTTPHeaderField: "User-Agent")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    private func propfind(path: String, depth: String) async throws -> (statusCode: Int, data: Data) {
        guard let url = url(for: path) else { throw WebDAVError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        applyHeaders(&request)
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:displayname/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:resourcetype/>
          </d:prop>
        </d:propfind>
        """
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await metadataSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse("非 HTTP 响应")
        }
        return (http.statusCode, data)
    }

    private func mapFailure(_ response: (statusCode: Int, data: Data), path: String) -> Error {
        let body = String(data: response.data, encoding: .utf8)
        switch response.statusCode {
        case 401: return WebDAVError.unauthorized
        case 404: return WebDAVError.notFound(path)
        default:
            return WebDAVError.serverError(status: response.statusCode, path: path, body: body)
        }
    }

    /// 把远程相对路径转成绝对 URL，逐段做百分号编码。
    func url(for relativePath: String) -> URL? {
        let encoded = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { WebDAVClient.percentEncode(String($0)) }
            .joined(separator: "/")
        var text = baseURL.absoluteString
        if !text.hasSuffix("/") { text += "/" }
        return URL(string: text + encoded)
    }

    /// 传输（上传/下载）走后台会话，用 continuation 桥接到 async/await。
    private func transfer(request: URLRequest, fileURL: URL?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task: URLSessionTask
            if let fileURL {
                task = transferSession.uploadTask(with: request, fromFile: fileURL)
            } else {
                task = transferSession.downloadTask(with: request)
            }
            lock.lock()
            continuations[task.taskIdentifier] = continuation
            lock.unlock()
            task.resume()
        }
    }

    // MARK: - 地址规范化

    /// 统一补上结尾 `/`，并校验 scheme。
    static func normalizeBaseAddress(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if let range = text.range(of: "://") {
            // 已经带了协议：只接受 http / https
            let scheme = text[text.startIndex..<range.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
        } else {
            text = "https://" + text
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            return nil
        }
        if url.absoluteString.hasSuffix("/") { return url }
        return URL(string: url.absoluteString + "/")
    }

    static func percentEncode(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}

// MARK: - 后台会话代理

extension WebDAVClient: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let continuation else { return }

        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                continuation.resume(throwing: WebDAVError.cancelled)
            } else {
                continuation.resume(throwing: error)
            }
            return
        }

        if let http = task.response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299:
                break
            case 401, 403:
                continuation.resume(throwing: WebDAVError.unauthorized)
                return
            case 404:
                continuation.resume(throwing: WebDAVError.notFound(task.originalRequest?.url?.path ?? ""))
                return
            default:
                continuation.resume(throwing: WebDAVError.serverError(
                    status: http.statusCode,
                    path: task.originalRequest?.url?.path ?? "",
                    body: nil
                ))
                return
            }
        }

        // 上传没有文件输出，返回一个占位 URL 表示成功
        if task is URLSessionUploadTask {
            continuation.resume(returning: URL(fileURLWithPath: "/dev/null"))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 系统会在回调返回后删除临时文件，必须立刻搬走
        let destination = AppPaths.workingDirectory("WebDAVDownload")
            .appendingPathComponent(UUID().uuidString + ".zip")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Log.error("WebDAV 下载临时文件搬运失败：\(error.localizedDescription)", .network)
        }

        lock.lock()
        let continuation = continuations.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        continuation?.resume(returning: destination)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { [weak self] in
            self?.progressHandler?(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            self?.progressHandler?(progress)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
            || challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest
            || challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodDefault {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - PROPFIND 解析

struct WebDAVResource {
    var href: String
    var name: String
    var isCollection: Bool
    var contentLength: Int64?
    var lastModified: Date?
}

enum WebDAVMultistatusParser {
    static func parse(_ data: Data, basePath: String) -> [WebDAVResource] {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            Log.warning("PROPFIND 响应解析失败：\(delegate.errorText ?? "unknown")", .network)
            return []
        }
        return delegate.resources.map { resource in
            var value = resource
            value.name = decodeName(resource.href)
            return value
        }
    }

    private static func decodeName(_ href: String) -> String {
        var path = href
        if let url = URL(string: href) { path = url.path }
        let decoded = path.removingPercentEncoding ?? path
        var trimmed = decoded
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return (trimmed as NSString).lastPathComponent
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var resources: [WebDAVResource] = []
        var errorText: String?

        private var current: WebDAVResource?
        private var currentElement = ""
        private var textBuffer = ""
        private var isInPropstat = false
        private var propstatStatus = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let name = Self.localName(elementName)
            currentElement = name
            textBuffer = ""
            switch name {
            case "response":
                current = WebDAVResource(href: "", name: "", isCollection: false,
                                         contentLength: nil, lastModified: nil)
            case "propstat":
                isInPropstat = true
                propstatStatus = ""
            case "collection":
                current?.isCollection = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let name = Self.localName(elementName)
            let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

            switch name {
            case "href":
                if current?.href.isEmpty ?? false {
                    current?.href = text
                }
            case "getcontentlength":
                if !isInPropstat || propstatStatus.contains("200") {
                    current?.contentLength = Int64(text)
                }
            case "getlastmodified":
                if let date = parseHTTPDate(text) {
                    current?.lastModified = date
                }
            case "status":
                if isInPropstat { propstatStatus = text }
            case "propstat":
                isInPropstat = false
            case "response":
                if let current, !current.href.isEmpty {
                    resources.append(current)
                }
                current = nil
            default:
                break
            }
            textBuffer = ""
        }

        /// 去掉 XML 命名空间前缀。真实服务器普遍写成 `<D:response>`，
        /// 不做归一化会导致所有元素都匹配不上，远程列表恒为空。
        static func localName(_ raw: String) -> String {
            if let index = raw.lastIndex(of: ":") {
                return String(raw[raw.index(after: index)...]).lowercased()
            }
            return raw.lowercased()
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            errorText = parseError.localizedDescription
        }

        private func parseHTTPDate(_ text: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter.date(from: text)
        }
    }
}
