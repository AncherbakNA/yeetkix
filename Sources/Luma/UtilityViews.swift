import SwiftUI
import AppKit
import LumaCore

@MainActor final class UtilityModel: ObservableObject {
    weak var owner: AppModel?
    @Published var isBusy = false
    @Published var status = ""
    @Published var error: String?
    @Published var applications: [ApplicationRecord] = []
    @Published var reviewed: [FileItem] = []
    @Published var backups: [FileItem] = []
    @Published var backupsChecked = false
    @Published var selectedApp: String?
    @Published var applicationSources: [ApplicationSourceResult] = []
    @Published var reviewNotes: [String] = []
    @Published var reviewTotal = 0
    @Published var vmLocations: [ApplicationReviewSource] = []
    private var selectedRecord: ApplicationRecord?
    private var additionalSources: [ApplicationReviewSource] = []
    @Published var selectedFiles = Set<String>()
    @Published var selectedBackups = Set<String>()
    @Published var map: DiskMapReport?
    @Published var resources: [ManagedResource] = []
    @Published var selectedResources = Set<String>()
    @Published var showReviewConfirmation = false
    @Published var showManagedConfirmation = false
    @Published var pendingItems: [FileItem] = []
    @Published var managedMode = 0
    private let coordinator = UtilityCoordinator()
    private var task: Task<Void, Never>?
    private var commandTask: Task<[ManagedResource], Error>?
    private var mapBookmark: Data?
    var disabled: Bool { isBusy || owner?.isScanning == true || owner?.isCleaning == true }
    func cancel() { task?.cancel(); commandTask?.cancel(); coordinator.cancel() }
    func perform(_ request: UtilityRequest, title: String, receive: @escaping (UtilityResult) -> Void) {
        guard !disabled, let owner, let exe = Bundle.main.executableURL else { return }
        isBusy = true; status = title; error = nil
        let access = owner.beginAccess()
        var job = request; job.bookmarks = access.compactMap { try? $0.workerBookmark() }
        if let mapBookmark { job.bookmarks.append(mapBookmark) }
        task = Task {
            let result = await coordinator.run(job, executable: exe) { count in if count > 0 { self.status = "Объектов проверено: \(count.formatted())" } }
            access.forEach { $0.stop() }; isBusy = false; task = nil
            if let failure = result.error { error = failure } else { receive(result) }
        }
    }
    func loadApplications() {
        guard let owner else { return }
        perform(UtilityRequest(job: .applications, home: owner.home), title: "Читаем каталог приложений") {
            self.applications = $0.applications; owner.observe($0.applications)
        }
    }
    func review(_ app: ApplicationRecord) {
        guard let owner, !disabled, let exe = Bundle.main.executableURL else { return }
        if selectedApp != app.id { additionalSources = [] }
        selectedApp = app.id; selectedRecord = app; reviewed = []; selectedFiles = []; applicationSources = []; reviewNotes = []; reviewTotal = 0; vmLocations = []
        isBusy = true; error = nil; status = "Готовим список мест для «\(app.name)»"
        let access = owner.beginAccess(); let workerBookmarks = access.compactMap { try? $0.workerBookmark() }
        task = Task {
            defer { access.forEach { $0.stop() }; isBusy = false; task = nil }
            var plan = UtilityRequest(job: .applicationPlan, home: owner.home, app: app, policy: owner.policy()); plan.bookmarks = workerBookmarks
            let planned = await coordinator.run(plan, executable: exe)
            if let error = planned.error { self.error = error; return }
            var queue = planned.sources + additionalSources; var position = 0
            var seen = Set<String>()
            while position < queue.count && !Task.isCancelled {
                let source = queue[position]; position += 1
                guard seen.insert(source.id).inserted else { continue }
                reviewTotal = queue.count; status = "\(position) из \(queue.count) · \(source.title)"
                var request = UtilityRequest(job: .applicationReview, home: owner.home, app: app, policy: owner.policy())
                request.applicationSource = source; request.bookmarks = workerBookmarks
                let result = await coordinator.run(request, executable: exe, timeoutSeconds: 10)
                for item in result.items {
                    if let index = reviewed.firstIndex(where: { $0.id == item.id }) {
                        if item.applicationEvidence?.location?.registryURL != nil { reviewed[index] = item }
                    } else { reviewed.append(item) }
                }
                selectedFiles.formUnion(result.items.filter { $0.applicationEvidence?.isBundle == true }.map(\.id))
                reviewNotes += result.notes
                applicationSources.append(ApplicationSourceResult(source: source, status: result.sourceStatus ?? (result.error == nil ? .complete : .denied), detail: result.error))
                for discovered in result.sources {
                    if discovered.kind == .utmPackage {
                        if let index = vmLocations.firstIndex(where: { $0.id == discovered.id }) {
                            if discovered.location?.registryURL != nil { vmLocations[index] = discovered }
                        } else { vmLocations.append(discovered) }
                    }
                    if let index = queue.firstIndex(where: { $0.id == discovered.id }) {
                        if index >= position && discovered.location?.registryURL != nil { queue[index] = discovered }
                    } else { queue.append(discovered) }
                }
            }
            reviewTotal = queue.count
            if Task.isCancelled { reviewNotes.append("Поиск остановлен. Список найденных данных неполный.") }
            reviewNotes = Array(Set(reviewNotes)).sorted()
        }
    }
    func connectApplicationSource(_ source: ApplicationReviewSource) {
        guard !disabled, let app = selectedRecord else { return }
        let expected = source.kind == .utmRegistry || source.kind == .utmPackage ? source.url.deletingLastPathComponent() : source.url
        chooseApplicationFolder(expected: expected) { _ in self.review(app) }
    }
    func chooseUTMFolder() {
        guard !disabled, let app = selectedRecord, ApplicationDiscovery.isUTM(app) else { return }
        chooseApplicationFolder(expected: nil) { url in
            let source = ApplicationReviewSource(kind: .utmFolder, url: url, ownerID: app.bundleID)
            if !self.additionalSources.contains(where: { $0.id == source.id }) { self.additionalSources.append(source) }
            self.review(app)
        }
    }
    func addApplicationData() {
        guard !disabled, let owner, let app = selectedRecord else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = "Добавить к приложению"
        panel.message = "Выберите конкретные данные «\(app.name)» в нестандартном месте. Они будут показаны отдельно и не выберутся для удаления автоматически."
        guard panel.runModal() == .OK else { return }
        defer { panel.urls.forEach { $0.stopAccessingSecurityScopedResource() } }
        var skipped = 0
        for url in panel.urls {
            guard ManualAssociation.allowed(url, home: owner.home), !owner.policy().isExcluded(url), let identity = FileIdentity.read(url), !identity.isSymbolicLink else { skipped += 1; continue }
            do {
                let bookmark = try FolderAccess.bookmark(for: url)
                let old = owner.manualAssociations.filter { $0.bundleID == app.bundleID && $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
                old.forEach { owner.grantedFolders.removeValue(forKey: "manual:" + $0.id.uuidString) }
                owner.manualAssociations.removeAll { $0.bundleID == app.bundleID && $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
                let association = ManualAssociation(bundleID: app.bundleID, url: url, identity: identity, bookmark: bookmark)
                owner.manualAssociations.append(association); owner.grantedFolders["manual:" + association.id.uuidString] = bookmark
            } catch { skipped += 1 }
        }
        saveManualAssociations()
        review(app)
        if skipped > 0 { error = "Не добавлено защищённых или недоступных объектов: \(skipped)." }
    }
    func forgetApplicationData(_ url: URL) {
        guard !disabled, let owner, let app = selectedRecord else { return }
        let records = owner.manualAssociations.filter { $0.bundleID == app.bundleID && $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
        records.forEach { owner.grantedFolders.removeValue(forKey: "manual:" + $0.id.uuidString) }
        owner.manualAssociations.removeAll { record in records.contains { $0.id == record.id } }
        saveManualAssociations(); review(app)
    }
    private func saveManualAssociations() {
        guard let owner else { return }
        if let data = try? JSONEncoder().encode(owner.manualAssociations) { UserDefaults.standard.set(data, forKey: "manualAssociations") }
        UserDefaults.standard.set(owner.grantedFolders, forKey: "folderBookmarks")
    }
    private func chooseApplicationFolder(expected: URL?, action: (URL) -> Void) {
        guard let owner else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = expected; panel.prompt = "Проверить папку"
        panel.message = expected.map { "Выберите \($0.path), чтобы разрешить проверку связанных данных." } ?? "Выберите папку с виртуальными машинами .utm. Машины не будут выбраны для удаления автоматически."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let expected, url.standardizedFileURL.path != expected.standardizedFileURL.path { error = "Нужно выбрать \(expected.path)."; return }
        guard ApplicationDiscovery.validSearchRoot(url, home: owner.home) else { error = "Выберите папку внутри домашней папки или на подключённом томе."; return }
        do {
            owner.grantedFolders["app-review:" + url.path] = try FolderAccess.bookmark(for: url)
            UserDefaults.standard.set(owner.grantedFolders, forKey: "folderBookmarks")
            action(url)
        } catch { self.error = error.localizedDescription }
    }
    func loadBackups() {
        guard let owner else { return }; selectedBackups = []
        perform(UtilityRequest(job: .backups, home: owner.home, policy: owner.policy(), ageDays: owner.minimumAgeDays), title: "Проверяем завершённые резервные копии") { self.backups = $0.items; self.backupsChecked = true }
    }
    func chooseMapFolder() {
        guard !disabled else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Карта покажет размеры папок. Файлы не изменяются."; panel.prompt = "Построить карту"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mapBookmark = try? FolderAccess.bookmark(for: url); scanMap(url)
        url.stopAccessingSecurityScopedResource()
    }
    func scanMap(_ url: URL) {
        guard let owner else { return }
        perform(UtilityRequest(job: .diskMap, home: owner.home, url: url), title: "Считаем размеры папок") { self.map = $0.map }
    }
    func loadResources() {
        guard !disabled, let owner else { return }
        isBusy = true; error = nil; status = managedMode == 0 ? "Запрашиваем симуляторы Xcode" : "Подключаемся к локальному Docker"
        resources = []; selectedResources = []
        let mode = managedMode; let home = owner.home
        task = Task {
            do {
                let command = Task.detached(priority: .utility) {
                    mode == 0 ? try ManagedResources.simulators() : try ManagedResources.docker(home: home)
                }
                commandTask = command; resources = try await command.value
            } catch {
                self.error = mode == 0 ? "Нужен полный Xcode с инструментом simctl. Если Xcode установлен, выберите его в Xcode → Settings → Locations → Command Line Tools.\n\n\(error.localizedDescription)" : "Docker недоступен. Запустите Docker Desktop и выберите локальный контекст, затем повторите проверку.\n\n\(error.localizedDescription)"
            }
            isBusy = false; task = nil; commandTask = nil
        }
    }
    func confirm(_ items: [FileItem]) { guard !disabled, !items.isEmpty else { return }; pendingItems = items; showReviewConfirmation = true }
    func trashPending() {
        showReviewConfirmation = false
        owner?.moveReviewedItems(pendingItems) { self.reviewed = []; self.backups = []; self.selectedFiles = []; self.selectedBackups = [] }
    }
}

struct UtilityStatus: View {
    @EnvironmentObject var utility: UtilityModel
    @EnvironmentObject var model: AppModel
    var body: some View {
        if utility.isBusy {
            HStack { ProgressView().controlSize(.small); Text(utility.status).font(.system(size: 12)); Spacer()
                Button("Остановить") { utility.cancel() }.buttonStyle(QuietButton())
            }.padding(15).background(Palette.lavender, in: RoundedRectangle(cornerRadius: 12))
        }
        if model.isCleaning { HStack { ProgressView().controlSize(.small); Text(model.operationProgress); Spacer() }.font(.system(size: 12)).padding(15) }
        if let error = utility.error { Text(error).font(.system(size: 12)).foregroundStyle(Palette.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(17).background(.white, in: RoundedRectangle(cornerRadius: 12)) }
    }
}

struct ApplicationsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var utility: UtilityModel
    @State private var query = ""
    var body: some View {
        let currentPolicy = model.policy()
        VStack(spacing: 16) {
            HStack {
                TextField("Найти приложение", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Spacer()
                Button("Обновить список") { utility.loadApplications() }.buttonStyle(QuietButton()).disabled(utility.disabled)
            }
            UtilityStatus()
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(utility.applications.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { app in
                            let protected = ApplicationInventory.protected(app, policy: currentPolicy)
                            Button { utility.review(app) } label: {
                                HStack(spacing: 11) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 33, height: 33)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(app.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                        Text(protected ? "Защищено или работает" : "Версия " + app.version).font(.system(size: 9)).foregroundStyle(Palette.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(11).background(utility.selectedApp == app.id ? Palette.lavender : .white, in: RoundedRectangle(cornerRadius: 11)).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(utility.disabled || protected)
                        }
                    }
                }.frame(width: 258)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Приложение и связанные файлы").font(.system(size: 17, weight: .semibold))
                    Text("Данные и виртуальные машины выбираются отдельно. Поиск может быть неполным без доступа к папкам или внешнему диску.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    if utility.selectedApp != nil { Button("Добавить файл или папку…") { utility.addApplicationData() }.buttonStyle(QuietButton()).disabled(utility.disabled) }
                    if let app = utility.applications.first(where: { $0.id == utility.selectedApp }), ApplicationDiscovery.isUTM(app) {
                        Button("Проверить папку с .utm…") { utility.chooseUTMFolder() }.buttonStyle(QuietButton()).disabled(utility.disabled)
                        Text("Размеры VM логические: разреженные диски могут занимать меньше места.").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                    }
                    if utility.reviewed.isEmpty && utility.selectedApp == nil { UtilityEmpty(symbol: "app.dashed", title: "Выберите приложение", text: "Сначала покажем состав и размер. Данные не выбираются автоматически.") }
                    else {
                        ScrollView { LazyVStack(spacing: 9) {
                            ForEach(utility.reviewed) { item in ReviewedFileRow(item: item, checked: utility.selectedFiles.contains(item.id)) { toggle(item.id, in: &utility.selectedFiles) } }
                            ForEach(utility.vmLocations.filter { source in !utility.reviewed.contains { $0.id == source.url.standardizedFileURL.path } }) { source in UnresolvedVMRow(source: source) }
                            ApplicationSourceSummary()
                        } }
                        Button("В Корзину · " + FileSize.string(utility.reviewed.filter { utility.selectedFiles.contains($0.id) }.reduce(0) { $0 + $1.bytes })) {
                            utility.confirm(utility.reviewed.filter { utility.selectedFiles.contains($0.id) })
                        }.buttonStyle(PrimaryButton()).disabled(utility.disabled || utility.selectedFiles.isEmpty || !model.historyReady)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(21).background(.white, in: RoundedRectangle(cornerRadius: 18))
            }
        }.padding(.horizontal, 36).padding(.bottom, 25).onAppear { if utility.applications.isEmpty { utility.loadApplications() } }
    }
}

private func toggle(_ id: String, in set: inout Set<String>) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }

struct ReviewedFileRow: View {
    let item: FileItem
    let checked: Bool
    let action: () -> Void
    @EnvironmentObject var utility: UtilityModel
    private var isVM: Bool { item.applicationEvidence?.location?.kind == .virtualMachine }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? Palette.accent : Palette.secondary)
                IconTile(symbol: isVM ? "desktopcomputer" : item.isDirectory ? "folder" : "doc", color: isVM ? Palette.orange : Palette.accent, size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if isVM { Text("Виртуальная машина · содержит систему и личные данные").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.orange) }
                    else if item.applicationEvidence?.location?.sensitive == true { Text("Документы и данные приложения").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.orange) }
                    Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 9)).foregroundStyle(Palette.secondary).lineLimit(2).truncationMode(.middle)
                }
                Spacer(minLength: 5)
                Text(FileSize.string(item.bytes)).font(.system(size: 11, weight: .medium))
            }.padding(12).background(checked ? Palette.lavender.opacity(0.45) : Palette.background, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(utility.disabled).accessibilityLabel((checked ? "Выбрано: " : "Выбрать: ") + item.name + (isVM ? ", виртуальная машина с личными данными" : ""))
        .contextMenu {
            if item.applicationEvidence?.location?.kind == .manual { Button("Убрать связь с приложением") { utility.forgetApplicationData(item.url) } }
        }
    }
}

