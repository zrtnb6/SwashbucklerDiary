import SwiftUI

/// 日记时间线。
struct DiaryListView: View {
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var path = NavigationPath()
    @State private var editorTarget: EditorTarget?
    @State private var showSearch = false
    @State private var selectedTagForFilter: Tag?
    @State private var filter = DiaryStore.Filter()
    @State private var showDeleteConfirm = false
    @State private var pendingDelete: Diary?
    @State private var showTemplateChoice = false

    private var filteredDiaries: [Diary] {
        store.apply(filter, to: store.diaries)
    }

    private var grouped: [(day: Date, diaries: [Diary])] {
        let calendar = Calendar.current
        var buckets: [Date: [Diary]] = [:]
        for diary in filteredDiaries {
            let day = calendar.startOfDay(for: diary.createTime)
            buckets[day, default: []].append(diary)
        }
        return buckets
            .map { (day: $0.key, diaries: $0.value) }
            .sorted { store.sort == .timeAscending || store.sort == .updateAscending ? $0.day < $1.day : $0.day > $1.day }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                    if settingsStore.settings.welcomeText || grouped.isEmpty == false {
                        header
                    }

                    if grouped.isEmpty {
                        EmptyStateView(
                            systemImage: "book.closed",
                            title: filter.isEmpty ? "还没有日记" : "没有匹配的日记",
                            message: filter.isEmpty ? "记录此刻的想法，它只属于你。" : "试试换个关键词或清除筛选条件。",
                            actionTitle: filter.isEmpty ? "写一篇" : "清除筛选",
                            action: {
                                if filter.isEmpty {
                                    createDiary()
                                } else {
                                    filter = DiaryStore.Filter()
                                }
                            }
                        )
                        .frame(minHeight: 360)
                    } else {
                        ForEach(grouped, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                dayHeader(group.day, count: group.diaries.count)
                                ForEach(group.diaries) { diary in
                                    DiaryCard(diary: diary) {
                                        path.append(Route.detail(diary.id))
                                    } onEdit: {
                                        editorTarget = EditorTarget(id: diary.id, isNew: false)
                                    }
                                    .contextMenu {
                                        contextMenu(for: diary)
                                    }
                                    .padding(.horizontal, Theme.pagePadding)
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 90)
                }
                .padding(.top, 4)
            }
            .pageBackground()
            .navigationTitle(store.isPrivacyActive ? "隐私空间" : "侠客日记")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showSearch = true
                        } label: {
                            Label("搜索", systemImage: "magnifyingglass")
                        }
                        Divider()
                        Picker("排序", selection: Binding(
                            get: { store.sort },
                            set: { store.sort = $0; store.reload() }
                        )) {
                            ForEach(DiarySort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        createDiary()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .tint(Theme.accent)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .detail(let id):
                    DiaryDetailPage(diaryID: id, onEdit: { editorTarget = EditorTarget(id: id, isNew: false) })
                case .tag(let id):
                    TagDetailPage(tagID: id)
                case .location(let name):
                    LocationDetailPage(name: name)
                case .media:
                    MediaLibraryPage()
                case .templates:
                    TemplateListPage(onEdit: { id in editorTarget = EditorTarget(id: id, isNew: false) })
                }
            }
            .fullScreenCover(item: $editorTarget) { target in
                DiaryEditorPage(diaryID: target.id, isNew: target.isNew) {
                    editorTarget = nil
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchPage { diary in
                showSearch = false
                path.append(Route.detail(diary.id))
            }
            .environmentObject(store)
        }
        .confirmationDialog("删除这篇日记？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let pendingDelete { store.delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("删除后可在备份中找回，但当前设备上不可撤销。")
        }
        .confirmationDialog("选择模板", isPresented: $showTemplateChoice, titleVisibility: .visible) {
            ForEach(store.templates) { template in
                Button(template.displayTitle) { createFromTemplate(template) }
            }
            Button("空白日记") {
                let diary = Diary()
                store.save(diary)
                editorTarget = EditorTarget(id: diary.id, isNew: true)
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 子视图

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if settingsStore.settings.welcomeText {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.title3.weight(.semibold))
                    Text(settingsStore.settings.sign.isEmpty ? "今天也要好好记下来。" : settingsStore.settings.sign)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if settingsStore.settings.statisticsCard {
                StatisticsStrip(statistics: store.statistics)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = settingsStore.settings.nickName.isEmpty ? "" : "，\(settingsStore.settings.nickName)"
        switch hour {
        case 5..<11: return "早上好\(name)"
        case 11..<14: return "中午好\(name)"
        case 14..<18: return "下午好\(name)"
        case 18..<23: return "晚上好\(name)"
        default: return "夜深了\(name)"
        }
    }

    private func dayHeader(_ day: Date, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(DateText.dayTitle(day))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count) 篇")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func contextMenu(for diary: Diary) -> some View {
        Button {
            editorTarget = EditorTarget(id: diary.id, isNew: false)
        } label: {
            Label("编辑", systemImage: "pencil")
        }
        Button {
            store.toggleTop(diary)
        } label: {
            Label(diary.top ? "取消置顶" : "置顶", systemImage: "pin")
        }
        Button {
            UIPasteboard.general.string = diary.content ?? ""
            ToastCenter.shared.show("已复制正文")
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        Button {
            let reference = "《\(diary.displayTitle)》\n\(diary.content ?? "")"
            UIPasteboard.general.string = reference
            ToastCenter.shared.show("已复制引用")
        } label: {
            Label("复制引用", systemImage: "text.quote")
        }
        Button {
            store.toggleTemplate(diary)
        } label: {
            Label(diary.template ? "取消模板" : "设为模板", systemImage: "square.stack.3d.up")
        }
        if settingsStore.settings.setPrivacyDiary {
            Button {
                store.moveToOtherSpace(diary)
                ToastCenter.shared.show(store.isPrivacyActive ? "已移出隐私空间" : "已移到隐私空间")
            } label: {
                Label(store.isPrivacyActive ? "移出隐私空间" : "移到隐私空间",
                      systemImage: store.isPrivacyActive ? "lock.open" : "lock")
            }
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = diary
            showDeleteConfirm = true
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func createDiary() {
        // 设置为「创建时选择模板」且有模板时，先让用户挑一个
        if settingsStore.settings.selectTemplateWhenCreate, !store.templates.isEmpty {
            showTemplateChoice = true
            return
        }
        var diary = Diary()
        if let defaultID = UUID(uuidString: settingsStore.settings.defaultTemplateId),
           let template = store.templates.first(where: { $0.id == defaultID }) {
            diary.title = template.title
            diary.content = template.content
            diary.tags = template.tags
        }
        store.save(diary)
        editorTarget = EditorTarget(id: diary.id, isNew: true)
    }

    private func createFromTemplate(_ template: Diary) {
        var diary = Diary()
        diary.title = template.title
        diary.content = template.content
        diary.tags = template.tags
        store.save(diary)
        editorTarget = EditorTarget(id: diary.id, isNew: true)
    }

}

struct EditorTarget: Identifiable, Hashable {
    let id: UUID
    let isNew: Bool
}

enum Route: Hashable {
    case detail(UUID)
    case tag(UUID)
    case location(String)
    case media
    case templates
}

extension DiaryStore {
    var isPrivacyActive: Bool {
        DiaryDatabase.shared.isPrivacyMode
    }
}

// MARK: - 统计条

struct StatisticsStrip: View {
    let statistics: DiaryStore.Statistics

    var body: some View {
        HStack(spacing: 0) {
            item(value: "\(statistics.diaryCount)", label: "篇日记")
            divider
            item(value: "\(statistics.wordCount)", label: "字")
            divider
            item(value: "\(statistics.streak)", label: "连续天")
            divider
            item(value: "\(statistics.tagCount)", label: "个标签")
        }
        .padding(.vertical, 14)
        .cardBackground()
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(width: 1, height: 22)
    }

    private func item(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
