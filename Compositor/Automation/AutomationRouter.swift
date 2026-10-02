import Foundation
import AppKit

/// Maps HTTP requests onto operations. Runs on the main actor, one request at a time, so commands see the session
/// exactly as a user's click would.
final class AutomationRouter {
    static let apiVersion = "1"

    let workspace: ProjectWorkspace
    let registry = AutomationRegistry()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(workspace: ProjectWorkspace) {
        self.workspace = workspace
    }

    func route(_ request: AutomationHTTPRequest) async -> AutomationHTTPResponse {
        let path = request.path.hasSuffix("/") && request.path.count > 1 ? String(request.path.dropLast()) : request.path
        do {
            switch (request.method, path) {
            case ("GET", "/"), ("GET", "/v1"), ("GET", "/v1/health"):
                return .json(status: 200, body: try health())
            case ("GET", "/v1/ops"), ("GET", "/v1/commands"):
                return .json(status: 200, body: registry.catalog)
            case ("GET", "/v1/state"):
                let context = try self.context(project: request.query["project"])
                let include = Set((request.query["include"] ?? "all").split(separator: ",").map { AutomationParams.normalize(String($0)) })
                return .json(status: 200, body: AutomationState.session(context, include: include))
            case ("GET", "/v1/render"):
                return try await serialized { try await self.render(request) }
            case ("POST", "/v1/run"), ("POST", "/v1/command"), ("POST", "/v1/commands"):
                return try await serialized { try await self.run(request) }
            default:
                if request.method != "GET" && request.method != "POST" { return .json(status: 405, body: ["ok": false, "error": "method not allowed"]) }
                return .json(status: 404, body: ["ok": false, "error": "no route \(request.method) \(path)", "routes": ["GET /v1/health", "GET /v1/ops", "GET /v1/state", "GET /v1/render", "POST /v1/run"]])
            }
        } catch let error as AutomationError {
            return .json(status: error.status, body: ["ok": false, "error": error.description])
        } catch {
            return .json(status: 500, body: ["ok": false, "error": error.localizedDescription])
        }
    }

    // MARK: Endpoints

    func health() throws -> [String: Any] {
        let bundle = Bundle.main
        return [
            "ok": true, "app": "Compositor", "version": bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "api": Self.apiVersion, "ops": registry.order.count,
            "projects": workspace.tabs.map { AutomationState.project(AutomationContext(workspace: workspace, tab: $0)) },
            "activeProject": workspace.selectedID.uuidString,
        ]
    }

    private func render(_ request: AutomationHTTPRequest) async throws -> AutomationHTTPResponse {
        let context = try self.context(project: request.query["project"])
        var raw: [String: Any] = [:]
        for (key, value) in request.query where key != "project" {
            if let number = Double(value) { raw[key] = number } else { raw[key] = value }
        }
        if let layers = request.query["layers"] { raw["layers"] = layers.split(separator: ",").map { String($0) } }
        if let crop = request.query["crop"], crop != "selection" {
            let parts = crop.split(separator: ",").compactMap { Double($0) }
            if parts.count == 4 { raw["crop"] = parts }
        }
        let params = AutomationParams(raw)
        let (data, format) = try await AutomationProjects.render(context, params, defaultFormat: .png)
        return .binary(data, contentType: AutomationImages.contentType(format), filename: "\(context.tab.title).\(format == .jpeg ? "jpg" : format.rawValue)")
    }

    private func run(_ request: AutomationHTTPRequest) async throws -> AutomationHTTPResponse {
        let body = try request.jsonObject()
        let envelope = AutomationParams(body)
        let project = try envelope.optionalString("project")
        if let steps = try envelope.optionalArray("steps") {
            let stopOnError = try envelope.bool("stopOnError", default: true)
            var results: [[String: Any]] = []
            var failed = false
            for (index, element) in steps.enumerated() {
                guard let object = element as? [String: Any] else {
                    results.append(["index": index, "ok": false, "error": "steps[\(index)] must be an object with \"op\""])
                    failed = true
                    if stopOnError { break } else { continue }
                }
                let step = AutomationParams(object)
                let started = ContinuousClock.now
                do {
                    let (name, result) = try await execute(step, defaultProject: project)
                    results.append(["index": index, "op": name, "ok": true, "result": result, "ms": Self.milliseconds(since: started)])
                } catch let error as AutomationError {
                    results.append(["index": index, "op": object["op"] as? String ?? "", "ok": false, "error": error.description, "status": error.status, "ms": Self.milliseconds(since: started)])
                    failed = true
                    if stopOnError { break }
                } catch {
                    results.append(["index": index, "op": object["op"] as? String ?? "", "ok": false, "error": error.localizedDescription, "status": 500])
                    failed = true
                    if stopOnError { break }
                }
            }
            return .json(status: 200, body: ["ok": !failed, "count": steps.count, "completed": results.count, "results": results])
        }
        let started = ContinuousClock.now
        let (name, result) = try await execute(envelope, defaultProject: project)
        return .json(status: 200, body: ["ok": true, "op": name, "result": result, "ms": Self.milliseconds(since: started)])
    }

