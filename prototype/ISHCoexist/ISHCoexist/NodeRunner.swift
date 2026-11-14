//  NodeRunner.swift
//  ISHCoexist — Stage 1 coexistence prototype
//
//  Minimal NodeMobile launcher, following dsh-go's
//  app/ios/Runner/NativeNodeRuntime.swift (main @ HEAD 8c00d26f):
//  dlopen NodeMobile.framework/NodeMobile (RTLD_NOW | RTLD_LOCAL),
//  dlsym node_start, run it on a dedicated 16 MiB-stack thread named
//  like the original ("DSH NodeMobile" -> "ISHCoexist NodeMobile").
//  Handshake is the same command.json / status.json file pair, simplified:
//  no supervisor/worker split, no DSH engine — the Node side runs a tiny
//  test-runner script (node-test-runner.mjs, written here at launch) that
//  polls node-command.json and answers in node-status.json. Each runScript
//  executes in-process via AsyncFunction, so the signal-handler tests see
//  the REAL Node/V8 handlers in this process.
//
//  node_start may only be called ONCE per process. After Node exits
//  (test ④ kills it on purpose) it cannot be restarted in-process;
//  relaunch the app.

import Foundation

enum NodeError: Error, LocalizedError {
    case frameworkMissing(String)
    case symbolMissing
    case startTimeout
    case runTimeout
    case nodeExited
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .frameworkMissing(let p): return "NodeMobile.framework 缺失：\(p)（需构建脚本先产出 NativeNodeArtifacts）"
        case .symbolMissing: return "dlopen 成功但找不到 node_start 符号"
        case .startTimeout: return "Node 30 秒内未就绪（status.json 无 ready）"
        case .runTimeout: return "Node 脚本执行超时"
        case .nodeExited: return "Node 已退出（node_start 返回），进程内无法重启，需重开 App"
        case .scriptError(let m): return "Node 脚本报错：\(m)"
        }
    }
}

final class NodeRunner {
    typealias NodeStart = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

    static let shared = NodeRunner()

    private let files = FileManager.default
    private let queue = DispatchQueue(label: "me.zzuu.ishcoexist.node-runner")

    private(set) var nodeStarted = false
    private(set) var nodeExited = false
    private(set) var nodeVersion = ""

    var root: URL {
        files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ISHCoexist/node", isDirectory: true)
    }

    private var commandURL: URL { root.appendingPathComponent("command.json") }
    private var statusURL: URL { root.appendingPathComponent("status.json") }
    private var runnerURL: URL { root.appendingPathComponent("node-test-runner.mjs") }

    private var commandCounter = 0

    // MARK: - Start