struct ApplicationSourceSummary: View {
    @EnvironmentObject var utility: UtilityModel
    @State private var expanded = false
    private var incomplete: [ApplicationSourceResult] { utility.applicationSources.filter { [.denied, .timedOut, .cancelled, .limited].contains($0.status) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !incomplete.isEmpty {
                Label("Не все места проверены · \(incomplete.count)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.orange)
                Text("Недоступные папки не считаются пустыми. Можно подключить папку и повторить поиск.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            DisclosureGroup("Места поиска · \(utility.applicationSources.count) из \(utility.reviewTotal)", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(utility.applicationSources) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.source.title).font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(entry.status == .denied ? "Не удалось проверить" : entry.status.title).font(.system(size: 9)).foregroundStyle([.denied, .timedOut].contains(entry.status) ? Palette.orange : Palette.secondary)
                            }
                            Text(entry.source.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 9)).foregroundStyle(Palette.secondary).textSelection(.enabled)
                            if let detail = entry.detail { Text(detail).font(.system(size: 9)).foregroundStyle(Palette.orange) }
                            if [.denied, .timedOut].contains(entry.status), entry.source.kind != .standard, entry.source.kind != .utmSpotlight, entry.source.kind != .utmPackage {
                                Button("Подключить папку…") { utility.connectApplicationSource(entry.source) }.buttonStyle(QuietButton()).disabled(utility.disabled)
                            }
                        }
                    }
                }.padding(.top, 10)
            }.font(.system(size: 11))
            ForEach(utility.reviewNotes, id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(Palette.secondary).textSelection(.enabled) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.background, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct UnresolvedVMRow: View {
    let source: ApplicationReviewSource
    @EnvironmentObject var utility: UtilityModel
    private var result: ApplicationSourceResult? { utility.applicationSources.first { $0.source.id == source.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                IconTile(symbol: "desktopcomputer", color: Palette.orange, size: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.url.lastPathComponent).font(.system(size: 12, weight: .semibold))
                    Text(result?.status == .missing ? "Не найдено по сохранённому пути" : "Найден путь .utm · содержимое ещё не подтверждено").font(.system(size: 10)).foregroundStyle(Palette.orange)
                }
                Spacer()
            }
            Text(source.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 9)).foregroundStyle(Palette.secondary).textSelection(.enabled)
            if let detail = result?.detail { Text(detail).font(.system(size: 9)).foregroundStyle(Palette.secondary) }
            if !utility.isBusy && result?.status != .missing {
                Button("Подключить папку и проверить…") { utility.connectApplicationSource(source) }.buttonStyle(QuietButton()).disabled(utility.disabled)
            }
            Text("Выбор для удаления появится после проверки пакета. Виртуальные машины не отмечаются автоматически.").font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Palette.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct BackupsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var utility: UtilityModel
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            Surface {
                HStack(alignment: .top, spacing: 16) {
                    IconTile(symbol: "iphone", color: Palette.blue, size: 48)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Резервные копии устройств").font(.system(size: 22, weight: .bold))
                        Text("Резервная копия может быть единственным способом вернуть данные устройства. Здесь показываются только завершённые копии старше \(model.minimumAgeDays) дней. Переносим всю копию целиком; до очистки Корзины её можно восстановить.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    }
                }
            }
            HStack {
                Button("Найти копии") { utility.loadBackups() }.buttonStyle(PrimaryButton()).disabled(utility.disabled)
                Button("Показать папку") { model.reveal(model.home.appendingPathComponent(BackupInventory.relativeRoot)) }.buttonStyle(QuietButton())
                Spacer()
                if !utility.selectedBackups.isEmpty {
                    Button("Перенести выбранные…") { utility.confirm(utility.backups.filter { utility.selectedBackups.contains($0.id) }) }.buttonStyle(QuietButton()).disabled(utility.disabled || !model.historyReady)
                }
            }
            UtilityStatus()
            if utility.backups.isEmpty && !utility.isBusy { UtilityEmpty(symbol: "externaldrive.badge.checkmark", title: utility.backupsChecked ? "Подходящих копий не найдено" : "Нет копий в списке", text: utility.backupsChecked ? "Новые, незавершённые, неизвестные форматы и недоступные копии не предлагаются." : "Запустите поиск. Новые, незавершённые и недоступные копии защищены.") }
            else { ScrollView { LazyVStack(spacing: 10) { ForEach(utility.backups) { item in
                VStack(alignment: .leading, spacing: 6) {
                    ReviewedFileRow(item: item, checked: utility.selectedBackups.contains(item.id)) { toggle(item.id, in: &utility.selectedBackups) }
                    Text(item.modified, format: .dateTime.day().month().year()).font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.leading, 12)
                }
            } } } }
        }.padding(.horizontal, 36).padding(.bottom, 26)
    }
}

