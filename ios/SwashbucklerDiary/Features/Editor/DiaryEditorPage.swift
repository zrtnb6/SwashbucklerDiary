import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 日记编辑器。
///
/// 设计要点（对应需求里对编辑器的硬性要求）：
/// - 输入流畅：正文走原生 UITextView，长文本不经过 SwiftUI 的 diff；
/// - 自动保存：按设置里的间隔防抖写库，切后台、点完成、手势返回都会强制保存；
/// - 光标准确：所有 Markdown 片段插入都基于 `selectedRange`；
/// - 键盘与布局：编辑区用 `safeAreaInset` 承载工具栏，键盘弹出时不会顶掉内容；
/// - 中断恢复：草稿实时落库，异常退出后重进仍是最后一次成功保存的内容；
/// - 撤销重做：直接用 UITextView 的 UndoManager。
struct DiaryEditorPage: View {
    let diaryID: UUID
    let isNew: Bool
    var onClose: () -> Void

    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @StateObject private var proxy = MarkdownEditorProxy()

    @State private var draft: Diary?
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var mood: String = ""
    @State private var weather: String = ""
    @State private var location: String = ""
    @State private var tags: [Tag] = []
    @State private var resources: [MediaResource] = []

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var showTagEditor = false
    @State private var showPreview = false
    @State private var showMetaSheet = false
    @State private var showDiscardConfirm = false

    @State private var autosaveTask: Task<Void, Never>?
    @State private var lastSavedAt: Date?
    @State private var hasLoaded = false
    @State private var isSaving = false
    @FocusState private var titleFocused: Bool

    private var autosaveInterval: Double {
        let seconds = settingsStore.settings.editAutoSave
        return seconds > 0 ? Double(seconds) : 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                metaBar
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, 6)

