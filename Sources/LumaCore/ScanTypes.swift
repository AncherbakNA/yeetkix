import Foundation

public enum ScanScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, cleanup, downloads, large, trash, duplicates, leftovers, developer, toolCaches
    public var id: Self { self }
    public var title: String {
        switch self {
        case .all: return "Все разделы"
        case .cleanup: return "Кэш и журналы"
        case .downloads: return "Загрузки"
        case .large: return "Большие файлы"
        case .trash: return "Корзина"
        case .duplicates: return "Дубликаты"
        case .leftovers: return "Остатки приложений"
        case .developer: return "Данные Xcode"
        case .toolCaches: return "Кэши разработки"
        }
    }
    public func includes(_ other: ScanScope) -> Bool { self == .all || self == other || (self == .cleanup && other == .toolCaches) }
    public func roots(home: URL, applications: [KnownApplication] = []) -> [ScanRoot] {
        let cache = ScanRoot(relativePath: "Library/Caches", category: .cache, home: home)
        let logs = ScanRoot(relativePath: "Library/Logs", category: .logs, home: home)
        let downloads = ScanRoot(relativePath: "Downloads", category: self == .large ? .large : .downloads, home: home)
        let large = ["Desktop", "Documents", "Movies"].map { ScanRoot(relativePath: $0, category: .large, home: home) }
        let trash = ScanRoot(relativePath: ".Trash", category: .trash, home: home)
        let personal = ["Downloads", "Desktop", "Documents", "Movies", "Pictures", "Music"].map { ScanRoot(relativePath: $0, category: .duplicates, home: home) }
        let remnants = (ArtifactPaths.leftoverRoots + ["Library/Containers", "Library/Group Containers"])
            .map { ScanRoot(relativePath: $0, category: .leftovers, home: home) }
        let developer = ["Library/Developer/Xcode/DerivedData", "Library/Caches/com.apple.dt.Xcode", "Library/Developer/Xcode/iOS DeviceSupport"]
            .map { ScanRoot(relativePath: $0, category: .developer, home: home) }
        let sandboxCaches = JunkCatalog.appCaches(applications).map { ScanRoot(relativePath: $0.relativePath, category: $0.category, home: home) }
        let tooling = JunkCatalog.toolCaches.map { ScanRoot(relativePath: $0.relativePath, category: .toolCaches, home: home) }
        switch self {
        case .all: return [cache, logs, downloads] + large + Array(personal.suffix(2)) + remnants + developer + sandboxCaches + tooling + [trash]
        case .cleanup: return [cache, logs] + sandboxCaches + tooling
        case .downloads: return [downloads]
        case .large: return [downloads] + large
        case .trash: return [trash]
        case .duplicates: return personal
        case .leftovers: return remnants
        case .developer: return developer
        case .toolCaches: return tooling
        }
    }
}

public struct ScanRoot: Codable, Hashable, Identifiable, Sendable {
    public let relativePath: String
    public let category: FileCategory
    public let url: URL
    public var id: String { category == .leftovers ? "leftovers:" + relativePath : relativePath }
    public var title: String {
        switch relativePath {
        case "Library/Caches": return "Кэш приложений"
        case "Library/Logs": return "Журналы"
        case "Downloads": return "Загрузки"
        case "Desktop": return "Рабочий стол"
        case "Documents": return "Документы"
        case "Movies": return "Фильмы"
        case "Pictures": return "Изображения"
        case "Music": return "Музыка"
        case "Library/Preferences": return "Настройки удалённых приложений"
        case "Library/Application Support": return "Данные удалённых приложений"
        case "Library/Saved Application State": return "Сохранённые состояния"
        case "Library/Developer/Xcode/DerivedData": return "Сборки и индексы Xcode"
        case "Library/Caches/com.apple.dt.Xcode": return "Кэш Xcode"
        case "Library/Developer/Xcode/iOS DeviceSupport": return "Поддержка устройств Xcode"
        case ".duplicate-analysis": return "Сравнение содержимого файлов"
        case ".Trash": return "Корзина"
        case "Library/Containers": return "Контейнеры удалённых приложений"
        case "Library/Group Containers": return "Общие данные удалённых приложений"
        case "Library/HTTPStorages": return "HTTP-данные удалённых приложений"
        case "Library/WebKit": return "WebKit удалённых приложений"
        case "Library/Cookies": return "Cookies удалённых приложений"
        case "Library/Application Scripts": return "Сценарии удалённых приложений"
        case "Library/Preferences/ByHost": return "Настройки ByHost"
        case ".npm/_cacache": return "Кэш npm"
        case "Library/Caches/pnpm": return "Кэш pnpm"
        case ".cache/pip", "Library/Caches/pip": return "Кэш pip"
        case ".cache/yarn", "Library/Caches/Yarn": return "Кэш Yarn"
        case "Library/Caches/Homebrew": return "Загрузочный кэш Homebrew"
        case ".cargo/registry/cache": return "Архивы Cargo"
        default: return relativePath
        }
    }
    public init(relativePath: String, category: FileCategory, home: URL) {
        self.relativePath = relativePath; self.category = category
        self.url = home.appendingPathComponent(relativePath, isDirectory: true)
    }
}

public enum RootStatus: String, Codable, Sendable {
    case complete, missing, denied, timedOut, cancelled, limited, protected
    public var title: String {
        switch self {
        case .complete: return "Проверена"
        case .missing: return "Папки нет"
        case .denied: return "Не удалось проверить"
        case .timedOut: return "Превышено время ожидания"
        case .cancelled: return "Пропущена"
        case .limited: return "Достигнут лимит"
        case .protected: return "Защищена"
        }
    }
}

public struct RootResult: Codable, Identifiable, Sendable {
    public let root: ScanRoot
    public var status: RootStatus
    public var detail: String?
    public var id: String { root.id }
    public init(root: ScanRoot, status: RootStatus, detail: String? = nil) { self.root = root; self.status = status; self.detail = detail }
}

public struct WorkerRequest: Codable, Sendable {
    public var home: URL
    public var roots: [ScanRoot]
    public var scope: ScanScope
    public var ageDays: Int
    public var entryLimit: Int
    public var policy: SafetyPolicy
    public var bookmarks: [Data]
    public var duplicateCandidates: [FileItem] = []
    public var analyzeDuplicates = false
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, roots: [ScanRoot], scope: ScanScope = .all,
                ageDays: Int = 14, entryLimit: Int = 250_000, policy: SafetyPolicy = SafetyPolicy(), bookmarks: [Data] = []) {
        self.home = home; self.roots = roots; self.scope = scope; self.ageDays = ageDays
        self.entryLimit = entryLimit; self.policy = policy; self.bookmarks = bookmarks
    }
}

public struct WorkerMessage: Codable, Sendable {
    public var progress: Double?
    public var location: String?
    public var visited: Int?
    public var report: ScanReport?
    public var partialReport: ScanReport?
    public var error: String?
}