struct DiskMapView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var utility: UtilityModel
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button("Выбрать папку…") { utility.chooseMapFolder() }.buttonStyle(PrimaryButton()).disabled(utility.disabled)
                if let map = utility.map {
                    Button { utility.scanMap(map.root.deletingLastPathComponent()) } label: { Label("Выше", systemImage: "arrow.up") }.buttonStyle(QuietButton()).disabled(utility.disabled || map.root.path == "/")
                    Button { utility.scanMap(map.root) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(QuietButton()).disabled(utility.disabled)
                }
                Spacer()
            }
            UtilityStatus()
            if let map = utility.map {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(map.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text("Размер файлов · жёсткие ссылки учтены один раз · без загрузки из iCloud").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(); Text(FileSize.string(map.bytes)).font(.system(size: 25, weight: .bold))
                }
                if map.inaccessible > 0 || map.truncated { Text("Карта неполная. Недоступных путей: \(map.inaccessible)." + (map.truncated ? " Достигнут лимит 500 000 объектов." : "")).font(.system(size: 11)).foregroundStyle(Palette.orange) }
                MapTiles(entries: map.children).frame(height: 220)
                ScrollView { LazyVStack(spacing: 1) { ForEach(map.children) { item in
                    Button { if item.directory { utility.scanMap(item.url) } else { model.reveal(item.url) } } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: item.directory ? "folder" : "doc", size: 30)
                            Text(item.url.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                            Spacer(); Text(FileSize.string(item.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                            Image(systemName: item.directory ? "chevron.right" : "arrow.up.right").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        }.padding(10).background(.white).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(utility.disabled)
                } } }.clipShape(RoundedRectangle(cornerRadius: 14))
            } else { UtilityEmpty(symbol: "chart.pie", title: "Карта диска", text: "Выберите папку. Нажимайте на блоки карты, чтобы увидеть её содержимое.") }
            Text("Логические размеры могут отличаться от занятого места APFS из-за сжатия, клонов и снимков.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }.padding(.horizontal, 36).padding(.bottom, 25)
    }
}

