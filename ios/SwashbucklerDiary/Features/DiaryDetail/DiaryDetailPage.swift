import SwiftUI

/// 日记详情。
struct DiaryDetailPage: View {
    let diaryID: UUID
    var onEdit: () -> Void

    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var previewImage: MediaResource?
    @State private var showDeleteConfirm = false

    private var diary: Diary? {
        store.diary(id: diaryID)
    }

    var body: some View {
        Group {
            if let diary {
                content(for: diary)
            } else {
                EmptyStateView(systemImage: "doc.questionmark", title: "日记已删除", message: "这篇日记可能刚刚被移到了隐私空间。")
            }
        }
        .pageBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let diary {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    Menu {
                        Button {
                            UIPasteboard.general.string = diary.content ?? ""
                            ToastCenter.shared.show("已复制正文")
                        } label: {
                            Label("复制正文", systemImage: "doc.on.doc")
                        }
                        Button {
                            share(diary)
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            store.toggleTop(diary)
                        } label: {
                            Label(diary.top ? "取消置顶" : "置顶", systemImage: "pin")
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
                                dismiss()
                            } label: {
                                Label(store.isPrivacyActive ? "移出隐私空间" : "移到隐私空间",
                                      systemImage: store.isPrivacyActive ? "lock.open" : "lock")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog("删除这篇日记？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let diary { store.delete(diary) }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
        .fullScreenCover(item: $previewImage) { resource in
            MediaPreviewPage(resources: diary?.resources ?? [], initial: resource)
        }
    }

    private func content(for diary: Diary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleBlock(diary)
                metaBlock(diary)
                Divider().padding(.vertical, 2)

                if settingsStore.settings.markdown {
                    MarkdownView(
                        markdown: diary.content ?? "",
                        lineSpacing: 7,
                        firstLineIndent: settingsStore.settings.firstLineIndent,
                        codeLineNumber: settingsStore.settings.codeLineNumber,
                        taskLineThrough: settingsStore.settings.taskListLineThrough,
                        onLinkTap: { url in
                            handleLink(url, diary: diary)
                        },
                        onImageTap: { uri in
                            if let resource = diary.resources.first(where: { $0.resourceUri == uri }) {
                                previewImage = resource
                            } else {
                                previewImage = MediaResource(resourceUri: uri, resourceType: .image)
                            }
                        }
                    )
                } else {
                    Text(diary.content ?? "")
                        .font(.system(.body))
                        .lineSpacing(7)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !diary.resources.isEmpty {
                    attachmentSection(diary)
                }

                footer(diary)
                Color.clear.frame(height: 60)
            }
            .padding(Theme.pagePadding)
        }
    }

    private func titleBlock(_ diary: Diary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(diary.displayTitle)
                .font(.system(.title, weight: .bold))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(DateText.full(diary.createTime))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if diary.updateTime.timeIntervalSince(diary.createTime) > 60 {
                    Text("· 编辑于 \(DateText.relative(diary.updateTime))")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func metaBlock(_ diary: Diary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                if let mood = diary.mood, !mood.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: DiaryMood.symbol(for: mood)).font(.system(size: 11))
                        Text(mood).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                if let weather = diary.weather, !weather.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: DiaryWeather.symbol(for: weather)).font(.system(size: 11))
                        Text(weather).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                if let location = diary.location, !location.isEmpty {
                    MetaChip(systemImage: "location", text: location)
                }
                Spacer()
            }
            if !diary.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(diary.tags) { tag in
                            NavigationLink(value: Route.tag(tag.id)) {
                                TagChip(name: "#\(tag.name)")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func attachmentSection(_ diary: Diary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("附件 · \(diary.resources.count)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            let images = diary.resources.filter { $0.resourceType == .image }
            if !images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(images) { resource in
                        Button {
                            previewImage = resource
                        } label: {
                            if let url = resource.fileURL, FileManager.default.fileExists(atPath: url.path) {
                                AsyncThumbnail(url: url)
                                    .frame(height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Theme.subtleFill)
                                    .frame(height: 96)
                                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ForEach(diary.resources.filter { $0.resourceType != .image }) { resource in
                AttachmentRow(resource: resource)
            }
        }
    }

    private func footer(_ diary: Diary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text("共 \(diary.wordCount) 字")
                Spacer()
                Text("创建于 \(DateText.full(diary.createTime))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }

    private func handleLink(_ url: URL, diary: Diary) {
        // 站内引用：swashbucklerdiary://read/<id>
        if url.scheme == (settingsStore.settings.urlScheme.isEmpty ? "swashbucklerdiary" : settingsStore.settings.urlScheme),
           url.host == "read" {
            let idString = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let id = UUID(uuidString: idString), let target = store.diary(id: id) {
                onOpenReference(target)
                return
            }
        }
        UIApplication.shared.open(url)
    }

    @State private var referenceTarget: Diary?

    private func onOpenReference(_ diary: Diary) {
        referenceTarget = diary
    }

    private func share(_ diary: Diary) {
        var items: [Any] = []
        if !diary.displayTitle.isEmpty {
            items.append("《\(diary.displayTitle)》")
        }
        items.append(diary.content ?? "")
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let controller = scene.keyWindow?.rootViewController {
            controller.present(activity, animated: true)
        }
    }
}

struct AttachmentRow: View {
    let resource: MediaResource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: resource.resourceType.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(fileSizeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if resource.resourceType == .audio || resource.resourceType == .video {
                MediaPlayerButton(resource: resource)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.subtleFill))
    }

    private var fileSizeText: String {
        guard let url = resource.fileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return resource.resourceType.displayName
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
