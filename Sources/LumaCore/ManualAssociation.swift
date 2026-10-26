import Foundation

public struct ManualAssociation: Codable, Identifiable, Sendable {
    public let id: UUID
    public let bundleID: String
    public let url: URL
    public let identity: FileIdentity
    public let bookmark: Data
    public init(bundleID: String, url: URL, identity: FileIdentity, bookmark: Data) {
        id = UUID(); self.bundleID = bundleID; self.url = url; self.identity = identity; self.bookmark = bookmark
    }
    public static func allowed(_ url: URL, home: URL) -> Bool {
        guard url.isFileURL, !url.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }), ApplicationDiscovery.validSearchRoot(url, home: home),
              !url.pathComponents.contains(".Trash"), !url.pathComponents.contains(".Trashes") else { return false }
        let base = home.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let protected = ["", "Library", "Applications"] + ArtifactPaths.personal + ArtifactPaths.leftoverRoots + ["Library/Containers", "Library/Group Containers", "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Safari"]
        guard !protected.contains(where: { path == base + ($0.isEmpty ? "" : "/" + $0) }) else { return false }
        if path.hasPrefix(base + "/Library/Keychains/") || path.hasPrefix(base + "/Library/Mail/") || path.hasPrefix(base + "/Library/Messages/") { return false }
        for secret in [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".config/gcloud", ".config/gh"] where path == base + "/" + secret || path.hasPrefix(base + "/" + secret + "/") { return false }
        if path.hasPrefix("/Volumes/") && url.pathComponents.count < 4 { return false }
        return true
    }
    public static func usedByRunningApp(_ url: URL, home: URL, policy: SafetyPolicy) -> Bool {
        guard let relative = ArtifactPaths.relative(url, to: home), relative.hasPrefix("Library/") else { return false }
        let parts = relative.split(separator: "/").map(String.init)
        if parts.count >= 3 && ["Containers", "Group Containers"].contains(parts[1]) {
            let owners = policy.knownApplications.filter { app in
                parts[1] == "Containers" ? (app.bundleID == parts[2] || (app.containerIDs ?? []).contains(parts[2])) : (app.groupIDs ?? []).contains(parts[2])
            }.map(\.bundleID)
            if JunkCatalog.activeOwners(owners, policy: policy) { return true }
        }
        return policy.belongsToRunningApp(url, home: home)
    }
    public static func authorized(_ url: URL, appID: String, home: URL, policy: SafetyPolicy) -> Bool {
        guard allowed(url, home: home), let now = FileIdentity.read(url), !now.isSymbolicLink, !policy.isExcluded(url) else { return false }
        return (policy.manualAssociations ?? []).contains { association in
            association.bundleID == appID && association.url.standardizedFileURL.path == url.standardizedFileURL.path && association.identity.sameFile(as: now)
        }
    }
}