private struct MapTile: Identifiable { let id: Int; let entry: DiskMapEntry; let rect: CGRect; let other: Bool }
private struct MapTiles: View {
    let entries: [DiskMapEntry]
    @EnvironmentObject var utility: UtilityModel
    @EnvironmentObject var model: AppModel
    private let colors = [Palette.accent, Palette.blue, Palette.mint, Palette.orange, Color(hex: 0x9D82D4)]
    private func tiles(in rect: CGRect) -> [MapTile] {
        let nonzero = entries.filter { $0.bytes > 0 }; var list = Array(nonzero.prefix(23))
        if nonzero.count > 23 { list.append(DiskMapEntry(url: URL(fileURLWithPath: "/Остальное"), bytes: nonzero.dropFirst(23).reduce(0) { $0 + $1.bytes }, directory: false)) }
        func divide(_ range: Range<Int>, _ box: CGRect) -> [MapTile] {
            guard !range.isEmpty else { return [] }
            if range.count == 1 { let index = range.lowerBound; return [MapTile(id: index, entry: list[index], rect: box, other: index == 23 && nonzero.count > 23)] }
            let total = range.reduce(0.0) { $0 + Double(list[$1].bytes) }; var first = 0.0; var split = range.lowerBound + 1
            for index in range.dropLast() { first += Double(list[index].bytes); split = index + 1; if first >= total / 2 { break } }
            let ratio = total > 0 ? first / total : 0.5
            let horizontal = box.width >= box.height
            let a = CGRect(x: box.minX, y: box.minY, width: horizontal ? box.width * ratio : box.width, height: horizontal ? box.height : box.height * ratio)
            let b = CGRect(x: horizontal ? a.maxX : box.minX, y: horizontal ? box.minY : a.maxY, width: horizontal ? box.width - a.width : box.width, height: horizontal ? box.height : box.height - a.height)
            return divide(range.lowerBound..<split, a) + divide(split..<range.upperBound, b)
        }
        return divide(list.indices, rect)
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(tiles(in: CGRect(origin: .zero, size: geometry.size))) { tile in
                    Button { if tile.entry.directory { utility.scanMap(tile.entry.url) } else if !tile.other { model.reveal(tile.entry.url) } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            if tile.rect.width > 80 && tile.rect.height > 40 {
                                Text(tile.entry.url.lastPathComponent).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                                Text(FileSize.string(tile.entry.bytes)).font(.system(size: 10))
                            }
                        }.padding(10).frame(width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3), alignment: .topLeading)
                            .background(colors[tile.id % colors.count].opacity(tile.other ? 0.5 : 0.88), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white).clipped().contentShape(Rectangle())
                    }.buttonStyle(.plain).offset(x: tile.rect.minX, y: tile.rect.minY).disabled(utility.disabled || tile.other)
                        .help(tile.entry.url.lastPathComponent + " · " + FileSize.string(tile.entry.bytes)).accessibilityLabel(tile.entry.url.lastPathComponent + " · " + FileSize.string(tile.entry.bytes))
                }
            }
        }
    }
}

