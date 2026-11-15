# iOS 原生架构

## 一、总体分层

```
┌──────────────────────────────────────────────────┐
│  Features/     SwiftUI 页面（14 个）              │
│  列表 详情 编辑 日历 标签 搜索 媒体 我的 设置 锁屏  │
├──────────────────────────────────────────────────┤
│  Services/     业务服务                           │
│  DiaryStore(状态) SettingsStore Markdown Backup   │
│  MediaImporter WebDAVClient AppLock Privacy       │
├──────────────────────────────────────────────────┤
│  Persistence/  数据访问                           │
│  Schema · DiaryDatabase · 4 个 Repository         │
├──────────────────────────────────────────────────┤
│  Core/ / Models/                                  │
│  SQLite 封装 · 兼容解析 · ZIP · 日志 · 设计系统    │
└──────────────────────────────────────────────────┘
```

四条硬边界，代码里可以逐条核对：

1. **UI 不含 SQL**。所有 SQL 只出现在 `Persistence/` 和 `DiaryDatabase` 里，页面层零字符串 SQL。
2. **UI 不含网络**。WebDAV 的请求细节全部封装在 `WebDAVClient`，
   页面只拿到 `WebDAVError` 或 `[WebDAVFileInfo]`。
3. **UI 不判断隐私库**。页面永远通过 `DiaryDatabase.current` 取连接，
   由连接层根据 `isPrivacyMode` 决定指向主库还是隐私库。页面无法「忘记」切库。
4. **写入只走 `DiaryStore`**。列表、详情、日历、标签页读的都是同一份 `@Published` 数据，
   写入后统一 `reload()`，不存在多处缓存不同步的问题。

依赖方向单向向下，`Core` 与 `Models` 不依赖任何 UI 类型（唯一例外是 `DesignSystem`，
它属于表现层但放在 Core 目录下便于共享）。

## 二、并发模型

- `DiaryStore`、`SettingsStore`、`AppLockService`、`PrivacyModeController` 都是 `@MainActor` 的 `ObservableObject`。
- 所有耗时操作（备份打包、解包、WebDAV 传输、图片解码）都在后台：
  - 备份用 `Task.detached(priority: .userInitiated)`；
  - 图片解码用独立 `DispatchQueue`（`ImageCache`）；
  - 网络用 `async/await` 包装的 `URLSession`。
- `SQLiteDatabase` 用一把 `NSRecursiveLock` 串行化所有访问。
  SQLite 的连接级并发限制决定了「一把锁 + 全串行」比「连接池 + 重试」更简单可靠，
  而且个人日记场景的写入频率极低。事务用嵌套计数实现，业务代码可以放心嵌套调用。

## 三、数据访问

### 为什么不用 SwiftData / Core Data

原项目的数据库是**跨端契约**（Android、Windows、Web 共用同一份 `.db3`）。
换成 SwiftData 意味着必须写一个双向迁移器，并且每次备份互导都要转换一次，
既增加数据丢失风险，也违背「优先复用而不是强制转换」的要求。

因此原生端直接用系统自带的 `sqlite3` C API（零第三方依赖），
保持表结构、列名、类型、时间格式与 SQLSugar 完全一致。
好处很直接：把 Android 端的备份 zip 拖进来就能恢复，反之亦然。

### 表名探测

`TableMap` 在打开库时读取 `sqlite_master`，按「`DiaryModel` → `Diary` → `Diaries`」的顺序
探测真实表名，兼容早期版本的命名差异。所有 SQL 都通过 `TableMap.quoted(...)` 取表名，
不会出现硬编码表名散落各处的情况。

### 仓储

四个仓储各管一块，用结构体实现（无状态、可随手构造）：

| 仓储 | 职责 |
| --- | --- |
| `DiaryRepository` | 日记增删改查、标签/资源关联、按天统计 |
| `TagRepository` | 标签 CRUD、按名复用、重命名、删除（只删标签不动日记） |
| `ResourceRepository` | 资源登记、引用计数、孤儿检测、体积统计 |
| `LocationRepository` | 从日记正文聚合地点、维护地点目录 |

`DiaryRepository.fetchAll()` 刻意采用「4 次全表查询 + 内存拼装」而不是 N+1 或多次 JOIN：
个人日记量级在千条以内，这样一次 IO 就能拿到列表所需的全部关联数据，
滚动列表时不会因为懒加载再打数据库。

## 四、Markdown 引擎

`Services/Markdown/` 三个文件，自研，无第三方依赖：

- `MarkdownParser`：块级解析（标题、列表、任务列表、代码块、引用、表格、分割线、公式块、块级图片）。
- `InlineParser`：行内解析（强调、加粗、删除线、行内代码、链接、图片、行内公式、脚注引用、自动链接）。
- `MathRender`：公式的符号替换与上下标近似排版。

