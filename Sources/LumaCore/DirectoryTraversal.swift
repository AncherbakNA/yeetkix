import Foundation

enum DirectoryTraversal {
    static func skipDirectory(_ url: URL, in enumerator: FileManager.DirectoryEnumerator) {
        // Foundation never follows symbolic links. skipDescendants applies to the
        // last directory, so calling it for a file/link can hide sibling folders.
        guard let identity = FileIdentity.read(url), !identity.isRegular, !identity.isSymbolicLink,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        enumerator.skipDescendants()
    }
}
