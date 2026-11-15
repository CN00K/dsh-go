//  IShLoopbackService.swift
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.4).
//
//  Minimal loopback HTTP/WebSocket service so Node's ish-bridge.mjs
//  (stage 3) can reach the iSH guest. Binds 127.0.0.1 only (ephemeral
//  port), token auth (token generated here, written to
//  Application Support/NativeNode/ish-service.json, 0600). Never the
//  DSH token — the two tokens are isolated (design §2.4(c), §2.7).
//
//  Endpoints (design §2.4(c)):
//    GET  /ish/status  — readiness probe (200 when booted, 503 when not)
//    POST /ish/exec    — one-shot command, chunked NDJSON stream
//         body {command, stdinData?, cwd?, env?, fsContext?, timeoutMs?}
//         response: NDJSON {stream: "stdout"/"stderr", line} frames +
//         terminal frame {exitCode, durationMs}
//         (timeout: {exitCode: -3, timedOut: true, partialOutput})
//    WS   /ish/pty     — interactive terminal: binary frames carry raw
//         PTY bytes both ways; JSON control frames {type: "resize",
//         cols, rows} / {type: "close"}. Server kills the Guest process
//         group when the socket disconnects.
//
//  BYTE STREAM (the 2.3 log-ring fix, done properly here): guest output
//  is a byte stream, not lines. /ish/exec accumulates bytes in a
//  LineBuffer and only emits a line once its terminating \n arrives;
//  the trailing partial line is flushed at end-of-stream. No bytes are
//  lost and no line is split across bursts (the 2.3 ring logged a
//  burst's trailing partial line as a complete line). Splitting on the
//  \n byte (0x0A) is UTF-8 safe: 0x0A never appears inside a multi-byte
//  UTF-8 sequence. /ish/pty forwards raw PTY bytes with no line
//  splitting at all.
//
//  PTY SESSIONS: ISHKernel's interactive path is a single shared
//  _consoleTTY, so at most ONE /ish/pty session is active at a time.
//  A second WebSocket connection while one is active is closed with
//  code 1008 (policy violation). Each session spawns its own /bin/sh;
//  on disconnect (or shell exit) the shell's process group is killed
//  (ISHShellExecutor.killProcessGroup), never pid 1, never halt_system.
//
//  TRANSPORT: Network framework NWListener (TCP, 127.0.0.1, port 0).
//  HTTP/1.1 and WebSocket framing are implemented here by hand (no
//  third-party dependency): request parsing (Content-Length bodies
//  only), chunked streaming responses, WS upgrade (Sec-WebSocket-Accept
//  via CryptoKit SHA-1), frame parse/encode (masking, fragmentation,
//  ping/pong, close). v1 accepts Content-Length request bodies only;
//  chunked request bodies get 400.
//
//  LIFECYCLE: started by ISHRuntime after a successful boot, stopped
//  on reset. The token file is written on start (0600) and removed on
//  stop. If the listener fails to bind, start() logs and reports
//  isRunning == false (non-fatal — the dsh/ish channel still works).
//
//  THREADING: all service state is owned by a private serial queue.
//  NWConnection callbacks arrive on that queue; ISHShellExecutor
//  outputHandler calls arrive on arbitrary queues and are dispatched
//  onto it. Sends on a connection are serialised through a per-
//  connection serial queue so chunk order is preserved.

import CryptoKit
import Foundation
import Network

/// Loopback HTTP/WebSocket service exposing the iSH guest to Node.
final class IShLoopbackService {
  static let shared = IShLoopbackService()

