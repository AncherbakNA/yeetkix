import Foundation
import Darwin

public struct FileIdentity: Codable, Hashable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let bytes: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let isRegular: Bool
    public let isSymbolicLink: Bool
    public let links: UInt16

    public static func read(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }) else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, bytes: info.st_size,
                            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                            isRegular: (info.st_mode & S_IFMT) == S_IFREG,
                            isSymbolicLink: (info.st_mode & S_IFMT) == S_IFLNK,
                            links: info.st_nlink)
    }
    public func sameFile(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode && isRegular == other.isRegular
    }
}

public struct RunningApplication: Codable, Sendable {
    public let bundleID: String
    public let name: String
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}

public struct SafetyPolicy: Codable, Sendable {
    public var excludedPaths: [String]
    public var runningApplications: [RunningApplication]
    public var developerToolsBusy: Bool
    public var applicationRoots: [URL]?
    public var checkRegisteredApplications: Bool
    public var knownApplications: [KnownApplication]
    public var virtualMachinesBusy: Bool? = nil
    public var activeProcesses: [String]? = nil
    public var manualAssociations: [ManualAssociation]? = nil
    public init(excludedPaths: [String] = [], runningApplications: [RunningApplication] = [], developerToolsBusy: Bool = false,
                applicationRoots: [URL]? = nil, checkRegisteredApplications: Bool = true, knownApplications: [KnownApplication] = []) {
        self.excludedPaths = excludedPaths; self.runningApplications = runningApplications
        self.developerToolsBusy = developerToolsBusy; self.applicationRoots = applicationRoots; self.checkRegisteredApplications = checkRegisteredApplications
        self.knownApplications = knownApplications
    }
    public func isExcluded(_ url: URL) -> Bool {
        let paths = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
        return excludedPaths.contains { excluded in
            let root = URL(fileURLWithPath: excluded).standardizedFileURL
            let roots = [root.path, root.resolvingSymlinksInPath().path]
            return paths.contains { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") } }
        }
    }
    public func belongsToRunningApp(_ url: URL, home: URL) -> Bool {
        let relative = url.path.replacingOccurrences(of: home.path + "/", with: "").lowercased()
        let components = relative.split(separator: "/").map(String.init)
        func normalized(_ value: String) -> String { String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }
        return runningApplications.contains { app in
            let bundle = app.bundleID.lowercased()
            let name = normalized(app.name)
            let bundleName = normalized(bundle.split(separator: ".").last.map(String.init) ?? "")
            let aliases: [String: [String]] = [
                "com.openai.codex": ["codex", "chatgpt"],
                "com.microsoft.vscode": ["code", "codeinsiders"],
                "com.google.chrome": ["chrome", "googlechrome"],
                "com.jetbrains.pycharm.ce": ["pycharm", "pycharmce"]
            ]
            let names = Set(([name] + (bundleName.count >= 3 ? [bundleName] : []) + (aliases[bundle] ?? [])).filter { !$0.isEmpty })
            return components.contains { component in
                (!bundle.isEmpty && (component == bundle || component.hasPrefix(bundle + ".")))
                || names.contains(normalized(component))
            }
        }
    }
    public func protectionReason(for url: URL, category: FileCategory, home: URL) -> String? {
        if isExcluded(url) { return "Файл находится в исключениях" }
        if let location = JunkCatalog.location(url, home: home, applications: knownApplications), [.cache, .logs, .toolCaches].contains(category) {
            if JunkCatalog.activeOwners(location.owners, policy: self) { return "Приложение, использующее кэш, сейчас работает" }
            if !location.processes.isEmpty && (!location.processes.isDisjoint(with: Set(activeProcesses ?? ["__unknown__"])) || activeProcesses == nil || activeProcesses?.contains("__unknown__") == true) { return "Инструмент, использующий кэш, сейчас работает или его состояние неизвестно" }
        }
        if category == .developer {
            if developerToolsBusy || runningApplications.contains(where: { $0.bundleID.lowercased().contains("xcode") || $0.name.lowercased() == "xcode" }) { return "Xcode или процесс сборки сейчас работает" }
            let directory = FileIdentity.read(url).map { !$0.isRegular && !$0.isSymbolicLink } ?? false
            if !ArtifactPaths.developerAllowed(url, home: home, directory: directory) { return "Этот путь не относится к разрешённым данным сборки" }
            return nil
        }
        if category == .leftovers {
            if belongsToRunningApp(url, home: home) { return "Приложение сейчас работает" }
            return nil
        }
        guard category == .cache || category == .logs || category == .toolCaches else { return nil }
        if belongsToRunningApp(url, home: home) { return "Приложение сейчас работает" }
        let name = url.lastPathComponent.lowercased()
        if url.pathComponents.contains(where: { $0.hasPrefix("com.apple.") }) { return "Данные системного приложения Apple" }
        let ext = url.pathExtension.lowercased()
        if ["db", "sqlite", "sqlite3", "realm", "lock", "plist", "keychain", "keychain-db"].contains(ext)
            || name.hasSuffix("-wal") || name.hasSuffix("-shm") || name == "lock" {
            return "База данных, настройки или служебная блокировка"
        }
        if let identity = FileIdentity.read(url), identity.isRegular, identity.links > 1 { return "Файл имеет несколько жёстких ссылок" }
        return nil
    }
    public func validate(_ item: FileItem, home: URL, minimumAgeDays: Int) throws {
        if item.category == .leftovers && item.orphanEvidence != nil {
            try JunkCatalog.validateOrphan(item, home: home, policy: self); return
        }
        if item.category == .applications || item.category == .backups {
            try ReviewedArtifactSafety.validate(item, home: home, policy: self, minimumAgeDays: minimumAgeDays)
            return
        }
        guard TrashSafety.isAllowed(item.url, home: home, knownApplications: knownApplications), !item.isDirectory else { throw SafetyError("Путь не разрешён для очистки") }
        let relativePath = ArtifactPaths.relative(item.url, to: home) ?? ""
        let roots: [String]
        switch item.category {
        case .cache: roots = ["Library/Caches"] + JunkCatalog.appCaches(knownApplications).filter { $0.category == .cache }.map(\.relativePath)
        case .logs: roots = ["Library/Logs"] + JunkCatalog.appCaches(knownApplications).filter { $0.category == .logs }.map(\.relativePath)
        case .toolCaches: roots = JunkCatalog.toolCaches.map(\.relativePath)
        case .downloads: roots = ["Downloads"]
        case .large, .duplicates: roots = ArtifactPaths.personal
        case .leftovers: roots = ArtifactPaths.leftoverRoots
        case .developer: roots = ArtifactPaths.developerRoots
        case .trash: throw SafetyError("Корзина не очищается автоматически")
        case .applications, .backups: throw SafetyError("Нужен отдельный просмотр")
        }
        guard roots.contains(where: { relativePath.hasPrefix($0 + "/") }) else { throw SafetyError("Файл не принадлежит выбранной категории") }
        if [.cache, .logs, .toolCaches].contains(item.category), JunkCatalog.location(item.url, home: home, applications: knownApplications) != nil {
            try JunkCatalog.validateCache(item, home: home, policy: self)
        }
        var current = home.standardizedFileURL
        let relative = item.url.standardizedFileURL.pathComponents.dropFirst(home.standardizedFileURL.pathComponents.count)
        for part in relative {
            current.appendPathComponent(part)
            if let identity = FileIdentity.read(current), identity.isSymbolicLink { throw SafetyError("Символические ссылки пропускаются") }
            if (try? current.resourceValues(forKeys: [.isPackageKey]).isPackage) == true,
               !(item.category == .developer && ArtifactPaths.developerAllowed(current, home: home, directory: true)) {
                throw SafetyError("Содержимое пакетов приложений защищено")
            }
        }
        if let reason = protectionReason(for: item.url, category: item.category, home: home) { throw SafetyError(reason) }
        guard let before = item.identity, let now = FileIdentity.read(item.url), before == now, now.isRegular else {
            throw SafetyError("Файл изменился после сканирования или недоступен")
        }
        if item.category == .duplicates {
            guard let proof = item.duplicateEvidence, item.url.standardizedFileURL != proof.keeperURL.standardizedFileURL,
                  TrashSafety.isAllowed(proof.keeperURL, home: home), FileIdentity.read(proof.keeperURL) == proof.keeperIdentity else {
                throw SafetyError("Одну неизменённую копию необходимо сохранить")
            }
        }
        if item.category == .leftovers {
            guard let bundleID = item.leftoverBundleID, ArtifactPaths.leftoverID(item.url, home: home, knownApplications: knownApplications) == bundleID,
                  !ApplicationCatalog.isInstalled(bundleID, snapshot: ApplicationCatalog.snapshot(home: home, roots: applicationRoots),
                                                  checkRegistry: checkRegisteredApplications) else { throw SafetyError("Приложение установлено или принадлежность файла не подтверждена") }
        }
        if item.category == .cache || item.category == .logs || item.category == .developer || item.category == .leftovers || item.category == .toolCaches {
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -max(7, minimumAgeDays), to: Date()),
                  item.modified < cutoff else { throw SafetyError("Файл слишком новый для очистки") }
        }
    }
}

public struct SafetyError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
