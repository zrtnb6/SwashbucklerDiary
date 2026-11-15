import SwiftUI

/// 标签页：所有标签的分组浏览。
struct TagPage: View {
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var path = NavigationPath()
    @State private var editorTarget: EditorTarget?
    @State private var renameTarget: Tag?
    @State private var renameText = ""
    @State private var deleteTarget: Tag?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.tags.isEmpty {
                        EmptyStateView(
                            systemImage: "tag",
                            title: "还没有标签",
                            message: "给日记加上标签，回头更容易找到。"
                        )
                        .frame(minHeight: 320)
                    } else {
                        tagCloud
                        locationSection
                    }
                    Color.clear.frame(height: 80)
                }
                .padding(.top, 8)
            }
            .pageBackground()
            .navigationTitle("标签")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .detail(let id):
                    DiaryDetailPage(diaryID: id) { editorTarget = EditorTarget(id: id, isNew: false) }
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
            .alert("重命名标签", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("标签名", text: $renameText)
                Button("保存") { commitRename() }
                Button("取消", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog("删除标签？", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ), titleVisibility: .visible) {
                Button("删除", role: .destructive) { commitDelete() }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("只会删除标签本身，日记内容不受影响。")
            }
        }
    }

    private var tagCloud: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "全部标签", subtitle: "\(store.tags.count) 个")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                ForEach(store.tags) { tag in
                    NavigationLink(value: Route.tag(tag.id)) {
                        tagCard(tag)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameTarget = tag
                            renameText = tag.name
                        } label: { Label("重命名", systemImage: "pencil") }
                        Button(role: .destructive) {
                            deleteTarget = tag
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    private func tagCard(_ tag: Tag) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "number")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                Text(tag.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            Text("\(tag.diaryCount) 篇")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground(radius: 12)
    }

    private var locationSection: some View {
        Group {
            if !store.locations.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "地点", subtitle: "\(store.locations.count) 个")
                    ForEach(store.locations.prefix(12)) { location in
                        NavigationLink(value: Route.location(location.name)) {
                            HStack(spacing: 10) {
                                Image(systemName: "location")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(Theme.accentSoft))
                                Text(location.name).font(.subheadline)
                                Spacer()
                                Text("\(location.diaryCount) 篇")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.pagePadding)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func commitRename() {
        guard let tag = renameTarget, let db = try? DiaryDatabase.shared.current else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { renameTarget = nil; return }
        try? TagRepository(db: db).rename(tag.id, to: name)
        renameTarget = nil
        store.reload()
    }

    private func commitDelete() {
        guard let tag = deleteTarget, let db = try? DiaryDatabase.shared.current else { return }
        try? TagRepository(db: db).delete(ids: [tag.id])
        deleteTarget = nil
        store.reload()
    }
}

/// 单个标签下的日记列表。
struct TagDetailPage: View {
    let tagID: UUID

    @EnvironmentObject private var store: DiaryStore
    @State private var editorTarget: EditorTarget?

    private var tag: Tag? { store.tags.first { $0.id == tagID } }
    private var diaries: [Diary] { store.diaries(taggedWith: tagID) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if diaries.isEmpty {
                    EmptyStateView(systemImage: "tag.slash", title: "没有日记使用这个标签")
                        .frame(minHeight: 320)
                }
                ForEach(diaries) { diary in
                    NavigationLink(value: Route.detail(diary.id)) {
                        DiaryCard(diary: diary) {} onEdit: {
                            editorTarget = EditorTarget(id: diary.id, isNew: false)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.pagePadding)
                }
                Color.clear.frame(height: 80)
            }
            .padding(.top, 8)
        }
        .pageBackground()
        .navigationTitle(tag?.name ?? "标签")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $editorTarget) { target in
            DiaryEditorPage(diaryID: target.id, isNew: target.isNew) { editorTarget = nil }
        }
    }
}

/// 某个地点下的日记。
struct LocationDetailPage: View {
    let name: String

    @EnvironmentObject private var store: DiaryStore
    @State private var editorTarget: EditorTarget?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                let diaries = store.diaries(atLocation: name)
                if diaries.isEmpty {
                    EmptyStateView(systemImage: "mappin.slash", title: "没有相关日记")
                        .frame(minHeight: 320)
                }
                ForEach(diaries) { diary in
                    NavigationLink(value: Route.detail(diary.id)) {
                        DiaryCard(diary: diary) {} onEdit: {
                            editorTarget = EditorTarget(id: diary.id, isNew: false)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.pagePadding)
                }
            }
            .padding(.top, 8)
        }
        .pageBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $editorTarget) { target in
            DiaryEditorPage(diaryID: target.id, isNew: target.isNew) { editorTarget = nil }
        }
    }
}

/// 模板列表。
struct TemplateListPage: View {
    var onEdit: (UUID) -> Void
    @EnvironmentObject private var store: DiaryStore
    @State private var showCreate = false

    var body: some View {
        List {
            if store.templates.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有模板").font(.subheadline.weight(.medium))
                        Text("把常用结构保存为模板，新建日记时一键套用。在任意日记的菜单里选择「设为模板」即可。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Section("模板") {
                    ForEach(store.templates) { template in
                        Button {
                            onEdit(template.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.displayTitle).font(.subheadline.weight(.medium))
                                if !template.plainSummary.isEmpty {
                                    Text(template.plainSummary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                store.toggleTemplate(template)
                            } label: { Label("取消模板", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("模板")
        .navigationBarTitleDisplayMode(.inline)
    }
}
