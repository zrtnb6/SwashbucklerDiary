import SwiftUI
import AVKit

/// 媒体库：图片 / 音频 / 视频分类浏览。
struct MediaLibraryPage: View {
    @EnvironmentObject private var store: DiaryStore

    @State private var kind: MediaKind = .image
    @State private var resources: [MediaResource] = []
    @State private var preview: MediaResource?
    @State private var pendingDelete: MediaResource?
    @State private var orphanCleanupMessage: String?

    private var filtered: [MediaResource] {
        resources.filter { $0.resourceType == kind }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("类型", selection: $kind) {
                Text("图片").tag(MediaKind.image)
                Text("音频").tag(MediaKind.audio)
                Text("视频").tag(MediaKind.video)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 8)

            if filtered.isEmpty {
                EmptyStateView(
                    systemImage: kind.systemImage,
                    title: "没有\(kind.displayName)",
                    message: "在日记里插入\(kind.displayName)后会出现在这里。"
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(filtered) { resource in
                            Button {
                                preview = resource
                            } label: {
                                cell(resource)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    preview = resource
                                } label: { Label("查看", systemImage: "eye") }
                                if let url = resource.fileURL {
                                    ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                                }
                                Button(role: .destructive) {
                                    pendingDelete = resource
                                } label: { Label("删除文件", systemImage: "trash") }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    Color.clear.frame(height: 80)
                }
            }
        }
        .pageBackground()
        .navigationTitle("媒体文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        cleanOrphans()
                    } label: {
                        Label("清理未引用的文件", systemImage: "sparkles")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { load() }
        .fullScreenCover(item: $preview) { resource in
            MediaPreviewPage(resources: filtered, initial: resource)
        }
        .confirmationDialog(
            "删除这个文件？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { commitDelete() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            if let pendingDelete, referenceCount(pendingDelete) > 0 {
                Text("有 \(referenceCount(pendingDelete)) 篇日记引用了它，删除后这些日记里会出现失效链接。")
            } else {
                Text("文件将从设备上移除。")
            }
        }
        .alert("清理完成", isPresented: Binding(
            get: { orphanCleanupMessage != nil },
            set: { if !$0 { orphanCleanupMessage = nil } }
        )) {
            Button("好", role: .cancel) { orphanCleanupMessage = nil }
        } message: {
            Text(orphanCleanupMessage ?? "")
        }
    }

    private func cell(_ resource: MediaResource) -> some View {
        ZStack(alignment: .bottomLeading) {
            if resource.resourceType == .image, let url = resource.fileURL {
                AsyncThumbnail(url: url)
                    .frame(height: 104)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.subtleFill)
                    .frame(height: 104)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: resource.resourceType.systemImage)
                                .font(.system(size: 22))
                                .foregroundStyle(Theme.accent)
                            Text(resource.fileName)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                        }
                    )
            }
        }
    }

    private func load() {
        guard let db = try? DiaryDatabase.shared.current else { return }
        resources = (try? ResourceRepository(db: db).fetchAll()) ?? []
    }

    private func referenceCount(_ resource: MediaResource) -> Int {
        guard let db = try? DiaryDatabase.shared.current else { return 0 }
        return (try? ResourceRepository(db: db).referenceCount(uri: resource.resourceUri)) ?? 0
    }

    private func commitDelete() {
        guard let resource = pendingDelete, let db = try? DiaryDatabase.shared.current else { return }
        // 先从所有日记的正文里移除引用，再删文件，避免留下死链
        for var diary in store.diaries where diary.resources.contains(where: { $0.resourceUri == resource.resourceUri }) {
            diary.resources.removeAll { $0.resourceUri == resource.resourceUri }
            if let content = diary.content {
                diary.content = content
                    .replacingOccurrences(of: resource.resourceUri, with: "")
                    .replacingOccurrences(of: "![]()", with: "")
            }
            store.save(diary)
        }
        try? ResourceRepository(db: db).delete(uri: resource.resourceUri)
        MediaImporter.shared.deleteFile(for: resource)
        pendingDelete = nil
        load()
        ToastCenter.shared.show("已删除")
    }

    private func cleanOrphans() {
        guard let db = try? DiaryDatabase.shared.current else { return }
        let repository = ResourceRepository(db: db)
        let orphans = (try? repository.orphanUris()) ?? []
        for uri in orphans {
            let resource = MediaResource(resourceUri: uri, resourceType: MediaKind.from(fileExtension: (uri as NSString).pathExtension))
            MediaImporter.shared.deleteFile(for: resource)
            try? repository.delete(uri: uri)
        }
        load()
        orphanCleanupMessage = orphans.isEmpty ? "没有发现未引用的文件。" : "已清理 \(orphans.count) 个未被引用的文件。"
    }
}

/// 全屏预览。图片可左右滑动，音视频直接播放。
struct MediaPreviewPage: View {
    let resources: [MediaResource]
    let initial: MediaResource

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0

    private var current: MediaResource {
        guard resources.indices.contains(index) else { return initial }
        return resources[index]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(resources.enumerated()), id: \.offset) { offset, resource in
                    Group {
                        if resource.resourceType == .image {
                            imageView(resource)
                        } else if let url = resource.fileURL {
                            VideoPlayer(player: AVPlayer(url: url))
                                .ignoresSafeArea(edges: .bottom)
                        } else {
                            Text("文件不可用").foregroundStyle(.white)
                        }
                    }
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                    Spacer()
                    Text("\(index + 1) / \(resources.count)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    if let url = current.fileURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(.black.opacity(0.35)))
                        }
                    } else {
                        Color.clear.frame(width: 34, height: 34)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .onAppear {
            index = resources.firstIndex(where: { $0.resourceUri == initial.resourceUri }) ?? 0
        }
    }

    @ViewBuilder
    private func imageView(_ resource: MediaResource) -> some View {
        if let url = resource.fileURL {
            ZoomableImage(url: url)
        } else {
            Text("图片不可用").foregroundStyle(.white)
        }
    }
}

/// 支持双击/捏合缩放的图片视图。
struct ZoomableImage: View {
    let url: URL

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(5, max(1, lastScale * value))
                            }
                            .onEnded { _ in lastScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            scale = scale > 1 ? 1 : 2.4
                            lastScale = scale
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            image = await ImageCache.shared.image(for: url)
        }
    }
}

/// 播放按钮：音频用系统播放器弹窗，视频直接全屏。
struct MediaPlayerButton: View {
    let resource: MediaResource
    @State private var showPlayer = false

    var body: some View {
        Button {
            showPlayer = true
        } label: {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showPlayer) {
            MediaPreviewPage(resources: [resource], initial: resource)
        }
    }
}
