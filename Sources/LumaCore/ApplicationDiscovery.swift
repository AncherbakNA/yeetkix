import Foundation
import Security
import CryptoKit
import Darwin

public enum ApplicationLocationKind: String, Codable, Sendable { case standard, container, groupContainer, virtualMachine, manual }
public struct ApplicationLocationEvidence: Codable, Hashable, Sendable {
    public let kind: ApplicationLocationKind
    public let root: URL
    public let ownerID: String
    public let sensitive: Bool
    public var registryURL: URL?
    public var registryIdentity: FileIdentity?
    public var registryDigest: String?
    public init(kind: ApplicationLocationKind, root: URL, ownerID: String, sensitive: Bool = false) {
        self.kind = kind; self.root = root; self.ownerID = ownerID; self.sensitive = sensitive
    }
}
public enum ApplicationSourceKind: String, Codable, Sendable { case standard, container, groupContainer, utmRegistry, utmFolder, utmSpotlight, utmPackage, manual }
public struct ApplicationReviewSource: Codable, Identifiable, Sendable {
    public let kind: ApplicationSourceKind
    public let url: URL
    public let ownerID: String
    public var location: ApplicationLocationEvidence?
    public var id: String { kind.rawValue + ":" + url.path }
    public var title: String {
        switch kind {
        case .standard: return "Приложение и обычные данные Library"
        case .container: return "Данные контейнера"
        case .groupContainer: return "Данные общего контейнера"
        case .utmRegistry: return "Список виртуальных машин UTM"
        case .utmFolder: return "Папка виртуальных машин"
        case .utmSpotlight: return "Поиск .utm через Spotlight"
        case .utmPackage: return "Виртуальная машина"
        case .manual: return "Данные, добавленные вручную"
        }
    }
    public init(kind: ApplicationSourceKind, url: URL, ownerID: String, location: ApplicationLocationEvidence? = nil) {
        self.kind = kind; self.url = url; self.ownerID = ownerID; self.location = location
    }
}
public struct ApplicationSourceResult: Codable, Identifiable, Sendable {
    public let source: ApplicationReviewSource
    public let status: RootStatus
    public let detail: String?
    public var id: String { source.id }
    public init(source: ApplicationReviewSource, status: RootStatus, detail: String? = nil) { self.source = source; self.status = status; self.detail = detail }
}
public struct ApplicationDiscoveryResult: Sendable {
    public var items: [FileItem] = []
    public var sources: [ApplicationReviewSource] = []
    public var notes: [String] = []
    public var status: RootStatus = .complete
    public init() {}
}

