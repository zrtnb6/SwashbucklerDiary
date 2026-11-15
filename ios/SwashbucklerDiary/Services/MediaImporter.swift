import Foundation
import CommonCrypto
import PhotosUI
import SwiftUI
import AVFoundation

/// 媒体文件导入器。
///
/// 落盘规则与原项目一致：
/// - 默认按内容 SHA-256 命名（相同文件天然去重），保存在 `Assets/<Kind>/`；
/// - 开启「使用原始文件名」时，放到 `Assets/<Kind>/<随机目录>/<原文件名>`；
/// - 返回的 URI 形如 `appdata/Image/<hash>.jpg`，可直接写进 Markdown。
struct MediaImporter {
    static let shared = MediaImporter()

    enum ImportError: LocalizedError {
        case unsupported
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return "不支持的文件类型"
            case .copyFailed(let name): return "复制 \(name) 失败"
            }
        }
    }

    /// 从文件 URL 导入（文档选择器 / 相机 / 录音都走这里）。
    func importFile(at sourceURL: URL) throws -> MediaResource {
        let kind = MediaKind.from(fileExtension: sourceURL.pathExtension)
        guard kind != .unknown else { throw ImportError.unsupported }

        let fileManager = FileManager.default
        let directory = AppPaths.assetsDirectory(for: kind)
        AppPaths.ensure(directory)

        let useOriginalName = SettingsStore.shared.settings.originalFileName
        let targetURL: URL
        if useOriginalName {
            let folder = directory.appendingPathComponent(UUID().uuidString.replacingOccurrences(of: "-", with: ""), isDirectory: true)
            AppPaths.ensure(folder)
            targetURL = folder.appendingPathComponent(sourceURL.lastPathComponent)
        } else {
            let hash = try Self.sha256(of: sourceURL)
            targetURL = directory.appendingPathComponent(hash + "." + sourceURL.pathExtension.lowercased())
        }

        let needsCopy = useOriginalName || !fileManager.fileExists(atPath: targetURL.path)
        if needsCopy {
            if fileManager.fileExists(atPath: targetURL.path) {
                try? fileManager.removeItem(at: targetURL)
            }
            do {
                try fileManager.copyItem(at: sourceURL, to: targetURL)
            } catch {
                throw ImportError.copyFailed(sourceURL.lastPathComponent)
            }
        }

        let uri = AppPaths.relativeURI(for: targetURL)
        Log.info("已导入媒体：\(uri)", .storage)
        return MediaResource(resourceUri: uri, resourceType: kind)
    }

    /// 把 Data 写成临时文件再导入，供 PhotosPicker / 相机使用。
    func importData(_ data: Data, fileExtension: String, suggestedName: String? = nil) throws -> MediaResource {
        let temp = AppPaths.workingDirectory("Media").appendingPathComponent(
            suggestedName ?? (UUID().uuidString + "." + fileExtension)
        )
        try data.write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try importFile(at: temp)
    }

    /// 导出照片/视频到系统相册。
    func saveToPhotoLibrary(_ resource: MediaResource) async throws {
        guard let url = resource.fileURL else { throw ImportError.unsupported }
        try await PHPhotoLibrary.shared().performChanges {
            if resource.resourceType == .video {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
        }
    }

    /// 删除媒体文件（仅当没有任何日记引用时由调用方触发）。
    func deleteFile(for resource: MediaResource) {
        guard let url = resource.fileURL else { return }
        try? FileManager.default.removeItem(at: url)
        // 「原始文件名」模式下目录里只有这一个文件，顺手清理空目录
        let parent = url.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Hasher()
        while case let chunk = try handle.read(upToCount: 1024 * 1024), let data = chunk, !data.isEmpty {
            hasher.update(data)
        }
        return hasher.finalize()
    }
}

/// 增量 SHA-256，避免把大文件一次性读进内存。
struct SHA256Hasher {
    private var context = CC_SHA256_CTX()

    init() {
        CC_SHA256_Init(&context)
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            CC_SHA256_Update(&context, base, CC_LONG(data.count))
        }
    }

    mutating func finalize() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
