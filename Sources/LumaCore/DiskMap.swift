import Foundation

public struct DiskMapEntry: Codable, Identifiable, Sendable {
    public let url: URL
    public var bytes: Int64 = 0
    public var files = 0
    public let directory: Bool
    public var id: String { url.path }
    public init(url: URL, bytes: Int64 = 0, files: Int = 0, directory: Bool) { self.url = url; self.bytes = bytes; self.files = files; self.directory = directory }
}
public struct DiskMapReport: Codable, Sendable {
    public let root: URL
    public var children: [DiskMapEntry]
    public var inaccessible: Int
    public var truncated: Bool
    public var visited: Int
    public var bytes: Int64 { children.reduce(0) { $0 + $1.bytes } }
}
public enum DiskMapScanner {
    public static func scan(_ root: URL, limit: Int = 500_000, progress: (Int) -> Void = { _ in }) throws -> DiskMapReport {
        guard let rootID = FileIdentity.read(root), !rootID.isSymbolicLink,
              (try root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw SafetyError("Выберите доступную папку без символической ссылки") }
        let fm = FileManager.default
        var denied = 0; var visited = 0; var limited = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let direct = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys).sorted { $0.path < $1.path }
        var result = [DiskMapEntry](); var seen = Set<String>(); var pulse = Date.distantPast
        for child in direct {
            if Task.isCancelled { throw CancellationError() }
            guard visited < limit else { limited = true; break }
            guard let identity = FileIdentity.read(child), !identity.isSymbolicLink, identity.device == rootID.device else { continue }
            let directory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            var item = DiskMapEntry(url: child, directory: directory)
            func count(_ url: URL) {
                visited += 1
                if Date().timeIntervalSince(pulse) > 0.35 { progress(visited); pulse = Date() }
                guard let id = FileIdentity.read(url), !id.isSymbolicLink, id.device == rootID.device else { return }
                if id.isRegular && seen.insert("\(id.device):\(id.inode)").inserted { item.bytes += max(0, id.bytes); item.files += 1 }
            }
            count(child)
            if directory {
                if let walk = fm.enumerator(at: child, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in denied += 1; return true }) {
                    for case let url as URL in walk {
                        if Task.isCancelled { throw CancellationError() }
                        if visited >= limit { limited = true; break }
                        if let id = FileIdentity.read(url), id.isSymbolicLink || id.device != rootID.device { DirectoryTraversal.skipDirectory(url, in: walk); continue }
                        count(url)
                    }
                } else { denied += 1 }
            }
            result.append(item)
            if limited { break }
        }
        return DiskMapReport(root: root, children: result.sorted { $0.bytes > $1.bytes }, inaccessible: denied, truncated: limited, visited: visited)
    }
}

public enum UtilityJob: String, Codable, Sendable { case applications, applicationPlan, applicationReview, backups, diskMap }
public struct UtilityRequest: Codable, Sendable {
    public let job: UtilityJob
    public let home: URL
    public let url: URL?
    public let app: ApplicationRecord?
    public let policy: SafetyPolicy
    public let ageDays: Int
    public var bookmarks: [Data] = []
    public var applicationSource: ApplicationReviewSource?
    public init(job: UtilityJob, home: URL, url: URL? = nil, app: ApplicationRecord? = nil, policy: SafetyPolicy = SafetyPolicy(), ageDays: Int = 14) {
        self.job = job; self.home = home; self.url = url; self.app = app; self.policy = policy; self.ageDays = ageDays
    }
}
public struct UtilityResult: Codable, Sendable {
    public var applications: [ApplicationRecord] = []
    public var items: [FileItem] = []
    public var map: DiskMapReport?
    public var error: String?
    public var progress: Int?
    public var finished = false
    public var sources: [ApplicationReviewSource] = []
    public var notes: [String] = []
    public var sourceStatus: RootStatus?
    public var partialItems = false
    public init() {}
}

