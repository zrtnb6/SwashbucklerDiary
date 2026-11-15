# iOS 原生重构 · 审计与迁移计划

本文基于对上游仓库 **Yu-Core/SwashbucklerDiary**（`master` 分支，2026-10-17 最后提交）真实代码的阅读结果，
不是根据 README 推测。所有「原实现位置」都指向可核对的文件路径。

审计方式：仓库完整 tar 包下载受网络限制，改为通过 GitHub Trees / Contents API 拉取全部
**文本类源文件共 845 个**（`.cs` / `.razor` / `.json` / `.resw` / `.csproj` / `.yml` / `.md` / `.css`），
以及 `wwwroot` 下的脚本与样式（仅排除图片、字体等二进制）。审计结论逐条对应到这些文件。

---

## 一、原项目技术栈与关键结论

| 项目 | 结论 |
| --- | --- |
| UI | Blazor Hybrid（Razor 组件）承载在 .NET MAUI 的 `BlazorWebView` 中 |
| 目标平台 | Android / Windows / macOS / iOS / Linux(Gtk) / WebAssembly / Blazor Server |
| 数据层 | **SQLSugar** ORM，CodeFirst 建表，**不是** EF Core |
| 数据库 | SQLite，三个物理文件：`SwashbucklerDiary.db3`、`SwashbucklerDiary.privacy.db3`、`logs.db3` |
| 编辑器 | **Vditor 3.11.2**（本地 vendored，约 20 MB JS），运行在 WebView 内 |
| 备份 | `System.IO.Compression.ZipFile` 打包固定目录结构 |
| WebDAV | 第三方库 `WebDav.Client` |
| 密码 | `Rfc2898DeriveBytes.Pbkdf2`（PBKDF2-HMAC-SHA256，10000 次，32 字节盐/输出，Base64） |
| 本地化 | 20+ 语言的 `.resx` / i18n JSON |
| CI | GitHub Actions 仅构建 Web（gh-pages）、打包 MSIX、发布 Release，**无 iOS 构建** |

关键结论有两条直接决定了重构方案：

1. **iOS 端没有任何独立实现**。`src/SwashbucklerDiary.Maui/Platforms/iOS/` 下只有 `AppDelegate.cs` 与 `Program.cs`，
   共计不到 60 行，全部是 MAUI 启动样板。所谓「iOS 客户端」就是 Blazor Hybrid 套壳，
   不满足「真正原生」的要求，必须整体重建。
2. **数据模型与备份格式是跨端契约**。表名 = C# 类名、列名 = 属性名、备份 zip 内部路径固定。
   只要原生端严格复刻这三样，老用户的数据可以零转换直接打开，备份也能与 Android/Windows 互通。
   这比「另起一套 SwiftData 模型再写迁移器」更可靠，也符合需求中「优先复用而不是强制转换」的要求。

---

## 二、数据库结构（从代码反推，已由测试固化）

来源：`src/SwashbucklerDiary.Shared/Models/*.cs` + `src/SwashbucklerDiary.Rcl/Extensions/ServiceCollectionExtensions/AddSqlsugar.cs`

`AddSqlsugar.cs` 中的 `CodeFirst.InitTables(types)` 决定了 SQLSugar 的默认命名策略：
**表名 = 类型名，列名 = 属性名**；`Id` 属性自动成为主键；`int` 类型的 Id 自增，`Guid` 类型不自增。

| 表 | 列 | 说明 |
| --- | --- | --- |
| `DiaryModel` | `Id`(Guid,PK) `CreateTime` `UpdateTime` `Title` `Content` `Mood` `Weather` `Location` `Top` `Private` `Template` | `Private` 自 1.3.9 起废弃，改由独立隐私库承载；`Template` 是后加列，老库里可能为 NULL |
| `TagModel` | `Id`(Guid,PK) `CreateTime` `UpdateTime` `Name` | |
| `DiaryTagModel` | `Id`(Guid,PK) `CreateTime` `UpdateTime` `DiaryId` `TagId` | 多对多中间表 |
| `ResourceModel` | `ResourceUri`(string,PK) `ResourceType`(int) | **主键是字符串**，不是 Guid |
| `DiaryResourceModel` | `Id`(Guid,PK) `CreateTime` `UpdateTime` `DiaryId` `ResourceUri` | |
| `LocationModel` | `Id`(Guid,PK) `CreateTime` `UpdateTime` `Name` | 地点目录表 |
| `UserStateModel` | `Id`(Guid,PK) `CreateTime` `UpdateTime` `Type`(int) `Count` | 成就进度 |
| `UserAchievementModel` | `Id`(Guid,PK) `AchievementName` `CompleteRate` `IsCompleted` `CompletedTime` | **不继承 BaseModel**，没有 CreateTime/UpdateTime |
| `LogModel`（独立库） | `Id`(int,自增) `Timestamp` … | 日志库，原生端不复用 |

