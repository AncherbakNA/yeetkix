import Foundation

public enum ScanWorkerHost {
    public static func runIfRequested() {
        guard CommandLine.arguments.contains("--scan-worker") else { return }
        @Sendable func send(_ message: WorkerMessage) {
            guard var data = try? JSONEncoder().encode(message) else { return }
            data.append(0x0A); FileHandle.standardOutput.write(data)
        }
        do {
            let request = try JSONDecoder().decode(WorkerRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
            var granted: [URL] = []
            for bookmark in request.bookmarks {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale) { granted.append(url) }
            }
            defer { granted.forEach { $0.stopAccessingSecurityScopedResource() } }
            if request.analyzeDuplicates {
                var report = ScanReport(); report.scope = request.scope
                report.duplicateGroups = try DuplicateFinder.find(request.duplicateCandidates, issue: { url, _ in
                    report.protectedCount += 1
                    if report.inaccessible.count < 30 { report.inaccessible.append(url.path) }
                }) { fraction, location, count in
                    send(WorkerMessage(progress: fraction, location: location, visited: count))
                }
                if let root = request.roots.first { report.roots = [RootResult(root: root, status: report.inaccessible.isEmpty ? .complete : .denied)] }
                send(WorkerMessage(report: report)); exit(0)
            }
            let report = try DiskScanner(home: request.home, ageDays: request.ageDays, entryLimit: request.entryLimit,
                                         scope: request.scope, policy: request.policy, roots: request.roots).scan(snapshot: {
                send(WorkerMessage(partialReport: $0))
            }) { fraction, location, count in
                send(WorkerMessage(progress: fraction, location: location, visited: count))
            }
            send(WorkerMessage(report: report)); exit(0)
        } catch {
            send(WorkerMessage(error: error.localizedDescription)); exit(1)
        }
    }
}

public struct ScanUpdate: Sendable {
    public var fraction: Double
    public var title: String
    public var visited: Int
    public var partial: ScanReport
}

@MainActor
public final class ScanCoordinator {
    private var process: Process?
    private var continuation: CheckedContinuation<ScanReport, Never>?
    private var rootToken = UUID()
    private var timeoutTask: Task<Void, Never>?
    private var current: ScanRoot?
    private var lastPartial = ScanReport()
    private var wasCancelled = false
    private var onProgress: ((Double, String, Int) -> Void)?
    private var idleTimeout: Double = 20
    public init() {}

    public func cancel() {
        wasCancelled = true
        finish(status: .cancelled)
    }
    public func skipCurrentRoot() { finish(status: .cancelled) }

    public func scan(_ request: WorkerRequest, executable: URL, timeoutSeconds: Double = 20,
                     update: @escaping (ScanUpdate) -> Void) async -> ScanReport {
        var combined = ScanReport(); combined.ageDays = request.ageDays; combined.scope = request.scope
        let scanningWeight = request.scope == .all || request.scope == .duplicates ? 0.65 : 1.0
        wasCancelled = false
        for (index, root) in request.roots.enumerated() {
            if wasCancelled || Task.isCancelled { combined.isPartial = true; break }
            if combined.visitedCount >= request.entryLimit { combined.truncated = true; break }
            var one = request; one.roots = [root]; one.entryLimit = request.entryLimit - combined.visitedCount
            let base = combined
            let total = Double(max(1, request.roots.count))
            onProgress = { fraction, title, count in
                var partial = base
                partial.items += self.lastPartial.items
                partial.duplicateCandidates += self.lastPartial.duplicateCandidates
                partial.protectedCount += self.lastPartial.protectedCount
                partial.visitedCount += self.lastPartial.visitedCount
                partial.isPartial = true
                partial.normalizeItems()
                update(ScanUpdate(fraction: (Double(index) + fraction) / total * scanningWeight, title: title,
                                  visited: base.visitedCount + count, partial: partial))
            }
            let container = root.relativePath.hasPrefix("Library/Containers/") || root.relativePath.hasPrefix("Library/Group Containers/")
            let rootTimeout = container && [.cache, .logs].contains(root.category) ? min(timeoutSeconds, 5) : timeoutSeconds
            let result = await runRoot(one, executable: executable, timeoutSeconds: rootTimeout)
            combined.items += result.items; combined.roots += result.roots
            combined.duplicateCandidates += result.duplicateCandidates
            combined.inaccessible += result.inaccessible
            combined.visitedCount += result.visitedCount; combined.protectedCount += result.protectedCount
            combined.truncated = combined.truncated || result.truncated
            combined.isPartial = combined.isPartial || result.isPartial
            combined.normalizeItems()
            update(ScanUpdate(fraction: Double(index + 1) / total * scanningWeight, title: root.title, visited: combined.visitedCount, partial: combined))
            if combined.truncated { break }
        }
        let checked = Set(combined.roots.map(\.id))
        let remaining = request.roots.filter { !checked.contains($0.id) }
        if !remaining.isEmpty {
            combined.isPartial = true
            combined.roots += remaining.map { RootResult(root: $0, status: combined.truncated ? .limited : .cancelled,
                detail: combined.truncated ? "Не проверена: достигнут общий лимит объектов." : "Не проверена: сканирование остановлено.") }
        }
        if !wasCancelled && !Task.isCancelled && (request.scope == .all || request.scope == .duplicates), combined.duplicateCandidates.count > 1 {
            let root = ScanRoot(relativePath: ".duplicate-analysis", category: .duplicates, home: request.home)
            var analysis = request; analysis.roots = [root]; analysis.analyzeDuplicates = true
            analysis.duplicateCandidates = combined.duplicateCandidates
            let base = combined
            onProgress = { fraction, title, _ in
                update(ScanUpdate(fraction: 0.65 + fraction * 0.35, title: title, visited: base.visitedCount, partial: base))
            }
            let result = await runRoot(analysis, executable: executable, timeoutSeconds: timeoutSeconds)
            combined.duplicateGroups = result.duplicateGroups; combined.roots += result.roots
            combined.inaccessible += result.inaccessible; combined.protectedCount += result.protectedCount
            combined.isPartial = combined.isPartial || result.isPartial
        }
        combined.duplicateCandidates = []
        onProgress = nil
        combined.normalizeItems()
        combined.inaccessible = Array(Set(combined.inaccessible)).sorted()
        combined.date = Date()
        return combined
    }

