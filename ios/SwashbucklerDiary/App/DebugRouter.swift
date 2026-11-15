import SwiftUI

#if DEBUG
/// 调试直达路由。
///
/// 只用于开发和截图验收：通过 `SIMCTL_CHILD_DEBUG_SCREEN=detail` 之类的环境变量
/// 直接打开某个页面，省去手工点击。Release 构建里整段代码会被编译剔除。
enum DebugRouter {
    struct Target: Identifiable {
        let name: String
        var id: String { name }
    }

    static func requested() -> Target? {
        guard let screen = ProcessInfo.processInfo.environment["DEBUG_SCREEN"], !screen.isEmpty else {
            return nil
        }
        return Target(name: screen)
    }
}

struct DebugScreenHost: View {
    let target: DebugRouter.Target
    @Environment(\.dismiss) private var dismiss

    private var diary: Diary? {
        let index = Int(ProcessInfo.processInfo.environment["DEBUG_DIARY_INDEX"] ?? "0") ?? 0
        let all = DiaryStore.shared.diaries
        guard all.indices.contains(index) else { return all.first }
        return all[index]
    }

    var body: some View {
        NavigationStack {
            Group {
                switch target.name {
                case "detail":
                    if let diary {
                        DiaryDetailPage(diaryID: diary.id) {}
                    } else {
                        Text("没有日记可展示")
                    }
                case "editor":
                    if let diary {
                        DiaryEditorPage(diaryID: diary.id, isNew: false) {}
                    } else {
                        Text("没有日记可编辑")
                    }
                case "calendar":
                    CalendarPage()
                case "tags":
                    TagPage()
                case "mine":
                    MinePage()
                case "webdav":
                    NavigationStack { WebDAVSettingsPage() }
                case "backup":
                    NavigationStack { BackupSettingsPage() }
                case "appearance":
                    NavigationStack { AppearanceSettingsPage() }
                case "privacy":
                    NavigationStack { PrivacySettingsPage() }
                case "about":
                    NavigationStack { AboutPage() }
                case "search":
                    SearchPage { _ in }
                case "media":
                    NavigationStack { MediaLibraryPage() }
                default:
                    Text("未知页面：\(target.name)")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .environmentObject(DiaryStore.shared)
        .environmentObject(SettingsStore.shared)
    }
}
#endif