  /// Token file (design §2.4(c)): Application Support/NativeNode/
  /// ish-service.json, 0600. Node's ish-bridge.mjs lazy-reads it.
  private static var serviceFileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NativeNode/ish-service.json")
  }

  /// WebSocket GUID (RFC 6455). Read by HTTPConnection.webSocketAccept
  /// (same file).
  fileprivate static let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  /// All service state is owned by this serial queue.
  private let queue = DispatchQueue(label: "me.zzuu.ish.loopback", qos: .userInitiated)

  /// The service queue (HTTPConnection runs its NWConnection on it, so
  /// all request parsing/routing happens here).
  fileprivate var workQueue: DispatchQueue { queue }

  private var listener: NWListener?
  private var token: String?
  private var boundPort: Int = 0
  private var running = false

  // Diagnostic (build 36): why the listener never becomes ready.
  // Build 35 showed `loopback DOWN` with no cause (start() is called
  // from performBoot, but `running` only flips in the .ready handler),
  // so track the listener's last state + error and expose them via
  // `diagnostics` for the failure page. All guarded by `queue`.
  private var listenerState = "not-started"
  private var lastErrorText: String?
  private var startCalled = false
  private var startCount = 0

  /// The single active PTY session (nil when none). Guarded by `queue`.
  private var ptySession: PTYSession?

  /// Live client connections, retained until they close (otherwise the
  /// HTTPConnection would deallocate mid-request). Guarded by `queue`.
  private var connections: [ObjectIdentifier: HTTPConnection] = [:]

  private init() {}

  // MARK: - Lifecycle

  var isRunning: Bool {
    queue.sync { running }
  }

  /// Current service info for debugging ({host, port, token}).
  /// Never log the token.
  var serviceInfo: [String: Any]? {
    queue.sync {
      guard running, let token else { return nil }
      return ["host": "127.0.0.1", "port": boundPort, "token": token]
    }
  }

  /// Diagnostic snapshot for the failure page (build 36): the
  /// listener's last state, the last error, and whether start() ran.
  var diagnostics: [String: Any] {
    queue.sync {
      var d: [String: Any] = [
        "state": listenerState,
        "startCalled": startCalled,
        "startCount": startCount,
        "boundPort": boundPort,
        "running": running,
      ]
      if let e = lastErrorText { d["lastError"] = e }
      return d
    }
  }

  /// Start listening on 127.0.0.1 (ephemeral port). Idempotent.
  /// Writes the token file (0600). Non-fatal on failure: logs and
  /// leaves isRunning == false.
  func start() {
    queue.async { [weak self] in
      guard let self else { return }
      if self.running { return }
      self.startCalled = true
      self.startCount += 1
      self.listenerState = "starting"
      let token = Self.makeToken()
      let parameters = NWParameters.tcp
      // NWListener(using:on:) takes a Port, not an Endpoint (no endpoint
      // overload in this SDK): bind an ephemeral port on all interfaces
      // and enforce loopback-only in accept(_:) below.
      guard let listener = try? NWListener(using: parameters, on: .any) else {
        self.listenerState = "create-failed"
        self.lastErrorText = "NWListener creation failed"
        NSLog("ish-loopback: NWListener creation failed")
        return
      }
      self.listenerState = "created"
      self.listener = listener
      self.token = token
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          self.queue.async { [weak self] in
            guard let self, let listener = self.listener else { return }
            self.boundPort = Int(listener.port?.rawValue ?? 0)
            self.running = self.boundPort > 0
            if self.running {
              self.listenerState = "ready"
              self.writeServiceFile(port: self.boundPort, token: token)
              NSLog("ish-loopback: listening on 127.0.0.1:\(self.boundPort)")
            } else {
              self.listenerState = "ready-no-port"
              self.lastErrorText = "listener ready but no port assigned"
              NSLog("ish-loopback: listener ready but no port assigned")
            }
          }
        case .failed(let error):
          NSLog("ish-loopback: listener failed: \(error)")
          self.queue.async { [weak self] in
            self?.running = false
            self?.boundPort = 0
            self?.listenerState = "failed"
            self?.lastErrorText = "\(error)"
          }
        case .cancelled:
          self.queue.async { [weak self] in
            self?.running = false
            self?.boundPort = 0
            self?.listenerState = "cancelled"
          }
        case .waiting(let error):
          self.queue.async { [weak self] in
            self?.listenerState = "waiting"
            self?.lastErrorText = "\(error)"
          }
        case .setup:
          self.queue.async { [weak self] in
            self?.listenerState = "setup"
          }
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      listener.start(queue: self.queue)
    }
  }

  /// Stop listening, close the PTY session (kills its shell), remove
  /// the token file. Idempotent.
  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      if let session = self.ptySession {
        // close() clears ptySession + the output sink via
        // clearPTYSession (do not nil ptySession first — the sink
        // would leak).
        session.close(reason: "service stopped")
      }
      self.listener?.cancel()
      self.listener = nil
      self.token = nil
      self.boundPort = 0
      self.running = false
      try? FileManager.default.removeItem(at: Self.serviceFileURL)
      NSLog("ish-loopback: stopped")
    }
  }

  // MARK: - Token + service file

  private static func makeToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if rc != errSecSuccess {
      // Fallback (should not happen): UUID is 128-bit random.
      return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func writeServiceFile(port: Int, token: String) {
    let url = Self.serviceFileURL
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let payload: [String: Any] = ["host": "127.0.0.1", "port": port, "token": token]
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      // 0600: only this app (and its Node child) may read the token.
      try data.write(to: url, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      NSLog("ish-loopback: failed to write ish-service.json: \(error)")
    }
  }

  // MARK: - Accept

  private func accept(_ connection: NWConnection) {
    // Loopback-only enforcement (see start(): the listener binds all
    // interfaces because NWListener has no endpoint overload). Drop any
    // remote that is not 127.0.0.1 / ::1 before any HTTP parsing;
    // Bearer auth still applies on top of this.
    guard case .hostPort(let host, _) = connection.endpoint else {
      connection.cancel()
      return
    }
    let isLoopback: Bool
    switch host {
    case .ipv4(let address):
      isLoopback = address == IPv4Address("127.0.0.1")
    case .ipv6(let address):
      isLoopback = address == IPv6Address("::1")
    case .name(let name, _):
      isLoopback = (name == "localhost" || name == "127.0.0.1" || name == "::1")
    @unknown default:
      isLoopback = false
    }
    guard isLoopback else {
      NSLog("ish-loopback: rejecting non-loopback connection")
      connection.cancel()
      return
    }
    let conn = HTTPConnection(connection: connection, service: self)
    connections[ObjectIdentifier(conn)] = conn
    conn.start()
  }

  /// Called by HTTPConnection when it closes; drops the retain.
  fileprivate func connectionClosed(_ connection: HTTPConnection) {
    queue.async { [weak self] in
      self?.connections.removeValue(forKey: ObjectIdentifier(connection))
    }
  }

  /// Bearer token check for a request's Authorization header.
  /// Called on `queue` (from route()) — read the token directly;
  /// do NOT queue.sync here (same-queue sync deadlocks).
  fileprivate func authorized(headers: [String: String]) -> Bool {
    guard let expected = token else { return false }
    guard let auth = headers["authorization"], auth.hasPrefix("Bearer ") else { return false }
    let presented = String(auth.dropFirst("Bearer ".count))
    // Constant-time compare (tokens are secrets; avoid timing leaks).
    guard presented.count == expected.count else { return false }
    var diff: UInt8 = 0
    for (a, b) in zip(presented.utf8, expected.utf8) { diff |= a ^ b }
    return diff == 0
  }

  /// Forward raw PTY bytes to the active session (called from
  /// ISHRuntime.ptyOutputSink on the main queue).
  fileprivate func forwardPTYOutput(_ data: Data) {
    queue.async { [weak self] in
      guard let self, let session = self.ptySession, !session.closed else { return }
      session.sendBinary(data)
    }
  }

  /// Register the active PTY session (called by HTTPConnection after a
  /// successful /ish/pty upgrade). Returns false if one is already
  /// active (the caller then closes the new connection with 1008).
  fileprivate func registerPTYSession(_ session: PTYSession) -> Bool {
    // Called on `queue` (HTTPConnection runs there).
    if ptySession != nil { return false }
    ptySession = session
    ISHRuntime.ptyOutputSink = { [weak self] data in
      self?.forwardPTYOutput(data)
    }
    return true
  }

  /// Clear the active PTY session (called when it ends). Idempotent.
  fileprivate func clearPTYSession(_ session: PTYSession) {
    // Called on `queue`.
    if ptySession === session {
      ptySession = nil
      ISHRuntime.ptyOutputSink = nil
    }
  }
}

