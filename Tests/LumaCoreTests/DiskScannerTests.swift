import Foundation
import LumaCore

final class DiskScannerTests {
    private var home: URL!
    func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("LumaTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    @discardableResult
    private func file(_ path: String, bytes: Int = 64, daysOld: Int = 30) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(daysOld) * 86400)], ofItemAtPath: url.path)
        return url
    }

    func testScanOnlyOffersOldCachesAndLogsAndPreservesFiles() throws {
        let old = try file("Library/Caches/com.example/old.bin")
        try file("Library/Caches/com.example/recent.bin", daysOld: 1)
        try file("Library/Caches/com.apple.protected/old.bin")
        try file("Library/Logs/old.log")
        try file("Library/Logs/fresh.log", daysOld: 2)
        try file("Documents/small.txt")
        try file("Downloads/recent.pdf", daysOld: 0)
        try file("Documents/large.mov", bytes: 110_000_000)
        let report = try DiskScanner(home: home).scan()
        try expect(report.cleanupItems.count == 2, "Only old cache and log files")
        try expect(report.cleanupBytes == 128, "Correct byte total")
        try expect(report.items(for: .downloads).count == 1, "Recent downloads remain visible")
        try expect(report.items(for: .large).count == 1, "Large file threshold")
        try expect(FileManager.default.fileExists(atPath: old.path), "Scanning never removes files")
    }

    func testSymlinksAndApplicationBundlesAreNeverTraversed() throws {
        let target = try file("private/secret.txt")
        try file("Downloads/Example.app/Contents/large.bin", bytes: 110_000_000)
        let caches = home.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("linked-file"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("linked-dir"), withDestinationURL: target.deletingLastPathComponent())
        let report = try DiskScanner(home: home).scan()
        try expect(report.items.isEmpty, "Symlinks and app bundles must be skipped")
        try expect(!TrashSafety.isAllowed(caches.appendingPathComponent("linked-file"), home: home), "Symlink file is blocked")
        try expect(!TrashSafety.isAllowed(caches.appendingPathComponent("linked-dir/secret.txt"), home: home), "Symlink parent is blocked")
    }

    func testTrashSafetyRejectsRootsProtectedPathsAndPrefixCollisions() throws {
        let allowed = try file("Downloads/old.zip")
        try expect(TrashSafety.isAllowed(allowed, home: home), "Download file is allowed")
        for path in ["Downloads", "Library/Caches", "Library/CachesOther/file", "Library/Application Support/db", ".Trash/file", "Documents/../private/file"] {
            try expect(!TrashSafety.isAllowed(home.appendingPathComponent(path), home: home), "Blocked: " + path)
        }
        let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Desktop"), withDestinationURL: outside)
        try expect(!TrashSafety.isAllowed(home.appendingPathComponent("Desktop/test"), home: home), "Symlink root is blocked")
    }

    func testSelectionDeduplicatesFilesAndDescendants() throws {
        let parent = FileItem(url: home.appendingPathComponent("Downloads/folder"), bytes: 100, modified: Date(), category: .downloads, isDirectory: true)
        let child = FileItem(url: home.appendingPathComponent("Downloads/folder/file"), bytes: 50, modified: Date(), category: .large)
        try expect(TrashSafety.uniqueTopLevelItems([child, parent, child]).map(\.id) == [parent.id], "Deduplicate parents and repeated files")
    }

    func testEntryLimitIsReportedAsPartial() throws {
        for i in 0..<10 { try file("Downloads/\(i).txt") }
        let report = try DiskScanner(home: home, entryLimit: 3).scan()
        try expect(report.truncated, "Partial scan is labelled")
        try expect(report.items.count == 3, "Entry limit is respected")
    }

    func testCancelledScanStopsBeforeReadingFiles() async throws {
        try file("Downloads/test.txt")
        let scanner = DiskScanner(home: home)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try scanner.scan()
        }
        do { _ = try await task.value; throw CheckFailure(message: "Expected cancellation") }
        catch { try expect(error is CancellationError, "Cancelled scan throws CancellationError") }
    }

    func testMissingRootsAreNotPermissionFailures() throws {
        // Every root is absent in this owned temporary home. ScanRoot explicitly
        // marks URLs as directories; Foundation's inferred URL does not.
        let scopes: [ScanScope] = [.developer, .cleanup, .downloads, .large, .trash, .duplicates, .leftovers]
        let policy = SafetyPolicy(applicationRoots: [], checkRegisteredApplications: false)
        for scope in scopes {
            let report = try DiskScanner(home: home, scope: scope, policy: policy).scan()
            try expect(report.roots.count == scope.roots(home: home).count, "All missing roots reported for \(scope)")
            try expect(report.roots.allSatisfy { $0.status == .missing }, "Absent folders are missing, not denied: \(scope)")
            try expect(report.inaccessible.isEmpty && report.items.isEmpty, "Absent folders do not request broader permissions")
        }
        // Accept the same path after IPC adds or removes a trailing slash.
        let request = WorkerRequest(home: home, roots: ScanScope.developer.roots(home: home), scope: .developer, policy: policy)
        let decoded = try JSONDecoder().decode(WorkerRequest.self, from: JSONEncoder().encode(request))
        let report = try DiskScanner(home: decoded.home, scope: decoded.scope, policy: decoded.policy, roots: decoded.roots).scan()
        try expect(report.roots.allSatisfy { $0.status == .missing }, "Directory markers survive worker serialization without false denial")
    }
}

