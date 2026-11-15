import Foundation

/// WebDAV 远程文件信息。
struct WebDAVFileInfo: Identifiable, Hashable {
    var name: String
    var length: Int64?
    var lastModified: Date?
    /// 服务端返回的原始 href，删除/下载时按原样回传，避免因编码差异拼错路径。
    var href: String

    var id: String { href }

    var readableSize: String {
        guard let length else { return "未知大小" }
        return ByteCountFormatter.string(fromByteCount: length, countStyle: .file)
    }
}

enum WebDAVError: LocalizedError {
    case invalidAddress
    case missingCredentials
    case unauthorized
    case notFound(String)
    case serverError(status: Int, path: String, body: String?)
    case folderCreationFailed(status: Int)
    case invalidResponse(String)
    case uploadVerificationFailed(expected: Int64, actual: Int64?)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "服务器地址无效，请填写完整的 http:// 或 https:// 地址"
        case .missingCredentials:
            return "请填写账号和密码"
        case .unauthorized:
            return "身份验证失败，请检查账号或密码（部分服务需要使用「应用密码」）"
        case .notFound(let path):
            return "远程路径不存在：\(path)"
        case .serverError(let status, let path, let body):
            var text = "服务器返回 \(status)（\(path)）"
            if let body, !body.isEmpty {
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count <= 180 { text += "：\(trimmed)" }
            }
            return text
        case .folderCreationFailed(let status):
            return "无法创建远程目录（HTTP \(status)）。请确认账号对该路径有写入权限"
        case .invalidResponse(let reason):
            return "服务器响应无法解析：\(reason)"
        case .uploadVerificationFailed(let expected, let actual):
            let actualText = actual.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知"
            let expectedText = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            return "上传后校验失败：本地 \(expectedText)，远程 \(actualText)"
        case .cancelled:
            return "操作已取消"
        }
    }

    var isRetryable: Bool {
        if case .serverError(let status, _, _) = self {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        return false
    }
}

/// WebDAV 配置（对应原项目 `WebDavConfigForm` 的 JSON 结构）。
struct WebDAVConfiguration: Codable, Equatable {
    var serverAddress: String = ""
    var account: String = ""
    var password: String = ""

    enum CodingKeys: String, CodingKey {
        case serverAddress = "ServerAddress"
        case account = "Account"
        case password = "Password"
    }

    var isConfigured: Bool {
        !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func parse(_ json: String) -> WebDAVConfiguration? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WebDAVConfiguration.self, from: data)
    }
}
