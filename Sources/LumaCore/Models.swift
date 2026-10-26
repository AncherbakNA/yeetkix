import Foundation

public enum FileCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    case cache, logs, downloads, large, trash, duplicates, leftovers, developer, applications, backups, toolCaches
    public var id: Self { self }
    public var title: String {
        switch self {
        case .cache: return "Кэш приложений"
        case .logs: return "Журналы приложений"
        case .downloads: return "Загрузки"
        case .large: return "Большие файлы"
        case .trash: return "Корзина"
        case .duplicates: return "Дубликаты"
        case .leftovers: return "Остатки приложений"
        case .developer: return "Данные Xcode"
        case .applications: return "Приложения"
        case .backups: return "Копии iPhone и iPad"
        case .toolCaches: return "Кэши разработки"
        }
    }
    public var symbol: String {
        switch self {
        case .cache: return "square.3.layers.3d"
        case .logs: return "doc.text"
        case .downloads: return "arrow.down.to.line"
        case .large: return "externaldrive"
        case .trash: return "trash"
        case .duplicates: return "doc.on.doc"
        case .leftovers: return "app.badge"
        case .developer: return "hammer"
        case .applications: return "app.dashed"
        case .backups: return "iphone"
        case .toolCaches: return "shippingbox"
        }
    }
}

public struct FileItem: Identifiable, Hashable, Sendable, Codable {
    public let url: URL
    public let bytes: Int64
    public let modified: Date
    public let category: FileCategory
    public let isDirectory: Bool
    public let identity: FileIdentity?
    public let duplicateEvidence: DuplicateEvidence?
    public let leftoverBundleID: String?
    public let directoryEvidence: DirectoryEvidence?
    public let applicationEvidence: ApplicationEvidence?
    public let displayName: String?
    public let orphanEvidence: OrphanEvidence?
    public let cleanupRoot: String?
    public var id: String { url.standardizedFileURL.path }
    public var name: String { displayName ?? url.lastPathComponent }
    public init(url: URL, bytes: Int64, modified: Date, category: FileCategory, isDirectory: Bool = false, identity: FileIdentity? = nil,
                duplicateEvidence: DuplicateEvidence? = nil, leftoverBundleID: String? = nil,
                directoryEvidence: DirectoryEvidence? = nil, applicationEvidence: ApplicationEvidence? = nil, displayName: String? = nil, orphanEvidence: OrphanEvidence? = nil, cleanupRoot: String? = nil) {
        self.url = url; self.bytes = bytes; self.modified = modified
        self.category = category; self.isDirectory = isDirectory
        self.identity = identity ?? FileIdentity.read(url)
        self.duplicateEvidence = duplicateEvidence; self.leftoverBundleID = leftoverBundleID
        self.directoryEvidence = directoryEvidence; self.applicationEvidence = applicationEvidence; self.displayName = displayName
        self.orphanEvidence = orphanEvidence
        self.cleanupRoot = cleanupRoot
    }
}

public struct ScanReport: Sendable, Codable {
    public var items: [FileItem] = []
    public var inaccessible: [String] = []
    public var truncated = false
    public var isPartial = false
    public var date = Date()
    public var ageDays = 14
    public var scope: ScanScope = .all
    public var roots: [RootResult] = []
    public var visitedCount = 0
    public var protectedCount = 0
    public var duplicateCandidates: [FileItem] = []
    public var duplicateGroups: [DuplicateGroup] = []
    public init() {}
    public mutating func normalizeItems() {
        if truncated || roots.contains(where: { [.denied, .timedOut, .cancelled, .limited].contains($0.status) }) { isPartial = true }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.category.rawValue + ":" + $0.id).inserted }.sorted { $0.bytes > $1.bytes }
        var candidates = Set<String>()
        duplicateCandidates = duplicateCandidates.filter { candidates.insert($0.id).inserted }
    }
    public func exportData() throws -> Data {
        var report = self
        report.normalizeItems()
        report.duplicateCandidates = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
    public var cleanupItems: [FileItem] { items.filter { $0.category == .cache || $0.category == .logs || $0.category == .toolCaches } }
    public var cleanupBytes: Int64 { cleanupItems.reduce(0) { $0 + $1.bytes } }
    public func items(for category: FileCategory) -> [FileItem] {
        if category == .duplicates { return duplicateGroups.flatMap(\.files) }
        if category == .large {
            return items.filter { ($0.category == .large || $0.category == .downloads) && $0.bytes >= DiskScanner.largeFileThreshold && !$0.isDirectory }
        }
        return items.filter { $0.category == category }
    }
}

public struct DiskInfo: Sendable {
    public let total: Int64
    public let available: Int64
    public let name: String
    public var used: Int64 { max(0, total - available) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    public static func read(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> DiskInfo {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey])
        return DiskInfo(total: Int64(values?.volumeTotalCapacity ?? 0), available: Int64(values?.volumeAvailableCapacity ?? 0), name: values?.volumeName ?? "Macintosh HD")
    }
}

public enum FileSize {
    public static func string(_ bytes: Int64) -> String {
        if bytes < 1_000 { return "\(max(0, bytes)) Б" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: max(0, bytes))
            .replacingOccurrences(of: "GB", with: "ГБ")
            .replacingOccurrences(of: "MB", with: "МБ")
            .replacingOccurrences(of: "KB", with: "КБ")
            .replacingOccurrences(of: "TB", with: "ТБ")
    }
}