    /// Start Node once. Calls completion on an arbitrary queue.
    func start(completion: @escaping (Result<String, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.nodeExited { completion(.failure(NodeError.nodeExited)); return }
            if self.nodeStarted { completion(.success(self.nodeVersion)); return }
            do {
                try self.prepareStorage()
                try self.writeRunner()
                try self.startNodeThread()
                let version = try self.waitReady(timeout: 30)
                self.nodeStarted = true
                self.nodeVersion = version
                completion(.success(version))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func prepareStorage() throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try? files.removeItem(at: commandURL)
        try? files.removeItem(at: statusURL)
    }

    private func startNodeThread() throws {
        guard let binary = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("NodeMobile.framework/NodeMobile") else {
            throw NodeError.frameworkMissing("(Frameworks 目录不可用)")
        }
        guard files.fileExists(atPath: binary.path) else {
            throw NodeError.frameworkMissing(binary.path)
        }
        guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(handle, "node_start") else {
            throw NodeError.symbolMissing
        }
        // Keep the image loaded for the process lifetime, including after exit.
        let start = unsafeBitCast(symbol, to: NodeStart.self)
        let arguments = ["node", runnerURL.path, root.path]
        let thread = Thread { [weak self] in
            let bytes = arguments.flatMap { Array($0.utf8CString) }
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            defer { buffer.deallocate() }
            bytes.withUnsafeBufferPointer { buffer.initialize(from: $0.baseAddress!, count: bytes.count) }
            var offset = 0
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { argument in
                defer { offset += argument.utf8.count + 1 }
                return buffer.advanced(by: offset)
            }
            argv.append(nil)
            let exitCode = argv.withUnsafeMutableBufferPointer { start(Int32(arguments.count), $0.baseAddress) }
            DispatchQueue.main.async { [weak self] in
                self?.nodeExited = true
                NSLog("ISHCoexist Node: node_start returned (\(exitCode))")
            }
        }
        thread.name = "ISHCoexist NodeMobile"
        thread.stackSize = 16 * 1024 * 1024
        thread.start()
    }

    private func waitReady(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if nodeExited { throw NodeError.nodeExited }
            if let data = try? Data(contentsOf: statusURL),
               let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               record["phase"] as? String == "ready" {
                return record["nodeVersion"] as? String ?? ""
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw NodeError.startTimeout
    }

    // MARK: - Run a script in-process

    /// Run `script` inside the already-running Node (AsyncFunction).
    /// Returns the script's captured console output. Throws on timeout
    /// or when the script throws (error text included).
    func runScript(_ script: String, timeout: TimeInterval = 15) throws -> String {
        var result: Result<String, Error>?
        let group = DispatchGroup()
        group.enter()
        queue.async { [weak self] in
            defer { group.leave() }
            guard let self else { result = .failure(NodeError.nodeExited); return }
            if self.nodeExited { result = .failure(NodeError.nodeExited); return }
            do {
                result = .success(try self.runScriptLocked(script, timeout: timeout))
            } catch {
                result = .failure(error)
            }
        }
        let waited = group.wait(timeout: .now() + timeout + 5)
        guard waited == .success, let result else { throw NodeError.runTimeout }
        return try result.get()
    }

    private func runScriptLocked(_ script: String, timeout: TimeInterval) throws -> String {
        commandCounter += 1
        let id = "cmd-\(commandCounter)-\(UUID().uuidString.prefix(8))"
        let payload: [String: Any] = ["id": id, "action": "run", "script": script]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: commandURL, options: .atomic)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if nodeExited { throw NodeError.nodeExited }
            if let data = try? Data(contentsOf: statusURL),
               let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               record["id"] as? String == id,
               let phase = record["phase"] as? String,
               phase == "done" || phase == "error" {
                let output = record["output"] as? String ?? ""
                if phase == "error" {
                    throw NodeError.scriptError((record["error"] as? String ?? "unknown") +
                                                (output.isEmpty ? "" : "\n输出：\(output)"))
                }
                return output
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NodeError.runTimeout
    }

    /// Ask Node to exit cleanly (used at the end of the suite, not by test ④).
    func stop() {
        queue.async { [weak self] in
            guard let self, !self.nodeExited else { return }
            let payload: [String: Any] = ["id": "stop-\(UUID().uuidString.prefix(8))",
                                          "action": "stop"]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                try? data.write(to: self.commandURL, options: .atomic)
            }
        }
    }

    // MARK: - The Node-side test runner (written to disk at launch)

    private func writeRunner() throws {
        // Keep in sync with the harness's expectations:
        // status phases: ready | done | error | stopped.
        // ready reports process.version. run() captures console.log/error
        // and reports them; a thrown error is reported with its stack.
        let source = """
        import { readFile, rename, writeFile } from 'node:fs/promises';
        import { join } from 'node:path';

        const root = process.argv[2];
        const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
        let lastId = '';

        async function report(value) {
          const file = join(root, 'status.json');
          const tmp = file + '.tmp';
          await writeFile(tmp, JSON.stringify(value));
          await rename(tmp, file);
        }

        async function poll() {
          try {
            const cmd = JSON.parse(await readFile(join(root, 'command.json'), 'utf8'));
            if (cmd.id === lastId) return;
            lastId = cmd.id;
            if (cmd.action === 'stop') {
              await report({ id: cmd.id, phase: 'stopped', output: '' });
              process.exit(0);
            }
            if (cmd.action !== 'run') return;
            const logs = [];
            const origLog = console.log;
            const origErr = console.error;
            console.log = (...a) => { logs.push(a.map(String).join(' ')); };
            console.error = (...a) => { logs.push('[err] ' + a.map(String).join(' ')); };
            try {
              const ret = await new AsyncFunction(cmd.script)();
              if (ret !== undefined) logs.push('[return] ' + String(ret));
              await report({ id: cmd.id, phase: 'done', output: logs.join('\\n') });
            } catch (e) {
              await report({ id: cmd.id, phase: 'error', output: logs.join('\\n'),
                             error: String((e && e.stack) || e) });
            } finally {
              console.log = origLog;
              console.error = origErr;
            }
          } catch (e) {
            if (e.code !== 'ENOENT') { /* transient read/parse: retry next tick */ }
          }
        }

        await report({ id: 'boot', phase: 'ready', output: 'node ok',
                       nodeVersion: process.version });
        setInterval(poll, 50);
        """
        try source.write(to: runnerURL, atomically: true, encoding: .utf8)
    }
}
