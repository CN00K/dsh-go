//  IShLoopbackService.swift
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.4).
//
//  Minimal loopback HTTP/WebSocket service so Node's ish-bridge.mjs
//  (stage 3) can reach the iSH guest. Binds 127.0.0.1 only (ephemeral
//  port), token auth (token generated here, written to
//  Application Support/runtime/rootfs/ish-service.json, 0600). Never the
//  DSH token — the two tokens are isolated (design §2.4(c), §2.7).
//
//  Endpoints (design §2.4(c)):
//    GET  /ish/status  — readiness probe (200 when booted, 503 when not)
//    POST /ish/exec    — one-shot command, chunked NDJSON stream
//         body {command, stdinData?, cwd?, env?, fsContext?, timeoutMs?,
//               tty?, cols?, rows?}
//         response: NDJSON {stream: "stdout"/"stderr", line} frames +
//         terminal frame {exitCode, durationMs}
//         (timeout: {exitCode: -3, timedOut: true, partialOutput})
//         tty exec: body tty:true runs the command on a fresh fake
//         PTY (merged stream, isStderr always "stdout"); the terminal
//         frame adds {tty: true}. Refused with 429 when the kernel's
//         PTY session cap is reached.
//    WS   /ish/pty     — interactive terminal: binary frames carry raw
//         PTY bytes both ways; JSON control frames {type: "resize",
//         cols, rows} / {type: "close"}. The server sends one text
//         frame right after the upgrade: {type: "session",
//         sessionId} — the kernel session id for this socket. Server
//         kills the Guest process group when the socket disconnects.
//
//  PERSISTENT SHELL WORKER (ENV-04, stage 5.4): one long-lived guest
//  /bin/bash per DSH session, so agent execs stop paying a fresh
//  process creation + shell start per command (1–2 s of fixed cost
//  under emulation). The worker is owned by ISHShellExecutor
//  (ISHWorkerShell); the loopback only routes commands to it:
//    POST /ish/worker/run  — run one command on the session worker
//         body {command, sessionId, cwd?, env?, nonce, timeoutMs?,
//               fsContext?}
//         response: NDJSON {stream, line} frames + terminal frame
//         {exitCode, durationMs, timedOut?, cancelled?, workerDied?}.
//         The command is wrapped (buildWorkerCommand): per-command env
//         overlay (saved + restored), `{ cmd; } < /dev/null` so a
//         stdin-reading command sees EOF instead of eating the next
//         command off the worker's stdin, an END marker line
//         (`__DSH_END__<nonce>:<exitCode>:<cwd>`, stderr) and a jobs
//         snapshot (`jobs -l` + `jobs -p`, nonce-tagged). The bridge
//         swallows the protocol lines; the terminal frame only arrives
//         after the marker AND the snapshot, so the bridge's job table
//         is up to date when the run resolves.
//         A `&` background job is a job OF THE WORKER SHELL (no
//         subshell wrapper), so `jobs -l` / `kill %1` work natively in
//         the worker, and the bridge's ishWorkerJobs reads the same
//         snapshot (it runs `:` on the worker — no separate control
//         channel is needed). Timeout is a NO-OUTPUT watchdog (120 s
//         of silence kills the foreground command; 5 s grace, then the
//         worker is killed and rebuilt) plus the 600 s wall-clock
//         backstop. Aborting the request kills the current command,
//         never the worker. One-shot /ish/exec stays as the fallback
//         (no session id, stdin data, tty exec, or worker unavailable).
//    POST /ish/worker/jobs/kill — kill one background job
//         body {sessionId, pid} → {killed: true} or 404
//         {error: "job_not_found"} (the pid must be a live descendant
//         of the worker; the worker itself is never a valid target).
//    POST /ish/worker/stop — stop one session's worker
//         body {sessionId} → {stopped: true}; kills the worker's whole
//         process tree, so no background job survives its session.
//    GET  /ish/worker/jobs does NOT exist on purpose: the job list is
//         the in-band snapshot after every run, and ishWorkerJobs just
//         runs `:` to refresh it — a dedicated endpoint would need a
//         second control channel into the worker's stdin for zero
//         benefit (it would queue behind the running command anyway).
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
//  PTY SESSIONS (stage 5.3, multi-terminal): ISHKernel routes every
//  guest PTY write to the session that owns its tty (per-session
//  buffer + output handler), so any number of /ish/pty sessions up to
//  ISHPtyMaxSessions (8) can be live at once. Each WSConnection owns
//  exactly one PTYSession (one kernel session id, one guest /bin/sh);
//  on disconnect (or shell exit) the shell's process group is killed
//  (ISHShellExecutor.killProcessGroup via ISHKernel.closePtySession),
//  never pid 1, never halt_system. The old single-session 1008 refusal
//  now only fires at the cap. Output routing no longer goes through
//  ISHRuntime.ptyOutputSink (that sink can only point at ONE session);
//  each session registers its own kernel output handler, and the
//  legacy outputCallback fan-out still feeds the dsh/ish log ring.
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

  /// Token file (design §2.4(c)): Application Support/runtime/rootfs/
  /// ish-service.json, 0600. Node's ish-bridge.mjs lazy-reads it.
  private static var serviceFileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("runtime/rootfs/ish-service.json")
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

  /// Live PTY sessions by kernel session id (nil when none).
  /// Guarded by `queue`.
  private var ptySessions: [String: PTYSession] = [:]

  /// Live client connections, retained until they close (otherwise the
  /// HTTPConnection would deallocate mid-request). Guarded by `queue`.
  private var connections: [ObjectIdentifier: HTTPConnection] = [:]

  /// Sessions with a worker run currently in flight (M-10). A worker
  /// has a single output-handler slot (beginWorkerRun overwrites it),
  /// so a second concurrent run on the same session would steal the
  /// first run's output and hang it until the wall-clock timeout.
  /// Claim/release are lock-guarded and release is idempotent (a
  /// double release just removes an absent element), so it is safe to
  /// release from every terminal path: WorkerSession.completeRun, its
  /// cancel-before-attach branch, and deinit as a backstop (the
  /// connection can drop the session mid-cancel, so the run may never
  /// reach completeRun); handleWorkerRun also releases on its
  /// worker_start_failed paths.
  fileprivate static let workerRunLock = NSLock()
  fileprivate static var workerRunsInFlight: Set<String> = []

  /// Claim the in-flight slot for sessionId; false when a run is
  /// already in flight on this session.
  fileprivate static func claimWorkerRun(sessionId: String) -> Bool {
    workerRunLock.lock()
    defer { workerRunLock.unlock() }
    guard !workerRunsInFlight.contains(sessionId) else { return false }
    workerRunsInFlight.insert(sessionId)
    return true
  }

  /// Release the in-flight slot for sessionId (idempotent).
  fileprivate static func releaseWorkerRun(sessionId: String) {
    workerRunLock.lock()
    defer { workerRunLock.unlock() }
    workerRunsInFlight.remove(sessionId)
  }

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

  /// Stop listening, close all PTY sessions (kills their shells),
  /// stop all shell workers (kills their whole process trees, so no
  /// background job survives the service stop), remove the token file.
  /// Idempotent.
  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      for session in self.ptySessions.values {
        session.close(reason: "service stopped")
      }
      ISHShellExecutor.shared().stopAllWorkers()
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

  /// Forward raw PTY bytes to one session (called from that
  /// session's kernel output handler on the main queue).
  fileprivate func forwardPTYOutput(_ data: Data, sessionId: String) {
    queue.async { [weak self] in
      guard let self, let session = self.ptySessions[sessionId], !session.closed else { return }
      session.sendBinary(data)
    }
  }

  /// Register a PTY session (called by WSConnection after spawning
  /// its shell). Returns false when the session cap is already
  /// reached (the caller then closes the new connection with 1008).
  /// Registers the session's kernel output handler, so the kernel
  /// routes that tty's bytes to exactly this session.
  fileprivate func registerPTYSession(_ session: PTYSession) -> Bool {
    // Called on `queue` (HTTPConnection runs there).
    if ptySessions.count >= Int(ISHPtyMaxSessions) { return false }
    if ptySessions[session.id] != nil { return false }
    ptySessions[session.id] = session
    let sessionId = session.id
    ISHKernel.shared.setPtyOutputHandler({ [weak self] data in
      self?.forwardPTYOutput(data, sessionId: sessionId)
    }, forSession: sessionId)
    return true
  }

  /// Clear a PTY session (called when it ends). Idempotent. Also
  /// clears the session's kernel output handler.
  fileprivate func clearPTYSession(_ session: PTYSession) {
    // Called on `queue`.
    if ptySessions[session.id] === session {
      ptySessions.removeValue(forKey: session.id)
      ISHKernel.shared.setPtyOutputHandler(nil, forSession: session.id)
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
  /// Live worker run while a /ish/worker/run request is being served.
  private var workerSession: WorkerSession?

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
    // /ish/pty carries readOnly in the query (?readOnly=1, N-2): route
    // on the path without the query so the upgrade still matches.
    let routePath = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
    switch (request.method, routePath) {
    case ("GET", "/ish/status"):
      handleStatus()
    case ("POST", "/ish/exec"):
      handleExec(request)
    case ("POST", "/ish/worker/run"):
      handleWorkerRun(request)
    case ("POST", "/ish/worker/jobs/kill"):
      handleWorkerJobKill(request)
    case ("POST", "/ish/worker/stop"):
      handleWorkerStop(request)
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
        "ptySessions": Int(kernel.ptySessionCount()),
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
    workerSession?.cancel()
    workerSession = nil
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
    guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
      sendJSON(status: 400, reason: "Bad Request", object: ["error": "request body must be a JSON object"])
      return
    }
    // B (argv mode): a direct guest exec — argv runs without a shell,
    // verbatim. command and argv are mutually exclusive; argv must be
    // a non-empty array of strings (a non-string element fails the
    // cast, so it 400s here).
    let argv: [String]?
    if json["argv"] != nil {
      guard let parsed = json["argv"] as? [String], !parsed.isEmpty else {
        sendJSON(status: 400, reason: "Bad Request", object: ["error": "argv must be a non-empty array of strings"])
        return
      }
      guard json["command"] == nil else {
        sendJSON(status: 400, reason: "Bad Request", object: ["error": "argv and command are mutually exclusive"])
        return
      }
      argv = parsed
    } else {
      argv = nil
    }
    let command: String?
    if argv == nil {
      guard let c = json["command"] as? String, !c.isEmpty else {
        sendJSON(status: 400, reason: "Bad Request", object: ["error": "command is required"])
        return
      }
      command = c
    } else {
      command = nil
    }
    // N-5 (round 2): an embedded NUL would be silently cut by the
    // executor's strlen/UTF8String packing (argv/env/cwd/command), so reject
    // it here with the same 400 shape as the argv checks above. JSON
    // \u0000 survives JSONSerialization as an embedded NUL in
    // NSString, so contains("\0") catches it. Only parsed values are
    // checked: a malformed env/cwd still falls through to the
    // existing nil handling below.
    if let argv, argv.contains(where: { $0.contains("\0") }) {
      sendJSON(status: 400, reason: "Bad Request", object: ["error": "argv must not contain NUL"])
      return
    }
    if let env = json["env"] as? [String: String],
       env.contains(where: { $0.key.contains("\0") || $0.value.contains("\0") }) {
      sendJSON(status: 400, reason: "Bad Request", object: ["error": "env must not contain NUL"])
      return
    }
    if let cwd = json["cwd"] as? String, cwd.contains("\0") {
      sendJSON(status: 400, reason: "Bad Request", object: ["error": "cwd must not contain NUL"])
      return
    }
    // N-5 follow-up: the command string itself takes the same path —
    // buildShellCommand splices it verbatim and the executor packs it
    // with strlen, so a NUL would silently truncate it like argv/env/cwd.
    if let command, command.contains("\0") {
      sendJSON(status: 400, reason: "Bad Request", object: ["error": "command must not contain NUL"])
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
    // ENV-14: per-exec nonce for the session-cwd marker. Hex only,
    // capped at 64 chars; anything else is ignored (no marker), so a
    // malformed client can never inject shell syntax through it.
    let cwdNonce: String? = {
      guard let nonce = json["cwdNonce"] as? String, !nonce.isEmpty, nonce.count <= 64,
            nonce.unicodeScalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57)
              || ($0.value >= 97 && $0.value <= 102) }) else { return nil }
      return nonce
    }()
    // PTY exec (stage 5.3, ENV-02): tty:true runs the command on a
    // fresh fake PTY (merged stream) instead of host pipes. The flag
    // is the "has pty" contract with the bridge (see ish-bridge.mjs):
    // absent/false means the pipe path, exactly as before.
    let tty = (json["tty"] as? Bool) ?? false
    var cols = 80
    var rows = 24
    if let n = json["cols"] as? NSNumber { cols = n.intValue }
    if let n = json["rows"] as? NSNumber { rows = n.intValue }
    cols = max(2, min(cols, 500))
    rows = max(1, min(rows, 200))
    // B: argv mode is pipe-only — a tty needs a shell to drive the
    // PTY session, and argv execs have none.
    if argv != nil && tty {
      sendJSON(status: 400, reason: "Bad Request", object: ["error": "argv mode does not support tty"])
      return
    }
    // Command path only: build the /bin/bash -c string (env exports +
    // cd + cwd marker). Argv mode skips this entirely — env/cwd go to
    // the executor directly, and no shell prints the cwd marker.
    let shellCommand: String?
    if let command {
      shellCommand = Self.buildShellCommand(
        command: command,
        cwd: json["cwd"] as? String,
        env: json["env"] as? [String: String],
        cwdNonce: cwdNonce)
    } else {
      shellCommand = nil
    }
    guard ISHKernel.shared.isBooted else {
      sendJSON(status: 503, reason: "Service Unavailable", object: ["error": "ish_not_booted"])
      return
    }
    // H-1: a read-only session must never reach the guest shell — the
    // workspace bind mount is always writable, so fail closed here
    // instead of running the command.
    if (json["readOnly"] as? Bool) == true {
      sendReadOnlyDenied()
      return
    }
    // B: no cwd marker in argv mode — an argv exec has no shell to
    // print it, and it cannot change the session shell's cwd.
    let session = ExecSession(connection: self, cwdNonce: argv == nil ? cwdNonce : nil)
    execSession = session
    if tty {
      // Cap pre-check (stage 5.3): refuse with 429 BEFORE any
      // headers are sent, so the bridge sees a typed failure instead
      // of a -1 terminal frame. Racy by one spawn (another session
      // can open between the check and the start); the loser then
      // fails with the executor's -1 creation-failed frame instead
      // — same code as any other failed start, documented in
      // ISHShellExecutor.runTtyRecord.
      if ISHKernel.shared.ptySessionCount() >= Int(ISHPtyMaxSessions) {
        sendJSON(status: 429, reason: "Too Many Requests",
                 object: ["error": "pty_session_limit"])
        return
      }
      session.startTty(command: shellCommand!, stdinData: stdinData,
                       fsContext: fsContext, timeout: TimeInterval(timeoutMs) / 1000.0,
                       cols: cols, rows: rows)
    } else if let argv {
      session.startArgv(argv: argv, env: json["env"] as? [String: String],
                        cwd: json["cwd"] as? String, stdinData: stdinData,
                        fsContext: fsContext, timeout: TimeInterval(timeoutMs) / 1000.0)
    } else {
      session.start(command: shellCommand!, stdinData: stdinData,
                    fsContext: fsContext, timeout: TimeInterval(timeoutMs) / 1000.0)
    }
  }

  /// Single-quote a string for /bin/bash (quoting is the same as for
  /// /bin/sh ash). Embedded single quotes become '\'' (close quote,
  /// escaped quote, reopen quote).
  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Build the /bin/bash -c command from the request: optional env
  /// exports, then an optional cd, then the command itself. Only valid
  /// shell identifiers are exported (others are ignored). The shell is
  /// /bin/bash (ENV-01; ISHShellExecutor.executeCommand), not /bin/sh.
  ///
  /// With a cwdNonce, a trailer is appended that prints the shell's
  /// final cwd as one stderr line (`__DSH_CWD__<nonce>:<cwd>`) and
  /// preserves the command's exit code (ENV-14: the bridge remembers
  /// a bare `cd` across execs of one session). The trailer runs after
  /// the command regardless of its exit code (`;`, not `&&`); it is
  /// skipped only when the command replaces the shell (`exec`) or
  /// exits it (`exit`) or the shell is killed — all cases where there
  /// is no cwd worth remembering. The bridge swallows the marker line
  /// (it never reaches tool output); ExecSession keeps it out of the
  /// timeout frame's partialOutput too.
  static func buildShellCommand(command: String, cwd: String?, env: [String: String]?,
                                cwdNonce: String? = nil) -> String {
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
    var built = prefix + command
    if let cwdNonce {
      built += "; _dsh_ec=$?; printf '__DSH_CWD__\(cwdNonce):%s\\n' \"$PWD\" >&2; exit $_dsh_ec"
    }
    return built
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
  /// Per-exec nonce for the session-cwd marker (ENV-14), or nil when
  /// the client did not ask for cwd tracking. The marker line is still
  /// sent as an NDJSON frame (the bridge needs it) but is kept out of
  /// partialOutput (see sendLine).
  private let cwdNonce: String?
  /// True when this exec runs on a PTY (merged stream; the terminal
  /// frame reports it so the bridge knows the exec had a tty).
  private var isTty = false

  init(connection: HTTPConnection, cwdNonce: String? = nil) {
    self.connection = connection
    self.cwdNonce = cwdNonce
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

  /// Direct argv exec (route B): the same NDJSON streaming shape as
  /// start(), but argv runs without a shell via
  /// ISHShellExecutor.executeArgv. env/cwd are applied by the
  /// executor (no shell `export`/`cd`, no cwd marker — an argv exec
  /// cannot change the session shell's cwd, so cwdNonce is nil here).
  func startArgv(argv: [String], env: [String: String]?, cwd: String?,
                 stdinData: Data?, fsContext: UInt64, timeout: TimeInterval) {
    // Send the chunked headers first, then stream.
    connection?.sendChunkedHeaders()
    let started = Date()
    execution = ISHShellExecutor.shared().executeArgv(
      argv, env: env, cwd: cwd, stdinData: stdinData, fsContext: fsContext,
      timeout: timeout,
      outputHandler: { [weak self] isStderr, chunk in
        self?.queue.async { [weak self] in self?.onChunk(isStderr: isStderr, chunk: chunk) }
      },
      completion: { [weak self] result in
        self?.queue.async { [weak self] in self?.onComplete(result: result, started: started) }
      })
  }

  /// PTY exec (stage 5.3, ENV-02): the same one-shot shape, but the
  /// command runs on a fresh fake PTY via
  /// ISHShellExecutor.executeCommandTty. stdout/stderr are merged —
  /// onChunk always sees isStderr == false, so every line is
  /// streamed as "stdout" (documented in the file header). stdin is
  /// fed by the executor (chunked + EOT); TERM is xterm-256color
  /// because a tty is present.
  func startTty(command: String, stdinData: Data?, fsContext: UInt64,
                timeout: TimeInterval, cols: Int, rows: Int) {
    // Send the chunked headers first, then stream.
    connection?.sendChunkedHeaders()
    let started = Date()
    isTty = true
    execution = ISHShellExecutor.shared().executeCommandTty(
      command, stdinData: stdinData, fsContext: fsContext, timeout: timeout,
      cols: Int32(cols), rows: Int32(rows),
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
    // NOTE (ENV-14, background jobs): on NORMAL completion the guest
    // process group is intentionally NOT killed. A command that
    // backgrounds work (`sleep 600 &`) leaves it running after the
    // exec returns — that is the long-task escape hatch the env report
    // documents, and the engine's managed handle only tracks the
    // foreground exec (its synthetic pid cannot signal the guest).
    // Cancel (disconnect) and timeout DO kill the group; see cancel()
    // and the executor's timeout path. A `&` child therefore survives
    // untracked: there is no job list for it yet (see the REPORT).
    // Flush trailing partial lines (if any) as final lines.
    if let line = stdoutBuffer.flush() { sendLine(stream: "stdout", lineData: line) }
    if let line = stderrBuffer.flush() { sendLine(stream: "stderr", lineData: line) }
    let durationMs = Int(Date().timeIntervalSince(started) * 1000)
    var frame: [String: Any] = [
      "exitCode": result.exitCode,
      "durationMs": durationMs,
    ]
    if isTty {
      // The "had a pty" flag (ENV-02 contract): the bridge checks
      // this to confirm the exec really ran on a PTY.
      frame["tty"] = true
    }
    if result.timedOut {
      frame["timedOut"] = true
      frame["partialOutput"] = partialOutput
    }
    if result.cancelled {
      frame["cancelled"] = true
    }
    sendJSONFrame(frame)
    // Close only after the terminating chunk has been handed to the
    // network stack. The sends are async — closing first cancels the
    // connection and discards the final frame, so the client sees the
    // stream die mid-response as "aborted" (build 52/53 agent bash).
    // Sends are serialised through sendQueue, so the chunk-end
    // completion also implies the final frame was processed.
    // Close on the service queue (ExecSession runs on its own queue;
    // HTTPConnection state is owned by the service queue).
    connection?.sendChunkEnd { [weak self] in
      self?.connection?.closeFromAnyQueue()
    }
  }

  /// Encode one NDJSON line ({stream, line}) and send it as a chunk.
  /// The line bytes are decoded lossy-UTF-8 (a truncated multi-byte
  /// character at end-of-stream becomes U+FFFD — the bytes themselves
  /// were already preserved in the buffer; only the JSON rendering is
  /// lossy, and only for a truncated final character).
  ///
  /// ENV-14: the session-cwd marker line (`__DSH_CWD__<nonce>:<cwd>`,
  /// stderr only, exact nonce) is still sent — the bridge consumes it
  /// — but is not appended to partialOutput, so a timeout frame never
  /// shows protocol as command output.
  private func sendLine(stream: String, lineData: Data) {
    let line = String(decoding: lineData, as: UTF8.self)
    let isCwdMarker = stream == "stderr" && cwdNonce != nil
      && line.hasPrefix("__DSH_CWD__\(cwdNonce!):")
    if !isCwdMarker {
      partialOutput += line + "\n"
    }
    sendJSONFrame(["stream": stream, "line": line])
  }

  private func sendJSONFrame(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return }
    var chunk = data
    chunk.append(0x0A) // NDJSON: one JSON object per line.
    connection?.sendChunk(chunk)
  }
}

// MARK: - /ish/worker (persistent shell, ENV-04)

/// No-output watchdog: a worker run that produces no output bytes for
/// this long is assumed stuck (blocked read, deadlock, waiting on
/// stdin that will never come) and its foreground command is killed.
/// 120 s: matches the DSH bash executor's default deadline, long
/// enough for legitimate silent work, and far sooner than the 600 s
/// wall-clock backstop. A command that keeps producing output is never
/// killed by it — only the wall clock applies. A silent long task
/// should print progress (tar -v, periodic echo) to stay alive.
private let kISHWorkerIdleTimeout: TimeInterval = 120
/// Grace after killing the foreground command for the END marker to
/// arrive (the wrapper prints it right after the kill). If nothing
/// arrives — the command was a builtin with no child to kill, e.g.
/// `wait` — the worker itself is killed and rebuilt.
private let kISHWorkerKillGrace: TimeInterval = 5
/// Grace after the END marker for the jobs snapshot to arrive (it is
/// printed immediately after the marker by the same wrapper, so this
/// is only a backstop against a truncated stream).
private let kISHWorkerJobsTailGrace: TimeInterval = 2

extension HTTPConnection {
  /// A worker session id is a DSH_SESSION_ID: [A-Za-z0-9][A-Za-z0-9_-]{0,127}.
  /// Anything else is rejected (it becomes a registry key, so it must
  /// not contain shell syntax or path separators).
  static func isValidWorkerSessionId(_ id: String) -> Bool {
    guard !id.isEmpty, id.count <= 128 else { return false }
    return id.unicodeScalars.allSatisfy {
      ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
        || ($0.value >= 97 && $0.value <= 122) || $0.value == 45 || $0.value == 95
    }
  }

  /// A worker nonce: hex only, capped at 64 chars (same rule as the
  /// ENV-14 cwdNonce — it is interpolated into shell source, so it
  /// must not contain shell syntax).
  static func isValidWorkerNonce(_ nonce: String) -> Bool {
    guard !nonce.isEmpty, nonce.count <= 64 else { return false }
    return nonce.unicodeScalars.allSatisfy {
      ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
    }
  }

  /// Build the base-env export line for a NEW worker: `export K='v'; ...`
  /// (one line, no save/restore — these persist for the worker's life).
  /// Keys in the `_dsh_` namespace are reserved for the worker protocol
  /// and never exported. Only valid shell names are exported.
  static func buildBaseEnvExports(env: [String: String]?) -> String {
    guard let env, !env.isEmpty else { return "" }
    var parts: [String] = []
    for key in env.keys.sorted() {
      guard isValidShellName(key), !key.hasPrefix("_dsh_"), let value = env[key] else { continue }
      parts.append("export \(key)=\(shellQuote(value));")
    }
    return parts.joined(separator: " ")
  }

  /// Build the text written to the worker's stdin for one command.
  ///
  /// - Per-command env overlay: each key is saved (`_dsh_sv_<K>` /
  ///   `_dsh_has_<K>`) and exported; the restore runs after the command,
  ///   so the overlay never leaks into later commands. The worker's BASE
  ///   env (set at creation) is untouched by this.
  /// - The command runs inside a `{ ...; }` group in the CURRENT shell
  ///   (no subshell: a bare `cd` persists and `&` jobs belong to the
  ///   worker, so `jobs` sees them), with stdin from /dev/null: a
  ///   command that reads stdin sees EOF instead of eating the next
  ///   command's text off the worker's command channel. Well-formed
  ///   multi-line commands (if/for/function/heredoc) parse fine inside
  ///   the group; a syntactically incomplete command swallows the
  ///   closing lines and the watchdog rebuilds the worker.
  /// - The END marker (`__DSH_END__<nonce>:<exitCode>:<cwd>`, stderr)
  ///   and the jobs snapshot (`jobs -l` for the bridge's job table,
  ///   `jobs -p` for the executor's kill-exclusion set) follow. The
  ///   bridge swallows all protocol lines (same split as the ENV-14
  ///   cwd marker: the server forwards, the client owns the protocol).
  static func buildWorkerCommand(command: String, cwd: String?, env: [String: String]?,
                                 nonce: String) -> String {
    var lines: [String] = []
    var savedKeys: [String] = []
    if let env, !env.isEmpty {
      for key in env.keys.sorted() {
        guard isValidShellName(key), !key.hasPrefix("_dsh_"), let value = env[key] else { continue }
        savedKeys.append(key)
        lines.append("_dsh_sv_\(key)=\"${\(key)-}\"; _dsh_has_\(key)=\"${\(key)+x}\"; export \(key)=\(shellQuote(value));")
      }
    }
    if let cwd, !cwd.isEmpty {
      // `;` (not `&&`): a failed cd must not skip the command — the
      // marker below reports the ACTUAL cwd, so the bridge's memory
      // self-heals. The bridge only sends cwd when it changed (or the
      // worker was rebuilt), so this is normally a no-op cd.
      lines.append("cd -- \(shellQuote(cwd));")
    }
    lines.append("{ \(command)")
    // `}` and the exit-code capture are separate lines so a group that
    // parses but whose command fails (e.g. `false`) still reaches the
    // marker with the right exit code. A group that FAILS TO PARSE
    // (e.g. a comment-only command is an empty list) is fatal: a
    // non-interactive bash exits on the syntax error (verified:
    // `bash --noprofile --norc` exits 2, the marker never runs) and
    // the worker dies — the run then completes via onWorkerDeath with
    // the shell's exit code, and the next run rebuilds the worker.
    // That is the designed recovery path; it costs one worker restart.
    lines.append("} < /dev/null")
    lines.append("_dsh_ec=$?;")
    for key in savedKeys {
      lines.append("if [ -n \"$_dsh_has_\(key)\" ]; then export \(key)=\"$_dsh_sv_\(key)\"; else unset \(key); fi; unset _dsh_sv_\(key) _dsh_has_\(key);")
    }
    lines.append("printf '__DSH_END__\(nonce):%s:%s\\n' \"$_dsh_ec\" \"$PWD\" >&2")
    lines.append("printf '__DSH_JOBS_BEGIN__\(nonce)\\n' >&2")
    lines.append("jobs -l >&2")
    lines.append("printf '__DSH_JOBS_END__\(nonce)\\n' >&2")
    lines.append("printf '__DSH_JOBPIDS_BEGIN__\(nonce)\\n' >&2")
    lines.append("jobs -p >&2")
    lines.append("printf '__DSH_JOBPIDS_END__\(nonce)\\n' >&2")
    return lines.joined(separator: "\n") + "\n"
  }

  func handleWorkerRun(_ request: HTTPRequest) {
    guard service != nil else { close(); return }
    guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
          let command = json["command"] as? String, !command.isEmpty,
          let sessionId = json["sessionId"] as? String, Self.isValidWorkerSessionId(sessionId),
          let nonce = json["nonce"] as? String, Self.isValidWorkerNonce(nonce) else {
      sendJSON(status: 400, reason: "Bad Request",
               object: ["error": "command, sessionId and nonce are required"])
      return
    }
    // N-5 follow-up (same truncation as /ish/exec): the worker command
    // is spliced verbatim by buildWorkerCommand and packed with strlen.
    if command.contains("\0") {
      sendJSON(status: 400, reason: "Bad Request",
               object: ["error": "command must not contain NUL"])
      return
    }
    var fsContext: UInt64 = 0
    if let n = json["fsContext"] as? NSNumber { fsContext = n.uint64Value }
    var timeoutMs = 600_000
    if let n = json["timeoutMs"] as? NSNumber { timeoutMs = n.intValue }
    timeoutMs = max(1_000, min(timeoutMs, 900_000))
    let env = json["env"] as? [String: String]
    let cwd = json["cwd"] as? String
    // N-5 follow-up (same truncation as /ish/exec): env/cwd are spliced
    // verbatim by buildWorkerCommand and packed with strlen, so a NUL
    // would silently truncate them like command.
    if let env, env.contains(where: { $0.key.contains("\0") || $0.value.contains("\0") }) {
      sendJSON(status: 400, reason: "Bad Request", object: ["error": "env must not contain NUL"])
      return
    }
    if let cwd, cwd.contains("\0") {
      sendJSON(status: 400, reason: "Bad Request", object: ["error": "cwd must not contain NUL"])
      return
    }
    guard ISHKernel.shared.isBooted else {
      sendJSON(status: 503, reason: "Service Unavailable", object: ["error": "ish_not_booted"])
      return
    }
    // H-1: same denial as /ish/exec, before registering the session
    // or touching the worker.
    if (json["readOnly"] as? Bool) == true {
      sendReadOnlyDenied()
      return
    }
    // (M-10) One run per session at a time: a second concurrent run
    // would overwrite the worker's single output handler (see
    // beginWorkerRun) and hang the first run until its wall-clock
    // timeout. Fail fast with 409; the bridge retries/queues.
    guard IShLoopbackService.claimWorkerRun(sessionId: sessionId) else {
      sendJSON(status: 409, reason: "Conflict", object: ["error": "worker_busy"])
      return
    }
    // Register the session NOW (service queue), before the possibly
    // blocking worker creation: close() must be able to cancel a run
    // that is still starting, or a command aborted mid-start would run
    // to completion on the worker and block the session.
    let session = WorkerSession(connection: self, nonce: nonce, sessionId: sessionId)
    workerSession = session
    let shellCommand = Self.buildWorkerCommand(command: command, cwd: cwd, env: env, nonce: nonce)
    let baseEnvText = Self.buildBaseEnvExports(env: env)
    // Worker creation can block up to 15 s (shell start under
    // emulation): do it off the service queue so other requests
    // (status, pty upgrade) are not stalled behind it.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        // (M-10) Connection gone before the worker started: the run
        // never reaches completeRun, so release the slot here.
        IShLoopbackService.releaseWorkerRun(sessionId: sessionId)
        return
      }
      var worker = ISHShellExecutor.shared().worker(forSession: sessionId, fsContext: fsContext,
                                                             baseEnvText: baseEnvText)
      if worker == nil {
        // The bridge falls back to one-shot /ish/exec for this command.
        self.sendJSON(status: 503, reason: "Service Unavailable",
                      object: ["error": "worker_start_failed"])
        // (M-10) No run started; release the slot.
        IShLoopbackService.releaseWorkerRun(sessionId: sessionId)
        return
      }
      // fs_context is per agent run: a worker started under a different
      // context is rebuilt (its jobs die with it — a context change
      // means a new agent run, whose jobs belong to the old run).
      if worker!.fsContext != fsContext {
        ISHShellExecutor.shared().stopWorker(forSession: sessionId)
        worker = ISHShellExecutor.shared().worker(forSession: sessionId, fsContext: fsContext,
                                                           baseEnvText: baseEnvText)
        if worker == nil {
          self.sendJSON(status: 503, reason: "Service Unavailable",
                        object: ["error": "worker_start_failed"])
          // (M-10) No run started; release the slot.
          IShLoopbackService.releaseWorkerRun(sessionId: sessionId)
          return
        }
      }
      session.attachWorker(worker!, commandText: shellCommand,
                           timeout: TimeInterval(timeoutMs) / 1000.0)
    }
  }

  func handleWorkerJobKill(_ request: HTTPRequest) {
    guard service != nil else { close(); return }
    guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
          let sessionId = json["sessionId"] as? String, Self.isValidWorkerSessionId(sessionId),
          let pidNumber = json["pid"] as? NSNumber else {
      sendJSON(status: 400, reason: "Bad Request",
               object: ["error": "sessionId and pid are required"])
      return
    }
    let pid = pidNumber.intValue
    guard let worker = ISHShellExecutor.shared().worker(forSessionIfPresent: sessionId),
          worker.isAlive else {
      sendJSON(status: 404, reason: "Not Found", object: ["error": "job_not_found"])
      return
    }
    // killWorkerJob validates the pid is a live descendant of the
    // worker (anything else — including the worker itself — is refused).
    if ISHShellExecutor.shared().killWorkerJob(worker, pid: Int32(pid)) {
      sendJSON(status: 200, reason: "OK", object: ["killed": true, "pid": pid])
    } else {
      sendJSON(status: 404, reason: "Not Found", object: ["error": "job_not_found"])
    }
  }

  func handleWorkerStop(_ request: HTTPRequest) {
    guard service != nil else { close(); return }
    guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
          let sessionId = json["sessionId"] as? String, Self.isValidWorkerSessionId(sessionId) else {
      sendJSON(status: 400, reason: "Bad Request", object: ["error": "sessionId is required"])
      return
    }
    // Idempotent: stopping a session with no worker still reports stopped.
    ISHShellExecutor.shared().stopWorker(forSession: sessionId)
    sendJSON(status: 200, reason: "OK", object: ["stopped": true])
  }
}

