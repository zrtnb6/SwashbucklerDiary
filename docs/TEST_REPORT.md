# 测试报告

- 执行时间：2026-11-16 00:33（GMT+8）
- 环境：macOS 26.7.1 (x86_64) ／ Xcode 26.5 (17F42) ／ Swift 6.3.2 ／ iOS 26.5 模拟器 (iPhone 17)
- 命令：`xcodebuild -project ios/SwashbucklerDiary.xcodeproj -scheme SwashbucklerDiary -destination 'platform=iOS Simulator,name=iPhone 17' test`

## 一、单元测试结果

```
Test Suite 'BackupFormatTests'   passed    Executed 5 tests,  0 failures
Test Suite 'MarkdownParserTests' passed    Executed 12 tests, 0 failures
Test Suite 'PersistenceTests'    passed    Executed 13 tests, 0 failures
Test Suite 'SecurityTests'       passed    Executed 4 tests,  0 failures
Test Suite 'WebDAVClientTests'   passed    Executed 13 tests, 0 failures
Test Suite 'ZipTests'            passed    Executed 7 tests,  0 failures
Test Suite 'All tests'           passed    Executed 54 tests, 0 failures in 4.440s
** TEST SUCCEEDED **
```

54 个用例全部通过，无跳过、无预期失败（`0 unexpected`）。

## 二、用例明细与意图

### MarkdownParserTests（12）

| 用例 | 验证什么 |
| --- | --- |
| `testHeadingLevels` | 1~6 级标题 |
| `testUnorderedAndOrderedList` | 无序列表项数；有序列表从 3 开始时后续项不丢 |
| `testTaskList` | `- [x]` / `- [ ]` 的勾选状态 |
| `testTableWithSpacesInSeparator` | **分隔行 `| --- | --- |` 带空格时也要识别成表格**（曾因去空格不彻底导致表格退化成纯文本，截图验收时发现） |
| `testCodeFenceWithLanguage` | 围栏代码块与语言标记 |
| `testQuoteContainsNestedBlocks` | 引用块内嵌块 |
| `testInlineStyles` | 加粗/斜体/删除线/行内代码/链接/图片 |
| `testInlineMathAndSuperscript` | 行内公式提取 + `^2 → ²` |
| `testDollarSignNotMath` | `$100 和 $200` 不能误判成公式 |
| `testPlainTextStripsSyntax` | 纯文本化后不残留 `**`、`[x]` |
| `testUnclosedFenceDoesNotCrash` | 未闭合代码块不崩 |
| `testLargeDocumentPerformance` | 800 段中文正文解析性能（`measure`） |

### PersistenceTests（13）

| 用例 | 验证什么 |
| --- | --- |
| `testSchemaMatchesOriginalTableNames` | 8 张表名与 SQLSugar 输出一致 |
| `testCreatesMissingLegacyColumn` | 老库缺 `Template` 列时启动自动补齐 |
| `testDateFormatsFromDotNetAreParsed` | 4 种 .NET 日期格式都能解析 |
| `testEpochAndTicksFallback` | Unix 秒/毫秒、.NET Ticks 兜底 |
| `testDateRoundTripKeepsSecondPrecision` | 写入→读回不丢精度 |
| `testUUIDWithBracesAndUppercase` | 带花括号、大写、去连字符三种 Guid 写法 |
| `testInsertAndFetchDiaryWithTagsAndResources` | 关联写入与回读 |
| `testUpdatingTagsDoesNotDuplicate` | 更新标签不重复建 |
| `testSameTagNameReusesExistingTag` | 同名标签复用且计数正确 |
| `testDeleteDiaryRemovesRelations` | 删除只清关联，保留资源记录 |
| `testCountsByDayGroupsCorrectly` | 按天分组统计 |
| `testTemplatesAreExcludedFromTimeline` | 模板不进时间线 |
| `testChineseContentAndTagsRoundTrip` | 中文 + emoji 往返 |

### ZipTests（7）

CRC32 标准值（`"123456789" → 0xCBF43926`）、store/deflate 往返、中文条目名、
解压落盘、空/损坏包拒绝、6 MB 大条目。