// MARK: - HTTP connection (one NWConnection, one request, then close
//         — except /ish/pty, which upgrades to WebSocket)

/// A single client connection. Reads an HTTP/1.1 request (Content-Length
/// bodies only), routes it, and either answers and closes or upgrades
/// to WebSocket (/ish/pty). All state is owned by the service queue.
private final class HTTPConnection {
  private let connection: NWConnection
  private weak var service: IShLoopbackService?
  /// Serialises all sends on this connection (chunk order matters).
  private let sendQueue = DispatchQueue(label: "me.zzuu.ish.loopback.send")
  private var buffer = Data()
  private var closed = false
  /// Set once the request is fully read (headers + body).
  private var request: HTTPRequest?
  /// Live exec/pty handler while a request is being served.
  private var execSession: ExecSession?
  private var wsSession: WSConnection?

  init(connection: NWConnection, service: IShLoopbackService) {
    self.connection = connection
    self.service = service
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        self?.receive()
      case .failed, .cancelled:
        self?.close()
      default:
        break
      }
    }
    // Run on the service queue so all request parsing/routing happens
    // on one serial queue (no extra locking for service state).
    connection.start(queue: service?.workQueue ?? DispatchQueue.main)
  }

  private func receive() {
    guard !closed else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let error {
        NSLog("ish-loopback: receive error: \(error)")
        self.close()
        return
      }
      if let data, !data.isEmpty {
        self.buffer.append(data)
        self.processBuffer()
      }
      if isComplete {
        // Peer half-closed (EOF). If a request is being served, let
        // the handler finish and close the connection itself (the
        // response must still go out); otherwise close now.
        if self.request == nil && self.wsSession == nil && self.execSession == nil {
          self.close()
        }
        return
      }
      if !self.closed { self.receive() }
    }
  }

  /// Try to parse a complete HTTP request from the buffer. If the
  /// connection already upgraded to WebSocket, frames go to WSConnection.
  private func processBuffer() {
    if let ws = wsSession {
      ws.feed(buffer)
      buffer.removeAll()
      return
    }
    guard request == nil else { return } // Already dispatched.
    guard let headerEnd = findHeaderEnd(in: buffer) else {
      if buffer.count > 64 * 1024 {
        sendError(431, "Request Header Fields Too Large")
      }
      return // Need more data.
    }
    let headerData = buffer[..<headerEnd]
    guard let headerText = String(data: headerData, encoding: .utf8) else {
      sendError(400, "Request headers are not valid UTF-8")
      return
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      sendError(400, "Empty request")
      return
    }
    let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count == 3 else {
      sendError(400, "Malformed request line")
      return
    }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    let method = String(parts[0]).uppercased()
    let path = String(parts[1])
    // Chunked request bodies are not supported in v1 (curl/node send
    // Content-Length for the small JSON bodies /ish/exec uses).
    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
      sendError(400, "Chunked request bodies are not supported")
      return
    }
    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    if contentLength < 0 || contentLength > 16 * 1024 * 1024 {
      sendError(413, "Request body too large")
      return
    }
    let bodyStart = headerEnd + 4 // Skip the "\r\n\r\n".
    guard buffer.count >= bodyStart + contentLength else { return } // Need more data.
    let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
    buffer.removeAll()
    request = HTTPRequest(method: method, path: path, headers: headers, body: body)
    route()
  }

  /// Index of the "\r\n\r\n" that ends the headers, or nil.
  private func findHeaderEnd(in data: Data) -> Data.Index? {
    // Data has no built-in subdata search; scan for the 4-byte sequence.
    guard data.count >= 4 else { return nil }
    let pattern: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
    var i = data.startIndex
    while i + 3 < data.endIndex {
      if data[i] == pattern[0] && data[i + 1] == pattern[1]
          && data[i + 2] == pattern[2] && data[i + 3] == pattern[3] {
        return i
      }
      i = data.index(after: i)
    }
    return nil
  }

  // MARK: - Routing

  private func route() {
    guard let request, let service else { close(); return }
    // Auth: every endpoint requires the Bearer token (never the DSH
    // token — the two are isolated by design).
    guard service.authorized(headers: request.headers) else {
      sendJSON(status: 401, reason: "Unauthorized", object: ["error": "unauthorized"])
      return
    }
    switch (request.method, request.path) {
    case ("GET", "/ish/status"):
      handleStatus()
    case ("POST", "/ish/exec"):
      handleExec(request)
    case ("GET", "/ish/pty"):
      handlePTYUpgrade(request)
    default:
      sendJSON(status: 404, reason: "Not Found", object: ["error": "not_found"])
    }
  }

  private func handleStatus() {
    let kernel = ISHKernel.shared
    var count: Int32 = 0
    var anon: UInt64 = 0
    let n = kernel.getGuestProcessCount(&count, anonBytes: &anon)
    if kernel.isBooted {
      sendJSON(status: 200, reason: "OK", object: [
        "status": "ok",
        "booted": true,
        "guestProcessCount": Int(n),
        "guestMemoryBytes": Int(anon),
      ])
    } else {
      sendJSON(status: 503, reason: "Service Unavailable", object: [
        "status": "not_booted",
        "booted": false,
        "error": "ish_not_booted",
      ])
    }
  }

  // MARK: - Sending

  /// Send bytes on the connection, serialised through sendQueue.
  fileprivate func send(_ data: Data, completion: @escaping () -> Void = {}) {
    sendQueue.async { [weak self] in
      guard let self, !self.closed else { completion(); return }
      self.connection.send(content: data, completion: .contentProcessed { _ in
        completion()
      })
    }
  }

  /// Send a complete HTTP response (headers + optional body) and close.
  private func sendHTTP(status: Int, reason: String, headers: [String: String], body: Data?) {
    var text = "HTTP/1.1 \(status) \(reason)\r\n"
    var all = headers
    all["Content-Length"] = "\(body?.count ?? 0)"
    all["Connection"] = "close"
    for (name, value) in all.sorted(by: { $0.key < $1.key }) {
      text += "\(name): \(value)\r\n"
    }
    text += "\r\n"
    var payload = Data(text.utf8)
    if let body { payload.append(body) }
    send(payload) { [weak self] in self?.close() }
  }

  private func sendJSON(status: Int, reason: String, object: [String: Any]) {
    let body = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
    sendHTTP(status: status, reason: reason,
             headers: ["Content-Type": "application/json"], body: body)
  }

  private func sendError(_ status: Int, _ message: String) {
    let reason: String
    switch status {
    case 400: reason = "Bad Request"
    case 401: reason = "Unauthorized"
    case 404: reason = "Not Found"
    case 413: reason = "Payload Too Large"
    case 431: reason = "Request Header Fields Too Large"
    case 503: reason = "Service Unavailable"
    default: reason = "Error"
    }
    sendJSON(status: status, reason: reason, object: ["error": message])
  }

  /// Close, dispatching to the service queue (for callers on other
  /// queues, e.g. ExecSession). Idempotent.
  func closeFromAnyQueue() {
    if let service {
      service.workQueue.async { [weak self] in self?.close() }
    } else {
      close()
    }
  }

  /// Close the connection (idempotent). Cancels any live exec/pty
  /// session (which kills its guest process group).
  func close() {
    guard !closed else { return }
    closed = true
    execSession?.cancel()
    execSession = nil
    wsSession?.closeLocal()
    wsSession = nil
    connection.cancel()
    service?.connectionClosed(self)
  }
}