public enum ApplicationCapabilities {
    public static func virtualMachinesBusy() -> Bool {
        let count = proc_listallpids(nil, 0); guard count > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(count) + 256)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { return true }
        for pid in pids.prefix(Int(actual)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 1024)
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
                let name = String(cString: buffer).lowercased()
                if name == "qemulauncher" || name.hasPrefix("qemu-system-") || name == "utm" || name == "utm se" { return true }
            }
        }
        return false
    }
    public static func entitlements(_ url: URL) -> [String: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return [:] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return [:] }
        return dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    }
    public static func identifiers(_ app: ApplicationRecord) -> [String] {
        var ids = [app.bundleID]
        let plugins = app.url.appendingPathComponent("Contents/PlugIns")
        let children = (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
        for child in children where child.pathExtension == "appex" && FileIdentity.read(child)?.isSymbolicLink == false {
            guard let data = try? Data(contentsOf: child.appendingPathComponent("Contents/Info.plist")), data.count < 2_000_000,
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let id = info["CFBundleIdentifier"] as? String, id.hasPrefix(app.bundleID + "."), validID(id) else { continue }
            ids.append(id)
        }
        return Array(Set(ids)).sorted()
    }
    public static func groups(_ app: ApplicationRecord) -> [String] {
        var declared = entitlements(app.url)["com.apple.security.application-groups"] as? [String] ?? []
        let children = (try? FileManager.default.contentsOfDirectory(at: app.url.appendingPathComponent("Contents/PlugIns"), includingPropertiesForKeys: nil)) ?? []
        let ids = identifiers(app)
        for child in children where child.pathExtension == "appex" && FileIdentity.read(child)?.isSymbolicLink == false {
            guard let data = try? Data(contentsOf: child.appendingPathComponent("Contents/Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let id = info["CFBundleIdentifier"] as? String, ids.contains(id) else { continue }
            declared += entitlements(child)["com.apple.security.application-groups"] as? [String] ?? []
        }
        return Array(Set(declared.filter(validID))).sorted()
    }
    public static func validID(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{2,250}$", options: .regularExpression) != nil }
}

public enum ApplicationDiscovery {
    public static func allowedRestore(_ entry: HistoryEntry, location: ApplicationLocationEvidence, home: URL) -> Bool {
        guard let app = entry.applicationEvidence else { return false }
        switch location.kind {
        case .virtualMachine:
            return ["com.utmapp.UTM", "com.utmapp.UTM-SE"].contains(app.bundleID) && entry.directoryEvidence != nil && validVMPath(entry.originalURL, home: home) && within(entry.originalURL, location.root)
        case .container:
            let root = home.appendingPathComponent("Library/Containers/\(location.ownerID)/Data")
            return ApplicationCapabilities.validID(location.ownerID) && (location.ownerID == app.bundleID || location.ownerID.hasPrefix(app.bundleID + ".")) && within(entry.originalURL, root) && entry.originalURL.standardizedFileURL.path != root.standardizedFileURL.path
        case .groupContainer:
            let root = home.appendingPathComponent("Library/Group Containers/\(location.ownerID)")
            return ApplicationCapabilities.validID(location.ownerID) && within(entry.originalURL, root)
        case .standard: return false
        case .manual: return ManualAssociation.allowed(entry.originalURL, home: home) && entry.originalURL.standardizedFileURL.path == location.root.standardizedFileURL.path && location.ownerID == app.bundleID
        }
    }
    public static func isUTM(_ app: ApplicationRecord) -> Bool { ["com.utmapp.UTM", "com.utmapp.UTM-SE"].contains(app.bundleID) }
    public static func within(_ url: URL, _ root: URL) -> Bool {
        let path = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }
    public static func plan(_ app: ApplicationRecord, home: URL, manualAssociations: [ManualAssociation] = []) -> [ApplicationReviewSource] {
        var sources = [ApplicationReviewSource(kind: .standard, url: app.url, ownerID: app.bundleID)]
        if isUTM(app) {
            sources.append(ApplicationReviewSource(kind: .utmSpotlight, url: home, ownerID: app.bundleID))
            sources.append(ApplicationReviewSource(kind: .utmRegistry, url: home.appendingPathComponent("Library/Preferences/\(app.bundleID).plist"), ownerID: app.bundleID))
            sources.append(ApplicationReviewSource(kind: .utmFolder, url: home.appendingPathComponent("Documents"), ownerID: app.bundleID))
        }
        for id in ApplicationCapabilities.identifiers(app) where ApplicationCapabilities.validID(id) {
            let data = home.appendingPathComponent("Library/Containers/\(id)/Data")
            sources.append(ApplicationReviewSource(kind: .container, url: data, ownerID: id))
            if isUTM(app) {
                sources.append(ApplicationReviewSource(kind: .utmRegistry, url: data.appendingPathComponent("Library/Preferences/\(id).plist"), ownerID: id))
            }
        }
        for group in ApplicationCapabilities.groups(app) {
            sources.append(ApplicationReviewSource(kind: .groupContainer, url: home.appendingPathComponent("Library/Group Containers/\(group)"), ownerID: group))
        }
        sources += manualAssociations.filter { $0.bundleID == app.bundleID && ManualAssociation.allowed($0.url, home: home) }.map {
            ApplicationReviewSource(kind: .manual, url: $0.url, ownerID: app.bundleID,
                                    location: ApplicationLocationEvidence(kind: .manual, root: $0.url, ownerID: app.bundleID, sensitive: true))
        }
        return sources
    }
    public static func sharedGroup(_ id: String, app: ApplicationRecord, installed: [ApplicationRecord]) -> Bool {
        installed.contains { $0.bundleID != app.bundleID && ApplicationCapabilities.groups($0).contains(id) }
    }
    public static func vmConfig(_ url: URL) throws -> [String: Any] {
        guard url.pathExtension.lowercased() == "utm", FileIdentity.read(url)?.isSymbolicLink == false,
              let identity = FileIdentity.read(url.appendingPathComponent("config.plist")), identity.isRegular, !identity.isSymbolicLink,
              identity.bytes > 0, identity.bytes < 8_000_000 else { throw SafetyError("Пакет не содержит подтверждённую конфигурацию UTM") }
        let cloud = try url.appendingPathComponent("config.plist").resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard cloud.isUbiquitousItem != true || cloud.ubiquitousItemDownloadingStatus == .current else { throw SafetyError("Конфигурация VM не загружена из iCloud; загрузка автоматически не выполняется") }
        let raw = try Data(contentsOf: url.appendingPathComponent("config.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any],
              ["QEMU", "Apple"].contains(info["Backend"] as? String ?? "") || info["System"] is [String: Any] else { throw SafetyError("Формат виртуальной машины UTM не распознан") }
        return info
    }
    public static func validVMPath(_ url: URL, home: URL) -> Bool {
        guard url.pathExtension.lowercased() == "utm", url.isFileURL, !url.pathComponents.contains(".Trash"), !url.pathComponents.contains(".Trashes") else { return false }
        if within(url, home) { return true }
        return url.path.hasPrefix("/Volumes/") && url.pathComponents.count >= 4
    }
    /// Extract only VM package references. Shared host folders, attached ISOs and
    /// ExternalDrives are deliberately not treated as owned by UTM.
    public static func registryPackages(_ plist: [String: Any], defaultRoot: URL) -> [URL] {
        func package(_ entry: [String: Any]) -> URL? {
            if let bookmark = entry["Bookmark"] as? Data {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale), url.isFileURL, url.pathExtension.lowercased() == "utm" { url.stopAccessingSecurityScopedResource(); return url }
            }
            if let path = entry["Path"] as? String, path.hasPrefix("/") {
                let url = URL(fileURLWithPath: path); return url.pathExtension.lowercased() == "utm" ? url : nil
            }
            return nil
        }
        var urls = [URL]()
        if let entries = plist["Registry"] as? [String: [String: Any]] {
            for entry in entries.values { if let reference = entry["Package"] as? [String: Any], let url = package(reference) { urls.append(url) } }
        }
        if let legacy = plist["VMList"] as? [Any] {
            for entry in legacy {
                if let dict = entry as? [String: Any], let url = package(dict) { urls.append(url) }
                else if let bookmark = entry as? Data, let url = package(["Bookmark": bookmark]) { urls.append(url) }
                else if let name = entry as? String, !name.contains("/"), name.lowercased().hasSuffix(".utm") { urls.append(defaultRoot.appendingPathComponent(name)) }
            }
        }
        return Array(Dictionary(grouping: urls, by: { $0.standardizedFileURL.path }).values.compactMap(\.first)).sorted { $0.path < $1.path }
    }
    static func registry(_ url: URL) throws -> (FileIdentity, String, [String: Any]) {
        guard let before = FileIdentity.read(url), before.isRegular, !before.isSymbolicLink, before.bytes < 16_000_000 else { throw SafetyError("Список UTM недоступен или имеет неизвестный размер") }
        let data = try Data(contentsOf: url)
        guard FileIdentity.read(url) == before, let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw SafetyError("Список UTM изменился или имеет неизвестный формат") }
        return (before, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), plist)
    }
    public static func registryOwns(_ url: URL, proof: ApplicationLocationEvidence, home: URL, app: ApplicationRecord) throws -> Bool {
        guard let registryURL = proof.registryURL,
              plan(app, home: home).contains(where: { $0.kind == .utmRegistry && $0.url.standardizedFileURL.path == registryURL.standardizedFileURL.path }) else { return false }
        let (identity, digest, plist) = try registry(registryURL)
        guard identity == proof.registryIdentity, digest == proof.registryDigest else { return false }
        let defaultRoot = home.appendingPathComponent("Library/Containers/\(app.bundleID)/Data/Documents")
        return registryPackages(plist, defaultRoot: defaultRoot).contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }
    public static func validateAssociation(_ item: FileItem, app: ApplicationRecord, home: URL, policy: SafetyPolicy) throws {
        guard let proof = item.applicationEvidence?.location else {
            guard ApplicationInventory.relatedURLs(app, home: home, installed: ApplicationInventory.list(home: home, roots: policy.applicationRoots)).contains(item.url) else { throw SafetyError("Связь с приложением не подтверждена") }; return
        }
        switch proof.kind {
        case .standard:
            guard ApplicationInventory.relatedURLs(app, home: home, installed: ApplicationInventory.list(home: home, roots: policy.applicationRoots)).contains(item.url) else { throw SafetyError("Связь с приложением не подтверждена") }
        case .container:
            let root = home.appendingPathComponent("Library/Containers/\(proof.ownerID)/Data")
            let allowed = ["Documents", "Library/Application Support", "Library/Caches", "Library/Logs", "Library/Preferences", "Library/Saved Application State", "Library/WebKit", "Library/HTTPStorages", "Library/Application Scripts"]
            guard ApplicationCapabilities.validID(proof.ownerID), ApplicationCapabilities.identifiers(app).contains(proof.ownerID), allowed.contains(where: { within(item.url, root.appendingPathComponent($0)) }), within(item.url, root) else { throw SafetyError("Контейнер не принадлежит приложению") }
        case .groupContainer:
            let root = home.appendingPathComponent("Library/Group Containers/\(proof.ownerID)")
            guard ApplicationCapabilities.groups(app).contains(proof.ownerID), within(item.url, root),
                  !sharedGroup(proof.ownerID, app: app, installed: ApplicationInventory.list(home: home, roots: policy.applicationRoots)) else { throw SafetyError("Контейнер используется другим установленным приложением") }
        case .virtualMachine:
            guard isUTM(app), validVMPath(item.url, home: home), within(item.url, proof.root) else { throw SafetyError("Путь виртуальной машины не подтверждён") }
            _ = try vmConfig(item.url)
            if proof.registryURL != nil, try !registryOwns(item.url, proof: proof, home: home, app: app) { throw SafetyError("UTM изменил список виртуальных машин после просмотра") }
        case .manual:
            guard proof.ownerID == app.bundleID, proof.root.standardizedFileURL.path == item.url.standardizedFileURL.path,
                  ManualAssociation.authorized(item.url, appID: app.bundleID, home: home, policy: policy) else { throw SafetyError("Данные не были добавлены пользователем или заменены") }
        }
    }
    static func item(_ url: URL, app: ApplicationRecord, proof: ApplicationLocationEvidence, policy: SafetyPolicy, heartbeat: () -> Void) throws -> FileItem? {
        guard !policy.isExcluded(url), let identity = FileIdentity.read(url), !identity.isSymbolicLink else { return nil }
        let directory = !identity.isRegular
        let tree = directory ? try DirectoryEvidence.capture(url, policy: policy, heartbeat: heartbeat) : nil
        return FileItem(url: url, bytes: tree?.bytes ?? identity.bytes, modified: Date(timeIntervalSince1970: TimeInterval(identity.modifiedSeconds)), category: .applications,
                        isDirectory: directory, identity: identity, directoryEvidence: tree,
                        applicationEvidence: ApplicationEvidence(bundleURL: app.url, bundleID: app.bundleID, bundleIdentity: app.identity, isBundle: false, location: proof))
    }
    public static func scan(_ source: ApplicationReviewSource, app: ApplicationRecord, home: URL, policy: SafetyPolicy,
                            heartbeat: () -> Void = {}, snapshot: ([FileItem]) -> Void = { _ in }) throws -> ApplicationDiscoveryResult {
        guard ApplicationInventory.allowedBundle(app.url, home: home, roots: policy.applicationRoots), ApplicationInventory.record(app.url)?.identity == app.identity,
              !ApplicationInventory.protected(app, policy: policy) else { throw SafetyError("Приложение работает, изменилось или защищено") }
        var result = ApplicationDiscoveryResult()
        func append(_ url: URL, proof: ApplicationLocationEvidence) {
            do {
                if let item = try item(url, app: app, proof: proof, policy: policy, heartbeat: heartbeat) { result.items.append(item); snapshot(result.items) }
            } catch { result.notes.append("\(url.path): \(error.localizedDescription)"); result.status = .denied }
            heartbeat()
        }
        if source.kind == .standard {
            // Publish the app first, so an unavailable related location cannot hide it.
            let base = try ApplicationInventory.review(app, home: home, policy: policy, heartbeat: heartbeat, snapshot: snapshot)
            result.items = base; return result
        }
        if source.kind == .manual {
            guard ManualAssociation.authorized(source.url, appID: app.bundleID, home: home, policy: policy) else { throw SafetyError("Нет сохранённого выбора этих данных") }
            append(source.url, proof: ApplicationLocationEvidence(kind: .manual, root: source.url, ownerID: app.bundleID, sensitive: true))
            result.notes.append("Данные добавлены вручную. Они могут быть личными документами и не считаются мусором автоматически.")
            return result
        }
        if source.kind == .utmSpotlight {
            guard isUTM(app), source.url.standardizedFileURL.path == home.standardizedFileURL.path else { throw SafetyError("Неизвестная область поиска") }
            let output = try LocalCommand.run(URL(fileURLWithPath: "/usr/bin/mdfind"), ["-0", "-onlyin", home.path, "kMDItemFSName == '*.utm'cd"], timeout: 6)
            guard output.status == 0 else { throw SafetyError("Spotlight не смог проверить индекс") }
            for path in output.text.split(separator: "\0").prefix(2000) {
                let url = URL(fileURLWithPath: String(path))
                guard validVMPath(url, home: home), within(url, home), url.lastPathComponent != app.bundleID,
                      !url.path.contains("/Library/Application Scripts/"), !ApplicationCapabilities.groups(app).contains(url.lastPathComponent) else { continue }
                result.sources.append(ApplicationReviewSource(kind: .utmPackage, url: url, ownerID: app.bundleID,
                    location: ApplicationLocationEvidence(kind: .virtualMachine, root: url.deletingLastPathComponent(), ownerID: app.bundleID, sensitive: true)))
            }
            result.notes.append("Spotlight видит только проиндексированные файлы. Для других папок и дисков используйте «Проверить папку с .utm».")
            return result
        }
        if source.kind == .utmRegistry {
            guard isUTM(app), plan(app, home: home).contains(where: { $0.id == source.id }) else { throw SafetyError("Неизвестный список виртуальных машин") }
            do { _ = try FileManager.default.attributesOfItem(atPath: source.url.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { result.status = .missing; return result }
            let (identity, digest, plist) = try registry(source.url)
            let root = home.appendingPathComponent("Library/Containers/\(app.bundleID)/Data/Documents")
            for url in registryPackages(plist, defaultRoot: root) where validVMPath(url, home: home) {
                var proof = ApplicationLocationEvidence(kind: .virtualMachine, root: url.deletingLastPathComponent(), ownerID: app.bundleID, sensitive: true)
                proof.registryURL = source.url; proof.registryIdentity = identity; proof.registryDigest = digest
                result.sources.append(ApplicationReviewSource(kind: .utmPackage, url: url, ownerID: app.bundleID, location: proof))
            }
            result.notes.append("Общие папки Mac, внешние ISO и подключённые диски из списка UTM не считаются частью .utm и не выбираются для удаления.")
            return result
        }
        if source.kind == .utmPackage {
            guard isUTM(app), let proof = source.location, validVMPath(source.url, home: home) else { throw SafetyError("Неизвестный пакет UTM") }
            do { _ = try FileManager.default.attributesOfItem(atPath: source.url.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { result.status = .missing; return result }
            _ = try vmConfig(source.url); append(source.url, proof: proof); return result
        }
        if source.kind == .utmFolder {
            guard isUTM(app), validSearchRoot(source.url, home: home) else { throw SafetyError("Эта область не разрешена для поиска виртуальных машин") }
            do { try vmFolder(source.url, app: app, home: home, policy: policy, heartbeat: heartbeat) { url in
                let proof = ApplicationLocationEvidence(kind: .virtualMachine, root: source.url, ownerID: app.bundleID, sensitive: true)
                append(url, proof: proof)
            } } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { result.status = .missing }
            return result
        }
        guard plan(app, home: home).contains(where: { $0.id == source.id }) else { throw SafetyError("Неизвестный контейнер") }
        if source.kind == .groupContainer, sharedGroup(source.ownerID, app: app, installed: ApplicationInventory.list(home: home, roots: policy.applicationRoots)) {
            result.notes.append("Общий контейнер сохранён: им пользуется другое установленное приложение."); return result
        }
        do { _ = try FileManager.default.contentsOfDirectory(at: source.url, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { result.status = .missing; return result }
        guard FileIdentity.read(source.url)?.isSymbolicLink == false else { throw SafetyError("Контейнер заменён ссылкой") }
        let children = ["Documents", "Library/Application Support", "Library/Caches", "Library/Logs", "Library/Preferences", "Library/Saved Application State", "Library/WebKit", "Library/HTTPStorages", "Library/Application Scripts"]
        if source.kind == .groupContainer {
            let proof = ApplicationLocationEvidence(kind: .groupContainer, root: source.url, ownerID: source.ownerID, sensitive: true)
            // Container-manager metadata and live IPC sockets are not app data.
            // Inspect children separately so a socket cannot hide the other data.
            let entries = try FileManager.default.contentsOfDirectory(at: source.url, includingPropertiesForKeys: [.isDirectoryKey])
            for child in entries.sorted(by: { $0.path < $1.path }) {
                guard ![".com.apple.containermanagerd.metadata.plist", ".com.apple.containermanagerd.metadata", ".DS_Store"].contains(child.lastPathComponent),
                      let identity = FileIdentity.read(child), !identity.isSymbolicLink else { continue }
                if !identity.isRegular && (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                    result.notes.append("Служебный сокет или специальный объект сохранён: \(child.path)"); continue
                }
                append(child, proof: proof)
            }
        } else {
            for relative in children {
                heartbeat(); let url = source.url.appendingPathComponent(relative)
                if relative == "Documents" && isUTM(app) {
                    do { try vmFolder(url, app: app, home: home, policy: policy, heartbeat: heartbeat) { vm in
                        append(vm, proof: ApplicationLocationEvidence(kind: .virtualMachine, root: url, ownerID: app.bundleID, sensitive: true))
                    } } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { }
                    continue
                }
                append(url, proof: ApplicationLocationEvidence(kind: .container, root: source.url, ownerID: source.ownerID, sensitive: relative == "Documents" || relative == "Library/Application Support"))
            }
        }
        return result
    }
    public static func validSearchRoot(_ url: URL, home: URL) -> Bool {
        within(url, home) || (url.path.hasPrefix("/Volumes/") && url.pathComponents.count >= 3)
    }
    static func vmFolder(_ root: URL, app: ApplicationRecord, home: URL, policy: SafetyPolicy, heartbeat: () -> Void, found: (URL) -> Void) throws {
        _ = try FileManager.default.attributesOfItem(atPath: root.path)
        guard FileIdentity.read(root)?.isSymbolicLink == false else { throw SafetyError("Папка виртуальных машин заменена ссылкой") }
        _ = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var problem: Error?; var count = 0; var pulse = Date.distantPast
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles], errorHandler: { _, error in problem = error; return true }) else { throw SafetyError("Папка виртуальных машин недоступна") }
        for case let url as URL in walk {
            try Task.checkCancellation(); count += 1
            guard count <= 200_000 else { throw SafetyError("Поиск .utm ограничен 200 000 объектами. Выберите более точную папку.") }
            if Date().timeIntervalSince(pulse) > 0.35 { heartbeat(); pulse = Date() }
            if policy.isExcluded(url) || FileIdentity.read(url)?.isSymbolicLink != false { DirectoryTraversal.skipDirectory(url, in: walk); continue }
            if url.pathExtension.lowercased() == "utm" { DirectoryTraversal.skipDirectory(url, in: walk); if (try? vmConfig(url)) != nil { found(url) }; continue }
            if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { DirectoryTraversal.skipDirectory(url, in: walk) }
        }
        if let problem { throw problem }
    }
}