### SecurityTests（4）

PBKDF2-SHA256 加盐哈希、随机盐使同密码产生不同哈希、空哈希拒绝一切、
固定输入输出稳定（与 .NET `Rfc2898DeriveBytes` 参数一致）。

### BackupFormatTests（5）

`settings.json` 用 PascalCase 键、缺失字段容错、`WebDavConfig` JSON 结构、
WebDAV 地址规范化（含拒绝 `ftp://`）、中文文件名百分号编码。

### WebDAVClientTests（13）

全部跑在进程内模拟服务器上，覆盖连接建目录、错误密码、非法地址、上传+尺寸校验、
中文文件名、8 MB 大文件、重复覆盖、服务器 500、列表过滤、空目录、下载一致性、删除、
上传后 zip 仍可解析。

## 三、测试中发现并修复的缺陷

测试不是走过场，下面 6 个问题都是先失败后修复的：

| # | 现象 | 根因 | 修复 |
| --- | --- | --- | --- |
| 1 | 详情页表格显示成 `| 项目 | 状态 |` 纯文本 | 表格分隔行判定没 trim 单元格空格 | `isTableSeparator` 逐格 trim 后再比对 |
| 2 | 卡片摘要残留 `- [x]` | `plainText` 主动拼接了任务标记 | 任务列表纯文本只取内容 |
| 3 | 星期几整体偏移一天 | `Calendar.weekday` 是 1-based，数组 0-based | `names[weekday - 1]` |
| 4 | `ftp://` 地址被改写成 `https://ftp://…` | 只判断了有无 `http` 前缀 | 检测任意 `://`，非 http(s) 直接拒绝 |
| 5 | 32 位无连字符 Guid 解析失败 | 按 8-8-8-8 分组，正确应为 8-4-4-4-12 | 重写分组 |
| 6 | **WebDAV 远程列表恒为空** | `XMLParser` 的 `elementName` 是 `D:response`，按 `response` 匹配不到 | 取命名空间前缀之后的部分再比较 |

第 6 条影响最大：它会让「上传成功但看不到备份」在真实服务器上稳定复现，
而本地用 `<response>` 无前缀的假数据测试时又完全正常。

## 四、UI 验收（模拟器实机截图）

逐屏截图核对，发现并修掉了上面第 1~3 条。

| 页面 | 检查项 | 结果 |
| --- | --- | --- |
| 时间线 | 空态、统计条、按天分组、卡片标题/摘要/日期列/置顶图钉/心情天气图标、Liquid Glass 标签栏 | 通过 |
| 时间线（有数据） | 3 篇日记正确分组为「昨天 / 11月14日 / 11月11日」，摘要已无 Markdown 残留 | 通过（修复后复验） |
| 详情 | 标题、时间、心情/天气/地点、标签、任务列表勾选框、引用竖线、表格、代码块（含语言标签与背景）、行内公式 `E = mc²`、字数统计 | 通过（表格与公式为修复后复验） |
| 编辑器 | 标题、正文、心情/天气/地点/标签胶囊、Markdown 工具栏 12 个按钮、字数状态栏 | 通过 |
| 日历 | 月标题、星期行（周日开头）、日期网格对齐、有日记的日期圆点、选中态、当日列表 | 通过 |
| 我的 | 头像区、统计四项、内容/备份与同步/隐私与安全/个性化/关于 分组的行样式与图标 | 通过 |

截图存放在 `docs/screenshots/`：

| 文件 | 页面 |
| --- | --- |
| `01-timeline-light.png` | 时间线（浅色） |
| `02-timeline-dark.png` | 时间线（深色） |
| `03-detail-markdown.png` | 详情（表格/任务/引用/代码/公式） |
| `04-editor.png` | 编辑器（含 Markdown 工具栏） |
| `05-calendar.png` | 日历 |
| `06-mine.png` | 我的 |
| `07-appearance-settings.png` | 外观与阅读设置 |

截图未包含的页面（搜索、媒体库、备份、WebDAV、应用锁、隐私、外观、关于）已通过
`DebugRouter` 的直达路由打开验证可正常渲染，但**没有做逐像素的视觉核对**，
这部分留给真机人工验收。