/// A parsed HTTP request (headers + complete body).
private struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data
}

// MARK: - /ish/exec (one-shot command, chunked NDJSON stream)

extension HTTPConnection {
  func handleExec(_ request: HTTPRequest) {
    guard service != nil else { close(); return }
    guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
          let command = json["command"] as? String, !command.isEmpty else {
      sendJSON(status: 400, reason: "Bad Request", object: ["error": "command is required"])
      return
    }
    var stdinData: Data?
    if let b64 = json["stdinData"] as? String {
      guard let decoded = Data(base64Encoded: b64) else {
        sendJSON(status: 400, reason: "Bad Request", object: ["error": "stdinData is not valid base64"])
        return
      }
      stdinData = decoded
    }
    var fsContext: UInt64 = 0
    if let n = json["fsContext"] as? NSNumber { fsContext = n.uint64Value }
    var timeoutMs = 30_000
    if let n = json["timeoutMs"] as? NSNumber { timeoutMs = n.intValue }
    timeoutMs = max(1_000, min(timeoutMs, 900_000))
    let shellCommand = Self.buildShellCommand(
      command: command,
      cwd: json["cwd"] as? String,
      env: json["env"] as? [String: String])
    guard ISHKernel.shared.isBooted else {
      sendJSON(status: 503, reason: "Service Unavailable", object: ["error": "ish_not_booted"])
      return
    }
    let session = ExecSession(connection: self)
    execSession = session
    session.start(command: shellCommand, stdinData: stdinData,
                  fsContext: fsContext, timeout: TimeInterval(timeoutMs) / 1000.0)
  }