struct CheckFailure: Error { let message: String }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message: message) }
}

@main
struct LumaChecks {
    static func main() async throws {
        ScanWorkerHost.runIfRequested()
        UtilityWorkerHost.runIfRequested()
        if CommandLine.arguments.contains("--catalog-diagnostics") {
            let snapshot = ApplicationCatalog.snapshot(home: FileManager.default.homeDirectoryForCurrentUser)
            print("Catalog complete: \(snapshot.complete); identifiers: \(snapshot.bundleIDs.count)")
            snapshot.issues.forEach { print($0) }
            return
        }
        let suite = DiskScannerTests()
        let checks: [(String, () async throws -> Void)] = [
            ("Age, size and read-only scanning", { try suite.testScanOnlyOffersOldCachesAndLogsAndPreservesFiles() }),
            ("Symlinks and app bundles", { try suite.testSymlinksAndApplicationBundlesAreNeverTraversed() }),
            ("Trash path boundaries", { try suite.testTrashSafetyRejectsRootsProtectedPathsAndPrefixCollisions() }),
            ("Selection deduplication", { try suite.testSelectionDeduplicatesFilesAndDescendants() }),
            ("Partial scan limit", { try suite.testEntryLimitIsReportedAsPartial() }),
            ("Cancellation", { try await suite.testCancelledScanStopsBeforeReadingFiles() }),
            ("Missing roots are not permission failures", { try suite.testMissingRootsAreNotPermissionFailures() }),
            ("Running apps, exclusions and databases", { try SafetyAndHistoryChecks.protections() }),
            ("Changed identity and hard links", { try SafetyAndHistoryChecks.changedIdentityAndHardLinks() }),
            ("Move, restore and persisted history", { try await SafetyAndHistoryChecks.moveRestoreAndPersistence() }),
            ("Restore conflicts and tampering", { try await SafetyAndHistoryChecks.restoreConflictsAndTampering() }),
            ("Restore through replaced parent", { try await SafetyAndHistoryChecks.unavailableRestoreAndSymlinkParent() }),
            ("Journal failures and crash recovery", { try await SafetyAndHistoryChecks.journalFailureAndRecovery() }),
            ("Per-file failures and cancelled cleanup", { try await SafetyAndHistoryChecks.perFileFailuresAndCancellation() }),
            ("Running app recheck before move", { try await SafetyAndHistoryChecks.activeAppRecheck() }),
            ("Corrupt history preservation", { try await SafetyAndHistoryChecks.corruptHistoryAndTruncatedJournal() }),
            ("Interrupted first journal record", { try await SafetyAndHistoryChecks.incompleteFirstIntent() }),
            ("Worker scopes, timeout, cancellation, failure", { try await SafetyAndHistoryChecks.scopedWorkersAndTimeouts() }),
            ("Persistent and worker folder bookmarks", { try await SafetyAndHistoryChecks.bookmarkRoundTrip() }),
            ("Large scan and selection", { try SafetyAndHistoryChecks.volumeAndLimit() }),
            ("Duplicates: content, prefix collisions and hard links", { try AdvancedFeatureChecks.duplicatesAreContentBased() }),
            ("Duplicates: keeper preserved and rechecked", { try await AdvancedFeatureChecks.duplicateMoveRequiresUnchangedKeeper() }),
            ("Duplicates: hash proof and cancellation", { try await AdvancedFeatureChecks.forgedOrChangedDuplicateEvidenceIsRejected() }),
            ("Leftovers: installed apps and reinstall race", { try await AdvancedFeatureChecks.orphanDetectionAndReinstallProtection() }),
            ("Leftovers: restore and incomplete catalog", { try await AdvancedFeatureChecks.orphanMoveRestoreAndIncompleteCatalog() }),
            ("Xcode: generated paths and active builds", { try await AdvancedFeatureChecks.developerScopeAndBusyProtection() }),
            ("Cleanup category boundaries", { try AdvancedFeatureChecks.categoryBoundaries() }),
            ("Shared vendor helpers remain protected", { try AdvancedFeatureChecks.sharedVendorDataIsProtected() }),
            ("Duplicate worker across folders", { try await AdvancedFeatureChecks.duplicateWorkerAcrossRoots() }),
            ("Directory manifests and nested exclusions", { try UtilityFeatureChecks.directoryManifest() }),
            ("Uninstall and restore whole app and related data", { try await UtilityFeatureChecks.uninstallAndRestore() }),
            ("Uninstall running, changed and Apple app protection", { try await UtilityFeatureChecks.uninstallGuards() }),
            ("Previously observed human-named leftovers", { try await UtilityFeatureChecks.humanNamedOrphans() }),
            ("Whole backups, restoration and disk map", { try await UtilityFeatureChecks.backupsAndMap() }),
            ("Simulator commands and running device recheck", { try UtilityFeatureChecks.simulatorCommands() }),
            ("Local Docker scope and daemon recheck", { try UtilityFeatureChecks.dockerCommands() }),
            ("Managed action durable audit and corruption guard", { try await UtilityFeatureChecks.managedAudit() }),
            ("Isolated disk map worker", { try await UtilityFeatureChecks.utilityWorker() }),
            ("Sandbox UTM packages and whole VM restore", { try await ApplicationDiscoveryChecks.sandboxVMs() }),
            ("Relocated UTM registry and cleanup ordering", { try await ApplicationDiscoveryChecks.relocatedRegistryAndOrdering() }),
            ("UTM modern and legacy registry boundaries", { try ApplicationDiscoveryChecks.registryFormatsAndSharedPaths() }),
            ("Stale VM registry and headless activity protection", { try await ApplicationDiscoveryChecks.staleRegistryAndRunningProtection() }),
            ("Expanded Library and extension container data", { try await ApplicationDiscoveryChecks.expandedLibraryAndExtensionContainers() }),
            ("Missing, denied and symlinked app data", { try ApplicationDiscoveryChecks.missingDeniedAndSymlinkLocations() }),
            ("Entitlement groups and shared ownership recheck", { try await ApplicationDiscoveryChecks.sharedGroupsRespectOtherApps() }),
            ("Blocked app source preserves partial results", { try await ApplicationDiscoveryChecks.partialWorkerSurvivesTimeout() }),
            ("Tool cache scope, history and restoration", { try await JunkCoverageChecks.toolCacheLifecycle() }),
            ("Nested tool cache categories and active process recheck", { try await JunkCoverageChecks.nestedAndBusyCaches() }),
            ("Sandbox and shared group cache ownership", { try await JunkCoverageChecks.sandboxCaches() }),
            ("Orphan container trees and whole VM restoration", { try await JunkCoverageChecks.orphanLifecycle() }),
            ("Orphan tree mutation, exclusion, activity and reinstall guards", { try await JunkCoverageChecks.orphanGuards() }),
            ("Orphan shared owners and partial tree preservation", { try await JunkCoverageChecks.orphanGroupsAndPartialTrees() }),
            ("Expanded Library leftover roots", { try await JunkCoverageChecks.expandedLeftovers() }),
            ("Explicit custom app data and worker bookmarks", { try await JunkCoverageChecks.manualLifecycle() }),
            ("Custom data authorization and legacy compatibility", { try JunkCoverageChecks.manualGuardsAndCompatibility() }),
            ("Tree limits, cache links and unrecorded signed group owner", { try JunkCoverageChecks.limitsLinksAndUnrecordedGroupOwner() }),
            ("Cancelled and limited scans account for every requested root", { try await ReleaseReadinessChecks.cancellationListsEveryRoot() }),
            ("Unreadable parents never imply absent apps or leftovers", { try ReleaseReadinessChecks.unreadableParentsAreNotAbsence() }),
            ("Portable scan report, privacy and streaming deduplication", { try ReleaseReadinessChecks.portableMetadataReport() }),
            ("Links and protected files cannot hide sibling caches, manifests or VMs", { try ReleaseReadinessChecks.linksDoNotHideSiblingTrees() })
        ]
        var failures = 0
        for (name, check) in checks {
            try suite.setUpWithError()
            do { try await check(); print("PASS  " + name) }
            catch { failures += 1; print("FAIL  \(name): \(error)") }
            try suite.tearDownWithError()
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        if failures > 0 { exit(1) }
    }
}
