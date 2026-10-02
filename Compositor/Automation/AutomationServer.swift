import Foundation
import Network

/// A small HTTP/1.1 server bound to the loopback interface that turns JSON requests into automation commands.
///
/// The server is deliberately minimal: one request per connection, `Content-Length` bodies only, no chunked
/// transfer, no TLS. It exists so scripts and agents on the same Mac can drive an editing session without the UI;
/// it is never reachable from another machine. Requests are parsed on the listener's queue and handed to
/// `AutomationRouter` on the main actor, where every editing operation has to run anyway.
nonisolated final class AutomationServer: @unchecked Sendable {
    /// The port the server listens on when nothing else is configured.
    static let defaultPort: UInt16 = 4747
    /// Largest request body accepted, in bytes. Inline images travel base64-encoded, so this is generous.
    static let maximumBodySize = 256 * 1024 * 1024

    let port: UInt16
    let token: String?
    private let router: AutomationRouter
    private let queue = DispatchQueue(label: "com.compositor.automation.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: AutomationConnection] = [:]
    private let lock = NSLock()

    init(port: UInt16, token: String?, router: AutomationRouter) {
        self.port = port
        self.token = token
        self.router = router
    }

    /// Starts listening. Throws when the port is taken or the sandbox refuses the listener.
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: NSLog("Compositor automation: listening on http://127.0.0.1:%d", Int(self.port))
            case .failed(let error): NSLog("Compositor automation: listener failed: %@", error.localizedDescription)
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let wrapper = AutomationConnection(connection: connection, queue: queue, maximumBodySize: Self.maximumBodySize) { [weak self] request, respond in
            guard let self else { respond(AutomationHTTPResponse.json(status: 503, body: ["error": "server stopped"])); return }
            self.handle(request, respond: respond)
        }
        wrapper.onClose = { [weak self, weak wrapper] in
            guard let self, let wrapper else { return }
            self.lock.lock()
            self.connections.removeValue(forKey: ObjectIdentifier(wrapper))
            self.lock.unlock()
        }
        lock.lock()
        connections[ObjectIdentifier(wrapper)] = wrapper
        lock.unlock()
        wrapper.start()
    }

    private func handle(_ request: AutomationHTTPRequest, respond: @escaping (AutomationHTTPResponse) -> Void) {
        if let refusal = Self.browserRefusal(request, port: port) {
            respond(.json(status: 403, body: ["ok": false, "error": refusal]))
            return
        }
        if let token {
            let presented = request.headers["authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
                ?? request.query["token"]
            guard presented == token else {
                respond(.json(status: 401, body: ["ok": false, "error": "missing or wrong token"]))
                return
            }
        }
        let router = router
        Task { @MainActor in
            let response = await router.route(request)
            respond(response)
        }
    }

    /// Why a request is refused as coming from a web page, or nil to serve it. Any site the person visits could
    /// otherwise post to 127.0.0.1 (a plain-text POST needs no preflight) or reach it through a DNS name rebound
    /// to it, and save or export files with the person's access. Scripts and agents send none of these headers.
    static func browserRefusal(_ request: AutomationHTTPRequest, port: UInt16) -> String? {
        let host = (request.headers["host"] ?? "").lowercased()
        let allowed = ["127.0.0.1", "localhost", "[::1]"].flatMap { [$0, "\($0):\(port)"] }
        guard host.isEmpty || allowed.contains(host) else { return "requests must be addressed to 127.0.0.1:\(port)" }
        // Browsers send Origin on cross-site and on every non-GET request; scripts don't.
        if request.headers["origin"] != nil { return "requests from web pages are not accepted" }
        // Sec-Fetch-Site is "none" only when the person typed the address themselves, which is fine for reading /v1/ops.
        if let site = request.headers["sec-fetch-site"], site.lowercased() != "none" { return "requests from web pages are not accepted" }
        return nil
    }
}

// MARK: - HTTP plumbing

nonisolated struct AutomationHTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    /// The body decoded as a JSON object; an empty body counts as an empty object.
    func jsonObject() throws -> [String: Any] {
        guard !body.isEmpty else { return [:] }
        let parsed = try JSONSerialization.jsonObject(with: body)
        guard let object = parsed as? [String: Any] else {
            throw AutomationError.badRequest("the request body must be a JSON object")
        }
        return object
    }
}

nonisolated struct AutomationHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(status: Int, body: Any) -> AutomationHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
        return AutomationHTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    static func binary(_ data: Data, contentType: String, filename: String? = nil) -> AutomationHTTPResponse {
        var headers = ["Content-Type": contentType]
        if let filename { headers["Content-Disposition"] = "inline; filename=\"\(filename)\"" }
        return AutomationHTTPResponse(status: 200, headers: headers, body: data)
    }

    var serialized: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        case 422: reason = "Unprocessable Entity"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "Status"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Server"] = "Compositor-Automation/1"
        for (key, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

/// One accepted socket: reads a single request, hands it to the handler, writes the response and closes.
nonisolated final class AutomationConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let maximumBodySize: Int
    private let handler: (AutomationHTTPRequest, @escaping (AutomationHTTPResponse) -> Void) -> Void
    private var buffer = Data()
    var onClose: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, maximumBodySize: Int,
         handler: @escaping (AutomationHTTPRequest, @escaping (AutomationHTTPResponse) -> Void) -> Void) {
        self.connection = connection
        self.queue = queue
        self.maximumBodySize = maximumBodySize
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.onClose?()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if error != nil { self.connection.cancel(); return }
            switch self.parse() {
            case .incomplete:
                if isComplete { self.connection.cancel() } else { self.receive() }
            case .tooLarge:
                self.send(.json(status: 413, body: ["ok": false, "error": "request body too large"]))
            case .malformed(let reason):
                self.send(.json(status: 400, body: ["ok": false, "error": reason]))
            case .request(let request):
                self.handler(request) { response in self.send(response) }
            }
        }
    }

    private enum Parse { case incomplete, tooLarge, malformed(String), request(AutomationHTTPRequest) }

    private func parse() -> Parse {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .malformed("request headers too long") : .incomplete
        }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return .malformed("headers are not UTF-8") }
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed("empty request") }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .malformed("bad request line") }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maximumBodySize else { return .tooLarge }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            for pair in target[target.index(after: mark)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        return .request(AutomationHTTPRequest(method: method, path: path, query: query, headers: headers, body: body))
    }

    private func send(_ response: AutomationHTTPResponse) {
        connection.send(content: response.serialized, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}