  /// Single-quote a string for /bin/sh (ash). Embedded single quotes
  /// become '\'' (close quote, escaped quote, reopen quote).
  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Build the /bin/sh -c command from the request: optional env
  /// exports, then an optional cd, then the command itself. Only valid
  /// shell identifiers are exported (others are ignored).
  static func buildShellCommand(command: String, cwd: String?, env: [String: String]?) -> String {
    var prefix = ""
    if let env, !env.isEmpty {
      for key in env.keys.sorted() {
        guard isValidShellName(key), let value = env[key] else { continue }
        prefix += "export \(key)=\(shellQuote(value)); "
      }
    }
    if let cwd, !cwd.isEmpty {
      prefix += "cd -- \(shellQuote(cwd)) && "
    }
    return prefix + command
  }

  /// Shell variable names are ASCII [A-Za-z_][A-Za-z0-9_]* (checked
  /// on scalar values — Unicode.Scalar has no isLetter).
  static func isValidShellName(_ name: String) -> Bool {
    let scalars = name.unicodeScalars
    guard let first = scalars.first else { return false }
    func isAlphaUnderscore(_ s: Unicode.Scalar) -> Bool {
      (s.value >= 65 && s.value <= 90)   // A-Z
        || (s.value >= 97 && s.value <= 122) // a-z
        || s.value == 95 // _
    }
    func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }
    guard isAlphaUnderscore(first) else { return false }
    return scalars.allSatisfy { isAlphaUnderscore($0) || isDigit($0) }
  }
}

/// Proper byte-stream → line buffering (the 2.3 log-ring fix, done
/// right). Bytes accumulate; a line is emitted only once its
/// terminating \n arrives; the trailing partial line is flushed at
/// end-of-stream. No bytes are lost and no line is split across
/// bursts. Splitting on the \n byte is UTF-8 safe (0x0A never appears
/// inside a multi-byte UTF-8 sequence). A trailing \r is stripped
/// (CRLF tolerance).
private final class LineBuffer {
  private var pending = Data()

  /// Append bytes; returns complete lines (without the trailing \n).
  func append(_ data: Data) -> [Data] {
    pending.append(data)
    var lines: [Data] = []
    while let nl = pending.firstIndex(of: 0x0A) {
      var line = pending[pending.startIndex..<nl]
      if line.last == 0x0D { line = line.dropLast() }
      lines.append(Data(line))
      pending.removeSubrange(pending.startIndex...nl)
    }
    return lines
  }

  /// Flush the remaining partial line (if any) at end-of-stream.
  func flush() -> Data? {
    guard !pending.isEmpty else { return nil }
    var line = pending
    if line.last == 0x0D { line = line.dropLast() }
    pending.removeAll()
    return Data(line)
  }
}

/// One /ish/exec request: streams the executor's output as chunked
/// NDJSON and ends with a terminal frame. All state is owned by a
/// private serial queue (the executor's outputHandler arrives on
/// arbitrary queues).
private final class ExecSession {
  private weak var connection: HTTPConnection?
  private let queue = DispatchQueue(label: "me.zzuu.ish.loopback.exec")
  private var stdoutBuffer = LineBuffer()
  private var stderrBuffer = LineBuffer()
  /// Decoded output text so far (for the timeout frame's partialOutput).
  private var partialOutput = ""
  private var finished = false
  private var execution: ISHShellExecution?

  init(connection: HTTPConnection) {
    self.connection = connection
  }

