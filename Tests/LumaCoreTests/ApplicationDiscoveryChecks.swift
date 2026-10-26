import Foundation
import Darwin
import LumaCore

enum ApplicationDiscoveryChecks {
    @discardableResult static func plist(_ f: Fixture, _ path: String, _ value: [String: Any]) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        return try f.file(path, text: String(decoding: data, as: UTF8.self)).url
    }
    static func vm(_ f: Fixture, _ path: String, payload: String = "only synthetic VM bytes") throws -> URL {
        try plist(f, path + "/config.plist", ["Backend": "QEMU", "ConfigurationVersion": 4, "Information": ["Name": "Owned VM fixture", "UUID": UUID().uuidString]])
        try f.file(path + "/Data/disk.qcow2", text: payload)
        return f.home.appendingPathComponent(path)
    }
    static func policy(_ f: Fixture) -> SafetyPolicy { SafetyPolicy(applicationRoots: [f.home.appendingPathComponent("Applications")], checkRegisteredApplications: false) }
    static func sandboxVMs() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let app = try UtilityFeatureChecks.app(f, id: "com.utmapp.UTM", name: "Owned UTM fixture")
        let original = try vm(f, "Library/Containers/\(app.bundleID)/Data/Documents/Owned Linux.utm")
        try f.file("Library/Containers/\(app.bundleID)/Data/Library/Caches/fixture.bin")
        let source = try require(ApplicationDiscovery.plan(app, home: f.home).first { $0.kind == .container }, "Container source")
        let result = try ApplicationDiscovery.scan(source, app: app, home: f.home, policy: policy(f))
        let identity = try require(FileIdentity.read(original), "Original synthetic VM identity")
        let machine = try require(result.items.first { $0.identity?.sameFile(as: identity) == true }, "Sandbox VM discovered as one package: \(result.items.map(\.id))")
        try expect(machine.directoryEvidence != nil && machine.applicationEvidence?.location?.sensitive == true, "VM has independent tree proof and explicit personal-data marker")
        try expect(result.items.filter { $0.applicationEvidence?.location?.kind == .virtualMachine }.count == 1, "VM is not flattened into disk files")
        let service = try f.service(); let moved = await service.move([machine], policy: policy(f), minimumAgeDays: 14)
        try expect(moved.moved.count == 1, "Only synthetic whole VM moves")
        _ = try await service.restore(try require(moved.moved.first, "VM history").id)
        try expect(try String(contentsOf: original.appendingPathComponent("Data/disk.qcow2")) == "only synthetic VM bytes", "Whole sandbox VM restores byte-for-byte")
        try f.file("Library/Application Support/UTM/owned.bin")
        let standard = try ApplicationInventory.review(app, home: f.home, policy: policy(f))
        try expect(standard.contains { $0.url.lastPathComponent == "UTM" }, "Known three-letter UTM support directory is included")
    }
    static func relocatedRegistryAndOrdering() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let app = try UtilityFeatureChecks.app(f, id: "com.utmapp.UTM", name: "Owned relocated UTM")
        let machine = try vm(f, "Custom/Relocated VM.utm")
        let registry = try plist(f, "Library/Preferences/\(app.bundleID).plist", ["Registry": [UUID().uuidString: ["Package": ["Path": machine.path], "ExternalDrives": ["shared": ["Path": f.home.appendingPathComponent("Documents/keep.iso").path]], "SharedDirectories": [["Path": f.home.appendingPathComponent("Documents").path]]]]])
        let source = try require(ApplicationDiscovery.plan(app, home: f.home).first { $0.kind == .utmRegistry && $0.url == registry }, "Global registry source")
        let registered = try ApplicationDiscovery.scan(source, app: app, home: f.home, policy: policy(f))
        try expect(registered.sources.count == 1 && registered.sources[0].url == machine, "Only Package is treated as a VM; external/shared files excluded")
        let vmItem = try require(ApplicationDiscovery.scan(registered.sources[0], app: app, home: f.home, policy: policy(f)).items.first, "Relocated VM reviewed")
        let base = try ApplicationInventory.review(app, home: f.home, policy: policy(f))
        let items = base + [vmItem]
        let service = try f.service(); let moved = await service.move(items, policy: policy(f), minimumAgeDays: 14)
        try expect(moved.failures.isEmpty && moved.moved.count == 3, "VM, registry and app all move without dependency failures")
        try expect(moved.moved.first?.originalURL == machine, "VM is validated and moved before its registry")
        for entry in moved.moved.reversed() { _ = try await service.restore(entry.id) }
        try expect(try String(contentsOf: machine.appendingPathComponent("Data/disk.qcow2")) == "only synthetic VM bytes", "Relocated VM restore preserves payload")
        try expect(FileManager.default.fileExists(atPath: registry.path), "Registry restores")
    }
    static func registryFormatsAndSharedPaths() throws {
        let f = try Fixture(); defer { try? f.remove() }
        let path = try vm(f, "Custom/Bookmark VM.utm")
        let bookmark = try path.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let defaultRoot = f.home.appendingPathComponent("Library/Containers/com.utmapp.UTM/Data/Documents")
        let values: [String: Any] = ["Registry": ["modern": ["Package": ["Path": path.path, "Bookmark": bookmark], "SharedDirectories": [["Path": f.home.appendingPathComponent("Documents/NeverTouch.utm").path]], "ExternalDrives": ["drive": ["Path": f.home.appendingPathComponent("Documents/NeverTouch.img").path]]]], "VMList": [["Name": "legacy", "Path": path.path, "Bookmark": bookmark], bookmark, "Legacy.utm", "../../Wrong.utm"]]
        let packages = ApplicationDiscovery.registryPackages(values, defaultRoot: defaultRoot)
        try expect(packages.count == 2 && packages.contains { $0.standardizedFileURL.path == path.standardizedFileURL.path }, "Modern, legacy and bookmark references are supported and deduplicated")
        try expect(packages.contains(defaultRoot.appendingPathComponent("Legacy.utm")), "Legacy relative package is restricted to default storage")
        try expect(!packages.contains { $0.path.contains("NeverTouch") || $0.path.contains("Wrong") }, "Shared directories, attached images and path traversal are excluded")
    }
    static func staleRegistryAndRunningProtection() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let app = try UtilityFeatureChecks.app(f, id: "com.utmapp.UTM", name: "Owned guarded UTM")
        let machine = try vm(f, "Custom/Guarded.utm")
        let registry = try plist(f, "Library/Preferences/\(app.bundleID).plist", ["Registry": ["a": ["Package": ["Path": machine.path]]]])
        let source = ApplicationReviewSource(kind: .utmRegistry, url: registry, ownerID: app.bundleID)
        let references = try ApplicationDiscovery.scan(source, app: app, home: f.home, policy: policy(f))
        let item = try require(ApplicationDiscovery.scan(try require(references.sources.first, "VM source"), app: app, home: f.home, policy: policy(f)).items.first, "VM item")
        try plist(f, "Library/Preferences/\(app.bundleID).plist", ["Registry": [:]])
        let service = try f.service(); let stale = await service.move([item], policy: policy(f), minimumAgeDays: 14)
        try expect(stale.moved.isEmpty && !stale.failures.isEmpty, "Changed registry blocks stale ownership proof")
        var busy = policy(f); busy.virtualMachinesBusy = true
        try expect(ApplicationInventory.protected(app, policy: busy), "Headless VM processes protect UTM even without a GUI window")
        let active = await service.move([item], policy: busy, minimumAgeDays: 14)
        try expect(active.moved.isEmpty && FileManager.default.fileExists(atPath: machine.path), "Active VM data is untouched")
    }
    static func expandedLibraryAndExtensionContainers() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let app = try UtilityFeatureChecks.app(f, id: "test.related.fixture", name: "Owned related fixture")
        for root in ["HTTPStorages", "WebKit", "Application Scripts"] { try f.file("Library/\(root)/\(app.bundleID)/owned.bin") }
        try f.file("Library/Cookies/\(app.bundleID).binarycookies")
        try f.file("Library/Preferences/ByHost/\(app.bundleID).\(UUID().uuidString).plist")
        try f.file("Library/Preferences/ByHost/\(app.bundleID).wrong-owner.plist")
        let base = try ApplicationInventory.review(app, home: f.home, policy: policy(f))
        try expect(base.count == 6 && !base.contains { $0.name.contains("wrong-owner") }, "HTTP, WebKit, scripts, cookies and UUID-qualified ByHost prefs found")
        let extensionID = app.bundleID + ".extension"
        let path = "Applications/Owned related fixture.app/Contents/PlugIns/Owned.appex/Contents/Info.plist"
        try plist(f, path, ["CFBundleIdentifier": extensionID])
        let current = try require(ApplicationInventory.record(app.url), "Updated app metadata")
        try f.file("Library/Containers/\(extensionID)/Data/Documents/owned.txt", text: "owned extension document")
        let plan = ApplicationDiscovery.plan(current, home: f.home)
        let source = try require(plan.first { $0.kind == .container && $0.ownerID == extensionID }, "Extension-specific container")
        let items = try ApplicationDiscovery.scan(source, app: current, home: f.home, policy: policy(f)).items
        try expect(items.count == 1 && items[0].applicationEvidence?.location?.sensitive == true, "Extension documents found with personal-data warning")
        let service = try f.service(); let moved = await service.move(items, policy: policy(f), minimumAgeDays: 14)
        try expect(moved.moved.count == 1, "Verified extension-owned documents can be reviewed and moved")
        _ = try await service.restore(try require(moved.moved.first, "Extension data history").id)
    }
    static func missingDeniedAndSymlinkLocations() throws {
        let f = try Fixture(); defer { try? f.remove() }
        let app = try UtilityFeatureChecks.app(f, id: "com.utmapp.UTM", name: "Owned location fixture")
        let missing = ApplicationReviewSource(kind: .utmFolder, url: f.home.appendingPathComponent("Missing"), ownerID: app.bundleID)
        try expect(try ApplicationDiscovery.scan(missing, app: app, home: f.home, policy: policy(f)).status == .missing, "Missing VM folder is not a permission failure")
        let target = try vm(f, "Keep/Linked.utm")
        let data = f.home.appendingPathComponent("Library/Containers/\(app.bundleID)/Data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("Documents"), withDestinationURL: target.deletingLastPathComponent())
        let source = ApplicationReviewSource(kind: .container, url: data, ownerID: app.bundleID)
        do { _ = try ApplicationDiscovery.scan(source, app: app, home: f.home, policy: policy(f)); throw CheckFailure(message: "Container link followed") }
        catch { try expect(error is SafetyError, "Container Documents symlink is protected") }
        try FileManager.default.removeItem(at: data.appendingPathComponent("Documents")) // Owned symlink only.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: data.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path) }
        do { _ = try ApplicationDiscovery.scan(source, app: app, home: f.home, policy: policy(f)); throw CheckFailure(message: "Unreadable container treated as empty") }
        catch { try expect(!(error is CheckFailure), "Denied container is reported as incomplete, not empty") }
        try expect(try ApplicationInventory.review(app, home: f.home, policy: policy(f)).contains { $0.applicationEvidence?.isBundle == true }, "Unavailable container does not hide separately reviewed app")
    }
    @MainActor static func partialWorkerSurvivesTimeout() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let item = try f.file("Downloads/owned-found.txt")
        var partial = UtilityResult(); partial.items = [item]; partial.partialItems = true
        let json = String(decoding: try JSONEncoder().encode(partial), as: UTF8.self)
        try expect(try JSONDecoder().decode(UtilityResult.self, from: Data(json.utf8)).items.count == 1, "Partial IPC result decodes before the timeout scenario")
        let executable = try f.helper("cat <<'YEETKIX_OWNED_JSON'\n" + json + "\nYEETKIX_OWNED_JSON\nexec sleep 5")
        let coordinator = UtilityCoordinator()
        let result = await coordinator.run(UtilityRequest(job: .applicationReview, home: f.home), executable: executable, timeoutSeconds: 2.5)
        try expect(result.sourceStatus == .timedOut && result.items.map(\.id) == [item.id], "Blocked source preserves already discovered data and exact timeout status: \(String(describing: result.sourceStatus)); \(result.items.map(\.id)); \(result.error ?? "")")
    }
    static func sharedGroupsRespectOtherApps() async throws {
        let f = try Fixture(); defer { try? f.remove() }
        let group = "group.test.yeetkix.owned"
        func signedApp(_ name: String, id: String) throws -> ApplicationRecord {
            let root = "Applications/\(name).app"
            try plist(f, root + "/Contents/Info.plist", ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleVersion": "1", "CFBundleExecutable": "fixture"])
            let executable = f.home.appendingPathComponent(root + "/Contents/MacOS/fixture")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
            let entitlement = try plist(f, name + "-entitlements.plist", ["com.apple.security.application-groups": [group]])
            let appURL = f.home.appendingPathComponent(root)
            let signed = try LocalCommand.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", "--entitlements", entitlement.path, appURL.path])
            guard signed.status == 0 else { throw CheckFailure(message: "Could not sign own fixture: " + signed.text) }
            return try require(ApplicationInventory.record(appURL), "Signed fixture app record")
        }
        let first = try signedApp("FirstOwnedApp", id: "test.owned.first")
        try expect(ApplicationCapabilities.groups(first) == [group], "Groups read from the app's real code-signing entitlements")
        try f.file("Library/Group Containers/\(group)/owned.txt", text: "shared fixture bytes")
        let pipe = f.home.appendingPathComponent("Library/Group Containers/\(group)/owned-pipe")
        try expect(mkfifo(pipe.path, 0o600) == 0, "Disposable named pipe created")
        let source = try require(ApplicationDiscovery.plan(first, home: f.home).first { $0.kind == .groupContainer }, "Entitlement-derived group source")
        let initial = try ApplicationDiscovery.scan(source, app: first, home: f.home, policy: policy(f))
        try expect(initial.items.count == 1 && !initial.notes.isEmpty, "Special object is retained without hiding normal group data")
        let second = try signedApp("SecondOwnedApp", id: "test.owned.second")
        let shared = try ApplicationDiscovery.scan(source, app: first, home: f.home, policy: policy(f))
        try expect(shared.items.isEmpty && !shared.notes.isEmpty, "Shared group is retained while another app declares it")
        let service = try f.service(); let blocked = await service.move(initial.items, policy: policy(f), minimumAgeDays: 14)
        try expect(blocked.moved.isEmpty && !blocked.failures.isEmpty, "Shared ownership is rechecked during cleanup")
        try FileManager.default.removeItem(at: second.url) // Only our signed fixture copy of /usr/bin/true.
        let moved = await service.move(initial.items, policy: policy(f), minimumAgeDays: 14)
        try expect(moved.moved.count == 1, "Exclusively owned synthetic group moves after peer removal")
        _ = try await service.restore(try require(moved.moved.first, "Group history").id)
    }
}