    private func runRoot(_ request: WorkerRequest, executable: URL, timeoutSeconds: Double) async -> ScanReport {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; self.current = request.roots.first
            self.lastPartial = ScanReport(); self.lastPartial.ageDays = request.ageDays; self.lastPartial.scope = request.scope
            let token = UUID(); rootToken = token
            idleTimeout = timeoutSeconds
            let process = Process(); let output = Pipe(); let input = Pipe()
            process.executableURL = executable; process.arguments = ["--scan-worker"]
            process.standardOutput = output; process.standardInput = input; process.standardError = FileHandle.nullDevice
            do {
                let data = try JSONEncoder().encode(request)
                try process.run(); self.process = process
                try input.fileHandleForWriting.write(contentsOf: data)
                try input.fileHandleForWriting.close()
            } catch { finish(status: .denied, detail: error.localizedDescription); return }
            resetTimeout()
            let receiver = self
            Task.detached(priority: .utility) {
                var buffer = Data()
                let reader = output.fileHandleForReading
                while true {
                    let data = reader.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    if buffer.count > 128 * 1024 * 1024 { await receiver.oversized(token: token); break }
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        guard let message = try? JSONDecoder().decode(WorkerMessage.self, from: line) else { continue }
                        await receiver.receive(message, token: token)
                    }
                }
                try? reader.close()
                await receiver.endOfStream(token: token)
            }
        }
    }
    private func receive(_ message: WorkerMessage, token: UUID) {
        guard token == rootToken, continuation != nil else { return }
        resetTimeout()
        if let final = message.report { lastPartial = final; finish(); return }
        if let partial = message.partialReport {
            lastPartial = partial; onProgress?(0, current?.title ?? "", partial.visitedCount)
        } else if let error = message.error { finish(status: .denied, detail: error) }
        else { onProgress?(message.progress ?? 0, current?.title ?? message.location ?? "", message.visited ?? 0) }
    }
    private func resetTimeout() {
        timeoutTask?.cancel()
        let token = rootToken; let seconds = idleTimeout
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.rootToken == token else { return }
            self.finish(status: .timedOut, detail: "Файловая система не отвечала \(Int(seconds)) секунд.")
        }
    }
    private func endOfStream(token: UUID) {
        guard token == rootToken, continuation != nil else { return }
        finish(status: .denied, detail: "Процесс сканирования завершился без результата.")
    }
    private func oversized(token: UUID) {
        guard token == rootToken, continuation != nil else { return }
        finish(status: .limited, detail: "Превышен размер ответа сканера. Сохранены уже полученные результаты.")
    }
    private func finish(status: RootStatus? = nil, detail: String? = nil) {
        guard let continuation else { return }
        self.continuation = nil; rootToken = UUID(); timeoutTask?.cancel(); timeoutTask = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        if let status, let root = current {
            lastPartial.roots = [RootResult(root: root, status: status, detail: detail)]
            lastPartial.isPartial = true
            if status == .denied || status == .timedOut { lastPartial.inaccessible.append(root.relativePath) }
        }
        continuation.resume(returning: lastPartial)
    }
}
