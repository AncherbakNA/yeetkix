import Foundation
import LumaCore

enum AdvancedFeatureChecks {
    static func policy(_ f: Fixture, busy: Bool = false) -> SafetyPolicy {
        SafetyPolicy(developerToolsBusy: busy, applicationRoots: [f.home.appendingPathComponent("Applications")], checkRegisteredApplications: false)
    }
    static func application(_ f: Fixture, id: String, name: String) throws {
        let url = f.home.appendingPathComponent("Applications/" + name + ".app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try data.write(to: url)
    }
    static func duplicatesAreContentBased() throws {
        let f = try Fixture(); defer { try? f.remove() }
        let a = try f.file("Downloads/one.txt", text: "identical content")
        let b = try f.file("Documents/different-name.txt", text: "identical content")
        let c = try f.file("Movies/third-copy.txt", text: "identical content")
        let hardURL = f.home.appendingPathComponent("Downloads/hard-link")
        try FileManager.default.linkItem(at: a.url, to: hardURL)
        let hard = FileItem(url: hardURL, bytes: a.bytes, modified: a.modified, category: .duplicates)
        let prefix = String(repeating: "A", count: 70_000)
        let x = try f.file("Downloads/same-prefix-one", text: prefix + "111")
        let y = try f.file("Downloads/same-prefix-two", text: prefix + "222")
        let groups = try DuplicateFinder.find([a, b, c, hard, x, y])
        try expect(groups.count == 1 && groups[0].files.count == 3, "Only exact content matches group; hard links and prefix-only matches do not")
        try expect(groups[0].reclaimableBytes == a.bytes * 2, "Reclaim estimate retains one physical copy")
        let keeper = groups[0].files[0]
        do { try policy(f).validate(keeper, home: f.home, minimumAgeDays: 14); throw CheckFailure(message: "Keeper selectable") }
        catch { try expect(error is SafetyError, "Keeper is protected at service boundary") }
    }
    static func duplicateMoveRequiresUnchangedKeeper() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let a = try f.file("Downloads/a", text: "same")
        let b = try f.file("Documents/b", text: "same")
        let group = try require(try DuplicateFinder.find([a, b]).first, "Expected group")
        let copy = group.files[1]
        let service = try f.service()
        let result = await service.move([copy], policy: policy(f), minimumAgeDays: 14)
        try expect(result.moved.count == 1 && FileManager.default.fileExists(atPath: group.files[0].url.path), "One duplicate moves; keeper remains")
        _ = try await service.restore(result.moved[0].id)
        let refreshed = try DuplicateFinder.find([a, b])
        let current = try require(refreshed.first, "Group remains after restore")
        try Data("edited keeper".utf8).write(to: current.files[0].url)
        let refused = await service.move([current.files[1]], policy: policy(f), minimumAgeDays: 14)
        try expect(refused.moved.isEmpty && !refused.failures.isEmpty, "Changed keeper blocks removing copy")
        try expect(FileManager.default.fileExists(atPath: current.files[1].url.path), "Copy preserved on changed keeper")
    }
    static func forgedOrChangedDuplicateEvidenceIsRejected() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let a = try f.file("Downloads/a", text: "same")
        let b = try f.file("Downloads/b", text: "same")
        let group = try require(try DuplicateFinder.find([a, b]).first, "Group")
        let item = group.files[1]
        let proof = try require(item.duplicateEvidence, "Evidence")
        let falseProof = DuplicateEvidence(sha256: String(repeating: "0", count: 64), keeperURL: proof.keeperURL, keeperIdentity: proof.keeperIdentity)
        let forged = FileItem(url: item.url, bytes: item.bytes, modified: item.modified, category: .duplicates, identity: item.identity, duplicateEvidence: falseProof)
        let service = try f.service()
        let outcome = await service.move([forged], policy: policy(f), minimumAgeDays: 14)
        try expect(outcome.moved.isEmpty && outcome.failures.count == 1, "Hashes rechecked before any move")
        try expect(FileManager.default.fileExists(atPath: item.url.path), "Unverified file untouched")
        let task = Task.detached { () throws -> [DuplicateGroup] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try DuplicateFinder.find([a, b])
        }
        do { _ = try await task.value; throw CheckFailure(message: "Expected cancelled comparison") }
        catch { try expect(error is CancellationError, "Hash comparison honors cancellation") }
    }
    static func orphanDetectionAndReinstallProtection() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        try application(f, id: "com.fixture.installed", name: "Installed")
        try f.file("Library/Application Support/com.fixture.installed/data.db")
        try f.file("Library/Application Support/com.fixture.installed.helper/data.db")
        try f.file("Library/Application Support/UnknownHumanName/user-data")
        let orphan = try f.file("Library/Application Support/org.remnant.fixture/data.db")
        try f.file("Library/Preferences/org.remnant.fixture.plist")
        try f.file("Library/Saved Application State/org.remnant.fixture.savedState/window.dat")
        try f.file("Library/Application Support/com.apple.old/data")
        try f.file("Library/Application Support/local.luma.cleaner/history.json")
        let request = WorkerRequest(home: f.home, roots: ScanScope.leftovers.roots(home: f.home), scope: .leftovers, policy: policy(f))
        let report = try LeftoverScanner.scan(request) { _, _, _ in }
        try expect(report.items.count == 3 && report.items.allSatisfy { $0.leftoverBundleID == "org.remnant.fixture" }, "Only namespaced absent app data proposed, including prefs and saved state")
        let candidate = try require(report.items.first { $0.id == orphan.id }, "Expected orphan candidate")
        try application(f, id: "org.remnant.fixture", name: "Reinstalled")
        let service = try f.service()
        let result = await service.move([candidate], policy: policy(f), minimumAgeDays: 14)
        try expect(result.moved.isEmpty && result.failures.count == 1, "Reinstall between scan and cleanup protects data")
        try expect(FileManager.default.fileExists(atPath: orphan.url.path), "Reinstalled app data remains")
    }
    static func orphanMoveRestoreAndIncompleteCatalog() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        try f.file("Library/Application Support/com.fixture.gone/data.db")
        let request = WorkerRequest(home: f.home, roots: ScanScope.leftovers.roots(home: f.home), scope: .leftovers, policy: policy(f))
        let report = try LeftoverScanner.scan(request) { _, _, _ in }
        let candidate = try require(report.items.first, "Expected orphan")
        let service = try f.service()
        let moved = await service.move([candidate], policy: policy(f), minimumAgeDays: 14)
        try expect(moved.moved.count == 1, "Orphan data can move after review")
        _ = try await service.restore(moved.moved[0].id)
        try expect(FileManager.default.fileExists(atPath: candidate.url.path), "Orphan data restores")
        let blocked = try f.file("unreadable-catalog", text: "not a directory")
        let badPolicy = SafetyPolicy(applicationRoots: [blocked.url], checkRegisteredApplications: false)
        let bad = WorkerRequest(home: f.home, roots: request.roots, scope: .leftovers, policy: badPolicy)
        let incomplete = try LeftoverScanner.scan(bad) { _, _, _ in }
        try expect(incomplete.items.isEmpty && !incomplete.inaccessible.isEmpty, "Incomplete catalog never implies app absence")
    }
    static func developerScopeAndBusyProtection() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let prefix = "Library/Developer/Xcode/DerivedData/Fixture-abc/"
        try f.file(prefix + "Build/Intermediates.noindex/file.o")
        try f.file(prefix + "Build/Products/Fixture.app/Contents/MacOS/Fixture")
        try f.file(prefix + "Index.noindex/index.db")
        try f.file("Library/Developer/Xcode/DerivedData/ModuleCache.noindex/module.pcm")
        try f.file("Library/Caches/com.apple.dt.Xcode/cache.bin")
        try f.file("Library/Developer/Xcode/iOS DeviceSupport/17.0/Symbols/usr/lib/symbols")
        let source = try f.file(prefix + "SourcePackages/checkouts/Package/Sources/Important.swift")
        try f.file(prefix + "Sources/User.swift")
        let archive = try f.file("Library/Developer/Xcode/Archives/Release.xcarchive/Important")
        try f.file(prefix + "Build/recent.o", days: 1)
        let report = try DiskScanner(home: f.home, scope: .developer, policy: policy(f)).scan()
        try expect(report.items.count == 6 && report.items.allSatisfy { $0.category == .developer }, "Generated build packages, indexes, cache, device symbols found")
        try expect(!report.items.contains { $0.id == source.id || $0.id == archive.id }, "Source checkouts and archives excluded")
        let busy = try DiskScanner(home: f.home, scope: .developer, policy: policy(f, busy: true)).scan()
        try expect(busy.items.isEmpty, "Active developer tools protect build data")
        let service = try f.service()
        let denied = await service.move([report.items[0]], policy: policy(f, busy: true), minimumAgeDays: 14)
        try expect(denied.moved.isEmpty && denied.failures.count == 1, "Developer activity rechecked before move")
        let product = try require(report.items.first { $0.url.path.contains("Fixture.app/Contents") }, "Generated product")
        let moved = await service.move([product], policy: policy(f), minimumAgeDays: 14)
        try expect(moved.moved.count == 1, "Generated package is eligible only inside allowlisted build output")
        _ = try await service.restore(moved.moved[0].id)
        try expect(FileManager.default.fileExists(atPath: product.url.path), "Generated build artifact restores")
    }
    static func categoryBoundaries() throws {
        let f = try Fixture(); defer { try? f.remove() }
        let file = try f.file("Library/Application Support/com.fixture.gone/data")
        let misleading = FileItem(url: file.url, bytes: file.bytes, modified: file.modified, category: .cache, identity: file.identity)
        do { try policy(f).validate(misleading, home: f.home, minimumAgeDays: 14); throw CheckFailure(message: "Category crossing allowed") }
        catch { try expect(error is SafetyError, "Generic cache cannot delete app support data") }
        let unexplained = FileItem(url: file.url, bytes: file.bytes, modified: file.modified, category: .leftovers, identity: file.identity)
        do { try policy(f).validate(unexplained, home: f.home, minimumAgeDays: 14); throw CheckFailure(message: "Owner proof missing") }
        catch { try expect(error is SafetyError, "Leftover owner evidence is required") }
    }
    static func sharedVendorDataIsProtected() throws {
        let f = try Fixture(); defer { try? f.remove() }
        try application(f, id: "com.microsoft.Excel", name: "Excel")
        try f.file("Library/Caches/com.microsoft.OneDriveStandaloneUpdater/data.db")
        try f.file("Library/Application Support/com.microsoft.OneAuth/settings")
        let request = WorkerRequest(home: f.home, roots: ScanScope.leftovers.roots(home: f.home), scope: .leftovers, policy: policy(f))
        let report = try LeftoverScanner.scan(request) { _, _, _ in }
        try expect(report.items.isEmpty, "Shared updater and authentication data are protected while any app from vendor remains")
    }
    @MainActor static func duplicateWorkerAcrossRoots() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        try f.file("Downloads/alpha", text: "cross-root identical content")
        try f.file("Documents/beta", text: "cross-root identical content")
        try f.file("Music/gamma", text: "cross-root identical content")
        let request = WorkerRequest(home: f.home, roots: ScanScope.duplicates.roots(home: f.home), scope: .duplicates, policy: policy(f))
        let coordinator = ScanCoordinator()
        let report = await coordinator.scan(request, executable: URL(fileURLWithPath: CommandLine.arguments[0])) { _ in }
        try expect(report.duplicateGroups.count == 1 && report.duplicateGroups[0].files.count == 3, "Isolated worker finds duplicates across separate roots")
        try expect(report.duplicateCandidates.isEmpty && report.roots.last?.status == .complete, "Temporary candidates discarded after verified comparison")
    }
}