                TextField("标题", text: $title, axis: .vertical)
                    .font(.system(.title2, weight: .semibold))
                    .focused($titleFocused)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, 10)
                    .onChange(of: title) { _, _ in scheduleAutosave() }

                MarkdownTextView(
                    text: $content,
                    proxy: proxy,
                    placeholder: "写点什么…",
                    fontSize: 17,
                    lineSpacing: 5,
                    autoFocus: isNew
                )
                .padding(.horizontal, Theme.pagePadding)
                .onChange(of: content) { _, _ in scheduleAutosave() }

                statusBar
            }
            .pageBackground()
            .navigationTitle(isNew ? "新日记" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { close() }
                }
                ToolbarItem(placement: .principal) {
                    if let lastSavedAt {
                        Text("已保存 \(DateText.time(lastSavedAt))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        proxy.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    Button {
                        showPreview = true
                    } label: {
                        Image(systemName: "eye")
                    }
                    Menu {
                        Button {
                            proxy.undo()
                        } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                        Button {
                            proxy.redo()
                        } label: { Label("重做", systemImage: "arrow.uturn.forward") }
                        Divider()
                        Button {
                            proxy.insertBlock(DateText.full(Date()) + "\n")
                        } label: { Label("插入当前时间", systemImage: "clock") }
                        Button {
                            showMetaSheet = true
                        } label: { Label("心情 / 天气 / 地点", systemImage: "cloud.sun") }
                        Button {
                            showTagEditor = true
                        } label: { Label("标签", systemImage: "tag") }
                        Divider()
                        Button {
                            save(force: true)
                            ToastCenter.shared.show("已保存")
                        } label: { Label("立即保存", systemImage: "tray.and.arrow.down") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                markdownToolbar
            }
            .sheet(isPresented: $showPreview) {
                NavigationStack {
                    ScrollView {
                        MarkdownView(markdown: content, lineSpacing: 7)
                            .padding(Theme.pagePadding)
                    }
                    .navigationTitle("预览")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showPreview = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showMetaSheet) {
                MetaEditorSheet(mood: $mood, weather: $weather, location: $location)
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showTagEditor) {
                TagEditorSheet(selected: $tags)
                    .presentationDetents([.medium, .large])
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 9, matching: .images)
            .onChange(of: photoItems) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task { await importPhotos(newValue) }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.audio, .movie, .image, .data],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    if let image { insertImage(image) }
                } onCancel: {
                    showCamera = false
                }
                .ignoresSafeArea()
            }
            .task {
                loadIfNeeded()
            }
            .onDisappear {
                autosaveTask?.cancel()
                if hasLoaded { save(force: true) }
            }
            .interactiveDismissDisabled(false)
        }
    }

    // MARK: - 副标题栏

    private var metaBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("不设置") { mood = ""; scheduleAutosave() }
                    ForEach(DiaryMood.allCases) { item in
                        Button {
                            mood = item.rawValue
                            scheduleAutosave()
                        } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                        }
                    }
                } label: {
                    pill(icon: mood.isEmpty ? "face.smiling" : DiaryMood.symbol(for: mood),
                         text: mood.isEmpty ? "心情" : mood,
                         active: !mood.isEmpty)
                }

                Menu {
                    Button("不设置") { weather = ""; scheduleAutosave() }
                    ForEach(DiaryWeather.allCases) { item in
                        Button {
                            weather = item.rawValue
                            scheduleAutosave()
                        } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                        }
                    }
                } label: {
                    pill(icon: weather.isEmpty ? "cloud" : DiaryWeather.symbol(for: weather),
                         text: weather.isEmpty ? "天气" : weather,
                         active: !weather.isEmpty)
                }

                Button {
                    showMetaSheet = true
                } label: {
                    pill(icon: "location", text: location.isEmpty ? "地点" : location, active: !location.isEmpty)
                }

                Button {
                    showTagEditor = true
                } label: {
                    pill(icon: "tag", text: tags.isEmpty ? "标签" : "\(tags.count) 个标签", active: !tags.isEmpty)
                }

                if !tags.isEmpty {
                    ForEach(tags) { tag in
                        TagChip(name: "#\(tag.name)") {
                            tags.removeAll { $0.id == tag.id }
                            scheduleAutosave()
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func pill(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(active ? Theme.accentSoft : Theme.subtleFill))
        .foregroundStyle(active ? Theme.accent : Color.secondary)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(content.count) 字")
            if !resources.isEmpty {
                Text("\(resources.count) 个附件")
            }
            Spacer()
            if autosaveInterval == 0 {
                Text("自动保存已关闭")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 6)
    }

    // MARK: - Markdown 工具栏

    private var markdownToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                toolbarButton("textformat.size", "标题") {
                    proxy.insert("", wrapping: ("## ", ""))
                }
                toolbarButton("bold", "加粗") {
                    proxy.insert("", wrapping: ("**", "**"))
                }
                toolbarButton("italic", "斜体") {
                    proxy.insert("", wrapping: ("*", "*"))
                }
                toolbarButton("strikethrough", "删除线") {
                    proxy.insert("", wrapping: ("~~", "~~"))
                }
                toolbarButton("list.bullet", "列表") {
                    proxy.insert("", linePrefix: "- ")
                }
                toolbarButton("checklist", "待办") {
                    proxy.insert("", linePrefix: "- [ ] ")
                }
                toolbarButton("text.quote", "引用") {
                    proxy.insert("", linePrefix: "> ")
                }
                toolbarButton("chevron.left.forwardslash.chevron.right", "代码") {
                    proxy.insertBlock("```\n\n```\n")
                }
                toolbarButton("function", "公式") {
                    proxy.insert("", wrapping: ("$", "$"))
                }
                toolbarButton("link", "链接") {
                    proxy.insert("", wrapping: ("[", "](https://)"))
                }
                toolbarButton("tablecells", "表格") {
                    proxy.insertBlock("| 列 1 | 列 2 |\n| --- | --- |\n|  |  |\n")
                }
                Divider().frame(height: 18)
                toolbarButton("photo.on.rectangle", "图片") { showPhotoPicker = true }
                toolbarButton("camera", "拍照") { showCamera = true }
                toolbarButton("paperclip", "附件") { showFileImporter = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .adaptiveGlass(Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: 0.5)
        }
    }

    private func toolbarButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }

    // MARK: - 载入与保存

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let diary = store.diary(id: diaryID) else {
            onClose()
            return
        }
        draft = diary
        title = diary.title ?? ""
        content = diary.content ?? ""
        mood = diary.mood ?? ""
        weather = diary.weather ?? ""
        location = diary.location ?? ""
        tags = diary.tags
        resources = diary.resources
    }

    private func scheduleAutosave() {
        guard autosaveInterval > 0 else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(autosaveInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { save(force: false) }
        }
    }

    private func save(force: Bool) {
        guard var diary = draft ?? store.diary(id: diaryID) else { return }
        if !force && isSaving { return }
        isSaving = true
        defer { isSaving = false }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = diary.title != (trimmedTitle.isEmpty ? nil : trimmedTitle)
            || diary.content != content
            || diary.mood != (mood.isEmpty ? nil : mood)
            || diary.weather != (weather.isEmpty ? nil : weather)
            || diary.location != (location.isEmpty ? nil : location)
            || diary.tags != tags
            || diary.resources != resources

        guard force || changed else { return }

        diary.title = trimmedTitle.isEmpty ? nil : trimmedTitle
        diary.content = content
        diary.mood = mood.isEmpty ? nil : mood
        diary.weather = weather.isEmpty ? nil : weather
        diary.location = location.isEmpty ? nil : location
        diary.tags = tags
        diary.resources = resources
        diary.updateTime = Date()
        draft = diary

        store.autosave(diary)
        lastSavedAt = Date()
    }

    private func close() {
        autosaveTask?.cancel()
        save(force: true)
        // 内容全空的新日记直接丢弃，避免留下空条目
        if let diary = store.diary(id: diaryID),
           (diary.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (diary.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           diary.resources.isEmpty,
           isNew {
            store.delete(diary)
        }
        onClose()
    }

    // MARK: - 媒体

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // PhotosPicker 不直接给扩展名，用 UTType 推断
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            do {
                let resource = try MediaImporter.shared.importData(data, fileExtension: ext)
                await MainActor.run { insertResource(resource) }
            } catch {
                await MainActor.run { ToastCenter.shared.show(error.localizedDescription, isError: true) }
            }
        }
        await MainActor.run { photoItems = [] }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                let needsScope = url.startAccessingSecurityScopedResource()
                defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                do {
                    let resource = try MediaImporter.shared.importFile(at: url)
                    insertResource(resource)
                } catch {
                    ToastCenter.shared.show(error.localizedDescription, isError: true)
                }
            }
        case .failure(let error):
            ToastCenter.shared.show(error.localizedDescription, isError: true)
        }
    }

    private func insertImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return }
        do {
            let resource = try MediaImporter.shared.importData(data, fileExtension: "jpg")
            insertResource(resource)
        } catch {
            ToastCenter.shared.show(error.localizedDescription, isError: true)
        }
    }

    private func insertResource(_ resource: MediaResource) {
        guard !resources.contains(where: { $0.resourceUri == resource.resourceUri }) else {
            ToastCenter.shared.show("这个附件已经添加过了")
            return
        }
        resources.append(resource)
        switch resource.resourceType {
        case .image:
            proxy.insertBlock("\n![图片](\(resource.resourceUri))\n")
        case .audio:
            proxy.insertBlock("\n<audio src=\"\(resource.resourceUri)\"></audio>\n")
        case .video:
            proxy.insertBlock("\n<video src=\"\(resource.resourceUri)\"></video>\n")
        case .unknown:
            break
        }
        scheduleAutosave()
        Haptics.success()
    }
}

