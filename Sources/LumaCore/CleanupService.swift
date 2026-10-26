import Foundation
import Darwin

public enum HistoryState: String, Codable, Sendable {
    case prepared, trashed, restoring, restored, failed, needsReview
    public var title: String {
        switch self {
        case .prepared, .restoring: return "Операция прервана"
        case .trashed: return "В Корзине"
        case .restored: return "Восстановлен"
        case .failed: return "Не перемещён"
        case .needsReview: return "Проверить в Finder"
        }
    }
}
public struct HistoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let batchID: UUID
    public let originalURL: URL
    public let originalIdentity: FileIdentity
    public let bytes: Int64
    public let date: Date
    public var trashURL: URL?
    public var trashIdentity: FileIdentity?
    public var state: HistoryState
    public var error: String?
    public var restoredAt: Date?
    public var category: FileCategory? = nil
    public var directoryEvidence: DirectoryEvidence? = nil
    public var applicationEvidence: ApplicationEvidence? = nil
    public var cleanupRoot: String? = nil
    public var orphanEvidence: OrphanEvidence? = nil
    public var name: String { originalURL.lastPathComponent }
}
public struct CleanupFailure: Sendable {
    public let id: String
    public let name: String
    public let message: String
}
public struct CleanupOutcome: Sendable {
    public var moved: [HistoryEntry] = []
    public var failures: [CleanupFailure] = []
    public var cancelled = false
    public var journalWarning: String?
}
private struct HistoryDocument: Codable {
    var version = 1
    var entries: [HistoryEntry]
}

