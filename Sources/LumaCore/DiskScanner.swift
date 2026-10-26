import Foundation

public struct DiskScanner: Sendable {
    public static let largeFileThreshold: Int64 = 100_000_000
    public let home: URL
    public let ageDays: Int
    public let entryLimit: Int
    public let scope: ScanScope
    public let policy: SafetyPolicy
    public let requestedRoots: [ScanRoot]?
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, ageDays: Int = 14, entryLimit: Int = 250_000,
                scope: ScanScope = .all, policy: SafetyPolicy = SafetyPolicy(), roots: [ScanRoot]? = nil) {
        self.home = home; self.ageDays = max(7, ageDays); self.entryLimit = max(1, entryLimit)
        self.scope = scope; self.policy = policy; self.requestedRoots = roots
    }
    public func scan(snapshot: @escaping @Sendable (ScanReport) -> Void = { _ in }, progress: @escaping @Sendable (Double, String, Int) -> Void = { _, _, _ in }) throws -> ScanReport {
        let fm = FileManager.default
        var report = ScanReport(); report.ageDays = ageDays; report.scope = scope
        var seen = Set<String>()
        var visited = 0
        var lastSnapshot = Date.distantPast
        let cutoff = Calendar.current.date(byAdding: .day, value: -ageDays, to: Date()) ?? .distantPast
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey, .isUbiquitousItemKey]
        let roots = requestedRoots ?? scope.roots(home: home, applications: policy.knownApplications)
        let allowedRoots = Set(ScanScope.all.roots(home: home, applications: policy.knownApplications).map(\.id))
        for (index, root) in roots.enumerated() {
            try Task.checkCancellation()
            if root.category == .leftovers {
                let request = WorkerRequest(home: home, roots: [root], scope: scope, ageDays: ageDays,
                                            entryLimit: max(1, entryLimit - visited), policy: policy)
                let emit: (Double, String, Int) -> Void = { fraction, location, count in
                    progress((Double(index) + fraction) / Double(max(1, roots.count)), location, count)
                }
                let extra = try ["Library/Containers", "Library/Group Containers"].contains(root.relativePath)
                    ? OrphanContainerScanner.scan(request, snapshot: snapshot, progress: emit)
                    : LeftoverScanner.scan(request, progress: emit)
                report.items += extra.items; report.roots += extra.roots; report.inaccessible += extra.inaccessible
                report.protectedCount += extra.protectedCount; visited += extra.visitedCount
                report.truncated = report.truncated || extra.truncated
                if report.truncated { break }
                continue
            }
            var status: RootStatus = .complete
            var detail: String?
            defer {
                report.visitedCount = visited
                report.roots.append(RootResult(root: root, status: status, detail: detail))
                var partial = report; partial.isPartial = true; snapshot(partial)
            }
            let directory = root.url
            progress(Double(index) / Double(max(1, roots.count)), root.title, visited)
            // URL equality also compares the directory marker. A missing directory
            // cannot be inferred as such by Foundation, so compare normalized paths.
            guard allowedRoots.contains(root.id), directory.standardizedFileURL.path == home.appendingPathComponent(root.relativePath).standardizedFileURL.path else {
                status = .denied; report.inaccessible.append(root.relativePath); continue
            }
            do { _ = try fm.attributesOfItem(atPath: directory.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { status = .missing; continue }
            catch { status = .denied; detail = error.localizedDescription; report.inaccessible.append(root.relativePath); continue }
            let approved = home.resolvingSymlinksInPath().appendingPathComponent(root.relativePath).standardizedFileURL
            guard directory.resolvingSymlinksInPath().standardizedFileURL.path == approved.path,
                  fm.isReadableFile(atPath: directory.path) else {
                status = .denied; report.inaccessible.append(root.relativePath); continue
            }
            if policy.isExcluded(directory) { report.protectedCount += 1; status = .protected; detail = "Папка в исключениях"; continue }
            if let reason = policy.protectionReason(for: directory, category: root.category, home: home), [.cache, .logs, .toolCaches].contains(root.category) {
                report.protectedCount += 1; status = .protected; detail = reason; continue
            }
            if root.category == .trash {
                do {
                    for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
                        try Task.checkCancellation()
                        visited += 1
                        if visited > entryLimit { report.truncated = true; status = .limited; break }
                        guard !policy.isExcluded(child), let value = try? child.resourceValues(forKeys: keys), value.isSymbolicLink != true else { continue }
                        let bytes = value.isDirectory == true ? 0 : Int64(value.fileSize ?? 0)
                        report.items.append(FileItem(url: child, bytes: bytes, modified: value.contentModificationDate ?? .distantPast,
                                                     category: .trash, isDirectory: value.isDirectory == true))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { status = .denied; report.inaccessible.append(root.relativePath) }
                continue
            }
            var hadError = false
            let options: FileManager.DirectoryEnumerationOptions = root.category == .developer ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: options, errorHandler: { _, _ in hadError = true; return true }) else {
                status = .denied; report.inaccessible.append(root.relativePath); continue
            }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                visited += 1
                if visited > entryLimit { report.truncated = true; status = .limited; break }
                if visited % 300 == 0 {
                    progress(Double(index) / Double(max(1, roots.count)), root.title, visited)
                    if Date().timeIntervalSince(lastSnapshot) > 0.75 {
                        report.visitedCount = visited
                        var partial = report; partial.isPartial = true; snapshot(partial); lastSnapshot = Date()
                    }
                }
                let cacheLocation = [.cache, .logs, .toolCaches].contains(root.category) ? JunkCatalog.location(url, home: home, applications: policy.knownApplications) : nil
                let category = cacheLocation?.category ?? root.category
                if policy.protectionReason(for: url, category: category, home: home) != nil {
                    DirectoryTraversal.skipDirectory(url, in: enumerator); report.protectedCount += 1; continue
                }
                guard let value = try? url.resourceValues(forKeys: keys) else { hadError = true; continue }
                guard value.isSymbolicLink != true else { DirectoryTraversal.skipDirectory(url, in: enumerator); report.protectedCount += 1; continue }
                guard value.isRegularFile == true, value.isPackage != true else { continue }
                // Metadata only; never download iCloud placeholders to inspect file contents.
                let bytes = Int64(value.fileSize ?? 0)
                let modified = value.contentModificationDate ?? .distantFuture
                guard bytes > 0 else { continue }
                if root.category == .cache || root.category == .logs || root.category == .developer || root.category == .toolCaches { guard modified < cutoff else { continue } }
                guard seen.insert(url.standardizedFileURL.path).inserted,
                      let identity = FileIdentity.read(url), identity.isRegular, !identity.isSymbolicLink else { continue }
                let personal = ArtifactPaths.personal.contains(root.relativePath)
                if personal && (scope == .all || scope == .duplicates) {
                    report.duplicateCandidates.append(FileItem(url: url, bytes: bytes, modified: modified, category: .duplicates, identity: identity))
                }
                if root.category == .large && bytes < Self.largeFileThreshold { continue }
                if root.category != .duplicates {
                    report.items.append(FileItem(url: url, bytes: bytes, modified: modified, category: category, identity: identity,
                                                 cleanupRoot: cacheLocation?.relativePath))
                }
            }
            if hadError { status = .denied; report.inaccessible.append(root.relativePath) }
            if report.truncated { break }
        }
        report.items.sort { $0.bytes > $1.bytes }
        report.inaccessible = Array(Set(report.inaccessible)).sorted()
        report.visitedCount = visited; report.date = Date()
        progress(1, "Готово", visited)
        return report
    }
}

