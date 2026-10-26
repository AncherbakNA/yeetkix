import Foundation
import CoreServices
import Darwin

public enum ArtifactPaths {
    public static let personal = ["Downloads", "Desktop", "Documents", "Movies", "Pictures", "Music"]
    public static let leftoverRoots = ["Library/Caches", "Library/Logs", "Library/Preferences/ByHost", "Library/Preferences", "Library/Application Support", "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Cookies", "Library/Application Scripts"]
    public static let developerRoots = ["Library/Developer/Xcode/DerivedData", "Library/Caches/com.apple.dt.Xcode", "Library/Developer/Xcode/iOS DeviceSupport"]
    public static func relative(_ url: URL, to home: URL) -> String? {
        let prefix = home.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
    public static func leftoverID(_ url: URL, home: URL, knownApplications: [KnownApplication] = []) -> String? {
        guard let relative = relative(url, to: home) else { return nil }
        for root in leftoverRoots where relative.hasPrefix(root + "/") {
            let suffix = String(relative.dropFirst(root.count + 1))
            guard var owner = suffix.split(separator: "/").first.map(String.init) else { return nil }
            if root == "Library/Preferences", owner.hasSuffix(".plist") { owner.removeLast(6) }
            if root == "Library/Preferences/ByHost", owner.hasSuffix(".plist") {
                owner.removeLast(6)
                if let dot = owner.lastIndex(of: "."), UUID(uuidString: String(owner[owner.index(after: dot)...])) != nil { owner = String(owner[..<dot]) }
                else { return nil }
            }
            if root == "Library/Cookies", owner.hasSuffix(".binarycookies") { owner.removeLast(14) }
            if root == "Library/Saved Application State", owner.hasSuffix(".savedState") { owner.removeLast(11) }
            if owner.range(of: #"^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$"#, options: .regularExpression) == nil {
                let matches = Set(knownApplications.filter { app in app.names.contains { $0.caseInsensitiveCompare(owner) == .orderedSame } }.map(\.bundleID))
                guard matches.count == 1, let match = matches.first, !match.lowercased().hasPrefix("com.apple."), match != "local.luma.cleaner" else { return nil }
                return match
            }
            guard
                  !owner.lowercased().hasPrefix("com.apple."), !owner.lowercased().hasPrefix("local.luma.cleaner"),
                  !owner.lowercased().hasPrefix("app.yeetkix") else { return nil }
            return owner
        }
        return nil
    }
    public static func developerAllowed(_ url: URL, home: URL, directory: Bool = false) -> Bool {
        guard let relative = relative(url, to: home) else { return false }
        for root in developerRoots.dropFirst() where relative.hasPrefix(root + "/") { return true }
        let root = developerRoots[0]
        guard relative.hasPrefix(root + "/") else { return directory && relative == root }
        let parts = String(relative.dropFirst(root.count + 1)).split(separator: "/").map(String.init)
        let shared = ["ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex", "SymbolCache.noindex"]
        if let first = parts.first, shared.contains(first) { return true }
        if directory && parts.count == 1 { return true }
        return parts.count >= 2 && ["Build", "Index.noindex", "Logs"].contains(parts[1])
    }
}

public struct ApplicationSnapshot: Sendable {
    public let bundleIDs: Set<String>
    public let complete: Bool
    public let issues: [String]
}
private final class CatalogCache: @unchecked Sendable {
    let lock = NSLock()
    var snapshots: [String: (Date, ApplicationSnapshot)] = [:]
    static let shared = CatalogCache()
}
public enum ApplicationCatalog {
    public static func snapshot(home: URL, roots customRoots: [URL]? = nil) -> ApplicationSnapshot {
        let roots = customRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/System/Applications")]
        let key = roots.map { root in
            let id = FileIdentity.read(root)
            return root.path + ":\(id?.modifiedSeconds ?? 0):\(id?.modifiedNanoseconds ?? 0)"
        }.joined(separator: "|")
        let cache = CatalogCache.shared
        cache.lock.lock(); let old = cache.snapshots[key]; cache.lock.unlock()
        if let old, Date().timeIntervalSince(old.0) < 2 { return old.1 }
        var ids = Set<String>(); var complete = true; var issues: [String] = []
        let fm = FileManager.default
        for root in roots {
            do { _ = try fm.attributesOfItem(atPath: root.path) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { continue }
            catch { complete = false; issues.append(root.path); continue }
            guard fm.isReadableFile(atPath: root.path) else { complete = false; issues.append(root.path); continue }
            var failed = false
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, _ in failed = true; if issues.count < 30 { issues.append(url.path) }; return true }) else { complete = false; issues.append(root.path); continue }
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > 50_000 { complete = false; break }
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { DirectoryTraversal.skipDirectory(url, in: enumerator); continue }
                guard url.pathExtension.lowercased() == "app" else { continue }
                let plist = url.appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: plist), let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let id = info["CFBundleIdentifier"] as? String {
                    ids.insert(id.lowercased())
                } else { complete = false; if issues.count < 30 { issues.append(plist.path) } }
                DirectoryTraversal.skipDirectory(url, in: enumerator)
            }
            if failed { complete = false }
        }
        let result = ApplicationSnapshot(bundleIDs: ids, complete: complete, issues: issues)
        cache.lock.lock(); cache.snapshots[key] = (Date(), result); cache.lock.unlock()
        return result
    }
    public static func isInstalled(_ id: String, snapshot: ApplicationSnapshot, checkRegistry: Bool = true) -> Bool {
        let key = id.lowercased()
        guard snapshot.complete else { return true }
        if key.hasPrefix("com.apple.") || key.hasPrefix("local.luma.cleaner") || key.hasPrefix("app.yeetkix") { return true }
        if snapshot.bundleIDs.contains(where: { $0 == key || key.hasPrefix($0 + ".") || $0.hasPrefix(key + ".") }) { return true }
        let family = key.split(separator: ".").prefix(2).joined(separator: ".")
        if snapshot.bundleIDs.contains(where: { $0.hasPrefix(family + ".") }) { return true }
        guard checkRegistry else { return false }
        var error: Unmanaged<CFError>?
        if let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, &error)?.takeRetainedValue() as? [URL] {
            return urls.contains { !$0.path.contains("/.Trash/") && !$0.path.contains("/.Trashes/") && FileManager.default.fileExists(atPath: $0.path) }
        }
        if let error = error?.takeRetainedValue(), CFErrorGetCode(error) != -10814 { return true }
        return false
    }
}

