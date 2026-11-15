# WebDAV 修复说明

## 一、原则

保留原作者的远程目录结构与备份文件格式，**不做**增量同步、分片上传、新协议、多端冲突解决。
所有改动都在「客户端怎么把这份 zip 可靠地送到那个目录」这一层。

- 远程根目录仍是 `SwashbucklerDiary/`；
- 文件名仍是 `SwashbucklerDiaryBackup_<yyyyMMddHHmmss>_v<版本>.zip`；
- 备份内容仍是原格式（见 `DATA_MIGRATION.md`）。

因此 Android / Windows 端看到的远程文件和以前完全一样。

## 二、原有的实现

```csharp
// WebDAV.cs（原实现，节选）
public async Task UploadAsync(string destFileName, Stream stream)
{
    var result = await webDavClient.PutFile(destFileName, stream);
    if (!result.IsSuccessful) throw new WebDAVException(result.ToString());
}

public async Task Set(string? baseAddress, ...)
{
    var webDavClient = GetWebDavClient(uri, userName, password);
    var result = await webDavClient.Propfind($"{webDavFolderName}/");
    if (!result.IsSuccessful)
    {
        if (result.StatusCode != 404) throw ...;
        var result2 = await webDavClient.Mkcol(webDavFolderName);   // 只建一级
        if (!result2.IsSuccessful) throw ...;
    }
    ...
}
```

`HttpClient.BaseAddress` 的相对路径语义、`WebDav.Client` 的流式上传行为、
以及 `IsSuccessful` 的宽泛判断，是后面所有问题的根源。

## 三、逐条修复

| # | 问题 | 根因 | 原生端做法 | 测试 |
| --- | --- | --- | --- | --- |
| 1 | 服务器连接失败 | 地址缺协议头、缺结尾斜杠、指向非 WebDAV 端点 | `normalizeBaseAddress`：无协议补 `https://`；**有非 http(s) 协议直接拒绝**；统一补结尾 `/`；用 PROPFIND 而不是 GET 探测 | `testInvalidAddressRejected`、`testBaseAddressNormalization` |
| 2 | 身份验证失败 | 依赖 challenge 往返；部分服务器/反代不接受二次握手 | 每个请求都带 `Authorization: Basic`（预认证），同时保留 `URLSession` 的 challenge 兜底 | `testConnectFailsWithWrongPassword` |
| 3 | 远程目录不存在 | 只 `MKCOL` 一级，父目录缺失时服务器返回 409 直接失败 | `ensureCollection` 递归：409 就先补父级再重试（深度上限 6 防环） | `testConnectCreatesMissingFolder` |
| 4 | 中文路径/特殊字符 | 直接拼字符串，未逐段编码 | 路径按 `/` 分段后逐段百分号编码 | `testUploadWithChineseFileName`、`testPercentEncodingForChineseName` |
| 5 | 文件名/路径拼接错误 | 依赖 `BaseAddress` 相对路径语义，base 无结尾 `/` 时会替换掉最后一段路径 | 每次请求都由 `url(for:)` 拼绝对 URL，不依赖任何相对路径语义 | `testUploadCreatesRemoteFileAndVerifiesSize` |
| 6 | 大文件上传失败 | 整包读入内存 + 默认 100 秒资源超时 | `uploadTask(with:fromFile:)` 直接从文件流式上传；`timeoutIntervalForResource` 提到 6 小时 | `testUploadLargeFile`（8 MB） |
| 7 | 上传过程连接中断 | 前台会话，切后台即被挂起 | 传输走 `URLSessionConfiguration.background`，由系统守护进程接管 | 见「后台传输」一节 |
| 8 | HTTP 超时 | 元数据与传输共用一个短超时 | 元数据 30 秒 / 传输请求 120 秒且资源上限 6 小时 | — |
| 9 | 非预期状态码 | `IsSuccessful` 一刀切 | 逐动词判断：PUT 接受 200/201/204；PROPFIND 必须 207；MKCOL 接受 200/201/204/405；其余抛 `serverError(status:path:body:)` | `testUploadSurfacesServerError` |
| 10 | 上传成功却误判失败 | `IsSuccessful` 覆盖不到 207/3xx 等；流关闭时机问题 | PUT 后回读 `Content-Length` 做尺寸校验；服务器不支持校验时**跳过而不是报错** | `testUploadCreatesRemoteFileAndVerifiesSize` |
| 11 | 重复上传/覆盖异常 | 目标已存在时部分服务器返回 204 而非 201 | 201/204 都算成功；文件名带时间戳天然不冲突 | `testUploadTwiceOverwrites` |
| 12 | 上传中进入后台 | 前台 URLSession 被挂起 | 后台会话 + `AppDelegate.handleEventsForBackgroundURLSession` 交还完成回调 | CI/真机验证 |
| 13 | 取消后状态错乱 | 取消被当成普通失败，或 continuation 泄漏 | `NSURLErrorCancelled` 映射成 `WebDAVError.cancelled`；`checkedContinuation` 按 `taskIdentifier` 一对一移除，不重复 resume | 代码审查 + 单测无崩溃 |
| 14 | 失败提示与日志 | 直接抛 `response.ToString()`，用户看不懂 | `WebDAVError` 六类中文文案；`NSURLErrorDomain` 常见码单独翻译；`Log.network` 记录请求路径、耗时、字节数（不含凭据） | 手工验证 |
| 15 | 内存占用过高 | 流被整体缓冲 | 上传/下载都是文件级，全程不把 zip 读进内存；图片解码另有 2200px 降采样 | `testUploadLargeFile` |