/// Serializes mutations. Each file has a durable intent record before it is moved.
public actor CleanupService {
    private let home: URL
    private let storeURL: URL
    private let trashOperation: @Sendable (URL) throws -> URL
    private let writer: @Sendable (Data, URL) throws -> Void
    private let journalWriter: @Sendable (Data, URL) throws -> Void
    private var entries: [HistoryEntry]
    private var operationInProgress = false
    private var journalHealthy = true

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, storeURL: URL,
                trashOperation: @escaping @Sendable (URL) throws -> URL = { try CleanupService.systemTrash($0) },
                writer: @escaping @Sendable (Data, URL) throws -> Void = { try CleanupService.atomicWrite($0, to: $1) },
                journalWriter: @escaping @Sendable (Data, URL) throws -> Void = { try CleanupService.appendEvent($0, to: $1) }) throws {
        self.home = home; self.storeURL = storeURL; self.trashOperation = trashOperation; self.writer = writer; self.journalWriter = journalWriter
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let document = try JSONDecoder().decode(HistoryDocument.self, from: Data(contentsOf: storeURL))
            guard document.version == 1 else { throw SafetyError("Неизвестная версия журнала очистки") }
            guard Set(document.entries.map(\.id)).count == document.entries.count else { throw SafetyError("В журнале повторяются идентификаторы операций") }
            self.entries = document.entries
        } else { self.entries = [] }
        let journal = storeURL.appendingPathExtension("journal")
        if FileManager.default.fileExists(atPath: journal.path) {
            let data = try Data(contentsOf: journal)
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            var positions = Dictionary(uniqueKeysWithValues: self.entries.enumerated().map { ($0.element.id, $0.offset) })
            for (index, line) in lines.enumerated() {
                do {
                    let record = try JSONDecoder().decode(HistoryEntry.self, from: Data(line))
                    if let existing = positions[record.id] { self.entries[existing] = record }
                    else { positions[record.id] = self.entries.count; self.entries.append(record) }
                } catch {
                    guard index == lines.count - 1, data.last != 0x0A else { throw SafetyError("Повреждён журнал операций. Исходный журнал сохранён.") }
                }
            }
        }
        // Resolve interrupted writes without changing any user files.
        for index in self.entries.indices {
            let entry = self.entries[index]
            guard entry.state == .prepared || entry.state == .restoring else { continue }
            if let original = FileIdentity.read(entry.originalURL), entry.originalIdentity.sameFile(as: original) {
                self.entries[index].state = entry.state == .restoring ? .restored : .failed
            } else if let trash = entry.trashURL, let identity = FileIdentity.read(trash),
                      entry.trashIdentity?.sameFile(as: identity) == true {
                self.entries[index].state = .trashed
            } else {
                // Finder may rename an item when it enters Trash. Locate only the exact inode.
                let candidates = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(".Trash"),
                                  includingPropertiesForKeys: nil)) ?? []
                if let found = candidates.first(where: { url in
                    guard let identity = FileIdentity.read(url) else { return false }
                    return entry.originalIdentity.sameFile(as: identity)
                }) {
                    self.entries[index].trashURL = found
                    self.entries[index].trashIdentity = FileIdentity.read(found)
                    self.entries[index].state = .trashed
                } else {
                    self.entries[index].state = .needsReview
                    self.entries[index].error = "Операция прервалась. Проверьте исходную папку и Корзину в Finder."
                }
            }
        }
        if !self.entries.isEmpty || FileManager.default.fileExists(atPath: journal.path) {
            let data = try JSONEncoder().encode(HistoryDocument(entries: self.entries))
            try writer(data, storeURL)
            try writer(Data(), journal)
        }
    }
    public static func appendEvent(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SafetyError("Не удалось создать журнал") }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func systemTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw SafetyError("Finder не вернул расположение файла в Корзине") }
        return result as URL
    }
    public func history() -> [HistoryEntry] { entries.sorted { $0.date > $1.date } }
    private func saveEntry(_ index: Int) throws {
        var data = try JSONEncoder().encode(entries[index]); data.append(0x0A)
        do { try journalWriter(data, storeURL.appendingPathExtension("journal")) }
        catch { journalHealthy = false; throw error }
    }
    private func compact() throws {
        try writer(JSONEncoder().encode(HistoryDocument(entries: entries)), storeURL)
        try writer(Data(), storeURL.appendingPathExtension("journal"))
    }

    public func move(_ items: [FileItem], policy: SafetyPolicy, minimumAgeDays: Int,
                     policyProvider: (@Sendable () async -> SafetyPolicy)? = nil,
                     progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> CleanupOutcome {
        var outcome = CleanupOutcome()
        guard !operationInProgress, journalHealthy else {
            outcome.journalWarning = "Журнал занят или недоступен. Файлы оставлены на месте."
            return outcome
        }
        operationInProgress = true
        defer { operationInProgress = false }
        let batch = UUID()
        // Keep the installed app available for ownership checks until its related data is moved.
        let unique = TrashSafety.uniqueTopLevelItems(items).sorted {
            func priority(_ item: FileItem) -> Int {
                if item.applicationEvidence?.location?.kind == .virtualMachine { return 0 }
                return item.applicationEvidence?.isBundle == true ? 2 : 1
            }
            return priority($0) < priority($1)
        }
        for (index, item) in unique.enumerated() {
            if Task.isCancelled { outcome.cancelled = true; break }
            let livePolicy = await policyProvider?() ?? policy
            do {
                try livePolicy.validate(item, home: home, minimumAgeDays: minimumAgeDays)
                if item.category == .duplicates { try DuplicateFinder.verifyEvidence(item) }
            }
            catch { outcome.failures.append(CleanupFailure(id: item.id, name: item.name, message: error.localizedDescription)); continue }
            guard let identity = item.identity else { continue }
            let record = HistoryEntry(id: UUID(), batchID: batch, originalURL: item.url, originalIdentity: identity,
                                      bytes: item.bytes, date: Date(), state: .prepared, category: item.category,
                                      directoryEvidence: item.directoryEvidence, applicationEvidence: item.applicationEvidence,
                                      cleanupRoot: item.cleanupRoot, orphanEvidence: item.orphanEvidence)
            entries.append(record)
            let position = entries.count - 1
            do { try saveEntry(position) }
            catch {
                entries.removeLast()
                outcome.failures.append(CleanupFailure(id: item.id, name: item.name, message: "Не удалось сохранить журнал. Файл оставлен на месте."))
                break
            }
            do {
                // Check again after the intent write, immediately before the filesystem operation.
                let finalPolicy = await policyProvider?() ?? livePolicy
                try finalPolicy.validate(item, home: home, minimumAgeDays: minimumAgeDays)
                if item.category == .applications || item.category == .backups {
                    // A tree walk may be long. Refresh app activity after it, before moving.
                    let immediatePolicy = await policyProvider?() ?? finalPolicy
                    try ReviewedArtifactSafety.validate(item, home: home, policy: immediatePolicy, minimumAgeDays: minimumAgeDays, checkTree: false)
                } else if item.orphanEvidence != nil {
                    let immediatePolicy = await policyProvider?() ?? finalPolicy
                    try JunkCatalog.validateOrphan(item, home: home, policy: immediatePolicy, checkTree: false)
                }
                let trashURL = try trashOperation(item.url)
                entries[position].trashURL = trashURL
                entries[position].trashIdentity = FileIdentity.read(trashURL)
                entries[position].state = .trashed
                outcome.moved.append(entries[position])
            } catch {
                entries[position].state = .failed; entries[position].error = error.localizedDescription
                outcome.failures.append(CleanupFailure(id: item.id, name: item.name, message: error.localizedDescription))
            }
            do { try saveEntry(position) }
            catch { outcome.journalWarning = "Не удалось обновить журнал на диске. Проверьте историю перед закрытием приложения."; break }
            progress(index + 1, unique.count)
        }
        if journalHealthy, !outcome.moved.isEmpty {
            do { try compact() }
            catch { outcome.journalWarning = "История сохранена в журнале операций; итоговый файл обновится при следующем запуске." }
        }
        return outcome
    }
    public func restore(_ id: UUID) throws -> HistoryEntry {
        guard !operationInProgress, journalHealthy else { throw SafetyError("Дождитесь завершения текущей операции или перезапустите приложение для проверки журнала.") }
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].state == .trashed,
              let source = entries[index].trashURL, let saved = entries[index].trashIdentity else {
            throw SafetyError("Восстановление этого файла недоступно")
        }
        let entry = entries[index]
        let parent = source.deletingLastPathComponent().resolvingSymlinksInPath().path
        let trustedTrash = parent == home.resolvingSymlinksInPath().appendingPathComponent(".Trash").standardizedFileURL.path
            || parent.hasSuffix("/.Trashes/\(getuid())")
        guard trustedTrash, FileIdentity.read(source) == saved else { throw SafetyError("Файл в Корзине изменён, удалён или перемещён. Проверьте Finder.") }
        guard ReviewedArtifactSafety.allowedRestore(entry, home: home) else { throw SafetyError("Исходный путь больше не разрешён") }
        if let tree = entry.directoryEvidence {
            guard try DirectoryEvidence.capture(source) == tree else { throw SafetyError("Содержимое папки в Корзине изменилось. Используйте Finder.") }
        }
        var ancestor = entry.originalURL.deletingLastPathComponent()
        while ancestor.path != "/" {
            if FileIdentity.read(ancestor)?.isSymbolicLink == true { throw SafetyError("В исходном пути появилась символическая ссылка") }
            if ancestor.standardizedFileURL == home.standardizedFileURL { break }
            ancestor.deleteLastPathComponent()
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.originalURL.deletingLastPathComponent().path, isDirectory: &directory),
              directory.boolValue else { throw SafetyError("Исходной папки больше нет. Восстановите файл через Finder в другую папку.") }
        guard FileIdentity.read(entry.originalURL) == nil else { throw SafetyError("На исходном месте уже есть файл. Он не будет перезаписан.") }
        entries[index].state = .restoring
        do { try saveEntry(index) } catch { entries[index].state = .trashed; throw error }
        do { try FileManager.default.moveItem(at: source, to: entry.originalURL) }
        catch { entries[index].state = .trashed; entries[index].error = error.localizedDescription; try? saveEntry(index); throw error }
        entries[index].state = .restored; entries[index].restoredAt = Date(); entries[index].error = nil
        try saveEntry(index)
        try? compact()
        return entries[index]
    }
}
