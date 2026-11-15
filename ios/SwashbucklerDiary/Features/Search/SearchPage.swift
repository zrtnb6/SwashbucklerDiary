import SwiftUI

/// 搜索页：关键词 + 多维筛选。
struct SearchPage: View {
    var onSelect: (Diary) -> Void

    @EnvironmentObject private var store: DiaryStore
    @Environment(\.dismiss) private var dismiss

    @State private var filter = DiaryStore.Filter()
    @State private var showFilters = false
    @FocusState private var searchFocused: Bool

    private var results: [Diary] {
        store.apply(filter, to: store.diaries)
    }

    private var allMoods: [String] {
        Array(Set(store.diaries.compactMap { $0.mood }.filter { !$0.isEmpty })).sorted()
    }

    private var allWeathers: [String] {
        Array(Set(store.diaries.compactMap { $0.weather }.filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                activeFilterBar
                Divider()
                resultList
            }
            .pageBackground()
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .tint(Theme.accent)
                }
            }
            .sheet(isPresented: $showFilters) {
                FilterSheet(filter: $filter, moods: allMoods, weathers: allWeathers)
                    .presentationDetents([.medium, .large])
            }
            .onAppear { searchFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField("搜索标题、正文、标签、地点", text: $filter.keyword)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !filter.keyword.isEmpty {
                Button {
                    filter.keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.subtleFill))
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 8)
    }

    private var activeFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !filter.tagIDs.isEmpty {
                    clearChip("\(filter.tagIDs.count) 个标签") { filter.tagIDs.removeAll() }
                }
                ForEach(Array(filter.moods), id: \.self) { mood in
                    clearChip(mood) { filter.moods.remove(mood) }
                }
                ForEach(Array(filter.weathers), id: \.self) { weather in
                    clearChip(weather) { filter.weathers.remove(weather) }
                }
                if filter.onlyWithMedia {
                    clearChip("含附件") { filter.onlyWithMedia = false }
                }
                if filter.dateRange != nil {
                    clearChip("时间范围") { filter.dateRange = nil }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
        }
        .frame(height: filter.isEmpty ? 0 : 34)
    }

    private func clearChip(_ title: String, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 3) {
                Text(title).font(.caption)
                Image(systemName: "xmark").font(.system(size: 8))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.accentSoft))
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                HStack {
                    Text("\(results.count) 条结果")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, Theme.pagePadding)

                if results.isEmpty {
                    EmptyStateView(
                        systemImage: "magnifyingglass",
                        title: filter.keyword.isEmpty ? "输入关键词开始搜索" : "没有找到相关日记",
                        message: filter.keyword.isEmpty ? nil : "试试更短的关键词，或放宽筛选条件。"
                    )
                    .frame(minHeight: 280)
                }

                ForEach(results) { diary in
                    Button {
                        onSelect(diary)
                    } label: {
                        SearchResultRow(diary: diary, keyword: filter.keyword)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.pagePadding)
                }
                Color.clear.frame(height: 40)
            }
            .padding(.top, 8)
        }
    }
}

private struct SearchResultRow: View {
    let diary: Diary
    let keyword: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(diary.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(DateText.dayTitle(diary.createTime))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let snippet = snippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !diary.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(diary.tags.prefix(4)) { tag in
                        Text("#\(tag.name)").font(.caption2).foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(radius: 12)
    }

    /// 截取关键词附近的片段，命中位置更直观
    private var snippet: String? {
        guard let content = diary.content, !content.isEmpty else { return nil }
        let plain = MarkdownParser.plainText(content)
        guard !keyword.isEmpty, let range = plain.range(of: keyword, options: .caseInsensitive) else {
            return String(plain.prefix(90))
        }
        let start = plain.index(range.lowerBound, offsetBy: -30, limitedBy: plain.startIndex) ?? plain.startIndex
        let end = plain.index(range.upperBound, offsetBy: 60, limitedBy: plain.endIndex) ?? plain.endIndex
        let prefix = start == plain.startIndex ? "" : "…"
        let suffix = end == plain.endIndex ? "" : "…"
        return prefix + String(plain[start..<end]) + suffix
    }
}

/// 高级筛选。
private struct FilterSheet: View {
    @Binding var filter: DiaryStore.Filter
    let moods: [String]
    let weathers: [String]

    @EnvironmentObject private var store: DiaryStore
    @Environment(\.dismiss) private var dismiss

    @State private var useDateRange = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("标签") {
                    if store.tags.isEmpty {
                        Text("还没有标签").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(store.tags) { tag in
                        Button {
                            if filter.tagIDs.contains(tag.id) {
                                filter.tagIDs.remove(tag.id)
                            } else {
                                filter.tagIDs.insert(tag.id)
                            }
                        } label: {
                            HStack {
                                Text(tag.name).foregroundStyle(.primary)
                                Spacer()
                                if filter.tagIDs.contains(tag.id) {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }

                if !moods.isEmpty {
                    Section("心情") {
                        FlexibleChips(items: moods, selection: $filter.moods)
                    }
                }

                if !weathers.isEmpty {
                    Section("天气") {
                        FlexibleChips(items: weathers, selection: $filter.weathers)
                    }
                }

                Section {
                    Toggle("只看含附件的日记", isOn: $filter.onlyWithMedia)
                    Toggle("限定时间范围", isOn: $useDateRange)
                    if useDateRange {
                        DatePicker("开始", selection: $startDate, displayedComponents: .date)
                        DatePicker("结束", selection: $endDate, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if filter.dateRange != nil {
                    useDateRange = true
                    startDate = filter.dateRange?.lowerBound ?? startDate
                    endDate = filter.dateRange?.upperBound ?? endDate
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("重置") {
                        filter = DiaryStore.Filter()
                        useDateRange = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        if useDateRange {
                            let start = Calendar.current.startOfDay(for: startDate)
                            let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) ?? endDate
                            filter.dateRange = start <= end ? start...end : end...start
                        } else {
                            filter.dateRange = nil
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct FlexibleChips: View {
    let items: [String]
    @Binding var selection: Set<String>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                TagChip(name: item, isSelected: selection.contains(item)) {
                    if selection.contains(item) {
                        selection.remove(item)
                    } else {
                        selection.insert(item)
                    }
                }
            }
        }
    }
}