// MARK: - 相机

struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage?) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

// MARK: - 心情 / 天气 / 地点

struct MetaEditorSheet: View {
    @Binding var mood: String
    @Binding var weather: String
    @Binding var location: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DiaryStore

    @State private var locationInput: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("心情") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                        ForEach(DiaryMood.allCases) { item in
                            Button {
                                mood = mood == item.rawValue ? "" : item.rawValue
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: item.symbol).font(.system(size: 17))
                                    Text(item.rawValue).font(.caption2)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(mood == item.rawValue ? Theme.accentSoft : Theme.subtleFill)
                                )
                                .foregroundStyle(mood == item.rawValue ? Theme.accent : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("天气") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                        ForEach(DiaryWeather.allCases) { item in
                            Button {
                                weather = weather == item.rawValue ? "" : item.rawValue
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: item.symbol).font(.system(size: 17))
                                    Text(item.rawValue).font(.caption2)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(weather == item.rawValue ? Theme.accentSoft : Theme.subtleFill)
                                )
                                .foregroundStyle(weather == item.rawValue ? Theme.accent : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("地点") {
                    TextField("例如：厦门 · 沙坡尾", text: $locationInput)
                    if !store.locations.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(store.locations.prefix(10)) { item in
                                    TagChip(name: item.name) {
                                        locationInput = item.name
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("附加信息")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { locationInput = location }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        location = locationInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 标签选择

struct TagEditorSheet: View {
    @Binding var selected: [Tag]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DiaryStore

    @State private var newTagName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("新建标签") {
                    HStack {
                        TextField("标签名", text: $newTagName)
                            .submitLabel(.done)
                            .onSubmit(addTag)
                        Button("添加", action: addTag)
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("已有标签") {
                    if store.tags.isEmpty {
                        Text("还没有标签").foregroundStyle(.secondary).font(.footnote)
                    }
                    ForEach(store.tags) { tag in
                        Button {
                            toggle(tag)
                        } label: {
                            HStack {
                                Text(tag.name).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(where: { $0.id == tag.id }) {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func toggle(_ tag: Tag) {
        if let index = selected.firstIndex(where: { $0.id == tag.id }) {
            selected.remove(at: index)
        } else {
            selected.append(tag)
        }
    }

    private func addTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let existing = store.tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            if !selected.contains(where: { $0.id == existing.id }) {
                selected.append(existing)
            }
        } else {
            selected.append(Tag(name: name))
        }
        newTagName = ""
    }
}
