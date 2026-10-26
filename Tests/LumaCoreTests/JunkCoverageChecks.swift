import Foundation
import Darwin
import LumaCore

enum JunkCoverageChecks {
    static func policy(_ f: Fixture, known: [KnownApplication] = []) -> SafetyPolicy {
        var result = SafetyPolicy(applicationRoots: [f.home.appendingPathComponent("Applications")], checkRegisteredApplications: false, knownApplications: known)
        result.activeProcesses = []
        return result
    }
    static func scan(_ f: Fixture, scope: ScanScope, policy: SafetyPolicy, roots: [ScanRoot]? = nil, limit: Int = 250_000) throws -> ScanReport {
        try DiskScanner(home: f.home, entryLimit: limit, scope: scope, policy: policy, roots: roots).scan()
    }
    static func refuse(_ item: FileItem, _ f: Fixture, _ policy: SafetyPolicy) throws {
        do { try policy.validate(item, home: f.home, minimumAgeDays: 14); throw CheckFailure(message: "Unsafe item accepted: " + item.id) }
        catch { try expect(error is SafetyError, "Expected a safety refusal") }
    }
    static func toolCacheLifecycle() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let paths = [".npm/_cacache/content-v2/owned", "Library/Caches/pnpm/v11/metadata/owned.jsonl", "Library/Caches/pip/http-v2/owned", "Library/Caches/Yarn/v6/owned", "Library/Caches/Homebrew/downloads/owned", ".cargo/registry/cache/index/owned.crate"]
        for path in paths { try f.file(path) }
        let secrets = try f.file(".npmrc", text: "fixture token")
        let cargo = try f.file(".cargo/credentials.toml", text: "fixture token")
        let fresh = try f.file(".npm/_cacache/content-v2/fresh", days: 0)
        let uv = try f.file(".cache/uv/archive-v0/owned")
        let p = policy(f)
        let report = try scan(f, scope: .toolCaches, policy: p)
        try expect(report.items.count == paths.count && report.items.allSatisfy { $0.category == .toolCaches && $0.cleanupRoot != nil }, "All explicit tool cache paths found with independent root evidence")
        let service = try f.service(); let result = await service.move(report.items, policy: p, minimumAgeDays: 14)
        try expect(result.failures.isEmpty && result.moved.count == paths.count, "Only owned cache fixtures move")
        let restarted = try f.service()
        for entry in result.moved { _ = try await restarted.restore(entry.id) }
        for path in paths { try expect(try String(contentsOf: f.home.appendingPathComponent(path)) == "Disposable test data", "Tool cache restores") }
        for item in [secrets, cargo, fresh, uv] { try expect(FileIdentity.read(item.url) == item.identity, "Credentials, recent files and uv internal cache remain untouched") }
    }
    static func nestedAndBusyCaches() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        try f.file("Library/Caches/pip/http-v2/old")
        try f.file(".npm/_cacache/content-v2/old")
        try f.file("Library/Caches/pnpm/v11/metadata/old.jsonl")
        let p = policy(f)
        let report = try scan(f, scope: .cleanup, policy: p)
        try expect(report.items.count == 3 && Set(report.items.map(\.id)).count == 3 && report.items.allSatisfy { $0.category == .toolCaches }, "Nested Library caches keep their category and appear once")
        let item = try require(report.items.first { $0.cleanupRoot == ".npm/_cacache" }, "npm item")
        var busy = p; busy.activeProcesses = ["node", "python3"]
        let blocked = try scan(f, scope: .toolCaches, policy: busy)
        try expect(blocked.items.isEmpty && blocked.roots.contains { $0.status == .protected }, "Live tools protect their caches")
        let service = try f.service(); let counter = LockedCounter(); let late = busy
        let result = await service.move([item], policy: p, minimumAgeDays: 14, policyProvider: { counter.next() >= 2 ? late : p })
        try expect(result.moved.isEmpty && result.failures.count == 1, "Tool activity is rechecked after journal intent")
        let nested = try require(report.items.first { $0.cleanupRoot == "Library/Caches/pip" }, "macOS pip cache")
        try refuse(FileItem(url: nested.url, bytes: nested.bytes, modified: nested.modified, category: .cache), f, p)
        try refuse(FileItem(url: item.url, bytes: item.bytes, modified: item.modified, category: .toolCaches, cleanupRoot: ".npm"), f, p)
        var unknown = p; unknown.activeProcesses = nil
        try refuse(item, f, unknown)
    }
    static func sandboxCaches() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let owner = KnownApplication(bundleID: "test.sandbox.primary", names: ["Owned app"], containerIDs: ["test.sandbox.primary.extension"], groupIDs: ["group.test.shared"])
        let peer = KnownApplication(bundleID: "test.peer.secondary", names: [], groupIDs: ["group.test.shared"])
        let cache = try f.file("Library/Containers/test.sandbox.primary.extension/Data/Library/Caches/owned")
        try f.file("Library/Containers/test.sandbox.primary/Data/Library/Logs/owned")
        try f.file("Library/Group Containers/group.test.shared/Library/Caches/owned")
        let documents = try f.file("Library/Containers/test.sandbox.primary/Data/Documents/keep")
        let p = policy(f, known: [owner, peer])
        let report = try scan(f, scope: .cleanup, policy: p)
        try expect(report.items.count == 3, "Extension, main and group caches found without personal documents")
        var busy = p; busy.runningApplications = [RunningApplication(bundleID: peer.bundleID, name: "Peer")]
        let active = try scan(f, scope: .cleanup, policy: busy)
        try expect(active.items.count == 2 && !active.items.contains { $0.url.path.contains("Group Containers") }, "Any running group owner protects the shared cache")
        let service = try f.service(); let result = await service.move(report.items, policy: p, minimumAgeDays: 14)
        try expect(result.moved.count == 3 && result.failures.isEmpty, "Synthetic container cache cleanup succeeds")
        for entry in result.moved { _ = try await service.restore(entry.id) }
        try expect(FileIdentity.read(documents.url) == documents.identity && FileIdentity.read(cache.url) != nil, "Documents preserved and caches restored")
        let roots = JunkCatalog.appCaches([KnownApplication(bundleID: "com.apple.test", names: []), KnownApplication(bundleID: "local.luma.cleaner", names: [])])
        try expect(roots.isEmpty, "Apple and cleaner containers never enter the cache catalog")
    }
    static func orphanLifecycle() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let id = "test.orphan.virtualizer"
        let vm = try ApplicationDiscoveryChecks.vm(f, "Library/Containers/\(id)/Data/Documents/Owned.utm")
        try f.file("Library/Containers/\(id)/Data/Library/Application Support/owned")
        let p = policy(f, known: [KnownApplication(bundleID: id, names: [])])
        let report = try scan(f, scope: .leftovers, policy: p)
        try expect(report.items.count == 2 && report.items.allSatisfy { $0.isDirectory && $0.directoryEvidence != nil && $0.orphanEvidence?.containsPersonalData == true }, "Orphan documents and support found as reviewed whole trees")
        let service = try f.service(); let moved = await service.move(report.items, policy: p, minimumAgeDays: 14)
        try expect(moved.moved.count == 2 && moved.failures.isEmpty, "Synthetic orphan trees move without flattening VM packages")
        let restarted = try f.service()
        for entry in moved.moved { _ = try await restarted.restore(entry.id) }
        try expect(try String(contentsOf: vm.appendingPathComponent("Data/disk.qcow2")) == "only synthetic VM bytes", "VM contents restore from durable orphan history")
    }
    static func orphanGuards() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let id = "test.ghost.app"
        let data = try f.file("Library/Containers/\(id)/Data/Documents/Owned/data")
        let p = policy(f)
        let initial = try scan(f, scope: .leftovers, policy: p)
        let item = try require(initial.items.first, "Orphan detected without prior observations")
        try Data("changed fixture".utf8).write(to: data.url)
        try refuse(item, f, p)
        let current = try require(scan(f, scope: .leftovers, policy: p).items.first, "Refreshed orphan")
        var busy = p; busy.runningApplications = [RunningApplication(bundleID: id, name: "Ghost")]
        let service = try f.service(); let calls = LockedCounter(); let running = busy
        let blocked = await service.move([current], policy: p, minimumAgeDays: 14, policyProvider: { calls.next() >= 3 ? running : p })
        try expect(blocked.moved.isEmpty && blocked.failures.count == 1, "Orphan activity checked after long tree walk")
        var excluded = p; excluded.excludedPaths = [data.id]
        try refuse(current, f, excluded)
        _ = try UtilityFeatureChecks.app(f, id: id, name: "Reinstalled ghost")
        try refuse(current, f, p)
        try expect(try scan(f, scope: .leftovers, policy: p).items.isEmpty, "Reinstalled container is protected")
        let limited = try scan(f, scope: .leftovers, policy: busy, limit: 1)
        try expect(limited.items.isEmpty, "Small budgets cannot expose unchecked trees")
    }
    static func orphanGroupsAndPartialTrees() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let group = "group.test.orphan"
        let a = KnownApplication(bundleID: "test.absent.first", names: [], groupIDs: [group])
        let b = KnownApplication(bundleID: "test.other.second", names: [], groupIDs: [group])
        let keep = try f.file("Library/Group Containers/\(group)/Data/Excluded/keep")
        try f.file("Library/Group Containers/\(group)/Data/Available/old")
        try f.file("Library/Group Containers/group.test.unknown/keep")
        let p = policy(f, known: [a, b])
        var partial = p; partial.excludedPaths = [keep.id]
        let report = try scan(f, scope: .leftovers, policy: partial)
        try expect(report.items.count == 1 && report.items[0].url.path.contains("Available"), "Nested exclusion preserves safe siblings without selecting its ancestor")
        try expect(report.items[0].orphanEvidence?.ownerIDs == [a.bundleID, b.bundleID], "All recorded group owners retained in proof")
        let service = try f.service(); let moved = await service.move(report.items, policy: partial, minimumAgeDays: 14)
        try expect(moved.moved.count == 1 && FileIdentity.read(keep.url) == keep.identity, "Only unexcluded fixture subtree moves")
        _ = try await service.restore(try require(moved.moved.first, "Group history").id)
        _ = try UtilityFeatureChecks.app(f, id: b.bundleID, name: "Installed group peer")
        try refuse(report.items[0], f, partial)
        try expect(try scan(f, scope: .leftovers, policy: partial).items.isEmpty, "Installed peer protects shared orphan data")
    }
    static func expandedLeftovers() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let id = "test.removed.editor"
        let paths = ["Library/HTTPStorages/\(id)/old", "Library/WebKit/\(id)/old", "Library/Application Scripts/\(id)/old", "Library/Cookies/\(id).binarycookies", "Library/Preferences/ByHost/\(id).\(UUID().uuidString).plist"]
        for path in paths { try f.file(path) }
        let protected = try f.file("Library/Preferences/ByHost/\(id).not-a-uuid.plist")
        let p = policy(f)
        let report = try scan(f, scope: .leftovers, policy: p)
        try expect(Set(report.items.map(\.id)).count == paths.count && report.items.allSatisfy { $0.leftoverBundleID == id }, "HTTP, WebKit, scripts, cookies and valid ByHost leftovers found")
        let service = try f.service(); let moved = await service.move(report.items, policy: p, minimumAgeDays: 14)
        try expect(moved.moved.count == paths.count && moved.failures.isEmpty, "Expanded leftovers validate and move")
        for entry in moved.moved { _ = try await service.restore(entry.id) }
        try expect(FileIdentity.read(protected.url) == protected.identity, "Ambiguous ByHost data left untouched")
    }
    static func manualLifecycle() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let app = try UtilityFeatureChecks.app(f)
        let data = try f.file("Documents/ChatGPT/Specific App Data/deep/owned", text: "only manual fixture")
        let root = data.url.deletingLastPathComponent().deletingLastPathComponent()
        let binding = ManualAssociation(bundleID: app.bundleID, url: root, identity: try require(FileIdentity.read(root), "Manual root"), bookmark: try root.bookmarkData(options: []))
        var p = policy(f); p.manualAssociations = [binding]
        p.runningApplications = [RunningApplication(bundleID: "com.openai.codex", name: "ChatGPT")]
        let sources = ApplicationDiscovery.plan(app, home: f.home, manualAssociations: [binding])
        let source = try require(sources.first { $0.kind == .manual }, "Saved manual source")
        let item = try require(ApplicationDiscovery.scan(source, app: app, home: f.home, policy: p).items.first, "Manual data reviewed")
        try expect(item.applicationEvidence?.location?.sensitive == true, "Explicit additions are always marked as personal data")
        let service = try f.service(); let moved = await service.move([item], policy: p, minimumAgeDays: 14)
        try expect(moved.moved.count == 1 && moved.failures.isEmpty, "Explicitly bound fixture folder moves")
        _ = try await service.restore(try require(moved.moved.first, "Manual history").id)
        try expect(try String(contentsOf: data.url) == "only manual fixture", "Explicit data restores exactly")
        let decoded = try JSONDecoder().decode(WorkerRequest.self, from: JSONEncoder().encode(WorkerRequest(home: f.home, roots: [], policy: p)))
        try expect(decoded.policy.manualAssociations?.first?.bookmark == binding.bookmark, "Binding and bookmark survive worker IPC")
    }
    static func manualGuardsAndCompatibility() throws {
        let f = try Fixture(); defer { try? f.remove() }
        let app = try UtilityFeatureChecks.app(f)
        let file = try f.file("Custom/one")
        let binding = ManualAssociation(bundleID: app.bundleID, url: file.url, identity: file.identity!, bookmark: Data())
        let source = try require(ApplicationDiscovery.plan(app, home: f.home, manualAssociations: [binding]).first { $0.kind == .manual }, "Manual source")
        let p = policy(f)
        do { _ = try ApplicationDiscovery.scan(source, app: app, home: f.home, policy: p); throw CheckFailure(message: "Unbound source accepted") }
        catch { try expect(error is SafetyError, "Backend requires the saved explicit association") }
        var authorized = p; authorized.manualAssociations = [binding]
        let item = try require(ApplicationDiscovery.scan(source, app: app, home: f.home, policy: authorized).items.first, "Authorized item")
        try FileManager.default.moveItem(at: file.url, to: f.home.appendingPathComponent("Custom/original"))
        try f.file("Custom/one", text: "replacement")
        try refuse(item, f, authorized)
        for path in ["", "Documents", "Library", "Library/Containers", ".ssh", ".ssh/key", "Library/Keychains/key", "Library/Mail/data", ".aws/credentials", "Applications/Other.app/Contents/data"] {
            try expect(!ManualAssociation.allowed(f.home.appendingPathComponent(path), home: f.home), "Broad roots and secrets cannot be bound: " + path)
        }
        let legacy = try JSONDecoder().decode(KnownApplication.self, from: Data("{\"bundleID\":\"test.legacy.app\",\"names\":[\"Legacy\"]}".utf8))
        try expect(legacy.containerIDs == nil && legacy.groupIDs == nil, "Existing app observations decode without a migration")
        let live = try f.file("Library/Caches/ChatGPT/active")
        let liveBinding = ManualAssociation(bundleID: app.bundleID, url: live.url, identity: live.identity!, bookmark: Data())
        authorized.manualAssociations = [liveBinding]
        authorized.runningApplications = [RunningApplication(bundleID: "com.openai.codex", name: "ChatGPT")]
        let liveSource = try require(ApplicationDiscovery.plan(app, home: f.home, manualAssociations: [liveBinding]).first { $0.kind == .manual }, "Live cache source")
        let liveItem = try require(ApplicationDiscovery.scan(liveSource, app: app, home: f.home, policy: authorized).items.first, "Explicit live cache review")
        try refuse(liveItem, f, authorized)
    }
    static func limitsLinksAndUnrecordedGroupOwner() throws {
        let f = try Fixture(); defer { try? f.remove() }
        try f.file("Library/Containers/test.absent.owner/Data/Documents/deep/one")
        let p = policy(f)
        let limited = try scan(f, scope: .leftovers, policy: p, roots: [ScanRoot(relativePath: "Library/Containers", category: .leftovers, home: f.home)], limit: 1)
        try expect(limited.truncated && limited.items.isEmpty && limited.roots.first?.status == .limited, "An incomplete tree is never offered as a complete directory")
        try f.file("Outside/data")
        try FileManager.default.createDirectory(at: f.home.appendingPathComponent(".npm"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.home.appendingPathComponent(".npm/_cacache"), withDestinationURL: f.home.appendingPathComponent("Outside"))
        let linked = try scan(f, scope: .toolCaches, policy: p)
        try expect(linked.items.isEmpty && linked.roots.first { $0.root.relativePath == ".npm/_cacache" }?.status == .denied, "Cache root links do not expose their targets")
        let group = "group.test.unrecorded"
        try f.file("Library/Group Containers/\(group)/owned")
        let owner = KnownApplication(bundleID: "test.vanished.owner", names: [], groupIDs: [group])
        let known = policy(f, known: [owner])
        let candidate = try require(scan(f, scope: .leftovers, policy: known).items.first { $0.orphanEvidence?.groupID == group }, "Initially orphaned group")
        let root = "Applications/Unrecorded Peer.app"
        try ApplicationDiscoveryChecks.plist(f, root + "/Contents/Info.plist", ["CFBundleIdentifier": "org.different.peer", "CFBundleName": "Unrecorded Peer", "CFBundleVersion": "1", "CFBundleExecutable": "fixture"])
        let executable = f.home.appendingPathComponent(root + "/Contents/MacOS/fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let entitlement = try ApplicationDiscoveryChecks.plist(f, "owned-entitlements.plist", ["com.apple.security.application-groups": [group]])
        let signed = try LocalCommand.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", "--entitlements", entitlement.path, f.home.appendingPathComponent(root).path])
        try expect(signed.status == 0, "Own synthetic peer signed")
        try refuse(candidate, f, known)
        try expect(try scan(f, scope: .leftovers, policy: known).items.allSatisfy { $0.orphanEvidence?.groupID != group }, "Current entitlements protect a group even when its installed owner was never recorded")
    }
}