  func start(command: String, stdinData: Data?, fsContext: UInt64, timeout: TimeInterval) {
    // Send the chunked headers first, then stream.
    connection?.sendChunkedHeaders()
    let started = Date()
    execution = ISHShellExecutor.shared().executeCommand(
      command, stdinData: stdinData, fsContext: fsContext, timeout: timeout,
      outputHandler: { [weak self] isStderr, chunk in
        self?.queue.async { [weak self] in self?.onChunk(isStderr: isStderr, chunk: chunk) }
      },
      completion: { [weak self] result in
        self?.queue.async { [weak self] in self?.onComplete(result: result, started: started) }
      })
  }

  /// Cancel (client disconnected): kills the guest process group; the
  /// completion still fires but the connection is closed, so sends are
  /// no-ops.
  func cancel() {
    queue.async { [weak self] in
      self?.execution?.cancel()
    }
  }

  private func onChunk(isStderr: Bool, chunk: Data) {
    guard !finished else { return }
    let stream = isStderr ? "stderr" : "stdout"
    let buffer = isStderr ? stderrBuffer : stdoutBuffer
    for line in buffer.append(chunk) {
      sendLine(stream: stream, lineData: line)
    }
  }

  private func onComplete(result: ISHShellExecutionResult, started: Date) {
    guard !finished else { return }
    finished = true
    // Flush trailing partial lines (if any) as final lines.
    if let line = stdoutBuffer.flush() { sendLine(stream: "stdout", lineData: line) }
    if let line = stderrBuffer.flush() { sendLine(stream: "stderr", lineData: line) }
    let durationMs = Int(Date().timeIntervalSince(started) * 1000)
    var frame: [String: Any] = [
      "exitCode": result.exitCode,
      "durationMs": durationMs,
    ]
    if result.timedOut {
      frame["timedOut"] = true
      frame["partialOutput"] = partialOutput
    }
    if result.cancelled {
      frame["cancelled"] = true
    }
    sendJSONFrame(frame)
    connection?.sendChunkEnd()
    // Close on the service queue (ExecSession runs on its own queue;
    // HTTPConnection state is owned by the service queue).
    connection?.closeFromAnyQueue()
  }

  /// Encode one NDJSON line ({stream, line}) and send it as a chunk.
  /// The line bytes are decoded lossy-UTF-8 (a truncated multi-byte
  /// character at end-of-stream becomes U+FFFD — the bytes themselves
  /// were already preserved in the buffer; only the JSON rendering is
  /// lossy, and only for a truncated final character).
  private func sendLine(stream: String, lineData: Data) {
    let line = String(decoding: lineData, as: UTF8.self)
    partialOutput += line + "\n"
    sendJSONFrame(["stream": stream, "line": line])
  }

  private func sendJSONFrame(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return }
    var chunk = data
    chunk.append(0x0A) // NDJSON: one JSON object per line.
    connection?.sendChunk(chunk)
  }
}

// MARK: - Chunked response helpers (HTTPConnection)

extension HTTPConnection {
  /// Send the 200 headers for a chunked NDJSON response.
  fileprivate func sendChunkedHeaders() {
    let text = "HTTP/1.1 200 OK\r\n"
      + "Content-Type: application/x-ndjson\r\n"
      + "Transfer-Encoding: chunked\r\n"
      + "Connection: close\r\n"
      + "\r\n"
    send(Data(text.utf8))
  }

  /// Send one chunk: "<hex-length>\r\n<data>\r\n".
  fileprivate func sendChunk(_ data: Data) {
    var prefix = Data("\(String(data.count, radix: 16))\r\n".utf8)
    prefix.append(data)
    prefix.append(Data("\r\n".utf8))
    send(prefix)
  }

  /// Send the terminating "0\r\n\r\n" chunk (does not close; the
  /// caller closes after).
  fileprivate func sendChunkEnd() {
    send(Data("0\r\n\r\n".utf8))
  }
}

// MARK: - /ish/pty (WebSocket upgrade + interactive terminal)

extension HTTPConnection {
  func handlePTYUpgrade(_ request: HTTPRequest) {
    guard let service else { close(); return }
    guard request.headers["upgrade"]?.lowercased() == "websocket",
          request.headers["connection"]?.lowercased().contains("upgrade") == true,
          let key = request.headers["sec-websocket-key"],
          request.headers["sec-websocket-version"] == "13" else {
      sendJSON(status: 400, reason: "Bad Request",
               object: ["error": "expected a WebSocket upgrade"])
      return
    }
    guard ISHKernel.shared.isBooted else {
      sendJSON(status: 503, reason: "Service Unavailable",
               object: ["error": "ish_not_booted"])
      return
    }
    let accept = Self.webSocketAccept(for: key)
    let response = "HTTP/1.1 101 Switching Protocols\r\n"
      + "Upgrade: websocket\r\n"
      + "Connection: Upgrade\r\n"
      + "Sec-WebSocket-Accept: \(accept)\r\n"
      + "\r\n"
    send(Data(response.utf8)) { [weak self] in
      guard let self, let service = self.service else { return }
      // Switch this connection to WebSocket mode. The WSConnection
      // spawns the shell and registers the PTY session; if a session
      // is already active it closes with 1008.
      let ws = WSConnection(httpConnection: self, service: service)
      self.wsSession = ws
      ws.start()
    }
  }

