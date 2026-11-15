import SwiftUI

/// 日记卡片。
///
/// 刻意不做「一屏全是同款圆角卡片」：时间信息固定在最左侧一列，
/// 正文区不加边框，只靠留白与字号分层，阅读时视线不被装饰打断。
struct DiaryCard: View {
    let diary: Diary
    var onTap: () -> Void
    var onEdit: () -> Void

    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                timeColumn

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if diary.top {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent)
                        }
                        if diary.template {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text(diary.displayTitle)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }

                    if !diary.plainSummary.isEmpty {
                        Text(diary.plainSummary)
                            .font(.system(.subheadline))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }

                    if !diary.resources.isEmpty {
                        mediaStrip
                    }

                    HStack(spacing: 10) {
                        if settingsStore.settings.diaryCardTags {
                            ForEach(diary.tags.prefix(3)) { tag in
                                TagChip(name: tag.name)
                            }
                        }
                        if settingsStore.settings.diaryCardLocation, let location = diary.location, !location.isEmpty {
                            MetaChip(systemImage: "location", text: location)
                        }
                        Spacer(minLength: 0)
                        if settingsStore.settings.diaryCardIcon {
                            if let mood = diary.mood, !mood.isEmpty {
                                Image(systemName: DiaryMood.symbol(for: mood))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            if let weather = diary.weather, !weather.isEmpty {
                                Image(systemName: DiaryWeather.symbol(for: weather))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                Haptics.light()
            }
        )
    }

    private var timeColumn: some View {
        VStack(spacing: 2) {
            Text(dayNumber)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.accent)
            Text(weekday)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 34)
    }

    private var dayNumber: String {
        let day = Calendar.current.component(.day, from: diary.createTime)
        return String(day)
    }

    private var weekday: String {
        let weekday = Calendar.current.component(.weekday, from: diary.createTime)
        return Theme.weekdayName(weekday)
    }

    private var mediaStrip: some View {
        HStack(spacing: 6) {
            ForEach(diary.resources.prefix(4)) { resource in
                mediaThumb(resource)
            }
            if diary.resources.count > 4 {
                Text("+\(diary.resources.count - 4)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func mediaThumb(_ resource: MediaResource) -> some View {
        if resource.resourceType == .image,
           let url = resource.fileURL,
           FileManager.default.fileExists(atPath: url.path) {
            AsyncThumbnail(url: url)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(systemName: resource.resourceType.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtleFill))
        }
    }
}

/// 列表缩略图：只解码到 160px，避免长列表里大图拖慢滚动。
struct AsyncThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.subtleFill)
            }
        }
        .task(id: url) {
            let loaded = await ImageCache.shared.thumbnail(for: url, maxPixel: 160)
            await MainActor.run { image = loaded }
        }
    }
}
