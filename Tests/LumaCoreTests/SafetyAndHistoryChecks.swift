import Foundation
import LumaCore

final class Fixture: @unchecked Sendable {
    let home: URL
    let store: URL
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("LumaOwnedFixture-" + UUID().uuidString)
        store = home.appendingPathComponent("state/history.json")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
    }
    func remove() throws { try FileManager.default.removeItem(at: home) }
    @discardableResult func file(_ path: String, text: String = "Disposable test data", days: Int = 30) throws -> FileItem {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let date = Date().addingTimeInterval(-Double(days) * 86400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let category: FileCategory = path.hasPrefix("Library/Caches") ? .cache : path.hasPrefix("Library/Logs") ? .logs : .downloads
        return FileItem(url: url, bytes: Int64(text.utf8.count), modified: date, category: category)
    }
    func trash(_ url: URL) throws -> URL {
        let target = home.appendingPathComponent(".Trash/" + UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
    func service() throws -> CleanupService { try CleanupService(home: home, storeURL: store, trashOperation: { [self] in try trash($0) }) }
    func helper(_ body: String) throws -> URL {
        let url = home.appendingPathComponent("worker.sh")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

enum SafetyAndHistoryChecks {
    static func protections() throws {
        let f = try Fixture(); defer { try? f.remove() }
        try f.file("Library/Caches/com.example.editor/a.bin")
        try f.file("Library/Caches/ExampleEditor/b.bin")
        try f.file("Library/Caches/other/database.sqlite")
        try f.file("Library/Caches/other/a.db-wal")
        try f.file("Library/Caches/Codex/cache.bin")
        try f.file("Library/Caches/Excluded/keep.bin")
        let allowed = try f.file("Library/Caches/Excluded-sibling/ok.bin")
        let policy = SafetyPolicy(excludedPaths: [f.home.appendingPathComponent("Library/Caches/Excluded").path],
                                  runningApplications: [RunningApplication(bundleID: "com.example.editor", name: "Example Editor"),
                                                        RunningApplication(bundleID: "com.openai.codex", name: "ChatGPT")])
        let report = try DiskScanner(home: f.home, scope: .cleanup, policy: policy).scan()
        try expect(report.items.map(\.id) == [allowed.id], "Running apps, databases and excluded subtrees are protected without prefix collisions")
        try expect(report.protectedCount >= 5, "Protected objects are counted")
        let fresh = try f.file("Library/Caches/other/fresh", days: 1)
        do { try policy.validate(fresh, home: f.home, minimumAgeDays: 14); throw CheckFailure(message: "Fresh cache allowed") }
        catch { try expect(error is SafetyError, "Fresh cache must be refused") }
    }
    static func changedIdentityAndHardLinks() throws {
        let f = try Fixture(); defer { try? f.remove() }
        let item = try f.file("Downloads/file", text: "original")
        try FileManager.default.moveItem(at: item.url, to: f.home.appendingPathComponent("old-inode"))
        try Data("replaced".utf8).write(to: item.url)
        try FileManager.default.setAttributes([.modificationDate: item.modified], ofItemAtPath: item.url.path)
        do { try SafetyPolicy().validate(item, home: f.home, minimumAgeDays: 14); throw CheckFailure(message: "Replaced inode allowed") }
        catch { try expect(error is SafetyError, "Replacing a file with same size and timestamp is refused") }
        let cache = try f.file("Library/Caches/other/linked")
        try FileManager.default.linkItem(at: cache.url, to: f.home.appendingPathComponent("hard-link"))
        let report = try DiskScanner(home: f.home, scope: .cleanup).scan()
        try expect(report.items.isEmpty, "Hard-linked cache files are protected")
    }
    static func moveRestoreAndPersistence() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let item = try f.file("Downloads/sample.txt")
        let service = try f.service()
        let outcome = await service.move([item, item], policy: SafetyPolicy(), minimumAgeDays: 14)
        try expect(outcome.moved.count == 1 && outcome.failures.isEmpty, "Duplicate selection moves once")
        try expect(!FileManager.default.fileExists(atPath: item.url.path), "Created fixture moved")
        let reloaded = try f.service()
        let records = await reloaded.history()
        try expect(records.count == 1 && records[0].state == .trashed, "History survives restart")
        _ = try await reloaded.restore(records[0].id)
        try expect(try String(contentsOf: item.url) == "Disposable test data", "Exact content restored")
        let restarted = try f.service()
        let restoredHistory = await restarted.history()
        try expect(restoredHistory.first?.state == .restored, "Restored state is durable")
    }
    static func restoreConflictsAndTampering() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let item = try f.file("Downloads/conflict.txt", text: "original")
        let service = try f.service()
        let result = await service.move([item], policy: SafetyPolicy(), minimumAgeDays: 14)
        let record = try require(result.moved.first, "Expected move")
        try Data("new user content".utf8).write(to: item.url)
        do { _ = try await service.restore(record.id); throw CheckFailure(message: "Overwrite allowed") }
        catch { try expect(error is SafetyError, "Conflicting destination refused") }
        try expect(try String(contentsOf: item.url) == "new user content", "Existing destination unchanged")
        try expect(try String(contentsOf: record.trashURL!) == "original", "Trash source unchanged")
        try FileManager.default.removeItem(at: item.url) // Only the conflict fixture just created above.
        try Data("tampered".utf8).write(to: record.trashURL!)
        do { _ = try await service.restore(record.id); throw CheckFailure(message: "Tampered source allowed") }
        catch { try expect(error is SafetyError, "Modified Trash file refused") }
        try expect(!FileManager.default.fileExists(atPath: item.url.path), "No destination created on failed restore")
    }
    static func unavailableRestoreAndSymlinkParent() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let item = try f.file("Downloads/item")
        let service = try f.service()
        let result = await service.move([item], policy: SafetyPolicy(), minimumAgeDays: 14)
        let entry = try require(result.moved.first, "Expected move")
        try FileManager.default.moveItem(at: f.home.appendingPathComponent("Downloads"), to: f.home.appendingPathComponent("Backup"))
        try FileManager.default.createDirectory(at: f.home.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.home.appendingPathComponent("Downloads"), withDestinationURL: f.home.appendingPathComponent("outside"))
        do { _ = try await service.restore(entry.id); throw CheckFailure(message: "Symlink destination allowed") }
        catch { try expect(error is SafetyError, "Changed parent path refused") }
        try expect(FileManager.default.fileExists(atPath: entry.trashURL!.path), "Trash file preserved")
    }
    static func journalFailureAndRecovery() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let item = try f.file("Downloads/keep.txt")
        let blocked = try CleanupService(home: f.home, storeURL: f.store, trashOperation: { try f.trash($0) }, journalWriter: { _, _ in throw SafetyError("Disk full") })
        let refused = await blocked.move([item], policy: SafetyPolicy(), minimumAgeDays: 14)
        try expect(refused.moved.isEmpty && FileManager.default.fileExists(atPath: item.url.path), "Failed intent write prevents move")
        let counter = LockedCounter()
        let interrupted = try CleanupService(home: f.home, storeURL: f.store, trashOperation: { try f.trash($0) }, journalWriter: { data, url in
            if counter.next() == 2 { throw SafetyError("Simulated crash after move") }
            try CleanupService.appendEvent(data, to: url)
        })
        let moved = await interrupted.move([item], policy: SafetyPolicy(), minimumAgeDays: 14)
        try expect(moved.moved.count == 1 && moved.journalWarning != nil, "Post-move journal failure reported")
        let recovered = try f.service()
        let entries = await recovered.history()
        try expect(entries.count == 1 && entries[0].state == .trashed, "Prepared intent reconciled by exact inode")
        _ = try await recovered.restore(entries[0].id)
        try expect(FileManager.default.fileExists(atPath: item.url.path), "Recovered operation can be restored")
    }
    static func perFileFailuresAndCancellation() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let good = try f.file("Downloads/good.txt")
        let bad = try f.file("Downloads/bad.txt")
        let service = try CleanupService(home: f.home, storeURL: f.store, trashOperation: { url in
            if url.lastPathComponent == "bad.txt" { throw SafetyError("Permission denied") }
            return try f.trash(url)
        })
        let result = await service.move([bad, good], policy: SafetyPolicy(), minimumAgeDays: 14)
        try expect(result.moved.count == 1 && result.failures.count == 1, "Failure on one item does not hide successful moves")
        try expect(FileManager.default.fileExists(atPath: bad.url.path), "Denied file unchanged")
        var items: [FileItem] = []
        for i in 0..<20 { items.append(try f.file("Downloads/cancel-\(i)")) }
        let candidates = items
        let task = Task.detached {
            await service.move(candidates, policy: SafetyPolicy(), minimumAgeDays: 14, progress: { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        let cancelled = await task.value
        try expect(cancelled.cancelled && cancelled.moved.count == 1, "Cancellation stops between files")
        try expect(items.filter { FileManager.default.fileExists(atPath: $0.url.path) }.count == 19, "Remaining fixtures untouched")
    }
    static func activeAppRecheck() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let item = try f.file("Library/Caches/com.example.editor/data.bin")
        let service = try f.service()
        let count = LockedCounter()
        let result = await service.move([item], policy: SafetyPolicy(), minimumAgeDays: 14, policyProvider: {
            count.next() == 1 ? SafetyPolicy() : SafetyPolicy(runningApplications: [RunningApplication(bundleID: "com.example.editor", name: "Example Editor")])
        })
        try expect(result.moved.isEmpty && result.failures.count == 1, "App launched after review is rechecked immediately before move")
        try expect(FileManager.default.fileExists(atPath: item.url.path), "Running app data preserved")
    }
    static func corruptHistoryAndTruncatedJournal() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        try FileManager.default.createDirectory(at: f.store.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("not a history document".utf8)
        try corrupt.write(to: f.store)
        do { _ = try f.service(); throw CheckFailure(message: "Corrupt history accepted") }
        catch { try expect(!(error is CheckFailure), "Corrupt history blocks service") }
        try expect(try Data(contentsOf: f.store) == corrupt, "Original corrupt history is not overwritten")
    }
    static func incompleteFirstIntent() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let item = try f.file("Downloads/after-restart")
        try FileManager.default.createDirectory(at: f.store.deletingLastPathComponent(), withIntermediateDirectories: true)
        let journal = f.store.appendingPathExtension("journal")
        try Data("{\"id\":".utf8).write(to: journal)
        let service = try f.service()
        try expect(try Data(contentsOf: journal).isEmpty, "An incomplete first journal line is removed before any new events")
        let moved = await service.move([item], policy: SafetyPolicy(), minimumAgeDays: 14)
        try expect(moved.moved.count == 1, "Next operation succeeds after journal recovery")
        let reloaded = try f.service()
        let history = await reloaded.history()
        try expect(history.count == 1 && history[0].state == .trashed, "Next operation remains readable after restart")
        _ = try await reloaded.restore(history[0].id)
    }
    @MainActor static func scopedWorkersAndTimeouts() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        try f.file("Downloads/visible.txt")
        try f.file("Library/Caches/other/hidden-from-scope")
        let coordinator = ScanCoordinator()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let request = WorkerRequest(home: f.home, roots: ScanScope.downloads.roots(home: f.home), scope: .downloads)
        let result = await coordinator.scan(request, executable: executable) { _ in }
        try expect(result.items.count == 1 && result.items[0].category == .downloads, "Separate worker scans only requested section")
        try expect(result.roots.first?.status == .complete, "Worker finishes and serializes report")
        let slow = try f.helper("exec /bin/sleep 5")
        var two = request; two.roots += ScanScope.trash.roots(home: f.home)
        let timed = await coordinator.scan(two, executable: slow, timeoutSeconds: 0.08) { _ in }
        try expect(timed.roots.count == 2 && timed.roots.allSatisfy { $0.status == .timedOut }, "Timeout skips roots and continues")
        let task = Task { await coordinator.scan(two, executable: slow) { _ in } }
        try await Task.sleep(for: .milliseconds(50)); coordinator.cancel()
        let cancelled = await task.value
        try expect(cancelled.isPartial && cancelled.roots.count == two.roots.count && cancelled.roots.allSatisfy { $0.status == .cancelled }
                   && cancelled.roots.last?.detail?.contains("Не проверена") == true, "Worker cancellation stops the child and marks queued roots as unverified")
        let broken = try f.helper("cat >/dev/null\nprintf 'invalid-json\\n'")
        let failed = await coordinator.scan(request, executable: broken) { _ in }
        try expect(failed.roots.first?.status == .denied, "Broken worker is reported instead of hanging")
    }
    @MainActor static func bookmarkRoundTrip() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        try f.file("Downloads/bookmark-test")
        let root = ScanScope.downloads.roots(home: f.home)[0]
        let saved = try FolderAccess.bookmark(for: root.url)
        let access = try FolderAccess.resolve(saved)
        defer { access.stop() }
        try expect(access.url.standardizedFileURL == root.url.standardizedFileURL, "Persistent bookmark resolves exact folder")
        let request = WorkerRequest(home: f.home, roots: [root], scope: .downloads, bookmarks: [try access.workerBookmark()])
        let coordinator = ScanCoordinator()
        let result = await coordinator.scan(request, executable: URL(fileURLWithPath: CommandLine.arguments[0])) { _ in }
        try expect(result.items.count == 1 && result.roots.first?.status == .complete, "Bookmark transfers to scan worker")
    }
    static func volumeAndLimit() throws {
        let f = try Fixture(); defer { try? f.remove() }
        for i in 0..<5_000 { try f.file("Downloads/\(i)", text: "fixture") }
        let result = try DiskScanner(home: f.home, entryLimit: 6_000, scope: .downloads).scan()
        try expect(result.items.count == 5_000 && !result.truncated, "Five thousand files scanned without loss")
        let limited = try DiskScanner(home: f.home, entryLimit: 2_000, scope: .downloads).scan()
        try expect(limited.items.count == 2_000 && limited.truncated && limited.roots[0].status == .limited, "Global entry limit clearly recorded")
        let duplicated = result.items + result.items
        try expect(TrashSafety.uniqueTopLevelItems(duplicated).count == 5_000, "Large selection deduplication")
    }
}
func require<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw CheckFailure(message: message) }; return value }