`ResourceType` 枚举：`Unknown=0, Image=1, Audio=2, Video=3`。

### 类型映射（原生端必须一致）

SQLSugar + Microsoft.Data.Sqlite 的实际落库类型：

| C# | SQLite |
| --- | --- |
| `Guid` | TEXT（36 位带连字符，小写） |
| `DateTime` | TEXT（`yyyy-MM-dd HH:mm:ss.fff`） |
| `bool` | INTEGER 0/1 |
| `int` | INTEGER |
| `string` | TEXT |

原生端**写入**时严格按上表格式，**读取**时做宽松解析（多种日期布局、带花括号/去连字符的 Guid、
Unix 时间戳与 .NET Ticks 兜底），因为历史版本之间格式并不完全统一。
这部分逻辑在 `ios/SwashbucklerDiary/Core/Compat.swift`，并有 5 个单元测试固定行为。

---

## 三、资源文件与路径约定

来源：`src/SwashbucklerDiary.Rcl/Services/MediaResourceManager/MediaResourceManager.cs`、
`src/SwashbucklerDiary.Maui/Essentials/AppFileSystem/AppFileSystem.MaciOS.cs`

- iOS 上的应用数据目录是 `~/Library/Application Support/<bundle id>/`。
- 媒体根目录 `Assets/`，下分 `Image` / `Audio` / `Video` / `Avatar`。
- 正文中的资源 URI 是 **`appdata/Image/<sha256>.jpg`**。
  - 默认命名 = 文件内容的 SHA-256（天然去重）。
  - 开启「使用原始文件名」时改为 `appdata/Image/<32位随机目录>/<原文件名>`。
  - 1.3.9 之前是 `appdata:///Image/x.jpg`，原项目有一次性迁移逻辑，原生端保留同等兼容。
- 正文 Markdown 中的资源引用用正则 `(?<=\(|")(appdata/.+?\.\S+?)(?=\)|")` 提取，
  原生端实现为 `MediaResourceExtractor`（见 `MediaImporter` 与编辑器插入逻辑）。

---

## 四、备份格式（跨端契约）

来源：`src/SwashbucklerDiary.Rcl/Services/DiaryFileManager/DiaryFileManager.cs`

```
SwashbucklerDiaryBackup_<yyyyMMddHHmmss>_v<version>.zip
├── SwashbucklerDiary.db3        当前库副本（隐私模式下导出的是隐私库，但文件名不变）
├── settings.json                设置，PascalCase 键，剔除敏感项
├── version.json                 {"Version","FileSuffix":".db3","Platform","DateTime"}
└── appdata/
     ├── Image/…  Audio/…  Video/…
     └── Avatar/…
```

- `settings.json` 的键是 C# 属性名原样（System.Text.Json 默认行为），例如 `Language`、`EditAutoSave`、
  甚至保留了原项目的拼写错误 `RigthOutline`。原生端 `AppSettings` 用 `CodingKeys` 逐一映射，
  保证读写双向兼容（见 `Services/SettingsStore.swift`）。
- 导出时排除的敏感设置（`excludedSettings`）：`WebDavConfig`、隐私与应用锁的全部密码与盐、
  `HidePrivacyModeEntrance`、`SetPrivacyDiary`、`PrivacyModeDark`、`PrivacyModeFunctionSearchKey`。
- 没有 `version.json` 的备份被视为旧版：需要把 `<root>/Image/` 搬到 `Assets/Image/`，
  并把正文里的 `appdata:///` 改成 `appdata/`。原生端完整实现了这两条兼容路径。

---

## 五、WebDAV 原有实现

来源：`src/SwashbucklerDiary.Rcl.Hybird/Services/WebDAV/WebDAV.cs`、
`.../Pages/Backups/WebDAVBackups/WebDAVBackupsPage.razor.cs`