    /// Runs one `{"op": …, …params}` object. Parameters may sit beside `op` or inside a `params` object.
    func execute(_ step: AutomationParams, defaultProject: String?) async throws -> (String, Any) {
        let name = try step.string("op")
        guard let op = registry.op(named: name) else {
            let suggestions = registry.order.filter { $0.lowercased().contains(name.lowercased().split(separator: ".").last.map(String.init) ?? name.lowercased()) }.prefix(5)
            throw AutomationError.notFound("unknown op \"\(name)\"" + (suggestions.isEmpty ? "; see GET /v1/ops" : "; did you mean " + suggestions.joined(separator: ", ") + "?"))
        }
        var raw = step.raw
        raw.removeValue(forKey: "op")
        if let nested = raw["params"] as? [String: Any] {
            raw.removeValue(forKey: "params")
            raw.merge(nested) { _, inner in inner }
        }
        let project = raw.removeValue(forKey: "project") as? String ?? defaultProject
        let context = try self.context(project: project)
        let result = try await op.run(context, AutomationParams(raw))
        return (op.name, result)
    }

    func context(project: String?) throws -> AutomationContext {
        guard let project, !project.isEmpty else { return AutomationContext(workspace: workspace, tab: workspace.current) }
        return AutomationContext(workspace: workspace, tab: try AutomationProjects.tab(workspace, project))
    }

    // MARK: Serialization

    /// Commands run one after another: a second request waits for the first, since the session is one editing state.
    private func serialized<T>(_ body: () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

/// Starts the server when the app is asked to, and runs script files given on the command line.
///
/// Turn it on with `--automation` (port 4747), `--automation-port 5000`, the `COMPOSITOR_AUTOMATION_PORT` environment
/// variable, or `defaults write com.wonderassembly.compositor automationPort -int 4747`. A token (`--automation-token`,
/// `COMPOSITOR_AUTOMATION_TOKEN`) makes every request carry `Authorization: Bearer <token>`.
/// `--automation-run script.json` runs the steps in a file (the same body `POST /v1/run` takes) and, with `--quit`,
/// exits with status 0 or 1 when done.
final class AutomationService {
    private(set) var server: AutomationServer?
    private(set) var router: AutomationRouter?
    private(set) var scriptURL: URL?
    private(set) var quitsAfterScript = false

    var isEnabled: Bool { server != nil || scriptURL != nil }

    struct Configuration {
        var port: UInt16?
        var token: String?
        var script: URL?
        var quit = false

        static func fromEnvironment(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) -> Configuration {
            var configuration = Configuration()
            if let text = environment["COMPOSITOR_AUTOMATION_PORT"], let port = UInt16(text) { configuration.port = port }
            if let token = environment["COMPOSITOR_AUTOMATION_TOKEN"], !token.isEmpty { configuration.token = token }
            let stored = UserDefaults.standard.integer(forKey: "automationPort")
            if stored > 0, stored <= Int(UInt16.max) { configuration.port = UInt16(stored) }
            if let token = UserDefaults.standard.string(forKey: "automationToken"), !token.isEmpty { configuration.token = token }
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                func value() -> String? {
                    if let equals = argument.firstIndex(of: "=") { return String(argument[argument.index(after: equals)...]) }
                    index += 1
                    return index < arguments.count ? arguments[index] : nil
                }
                switch argument.split(separator: "=").first.map(String.init) ?? argument {
                case "--automation": configuration.port = configuration.port ?? AutomationServer.defaultPort
                case "--automation-port": if let text = value(), let port = UInt16(text) { configuration.port = port }
                case "--automation-token": configuration.token = value()
                case "--automation-run": if let path = value() { configuration.script = AutomationParams.fileURL(path); configuration.port = configuration.port ?? AutomationServer.defaultPort }
                case "--quit": configuration.quit = true
                default: break
                }
                index += 1
            }
            return configuration
        }
    }

    func start(workspace: ProjectWorkspace, configuration: Configuration = .fromEnvironment()) {
        let router = AutomationRouter(workspace: workspace)
        self.router = router
        if let port = configuration.port {
            let server = AutomationServer(port: port, token: configuration.token, router: router)
            do {
                try server.start()
                self.server = server
            } catch {
                NSLog("Compositor automation: could not listen on port %d: %@", Int(port), error.localizedDescription)
            }
        }
        if let script = configuration.script {
            scriptURL = script
            quitsAfterScript = configuration.quit
            Task { @MainActor in await self.runScript(script, router: router, quit: configuration.quit) }
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    /// Runs a script file: `{"steps": [...]}` or a bare array of steps. Results go to standard output as JSON.
    private func runScript(_ url: URL, router: AutomationRouter, quit: Bool) async {
        var exitCode: Int32 = 0
        do {
            let data = try Data(contentsOf: url)
            let parsed = try JSONSerialization.jsonObject(with: data)
            let body: [String: Any]
            if let steps = parsed as? [Any] { body = ["steps": steps] }
            else if let object = parsed as? [String: Any] { body = object.keys.contains("steps") ? object : ["steps": [object]] }
            else { throw AutomationError.badRequest("the script must be a JSON object with \"steps\" or an array of steps") }
            let request = AutomationHTTPRequest(method: "POST", path: "/v1/run", query: [:], headers: [:], body: try JSONSerialization.data(withJSONObject: body))
            let response = await router.route(request)
            FileHandle.standardOutput.write(response.body)
            FileHandle.standardOutput.write(Data("\n".utf8))
            if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any], object["ok"] as? Bool != true { exitCode = 1 }
            if response.status != 200 { exitCode = 1 }
        } catch {
            FileHandle.standardError.write(Data("Compositor automation: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        if quit {
            for tab in router.workspace.tabs { tab.session.history.markSaved() }
            exit(exitCode)
        }
    }
}
