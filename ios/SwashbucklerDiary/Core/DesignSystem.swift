import SwiftUI

/// 视觉规范。
///
/// 取向：中性灰底 + 单一强调色（深松绿），克制使用材质，
/// 只在浮层（工具栏、弹层）上使用 Liquid Glass，正文区域保持纯色，
/// 避免满屏玻璃造成阅读疲劳。
enum Theme {
    /// 强调色。深色模式下换成同色系的浅一档，避免深青压在黑底上看不清。
    static let accent = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.361, green: 0.741, blue: 0.686, alpha: 1)   // #5CBDAF
            : UIColor(red: 0.129, green: 0.400, blue: 0.373, alpha: 1)   // #21665F
    })

    static let accentSoft = accent.opacity(0.14)

    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 12
    static let pagePadding: CGFloat = 16

    static let separator = Color.primary.opacity(0.07)
    static let subtleFill = Color.primary.opacity(0.045)

    /// 星期与日期格式跟随用户设置
    static func weekdayName(_ weekday: Int) -> String {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return "周" + names[max(0, min(6, weekday - 1))]
    }
}

// MARK: - 玻璃材质

extension View {
    /// 浮层玻璃背景。
    ///
    /// 这里必须按**编译器版本**分支而不是只用 `if #available`：
    /// iOS 26 的 `glassEffect` 在旧 SDK（如 Xcode 16.4 / iOS 18.5）里根本不存在，
    /// 可用性判断只能挡住运行时，挡不住编译期报错。
    #if compiler(>=6.2)
    @ViewBuilder
    func adaptiveGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.materialFallback(shape)
        }
    }
    #else
    @ViewBuilder
    func adaptiveGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        self.materialFallback(shape)
    }
    #endif

    /// 旧系统 / 旧 SDK 的视觉降级：超薄材质 + 极细描边，层级接近玻璃但不依赖新 API。
    fileprivate func materialFallback<S: Shape>(_ shape: S) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.6))
    }

    func cardBackground(radius: CGFloat = Theme.cardRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    func pageBackground() -> some View {
        background(Color(uiColor: .systemGroupedBackground))
    }
}

// MARK: - 通用组件

struct TagChip: View {
    let name: String
    var isSelected: Bool = false
    var onTap: (() -> Void)?

    var body: some View {
        let label = Text(name)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isSelected ? Theme.accent.opacity(0.16) : Theme.subtleFill)
            )
            .foregroundStyle(isSelected ? Theme.accent : Color.secondary)

        if let onTap {
            Button(action: onTap) { label }.buttonStyle(.plain)
        } else {
            label
        }
    }
}

struct MetaChip: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .medium))
            Text(text).font(.caption2)
        }
        .foregroundStyle(.secondary)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pagePadding)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}

/// 轻量提示条，替代原项目里的 Snackbar。
struct ToastView: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            Text(message).font(.subheadline).lineLimit(3)
        }
        .foregroundStyle(isError ? Color.red : Theme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .adaptiveGlass(Capsule())
        .padding(.horizontal, 24)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// 简易 Toast 控制器，页面里 `.toast(message:)` 即可。
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var message: String?
    @Published var isError = false

    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, isError: Bool = false) {
        self.message = message
        self.isError = isError
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.snappy) { self?.message = nil }
            }
        }
    }
}

extension View {
    func toastOverlay() -> some View {
        modifier(ToastOverlayModifier())
    }
}

private struct ToastOverlayModifier: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = center.message {
                ToastView(message: message, isError: center.isError)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - 日期格式化

enum DateText {
    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "M月d日 EEEE"
        } else {
            formatter.dateFormat = "yyyy年M月d日 EEEE"
        }
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func full(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 心情 / 天气

enum DiaryMood: String, CaseIterable, Identifiable {
    case happy = "开心"
    case calm = "平静"
    case excited = "兴奋"
    case tired = "疲惫"
    case sad = "难过"
    case angry = "生气"
    case anxious = "焦虑"
    case grateful = "感恩"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .happy: return "sun.max"
        case .calm: return "leaf"
        case .excited: return "sparkles"
        case .tired: return "moon.zzz"
        case .sad: return "cloud.rain"
        case .angry: return "flame"
        case .anxious: return "wind"
        case .grateful: return "heart"
        }
    }
}

enum DiaryWeather: String, CaseIterable, Identifiable {
    case sunny = "晴"
    case cloudy = "多云"
    case overcast = "阴"
    case rain = "雨"
    case snow = "雪"
    case wind = "风"
    case fog = "雾"
    case thunderstorm = "雷雨"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .sunny: return "sun.max.fill"
        case .cloudy: return "cloud.sun.fill"
        case .overcast: return "cloud.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "snowflake"
        case .wind: return "wind"
        case .fog: return "cloud.fog.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        }
    }

    /// 兼容旧数据里存英文 key 的情况
    static func symbol(for raw: String) -> String {
        if let match = DiaryWeather(rawValue: raw) { return match.symbol }
        switch raw.lowercased() {
        case "sunny": return "sun.max.fill"
        case "cloudy": return "cloud.sun.fill"
        case "overcast": return "cloud.fill"
        case "rain": return "cloud.rain.fill"
        case "snow": return "snowflake"
        case "wind": return "wind"
        case "fog": return "cloud.fog.fill"
        default: return "cloud"
        }
    }
}

extension DiaryMood {
    static func symbol(for raw: String) -> String {
        if let match = DiaryMood(rawValue: raw) { return match.symbol }
        switch raw.lowercased() {
        case "happy": return "sun.max"
        case "calm": return "leaf"
        case "excited": return "sparkles"
        case "tired": return "moon.zzz"
        case "sad": return "cloud.rain"
        case "angry": return "flame"
        case "anxious": return "wind"
        case "grateful": return "heart"
        default: return "face.smiling"
        }
    }
}