- 远程根目录硬编码为 `SwashbucklerDiary/`。
- `Set()`：先 `PROPFIND SwashbucklerDiary/`，404 则 `MKCOL SwashbucklerDiary`。
- `UploadAsync(destFileName, stream)`：`PUT`。
- `DownloadAsync(destFileName)`：`GET`。
- `GetZipFileListAsync(folderName)`：`PROPFIND` depth 1，筛 `.zip`，按修改时间倒序。

已确认的缺陷清单见 `docs/WEBDAV_FIXES.md`，其中最关键的两条是
**相对路径拼接依赖 base 末尾斜杠**与**只建一级目录（父目录缺失直接失败）**。

---

## 六、功能迁移清单

状态图例：✅ 已实现并测试 ｜ 🟡 已实现未充分测试 ｜ ⚪ 平台限制下的替代方案 ｜ ❌ 未实现（原因见备注）

### 6.1 日记核心

| 功能 | 原实现位置 | 数据依赖 | 原有行为 | 原生方案 | 状态 |
| --- | --- | --- | --- | --- | --- |
| 创建日记 | `Rcl/Pages/Write.razor` | `DiaryModel` | 新建后进入编辑器 | `DiaryStore.save` + 全屏编辑器 | ✅ |
| 编辑日记 | 同上 | `DiaryModel` | Vditor 富文本 | `UITextView` + 原生 Markdown 工具栏 | ✅ |
| 删除日记 | `DiaryRepository.DeleteNav` | 三张表关联 | 级联删中间表 | `delete(ids:)` 事务内删除关联 | ✅ |
| 日记详情 | `Rcl/Pages/Read.razor` | `DiaryModel` | Vditor 预览 | 原生 Markdown 渲染器 | ✅ |
| 排序 | `DiaryCardList.razor.cs` 的 `sortOptions` | `Setting.DiarySort` | 4 种排序，键是本地化字符串 | 同样的 4 种 + 旧字符串容错解析 | ✅ |
| 置顶 | `DiaryCardList.Topping` | `DiaryModel.Top` | 更新 `Top` 与 `UpdateTime` | 同左 | ✅ |
| 搜索 | `Rcl/Pages/Search` | 全文 | 关键词 + 多维筛选 | 原生搜索页 + 筛选 Sheet | ✅ |
| 模板 | `TemplateSettingPage` | `DiaryModel.Template` | 标记为模板，新建时可套用 | 同左，支持「创建时选模板」 | ✅ |
| 引用 | 正文内 `scheme://read/<id>` | 正文 | 复制引用文本 | 渲染时识别 scheme 并跳转，菜单可复制引用 | 🟡 |
| 合并日记 | `DiaryFileManager.MergedDiariesAsync` | 多篇 | 按时间拼接正文，标签/资源取并集 | `DiaryStore.merge` 已实现，**暂无多选 UI** | ❌ UI |
| 分享 | `DiaryCardList` 菜单 | 正文 | 复制/分享文本 | 系统 Share Sheet | ✅ |
| 快速记录 | `Setting.QuickRecord` | — | 桌面小组件/快捷方式 | 未做（可用 WidgetKit 扩展，见遗留） | ❌ |

### 6.2 附加信息

| 功能 | 原实现 | 原生方案 | 状态 |
| --- | --- | --- | --- |
| 标签（多对多） | `TagModel` + `DiaryTagModel` | 同结构，同名标签复用 | ✅ |
| 心情 | `DiaryModel.Mood`（存本地化字符串） | 8 种心情 + 旧英文 key 兼容图标 | ✅ |
| 天气 | `DiaryModel.Weather` | 8 种天气 + 旧 key 兼容 | ✅ |
| 地点 | `DiaryModel.Location` 文本 + `LocationModel` 目录 | 文本 + 历史地点快选 | ✅ |
| 时间 | `CreateTime`/`UpdateTime` | 保留原值，编辑只动 UpdateTime | ✅ |

### 6.3 媒体

