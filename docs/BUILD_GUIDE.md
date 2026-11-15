# 构建与安装指南

## 一、环境要求

| 项 | 要求 |
| --- | --- |
| macOS | 26.x（实测 26.7.1，Intel 亦可） |
| Xcode | **16.4 及以上可编译**；26.0+ 才能启用 Liquid Glass（实测 26.5 / 17F42，CI 用 16.4 / iOS 18.5） |
| iOS SDK | 18.5 ~ 26.x |
| 部署目标 | iOS 17.0 |
| 额外工具 | **不需要** xcodegen / CocoaPods / SPM 依赖，工程文件已随仓库提供 |

工程里没有任何第三方依赖，`xcodebuild` 直接可跑。

关于 SDK 版本：`glassEffect` 只在 iOS 26 SDK 里存在，代码用 `#if compiler(>=6.2)` 分支隔离，
用 Xcode 16.4（iOS 18.5 SDK）编译时会走 `.ultraThinMaterial` 降级路径，功能完全一样，只是浮层不是真玻璃。
这条也是 CI 最早暴露出来的问题之一——`if #available` 挡不住编译期缺少符号。

## 二、本地构建

```bash
cd ios

# 模拟器（最快，用于日常开发）
xcodebuild -project SwashbucklerDiary.xcodeproj \
           -scheme SwashbucklerDiary \
           -sdk iphonesimulator \
           -destination 'generic/platform=iOS Simulator' \
           -configuration Debug build

# 真机（未签名）
xcodebuild -project SwashbucklerDiary.xcodeproj \
           -scheme SwashbucklerDiary \
           -sdk iphoneos \
           -configuration Release \
           -destination 'generic/platform=iOS' \
           CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
           build
```

跑测试：

```bash
xcodebuild -project SwashbucklerDiary.xcodeproj \
           -scheme SwashbucklerDiary \
           -destination 'platform=iOS Simulator,name=iPhone 17' \
           test
```

用 Xcode 打开：`open ios/SwashbucklerDiary.xcodeproj`。
选自己的 Team 后即可直接跑到真机（`Signing & Capabilities → Team`）。

## 三、在模拟器里安装运行（命令行）

```bash
xcrun simctl boot "iPhone 17"
APP=$(find ~/Library/Developer/Xcode/DerivedData/SwashbucklerDiary-*/Build/Products/Debug-iphonesimulator \
      -maxdepth 1 -name "SwashbucklerDiary.app" | head -1)
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.yucore.swashbucklerdiary.native
```

### Debug 直达路由（开发用）

Debug 构建支持通过环境变量直接打开某个页面，省去手工点击：

```bash
SIMCTL_CHILD_DEBUG_SCREEN=detail SIMCTL_CHILD_DEBUG_DIARY_INDEX=1 \
  xcrun simctl launch booted com.yucore.swashbucklerdiary.native
```

`DEBUG_SCREEN` 可选：`detail` `editor` `calendar` `tags` `mine` `webdav` `backup`
`appearance` `privacy` `about` `search` `media`。
这段代码整体包在 `#if DEBUG` 里，Release 构建不存在。

## 四、GitHub Actions 云构建

工作流：`.github/workflows/ios-build.yml`

| 触发 | 行为 |
| --- | --- |
| push / PR 到 `main`（改动了 `ios/**` 或工作流自身） | 编译 Release + 跑单元测试，上传 `.app` 与测试日志 |
| 手动 `workflow_dispatch` | 同上，并额外打包**未签名 IPA** |
| 配置了签名 Secrets | 额外产出**已签名 IPA** |

Runner 用 `macos-15`（自带 Xcode 16.4 / iOS 18.5 SDK）。
如果要用更新的 SDK，把 `runs-on` 改成 `macos-26`（若已开放）或在步骤里 `xcodes select`。

产物：

- `SwashbucklerDiary-app-unsigned`：`.app` 目录，可直接喂给重签工具；
- `SwashbucklerDiary-ipa-unsigned`：`Payload/` 打包成的 `.ipa`；
- `SwashbucklerDiary-ipa-signed`：配置签名后才有；
- `test-log`：完整测试输出。

