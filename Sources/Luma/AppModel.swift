import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import LumaCore

enum Destination: String, CaseIterable, Identifiable {
    case overview, cleanup, large, downloads, duplicates, leftovers, developer, toolCaches, applications, diskMap, backups, tools, trash, history, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .cleanup: return "Кэши и журналы"
        case .large: return "Большие файлы"
        case .downloads: return "Загрузки"
        case .duplicates: return "Дубликаты"
        case .leftovers: return "Остатки приложений"
        case .developer: return "Данные Xcode"
        case .toolCaches: return "Кэши разработки"
        case .applications: return "Приложения"
        case .diskMap: return "Карта диска"
        case .backups: return "Копии устройств"
        case .tools: return "Среда разработки"
        case .trash: return "Корзина"
        case .history: return "История очистки"
        case .settings: return "Настройки"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .cleanup: return "sparkles"
        case .large: return "externaldrive"
        case .downloads: return "arrow.down.to.line"
        case .duplicates: return "doc.on.doc"
        case .leftovers: return "app.badge"
        case .developer: return "hammer"
        case .toolCaches: return "shippingbox"
        case .applications: return "app.dashed"
        case .diskMap: return "chart.pie"
        case .backups: return "iphone"
        case .tools: return "shippingbox"
        case .trash: return "trash"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "slider.horizontal.3"
        }
    }
    var category: FileCategory? {
        switch self { case .large: return .large; case .downloads: return .downloads; case .trash: return .trash; case .duplicates: return .duplicates; case .leftovers: return .leftovers; case .developer: return .developer; case .toolCaches: return .toolCaches; default: return nil }
    }
    var scope: ScanScope? {
        switch self {
        case .overview: return .all
        case .cleanup: return .cleanup
        case .large: return .large
        case .downloads: return .downloads
        case .trash: return .trash
        case .duplicates: return .duplicates
        case .leftovers: return .leftovers
        case .developer: return .developer
        case .toolCaches: return .toolCaches
        default: return nil
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var destination: Destination = .overview { didSet { rebuildItems() } }
    @Published var disk = DiskInfo.read()
    @Published var report: ScanReport? { didSet { rebuildItems() } }
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var scanLocation = "Подготовка"
    @Published var visited = 0
    @Published var selection = Set<String>()
    @Published var query = "" { didSet { rebuildItems() } }
    @Published var cleanupFilter: FileCategory? { didSet { rebuildItems() } }
    @Published var showConfirmation = false
    @Published var showWelcome = false
    @Published var showScanReport = false
    @Published var showHelp = false
    @Published var isCleaning = false
    @Published var operationProgress = ""
    @Published var notice: String?
    @Published var sortByDate = false { didSet { rebuildItems() } }
    @Published var visibleItems: [FileItem] = []
    @Published var history: [HistoryEntry] = []
    @Published var historyError: String?
    @Published var historyReady = false
    @Published var managedHistory: [ManagedEvent] = []
    @Published var exclusions: [String] = []
    @Published var grantedFolders: [String: Data] = [:]
    @Published var manualAssociations: [ManualAssociation] = []
    @AppStorage("minimumAgeDays") var minimumAgeDays = 14
    @AppStorage("hasSeenWelcome") var hasSeenWelcome = false
    private let coordinator = ScanCoordinator()
    private var scanTask: Task<Void, Never>?
    private var initialInventory: Task<[KnownApplication], Never>?
    private var operationTask: Task<Void, Never>?
    private var service: CleanupService?
    private var managedService: ManagedCleanupService?
    let utilities = UtilityModel()
    let updater = UpdaterModel()
    var knownApplications: [KnownApplication] = []
    private var observers = Set<AnyCancellable>()
    private var scanID = UUID()
    let home = FileManager.default.homeDirectoryForCurrentUser
    var historyURL: URL { home.appendingPathComponent("Library/Application Support/local.luma.cleaner/history.json") }

    init() {
        exclusions = UserDefaults.standard.stringArray(forKey: "excludedPaths") ?? []
        grantedFolders = UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data] ?? [:]
        if let data = UserDefaults.standard.data(forKey: "manualAssociations"), let saved = try? JSONDecoder().decode([ManualAssociation].self, from: data) { manualAssociations = saved }
        let store = historyURL
        if let data = UserDefaults.standard.data(forKey: "knownApplications"), let saved = try? JSONDecoder().decode([KnownApplication].self, from: data) { knownApplications = saved }
        utilities.owner = self
        utilities.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        updater.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        let managed = ManagedCleanupService(store: store.deletingLastPathComponent().appendingPathComponent("managed-history.jsonl"))
        managedService = managed
        Task {
            do { managedHistory = try await managed.history() } catch { notice = "Журнал среды разработки недоступен: \(error.localizedDescription)" }
            do {
                let service = try await Task.detached(priority: .utility) { try CleanupService(storeURL: store) }.value
                self.service = service; history = await service.history(); historyReady = true
            } catch {
                historyError = "Журнал очистки недоступен: \(error.localizedDescription). Чтобы не потерять историю, очистка временно отключена."
            }
        }
        let userHome = home
        let inventory = Task.detached(priority: .utility) { ApplicationInventory.list(home: userHome).map(\.known) }
        initialInventory = inventory
        Task {
            observeKnown(await inventory.value)
        }
    }
    func observe(_ apps: [ApplicationRecord]) { observeKnown(apps.map(\.known)) }
    private func observeKnown(_ apps: [KnownApplication]) {
        var merged = Dictionary(grouping: knownApplications + apps, by: \.bundleID).map { id, records in
            KnownApplication(bundleID: id, names: Array(Set(records.flatMap(\.names))).sorted(),
                             containerIDs: Array(Set(records.flatMap { $0.containerIDs ?? [] })).sorted(),
                             groupIDs: Array(Set(records.flatMap { $0.groupIDs ?? [] })).sorted())
        }
        merged.sort { $0.bundleID < $1.bundleID }; knownApplications = merged
        if let data = try? JSONEncoder().encode(merged) { UserDefaults.standard.set(data, forKey: "knownApplications") }
    }
    var needsScan: Bool { guard let scope = destination.scope else { return false }; return report?.scope.includes(scope) != true }
    private var sectionItems: [FileItem] {
        guard let report else { return [] }
        if destination == .cleanup { return report.cleanupItems }
        if let category = destination.category { return report.items(for: category) }
        return []
    }
    var selectedItems: [FileItem] { TrashSafety.uniqueTopLevelItems(sectionItems.filter { selection.contains($0.id) && $0.category != .trash }) }
    var duplicateGroups: [DuplicateGroup] { report?.duplicateGroups ?? [] }
    var permissionRoots: [ScanRoot] {
        var seen = Set<String>()
        return (ScanScope.all.roots(home: home, applications: knownApplications) + [ScanRoot(relativePath: BackupInventory.relativeRoot, category: .backups, home: home)]).filter { seen.insert($0.relativePath).inserted }
    }
    var developerBusy: Bool { DeveloperActivity.isBusy() }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var totalVisibleBytes: Int64 { visibleItems.reduce(0) { $0 + $1.bytes } }
    var computerName: String { Host.current().localizedName ?? "Ваш Mac" }
    var memory: String { "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) ГБ" }
    var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }
    func policy() -> SafetyPolicy {
        let running = NSWorkspace.shared.runningApplications.map { RunningApplication(bundleID: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "") }
        var policy = SafetyPolicy(excludedPaths: exclusions, runningApplications: running, developerToolsBusy: developerBusy, knownApplications: knownApplications)
        policy.virtualMachinesBusy = ApplicationCapabilities.virtualMachinesBusy()
        policy.activeProcesses = JunkCatalog.processNames()
        policy.manualAssociations = manualAssociations
        return policy
    }
    private func rebuildItems() {
        guard let report else { visibleItems = []; return }
        var items: [FileItem]
        if destination == .cleanup { items = cleanupFilter.map { report.items(for: $0) } ?? report.cleanupItems }
        else if let category = destination.category { items = report.items(for: category) }
        else { items = [] }
        if !query.isEmpty { items = items.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.url.path.localizedCaseInsensitiveContains(query) } }
        visibleItems = sortByDate ? items.sorted { $0.modified < $1.modified } : items.sorted { $0.bytes > $1.bytes }
    }
    func navigate(_ target: Destination) { destination = target; query = ""; selection.removeAll(); cleanupFilter = nil }
    func startScan(scope explicit: ScanScope? = nil) {
        guard !isScanning, !isCleaning, !utilities.isBusy, !showConfirmation, !utilities.showReviewConfirmation, !utilities.showManagedConfirmation else { return }
        let scope = explicit ?? destination.scope ?? .all
        if destination == .overview || destination == .settings || explicit != nil {
            let target: Destination
            switch scope {
            case .downloads: target = .downloads
            case .large: target = .large
            case .trash: target = .trash
            case .duplicates: target = .duplicates
            case .leftovers: target = .leftovers
            case .developer: target = .developer
            case .toolCaches: target = .toolCaches
            default: target = .cleanup
            }
            navigate(target)
        }
        selection.removeAll(); query = ""; cleanupFilter = nil; report = nil
        isScanning = true; progress = 0; visited = 0; scanLocation = "Подготовка"
        let id = UUID(); scanID = id
        guard let executable = Bundle.main.executableURL else { isScanning = false; return }
        let access = beginAccess()
        scanTask = Task {
            defer { access.forEach { $0.stop() } }
            if let initialInventory { observeKnown(await initialInventory.value) }
            guard !Task.isCancelled, scanID == id else { isScanning = false; return }
            let safety = policy()
            let request = WorkerRequest(home: home, roots: scope.roots(home: home, applications: safety.knownApplications), scope: scope, ageDays: minimumAgeDays,
                                        policy: safety, bookmarks: access.compactMap { try? $0.workerBookmark() })
            let result = await coordinator.scan(request, executable: executable) { [weak self] update in
                guard let self, self.scanID == id else { return }
                self.progress = update.fraction; self.scanLocation = update.title; self.visited = update.visited
                self.report = update.partial
            }
            guard scanID == id else { return }
            report = result; disk = DiskInfo.read(); isScanning = false; scanTask = nil
        }
    }
    func cancelScan() { scanTask?.cancel(); coordinator.cancel(); utilities.cancel() }
    func skipFolder() { coordinator.skipCurrentRoot() }
    func toggle(_ item: FileItem) {
        guard !isCleaning else { return }
        if let proof = item.duplicateEvidence, item.url.standardizedFileURL == proof.keeperURL.standardizedFileURL { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }
    func toggleVisible() {
        guard !isCleaning else { return }
        let ids = Set(visibleItems.filter { item in
            item.category != .trash && (item.duplicateEvidence.map { item.url.standardizedFileURL != $0.keeperURL.standardizedFileURL } ?? true)
        }.map(\.id))
        if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }
    func selectDuplicateCopies(_ groups: [DuplicateGroup]) {
        guard !isCleaning else { return }
        let ids = Set(groups.flatMap(\.files).filter { item in
            item.duplicateEvidence.map { item.url.standardizedFileURL != $0.keeperURL.standardizedFileURL } ?? false
        }.map(\.id))
        if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }
    func keepDuplicate(_ item: FileItem, groupID: String) {
        guard !isCleaning, var current = report, let index = current.duplicateGroups.firstIndex(where: { $0.id == groupID }),
              let identity = item.identity, FileIdentity.read(item.url) == identity, let existing = item.duplicateEvidence else { return }
        let proof = DuplicateEvidence(sha256: existing.sha256, keeperURL: item.url, keeperIdentity: identity)
        let files = current.duplicateGroups[index].files
        current.duplicateGroups[index].files = ([item] + files.filter { $0.id != item.id }).map {
            FileItem(url: $0.url, bytes: $0.bytes, modified: $0.modified, category: .duplicates, identity: $0.identity, duplicateEvidence: proof)
        }
        selection.remove(item.id); report = current
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openTrash() { NSWorkspace.shared.open(home.appendingPathComponent(".Trash")) }
    func openPrivacy() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    func addExclusion() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = "Эти файлы и папки не будут предлагаться для очистки."
        panel.prompt = "Исключить"
        guard panel.runModal() == .OK else { return }
        defer { panel.urls.forEach { $0.stopAccessingSecurityScopedResource() } }
        for url in panel.urls where !exclusions.contains(url.standardizedFileURL.path) { exclusions.append(url.standardizedFileURL.path) }
        UserDefaults.standard.set(exclusions, forKey: "excludedPaths")
        let current = policy()
        report?.items.removeAll { current.isExcluded($0.url) }
        if var result = report {
            result.duplicateGroups.removeAll { $0.files.contains { current.isExcluded($0.url) } }
            report = result
        }
        selection = selection.intersection(Set(report?.items.map(\.id) ?? []))
    }
    func removeExclusion(_ path: String) { exclusions.removeAll { $0 == path }; UserDefaults.standard.set(exclusions, forKey: "excludedPaths") }
    func exclude(_ url: URL) {
        guard !isCleaning else { return }
        let path = url.standardizedFileURL.path
        if !exclusions.contains(path) { exclusions.append(path); UserDefaults.standard.set(exclusions, forKey: "excludedPaths") }
        report?.items.removeAll { policy().isExcluded($0.url) }
        if var current = report {
            current.duplicateGroups.removeAll { group in group.files.contains { policy().isExcluded($0.url) } }
            report = current
        }
        selection.remove(path)
    }
    func connectFolder(_ root: ScanRoot) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = root.url; panel.prompt = "Разрешить доступ"
        panel.message = "Выберите папку «\(root.title)». Доступ нужен для сканирования и переноса только выбранных вами файлов в Корзину."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard url.standardizedFileURL == root.url.standardizedFileURL else { notice = "Для этого раздела выберите папку \(root.url.path)."; return }
        do {
            let data = try FolderAccess.bookmark(for: url)
            grantedFolders[root.id] = data; UserDefaults.standard.set(grantedFolders, forKey: "folderBookmarks")
        } catch { notice = "Не удалось сохранить доступ: \(error.localizedDescription)" }
    }
    func beginAccess() -> [FolderAccess] {
        let saved = grantedFolders
        var refreshed = false
        let result = saved.compactMap { id, data -> FolderAccess? in
            guard let access = try? FolderAccess.resolve(data) else { return nil }
            if access.stale, let bookmark = try? FolderAccess.bookmark(for: access.url) {
                grantedFolders[id] = bookmark; refreshed = true
            }
            return access
        }
        if refreshed { UserDefaults.standard.set(grantedFolders, forKey: "folderBookmarks") }
        return result
    }
    func showScanDetails() {
        guard report != nil else { return }
        showScanReport = true
    }
    func exportScanReport() {
        guard let report, !isScanning, !isCleaning else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "YEETKIX-report.json"
        panel.message = "Отчёт содержит пути к найденным файлам и статусы папок. Содержимое файлов и bookmarks доступа в него не включаются."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.exportData().write(to: url, options: .atomic) }
        catch { notice = "Не удалось сохранить отчёт: " + error.localizedDescription }
    }
    func moveSelectionToTrash() {
        moveReviewedItems(selectedItems)
    }
    func moveReviewedItems(_ items: [FileItem], completion: (() -> Void)? = nil) {
        guard !items.isEmpty, !isCleaning, !isScanning, !utilities.isBusy, let service, historyReady else { return }
        isCleaning = true; showConfirmation = false; operationProgress = "Подготовка"
        let initialPolicy = policy(); let age = report?.ageDays ?? minimumAgeDays
        let access = beginAccess()
        operationTask = Task {
            let outcome = await service.move(items, policy: initialPolicy, minimumAgeDays: age, policyProvider: { [weak self] in
                guard let self else { return initialPolicy }
                return await self.policy()
            }) { [weak self] done, total in
                guard let self else { return }
                Task { @MainActor in self.operationProgress = "\(done) из \(total)" }
            }
            access.forEach { $0.stop() }
            let moved = Set(outcome.moved.map { $0.originalURL.standardizedFileURL.path })
            report?.items.removeAll { moved.contains($0.id) }
            if var current = report {
                current.duplicateGroups = current.duplicateGroups.compactMap { group in
                    var remaining = group; remaining.files.removeAll { moved.contains($0.id) }
                    return remaining.files.count > 1 ? remaining : nil
                }
                report = current
            }
            selection.removeAll()
            history = await service.history(); disk = DiskInfo.read(); isCleaning = false; operationTask = nil
            var text = "Файлов перемещено в Корзину: \(outcome.moved.count). Восстановить их можно в разделе «История очистки». Место освободится после очистки Корзины в Finder."
            if outcome.cancelled { text += "\n\nОчистка остановлена. Остальные файлы оставлены на месте." }
            if !outcome.failures.isEmpty { text += "\n\nПропущено: \(outcome.failures.count).\n" + outcome.failures.prefix(4).map { $0.name + ": " + $0.message }.joined(separator: "\n") }
            if let warning = outcome.journalWarning { text += "\n\n" + warning }
            notice = text
            completion?()
        }
    }
    func removeManagedResources(_ items: [ManagedResource]) {
        guard !items.isEmpty, !isCleaning, !isScanning, !utilities.isBusy, let managedService else { return }
        isCleaning = true; operationProgress = "Очистка выбранных ресурсов"
        operationTask = Task {
            do {
                let events = try await managedService.remove(items, home: home)
                managedHistory = try await managedService.history()
                let done = events.filter { $0.state == "Удалено без восстановления" }.count
                utilities.resources.removeAll { resource in events.contains { $0.resource.id == resource.id && $0.state == "Удалено без восстановления" } }
                notice = "Удалено ресурсов: \(done) из \(items.count). Эти операции выполняются средствами Docker или Xcode и не восстанавливаются из Корзины.\n\n" + events.filter { $0.state != "Удалено без восстановления" }.map { $0.resource.name + ": " + $0.detail }.joined(separator: "\n")
            } catch { notice = error.localizedDescription }
            disk = DiskInfo.read(); isCleaning = false; operationTask = nil
        }
    }
    func cancelCleanup() { operationTask?.cancel() }
    func waitForOperation() async { await operationTask?.value }
    func restore(_ entry: HistoryEntry) {
        guard !isCleaning, !isScanning, !utilities.isBusy, let service else { return }
        isCleaning = true; operationProgress = "Восстанавливаем файл"
        let access = beginAccess()
        operationTask = Task {
            do { _ = try await service.restore(entry.id); notice = "«\(entry.name)» восстановлен в исходную папку." }
            catch { notice = error.localizedDescription }
            access.forEach { $0.stop() }
            history = await service.history(); disk = DiskInfo.read(); isCleaning = false; operationTask = nil
        }
    }
}
