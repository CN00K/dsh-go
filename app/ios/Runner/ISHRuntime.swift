//  ISHRuntime.swift
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.3).
//
//  Flutter plugin for MethodChannel `dsh/ish` (+ EventChannel
//  `dsh/ish/events`), the Dart ↔ Swift side of the iSH Linux guest.
//  Parallel to NativeNodeRuntime (`dsh/native_node`); deliberately a
//  SEPARATE channel with its own phase machine (design §2.4(a)):
//  iSH's stop/restart are repeatable and must never inherit Node's
//  `nodeExited` terminal semantics — Node exit is terminal and needs an
//  app relaunch; iSH stop only stops the guest (pid >= 2), the app
//  lives, and a later boot() works again.
//
//  Methods (design §2.4(a)):
//    status            -> {phase, booted, rootfsReady, rootfsVersion,
//                        kernelVersion, guestMemoryBytes,
//                        guestProcessCount, error?}
//    boot / stop / restart -> null (async; idempotent)
//    reset {keepUserData}  -> null (async)
//    getLogs / logs / getLogSnapshot {lines} -> [String] / {entries, throughSeq}
//
//  Phases (independent state machine, NOT RuntimePhase):
//    notInstalled / installing / installed / booting / running /
//    stopping / stopped / stopBlocked / error.
//
//  STARTUP ORDER (design §2.4(c)): Dart triggers boot() only after the
//  local Node engine is running and DSH is connected, so by the time
//  boot() runs here, NodeMobile has initialised and installing the iSH
//  crash handler captures Node's handler in g_prev (mitigation ①,
//  design §6 risk 1). boot() installs the handler itself —
//  ISHKernel.bootWithRootPath: verifies it is installed and refuses
//  with -3 if it is not.
//
//  THREADING: all channel state is owned by the main queue (same rule
//  as NativeNodeRuntime). boot/stop/restart/reset do their long work on
//  a background queue and call the FlutterResult exactly once, on the
//  main queue, when done. A second lifecycle call while one is in
//  flight gets `ish_busy`.
//
//  LOGS: the guest's PTY output arrives via ISHKernel.outputCallback
//  (batched per burst, main queue); it is decoded lossy-UTF-8, split
//  into lines and kept in a 100-entry ring ({seq, line, stream}) with
//  the same {seq, line, stream} shape as `dsh/native_node` logs.
//  Partial lines (a burst ending mid-line) are logged as-is; the
//  loopback service (stage 2.4) does proper byte streaming.

import Flutter
import Foundation

/// iSH guest lifecycle, exposed to Dart over `dsh/ish`.
@objc(DshIshRuntime) final class ISHRuntime: NSObject, FlutterStreamHandler {
  private static let shared = ISHRuntime()

  /// Pinned ish-arm64 commit (third_party/ish/source.json).
  private static let kernelVersion = "0fd17a13"

