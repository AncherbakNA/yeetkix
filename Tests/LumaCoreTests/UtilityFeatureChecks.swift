import Foundation
import LumaCore

enum UtilityFeatureChecks {
    static func app(_ f: Fixture, id: String = "test.yeetkix.owned", name: String = "Yeetkix Owned Fixture") throws -> ApplicationRecord {
        let path = "Applications/\(name).app"
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.0"], format: .xml, options: 0)
        try f.file(path + "/Contents/Info.plist", text: String(decoding: data, as: UTF8.self))
        try f.file(path + "/Contents/MacOS/fixture", text: "this is only synthetic test data")
        return try require(ApplicationInventory.record(f.home.appendingPathComponent(path)), "Fixture app metadata")
    }
    static func directoryManifest() throws {
        let f = try Fixture(); defer { try? f.remove() }
        let file = try f.file("Downloads/Tree/deep/data", text: "owned")
        let root = f.home.appendingPathComponent("Downloads/Tree")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: file.url)
        let first = try DirectoryEvidence.capture(root)
        try expect(first == DirectoryEvidence.capture(root), "Manifest is deterministic and links are not traversed")
        try expect(first.bytes == 5 && first.entries == 3, "Tree logical size excludes symlink targets")
        try Data("changed".utf8).write(to: file.url)
        try expect(first != DirectoryEvidence.capture(root), "Nested change invalidates manifest")
        do { _ = try DirectoryEvidence.capture(root, policy: SafetyPolicy(excludedPaths: [file.id])); throw CheckFailure(message: "Nested exclusion allowed") }
        catch { try expect(error is SafetyError, "Nested exclusions block whole-folder cleanup") }
    }
    static func uninstallAndRestore() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let installed = try app(f)
        try f.file("Library/Application Support/\(installed.bundleID)/owned", text: "private fixture data")
        try f.file("Library/Caches/\(installed.name)/owned", text: "cache fixture")
        let policy = SafetyPolicy(applicationRoots: [f.home.appendingPathComponent("Applications")], checkRegisteredApplications: false)
        let reviewed = try ApplicationInventory.review(installed, home: f.home, policy: policy)
        try expect(reviewed.count == 3, "App, exact ID and unambiguous own name are reviewed")
        let service = try f.service(); let outcome = await service.move(reviewed, policy: policy, minimumAgeDays: 14)
        try expect(outcome.moved.count == 3 && outcome.failures.isEmpty, "Related data moves before bundle ownership disappears")
        for event in outcome.moved.reversed() { _ = try await service.restore(event.id) }
        try expect(ApplicationInventory.record(installed.url)?.bundleID == installed.bundleID, "Whole app restores")
        try expect(try String(contentsOf: f.home.appendingPathComponent("Library/Application Support/\(installed.bundleID)/owned")) == "private fixture data", "Related file bytes restore")
        let reopened = try f.service(); let history = await reopened.history(); try expect(history.filter { $0.state == .restored }.count == 3, "Directory history persists")
    }
    static func uninstallGuards() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let installed = try app(f)
        let policy = SafetyPolicy(applicationRoots: [f.home.appendingPathComponent("Applications")], checkRegisteredApplications: false)
        let reviewed = try ApplicationInventory.review(installed, home: f.home, policy: policy)
        let service = try f.service()
        var running = policy; running.runningApplications = [RunningApplication(bundleID: installed.bundleID, name: installed.name)]
        let blocked = await service.move(reviewed, policy: running, minimumAgeDays: 14)
        try expect(blocked.moved.isEmpty, "Running app remains untouched")
        try f.file("Applications/\(installed.name).app/Contents/late-file")
        let changed = await service.move(reviewed, policy: policy, minimumAgeDays: 14)
        try expect(changed.moved.isEmpty && !changed.failures.isEmpty, "Changed nested contents remain untouched")
        let current = try ApplicationInventory.review(installed, home: f.home, policy: policy)
        let calls = LockedCounter()
        let runningPolicy = running
        let lateStart = await service.move(current, policy: policy, minimumAgeDays: 14, policyProvider: {
            calls.next() >= 3 ? runningPolicy : policy
        })
        try expect(lateStart.moved.isEmpty, "Activity is refreshed after the potentially long tree verification")
        let trashed = await service.move(current, policy: policy, minimumAgeDays: 14)
        let event = try require(trashed.moved.first, "Synthetic app moved")
        let trash = try require(event.trashURL, "Synthetic app Trash path")
        try Data("edited fixture".utf8).write(to: trash.appendingPathComponent("Contents/MacOS/fixture"))
        do { _ = try await service.restore(event.id); throw CheckFailure(message: "Tampered directory restored") }
        catch { try expect(error is SafetyError, "Nested tampering in Trash blocks restoration") }
        let apple = try app(f, id: "com.apple.Fixture", name: "Apple Fixture")
        do { _ = try ApplicationInventory.review(apple, home: f.home, policy: policy); throw CheckFailure(message: "System app allowed") }
        catch { try expect(error is SafetyError, "Apple bundles protected") }
    }
    static func humanNamedOrphans() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let installed = try app(f)
        let file = try f.file("Library/Application Support/\(installed.name)/data")
        let policy = SafetyPolicy(applicationRoots: [f.home.appendingPathComponent("Applications")], checkRegisteredApplications: false, knownApplications: [installed.known])
        try expect(try DiskScanner(home: f.home, scope: .leftovers, policy: policy).scan().items.isEmpty, "Observed name of installed app is protected")
        try FileManager.default.removeItem(at: installed.url) // Only the synthetic fixture app.
        let report = try DiskScanner(home: f.home, scope: .leftovers, policy: policy).scan()
        let candidate = try require(report.items.first { $0.id == file.id }, "Previously observed human name found")
        let service = try f.service(); let moved = await service.move([candidate], policy: policy, minimumAgeDays: 14)
        try expect(moved.moved.count == 1, "Observed ownership passes independent mutation check")
        _ = try await service.restore(try require(moved.moved.first, "History").id)
        try expect(try String(contentsOf: file.url) == "Disposable test data", "Named orphan restores")
        let ambiguous = [installed.known, KnownApplication(bundleID: "test.other.fixture", names: installed.names)]
        try expect(ArtifactPaths.leftoverID(file.url, home: f.home, knownApplications: ambiguous) == nil, "Ambiguous human names are protected")
    }
    static func backupsAndMap() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let root = BackupInventory.relativeRoot + "/1234567890abcdef1234567890abcdef12345678"
        let values: [(String, [String: Any])] = [("Info.plist", ["Device Name": "Owned Test iPhone", "Last Backup Date": Date().addingTimeInterval(-40*86400)]), ("Manifest.plist", ["IsEncrypted": true]), ("Status.plist", ["SnapshotState": "finished"])]
        for (file, info) in values {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try f.file(root + "/" + file, text: String(decoding: data, as: UTF8.self))
        }
        try f.file(root + "/00/payload", text: "owned backup data")
        let url = f.home.appendingPathComponent(root)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40*86400)], ofItemAtPath: url.path)
        let copies = try BackupInventory.scan(home: f.home, policy: SafetyPolicy(), minimumAgeDays: 14)
        try expect(copies.count == 1 && copies[0].name == "Owned Test iPhone", "Complete old backup is one object")
        let map = try DiskMapScanner.scan(url)
        try expect(map.bytes == copies[0].bytes && map.children.contains { $0.url.lastPathComponent == "00" && $0.bytes == 17 }, "Map totals agree with whole-backup manifest")
        let limited = try DiskMapScanner.scan(url, limit: 1); try expect(limited.truncated, "Map limit is explicit")
        let beforeMove = try DirectoryEvidence.capture(url)
        try expect(beforeMove == copies[0].directoryEvidence, "Read-only map must not alter backup manifest")
        let service = try f.service(); let moved = await service.move(copies, policy: SafetyPolicy(), minimumAgeDays: 14)
        try expect(moved.moved.count == 1, "Entire backup moves atomically to fixture Trash")
        let trashURL = try require(moved.moved.first?.trashURL, "Trash URL")
        let afterMove = try DirectoryEvidence.capture(trashURL)
        try expect(beforeMove == afterMove, "Directory manifest remains stable after rename, including /var aliases")
        _ = try await service.restore(try require(moved.moved.first, "Backup event").id)
        try expect(try String(contentsOf: url.appendingPathComponent("00/payload")) == "owned backup data", "Backup payload restores")
        let backupRoot = f.home.appendingPathComponent(BackupInventory.relativeRoot)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: backupRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupRoot.path) }
        do { _ = try BackupInventory.scan(home: f.home, policy: SafetyPolicy(), minimumAgeDays: 14); throw CheckFailure(message: "Denied backup root reported empty") }
        catch { try expect(!(error is CheckFailure), "Permission errors are not mistaken for no backups") }
    }
    static func simulatorCommands() throws {
        let id = UUID().uuidString
        let fake = FakeCommands { args in
            if args == ["simctl", "list", "devices", "--json"] { return "{\"devices\":{\"runtime\":[{\"udid\":\"\(id)\",\"name\":\"Owned simulator fixture\",\"isAvailable\":false,\"state\":\"Shutdown\"},{\"udid\":\"\(UUID().uuidString)\",\"isAvailable\":true,\"state\":\"Shutdown\"}]}}" }
            return ""
        }
        let run: CommandExecutor = { _, args in try fake.run(args) }
        let items = try ManagedResources.simulators(run: run)
        try expect(items.count == 1, "Only unavailable shutdown simulators")
        _ = try ManagedResources.remove(items[0], home: URL(fileURLWithPath: "/owned"), run: run)
        try expect(fake.commands.last == ["simctl", "delete", id], "Only reviewed UUID is passed to simctl; no real command executed")
        let active = FakeCommands { _ in "{\"devices\":{\"runtime\":[{\"udid\":\"\(id)\",\"isAvailable\":false,\"state\":\"Booted\"}]}}" }
        do { _ = try ManagedResources.remove(items[0], home: URL(fileURLWithPath: "/owned"), run: { _, args in try active.run(args) }); throw CheckFailure(message: "Running simulator allowed") }
        catch { try expect(error is SafetyError && active.commands.count == 1, "Booted simulator is rechecked and refused") }
    }
    static func dockerCommands() throws {
        let home = URL(fileURLWithPath: "/owned"); let exe = URL(fileURLWithPath: "/fake/docker")
        let id = "sha256:" + String(repeating: "a", count: 64)
        let fake = FakeCommands { args in
            if args == ["context", "show"] { return "desktop-local\n" }
            if args.starts(with: ["context", "inspect"]) { return "[{\"Endpoints\":{\"docker\":{\"Host\":\"unix:///owned/.docker/run/docker.sock\"}}}]" }
            let args = Array(args.dropFirst(2))
            if args.first == "info" { return "fixture-server\n" }
            if args.starts(with: ["image", "ls"]) { return id }
            if args.starts(with: ["image", "inspect"]) { return "[{\"Id\":\"\(id)\",\"RepoTags\":[],\"RepoDigests\":[],\"Size\":1200}]" }
            return ""
        }
        let run: CommandExecutor = { _, args in try fake.run(args) }
        let items = try ManagedResources.docker(home: home, executable: exe, run: run)
        try expect(items.count == 2 && items.contains { $0.kind == .dockerBuildCache }, "Dangling images and bounded old build cache")
        for item in items { _ = try ManagedResources.remove(item, home: home, dockerExecutable: exe, run: run) }
        try expect(fake.commands.contains { $0.suffix(4) == ["image", "rm", "--no-prune", id] }, "Image deletion has no force or parent pruning")
        try expect(fake.commands.contains { $0.suffix(5) == ["builder", "prune", "--filter", "until=168h", "--force"] }, "Build prune has a seven day filter")
        try expect(!fake.commands.flatMap { $0 }.contains("--volumes"), "No volumes are passed to deletion")
        try expect(!ManagedResources.localDockerEndpoint("ssh://remote", home: home) && !ManagedResources.localDockerEndpoint("tcp://127.0.0.1:2375", home: home), "All network Docker endpoints refused")
        let changed = FakeCommands { _ in "another-server" }
        do { _ = try ManagedResources.remove(items[0], home: home, dockerExecutable: exe, run: { _, args in try changed.run(args) }); throw CheckFailure(message: "Changed daemon allowed") }
        catch { try expect(error is SafetyError && changed.commands.count == 1, "Daemon identity is rechecked before mutation") }
        let container = String(repeating: "b", count: 64)
        let stopped = ManagedResource(kind: .dockerContainer, key: container, name: "owned fixture", detail: "", endpoint: "unix:///owned/.docker/run/docker.sock", serverID: "fixture-server", stateToken: "created|start|finish")
        let active = FakeCommands { args in
            if args.contains("info") { return "fixture-server" }
            return "[{\"Id\":\"\(container)\",\"State\":{\"Running\":true,\"Status\":\"running\"}}]"
        }
        do { _ = try ManagedResources.remove(stopped, home: home, dockerExecutable: exe, run: { _, args in try active.run(args) }); throw CheckFailure(message: "Running container allowed") }
        catch { try expect(error is SafetyError && !active.commands.contains { $0.contains("rm") }, "A container started after selection is refused") }
    }
    static func managedAudit() async throws {
        let f = try Fixture(); defer { try? f.remove() }; let id = UUID().uuidString
        let fake = FakeCommands { args in args.contains("list") ? "{\"devices\":{\"runtime\":[{\"udid\":\"\(id)\",\"isAvailable\":false,\"state\":\"Shutdown\"}]}}" : "fixture deleted" }
        let resource = ManagedResource(kind: .simulator, key: id, name: "owned fixture", detail: "runtime", stateToken: "unavailable:Shutdown")
        let store = f.home.appendingPathComponent("state/managed.jsonl")
        let service = ManagedCleanupService(store: store)
        let events = try await service.remove([resource], home: f.home, run: { _, args in try fake.run(args) })
        try expect(events.count == 1 && events[0].state == "Удалено без восстановления", "Managed operation records actual fake command outcome")
        let reopened = ManagedCleanupService(store: store); let history = try await reopened.history()
        try expect(history.count == 1 && history[0].id == events[0].id, "Intent and outcome replay as one audit record")
        try Data("corrupt fixture".utf8).write(to: store)
        let previousCalls = fake.commands.count
        do { _ = try await reopened.remove([resource], home: f.home, run: { _, args in try fake.run(args) }); throw CheckFailure(message: "Corrupt audit allowed deletion") }
        catch { try expect(fake.commands.count == previousCalls, "Corrupt journal blocks commands before any deletion") }
    }
    @MainActor static func utilityWorker() async throws {
        let f = try Fixture(); defer { try? f.remove() }; try f.file("Documents/Owned/fixture", text: "read only")
        let coordinator = UtilityCoordinator()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let result = await coordinator.run(UtilityRequest(job: .diskMap, home: f.home, url: f.home.appendingPathComponent("Documents")), executable: executable)
        try expect(result.error == nil && result.map?.bytes == 9, "Read-only disk map works in isolated process")
    }
}

final class FakeCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private let respond: ([String]) throws -> String
    init(_ respond: @escaping ([String]) throws -> String) { self.respond = respond }
    var commands: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
    func run(_ args: [String]) throws -> CommandOutput { lock.lock(); calls.append(args); lock.unlock(); return CommandOutput(status: 0, text: try respond(args)) }
}
