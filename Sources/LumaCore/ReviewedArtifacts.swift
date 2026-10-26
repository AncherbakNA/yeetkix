import Foundation
import CryptoKit
import Darwin

/// A metadata manifest, relative to the directory. Links are recorded, never followed.
public struct DirectoryEvidence: Codable, Hashable, Sendable {
    public let digest: String
    public let bytes: Int64
    public let entries: Int

    public static func capture(_ suppliedRoot: URL, policy: SafetyPolicy = SafetyPolicy(), limit: Int = 500_000,
                               heartbeat: () -> Void = {}) throws -> DirectoryEvidence {
        let fm = FileManager.default
        guard let original = FileIdentity.read(suppliedRoot), !original.isRegular, !original.isSymbolicLink,
              (try suppliedRoot.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw SafetyError("Папка недоступна или заменена ссылкой") }
        // Foundation may abbreviate /private/var back to /var while its enumerator
        // returns physical paths. Use POSIX realpath so relative manifests survive renames.
        guard let resolved = suppliedRoot.withUnsafeFileSystemRepresentation({ path in path.flatMap { realpath($0, nil) } }) else { throw SafetyError("Не удалось определить путь папки") }
        let physicalPath = String(cString: resolved); free(resolved)
        let root = URL(fileURLWithPath: physicalPath, isDirectory: true)
        var issue: Error?
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, error in issue = error; return false }) else { throw SafetyError("Не удалось проверить содержимое папки") }
        var records = [String](); var bytes: Int64 = 0; var inodes = Set<String>()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var lastPulse = Date.distantPast
        for case let url as URL in walk {
            if Task.isCancelled { throw CancellationError() }
            guard records.count < limit else { throw SafetyError("Папка слишком большая для безопасной операции. Используйте Finder.") }
            guard !policy.isExcluded(url), let identity = FileIdentity.read(url), identity.device == original.device else { throw SafetyError("Внутри есть исключённые, недоступные файлы или другой том") }
            let values = try url.resourceValues(forKeys: Set(keys))
            if identity.isSymbolicLink { DirectoryTraversal.skipDirectory(url, in: walk) }
            else if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current { throw SafetyError("Папка содержит файлы, не загруженные из iCloud") }
            else if !identity.isRegular && values.isDirectory != true { throw SafetyError("Папка содержит специальный объект файловой системы") }
            let relative = url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
            let encoded = try encoder.encode(identity).base64EncodedString()
            let link = identity.isSymbolicLink ? try fm.destinationOfSymbolicLink(atPath: url.path) : ""
            let record = Data(relative.utf8).base64EncodedString() + ":" + encoded + ":" + Data(link.utf8).base64EncodedString()
            records.append(record)
            if identity.isRegular && inodes.insert("\(identity.device):\(identity.inode)").inserted { bytes += max(0, identity.bytes) }
            if Date().timeIntervalSince(lastPulse) > 0.4 { heartbeat(); lastPulse = Date() }
        }
        if let issue { throw issue }
        guard FileIdentity.read(root) == original else { throw SafetyError("Папка меняется во время проверки") }
        var hash = SHA256()
        for record in records.sorted() { hash.update(data: Data((record + "\n").utf8)) }
        return DirectoryEvidence(digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes, entries: records.count)
    }
}

public struct KnownApplication: Codable, Hashable, Sendable {
    public let bundleID: String
    public let names: [String]
    public var containerIDs: [String]?
    public var groupIDs: [String]?
    public init(bundleID: String, names: [String], containerIDs: [String]? = nil, groupIDs: [String]? = nil) {
        self.bundleID = bundleID; self.names = names; self.containerIDs = containerIDs; self.groupIDs = groupIDs
    }
}

public struct ApplicationRecord: Codable, Identifiable, Sendable {
    public let url: URL
    public let bundleID: String
    public let name: String
    public let version: String
    public let names: [String]
    public let identity: FileIdentity
    public var id: String { url.path }
    public var known: KnownApplication { KnownApplication(bundleID: bundleID, names: names, containerIDs: ApplicationCapabilities.identifiers(self), groupIDs: ApplicationCapabilities.groups(self)) }
}

