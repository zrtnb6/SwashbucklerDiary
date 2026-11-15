import SwiftUI

/// 应用根视图：底部四个标签页 + 全局遮罩（应用锁 / 隐私模式提示）。
struct RootView: View {
    @StateObject private var store = DiaryStore.shared
    @StateObject private var settingsStore = SettingsStore.shared
    @StateObject private var lockService = AppLockService.shared
    @StateObject private var privacy = PrivacyModeController.shared

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .timeline
    #if DEBUG
    @State private var debugTarget: DebugRouter.Target?
    #endif

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                DiaryListView()
                    .tabItem { Label("日记", systemImage: "book.closed") }
                    .tag(AppTab.timeline)

                CalendarPage()
                    .tabItem { Label("日历", systemImage: "calendar") }
                    .tag(AppTab.calendar)

                TagPage()
                    .tabItem { Label("标签", systemImage: "tag") }
                    .tag(AppTab.tags)

                MinePage()
                    .tabItem { Label("我的", systemImage: "person.crop.circle") }
                    .tag(AppTab.mine)
            }
            .tint(Theme.accent)
            .environmentObject(store)
            .environmentObject(settingsStore)

            if privacy.isActive {
                privacyBanner
            }

            if lockService.isLocked {
                LockScreenView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .toastOverlay()
        #if DEBUG
        .fullScreenCover(item: $debugTarget) { target in
            DebugScreenHost(target: target)
        }
        #endif
        .task {
            #if DEBUG
            debugTarget = DebugRouter.requested()
            #endif
            store.reload()
            if AppLockService.shared.hasPassword {
                lockService.lock()
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            switch newValue {
            case .background:
                DiaryDatabase.shared.flush()
                if lockService.lockWhenLeave && lockService.hasPassword {
                    lockService.lock()
                }
            case .active:
                if BackgroundSessionBridge.shared.completionHandler != nil {
                    BackgroundSessionBridge.shared.finish()
                }
            default:
                break
            }
        }
        .onChange(of: privacy.isActive) { _, _ in
            store.reload()
        }
        .alert("出错了", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("好", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var privacyBanner: some View {
        VStack {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                Text("隐私空间")
                Spacer()
                Button("退出") {
                    privacy.exit()
                    ToastCenter.shared.show("已退出隐私空间")
                }
                .font(.caption.weight(.semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .adaptiveGlass(Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 4)
            Spacer()
        }
        .allowsHitTesting(true)
        .zIndex(1)
    }
}

enum AppTab: Hashable {
    case timeline, calendar, tags, mine
}
