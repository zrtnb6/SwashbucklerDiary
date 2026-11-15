# 数据兼容与迁移说明

## 一、结论先行

**本方案不迁移数据，而是直接复用原项目的数据库文件。**

原生 iOS 客户端读写的就是 `SwashbucklerDiary.db3`，表名、列名、类型、时间格式全部对齐
SQLSugar 的 CodeFirst 输出。因此：

- 老用户从 Android / Windows 端导出的备份，可以在 iOS 上直接恢复，不需要转换；
- iOS 端导出的备份，官方 Android / Windows 端也能直接恢复；
- 不存在「迁移失败导致数据半损坏」的场景，因为根本没有转换步骤。

代价是必须严格遵守原项目的格式约定，这部分由 13 个单元测试固化（见 `Tests/PersistenceTests.swift`）。

## 二、如何把旧数据弄进来

三条路径，按推荐顺序：

### 1. 备份 zip 恢复（推荐）

在原设备上「设置 → 备份 → 生成备份文件（勾选包含媒体）」，把 zip 传到 iPhone，
在「我的 → 本地备份与恢复 → 从备份文件恢复」选择它。

也可以放到 iCloud 云盘 / 文件 App 里直接点选，应用支持通过 `fileImporter` 读取。

### 2. WebDAV 恢复

原设备已经配好 WebDAV 的话，iOS 端填同样的地址/账号/密码，
「WebDAV → 读取远程备份列表 → 恢复到此设备」即可。

### 3. 直接替换数据库文件（开发者）

沙盒路径：
```
~/Library/Application Support/com.yucore.swashbucklerdiary.native/
├── SwashbucklerDiary.db3
├── SwashbucklerDiary.privacy.db3
└── Assets/{Image,Audio,Video,Avatar}/
```
把旧的 `SwashbucklerDiary.db3` 和 `Assets/` 覆盖进去即可。
注意覆盖前要先杀掉进程，否则 WAL 会写回旧内容。

## 三、字段级兼容策略

| 字段 | 风险 | 处理 |
| --- | --- | --- |
| `Id`（Guid） | SQLSugar 写 36 位小写带连字符；个别路径可能写 BLOB 或去连字符 | 读取时兼容 3 种形态，写入统一小写带连字符 |
| `CreateTime` / `UpdateTime` | 历史版本出现过带毫秒/不带毫秒/带 T/带时区多种格式 | 依次尝试 10 种日期布局，再兜底 Unix 秒/毫秒/.NET Ticks；写入固定 `yyyy-MM-dd HH:mm:ss.fff` |
| `Template` | 后加列，老库可能为 NULL 或整列缺失 | 读时 NULL→false；启动时 `ALTER TABLE ADD COLUMN` 补齐 |
| `Private` | 1.3.9 起废弃 | 保留字段与读写，但不再用于判断私密性 |
| `ResourceType` | 枚举顺序是契约 | 严格按 `Unknown=0/Image=1/Audio=2/Video=3` |
| 正文资源 URI | 1.3.9 之前是 `appdata:///Image/x.jpg` | 解析时统一归一化；导入旧备份时批量改写正文 |
| 表名 | 早期版本可能叫 `Diary` / `Diaries` | `TableMap` 运行时探测，按优先级匹配 |

日期与 Guid 的解析逻辑集中在 `ios/SwashbucklerDiary/Core/Compat.swift`，
被 5 个测试覆盖，改动这一层必须让测试通过。

## 四、导入流程（含回滚）

`BackupService.importBackup(from:)` 的顺序是刻意设计的：

1. **解包到临时目录**，与正式数据完全隔离。
2. **预检**：用只读连接打开解包出来的 `.db3`，
   执行 `SELECT COUNT(*) FROM DiaryModel`。打不开或没表就直接报错，
   绝不动正式文件——这是「迁移失败不能产生不完整正式数据」的落点。
3. **留回滚副本**：把当前库复制成 `Rollback-<时间戳>.db3`。
4. **断开连接**（`DiaryDatabase.closeAll()`），删掉目标库与 `-wal`/`-shm`，
   复制新库，再 `reopen()`。
   不先断开就会出现「新文件被旧 WAL 覆盖」的隐蔽数据错乱。
5. **恢复媒体文件**：把 `appdata/Image|Audio|Video` 合并到 `Assets/`，
   `appdata/Avatar` 合并到 `Assets/Avatar`。同名文件覆盖，不存在的保留。
6. **恢复设置**：读 `settings.json`，敏感项在导出阶段就被剔除了，所以不会把别人的密码带进来。
7. **旧格式修正**：没有 `version.json` 的备份，额外把 `<root>/Image/` 搬进 `Assets/Image/`，
   并批量把正文里的 `appdata:///` 改成 `appdata/`。
8. **清理**临时目录与回滚副本。

任何一步抛错，第 3 步的回滚副本会覆盖回原库并重新打开连接。

### 已验证的路径

| 场景 | 结果 |
| --- | --- |
| 正常 zip 结构（含 `version.json`） | 恢复日记与媒体，设置一并恢复 |
| 旧格式 zip（无 `version.json`，图片平铺在 `Image/`） | 自动搬运 + 改写 URI，给出 warning |
| 含中文文件名的 zip | 正确解出（UTF-8 标志位） |
| zip 内没有 `.db3` | 报错「备份包内没有 .db3 数据库文件」，原数据不动 |
| 损坏的 zip | `ZipReader` 抛格式异常，原数据不动 |
| 恢复大备份（8 MB 级） | 通过（单元测试覆盖 6 MB 条目） |

## 五、隐私库的处理

原项目导出的备份文件名永远是 `SwashbucklerDiary.db3`，
即使内容来自隐私库也是如此（`DiaryFileManager.GetCurrentDatabasePath()` 的逻辑）。

原生端保持同样行为：
- 在隐私模式下导出，zip 里装的是隐私库内容，文件名不变；
- 导入时，如果当前处于隐私模式，就覆盖隐私库，否则覆盖主库。

这意味着**「在普通模式恢复一份隐私备份」会把私密内容写进普通库**。
这是原项目的既有语义，为保持格式兼容没有改动，但在 UI 上做了提示：
恢复确认弹窗明确写了「当前设备上的日记会被这份备份替换」。

## 六、不删除任何原有数据

- 删除日记只删中间表关联，`ResourceModel` 记录与磁盘文件都保留
  （避免误删仍被其它日记引用的文件）。
- 媒体库页面提供显式的「清理未被引用的文件」，
  且只删除「零引用」的资源，删除前会在页面上列出数量。
- 导入失败自动回滚，不留下半套数据。

## 七、备份格式的回归验证

`Tests/ZipAndSecurityTests.swift` 中：

- `testSettingsJSONUsesPascalCaseKeys`：确保 `settings.json` 的键名与原项目一致；
- `testSettingsDecodingToleratesMissingFields`：确保缺字段的旧设置文件不会让应用起不来；
- `testWebDAVConfigurationJSONMatchesOriginal`：`WebDavConfig` 的 JSON 结构（`ServerAddress`/`Account`/`Password`）；
- `testRoundTripStoredAndDeflated` / `testChineseEntryNameSurvives`：ZIP 容器本身的正确性；
- `testUploadedZipIsValidArchive`：上传到 WebDAV 再下载回来，zip 仍可正常解析。