public struct ApplicationEvidence: Codable, Hashable, Sendable {
    public let bundleURL: URL
    public let bundleID: String
    public let bundleIdentity: FileIdentity
    public let isBundle: Bool
    public var location: ApplicationLocationEvidence? = nil
}

public enum ApplicationInventory {
    public static func roots(home: URL) -> [URL] { [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] }
    public static func record(_ url: URL) -> ApplicationRecord? {
        guard url.pathExtension.lowercased() == "app", let identity = FileIdentity.read(url), !identity.isSymbolicLink,
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let bundle = info["CFBundleIdentifier"] as? String, ApplicationCapabilities.validID(bundle) else { return nil }
        let fallback = url.deletingPathExtension().lastPathComponent
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? fallback
        let names = Array(Set([fallback, name, info["CFBundleName"] as? String ?? ""].filter { $0.count >= 4 && !$0.contains("/") && !$0.hasPrefix(".") })).sorted()
        return ApplicationRecord(url: url, bundleID: bundle, name: name, version: info["CFBundleShortVersionString"] as? String ?? "—", names: names, identity: identity)
    }
    public static func list(home: URL, roots override: [URL]? = nil) -> [ApplicationRecord] {
        var records = [ApplicationRecord]()
        for root in override ?? roots(home: home) {
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walk {
                if FileIdentity.read(url)?.isSymbolicLink == true { DirectoryTraversal.skipDirectory(url, in: walk); continue }
                if let record = record(url) { records.append(record); DirectoryTraversal.skipDirectory(url, in: walk) }
            }
        }
        return records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func protected(_ app: ApplicationRecord, policy: SafetyPolicy) -> Bool {
        let id = app.bundleID.lowercased()
        return id.hasPrefix("com.apple.") || id == "local.luma.cleaner" || id.hasPrefix("app.yeetkix")
            || policy.isExcluded(app.url) || policy.runningApplications.contains { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }
            || (ApplicationDiscovery.isUTM(app) && policy.virtualMachinesBusy == true)
    }
    public static func allowedBundle(_ url: URL, home: URL, roots override: [URL]? = nil) -> Bool {
        guard url.pathExtension.lowercased() == "app", FileIdentity.read(url)?.isSymbolicLink != true else { return false }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        return (override ?? roots(home: home)).contains { root in
            let base = root.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonical.hasPrefix(base + "/") else { return false }
            let parents = canonical.dropFirst(base.count + 1).split(separator: "/").dropLast()
            return !parents.contains { $0.lowercased().hasSuffix(".app") }
        }
    }
    public static func relatedURLs(_ app: ApplicationRecord, home: URL, installed: [ApplicationRecord]) -> [URL] {
        // Only explicit bundle IDs and unambiguous names from the app's own Info.plist.
        let vendor = app.bundleID.split(separator: ".").dropFirst().first.map(String.init)?.lowercased() ?? ""
        let generic: Set<String> = [vendor, "adobe", "microsoft", "google", "jetbrains", "apple", "openai", "electron", "mozilla"]
        let names = Array(Set(app.names + (ApplicationDiscovery.isUTM(app) ? ["UTM"] : [])))
        let uniqueNames = names.filter { name in !generic.contains(name.lowercased()) && !installed.contains { other in
            other.bundleID != app.bundleID && (other.name.caseInsensitiveCompare(name) == .orderedSame || other.names.contains { $0.caseInsensitiveCompare(name) == .orderedSame })
        } }
        var urls = [URL]()
        for root in ArtifactPaths.leftoverRoots {
            let suffix = root.hasSuffix("Preferences") ? ".plist" : root.hasSuffix("State") ? ".savedState" : ""
            urls.append(home.appendingPathComponent(root).appendingPathComponent(app.bundleID + suffix))
            if suffix.isEmpty { urls += uniqueNames.map { home.appendingPathComponent(root).appendingPathComponent($0) } }
        }
        for root in ["Library/HTTPStorages", "Library/WebKit", "Library/Application Scripts"] {
            urls.append(home.appendingPathComponent(root).appendingPathComponent(app.bundleID))
        }
        urls.append(home.appendingPathComponent("Library/Cookies/\(app.bundleID).binarycookies"))
        let byHost = home.appendingPathComponent("Library/Preferences/ByHost")
        if let entries = try? FileManager.default.contentsOfDirectory(at: byHost, includingPropertiesForKeys: nil) {
            urls += entries.filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix(app.bundleID + "."), name.hasSuffix(".plist") else { return false }
                return UUID(uuidString: String(name.dropFirst(app.bundleID.count + 1).dropLast(6))) != nil
            }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted && FileIdentity.read($0) != nil && FileIdentity.read($0)?.isSymbolicLink == false }
    }
    public static func review(_ app: ApplicationRecord, home: URL, policy: SafetyPolicy, heartbeat: () -> Void = {}, snapshot: ([FileItem]) -> Void = { _ in }) throws -> [FileItem] {
        guard allowedBundle(app.url, home: home, roots: policy.applicationRoots), !protected(app, policy: policy), record(app.url)?.identity == app.identity else { throw SafetyError("Системное, работающее или изменившееся приложение защищено") }
        var items = [FileItem]()
        func append(_ url: URL) throws {
            if policy.isExcluded(url) { return }
            guard let identity = FileIdentity.read(url), !identity.isSymbolicLink else { return }
            let directory = !identity.isRegular
            let tree = directory ? try DirectoryEvidence.capture(url, policy: policy, heartbeat: heartbeat) : nil
            let date = Date(timeIntervalSince1970: TimeInterval(identity.modifiedSeconds))
            items.append(FileItem(url: url, bytes: tree?.bytes ?? identity.bytes, modified: date, category: .applications, isDirectory: directory, identity: identity,
                            directoryEvidence: tree, applicationEvidence: ApplicationEvidence(bundleURL: app.url, bundleID: app.bundleID, bundleIdentity: app.identity, isBundle: url == app.url)))
            snapshot(items); heartbeat()
        }
        try append(app.url)
        let installed = list(home: home, roots: policy.applicationRoots)
        for url in relatedURLs(app, home: home, installed: installed) { try append(url) }
        return items
    }
}