  /// Sec-WebSocket-Accept = base64(SHA1(key + GUID)) (RFC 6455).
  static func webSocketAccept(for key: String) -> String {
    let input = Data((key + IShLoopbackService.webSocketGUID).utf8)
    let digest = Insecure.SHA1.hash(data: input)
    return Data(digest).base64EncodedString()
  }
}

/// One /ish/pty WebSocket connection: frame parse/encode + the guest
/// shell it drives. All methods run on the service queue, except
/// sendBinary (called from the PTY output sink via the service queue)
/// and the shell-exit observer (main queue, dispatches to the service
/// queue). A WSConnection owns exactly one PTYSession.
private final class WSConnection {
  private weak var httpConnection: HTTPConnection?
  private weak var service: IShLoopbackService?
  private var buffer = Data()
  private var fragmentBuffer = Data()
  private var fragmentOpcode: UInt8 = 0
  private var closed = false
  private var ptySession: PTYSession?

  init(httpConnection: HTTPConnection, service: IShLoopbackService) {
    self.httpConnection = httpConnection
    self.service = service
  }

  /// Spawn the shell and register the PTY session. Called after the
  /// 101 response is sent.
  func start() {
    guard !closed else { return }
    var pid: Int32 = 0
    let rc = ISHKernel.shared.executeCommand(["/bin/sh"], pid: &pid)
    guard rc == 0, pid > 0 else {
      NSLog("ish-loopback: pty shell spawn failed (rc=\(rc))")
      close(code: 1011, reason: "shell spawn failed")
      return
    }
    let session = PTYSession(guestPid: Int(pid), service: service, ws: self)
    guard let service, service.registerPTYSession(session) else {
      // Another PTY session is already active (single shared
      // _consoleTTY). Kill the shell we just spawned and refuse.
      ISHShellExecutor.shared().killProcessGroup(pid)
      close(code: 1008, reason: "another pty session is active")
      return
    }
    ptySession = session
    NSLog("ish-loopback: pty session started (guest pid \(pid))")
  }

  /// Feed inbound bytes (called by HTTPConnection after the upgrade).
  func feed(_ data: Data) {
    guard !closed else { return }
    buffer.append(data)
    parseFrames()
  }

  // MARK: - Frame parsing (RFC 6455)