struct ManagedResourcesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var utility: UtilityModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Инструмент", selection: $utility.managedMode) { Text("Симуляторы Xcode").tag(0); Text("Docker Desktop").tag(1) }.pickerStyle(.segmented).frame(width: 340).disabled(utility.disabled)
                    .onChange(of: utility.managedMode) { _, _ in utility.resources = []; utility.selectedResources = []; utility.error = nil }
                Spacer(); Button("Проверить") { utility.loadResources() }.buttonStyle(PrimaryButton()).disabled(utility.disabled)
            }
            Text(utility.managedMode == 0 ? "Только выключенные симуляторы с недоступной средой исполнения. Удаление через simctl также удалит их приложения и данные." : "Локальный Docker: образы без тегов, остановленные контейнеры и старый неиспользуемый кэш сборок. Тома с данными сохраняются.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4)
            UtilityStatus()
            if utility.resources.isEmpty && !utility.isBusy { UtilityEmpty(symbol: "shippingbox", title: "Ресурсы среды разработки", text: "Выберите инструмент и нажмите «Проверить». Ничего не запускается и не удаляется автоматически.") }
            else {
                ScrollView { LazyVStack(spacing: 10) { ForEach(utility.resources) { resource in
                    Button { toggle(resource.id, in: &utility.selectedResources) } label: {
                        HStack(spacing: 13) {
                            Image(systemName: utility.selectedResources.contains(resource.id) ? "checkmark.square.fill" : "square").foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(resource.name).font(.system(size: 13, weight: .semibold))
                                Text(resource.detail).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(3)
                            }
                            Spacer(); if let bytes = resource.bytes { Text(FileSize.string(bytes)).font(.system(size: 12)) }
                        }.padding(17).background(.white, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(utility.disabled)
                } } }
                HStack { Text("Удаление этих ресурсов нельзя отменить.").font(.system(size: 11)).foregroundStyle(Palette.orange); Spacer()
                    Button("Проверить выбор…") { utility.showManagedConfirmation = true }.buttonStyle(PrimaryButton()).disabled(utility.disabled || utility.selectedResources.isEmpty)
                }
            }
        }.padding(.horizontal, 36).padding(.bottom, 26)
    }
}