public enum TrashSafety {
    public static func isAllowed(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, knownApplications: [KnownApplication] = []) -> Bool {
        let path = url.standardizedFileURL.path
        let resolved = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).resolvingSymlinksInPath().standardizedFileURL.path
        let base = ["Library/Caches", "Library/Logs"] + ArtifactPaths.personal + JunkCatalog.toolCaches.map(\.relativePath) + JunkCatalog.appCaches(knownApplications).map(\.relativePath)
        let allowed = base.contains { relative in
            let root = home.appendingPathComponent(relative).standardizedFileURL.path + "/"
            let realRoot = home.resolvingSymlinksInPath().appendingPathComponent(relative).standardizedFileURL.path + "/"
            return path.hasPrefix(root) && resolved.hasPrefix(realRoot)
        }
        if allowed { return true }
        guard resolved == home.resolvingSymlinksInPath().appendingPathComponent(ArtifactPaths.relative(url, to: home) ?? "outside").standardizedFileURL.path else { return false }
        return ArtifactPaths.leftoverID(url, home: home, knownApplications: knownApplications) != nil || ArtifactPaths.developerAllowed(url, home: home)
    }
    public static func uniqueTopLevelItems(_ items: [FileItem]) -> [FileItem] {
        var result: [FileItem] = []
        for item in items.sorted(by: { $0.id < $1.id }) {
            if let previous = result.last, previous.id == item.id || item.id.hasPrefix(previous.id + "/") { continue }
            result.append(item)
        }
        return result
    }
}
