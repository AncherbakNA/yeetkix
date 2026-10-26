import Foundation

public struct FolderAccess: Sendable {
    public let url: URL
    public let stale: Bool
    private let mustStop: Bool
    public static func bookmark(for url: URL) throws -> Data {
        do { return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
    }
    public static func resolve(_ data: Data) throws -> FolderAccess {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
            return FolderAccess(url: url, stale: stale, mustStop: url.startAccessingSecurityScopedResource())
        } catch {
            // A non-sandboxed local build may use an implicit bookmark.
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale)
            return FolderAccess(url: url, stale: stale, mustStop: true)
        }
    }
    public func workerBookmark() throws -> Data { try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
    public func stop() { if mustStop { url.stopAccessingSecurityScopedResource() } }
}
