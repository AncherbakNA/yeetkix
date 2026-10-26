import Foundation
import Darwin

public struct CacheLocation: Sendable {
    public let relativePath: String
    public let category: FileCategory
    public let owners: [String]
    public let processes: Set<String>
    public init(_ path: String, category: FileCategory = .cache, owners: [String] = [], processes: Set<String> = []) {
        relativePath = path; self.category = category; self.owners = owners; self.processes = processes
    }
}
public struct OrphanEvidence: Codable, Hashable, Sendable {
    public let ownerIDs: [String]
    public let relativeRoot: String
    public let groupID: String?
    public let containsPersonalData: Bool
    public init(ownerIDs: [String], relativeRoot: String, groupID: String? = nil, containsPersonalData: Bool = false) {
        self.ownerIDs = ownerIDs; self.relativeRoot = relativeRoot; self.groupID = groupID; self.containsPersonalData = containsPersonalData
    }
}

private final class CacheLocationCache: @unchecked Sendable {
    static let shared = CacheLocationCache()
    let lock = NSLock()
    var values: [[KnownApplication]: [CacheLocation]] = [:]
}

public enum JunkCatalog {
    public static let toolCaches: [CacheLocation] = [
        CacheLocation(".npm/_cacache", category: .toolCaches, processes: ["node", "npm", "npx", "yarn", "pnpm"]),
        CacheLocation("Library/Caches/pnpm", category: .toolCaches, processes: ["node", "pnpm", "pnpx"]),
        CacheLocation(".cache/pip", category: .toolCaches, processes: ["pip", "pip3", "uv", "python", "python3"]),
        CacheLocation("Library/Caches/pip", category: .toolCaches, processes: ["pip", "pip3", "uv", "python", "python3"]),
        CacheLocation("Library/Caches/Yarn", category: .toolCaches, processes: ["node", "yarn"]),
        CacheLocation("Library/Caches/Homebrew", category: .toolCaches, processes: ["brew", "ruby", "curl"]),
        CacheLocation(".cache/yarn", category: .toolCaches, processes: ["node", "yarn"]),
        CacheLocation(".cargo/registry/cache", category: .toolCaches, processes: ["cargo", "rustc", "rustup"])
    ]
    public static func appCaches(_ applications: [KnownApplication]) -> [CacheLocation] {
        let cache = CacheLocationCache.shared
        cache.lock.lock(); let existing = cache.values[applications]; cache.lock.unlock()
        if let existing { return existing }
        var roots = [String: (FileCategory, Set<String>)]()
        for app in applications where safeOwner(app.bundleID) {
            for id in Set((app.containerIDs ?? []) + [app.bundleID]) where safeOwner(id) {
                for (suffix, category) in [("Caches", FileCategory.cache), ("Logs", .logs)] {
                    let path = "Library/Containers/\(id)/Data/Library/\(suffix)"
                    var owners = roots[path]?.1 ?? []; owners.insert(app.bundleID); roots[path] = (category, owners)
                }
            }
            for id in app.groupIDs ?? [] where ApplicationCapabilities.validID(id) {
                for (suffix, category) in [("Caches", FileCategory.cache), ("Logs", .logs)] {
                    let path = "Library/Group Containers/\(id)/Library/\(suffix)"
                    var owners = roots[path]?.1 ?? []; owners.insert(app.bundleID); roots[path] = (category, owners)
                }
            }
        }
        let result = roots.map { CacheLocation($0.key, category: $0.value.0, owners: $0.value.1.sorted()) }.sorted { $0.relativePath < $1.relativePath }
        cache.lock.lock(); if cache.values.count > 12 { cache.values.removeAll() }; cache.values[applications] = result; cache.lock.unlock()
        return result
    }
    public static func safeOwner(_ id: String) -> Bool {
        ApplicationCapabilities.validID(id) && !id.lowercased().hasPrefix("com.apple.") && id != "local.luma.cleaner" && !id.hasPrefix("app.yeetkix")
    }
    public static func location(_ url: URL, home: URL, applications: [KnownApplication]) -> CacheLocation? {
        guard let relative = ArtifactPaths.relative(url, to: home) else { return nil }
        guard relative.hasPrefix("Library/Containers/") || relative.hasPrefix("Library/Group Containers/") || toolCaches.contains(where: { relative == $0.relativePath || relative.hasPrefix($0.relativePath + "/") }) else { return nil }
        return (toolCaches + appCaches(applications)).first { relative == $0.relativePath || relative.hasPrefix($0.relativePath + "/") }
    }
    public static func activeOwners(_ owners: [String], policy: SafetyPolicy) -> Bool {
        owners.contains { owner in policy.runningApplications.contains { app in
            app.bundleID.caseInsensitiveCompare(owner) == .orderedSame || app.bundleID.lowercased().hasPrefix(owner.lowercased() + ".")
        } }
    }
    public static func processNames() -> [String] {
        let capacity = proc_listallpids(nil, 0); guard capacity > 0 else { return ["__unknown__"] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 256)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return ["__unknown__"] }
        var result = Set<String>()
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var name = [CChar](repeating: 0, count: 1024)
            if proc_name(pid, &name, UInt32(name.count)) > 0 { result.insert(String(cString: name).lowercased()) }
        }
        return result.sorted()
    }
    public static func validateCache(_ item: FileItem, home: URL, policy: SafetyPolicy) throws {
        guard let location = location(item.url, home: home, applications: policy.knownApplications), location.category == item.category, item.cleanupRoot == location.relativePath,
              let relative = ArtifactPaths.relative(item.url, to: home), relative.hasPrefix(location.relativePath + "/") else { throw SafetyError("Не подтверждён каталог кэша") }
        if activeOwners(location.owners, policy: policy) { throw SafetyError("Приложение, использующее этот кэш, сейчас работает") }
        let processes = Set(policy.activeProcesses ?? ["__unknown__"])
        if !location.processes.isEmpty && (processes.contains("__unknown__") || !location.processes.isDisjoint(with: processes)) { throw SafetyError("Этот кэш используется работающим инструментом разработки") }
    }
    public static func cacheRootSyntax(_ root: String, category: FileCategory) -> Bool {
        if category == .toolCaches { return toolCaches.contains { $0.relativePath == root } }
        let parts = root.split(separator: "/").map(String.init)
        let tail = category == .cache ? "Caches" : category == .logs ? "Logs" : ""
        guard !tail.isEmpty, parts.count >= 5, parts[0] == "Library", ApplicationCapabilities.validID(parts[2]), parts.last == tail else { return false }
        return (parts[1] == "Containers" && parts.count == 6 && parts[3] == "Data" && parts[4] == "Library")
            || (parts[1] == "Group Containers" && parts.count == 5 && parts[3] == "Library")
    }
    public static let orphanContainerChildren = ["Documents", "Library/Application Support", "Library/Caches", "Library/Logs", "Library/Preferences", "Library/Saved Application State", "Library/WebKit", "Library/HTTPStorages", "Library/Application Scripts"]
    public static func orphanProof(_ url: URL, home: URL, policy: SafetyPolicy) -> OrphanEvidence? {
        guard let relative = ArtifactPaths.relative(url, to: home) else { return nil }
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "Library", safeOwner(parts[2]) else { return nil }
        if parts[1] == "Containers" {
            guard parts[3] == "Data", parts.count >= 5 else { return nil }
            let id = parts[2]
            let owners = Set(policy.knownApplications.filter { ($0.containerIDs ?? []).contains(id) || $0.bundleID == id }.map(\.bundleID))
            let ownerIDs = owners.isEmpty ? [id] : owners.sorted()
            guard ownerIDs.allSatisfy(safeOwner), let child = orphanContainerChildren.first(where: { relative == "Library/Containers/\(id)/Data/" + $0 || relative.hasPrefix("Library/Containers/\(id)/Data/" + $0 + "/") }) else { return nil }
            return OrphanEvidence(ownerIDs: ownerIDs, relativeRoot: "Library/Containers/\(id)/Data/" + child,
                                  containsPersonalData: child == "Documents" || child == "Library/Application Support")
        }
        if parts[1] == "Group Containers" {
            let group = parts[2]
            let owners = Set(policy.knownApplications.filter { ($0.groupIDs ?? []).contains(group) }.map(\.bundleID))
            guard !owners.isEmpty, owners.allSatisfy(safeOwner), !parts[3].hasPrefix(".com.apple.containermanagerd"), parts[3] != ".DS_Store" else { return nil }
            return OrphanEvidence(ownerIDs: owners.sorted(), relativeRoot: "Library/Group Containers/\(group)/\(parts[3])", groupID: group, containsPersonalData: true)
        }
        return nil
    }
    public static func validateOrphan(_ item: FileItem, home: URL, policy: SafetyPolicy, snapshot: ApplicationSnapshot? = nil, checkTree: Bool = true) throws {
        guard let proof = item.orphanEvidence, orphanProof(item.url, home: home, policy: policy) == proof,
              !policy.isExcluded(item.url), FileIdentity.read(item.url) == item.identity else { throw SafetyError("Принадлежность или содержимое остатков изменилось") }
        let catalog = snapshot ?? ApplicationCatalog.snapshot(home: home, roots: policy.applicationRoots)
        guard catalog.complete, proof.ownerIDs.allSatisfy({ !ApplicationCatalog.isInstalled($0, snapshot: catalog, checkRegistry: policy.checkRegisteredApplications) }),
              !activeOwners(proof.ownerIDs, policy: policy) else { throw SafetyError("Владелец данных установлен или работает") }
        if let group = proof.groupID {
            let installed = ApplicationInventory.list(home: home, roots: policy.applicationRoots)
            guard !installed.contains(where: { ApplicationCapabilities.groups($0).contains(group) }) else { throw SafetyError("Общий контейнер используется установленным приложением") }
        }
        var ancestor = item.url
        while ancestor.standardizedFileURL.path != home.standardizedFileURL.path && ancestor.path != "/" {
            guard FileIdentity.read(ancestor)?.isSymbolicLink != true else { throw SafetyError("Ссылки в пути остатков защищены") }
            ancestor.deleteLastPathComponent()
        }
        if item.isDirectory && checkTree {
            guard let tree = item.directoryEvidence, try DirectoryEvidence.capture(item.url, policy: policy) == tree else { throw SafetyError("Папка остатков изменилась после сканирования") }
        } else if !item.isDirectory { guard item.identity?.isRegular == true else { throw SafetyError("Специальный объект защищён") } }
    }
}