/// One POST /ish/worker/run request: streams the worker's output as
/// chunked NDJSON and ends with a terminal frame. All state is owned
/// by a private serial queue (the executor's outputHandler arrives on
/// arbitrary queues). The run completes when the END marker AND the
/// jobs snapshot have arrived, the worker dies, the client disconnects,
/// the no-output watchdog fires, or the wall-clock timeout fires.
/// One run per worker at a time — the bridge serializes runs per
/// session (its per-session queue), so two WorkerSessions never share
/// a worker concurrently.
private final class WorkerSession {
  private weak var connection: HTTPConnection?
  private let queue = DispatchQueue(label: "me.zzuu.ish.loopback.worker")
  private var stdoutBuffer = LineBuffer()
  private var stderrBuffer = LineBuffer()
  /// Decoded output text so far (for the timeout frame's partialOutput).
  /// Protocol lines never enter it.
  private var partialOutput = ""
  private var finished = false
  private var cancelled = false
  private var timedOut = false
  private let nonce: String
  /// The session id, for the M-10 in-flight run slot.
  private let sessionId: String
  private var worker: ISHWorkerShell?
  private var startedAt = Date()
  private var wallClockTimeout: TimeInterval = 600
  private var lastOutputAt = Date()
  /// END marker seen (exit code + final cwd parsed).
  private var sawEndMarker = false
  private var markerExitCode: Int?
  private var markerCwd: String?
  /// Jobs snapshot complete (JOBPIDS_END seen).
  private var sawJobsEnd = false
  /// The worker died mid-run (its shell exited: `exit`, `exec`, kill).
  private var workerDied = false
  /// Wait-decoded exit code of the dead worker shell, if known.
  private var workerExitCode: Int?
  /// Inside a `jobs -l` block (lines are protocol, not output).
  private var inJobsBlock = false
  /// Inside a `jobs -p` block (pids for the kill-exclusion set).
  private var inJobpidsBlock = false
  private var collectedJobPids: [Int] = []
  /// Watchdog re-arm token: a stale timer block (from an earlier
  /// arming) is ignored.
  private var watchdogToken = 0