public enum BackupInventory {
    public static let relativeRoot = "Library/Application Support/MobileSync/Backup"
    public static func isBackup(_ url: URL, home: URL) -> Bool {
        guard ArtifactPaths.relative(url.deletingLastPathComponent(), to: home) == relativeRoot,
              FileIdentity.read(url)?.isSymbolicLink == false else { return false }
        let root = url.lastPathComponent
        guard root.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{15,100}$", options: .regularExpression) != nil else { return false }
        return ["Info.plist", "Manifest.plist", "Status.plist"].allSatisfy { FileIdentity.read(url.appendingPathComponent($0))?.isRegular == true }
    }
    public static func info(_ url: URL, file: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(file)), data.count < 4_000_000 else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
    }
    public static func validate(_ url: URL, home: URL, minimumAgeDays: Int) throws {
        guard isBackup(url, home: home), info(url, file: "Status.plist")["SnapshotState"] as? String == "finished",
              let date = info(url, file: "Info.plist")["Last Backup Date"] as? Date,
              date < Date().addingTimeInterval(-Double(max(7, minimumAgeDays)) * 86400),
              let identity = FileIdentity.read(url), Date(timeIntervalSince1970: TimeInterval(identity.modifiedSeconds)) < Date().addingTimeInterval(-86400) else {
            throw SafetyError("Копия новая, незавершённая или её формат не подтверждён")
        }
    }
    public static func scan(home: URL, policy: SafetyPolicy, minimumAgeDays: Int, heartbeat: () -> Void = {}) throws -> [FileItem] {
        let root = home.appendingPathComponent(relativeRoot)
        let children: [URL]
        do { children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return [] }
        guard FileIdentity.read(root)?.isSymbolicLink == false else { throw SafetyError("Папка резервных копий недоступна или заменена ссылкой") }
        return try children.compactMap { url in
            guard !policy.isExcluded(url), (try? validate(url, home: home, minimumAgeDays: minimumAgeDays)) != nil else { return nil }
            let tree = try DirectoryEvidence.capture(url, policy: policy, heartbeat: heartbeat)
            let title = info(url, file: "Info.plist")["Device Name"] as? String ?? "iPhone / iPad"
            return FileItem(url: url, bytes: tree.bytes, modified: info(url, file: "Info.plist")["Last Backup Date"] as? Date ?? .distantPast,
                            category: .backups, isDirectory: true, directoryEvidence: tree, displayName: title)
        }
    }
}

