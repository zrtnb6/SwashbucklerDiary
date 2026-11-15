import SwiftUI
import UIKit

@main
struct SwashbucklerDiaryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var settings = SettingsStore.shared

    /// 0 跟随系统 / 1 浅色 / 2 深色
    private var preferredScheme: ColorScheme? {
        switch settings.settings.theme {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
                .preferredColorScheme(preferredScheme)
        }
    }
}

/// 只负责两件系统级事情：后台 WebDAV 会话事件回传、进入后台时的应用锁。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Log.info("应用启动，版本 \(Bundle.main.appVersion) (\(Bundle.main.buildNumber))", .app)
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // 后台会话把事件交回 App 时，先记录下来再回调，避免系统认为我们没处理。
        Log.info("收到后台传输会话事件：\(identifier)", .network)
        BackgroundSessionBridge.shared.completionHandler = completionHandler
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        DiaryDatabase.shared.flush()
        if AppLockService.shared.lockWhenLeave {
            AppLockService.shared.lock()
        }
    }
}

/// 后台 URLSession 的完成回调需要在合适时机交还给系统。
final class BackgroundSessionBridge {
    static let shared = BackgroundSessionBridge()
    var completionHandler: (() -> Void)?

    private init() {}

    func finish() {
        completionHandler?()
        completionHandler = nil
    }
}

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
}