  init(connection: HTTPConnection, nonce: String, sessionId: String) {
    self.connection = connection
    self.nonce = nonce
    self.sessionId = sessionId
  }

  deinit {
    // (M-10) Backstop: close() drops the session after cancel(), so a
    // cancelled run may deallocate before completeRun; release here so
    // the session is not 409'd forever. Idempotent with completeRun.
    IShLoopbackService.releaseWorkerRun(sessionId: sessionId)
  }

  /// Attach the (possibly newly created) worker and start the run.
  /// Called once, from any queue. If the client already disconnected,
  /// the command is never written (a cancelled command must not run
  /// and block the worker).
  func attachWorker(_ worker: ISHWorkerShell, commandText: String, timeout: TimeInterval) {
    queue.async { [weak self] in
      guard let self, !self.finished, !self.cancelled else { return }
      self.worker = worker
      self.startedAt = Date()
      self.lastOutputAt = Date()
      self.wallClockTimeout = timeout
      self.connection?.sendChunkedHeaders()
      // Death: the shell exited mid-run (`exit`, `exec`, eviction,
      // guest stop). Complete with the shell's exit code when known.
      worker.onDeath = { [weak self] exitCode in
        self?.queue.async { [weak self] in self?.onWorkerDeath(exitCode: exitCode) }
      }
      ISHShellExecutor.shared().beginWorkerRun(worker, commandText: commandText) { [weak self] isStderr, chunk in
        self?.queue.async { [weak self] in self?.onChunk(isStderr: isStderr, chunk: chunk) }
      }
      self.armWatchdog()
      self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.wallClockFired() }
    }
  }

  /// Cancel (client disconnected): kill the foreground command, never
  /// the worker — the session stays usable for the next command. The
  /// completion still fires but the connection is closed, so sends are
  /// no-ops. A builtin with no child escalates to a worker kill.
  func cancel() {
    queue.async { [weak self] in
      guard let self, !self.finished else { return }
      self.cancelled = true
      if let worker = self.worker {
        self.killCurrentCommandOrEscalate(worker: worker)
      } else {
        // No worker yet (still starting): the command was never
        // written, and attachWorker will see cancelled and skip it.
        self.finished = true
        // (M-10) No run will ever complete; release the slot now.
        IShLoopbackService.releaseWorkerRun(sessionId: self.sessionId)
      }
    }
  }

  private func onChunk(isStderr: Bool, chunk: Data) {
    guard !finished else { return }
    lastOutputAt = Date()
    let stream = isStderr ? "stderr" : "stdout"
    let buffer = isStderr ? stderrBuffer : stdoutBuffer
    for line in buffer.append(chunk) {
      sendLine(stream: stream, lineData: line)
    }
  }

  /// Encode one NDJSON line ({stream, line}) and send it as a chunk.
  /// Protocol lines (stderr only, exact nonce) are still forwarded —
  /// the bridge parses them (same split as the ENV-14 cwd marker) —
  /// but never enter partialOutput. The `jobs -l` / `jobs -p` lines
  /// inside a snapshot block are protocol too.
  private func sendLine(stream: String, lineData: Data) {
    let line = String(decoding: lineData, as: UTF8.self)
    var isProtocol = false
    // P0-1 fix: NEVER complete the run from inside sendLine before this
    // line's own NDJSON frame is on the wire. tryCompleteFromMarker()
    // fires completeRun(), which emits the terminal frame and the chunked
    // terminal 0-chunk; a frame enqueued after that (the
    // __DSH_JOBPIDS_END__ protocol frame) is data after the terminal
    // chunk, and Node llhttp rejects the response with
    // HPE_CLOSED_CONNECTION ("Data after `Connection: close`").
    // Defer the completion check until after sendJSONFrame.
    var shouldTryComplete = false
    if stream == "stderr" {
      if line.hasPrefix("__DSH_END__\(nonce):") {
        isProtocol = true
        parseEndMarker(line)
        shouldTryComplete = true
      } else if line == "__DSH_JOBS_BEGIN__\(nonce)" {
        isProtocol = true
        inJobsBlock = true
      } else if line == "__DSH_JOBS_END__\(nonce)" {
        isProtocol = true
        inJobsBlock = false
      } else if line == "__DSH_JOBPIDS_BEGIN__\(nonce)" {
        isProtocol = true
        inJobpidsBlock = true
      } else if line == "__DSH_JOBPIDS_END__\(nonce)" {
        isProtocol = true
        inJobpidsBlock = false
        sawJobsEnd = true
        worker?.jobPids = Set(collectedJobPids.map { NSNumber(value: $0) })
        collectedJobPids.removeAll()
        shouldTryComplete = true
      } else if inJobsBlock {
        isProtocol = true
      } else if inJobpidsBlock {
        isProtocol = true
        if let pid = Int(line.trimmingCharacters(in: .whitespaces)), pid > 0 {
          collectedJobPids.append(pid)
        }
      }
    }
    if !isProtocol {
      partialOutput += line + "\n"
    }
    sendJSONFrame(["stream": stream, "line": line])
    if shouldTryComplete {
      tryCompleteFromMarker()
    }
  }

  /// Parse `__DSH_END__<nonce>:<exitCode>:<cwd>` (stderr). A malformed
  /// line is ordinary output (the bridge applies the same rule, so a
  /// command that prints a look-alike line cannot corrupt the run).
  private func parseEndMarker(_ line: String) {
    let rest = line.dropFirst("__DSH_END__\(nonce):".count)
    guard let colon = rest.firstIndex(of: ":"),
          let code = Int(rest[..<colon]), code >= 0, code <= 255 else { return }
    let cwd = rest[rest.index(after: colon)...]
    guard cwd.hasPrefix("/") else { return }
    markerExitCode = code
    markerCwd = String(cwd)
    sawEndMarker = true
    // Tail grace: the jobs snapshot is printed immediately after the
    // marker by the same wrapper; if it never arrives, complete anyway
    // rather than hanging the run.
    queue.asyncAfter(deadline: .now() + kISHWorkerJobsTailGrace) { [weak self] in
      guard let self, !self.finished, self.sawEndMarker, !self.sawJobsEnd else { return }
      NSLog("ish-loopback: worker run END marker without jobs snapshot; completing anyway")
      self.tryCompleteFromMarker(forceJobs: true)
    }
    // P0-1 fix: do NOT call tryCompleteFromMarker() here. parseEndMarker
    // runs from inside sendLine, before the END marker line's own frame
    // is sent; completing here would emit the terminal frame and the
    // chunked 0-chunk ahead of that frame. sendLine defers the
    // completion check until after sendJSONFrame (see shouldTryComplete).
  }

  private func tryCompleteFromMarker(forceJobs: Bool = false) {
    guard !finished, sawEndMarker, let code = markerExitCode,
          sawJobsEnd || forceJobs else { return }
    completeRun(exitCode: code, timedOut: timedOut, cancelled: cancelled, workerDied: false)
  }

  private func onWorkerDeath(exitCode: NSNumber?) {
    guard !finished else { return }
    workerDied = true
    // The shell's exit code, wait-decoded (`exit 3` → 3; killed by a
    // signal → 128 + signal). Nil when the shell was killed without a
    // notification — the run then reports -1 (unknown).
    if let code = exitCode {
      workerExitCode = Int(ISHDecodeWaitStatus(Int32(code.intValue)))
    }
    completeRun(exitCode: workerExitCode ?? -1, timedOut: timedOut,
                cancelled: cancelled, workerDied: true)
  }

  private func wallClockFired() {
    guard !finished else { return }
    timedOut = true
    NSLog("ish-loopback: worker run hit the %.0fs wall clock; killing foreground command",
          wallClockTimeout)
    if let worker { killCurrentCommandOrEscalate(worker: worker) }
  }

  private func armWatchdog() {
    watchdogToken += 1
    let token = watchdogToken
    queue.asyncAfter(deadline: .now() + kISHWorkerIdleTimeout) { [weak self] in
      guard let self, !self.finished, token == self.watchdogToken else { return }
      self.watchdogFired()
    }
  }

  private func watchdogFired() {
    guard !finished, !cancelled else { return }
    if Date().timeIntervalSince(lastOutputAt) < kISHWorkerIdleTimeout {
      armWatchdog() // output arrived since the last arming; re-arm
      return
    }
    // Silent for 120 s: kill the foreground command. The wrapper
    // prints the END marker right after the kill, which completes the run.
    timedOut = true
    if let worker {
      NSLog("ish-loopback: worker run silent %.0fs, killing foreground command",
            kISHWorkerIdleTimeout)
      killCurrentCommandOrEscalate(worker: worker)
    }
  }

  /// Kill the foreground command; if there is no child to kill (a
  /// builtin such as `wait`), or the END marker still has not arrived
  /// after the grace, kill the worker itself (the run then completes
  /// via onWorkerDeath).
  private func killCurrentCommandOrEscalate(worker: ISHWorkerShell) {
    let killed = ISHShellExecutor.shared().killWorkerForegroundCommand(worker)
    if killed.isEmpty {
      escalateToWorkerKill(worker: worker)
      return
    }
    queue.asyncAfter(deadline: .now() + kISHWorkerKillGrace) { [weak self] in
      guard let self, !self.finished else { return }
      self.escalateToWorkerKill(worker: worker)
    }
  }

  private func escalateToWorkerKill(worker: ISHWorkerShell) {
    guard !finished else { return }
    NSLog("ish-loopback: worker run stuck, killing worker session %@", worker.sessionId)
    ISHShellExecutor.shared().stopWorker(forSession: worker.sessionId)
    // Backstop: if the death notice does not complete the run within
    // 2 s, complete directly (the run must never hang the session).
    queue.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self, !self.finished else { return }
      self.completeRun(exitCode: self.cancelled ? -4 : -3, timedOut: self.timedOut,
                       cancelled: self.cancelled, workerDied: true)
    }
  }

  /// The single completion point. No-op if already finished. Releases
  /// the worker (clears the death handler + the output handler) before
  /// sending the terminal frame, so the next run can start.
  private func completeRun(exitCode: Int, timedOut: Bool = false,
                           cancelled: Bool = false, workerDied: Bool = false) {
    guard !finished else { return }
    finished = true
    // Flush trailing partial lines (if any) as final lines.
    if let line = stdoutBuffer.flush() { sendLine(stream: "stdout", lineData: line) }
    if let line = stderrBuffer.flush() { sendLine(stream: "stderr", lineData: line) }
    let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    var frame: [String: Any] = [
      "exitCode": exitCode,
      "durationMs": durationMs,
    ]
    if timedOut {
      frame["timedOut"] = true
      frame["partialOutput"] = partialOutput
    }
    if cancelled {
      frame["cancelled"] = true
    }
    if workerDied {
      frame["workerDied"] = true
    }
    if let cwd = markerCwd {
      // The bridge already learns the cwd from the marker frame; this
      // copy is for debugging (a frame that arrives without its marker
      // still names the directory the run ended in).
      frame["cwd"] = cwd
    }
    if let worker {
      worker.onDeath = nil
      ISHShellExecutor.shared().endWorkerRun(worker)
      self.worker = nil
    }
    // (M-10) Release the in-flight slot only AFTER endWorkerRun has
    // cleared the output handler: releasing earlier would let the next
    // run install its handler first, and this run's endWorkerRun would
    // then clear it (same clobber in reverse). Release is idempotent
    // (deinit re-releases).
    IShLoopbackService.releaseWorkerRun(sessionId: sessionId)
    sendJSONFrame(frame)
    // Close only after the terminating chunk has been handed to the
    // network stack (same reason as ExecSession.onComplete).
    connection?.sendChunkEnd { [weak self] in
      self?.connection?.closeFromAnyQueue()
    }
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

  /// Send the terminating "0\r\n\r\n" chunk. Calls completion when the
  /// chunk has been handed to the network stack; the caller closes
  /// after (closing earlier discards the final frame — close() cancels
  /// the connection before the async sends flush, so the client sees
  /// the stream die mid-response as "aborted").
  fileprivate func sendChunkEnd(completion: @escaping () -> Void = {}) {
    send(Data("0\r\n\r\n".utf8), completion: completion)
  }

  /// Deny a read-only exec/worker run as a normal NDJSON result: exit 1
  /// with the sandbox message on stderr, so the bridge reports the
  /// command as failed (the same shape as the virtual path's EACCES
  /// throw) instead of a bridge/HTTP error that would trigger a retry
  /// or a worker→one-shot fallback. The workspace bind mount is always
  /// writable, so the denial happens here per request — never by
  /// remounting (which would race concurrent execs). (H-1)
  fileprivate func sendReadOnlyDenied() {
    sendChunkedHeaders()
    let line = (try? JSONSerialization.data(
      withJSONObject: ["stream": "stderr",
                       "line": "EACCES: OHOS_SANDBOX_DENIED: 当前调用是 read-only，不能修改文件"],
      options: [])) ?? Data()
    var lineChunk = line
    lineChunk.append(0x0A)
    sendChunk(lineChunk)
    let frame = (try? JSONSerialization.data(
      withJSONObject: ["exitCode": 1, "durationMs": 0],
      options: [])) ?? Data()
    var frameChunk = frame
    frameChunk.append(0x0A)
    sendChunk(frameChunk)
    // Close only after the terminating chunk has been handed to the
    // network stack (same reason as ExecSession.onComplete).
    sendChunkEnd { [weak self] in self?.closeFromAnyQueue() }
  }
}