public enum OrphanContainerScanner {
    public static func scan(_ request: WorkerRequest, snapshot: @escaping @Sendable (ScanReport) -> Void = { _ in }, progress: (Double, String, Int) -> Void) throws -> ScanReport {
        var report = ScanReport(); report.scope = request.scope; report.ageDays = request.ageDays
        let catalog = ApplicationCatalog.snapshot(home: request.home, roots: request.policy.applicationRoots)
        let installedGroups = Set(ApplicationInventory.list(home: request.home, roots: request.policy.applicationRoots).flatMap { ApplicationCapabilities.groups($0) })
        let fm = FileManager.default
        for root in request.roots {
            var status: RootStatus = .complete; var detail: String?
            defer { report.roots.append(RootResult(root: root, status: status, detail: detail)); var partial = report; partial.isPartial = true; snapshot(partial) }
            guard ["Library/Containers", "Library/Group Containers"].contains(root.relativePath),
                  root.url.standardizedFileURL.path == request.home.appendingPathComponent(root.relativePath).standardizedFileURL.path,
                  root.url.resolvingSymlinksInPath().path == request.home.resolvingSymlinksInPath().appendingPathComponent(root.relativePath).path,
                  catalog.complete else { status = .denied; report.inaccessible.append(root.relativePath); continue }
            if request.policy.isExcluded(root.url) { status = .protected; detail = "Папка в исключениях"; report.protectedCount += 1; continue }
            func inspect(_ url: URL, depth: Int = 0) throws {
                try Task.checkCancellation(); report.visitedCount += 1
                guard report.visitedCount <= request.entryLimit else { report.truncated = true; status = .limited; return }
                guard let proof = JunkCatalog.orphanProof(url, home: request.home, policy: request.policy),
                      proof.ownerIDs.allSatisfy({ !ApplicationCatalog.isInstalled($0, snapshot: catalog, checkRegistry: request.policy.checkRegisteredApplications) }),
                      !JunkCatalog.activeOwners(proof.ownerIDs, policy: request.policy), !request.policy.isExcluded(url),
                      let identity = FileIdentity.read(url), !identity.isSymbolicLink else { report.protectedCount += 1; return }
                if let group = proof.groupID, installedGroups.contains(group) { report.protectedCount += 1; return }
                guard identity.isRegular || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { report.protectedCount += 1; return }
                if !identity.isRegular && report.visitedCount >= request.entryLimit { report.truncated = true; status = .limited; return }
                progress(0, root.title, report.visitedCount)
                do {
                    let tree = identity.isRegular ? nil : try DirectoryEvidence.capture(url, policy: request.policy, limit: max(1, request.entryLimit - report.visitedCount), heartbeat: { progress(0, root.title, report.visitedCount) })
                    report.visitedCount += tree?.entries ?? 0
                    report.items.append(FileItem(url: url, bytes: tree?.bytes ?? identity.bytes, modified: Date(timeIntervalSince1970: TimeInterval(identity.modifiedSeconds)), category: .leftovers,
                                                isDirectory: !identity.isRegular, identity: identity, leftoverBundleID: proof.ownerIDs.joined(separator: ", "), directoryEvidence: tree, orphanEvidence: proof))
                    var partial = report; partial.isPartial = true; snapshot(partial)
                } catch {
                    // A lock, socket, exclusion or unreadable child must not hide siblings.
                    if !identity.isRegular && depth < 5, let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil), !children.isEmpty {
                        for child in children where !report.truncated { try inspect(child, depth: depth + 1) }
                    } else { status = .denied; detail = "Часть данных сохранена: " + error.localizedDescription; report.inaccessible.append(url.path) }
                }
            }
            var seenOwners = Set<String>()
            func inspectOwner(_ owner: URL) throws {
                guard seenOwners.insert(owner.standardizedFileURL.path).inserted, FileIdentity.read(owner)?.isSymbolicLink == false else { return }
                if root.relativePath == "Library/Containers" {
                    let id = owner.lastPathComponent
                    guard JunkCatalog.safeOwner(id), !ApplicationCatalog.isInstalled(id, snapshot: catalog, checkRegistry: request.policy.checkRegisteredApplications) else { report.protectedCount += 1; return }
                    for child in JunkCatalog.orphanContainerChildren where !report.truncated {
                        let url = owner.appendingPathComponent("Data/" + child)
                        if FileIdentity.read(url) != nil { try inspect(url) }
                    }
                } else {
                    guard request.policy.knownApplications.contains(where: { ($0.groupIDs ?? []).contains(owner.lastPathComponent) }) else { report.protectedCount += 1; return }
                    do { for child in try fm.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil) where !report.truncated { try inspect(child) } }
                    catch { status = .denied; detail = error.localizedDescription; report.inaccessible.append(owner.path) }
                }
            }
            // Known locations can be readable even when macOS blocks listing the parent.
            let ids = Set(request.policy.knownApplications.flatMap { app in
                root.relativePath == "Library/Containers" ? [app.bundleID] + (app.containerIDs ?? []) : (app.groupIDs ?? [])
            }.filter(ApplicationCapabilities.validID))
            for id in ids.sorted() where !report.truncated { try inspectOwner(root.url.appendingPathComponent(id)) }
            do {
                let owners = try fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil)
                for (index, owner) in owners.enumerated() where !report.truncated {
                    progress(Double(index) / Double(max(1, owners.count)), root.title, report.visitedCount)
                    try inspectOwner(owner)
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { status = .missing }
            catch { status = .denied; detail = error.localizedDescription; report.inaccessible.append(root.relativePath) }
        }
        return report
    }
}
