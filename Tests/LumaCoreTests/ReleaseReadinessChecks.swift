import Foundation
import LumaCore

enum ReleaseReadinessChecks {
    static func linksDoNotHideSiblingTrees() throws {
        let f = try Fixture(); defer { try? f.remove() }
        let outside = try f.file("Outside/target", text: "never follow this target")
        let base = "Library/Caches/OwnedRoot"
        var files = [FileItem]()
        for index in 0..<12 {
            files.append(try f.file(base + "/Branch\(index)/data", text: "owned sibling \(index)"))
            let link = f.home.appendingPathComponent(base + "/link\(index)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
            try f.file(base + "/Branch\(index)/lock")
        }
        let report = try DiskScanner(home: f.home, scope: .cleanup).scan()
        try expect(Set(report.items.map(\.id)) == Set(files.map(\.id)), "Links and protected regular files cannot hide sibling directories")
        let root = f.home.appendingPathComponent(base)
        let manifest = try DirectoryEvidence.capture(root)
        try expect(manifest.entries == 48, "The whole-tree manifest records every branch, file, lock and link")
        var excluded = SafetyPolicy(); excluded.excludedPaths = [files.last!.id]
        do { _ = try DirectoryEvidence.capture(root, policy: excluded); throw CheckFailure(message: "An exclusion hidden behind links was ignored") }
        catch { try expect(error is SafetyError, "Exclusions after links still block moving the ancestor") }
        let map = try DiskMapScanner.scan(root)
        try expect(map.children.filter(\.directory).count == 12 && map.children.reduce(0) { $0 + $1.files } == 24, "Disk map retains siblings and counts each actual file")
        let app = try UtilityFeatureChecks.app(f, id: "com.utmapp.UTM", name: "UTM traversal fixture")
        let vmRoot = f.home.appendingPathComponent("Custom/VMs")
        try FileManager.default.createDirectory(at: vmRoot, withIntermediateDirectories: true)
        for index in 0..<8 {
            try FileManager.default.createSymbolicLink(at: vmRoot.appendingPathComponent("link\(index)"), withDestinationURL: outside.url)
            _ = try ApplicationDiscoveryChecks.vm(f, "Custom/VMs/Group\(index)/Owned\(index).utm")
        }
        let result = try ApplicationDiscovery.scan(ApplicationReviewSource(kind: .utmFolder, url: vmRoot, ownerID: app.bundleID), app: app, home: f.home, policy: JunkCoverageChecks.policy(f))
        try expect(result.items.filter { $0.applicationEvidence?.location?.kind == .virtualMachine }.count == 8, "External VM folders after symlinks remain discoverable")
        try expect(FileIdentity.read(outside.url) == outside.identity, "Link targets remain untouched")
    }
    @MainActor static func cancellationListsEveryRoot() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        try f.file("Library/Caches/owned/item")
        try f.file("Library/Logs/owned/item")
        try f.file("Downloads/owned")
        let roots = [ScanRoot(relativePath: "Library/Caches", category: .cache, home: f.home), ScanRoot(relativePath: "Library/Logs", category: .logs, home: f.home), ScanRoot(relativePath: "Downloads", category: .downloads, home: f.home)]
        let coordinator = ScanCoordinator()
        let report = await coordinator.scan(WorkerRequest(home: f.home, roots: roots, scope: .cleanup), executable: URL(fileURLWithPath: CommandLine.arguments[0])) { update in
            if update.partial.roots.first?.status == .complete { coordinator.cancel() }
        }
        try expect(report.isPartial && report.roots.count == roots.count, "Cancellation accounts for every requested root")
        try expect(report.roots.first?.status == .complete && report.roots.dropFirst().allSatisfy { $0.status == .cancelled && $0.detail?.contains("Не проверена") == true }, "Unvisited folders explicitly remain unverified")
        try expect(report.items.count == 1 && FileIdentity.read(report.items[0].url) == report.items[0].identity, "Completed read-only results are retained")
        let limited = await ScanCoordinator().scan(WorkerRequest(home: f.home, roots: roots, scope: .cleanup, entryLimit: 1), executable: URL(fileURLWithPath: CommandLine.arguments[0])) { _ in }
        try expect(limited.truncated && limited.isPartial && limited.roots.count == roots.count && limited.roots.dropFirst().allSatisfy { $0.status == .limited }, "Budget exhaustion also records unvisited roots")
    }
    static func unreadableParentsAreNotAbsence() throws {
        let f = try Fixture(); defer { try? f.remove() }
        try f.file("locked/Applications/Fixture.app/Contents/Info.plist")
        let locked = f.home.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let catalog = ApplicationCatalog.snapshot(home: f.home, roots: [locked.appendingPathComponent("Applications")])
        try expect(!catalog.complete && !catalog.issues.isEmpty, "An unreadable catalog parent cannot imply no installed apps")
        try f.file("Library/Preferences/test.absent.app.plist")
        let library = f.home.appendingPathComponent("Library")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.path) }
        let root = ScanRoot(relativePath: "Library/Preferences", category: .leftovers, home: f.home)
        let policy = SafetyPolicy(applicationRoots: [f.home.appendingPathComponent("Applications")], checkRegisteredApplications: false)
        let report = try LeftoverScanner.scan(WorkerRequest(home: f.home, roots: [root], scope: .leftovers, policy: policy)) { _, _, _ in }
        try expect(report.items.isEmpty && report.roots.first?.status == .denied && !report.inaccessible.isEmpty, "Unreadable leftover paths are denied, never missing")
    }
    static func portableMetadataReport() throws {
        let f = try Fixture(); defer { try? f.remove() }
        let file = try f.file("Library/Caches/owned/item", text: "PRIVATE FIXTURE CONTENT MUST NOT BE EXPORTED")
        var report = ScanReport(); report.scope = .cleanup; report.items = [file, file]; report.duplicateCandidates = [file, file]
        report.roots = [RootResult(root: ScanRoot(relativePath: "Library/Caches", category: .cache, home: f.home), status: .complete), RootResult(root: ScanRoot(relativePath: "Library/Logs", category: .logs, home: f.home), status: .cancelled, detail: "Не проверена")]
        report.visitedCount = 2; report.isPartial = true
        let data = try report.exportData(); let text = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScanReport.self, from: data)
        try expect(decoded.items.count == 1 && decoded.duplicateCandidates.isEmpty && decoded.roots.count == 2 && decoded.isPartial, "Export preserves coverage and status without duplicate internal candidates")
        try expect(decoded.items[0].identity == file.identity && !text.contains("PRIVATE FIXTURE CONTENT") && !text.contains("bookmark"), "Export contains metadata, never file contents or access bookmarks")
        report.normalizeItems()
        try expect(report.cleanupBytes == file.bytes && report.duplicateCandidates.count == 1, "Streaming normalization avoids counting overlapping roots twice")
        try expect(ScanScope.cleanup.includes(.toolCaches) && !ScanScope.toolCaches.includes(.cleanup), "A complete cleanup result can be reused for its tool-cache section")
        report.isPartial = false
        report.roots[1].status = .denied
        report.normalizeItems()
        try expect(report.isPartial, "A worker with read errors cannot be labelled a complete scan")
    }
}