// MARK: - /ish/pty (WebSocket upgrade + interactive terminal)

extension HTTPConnection {
  /// True when the upgrade URL carries ?readOnly=1 as one exact query
  /// item (readOnly=10 or readOnly=true do not count). A GET upgrade
  /// has no body, so the flag rides the query — see ish-bridge.mjs.
  static func isReadOnlyUpgrade(_ request: HTTPRequest) -> Bool {
    let parts = request.path.split(separator: "?", maxSplits: 1)
    guard parts.count == 2 else { return false }
    return parts[1].split(separator: "&").contains(where: { $0 == "readOnly=1" })
  }

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
    // N-2 (H-1 residual): a terminal opened under a read-only policy
    // must never reach the guest shell — same denial as /ish/exec and
    // /ish/worker/run, before the 101 or any session is created. A
    // plain HTTP 403 (not the exec NDJSON denial: a refused upgrade
    // has no stream to write to, and the bridge fails the handshake).
    // Only a spawnTerminal call that carried a read-only policy sends
    // the flag; a manually opened terminal has no policy and is
    // unaffected.
    if Self.isReadOnlyUpgrade(request) {
      sendJSON(status: 403, reason: "Forbidden",
               object: ["error": "EACCES: OHOS_SANDBOX_DENIED: 当前调用是 read-only，不能修改文件"])
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
      // spawns the shell and registers the PTY session; if the
      // session cap is reached it closes with 1008.
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
    // Each socket gets its own kernel session (stage 5.3): a fresh
    // UUID is the routing key for this socket's PTY.
    let sessionId = UUID().uuidString
    var pid: Int32 = 0
    let rc = ISHKernel.shared.executeCommand(["/bin/sh"], pid: &pid,
        sessionId: sessionId, fsContext: 0, cols: 0, rows: 0)
    guard rc == 0, pid > 0 else {
      // -5 is the session cap: refuse as 1008 (policy), not 1011.
      if rc == -5 {
        close(code: 1008, reason: "too many pty sessions are active (max \(ISHPtyMaxSessions))")
      } else {
        NSLog("ish-loopback: pty shell spawn failed (rc=\(rc))")
        close(code: 1011, reason: "shell spawn failed")
      }
      return
    }
    let session = PTYSession(id: sessionId, guestPid: Int(pid), service: service, ws: self)
    guard let service, service.registerPTYSession(session) else {
      // Cap filled between the spawn and the register (a duplicate
      // id cannot happen with UUIDs): release the kernel session —
      // closePtySession kills the shell AND frees the registry
      // slot — then refuse.
      ISHKernel.shared.closePtySession(sessionId)
      close(code: 1008, reason: "too many pty sessions are active (max \(ISHPtyMaxSessions))")
      return
    }
    ptySession = session
    // Tell the client its session id (the bridge stores it for
    // diagnostics; routing itself is by socket). Sent as a text
    // frame: the client distinguishes control frames by opcode
    // (binary = PTY bytes, text = JSON control).
    sendText("{\"type\":\"session\",\"sessionId\":\"\(sessionId)\"}")
    NSLog("ish-loopback: pty session started (guest pid \(pid), session \(sessionId))")
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
    case 0x8: // Close — echo the code, then close (waits for the
      // echo frame to flush before tearing down the connection).
      var code: UInt16 = 1000
      if payload.count >= 2 {
        code = UInt16(payload[0]) << 8 | UInt16(payload[1])
      }
      close(code: code, reason: "client requested close")
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
           cols > 0, rows > 0, let id = ptySession?.id {
          ISHKernel.shared.setTerminalSize(Int32(cols), rows: Int32(rows), sessionId: id)
        }
      case "close":
        close(code: 1000, reason: "client requested close")
      default:
        break
      }
    case 0x2: // Binary — PTY input (raw bytes to the guest shell).
      if let id = ptySession?.id {
        ISHKernel.shared.sendInput(payload, sessionId: id)
      }
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

