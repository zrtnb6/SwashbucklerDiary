import Foundation
import SwiftUI

/// 全局数据状态。
///
/// 单一数据源：所有页面读这里，所有写入走这里。写入后统一 `reload()`，
/// 避免各页面各自缓存导致列表与详情不同步。
@MainActor
final class DiaryStore: ObservableObject {
    static let shared = DiaryStore()

    @Published private(set) var diaries: [Diary] = []
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var locations: [DiaryLocation] = []
    @Published private(set) var countsByDay: [String: Int] = [:]
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    @Published var sort: DiarySort {
        didSet {
            SettingsStore.shared.update { $0.diarySort = sort.rawValue }
        }
    }

    /// 隐私模式变化时由 NotificationCenter 触发重载。
    private var observer: NSObjectProtocol?

    private init() {
        sort = DiarySort.parse(SettingsStore.shared.settings.diarySort)
        observer = NotificationCenter.default.addObserver(
            forName: .privacyModeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - 读取

    func reload() {
        isLoading = true
        defer { isLoading = false }
        do {
            let db = try DiaryDatabase.shared.current
            let repository = DiaryRepository(db: db)
            diaries = sortDiaries(try repository.fetchAll())
            tags = try TagRepository(db: db).fetchAll()
            locations = try LocationRepository(db: db).fetchAllFromDiaries()
            countsByDay = try repository.countsByDay()
        } catch {
            Log.error("加载日记失败：\(error.localizedDescription)", .storage)
            lastError = error.localizedDescription
        }
    }

    private func sortDiaries(_ input: [Diary]) -> [Diary] {
        let sorted: [Diary]
        switch sort {
        case .timeDescending: sorted = input.sorted { $0.createTime > $1.createTime }
        case .timeAscending: sorted = input.sorted { $0.createTime < $1.createTime }
        case .updateDescending: sorted = input.sorted { $0.updateTime > $1.updateTime }
        case .updateAscending: sorted = input.sorted { $0.updateTime < $1.updateTime }
        }
        // 置顶永远排在最前面
        return sorted.sorted { lhs, rhs in
            if lhs.top != rhs.top { return lhs.top }
            return false
        }
    }

    func diary(id: UUID) -> Diary? {
        diaries.first { $0.id == id }
    }

    func diaries(on day: Date) -> [Diary] {
        let calendar = Calendar.current
        return diaries.filter { calendar.isDate($0.createTime, inSameDayAs: day) }
    }

    func diaries(taggedWith tagID: UUID) -> [Diary] {
        diaries.filter { $0.tags.contains { $0.id == tagID } }
    }

    func diaries(atLocation name: String) -> [Diary] {
        diaries.filter { ($0.location ?? "") == name }
    }

    var templates: [Diary] { diaries.filter(\.template) }

    // MARK: - 写入

    func save(_ diary: Diary) {
        do {
            let db = try DiaryDatabase.shared.current
            let repository = DiaryRepository(db: db)
            if diaries.contains(where: { $0.id == diary.id }) {
                try repository.update(diary)
            } else {
                try repository.insert(diary)
            }
            for resource in diary.resources {
                try? ResourceRepository(db: db).ensureRegistered(uri: resource.resourceUri, type: resource.resourceType)
            }
            reload()
        } catch {
            Log.error("保存日记失败：\(error.localizedDescription)", .storage)
            lastError = error.localizedDescription
        }
    }

    /// 编辑器自动保存走这条路径：不刷新整个列表（避免打断输入），只更新缓存。
    func autosave(_ diary: Diary) {
        do {
            let db = try DiaryDatabase.shared.current
            try DiaryRepository(db: db).update(diary)
            if let index = diaries.firstIndex(where: { $0.id == diary.id }) {
                diaries[index] = diary
            }
        } catch {
            Log.error("自动保存失败：\(error.localizedDescription)", .storage)
            lastError = error.localizedDescription
        }
    }

    func delete(_ diary: Diary) {
        delete(ids: [diary.id])
    }

    func delete(ids: [UUID]) {
        do {
            let db = try DiaryDatabase.shared.current
            try DiaryRepository(db: db).delete(ids: ids)
            reload()
        } catch {
            Log.error("删除日记失败：\(error.localizedDescription)", .storage)
            lastError = error.localizedDescription
        }
    }

    func toggleTop(_ diary: Diary) {
        var value = diary
        value.top.toggle()
        save(value)
    }

    func toggleTemplate(_ diary: Diary) {
        var value = diary
        value.template.toggle()
        save(value)
    }

    /// 把日记移到隐私空间（或从隐私空间移出）。
    func moveToOtherSpace(_ diary: Diary) {
        do {
            let isPrivacy = DiaryDatabase.shared.isPrivacyMode
            var copy = diary
            copy.updateTime = Date()
            if isPrivacy {
                // 隐私 → 普通
                let mainDB = try DiaryDatabase.shared.main()
                try DiaryRepository(db: mainDB).insert(copy)
                let privacyDB = try DiaryDatabase.shared.privacy()
                try DiaryRepository(db: privacyDB).delete(ids: [diary.id])
            } else {
                let privacyDB = try DiaryDatabase.shared.privacy()
                try DiaryRepository(db: privacyDB).insert(copy)
                let mainDB = try DiaryDatabase.shared.main()
                try DiaryRepository(db: mainDB).delete(ids: [diary.id])
            }
            reload()
        } catch {
            Log.error("移动日记失败：\(error.localizedDescription)", .storage)
            lastError = error.localizedDescription
        }
    }

    /// 合并多条日记：内容按时间拼接，标签与资源取并集，保留最早一条。
    func merge(_ items: [Diary]) {
        guard items.count >= 2 else { return }
        let ordered = items.sorted { $0.createTime < $1.createTime }
        var merged = ordered[0]
        merged.content = ordered.map { $0.content ?? "" }.joined(separator: "\n")
        var seenTags = Set<UUID>()
        merged.tags = ordered.flatMap(\.tags).filter { seenTags.insert($0.id).inserted }
            .sorted { $0.name < $1.name }
        var seenResources = Set<String>()
        merged.resources = ordered.flatMap(\.resources).filter { seenResources.insert($0.resourceUri).inserted }
        merged.updateTime = Date()
        save(merged)
        delete(ids: ordered.dropFirst().map(\.id))
    }

    // MARK: - 统计

    struct Statistics {
        var diaryCount: Int
        var wordCount: Int
        var tagCount: Int
        var activeDays: Int
        var streak: Int
        var mediaCount: Int
        var firstDiaryDate: Date?
    }

    var statistics: Statistics {
        let calendar = Calendar.current
        let days = Set(diaries.map { calendar.startOfDay(for: $0.createTime) })
        var streak = 0
        var cursor = calendar.startOfDay(for: Date())
        if !days.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return Statistics(
            diaryCount: diaries.count,
            wordCount: diaries.reduce(0) { $0 + $1.wordCount },
            tagCount: tags.count,
            activeDays: days.count,
            streak: streak,
            mediaCount: Set(diaries.flatMap(\.resources).map(\.resourceUri)).count,
            firstDiaryDate: diaries.map(\.createTime).min()
        )
    }

    // MARK: - 搜索与筛选

    struct Filter: Equatable {
        var keyword: String = ""
        var tagIDs: Set<UUID> = []
        var moods: Set<String> = []
        var weathers: Set<String> = []
        var onlyWithMedia = false
        var dateRange: ClosedRange<Date>?

        var isEmpty: Bool {
            keyword.isEmpty && tagIDs.isEmpty && moods.isEmpty && weathers.isEmpty
                && !onlyWithMedia && dateRange == nil
        }
    }

    func apply(_ filter: Filter, to input: [Diary]) -> [Diary] {
        var result = input
        let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            let lowered = keyword.lowercased()
            result = result.filter { diary in
                let haystack = [
                    diary.title ?? "", diary.content ?? "",
                    diary.location ?? "", diary.mood ?? "", diary.weather ?? "",
                    diary.tags.map(\.name).joined(separator: " "),
                ].joined(separator: "\n").lowercased()
                return haystack.contains(lowered)
            }
        }
        if !filter.tagIDs.isEmpty {
            result = result.filter { diary in
                !filter.tagIDs.isDisjoint(with: Set(diary.tags.map(\.id)))
            }
        }
        if !filter.moods.isEmpty {
            result = result.filter { filter.moods.contains($0.mood ?? "") }
        }
        if !filter.weathers.isEmpty {
            result = result.filter { filter.weathers.contains($0.weather ?? "") }
        }
        if filter.onlyWithMedia {
            result = result.filter { !$0.resources.isEmpty }
        }
        if let range = filter.dateRange {
            result = result.filter { range.contains($0.createTime) }
        }
        return result
    }
}