### 关于未签名 IPA 的说明

**未签名 IPA 不能直接安装到 iPhone。** 它只是把 `.app` 按 `Payload/` 结构打成 zip。
需要用自己的证书重签后才能安装，方式有三种：

1. **Xcode**：把 `.app` 拖进 Xcode 的 Devices 窗口，或用 `ios-deploy`；
2. **AltStore / Sideloa​dly / TrollStore**：直接导入 ipa，由工具用你的 Apple ID 签名；
3. **命令行重签**：
   ```bash
   unzip SwashbucklerDiary-*.ipa -d out
   codesign -f -s "Apple Development: you@example.com" \
     --entitlements entitlements.plist out/Payload/SwashbucklerDiary.app
   codesign -dv --verbose=4 out/Payload/SwashbucklerDiary.app   # 确认 Signature=adhoc/证书
   cd out && zip -qry ../SwashbucklerDiary-signed.ipa Payload
   ```

仓库不会、也不应该包含任何证书或私钥。

### 配置签名（可选）

在仓库 `Settings → Secrets and variables → Actions` 里添加：

| Secret | 内容 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | `.p12` 导出证书的 base64：`base64 -i cert.p12 \| pbcopy` |
| `P12_PASSWORD` | 导出时设置的密码 |
| `PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 的 base64 |
| `KEYCHAIN_PASSWORD` | 临时钥匙串密码（随便设一个强密码） |
| `APPLE_TEAM_ID` | 10 位 Team ID |

工作流会检测 `BUILD_CERTIFICATE_BASE64` 是否存在，存在才走签名分支，
不存在就只产出未签名包，不会失败。

## 五、安装到真机

### 方式 A：Xcode（最省事）

```bash
open ios/SwashbucklerDiary.xcodeproj
# Signing & Capabilities 里选自己的 Team，插上设备，Cmd+R
```

Bundle ID 默认 `com.yucore.swashbucklerdiary.native`，
个人开发者账号下如果冲突，改成自己的前缀（`PRODUCT_BUNDLE_IDENTIFIER`）。

### 方式 B：安装 CI 产物

1. 下载 `SwashbucklerDiary-ipa-unsigned`；
2. 用 AltStore / Side​loadly 导入并签名安装；
3. 首次启动需要在「设置 → 通用 → VPN与设备管理」里信任开发者证书。

## 六、常见问题

**`error: No signing certificate "iOS Development" found`**
本地构建加上 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`，
或者到 Xcode 里选一个 Team。

**模拟器列表里没有 iPhone 17**
`xcrun simctl list devices available` 看实际机型，把 `-destination` 换成有的那个。
CI 里会自动探测可用机型。

**`The request was denied by service delegate (SBMainWorkspace)`**
模拟器状态异常，`xcrun simctl shutdown all && xcrun simctl boot "iPhone 17"` 重来。

**改了 Bundle ID 之后数据不见了**
数据目录跟 Bundle ID 绑定（`~/Library/Application Support/<bundle id>/`）。
换 ID 等于换沙盒，需要重新导入备份。

**构建很慢**
Intel Mac 上首次全量编译约 3~5 分钟属正常。
增量编译通常 20 秒内。CI 上有缓存目录 `build/`，但每次都是干净构建。

## 七、工程结构说明（给后续维护者）

`project.pbxproj` 是手写的，用的是 `objectVersion = 77` +
`PBXFileSystemSynchronizedRootGroup`：**新增 Swift 文件不需要改工程文件**，
只要放进 `SwashbucklerDiary/` 或 `Tests/` 目录就会被自动纳入编译。
这是刻意选择——避免依赖 xcodegen，也避免每次加文件都要动 pbxproj 造成冲突。

需要注意的两点：

1. `Support/Info.plist` 放在同步目录**之外**，否则会被当作资源重复拷贝，
   构建时报 `Multiple commands produce ... Info.plist`。
2. 新增 target 时要同步更新 `xcshareddata/xcschemes/SwashbucklerDiary.xcscheme` 的
   `TestAction → Testables`，否则 `xcodebuild test` 找不到测试包。