  /// Send a text frame (JSON control, e.g. the session hello sent
  /// right after the upgrade).
  func sendText(_ string: String) {
    guard !closed else { return }
    sendFrame(opcode: 0x1, payload: Data(string.utf8))
  }

  private func sendFrame(opcode: UInt8, payload: Data, completion: @escaping () -> Void = {}) {
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
    guard let httpConnection else { completion(); return }
    httpConnection.send(frame, completion: completion)
  }

  private func sendCloseFrame(code: UInt16, completion: @escaping () -> Void = {}) {
    var payload = Data()
    payload.append(UInt8((code >> 8) & 0xFF))
    payload.append(UInt8(code & 0xFF))
    sendFrame(opcode: 0x8, payload: payload, completion: completion)
  }

  /// Send a close frame (if not already closed) and close the
  /// connection. The TCP teardown waits until the close frame has
  /// been handed to the network stack: cancelling the connection
  /// synchronously right after enqueueing the frame (the old code)
  /// discarded the frame, so the client saw `read ECONNRESET`
  /// instead of the intended close code (e.g. 1008 "too many pty
  /// sessions are active"). A 2 s fallback tears down anyway, so a
  /// stuck send can never leak the connection or the shell.
  /// Idempotent.
  func close(code: UInt16, reason: String) {
    guard !closed else { return }
    closed = true
    NSLog("ish-loopback: closing pty websocket (code \(code)): \(reason)")
    service?.workQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      self?.tearDown()
    }
    sendCloseFrame(code: code) { [weak self] in
      self?.tearDown()
    }
  }

  /// Close from the local side (service stopping / shell exited /
  /// peer close). Kills the shell's process group via the session.
  func closeLocal() {
    guard !closed else { return }
    closed = true
    tearDown()
  }

  /// Shared teardown: kill the shell's process group, drop the
  /// session, close the HTTP connection. Idempotent.
  private func tearDown() {
    ptySession?.close(reason: "websocket closed")
    ptySession = nil
    httpConnection?.close()
  }
}