struct UtilityEmpty: View {
    let symbol: String
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 17) {
            IconTile(symbol: symbol, size: 66)
            Text(title).font(.system(size: 23, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 390)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(25)
    }
}

struct ReviewedItemsConfirmation: View {
    @EnvironmentObject var utility: UtilityModel
    @State private var acknowledgePersonalData = false
    private var containsPersonalData: Bool { utility.pendingItems.contains { $0.applicationEvidence?.location?.sensitive == true } }
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            IconTile(symbol: "trash", size: 54)
            Text("Перенести выбранное в Корзину?").font(.system(size: 23, weight: .bold))
            Text("Объектов: \(utility.pendingItems.count) · " + FileSize.string(utility.pendingItems.reduce(0) { $0 + $1.bytes })).font(.system(size: 13))
            Text(utility.pendingItems.contains { $0.category == .backups } ? "После очистки Корзины резервная копия будет потеряна. Убедитесь, что нужные данные есть в другой копии." : "Связанные данные могут содержать настройки и личные проекты. Просмотрите каждый путь. Если операция будет остановлена, уже перенесённые объекты останутся в истории.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4)
            ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(utility.pendingItems) { Text($0.url.path).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } } }.frame(maxHeight: 180)
            if containsPersonalData {
                Toggle("Я понимаю, что выбраны целые виртуальные машины или документы с личными данными.", isOn: $acknowledgePersonalData).font(.system(size: 12)).foregroundStyle(Palette.orange)
            }
            HStack { Button("Отмена") { utility.showReviewConfirmation = false }.buttonStyle(QuietButton()); Spacer(); Button("Перенести в Корзину") { utility.trashPending() }.buttonStyle(PrimaryButton()).disabled(containsPersonalData && !acknowledgePersonalData) }
        }.padding(30).frame(width: 540).foregroundStyle(Palette.ink)
    }
}

