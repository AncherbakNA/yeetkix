import Foundation
import Darwin

public struct CommandOutput: Sendable {
    public let status: Int32
    public let text: String
    public init(status: Int32, text: String) { self.status = status; self.text = text }
}
public typealias CommandExecutor = @Sendable (URL, [String]) throws -> CommandOutput
public enum LocalCommand {
    public static func run(_ executable: URL, _ arguments: [String], timeout: Double = 60) throws -> CommandOutput {
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YeetkixCommand-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for name in ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION", "BUILDX_BUILDER"] { env.removeValue(forKey: name) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"; env["LC_ALL"] = "C"
        process.environment = env; process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
        try process.run(); let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate(); Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            if Task.isCancelled { throw CancellationError() }
            throw SafetyError("Команда не ответила вовремя. Перед повтором обновите список ресурсов.")
        }
        process.waitUntilExit(); try handle.synchronize()
        let reader = try FileHandle(forReadingFrom: output); defer { try? reader.close() }
        let data = try reader.read(upToCount: 16_000_001) ?? Data()
        guard data.count <= 16_000_000 else { throw SafetyError("Ответ команды слишком большой") }
        return CommandOutput(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }
}

public enum ManagedKind: String, Codable, Sendable { case simulator, dockerImage, dockerContainer, dockerBuildCache }
public struct ManagedResource: Codable, Identifiable, Sendable {
    public let kind: ManagedKind
    public let key: String
    public let name: String
    public let detail: String
    public let bytes: Int64?
    public let endpoint: String?
    public let serverID: String?
    public let stateToken: String
    public var id: String { kind.rawValue + ":" + key }
    public init(kind: ManagedKind, key: String, name: String, detail: String, bytes: Int64? = nil, endpoint: String? = nil, serverID: String? = nil, stateToken: String = "") {
        self.kind = kind; self.key = key; self.name = name; self.detail = detail; self.bytes = bytes; self.endpoint = endpoint; self.serverID = serverID; self.stateToken = stateToken
    }
}
public enum ManagedResources {
    public static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    public static func dockerExecutable() -> URL? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"].map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static func checked(_ exe: URL, _ args: [String], run: CommandExecutor) throws -> String {
        let result = try run(exe, args)
        guard result.status == 0 else { throw SafetyError(String(result.text.prefix(1200))) }
        return result.text
    }
    static func objects(_ text: String) throws -> [[String: Any]] {
        guard let data = text.data(using: .utf8), let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SafetyError("Неожиданный формат ответа") }
        return objects
    }
    public static func simulators(run: CommandExecutor = { try LocalCommand.run($0, $1) }) throws -> [ManagedResource] {
        let raw = try checked(xcrun, ["simctl", "list", "devices", "--json"], run: run)
        guard let data = raw.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let devices = json["devices"] as? [String: [[String: Any]]] else { throw SafetyError("simctl вернул неизвестный формат") }
        return devices.flatMap { runtime, devices in devices.compactMap { device -> ManagedResource? in
            guard device["isAvailable"] as? Bool == false, device["state"] as? String == "Shutdown", let id = device["udid"] as? String, UUID(uuidString: id) != nil else { return nil }
            return ManagedResource(kind: .simulator, key: id, name: device["name"] as? String ?? "Симулятор", detail: runtime, stateToken: "unavailable:Shutdown")
        } }.sorted { $0.name < $1.name }
    }
    public static func localDockerEndpoint(_ value: String, home: URL) -> Bool {
        guard value.hasPrefix("unix://") else { return false }
        let path = String(value.dropFirst(7))
        return ["/var/run/docker.sock", home.appendingPathComponent(".docker/run/docker.sock").path].contains(path)
    }
    public static func docker(home: URL, executable: URL? = nil, run: CommandExecutor = { try LocalCommand.run($0, $1) }) throws -> [ManagedResource] {
        guard let exe = executable ?? dockerExecutable() else { throw SafetyError("Docker CLI не установлен") }
        let context = try checked(exe, ["context", "show"], run: run).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty, context.count < 200, !context.hasPrefix("-") else { throw SafetyError("Не удалось определить контекст Docker") }
        let contexts = try objects(checked(exe, ["context", "inspect", context], run: run))
        guard let first = contexts.first, let endpoints = first["Endpoints"] as? [String: Any], let docker = endpoints["docker"] as? [String: Any], let endpoint = docker["Host"] as? String, localDockerEndpoint(endpoint, home: home) else { throw SafetyError("Выбран удалённый контекст. Поддерживается только локальный Docker Desktop через Unix socket.") }
        func command(_ args: [String]) throws -> String { try checked(exe, ["--host", endpoint] + args, run: run) }
        let server = try command(["info", "--format", "{{.ID}}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { throw SafetyError("Локальный Docker не запущен. Запустите его самостоятельно и повторите проверку.") }
        var result = [ManagedResource]()
        let ids = try command(["image", "ls", "--filter", "dangling=true", "--no-trunc", "--quiet"]).split(whereSeparator: \.isWhitespace).map(String.init)
        for id in Set(ids).sorted().prefix(200) where validImage(id) {
            guard let object = try objects(command(["image", "inspect", id])).first,
                  (object["RepoTags"] as? [String] ?? []).isEmpty, (object["RepoDigests"] as? [String] ?? []).isEmpty,
                  try command(["container", "ls", "--all", "--quiet", "--filter", "ancestor=\(id)"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result.append(ManagedResource(kind: .dockerImage, key: id, name: "Образ без тега · " + String(id.suffix(12)), detail: "Не используется контейнерами", bytes: (object["Size"] as? NSNumber)?.int64Value, endpoint: endpoint, serverID: server))
        }
        let containerIDs = try command(["container", "ls", "--all", "--no-trunc", "--quiet", "--filter", "status=exited", "--filter", "status=dead"]).split(whereSeparator: \.isWhitespace).map(String.init)
        for id in Set(containerIDs).sorted().prefix(200) where validContainer(id) {
            guard let object = try objects(command(["container", "inspect", "--size", id])).first, let state = object["State"] as? [String: Any], let status = state["Status"] as? String, ["exited", "dead"].contains(status), state["Running"] as? Bool == false else { continue }
            let token = [object["Created"] as? String ?? "", state["StartedAt"] as? String ?? "", state["FinishedAt"] as? String ?? ""].joined(separator: "|")
            result.append(ManagedResource(kind: .dockerContainer, key: id, name: (object["Name"] as? String ?? String(id.prefix(12))).trimmingCharacters(in: CharacterSet(charactersIn: "/")), detail: "Остановленный контейнер · записываемый слой", bytes: (object["SizeRw"] as? NSNumber)?.int64Value, endpoint: endpoint, serverID: server, stateToken: token))
        }
        result.append(ManagedResource(kind: .dockerBuildCache, key: "dangling-168h", name: "Неиспользуемый кэш сборок", detail: "Только dangling-кэш, не использовавшийся 7 дней. Размер уточнит Docker.", endpoint: endpoint, serverID: server))
        return result
    }
    static func validImage(_ id: String) -> Bool { id.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil }
    static func validContainer(_ id: String) -> Bool { id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    public static func remove(_ item: ManagedResource, home: URL, dockerExecutable: URL? = nil, run: CommandExecutor = { try LocalCommand.run($0, $1) }) throws -> String {
        if item.kind == .simulator {
            guard UUID(uuidString: item.key) != nil, try simulators(run: run).contains(where: { $0.key == item.key && $0.stateToken == item.stateToken }) else { throw SafetyError("Состояние симулятора изменилось. Обновите список.") }
            return try checked(xcrun, ["simctl", "delete", item.key], run: run)
        }
        guard let exe = dockerExecutable ?? self.dockerExecutable(), let endpoint = item.endpoint, localDockerEndpoint(endpoint, home: home), let expectedServer = item.serverID else { throw SafetyError("Локальное подключение Docker не подтверждено") }
        func command(_ args: [String]) throws -> String { try checked(exe, ["--host", endpoint] + args, run: run) }
        let server = try command(["info", "--format", "{{.ID}}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard server == expectedServer else { throw SafetyError("Docker daemon изменился. Обновите список.") }
        switch item.kind {
        case .dockerImage:
            guard validImage(item.key), let object = try objects(command(["image", "inspect", item.key])).first, object["Id"] as? String == item.key,
                  (object["RepoTags"] as? [String] ?? []).isEmpty, (object["RepoDigests"] as? [String] ?? []).isEmpty,
                  try command(["container", "ls", "--all", "--quiet", "--filter", "ancestor=\(item.key)"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SafetyError("Образ получил тег или используется контейнером") }
            return try command(["image", "rm", "--no-prune", item.key])
        case .dockerContainer:
            guard validContainer(item.key), let object = try objects(command(["container", "inspect", "--size", item.key])).first, object["Id"] as? String == item.key,
                  let state = object["State"] as? [String: Any], state["Running"] as? Bool == false, ["exited", "dead"].contains(state["Status"] as? String ?? "") else { throw SafetyError("Контейнер запущен или изменился") }
            let token = [object["Created"] as? String ?? "", state["StartedAt"] as? String ?? "", state["FinishedAt"] as? String ?? ""].joined(separator: "|")
            guard token == item.stateToken else { throw SafetyError("Контейнер запускался после проверки") }
            return try command(["container", "rm", item.key])
        case .dockerBuildCache:
            guard item.key == "dangling-168h" else { throw SafetyError("Неподдерживаемый набор кэша") }
            return try command(["builder", "prune", "--filter", "until=168h", "--force"])
        case .simulator: throw SafetyError("Недопустимый ресурс")
        }
    }
}

public struct ManagedEvent: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let resource: ManagedResource
    public var state: String
    public var detail: String
}
public actor ManagedCleanupService {
    private let store: URL
    private var busy = false
    public init(store: URL) { self.store = store }
    public func history() throws -> [ManagedEvent] {
        guard FileManager.default.fileExists(atPath: store.path) else { return [] }
        let data = try Data(contentsOf: store)
        var events = [UUID: ManagedEvent]()
        for line in data.split(separator: 10) { let record = try JSONDecoder().decode(ManagedEvent.self, from: Data(line)); events[record.id] = record }
        return events.values.sorted { $0.date > $1.date }
    }
    public func remove(_ items: [ManagedResource], home: URL, run: @escaping CommandExecutor = { try LocalCommand.run($0, $1) }) async throws -> [ManagedEvent] {
        guard !busy else { throw SafetyError("Операция уже выполняется") }; busy = true; defer { busy = false }
        _ = try history() // Fail closed if the audit log is damaged.
        var result = [ManagedEvent]()
        for item in items {
            if Task.isCancelled { break }
            var event = ManagedEvent(id: UUID(), date: Date(), resource: item, state: "Подготовлено", detail: "При прерывании проверьте ресурс в исходном приложении.")
            func save(_ value: ManagedEvent) throws { var data = try JSONEncoder().encode(value); data.append(10); try CleanupService.appendEvent(data, to: store) }
            try save(event)
            do {
                let detail = try await Task.detached(priority: .utility) { try ManagedResources.remove(item, home: home, run: run) }.value
                event.state = "Удалено без восстановления"; event.detail = String(detail.prefix(4000))
            } catch { event.state = "Не подтверждено"; event.detail = error.localizedDescription }
            try save(event); result.append(event)
        }
        return result
    }
}
