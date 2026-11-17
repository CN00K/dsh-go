import Foundation
import Network

// BrowserLoopbackService.swift — dsh-go browser_use: loopback HTTP service.
//
// The Node engine (DSH, running in NodeMobile) reaches the Swift browser
// through this service — the same pattern as IShLoopbackService (127.0.0.1,
// Bearer token, one-shot requests), but a SEPARATE service so no existing
// file is touched.
//
//   GET  /browser/status   — pool status JSON
//   POST /browser/execute  — action JSON in, result JSON out
//
// The service writes its port + token to
// Application Support/runtime/rootfs/browser-service.json (0600); the JS client
// (runtime/native-node/browser-bridge.mjs) reads that file, exactly like
// ish-bridge.mjs reads ish-service.json. One request per connection
// (Connection: close); no WebSocket, no keep-alive — the JS client makes
// one-shot POSTs.
//
// Auth: `Authorization: Bearer <token>`; missing/wrong token -> 401.
// Unknown route -> 404. Browser not ready -> 503.

final class BrowserLoopbackService {
    static let shared = BrowserLoopbackService()

    private var listener: NWListener?
    private var token: String = ""
    private let queue = DispatchQueue(label: "dsh.browser.loopback", qos: .userInitiated)
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    /// Start listening on 127.0.0.1 (ephemeral port). Idempotent.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.started else { return }
            self.started = true
            self.token = Self.randomToken()
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(0))
                listener.service = nil
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port {
                            self.writeServiceFile(port: Int(port.rawValue))
                        }
                    case .failed(let error):
                        self.started = false
                        self.listener = nil
                        NSLog("[BrowserLoopback] listener failed: \(error)")
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }
                listener.start(queue: self.queue)
            } catch {
                self.started = false
                NSLog("[BrowserLoopback] failed to start listener: \(error)")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.started = false
        }
    }

    // MARK: - Service file

    private static var serviceFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("runtime/rootfs/browser-service.json")
    }

    private func writeServiceFile(port: Int) {
        let url = Self.serviceFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload: [String: Any] = ["port": port, "token": token]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("[BrowserLoopback] failed to write service file: \(error)")
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Connections

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        let state = ConnectionState(connection: connection, service: self)
        state.receive()
    }

    /// Per-connection HTTP reader: accumulate until headers + Content-Length
    /// body are complete, then route once and close.
    private final class ConnectionState {
        let connection: NWConnection
        weak var service: BrowserLoopbackService?
        var buffer = Data()

        init(connection: NWConnection, service: BrowserLoopbackService) {
            self.connection = connection
            self.service = service
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                }
                if error != nil {
                    self.connection.cancel()
                    return
                }
                if let request = Self.parseRequest(self.buffer) {
                    self.respond(to: request)
                } else if self.buffer.count > 1_048_576 {
                    // 1MB cap on request size; the action JSON is small.
                    self.send(status: 413, reason: "Payload Too Large", json: ["error": "request too large"])
                } else {
                    self.receive()
                }
            }
        }

        /// Parse a complete HTTP request from the buffer, or nil when more
        /// data is needed. Returns the method, path, headers and body.
        private static func parseRequest(_ buffer: Data) -> (method: String, path: String, headers: [String: String], body: Data)? {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
            let lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return nil }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            let method = String(parts[0])
            let rawPath = String(parts[1])
            let path = rawPath.components(separatedBy: "?").first ?? rawPath
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            let bodyStart = headerEnd.upperBound
            let available = buffer.count - bodyStart
            guard available >= contentLength else { return nil }
            let body = contentLength > 0 ? buffer.subdata(in: bodyStart..<(bodyStart + contentLength)) : Data()
            return (method, path, headers, body)
        }

        private func respond(to request: (method: String, path: String, headers: [String: String], body: Data)) {
            guard let service else {
                send(status: 503, reason: "Service Unavailable", json: ["error": "browser service stopped"])
                return
            }
            // Auth: Bearer token, same scheme as the iSH loopback service.
            let auth = request.headers["authorization"] ?? ""
            guard auth == "Bearer \(service.token)" else {
                send(status: 401, reason: "Unauthorized", json: ["error": "missing or wrong Bearer token"])
                return
            }
            switch (request.method, request.path) {
            case ("GET", "/browser/status"):
                Task { @MainActor in
                    self.send(status: 200, reason: "OK", json: BrowserUsePlugin.statusDict())
                }
            case ("POST", "/browser/execute"):
                guard let inputJSON = String(data: request.body, encoding: .utf8),
                      let input = BrowserActionInput.parse(from: inputJSON) else {
                    send(status: 400, reason: "Bad Request", json: ["error": "body must be an action JSON object with an 'action' field"])
                    return
                }
                Task { @MainActor in
                    do {
                        let result = try await BrowserUsePlugin.sharedPool.execute(input: input)
                        self.send(status: 200, reason: "OK", json: result.toDict())
                    } catch {
                        self.send(status: 200, reason: "OK", json: BrowserActionResult.error(error.localizedDescription).toDict())
                    }
                }
            default:
                send(status: 404, reason: "Not Found", json: ["error": "unknown route \(request.method) \(request.path)"])
            }
        }

        private func send(status: Int, reason: String, json: [String: Any]) {
            let body: Data
            do {
                body = try JSONSerialization.data(withJSONObject: json, options: [])
            } catch {
                body = Data("{\"error\":\"encode failed\"}".utf8)
            }
            let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var out = Data(head.utf8)
            out.append(body)
            connection.send(content: out, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        }
    }
}