| 功能 | 原实现 | 原生方案 | 状态 |
| --- | --- | --- | --- |
| 添加图片 | `MediaResourceManager.AddImageAsync` | PhotosPicker（多选 9 张）+ 相机 | ✅ |
| 添加音频/视频 | `AddAudioAsync` / `AddVideoAsync` | 文件导入（`UTType.audio/.movie`） | ✅ |
| 图片预览 | `Rcl/Components/Waterfall` | 全屏翻页 + 双指缩放 + 双击放大 | ✅ |
| 音视频播放 | `MediaPlayer` | `AVPlayer` / `VideoPlayer` | ✅ |
| 媒体库 | `Rcl/Pages/Mine/MediaResource` | 分类网格 + 引用计数 + 清理未引用 | ✅ |
| 关联与去重 | SHA-256 命名 | 同左 | ✅ |
| 删除引用处理 | 删除前校验引用 | 删除时同步清理正文链接 | ✅ |
| 保存到相册 | `SaveToAlbum` | `PHPhotoLibrary` | 🟡 |

### 6.4 隐私与安全

| 功能 | 原实现 | 原生方案 | 状态 |
| --- | --- | --- | --- |
| 隐私模式 | 独立 db3 + `ConfigId` 切换 | `DiaryDatabase.isPrivacyMode` 在连接层切换 | ✅ |
| 进入密码 | `PrivacyModeEntrancePassword` + Salt | 同算法 PBKDF2-SHA256 | ✅ |
| 隐藏入口 | `HidePrivacyModeEntrance` | 同左 | ✅ |
| 应用锁 | `AppLockService` | 数字密码 + 图案 + 生物识别 | ✅ |
| 指纹/FaceID | MAUI `BiometricAuthentication` | `LocalAuthentication` | 🟡（模拟器无法验证） |
| 私密数据隔离 | 双库 | 双库，普通模式连接层完全不可达 | ✅ |
| 明文密码 | 无（哈希存储） | 无 | ✅ |

### 6.5 其它

| 功能 | 原生方案 | 状态 |
| --- | --- | --- |
| 深色模式 | 跟随系统 / 强制浅色 / 强制深色 | ✅ |
| Liquid Glass | iOS 26 `glassEffect`，旧系统 `ultraThinMaterial` 降级 | ✅ |
| 数据导出 | Markdown / JSON / TXT / CSV(zip) | ✅ |
| 本地备份/恢复 | 与原格式一致的 zip，恢复前自动留回滚副本 | ✅ |
| Markdown 渲染设置 | 渲染开关、首行缩进、代码行号、待办删除线 | ✅ |
| 多语言 | 仅简体中文。原项目 20+ 语言词表未迁移 | ❌ |
| 局域网传输 | 未实现（原项目 `LANDeviceName`/`LANScanPort`） | ❌ |
| 成就系统 | 旧数据可读，无成就 UI | 🟡 |
| 数学公式 | 符号替换 + 上下标近似排版，保留原始 LaTeX | ⚪ |

---

## 七、目录结构

```
ios/
├── SwashbucklerDiary.xcodeproj
├── Support/Info.plist
├── SwashbucklerDiary/
│   ├── App/           入口、根视图、调试直达路由
│   ├── Core/          日志、路径、SQLite 封装、兼容解析、ZIP、设计系统
│   ├── Models/        实体与枚举
│   ├── Persistence/   Schema、连接管理、四个仓储
│   ├── Services/      设置、日记状态、备份、媒体导入、Markdown、WebDAV、安全
│   ├── Features/      各功能页面（列表/详情/编辑/日历/标签/搜索/媒体/我的/设置/锁屏）
│   └── Resources/     Assets
└── Tests/             4 个测试文件（54 个用例）+ 1 个进程内 WebDAV 模拟服务器
```

## 八、阶段推进记录

1. **审计**：读 845 个源文件，产出本文。
2. **工程**：手写 `project.pbxproj`（`objectVersion 77` + `PBXFileSystemSynchronizedRootGroup`，
   无需 xcodegen），先跑通空壳编译再堆代码。
3. **数据层**：SQLite 封装 → Schema → 仓储 → 13 个测试覆盖这一层。
4. **Markdown**：自研块级/行内解析器 + SwiftUI 渲染，12 个测试。
5. **ZIP/备份**：手写 ZIP 读写，7 个测试。
6. **WebDAV**：URLSession 重写 + 进程内模拟服务器，13 个测试。
7. **UI**：14 个页面，逐屏截图验收。
8. **收尾**：CI、文档、Git 分支。