public enum ReviewedArtifactSafety {
    public static func validate(_ item: FileItem, home: URL, policy: SafetyPolicy, minimumAgeDays: Int, checkTree: Bool = true) throws {
        guard !policy.isExcluded(item.url), let original = item.identity, FileIdentity.read(item.url) == original, !original.isSymbolicLink else { throw SafetyError("Объект изменился или находится в исключениях") }
        var ancestor = item.url.deletingLastPathComponent()
        while ancestor.path != "/" {
            if FileIdentity.read(ancestor)?.isSymbolicLink == true { throw SafetyError("Ссылки в пути папки защищены") }
            if ancestor.standardizedFileURL == home.standardizedFileURL { break }
            ancestor.deleteLastPathComponent()
        }
        if item.category == .applications {
            guard let proof = item.applicationEvidence, ApplicationInventory.allowedBundle(proof.bundleURL, home: home, roots: policy.applicationRoots),
                  let app = ApplicationInventory.record(proof.bundleURL), app.identity == proof.bundleIdentity, app.bundleID == proof.bundleID,
                  !ApplicationInventory.protected(app, policy: policy) else { throw SafetyError("Приложение работает, защищено или изменилось") }
            if proof.isBundle { guard item.url == proof.bundleURL else { throw SafetyError("Путь приложения не совпадает") } }
            else {
                try ApplicationDiscovery.validateAssociation(item, app: app, home: home, policy: policy)
                let used = proof.location?.kind == .manual
                    ? ManualAssociation.usedByRunningApp(item.url, home: home, policy: policy)
                    : policy.belongsToRunningApp(item.url, home: home)
                guard !used else { throw SafetyError("Приложение сейчас работает") }
            }
        } else if item.category == .backups { try BackupInventory.validate(item.url, home: home, minimumAgeDays: minimumAgeDays) }
        else { throw SafetyError("Недопустимая категория") }
        if item.isDirectory && checkTree {
            guard let tree = item.directoryEvidence, try DirectoryEvidence.capture(item.url, policy: policy) == tree else { throw SafetyError("Содержимое папки изменилось после просмотра") }
        } else if !item.isDirectory { guard original.isRegular else { throw SafetyError("Ожидался обычный файл") } }
    }
    public static func allowedRestore(_ entry: HistoryEntry, home: URL) -> Bool {
        if let root = entry.cleanupRoot, let category = entry.category, JunkCatalog.cacheRootSyntax(root, category: category) {
            return (ArtifactPaths.relative(entry.originalURL, to: home) ?? "").hasPrefix(root + "/")
        }
        if let proof = entry.orphanEvidence, entry.category == .leftovers {
            let path = ArtifactPaths.relative(entry.originalURL, to: home) ?? ""
            return proof.ownerIDs.allSatisfy(JunkCatalog.safeOwner) && (path == proof.relativeRoot || path.hasPrefix(proof.relativeRoot + "/"))
                && (proof.relativeRoot.hasPrefix("Library/Containers/") || proof.relativeRoot.hasPrefix("Library/Group Containers/"))
        }
        if entry.category == .applications, let proof = entry.applicationEvidence {
            if proof.isBundle { return entry.originalURL == proof.bundleURL && ApplicationInventory.allowedBundle(entry.originalURL, home: home) }
            if let location = proof.location {
                return ApplicationDiscovery.allowedRestore(entry, location: location, home: home)
            }
            let rel = ArtifactPaths.relative(entry.originalURL, to: home) ?? ""
            let roots = ArtifactPaths.leftoverRoots + ["Library/HTTPStorages", "Library/WebKit", "Library/Application Scripts", "Library/Cookies", "Library/Preferences/ByHost"]
            return roots.contains { rel.hasPrefix($0 + "/") && !rel.dropFirst($0.count + 1).contains("/") }
        }
        if entry.category == .backups { return ArtifactPaths.relative(entry.originalURL.deletingLastPathComponent(), to: home) == BackupInventory.relativeRoot }
        if entry.category == .leftovers {
            let rel = ArtifactPaths.relative(entry.originalURL, to: home) ?? ""
            return ArtifactPaths.leftoverRoots.contains { rel.hasPrefix($0 + "/") }
        }
        return TrashSafety.isAllowed(entry.originalURL, home: home)
    }
}