struct ManagedConfirmation: View {
    @EnvironmentObject var utility: UtilityModel
    @EnvironmentObject var model: AppModel
    @State private var confirmation = ""
    private var chosen: [ManagedResource] { utility.resources.filter { utility.selectedResources.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            IconTile(symbol: "exclamationmark.triangle", color: Palette.orange, size: 54)
            Text("Удаление без восстановления").font(.system(size: 23, weight: .bold))
            Text("Действие выполнят Xcode или Docker. Корзина и отмена недоступны. Будут удалены только перечисленные ресурсы; состояние проверится ещё раз.").font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4)
            ScrollView { VStack(alignment: .leading, spacing: 12) { ForEach(chosen) { item in
                VStack(alignment: .leading, spacing: 5) { Text(item.name).font(.system(size: 12, weight: .semibold)); Text(item.key).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary).textSelection(.enabled) }
            } } }.frame(maxHeight: 180)
            TextField("Введите УДАЛИТЬ", text: $confirmation).textFieldStyle(.roundedBorder)
            HStack { Button("Отмена") { utility.showManagedConfirmation = false }.buttonStyle(QuietButton()); Spacer()
                Button("Удалить окончательно") { utility.showManagedConfirmation = false; model.removeManagedResources(chosen) }.buttonStyle(PrimaryButton()).disabled(confirmation != "УДАЛИТЬ" || chosen.isEmpty)
            }
        }.padding(30).frame(width: 540).foregroundStyle(Palette.ink)
    }
}
