import SwiftUI

/// 日历页：月视图 + 当日日记。
struct CalendarPage: View {
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var month: Date = Date()
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var path = NavigationPath()
    @State private var editorTarget: EditorTarget?

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = settingsStore.settings.firstDayOfWeek + 1
        return calendar
    }

    private var days: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: month)?.count ?? 30

        var result: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            if let date = calendar.date(byAdding: .day, value: offset, to: monthInterval.start) {
                result.append(calendar.startOfDay(for: date))
            }
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private var weekdaySymbols: [String] {
        let base = ["日", "一", "二", "三", "四", "五", "六"]
        let start = calendar.firstWeekday - 1
        return (0..<7).map { base[(start + $0) % 7] }
    }

    private var selectedDiaries: [Diary] {
        store.diaries(on: selectedDay)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    monthHeader
                    weekdayRow
                    grid
                    Divider().padding(.horizontal, Theme.pagePadding)
                    daySection
                    Color.clear.frame(height: 80)
                }
                .padding(.top, 8)
            }
            .pageBackground()
            .navigationTitle("日历")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorTarget = nil
                        createDiaryOnSelectedDay()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Theme.accent)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .detail(let id):
                    DiaryDetailPage(diaryID: id) {
                        editorTarget = EditorTarget(id: id, isNew: false)
                    }
                case .tag(let id):
                    TagDetailPage(tagID: id)
                case .location(let name):
                    LocationDetailPage(name: name)
                case .media:
                    MediaLibraryPage()
                case .templates:
                    TemplateListPage { id in editorTarget = EditorTarget(id: id, isNew: false) }
                }
            }
            .fullScreenCover(item: $editorTarget) { target in
                DiaryEditorPage(diaryID: target.id, isNew: target.isNew) { editorTarget = nil }
            }
        }
    }

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()
            VStack(spacing: 2) {
                Text(monthTitle)
                    .font(.headline)
                Text("\(store.countsByDay.filter { $0.key.hasPrefix(monthKey) }.values.reduce(0, +)) 篇")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()

            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        let count = store.countsByDay[Self.dayKey(day)] ?? 0

        return Button {
            selectedDay = day
            Haptics.selection()
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(.subheadline, design: .rounded).weight(isToday ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : (isToday ? Theme.accent : Color.primary))
                Circle()
                    .fill(count > 0 ? (isSelected ? Color.white : Theme.accent) : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.accent : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(DateText.dayTitle(selectedDay))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(selectedDiaries.count) 篇")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, Theme.pagePadding)

            if selectedDiaries.isEmpty {
                VStack(spacing: 8) {
                    Text("这天还没有日记").font(.footnote).foregroundStyle(.secondary)
                    Button("写一篇") { createDiaryOnSelectedDay() }
                        .font(.footnote.weight(.medium))
                        .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ForEach(selectedDiaries) { diary in
                    DiaryCard(diary: diary) {
                        path.append(Route.detail(diary.id))
                    } onEdit: {
                        editorTarget = EditorTarget(id: diary.id, isNew: false)
                    }
                    .padding(.horizontal, Theme.pagePadding)
                }
            }
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: month)
    }

    private var monthKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: month)
    }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        withAnimation(.snappy) { month = next }
    }

    private func createDiaryOnSelectedDay() {
        var diary = Diary()
        // 落在选中那天的当前时刻，符合「补记」的直觉
        let components = calendar.dateComponents([.hour, .minute], from: Date())
        if let combined = calendar.date(bySettingHour: components.hour ?? 12,
                                       minute: components.minute ?? 0,
                                       second: 0, of: selectedDay) {
            diary.createTime = combined
            diary.updateTime = combined
        }
        store.save(diary)
        editorTarget = EditorTarget(id: diary.id, isNew: true)
    }
}