## 五、构建验证

| 配置 | 命令 | 结果 |
| --- | --- | --- |
| Debug 模拟器 | `-sdk iphonesimulator -destination 'generic/platform=iOS Simulator'` | BUILD SUCCEEDED |
| Release 设备 | `-sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| 模拟器运行 | `simctl install` + `launch` | 正常启动，无崩溃 |
| 单元测试 | 见上 | 54/54 通过 |

## 六、没有验证到的部分（如实说明）

| 项 | 原因 | 建议 |
| --- | --- | --- |
| Face ID / Touch ID 真机解锁 | 模拟器不支持生物识别 | 需真机验证；代码路径走 `LAContext.canEvaluatePolicy`，失败会回落到密码 |
| WebDAV 真实服务器（坚果云/Nextcloud 等） | 无凭据 | 模拟服务器已覆盖协议层；真实环境需人工连一次 |
| App 进入后台继续上传 | 模拟器后台调度与实际差异大 | 真机验证；实现用后台 `URLSession` + 后台事件回调 |
| 大附件（>200 MB 视频） | 未构造 | 上传/下载都是文件级，理论无内存压力 |
| 长文本输入流畅度 | 模拟器性能不代表真机 | 解析性能有 `measure` 基线；输入路径是原生 `UITextView` |
| 深色模式逐页核对 | 只核对了时间线与设置页 | 已核对的两页对比度正常；强调色做了深色自适应（`#21665F` → `#5CBDAF`）。其余页面颜色全部走语义色，未硬编码浅色值 |
| 多语言 | 未实现 | 见 `IOS_REWRITE_PLAN.md` 遗留项 |

## 七、云端 CI 实测

本地验证通过后，代码推送到 GitHub 触发 Actions 跑了一遍。CI 环境与本机不同
（Xcode 16.4 / iOS 18.5 SDK / iPhone 16 Pro 模拟器），正好补上了本机无法覆盖的编译期差异。

| 项 | 结果 |
| --- | --- |
| Build & Test | ✅ success |
| Package IPA | ✅ success |
| 单元测试 | `Executed 54 tests, with 0 failures (0 unexpected) in 50.443s` |
| 产物 | `SwashbucklerDiary-app-unsigned`（1.2 MB）、`SwashbucklerDiary-ipa-unsigned`（1.2 MB）、`test-log` |

> 注：该次运行记录属于仓库重置前的 fork（含完整 .NET 工程）。仓库转为独立的 iOS 项目后，
> 旧运行记录随仓库删除而失效；当前 `main` 分支的每次提交都会重新触发同样的流程。

### CI 比本机多抓到的两个问题

本机是 Xcode 26.5 / iOS 26.5 SDK，CI 是 Xcode 16.4 / iOS 18.5 SDK，
两者差异暴露了本机发现不了的缺陷：

1. **`glassEffect` 在旧 SDK 里不存在**，`if #available(iOS 26.0, *)` 只能挡运行时、
   挡不住编译期缺符号 → 改为 `#if compiler(>=6.2)` 分支，旧编译器直接走材质降级。
   两条分支都已本地强制编译验证。
2. **`ZipArchive.dosComponents` 的混合类型长位运算**
   在 arm64 Release 下触发 `unable to type-check this expression in reasonable time`
   → 拆成具名中间变量后再转 `UInt16`。

另外工作流本身也有一个坑：**`secrets` 上下文不允许出现在 `if` 表达式里**，
否则整个工作流被判为无效，运行记录显示 0 个 job、没有日志、只有一句 failure。
改成先用一步探测 Secrets 是否存在并写入 `output`，后续步骤按 `output` 判断。

## 八、如何复现

```bash
cd ios
xcodebuild -project SwashbucklerDiary.xcodeproj \
  -scheme SwashbucklerDiary \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

CI 中同样执行这条命令（见 `.github/workflows/ios-build.yml` 的 `Run unit tests` 步骤），
并把日志与构建产物一并上传为 Artifact。