  /// Host workspace shared into the guest at /home/workspace
  /// (same directory DSH uses as its working directory).
  private static var hostWorkspaceURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NativeNode/home/workspace", isDirectory: true)
  }

  private let files = FileManager.default
  private let kernel = ISHKernel.shared

  private var phase: String = ISHRuntime.initialPhase()
  private var lastError: [String: String]?
  private var logs: [[String: Any]] = []
  private var logSequence = 0
  private var eventSink: FlutterEventSink?
  private var lifecycleBusy = false

  private static func initialPhase() -> String {
    if ISHKernel.shared.didResetWhileBooted { return "error" }
    if ISHKernel.shared.isBooted { return "running" }
    return RootfsManager.isInstalled ? "installed" : "notInstalled"
  }

  override init() {
    super.init()
    // Guest PTY output -> log ring. The callback is invoked on the main
    // queue (batched per burst); dispatch defensively anyway.
    kernel.outputCallback = { [weak self] data in
      DispatchQueue.main.async {
        guard let self else { return }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
          self.log(String(line), stream: "stdout")
        }
      }
    }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dsh/ish", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      shared.handle(call, result: result)
    }
    FlutterEventChannel(name: "dsh/ish/events", binaryMessenger: registrar.messenger())
      .setStreamHandler(shared)
  }

  // MARK: - Events

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    publishStatus()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - Status

  private var status: [String: Any] {
    var count: Int32 = 0
    var anon: UInt64 = 0
    let n = kernel.getGuestProcessCount(&count, anonBytes: &anon)
    var value: [String: Any] = [
      "phase": phase,
      "booted": kernel.isBooted,
      "rootfsReady": RootfsManager.isInstalled,
      "kernelVersion": Self.kernelVersion,
      "guestMemoryBytes": n >= 0 ? Int(anon) : 0,
      "guestProcessCount": Int(n),
    ]
    if let hash = RootfsManager.installedHash() { value["rootfsVersion"] = hash }
    if let error = lastError { value["error"] = error }
    return value
  }

  private func setPhase(_ next: String, error: [String: String]? = nil) {
    phase = next
    lastError = error
    publishStatus()
  }

  private func publishStatus() {
    var value = status
    if let reason = value["error"] as? [String: String] {
      value["error"] = [reason["code"], reason["message"]].compactMap { $0 }.joined(separator: ": ")
    }
    eventSink?(["type": "status", "status": value])
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }

  // MARK: - Logs

  private func log(_ line: String, stream: String = "system") {
    // All channel state is main-queue owned; the rootfs progress
    // closure is documented main-queue, but never trust a callback.
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in self?.log(line, stream: stream) }
      return
    }
    logSequence += 1
    let entry: [String: Any] = ["seq": logSequence, "line": line, "stream": stream]
    logs.append(entry)
    eventSink?(["type": "logs", "entries": [entry]])
    if logs.count > 100 { logs.removeFirst() }
    NSLog("ish: %@", line)
  }

  // MARK: - Method handling

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let method = call.method
    let arguments = call.arguments as? [String: Any]
    switch method {
    case "getLogs", "logs", "getLogSnapshot":
      let count = max(0, arguments?["lines"] as? Int ?? 100)
      let entries = Array(logs.suffix(count))
      if method == "getLogSnapshot" {
        result(["entries": entries, "throughSeq": logSequence])
      } else {
        result(entries.compactMap { $0["line"] as? String })
      }
      return
    case "status":
      result(status)
      return
    case "boot", "stop", "restart", "reset":
      break // Async lifecycle work below.
    default:
      result(FlutterMethodNotImplemented)
      return
    }

    // Lifecycle methods are serialized: a second call while one is in
    // flight is rejected instead of racing the phase machine.
    guard !lifecycleBusy else {
      result(error("ish_busy", "An iSH lifecycle operation is already in progress."))
      return
    }
    lifecycleBusy = true
    let keepUserData = arguments?["keepUserData"] as? Bool ?? false
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      switch method {
      case "boot": self.performBoot(result: result)
      case "stop": self.performStop(result: result)
      case "restart": self.performRestart(result: result)
      case "reset": self.performReset(keepUserData: keepUserData, result: result)
      default: break
      }
    }
  }

  /// Clear the busy flag on the main queue, then call the FlutterResult
  /// exactly once with `value` (nil or a FlutterError).
  private func finish(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { [weak self] in
      self?.lifecycleBusy = false
      result(value)
    }
  }

  // MARK: - Boot

  private func performBoot(result: @escaping FlutterResult) {
    // A reset while booted refuses every boot until the app relaunches.
    if kernel.didResetWhileBooted {
      let err = ["code": "ish_boot_reset_flag",
                 "message": "rootfs 已重置，终端将拒绝起 shell，直到重启 App。"]
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("error", error: err)
        self?.log("boot 被拒：didResetWhileBooted 已置位，需重启 App")
      }
      finish(result, error("ish_boot_reset_flag", err["message"]!))
      return
    }
    if kernel.isBooted {
      DispatchQueue.main.async { [weak self] in self?.setPhase("running") }
      finish(result, nil)
      return
    }

    DispatchQueue.main.async { [weak self] in self?.setPhase("installing") }
    do {
      let installed = try RootfsManager.ensureInstalled { [weak self] fraction in
        self?.log("rootfs 安装进度 \(Int(fraction * 100))%")
      }
      DispatchQueue.main.async { [weak self] in
        self?.log(installed == .alreadyInstalled ? "rootfs 已安装（同哈希幂等）" : "rootfs 已安装")
      }
    } catch let err as RootfsError {
      let code: String
      switch err {
      case .upgradeRequiresReset: code = "ish_rootfs_upgrade_requires_reset"
      case .missingZip: code = "ish_rootfs_missing"
      case .corruptZip: code = "ish_rootfs_corrupt"
      case .ioError: code = "ish_rootfs_io"
      case .kernelBooted: code = "ish_rootfs_kernel_booted"
      }
      let message = err.localizedDescription
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("error", error: ["code": code, "message": message])
        self?.log("rootfs 安装失败：\(message)")
      }
      finish(result, error(code, message))
      return
    } catch {
      let message = error.localizedDescription
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("error", error: ["code": "ish_rootfs_failed", "message": message])
      }
      finish(result, self.error("ish_rootfs_failed", message))
      return
    }

    // Install the crash handler AFTER Node has initialised (Dart only
    // calls boot once Node is running), so g_prev captures Node's
    // handler (mitigation ①). bootWithRootPath: refuses with -3 if the
    // handler is not installed.
    if ish_crash_handler_install() != 0 {
      let message = "iSH 信号 handler 安装失败"
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("error", error: ["code": "ish_crash_handler_failed", "message": message])
      }
      finish(result, error("ish_crash_handler_failed", message))
      return
    }

    DispatchQueue.main.async { [weak self] in self?.setPhase("booting") }
    let rc = kernel.bootWithRootPath(RootfsManager.rootfsURL.path)
    guard rc == 0 else {
      let (code, message): (String, String) = switch rc {
      case -1: ("ish_boot_no_data", "rootfs 缺失 data/，无法 boot")
      case -2: ("ish_boot_timeout", "PID 1 supervisor 启动超时（30s）")
      case -3: ("ish_boot_crash_handler_missing", "iSH 信号 handler 未安装")
      case -100: ("ish_boot_reset_flag", "rootfs 已重置，需重启 App")
      default: ("ish_boot_failed", "iSH boot 失败（rc=\(rc)）")
      }
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("error", error: ["code": code, "message": message])
        self?.log("boot 失败：\(message)")
      }
      finish(result, error(code, message))
      return
    }

    // Share the DSH workspace into the guest at /home/workspace
    // (design §2.6; idempotent — safe to call again after boot).
    // Non-fatal: the guest still boots without it.
    do {
      try files.createDirectory(at: Self.hostWorkspaceURL, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
      let mountRc = kernel.bindMountPath("/home/workspace", toHostPath: Self.hostWorkspaceURL.path, readOnly: false)
      if mountRc != 0 {
        DispatchQueue.main.async { [weak self] in
          self?.log("/home/workspace 挂载失败（rc=\(mountRc)），终端可用但 workspace 不共享")
        }
      }
    } catch {
      DispatchQueue.main.async { [weak self] in
        self?.log("/home/workspace 宿主目录创建失败：\(error.localizedDescription)")
      }
    }

    DispatchQueue.main.async { [weak self] in
      self?.setPhase("running")
      self?.log("iSH 已 boot（PID 1 supervisor 已挂起）")
    }
    finish(result, nil)
  }

  // MARK: - Stop / restart

  /// Stop the guest (SIGTERM then SIGKILL to pid >= 2) and wait up to
  /// 5 s for the process count to drop to 1 (only PID 1). Returns true
  /// when the guest is stopped, false on timeout (phase stopBlocked).
  /// Must be called from a background queue (it sleeps).
  private func stopGuestAndWait() -> Bool {
    kernel.stopGuest()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      var count: Int32 = 0
      if kernel.getGuestProcessCount(&count, anonBytes: nil) == 1 { return true }
      Thread.sleep(forTimeInterval: 0.1)
    }
    var count: Int32 = 0
    return kernel.getGuestProcessCount(&count, anonBytes: nil) == 1
  }

  private func performStop(result: @escaping FlutterResult) {
    guard kernel.isBooted else {
      finish(result, nil) // Already stopped (or never booted).
      return
    }
    DispatchQueue.main.async { [weak self] in self?.setPhase("stopping") }
    if stopGuestAndWait() {
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("stopped")
        self?.log("Guest 已 stop（仅剩 PID 1），可再次 boot")
      }
      finish(result, nil)
    } else {
      let message = "stop 超时：5s 后 Guest 仍有残留进程"
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("stopBlocked", error: ["code": "ish_stop_blocked", "message": message])
        self?.log(message)
      }
      finish(result, error("ish_stop_blocked", message))
    }
  }

  private func performRestart(result: @escaping FlutterResult) {
    guard kernel.isBooted else {
      // Not booted: restart is just a boot.
      performBoot(result: result)
      return
    }
    DispatchQueue.main.async { [weak self] in self?.setPhase("stopping") }
    if stopGuestAndWait() {
      // The kernel stays booted (PID 1 never exits); a stopped guest
      // is ready to run again immediately — no relaunch needed. This
      // is the core difference from Node's terminal `nodeExited`.
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("running")
        self?.log("Guest 已 restart（stop 后内核仍在，可直接跑命令）")
      }
      finish(result, nil)
    } else {
      let message = "restart 失败：stop 超时，Guest 仍有残留进程"
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("stopBlocked", error: ["code": "ish_stop_blocked", "message": message])
      }
      finish(result, error("ish_stop_blocked", message))
    }
  }

  // MARK: - Reset

  private func performReset(keepUserData: Bool, result: @escaping FlutterResult) {
    if kernel.isBooted {
      // Booted kernel: back up Guest /root first when asked, then the
      // reset-while-booted path (sets didResetWhileBooted, deletes the
      // rootfs; the terminal refuses new shells until relaunch).
      if keepUserData {
        let backup = RootfsManager.ishDirURL
          .appendingPathComponent("rootfs-backup-\(Self.backupStamp())", isDirectory: true)
        do {
          try files.copyItem(at: RootfsManager.dataURL.appendingPathComponent("root"), to: backup)
          DispatchQueue.main.async { [weak self] in
            self?.log("Guest /root 已备份到 \(backup.lastPathComponent)")
          }
        } catch {
          DispatchQueue.main.async { [weak self] in
            self?.log("Guest /root 备份失败（继续重置）：\(error.localizedDescription)")
          }
        }
      }
      kernel.resetRootfsWhileBooted()
      let message = "rootfs 已删除，终端将拒绝起 shell，直到重启 App。"
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("error", error: ["code": "ish_reset_requires_relaunch", "message": message])
        self?.log("reset：\(message)")
      }
      finish(result, nil)
      return
    }
    do {
      try RootfsManager.reset()
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("notInstalled")
        self?.log("rootfs 已删除（下次 boot 重新安装）")
      }
      finish(result, nil)
    } catch {
      let message = error.localizedDescription
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("error", error: ["code": "ish_reset_failed", "message": message])
      }
      finish(result, self.error("ish_reset_failed", message))
    }
  }

  private static func backupStamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
  }
}