/// One interactive guest shell (/bin/sh) driven by a /ish/pty
/// WebSocket. The shell is a child of init (pid >= 2); on close its
/// process group is killed (never pid 1, never halt_system).
private final class PTYSession {
  /// The kernel session id (UUID, the routing key for this session's
  /// PTY). The WSConnection owns exactly one PTYSession.
  let id: String
  let guestPid: Int
  private weak var service: IShLoopbackService?
  private weak var ws: WSConnection?
  /// Read by IShLoopbackService.forwardPTYOutput (same file).
  fileprivate var closed = false
  private var exitObserver: NSObjectProtocol?

  init(id: String, guestPid: Int, service: IShLoopbackService?, ws: WSConnection) {
    self.id = id
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
  /// from the service queue via this session's kernel output handler.
  func sendBinary(_ data: Data) {
    guard !closed else { return }
    ws?.sendBinary(data)
  }

  /// Kill the shell's process group, unregister the kernel session
  /// (frees the registry slot + clears the output handler), and
  /// unregister from the service. Idempotent. Runs on the service
  /// queue.
  func close(reason: String) {
    guard !closed else { return }
    closed = true
    if let observer = exitObserver {
      NotificationCenter.default.removeObserver(observer)
      exitObserver = nil
    }
    ISHKernel.shared.closePtySession(id)
    service?.clearPTYSession(self)
    NSLog("ish-loopback: pty session closed (guest pid \(guestPid), session \(id)): \(reason)")
  }
}
