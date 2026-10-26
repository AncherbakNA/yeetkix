import Foundation
import CryptoKit

public struct DuplicateEvidence: Codable, Hashable, Sendable {
    public let sha256: String
    public let keeperURL: URL
    public let keeperIdentity: FileIdentity
    public init(sha256: String, keeperURL: URL, keeperIdentity: FileIdentity) {
        self.sha256 = sha256; self.keeperURL = keeperURL; self.keeperIdentity = keeperIdentity
    }
}
public struct DuplicateGroup: Codable, Identifiable, Sendable {
    public let id: String
    public var files: [FileItem]
    public var reclaimableBytes: Int64 { files.dropFirst().reduce(0) { $0 + $1.bytes } }
}

public enum DuplicateFinder {
    public static func hash(_ item: FileItem, prefixOnly: Bool = false, progress: (Int64) -> Void = { _ in }) throws -> String {
        try Task.checkCancellation()
        guard let identity = item.identity, FileIdentity.read(item.url) == identity, identity.isRegular, !identity.isSymbolicLink else {
            throw SafetyError("Файл изменился перед сравнением")
        }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let values = try item.url.resourceValues(forKeys: keys)
        if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current && values.ubiquitousItemDownloadingStatus != .downloaded {
            throw SafetyError("Облачный файл ещё не загружен: сравнение пропущено")
        }
        let handle = try FileHandle(forReadingFrom: item.url)
        defer { try? handle.close() }
        var digest = SHA256(); var read: Int64 = 0; var lastProgress = Date.distantPast
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: prefixOnly ? 65_536 : 1_048_576) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data); read += Int64(data.count)
            if prefixOnly || read == item.bytes || Date().timeIntervalSince(lastProgress) > 0.2 { progress(read); lastProgress = Date() }
            if prefixOnly { break }
        }
        guard FileIdentity.read(item.url) == identity, prefixOnly || read == item.bytes else { throw SafetyError("Файл изменился во время сравнения") }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func identical(_ first: FileItem, _ second: FileItem, progress: (Int64) -> Void = { _ in }) throws -> Bool {
        guard first.bytes == second.bytes, first.identity != nil, second.identity != nil,
              FileIdentity.read(first.url) == first.identity, FileIdentity.read(second.url) == second.identity else { return false }
        let a = try FileHandle(forReadingFrom: first.url); defer { try? a.close() }
        let b = try FileHandle(forReadingFrom: second.url); defer { try? b.close() }
        var read: Int64 = 0; var lastProgress = Date.distantPast
        while true {
            try Task.checkCancellation()
            let left = try a.read(upToCount: 1_048_576) ?? Data()
            let right = try b.read(upToCount: 1_048_576) ?? Data()
            if left != right { return false }
            if left.isEmpty { break }
            read += Int64(left.count)
            if read == first.bytes || Date().timeIntervalSince(lastProgress) > 0.2 { progress(read); lastProgress = Date() }
        }
        return FileIdentity.read(first.url) == first.identity && FileIdentity.read(second.url) == second.identity
    }
    public static func find(_ candidates: [FileItem], issue: (URL, String) -> Void = { _, _ in },
                            progress: @escaping (Double, String, Int) -> Void = { _, _, _ in }) throws -> [DuplicateGroup] {
        var inodes = Set<String>()
        let unique = candidates.sorted { $0.url.path < $1.url.path }.filter {
            guard $0.bytes > 0, let id = $0.identity else { return false }
            return inodes.insert("\(id.device):\(id.inode)").inserted
        }
        let bySize = Dictionary(grouping: unique, by: \.bytes).values.filter { $0.count > 1 }
        var prefixes: [String: [FileItem]] = [:]
        var done = 0
        let total = max(1, bySize.reduce(0) { $0 + $1.count })
        for files in bySize {
            for item in files {
                try Task.checkCancellation()
                do { let digest = try hash(item, prefixOnly: true); prefixes["\(item.bytes):" + digest, default: []].append(item) }
                catch is CancellationError { throw CancellationError() }
                catch { issue(item.url, error.localizedDescription) }
                done += 1
                progress(Double(done) / Double(total) * 0.3, "Проверяем совпадения размеров", done)
            }
        }
        var fullHashes: [String: [FileItem]] = [:]
        let possible = prefixes.values.filter { $0.count > 1 }.flatMap { $0 }
        for (index, item) in possible.enumerated() {
            try Task.checkCancellation()
            do {
                let digest = try hash(item, progress: { _ in
                progress(0.3 + Double(index) / Double(max(1, possible.count)) * 0.6, "Сравниваем: " + item.name, index)
                })
                fullHashes["\(item.bytes):" + digest, default: []].append(item)
            } catch is CancellationError { throw CancellationError() }
            catch { issue(item.url, error.localizedDescription) }
        }
        var groups: [DuplicateGroup] = []
        for (digest, files) in fullHashes where files.count > 1 {
            let sorted = files.sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified < $1.modified }
            guard let keeper = sorted.first, let identity = keeper.identity else { continue }
            var verified = [keeper]
            for file in sorted.dropFirst() {
                try Task.checkCancellation()
                if (try? identical(keeper, file, progress: { _ in
                    progress(0.95, "Подтверждаем полное совпадение", groups.count)
                })) == true { verified.append(file) }
                progress(0.95, "Подтверждаем полное совпадение", groups.count)
            }
            guard verified.count > 1 else { continue }
            let proof = DuplicateEvidence(sha256: String(digest.split(separator: ":").last ?? ""), keeperURL: keeper.url, keeperIdentity: identity)
            let items = verified.map { FileItem(url: $0.url, bytes: $0.bytes, modified: $0.modified, category: .duplicates, identity: $0.identity, duplicateEvidence: proof) }
            groups.append(DuplicateGroup(id: digest, files: items))
        }
        progress(1, "Дубликаты проверены", candidates.count)
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }
    public static func verifyEvidence(_ item: FileItem) throws {
        guard let proof = item.duplicateEvidence, item.url.standardizedFileURL != proof.keeperURL.standardizedFileURL,
              FileIdentity.read(proof.keeperURL) == proof.keeperIdentity else { throw SafetyError("Исходная копия отсутствует или изменилась") }
        let keeper = FileItem(url: proof.keeperURL, bytes: proof.keeperIdentity.bytes, modified: .distantPast, category: .duplicates, identity: proof.keeperIdentity)
        guard try hash(item) == proof.sha256, try hash(keeper) == proof.sha256, try identical(item, keeper) else { throw SafetyError("Содержимое копий больше не совпадает") }
    }
}