  private func parseFrames() {
    while !closed {
      guard buffer.count >= 2 else { return }
      let b0 = buffer[buffer.startIndex]
      let b1 = buffer[buffer.startIndex + 1]
      let fin = (b0 & 0x80) != 0
      let opcode = b0 & 0x0F
      let masked = (b1 & 0x80) != 0
      var length = Int(b1 & 0x7F)
      var headerLen = 2
      if length == 126 {
        guard buffer.count >= 4 else { return }
        length = Int(buffer[buffer.startIndex + 2]) << 8
          | Int(buffer[buffer.startIndex + 3])
        headerLen = 4
      } else if length == 127 {
        guard buffer.count >= 10 else { return }
        var value: UInt64 = 0
        for i in 0..<8 {
          value = (value << 8) | UInt64(buffer[buffer.startIndex + 2 + i])
        }
        guard value <= UInt64(Int.max) else {
          close(code: 1009, reason: "message too large")
          return
        }
        length = Int(value)
        headerLen = 10
      }
      var maskKey: [UInt8] = []
      if masked {
        guard buffer.count >= headerLen + 4 else { return }
        maskKey = (0..<4).map { buffer[buffer.startIndex + headerLen + $0] }
        headerLen += 4
      }
      guard buffer.count >= headerLen + length else { return }
      var payload = Data(buffer[(buffer.startIndex + headerLen)..<(buffer.startIndex + headerLen + length)])
      if masked {
        for i in payload.indices { payload[i] ^= maskKey[i % 4] }
      }
      buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + headerLen + length))
      handleFrame(fin: fin, opcode: opcode, payload: payload)
    }
  }

  private func handleFrame(fin: Bool, opcode: UInt8, payload: Data) {
    switch opcode {
    case 0x8: // Close — echo the code, then close.
      var code: UInt16 = 1000
      if payload.count >= 2 {
        code = UInt16(payload[0]) << 8 | UInt16(payload[1])
      }
      sendCloseFrame(code: code)
      closeLocal()
      return
    case 0x9: // Ping — reply pong with the same payload.
      sendFrame(opcode: 0xA, payload: payload)
      return
    case 0xA: // Pong — ignore.
      return
    case 0x0, 0x1, 0x2: // Continuation / text / binary.
      break
    default: // Unknown opcode — protocol error.
      close(code: 1002, reason: "unknown opcode")
      return
    }
    if opcode != 0x0 {
      fragmentOpcode = opcode
      fragmentBuffer = payload
    } else {
      fragmentBuffer.append(payload)
    }
    if fin {
      let messageOpcode = fragmentOpcode
      let message = fragmentBuffer
      fragmentBuffer = Data()
      onMessage(opcode: messageOpcode, payload: message)
    }
  }

  private func onMessage(opcode: UInt8, payload: Data) {
    switch opcode {
    case 0x1: // Text — JSON control frame.
      guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let type = json["type"] as? String else { return }
      switch type {
      case "resize":
        if let cols = json["cols"] as? Int, let rows = json["rows"] as? Int,
           cols > 0, rows > 0 {
          ISHKernel.shared.setTerminalSize(Int32(cols), rows: Int32(rows))
        }
      case "close":
        close(code: 1000, reason: "client requested close")
      default:
        break
      }
    case 0x2: // Binary — PTY input (raw bytes to the guest shell).
      ISHKernel.shared.sendInput(payload)
    default:
      break
    }
  }

  // MARK: - Sending (server frames are never masked)

  /// Send a binary frame (PTY output). Called from the service queue
  /// via the PTY output sink.
  func sendBinary(_ data: Data) {
    guard !closed else { return }
    sendFrame(opcode: 0x2, payload: data)
  }

  private func sendFrame(opcode: UInt8, payload: Data) {
    var header = Data()
    header.append(0x80 | opcode) // FIN + opcode.
    let count = payload.count
    if count < 126 {
      header.append(UInt8(count))
    } else if count <= 0xFFFF {
      header.append(126)
      header.append(UInt8((count >> 8) & 0xFF))
      header.append(UInt8(count & 0xFF))
    } else {
      header.append(127)
      let value = UInt64(count)
      for shift in stride(from: 56, through: 0, by: -8) {
        header.append(UInt8((value >> UInt64(shift)) & 0xFF))
      }
    }
    var frame = header
    frame.append(payload)
    httpConnection?.send(frame)
  }

  private func sendCloseFrame(code: UInt16) {
    var payload = Data()
    payload.append(UInt8((code >> 8) & 0xFF))
    payload.append(UInt8(code & 0xFF))
    sendFrame(opcode: 0x8, payload: payload)
  }

  /// Send a close frame (if not already closed) and close the
  /// connection. Idempotent.
  func close(code: UInt16, reason: String) {
    guard !closed else { return }
    NSLog("ish-loopback: closing pty websocket (code \(code)): \(reason)")
    sendCloseFrame(code: code)
    closeLocal()
  }

  /// Close from the local side (service stopping / shell exited /
  /// peer close). Kills the shell's process group via the session.
  func closeLocal() {
    guard !closed else { return }
    closed = true
    ptySession?.close(reason: "websocket closed")
    ptySession = nil
    httpConnection?.close()
  }
}

/// One interactive guest shell (/bin/sh) driven by a /ish/pty
/// WebSocket. The shell is a child of init (pid >= 2); on close its
/// process group is killed (never pid 1, never halt_system).
private final class PTYSession {
  let guestPid: Int
  private weak var service: IShLoopbackService?
  private weak var ws: WSConnection?
  /// Read by IShLoopbackService.forwardPTYOutput (same file).
  fileprivate var closed = false
  private var exitObserver: NSObjectProtocol?

  init(guestPid: Int, service: IShLoopbackService?, ws: WSConnection) {
    self.guestPid = guestPid
    self.service = service
    self.ws = ws
    // When the shell exits on its own (e.g. the user typed `exit`),
    // close the WebSocket so the client knows the shell is gone.
    exitObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.ISHGuestExited, object: nil, queue: .main
    ) { [weak self] note in
      guard let self else { return }
      guard let pid = note.userInfo?["pid"] as? NSNumber,
            pid.intValue == self.guestPid else { return }
      // The notification fires on the main queue; the WS lives on the
      // service queue.
      if let service = self.service {
        service.workQueue.async { [weak self] in
          self?.ws?.close(code: 1000, reason: "shell exited")
        }
      } else {
        self.ws?.close(code: 1000, reason: "shell exited")
      }
    }
  }

  /// Forward raw PTY bytes to the WebSocket (binary frame). Called
  /// from the service queue via ISHRuntime.ptyOutputSink.
  func sendBinary(_ data: Data) {
    guard !closed else { return }
    ws?.sendBinary(data)
  }

  /// Kill the shell's process group and unregister. Idempotent.
  /// Runs on the service queue.
  func close(reason: String) {
    guard !closed else { return }
    closed = true
    if let observer = exitObserver {
      NotificationCenter.default.removeObserver(observer)
      exitObserver = nil
    }
    ISHShellExecutor.shared().killProcessGroup(Int32(guestPid))
    service?.clearPTYSession(self)
    NSLog("ish-loopback: pty session closed (guest pid \(guestPid)): \(reason)")
  }
}