public enum UtilityWorkerHost {
    public static func runIfRequested() {
        guard CommandLine.arguments.contains("--utility-worker") else { return }
        func send(_ result: UtilityResult) {
            if let data = try? JSONEncoder().encode(result) { FileHandle.standardOutput.write(data + Data([10])) }
        }
        var result = UtilityResult()
        do {
            let request = try JSONDecoder().decode(UtilityRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
            let access = request.bookmarks.compactMap { try? FolderAccess.resolve($0) }
            defer { access.forEach { $0.stop() } }
            func pulse(_ count: Int = 0) { var tick = UtilityResult(); tick.progress = count; send(tick) }
            pulse()
            switch request.job {
            case .applications: result.applications = ApplicationInventory.list(home: request.home, roots: request.policy.applicationRoots)
            case .applicationPlan:
                guard let app = request.app else { throw SafetyError("Приложение не выбрано") }
                result.sources = ApplicationDiscovery.plan(app, home: request.home, manualAssociations: request.policy.manualAssociations ?? [])
            case .applicationReview:
                guard let app = request.app else { throw SafetyError("Приложение не выбрано") }
                let source = request.applicationSource ?? ApplicationReviewSource(kind: .standard, url: app.url, ownerID: app.bundleID)
                let discovered = try ApplicationDiscovery.scan(source, app: app, home: request.home, policy: request.policy, heartbeat: { pulse() }) { items in
                    var partial = UtilityResult(); partial.items = items; partial.partialItems = true; send(partial)
                }
                result.items = discovered.items; result.sources = discovered.sources; result.notes = discovered.notes; result.sourceStatus = discovered.status
            case .backups: result.items = try BackupInventory.scan(home: request.home, policy: request.policy, minimumAgeDays: request.ageDays, heartbeat: { pulse() })
            case .diskMap:
                guard let url = request.url else { throw SafetyError("Папка не выбрана") }
                result.map = try DiskMapScanner.scan(url, progress: { pulse($0) })
            }
        } catch { result.error = error.localizedDescription; result.sourceStatus = .denied }
        result.finished = true; send(result); exit(result.error == nil ? 0 : 1)
    }
}

@MainActor public final class UtilityCoordinator {
    private var process: Process?
    private var continuation: CheckedContinuation<UtilityResult, Never>?
    private var timer: Task<Void, Never>?
    private var token = UUID()
    private var update: ((Int) -> Void)?
    private var lastPartial = UtilityResult()
    private var idleTimeout = 20.0
    public init() {}
    public func cancel() { finish(error: "Проверка остановлена", status: .cancelled) }
    public func run(_ request: UtilityRequest, executable: URL, timeoutSeconds: Double = 20, update: @escaping (Int) -> Void = { _ in }) async -> UtilityResult {
        guard continuation == nil else { var error = UtilityResult(); error.error = "Другая проверка ещё работает"; return error }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation; self.update = update; let current = UUID(); token = current
            lastPartial = UtilityResult(); idleTimeout = timeoutSeconds
            let process = Process(); let output = Pipe(); let input = Pipe()
            process.executableURL = executable; process.arguments = ["--utility-worker"]
            process.standardOutput = output; process.standardInput = input; process.standardError = FileHandle.nullDevice
            do {
                let data = try JSONEncoder().encode(request)
                try process.run(); self.process = process
                try input.fileHandleForWriting.write(contentsOf: data); try input.fileHandleForWriting.close()
            } catch { finish(error: error.localizedDescription); return }
            resetTimer()
            Task.detached(priority: .utility) {
                var buffer = Data()
                while true {
                    let bytes = output.fileHandleForReading.availableData
                    if bytes.isEmpty { break }; buffer.append(bytes)
                    if buffer.count > 100_000_000 { await self.finish(error: "Результат проверки слишком большой"); break }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        guard let result = try? JSONDecoder().decode(UtilityResult.self, from: line) else { continue }
                        await self.receive(result, token: current)
                    }
                }
                try? output.fileHandleForReading.close()
                await self.ended(token: current)
            }
        }
    }
    private func receive(_ result: UtilityResult, token: UUID) {
        guard self.token == token, continuation != nil else { return }
        resetTimer()
        if result.finished {
            var final = result
            if final.error != nil, final.items.isEmpty { final.items = lastPartial.items }
            finish(result: final)
        } else {
            if result.partialItems { lastPartial = result }
            update?(result.progress ?? 0)
        }
    }
    private func ended(token: UUID) { if self.token == token { finish(error: "Проверка завершилась без результата") } }
    private func resetTimer() {
        timer?.cancel(); let current = token
        let seconds = idleTimeout
        timer = Task { do { try await Task.sleep(for: .seconds(seconds)) } catch { return }; if current == self.token { self.finish(error: "Нет ответа от этой папки. Найденные данные сохранены; остальные места будут проверены отдельно.", status: .timedOut) } }
    }
    private func finish(result: UtilityResult? = nil, error: String? = nil, status: RootStatus? = nil) {
        guard let continuation else { return }
        self.continuation = nil; token = UUID(); timer?.cancel(); timer = nil
        if process?.isRunning == true { process?.terminate() }; process = nil
        var value = result ?? lastPartial; if let error { value.error = error }; if let status { value.sourceStatus = status }
        continuation.resume(returning: value)
    }
}