## 四、关键实现片段

### 递归建目录

```swift
private func ensureCollection(path: String, depth: Int) async throws {
    guard depth < 6 else { throw WebDAVError.folderCreationFailed(status: 409) }
    let probe = try await propfind(path: path + "/", depth: "0")
    if probe.statusCode == 207 || probe.statusCode == 200 { return }
    if probe.statusCode == 401 || probe.statusCode == 403 { throw WebDAVError.unauthorized }

    let (data, response) = try await metadataSession.data(for: mkcolRequest)
    switch http.statusCode {
    case 200, 201, 204: return
    case 405: return                       // 已存在
    case 409:                              // 父目录缺失 → 补父级再重试
        try await ensureCollection(path: parent(path), depth: depth + 1)
        try await ensureCollection(path: path, depth: depth + 1)
    case 401, 403: throw WebDAVError.unauthorized
    default: throw WebDAVError.serverError(...)
    }
}
```

### 上传后校验

```swift
private func verifyUpload(path: String, expectedSize: Int64) async throws {
    // 服务器不支持单文件 PROPFIND / 不返回 Content-Length 时跳过，而不是误报失败
    guard let response = try? await propfind(path: path, depth: "0"),
          response.statusCode == 207 else { return }
    guard let remote = parse(response).first(where: { !$0.isCollection }),
          let remoteSize = remote.contentLength else { return }
    guard remoteSize == expectedSize else {
        throw WebDAVError.uploadVerificationFailed(expected: expectedSize, actual: remoteSize)
    }
}
```

### 后台传输

```swift
let config: URLSessionConfiguration = useBackgroundSession
    ? .background(withIdentifier: "com.yucore.swashbucklerdiary.webdav")
    : .default              // 单元测试环境没有后台调度器
```

`AppDelegate` 里的 `handleEventsForBackgroundURLSession` 会保存系统给的 completionHandler，
在 App 回到前台时调用，避免系统认为客户端没处理完而降低调度优先级。

## 五、修复过程中发现的两个隐蔽 bug

这两条不在原始清单里，是写测试时暴露出来的：

**1. XML 命名空间前缀导致远程列表恒为空。**
`XMLParser` 默认不处理命名空间，`elementName` 拿到的是 `D:response` 而不是 `response`。
原来按 `response` 匹配，遇到真实服务器（普遍写成 `<D:response>` 或 `<d:response>`）就一个都解析不出来，
表现为「上传成功但列表永远空」。修法是取 `lastIndex(of: ":")` 之后的部分再小写比较。
修完 `testListBackupsReturnsZipOnly` 才从失败转通过。

**2. 上传后校验把目录也算进去。**
PROPFIND depth 0 对目录返回的条目没有 `getcontentlength`，
早期版本会把 `nil` 当 0 处理从而误报「尺寸不一致」。现在显式 `filter { !$0.isCollection }`。

## 六、测试矩阵

全部跑在进程内模拟服务器上（`Tests/LocalWebDAVServer.swift`，基于 `NWListener`），
不依赖外网、不需要真实账号，可重复执行。

| 用例 | 覆盖点 |
| --- | --- |
| `testConnectCreatesMissingFolder` | 目录不存在时自动 MKCOL |
| `testConnectFailsWithWrongPassword` | 401 → `unauthorized` |
| `testInvalidAddressRejected` | 空地址、空账号拒绝 |
| `testUploadCreatesRemoteFileAndVerifiesSize` | 基本上传 + 尺寸校验 |
| `testUploadWithChineseFileName` | 中文文件名端到端 |
| `testUploadLargeFile` | 8 MB 流式上传 |
| `testUploadTwiceOverwrites` | 重复上传覆盖 |
| `testUploadSurfacesServerError` | 500 → `serverError` 且状态码正确 |
| `testListBackupsReturnsZipOnly` | 列表过滤 + 排序 + 命名空间解析 |
| `testListWhenFolderExistsButEmpty` | 空目录不报错 |
| `testDownloadReturnsSameBytes` | 下载字节一致 |
| `testDeleteRemovesRemoteFile` | 删除 |
| `testUploadedZipIsValidArchive` | 上传→下载→zip 仍可解析（端到端） |

结果：13 / 13 通过。

## 七、没有做的事（以及为什么）

- **不做增量同步**：需求明确要求保持现有设计，且日记的长期同步架构尚未确定。
- **不做分片/断点续传**：会改变远程文件形态，破坏与其它端的兼容。
- **不并发上传多份**：一次一份更容易保证「上传的是当前这份数据库」的语义。
- **不改目录结构**：`SwashbucklerDiary/` 是跨端契约的一部分。