public enum DeveloperActivity {
    public static func isBusy() -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(count) + 256)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { return true }
        let protected: Set<String> = ["Xcode", "xcodebuild", "XCBBuildService", "swift-build", "swift-frontend", "SourceKitService"]
        for pid in pids.prefix(Int(actual)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 1024)
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            if length > 0 && protected.contains(String(cString: buffer)) { return true }
        }
        return false
    }
}

public enum LeftoverScanner {
    public static func scan(_ request: WorkerRequest, progress: @escaping (Double, String, Int) -> Void) throws -> ScanReport {
        var report = ScanReport(); report.scope = request.scope; report.ageDays = request.ageDays
        let snapshot = ApplicationCatalog.snapshot(home: request.home, roots: request.policy.applicationRoots)
        let fm = FileManager.default
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(7, request.ageDays), to: Date()) ?? .distantPast
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        for root in request.roots {
            var status: RootStatus = .complete
            defer {
                let detail = !snapshot.complete ? "Не удалось проверить каталог приложений: " + snapshot.issues.prefix(2).joined(separator: ", ") : nil
                report.roots.append(RootResult(root: root, status: status, detail: detail))
            }
            guard ArtifactPaths.leftoverRoots.contains(root.relativePath), root.url.standardizedFileURL.path == request.home.appendingPathComponent(root.relativePath).standardizedFileURL.path else { status = .denied; continue }
            guard snapshot.complete else { status = .denied; report.inaccessible.append("Список установленных приложений"); continue }
            do { _ = try fm.attributesOfItem(atPath: root.url.path) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { status = .missing; continue }
            catch { status = .denied; report.inaccessible.append(root.relativePath); continue }
            guard root.url.resolvingSymlinksInPath().standardizedFileURL.path == request.home.resolvingSymlinksInPath().appendingPathComponent(root.relativePath).standardizedFileURL.path else { status = .denied; continue }
            if request.policy.isExcluded(root.url) { status = .protected; report.protectedCount += 1; continue }
            let owners: [URL]
            do { owners = try fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) }
            catch { status = .denied; report.inaccessible.append(root.relativePath); continue }
            for (index, owner) in owners.enumerated() {
                try Task.checkCancellation()
                report.visitedCount += 1
                if report.visitedCount > request.entryLimit { report.truncated = true; status = .limited; break }
                progress(Double(index) / Double(max(1, owners.count)), root.title, report.visitedCount)
                guard let bundleID = ArtifactPaths.leftoverID(owner, home: request.home, knownApplications: request.policy.knownApplications),
                      !ApplicationCatalog.isInstalled(bundleID, snapshot: snapshot, checkRegistry: request.policy.checkRegisteredApplications),
                      request.policy.protectionReason(for: owner, category: .leftovers, home: request.home) == nil,
                      let values = try? owner.resourceValues(forKeys: keys), values.isSymbolicLink != true else { report.protectedCount += 1; continue }
                var files: [URL] = []
                if values.isRegularFile == true { files = [owner] }
                else if values.isDirectory == true && values.isPackage != true {
                    var failed = false
                    if let enumerator = fm.enumerator(at: owner, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in failed = true; return true }) {
                        for case let url as URL in enumerator {
                            try Task.checkCancellation()
                            report.visitedCount += 1
                            if report.visitedCount > request.entryLimit { report.truncated = true; status = .limited; break }
                            if report.visitedCount % 200 == 0 { progress(Double(index) / Double(max(1, owners.count)), root.title, report.visitedCount) }
                            if request.policy.isExcluded(url) { DirectoryTraversal.skipDirectory(url, in: enumerator); report.protectedCount += 1; continue }
                            guard let metadata = try? url.resourceValues(forKeys: keys), metadata.isSymbolicLink != true else { DirectoryTraversal.skipDirectory(url, in: enumerator); continue }
                            if metadata.isRegularFile == true { files.append(url) }
                        }
                    } else { failed = true }
                    if failed { status = .denied; report.inaccessible.append(owner.path) }
                }
                for file in files {
                    try Task.checkCancellation()
                    if request.policy.isExcluded(file) { continue }
                    guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                          let modified = values.contentModificationDate, modified < cutoff,
                          let identity = FileIdentity.read(file), identity.isRegular, identity.links == 1, identity.bytes > 0 else { continue }
                    report.items.append(FileItem(url: file, bytes: identity.bytes, modified: modified, category: .leftovers, identity: identity, leftoverBundleID: bundleID))
                }
                if report.truncated { break }
            }
        }
        report.items.sort { $0.bytes > $1.bytes }
        return report
    }
}