渲染层 `Features/Markdown/MarkdownView.swift` 把 AST 映射成 SwiftUI 视图：
行内用 `AttributedString`（享受系统排版与 Dynamic Type），块级用 VStack 组合，
代码块横向滚动、表格横向滚动、图片自适应宽度。

**为什么不用 WebView 渲染 Vditor**：需求明确禁止把 WebView 当最终方案。
Vditor 的打包体积约 20 MB（含 MathJax、Mermaid、ECharts），
在移动端还会带来首屏白屏与滚动卡顿。自研解析器覆盖日记场景实际会用到的语法，
代价是放弃 Mermaid/Graphviz 这类图表语法（原文会以代码块显示）。

性能：单元测试里用 800 段带格式的中文正文（约 3 万字）跑 `measure`，
解析耗时在模拟器上约 0.5 秒，且只在打开详情时执行一次，
列表卡片走的是纯文本摘要，不做完整解析。

## 五、编辑器

`Features/Editor/` 两个文件：

- `MarkdownTextView`：`UITextView` 的 `UIViewRepresentable` 封装。
  选它而不是 SwiftUI `TextEditor` 的原因是三件 SwiftUI 目前给不了的事：
  精确的 `selectedRange`、可用的 `UndoManager`、长文本下的滚动性能。
- `MarkdownEditorProxy`：把「在光标处插入片段」抽象成 `insert(wrapping:)` / `insert(linePrefix:)` /
  `insertBlock(_:)` 三个方法，工具栏按钮不接触 UIKit。

自动保存：`scheduleAutosave()` 用可取消的 `Task.sleep` 做防抖，
间隔取设置里的 `EditAutoSave`（3/5/10/30 秒或关闭）。
另外三条强制保存路径：点「关闭」、`onDisappear`、App 进入后台。
即使自动保存被关闭，关闭编辑器时也会保存，所以不存在「写了半天丢了」的情况。

草稿恢复：每次自动保存都直接写库，所以进程被杀后重新打开就是最后一次成功保存的内容。
没有另设草稿表——多一份副本就多一处不一致。

## 六、状态管理与错误处理

- 单一数据源 `DiaryStore`，`@Published private(set)`，外部只能通过方法改。
- 统一错误出口：`DiaryStore.lastError` → 根视图 alert；即时操作反馈走 `ToastCenter`。
- 网络错误统一映射：`WebDAVError` 覆盖地址非法、认证失败、路径不存在、状态码异常、
  校验失败、取消六类，每一类都有中文可读文案；`NSURLErrorDomain` 的常见码再单独翻译。
- 日志 `Log.debug/info/warning/error`：控制台走 `os.Logger`，同时写滚动文本日志（2 MB 轮转），
  可在「关于 → 运行日志」查看与分享。日志不含日记正文。

## 七、Liquid Glass 与旧系统降级

```swift
@ViewBuilder
func adaptiveGlass<S: Shape>(_ shape: S) -> some View {
    if #available(iOS 26.0, *) {
        self.glassEffect(.regular, in: shape)
    } else {
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.6))
    }
}
```

使用范围刻意收窄：工具栏、Toast、悬浮提示条、底部编辑工具栏。
正文、卡片、列表一律纯色，理由很实际——满屏玻璃会让长文阅读变得疲劳，
而且 Liquid Glass 的设计意图本来就是「浮层」，不是「所有容器」。

部署目标 iOS 17.0。所有 iOS 18+/26+ 的 API 都包在 `#available` 里，
在 iOS 17 上会自动降级而不是崩溃。

## 八、可测试性设计

- 纯逻辑（Markdown / ZIP / 兼容解析 / 哈希）不依赖 UIKit，可直接单测。
- `WebDAVClient` 的传输会话可注入（`useBackgroundSession:`）：
  生产用后台 `URLSession`（App 切后台不中断），测试用默认会话（回调即时）。
- 仓储依赖 `SQLiteDatabase` 而非全局单例，测试可以在临时目录里造库，
  不会污染真实数据。
- `DebugRouter`：Debug 构建下用环境变量直达任意页面，方便截图验收，
  Release 构建整段代码被 `#if DEBUG` 剔除。

## 九、已知取舍

| 取舍 | 原因 | 后续路径 |
| --- | --- | --- |
| 自研 Markdown 而非接第三方 | 避免 WebView 与 20 MB 依赖 | 需要 Mermaid 时可加一个懒加载的渲染扩展 |
| 公式只做近似排版 | 完整 LaTeX 引擎体积与维护成本过高 | 可接 SwiftMath（仅数学排版，不引入 WebView） |
| CSV 代替 xlsx | 无 ClosedXML 等价物，且 XLSX 本质是 zip+XML | 用现有 `ZipWriter` 可补一个最小 XLSX 写出器 |
| 单语言 | 20+ 语言词表迁移工作量独立且大 | `AppSettings.language` 字段已保留，接入词表即可 |
