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
//                        guestProcessCount, governors, error?}
//                        (governors: stage 2.5 live snapshot — memory
//                        governor state, fork-guard counters, fork-rate
//                        stats, background CPU governor state)
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

  /// Raw PTY byte sink for the loopback service (stage 2.4 /ish/pty).
  /// The log ring still receives the same bytes (line-split); the sink
  /// receives the raw burst bytes, unmodified, so the WebSocket forwards
  /// a proper byte stream (no line-splitting, no data loss — the 2.3
  /// log ring's trailing-partial-line split does not apply here).
  /// Set by IShLoopbackService on start, cleared on stop. Called on the
  /// main queue (the outputCallback is main-queue batched).
  static var ptyOutputSink: ((Data) -> Void)?

  private let files = FileManager.default
  private let kernel = ISHKernel.shared

  private var phase: String = ISHRuntime.initialPhase()
  private var lastError: [String: String]?
  private var logs: [[String: Any]] = []
  private var logSequence = 0
  private var eventSink: FlutterEventSink?
  private var lifecycleBusy = false

  private static func initialPhase() -> String {
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
        // Raw bytes to the loopback PTY sink first (proper byte stream
        // for /ish/pty); the log ring below still gets its line-split
        // copy. Both see the same burst — nothing is consumed twice:
        // outputCallback receives the drained batch, and the sink just
        // forwards it.
        Self.ptyOutputSink?(data)
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
      "governors": kernel.resourceGovernorStatus(),
    ]
    if let hash = RootfsManager.installedHash() { value["rootfsVersion"] = hash }
    if let error = lastError { value["error"] = error }
    // Diagnostic (build 31): loopback service state. The kernel can be
    // "running" while the loopback service is down (no token file), which
    // makes backend.create fail with a bare generic error — the failure
    // page then shows `iSH: running` with no hint why. Expose it here so
    // the Dart failure page can tell the bridge path apart from the kernel.
    value["loopbackRunning"] = IShLoopbackService.shared.isRunning
    if let info = IShLoopbackService.shared.serviceInfo,
       let port = info["port"] as? Int, port > 0 {
      value["loopbackPort"] = port
    }
    // Diagnostic (build 36): why the loopback service is down. Build 35
    // showed `loopback DOWN` with no cause — expose the listener's last
    // state + error so the failure page can name it.
    let lb = IShLoopbackService.shared.diagnostics
    value["loopbackState"] = lb["state"] as? String ?? "unknown"
    value["loopbackStartCalled"] = lb["startCalled"] as? Bool ?? false
    value["loopbackStartCount"] = lb["startCount"] as? Int ?? 0
    if let e = lb["lastError"] as? String { value["loopbackError"] = e }
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

  /// Ensure the host workspace directory exists and is bind-mounted
  /// into the guest at /home/workspace (design §2.6; idempotent —
  /// safe to call again after boot). The DSH gateway validates this
  /// directory before creating a terminal session; if it is missing
  /// the terminal fails with "gateway/internal: working-directory:
  /// directory does not exist" (build 43 device test 23:03).
  /// (Build 44) This used to live only in the fresh-boot path, so
  /// the kernel.isBooted early-return branch never created the
  /// directory or the mount — same class of bug as build 42 (the
  /// loopback service was not restarted in that branch either).
  /// (Build 45) Returns whether the directory exists after the
  /// attempt, so a silent create failure surfaces as a clear boot
  /// error instead of the cryptic gateway error later. The
  /// bind-mount itself stays non-fatal (the guest boots without it).
  @discardableResult
  private func ensureHostWorkspace() -> Bool {
    do {
      try files.createDirectory(at: Self.hostWorkspaceURL, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    } catch {
      DispatchQueue.main.async { [weak self] in
        self?.log("/home/workspace 宿主目录创建失败：\(error.localizedDescription)")
      }
      return false
    }
    guard files.fileExists(atPath: Self.hostWorkspaceURL.path) else {
      DispatchQueue.main.async { [weak self] in
        self?.log("/home/workspace 宿主目录创建后仍不存在")
      }
      return false
    }
    let mountRc = kernel.bindMountPath("/home/workspace", toHostPath: Self.hostWorkspaceURL.path, readOnly: false)
    if mountRc != 0 {
      DispatchQueue.main.async { [weak self] in
        self?.log("/home/workspace 挂载失败（rc=\(mountRc)），终端可用但 workspace 不共享")
      }
    }
    return true
  }

  /// Fail performBoot with a clear error when the host workspace
  /// directory cannot be created (build 45): without it the gateway
  /// rejects every terminal with the cryptic "working-directory:
  /// directory does not exist", so surface the cause here instead.
  private func failWorkspaceMissing(result: @escaping FlutterResult) {
    let message = "工作目录创建失败：\(Self.hostWorkspaceURL.path) 不存在，终端无法启动"
    DispatchQueue.main.async { [weak self] in
      self?.setPhase("error", error: ["code": "ish_workspace_missing", "message": message])
      self?.log("boot 失败：\(message)")
    }
    finish(result, error("ish_workspace_missing", message))
  }

  private func performBoot(result: @escaping FlutterResult) {
    // (Retired 2026-11-15: the didResetWhileBooted refusal is gone.
    // Reset is now synchronous and self-healing; the next boot just
    // reinstalls the rootfs from the bundled zip. See
    // ISHKernel.resetRootfsWhileBooted.)
    if kernel.isBooted {
      // (Build 40) The old build-39 path deleted the broken tree and
      // asked for an app restart — but tapping the app icon does not
      // kill the process, so the kernel stayed booted, the files
      // stayed gone, and the restart error fired forever (build 39
      // device test 18:42: "重开也没有用"). The kernel reads guest
      // files on demand, so restore the missing files in place and
      // keep running: the next shell spawn then succeeds, no restart
      // needed. Only if the restore itself fails do we fall back to
      // the restart error.
      if RootfsManager.criticalFilesPresent() {
        // (Build 42) The loopback service must be (re)started here:
        // performReset stops it (listener.cancel(), token file
        // removed), and this early-return branch used to skip the
        // start() call that only the fresh-boot path made — so after
        // a Reset the loopback stayed cancelled forever and the
        // terminal failed with "iSH: running, loopback DOWN
        // (state=cancelled)" (build 41 device test 22:03). start()
        // is idempotent (no-op when already running).
        // (Build 44) Same for the host workspace: create the
        // directory and bind-mount it, or the gateway rejects the
        // terminal with "working-directory: directory does not
        // exist" (build 43 device test 23:03).
        // (Build 45) Fail loudly if the directory still cannot be
        // created, instead of letting the gateway fail cryptically.
        guard ensureHostWorkspace() else {
          failWorkspaceMissing(result: result)
          return
        }
        IShLoopbackService.shared.start()
        DispatchQueue.main.async { [weak self] in self?.setPhase("running") }
        finish(result, nil)
        return
      }
      NSLog("ISHRuntime: 内核已启动但缺关键文件，正在原地补回（无需重启 App）")
      do {
        try RootfsManager.restoreMissingFiles()
      } catch let restoreError {
        NSLog("ISHRuntime: 原地补回失败：%@，回退到重启提示", restoreError.localizedDescription)
        kernel.stopGuest()
        try? RootfsManager.clearBrokenInstallForRestart()
        let message = "Linux 沙箱损坏已清除，请重启 App 完成重装"
        DispatchQueue.main.async { [weak self] in
          self?.setPhase("error", error: ["code": "ish_rootfs_broken_restart_app", "message": message])
        }
        finish(result, error("ish_rootfs_broken_restart_app", message))
        return
      }
      // (Build 42) Same as above: restart the loopback service, which
      // a Reset may have stopped. start() is idempotent.
      // (Build 44) Same for the host workspace: create the directory
      // and bind-mount it (see above).
      // (Build 45) Fail loudly if the directory still cannot be created.
      guard ensureHostWorkspace() else {
        failWorkspaceMissing(result: result)
        return
      }
      IShLoopbackService.shared.start()
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
    let rc = kernel.boot(withRootPath: RootfsManager.rootfsURL.path)
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
    // (Build 45) Fail loudly if the directory still cannot be created.
    guard ensureHostWorkspace() else {
      failWorkspaceMissing(result: result)
      return
    }

    DispatchQueue.main.async { [weak self] in
      self?.setPhase("running")
      self?.log("iSH 已 boot（PID 1 supervisor 已挂起）")
    }
    // Start the loopback service (stage 2.4) so Node's ish-bridge can
    // reach the guest (pty/exec). Non-fatal if it fails to bind — the
    // dsh/ish channel still works; ish-bridge reports backend
    // unavailable until the service is up.
    IShLoopbackService.shared.start()
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
      // The loopback service dies with the reset (the token file is
      // removed; a relaunch regenerates it). Stop it before the kernel
      // reset so no client keeps talking to a dead guest.
      IShLoopbackService.shared.stop()
      // Booted kernel: back up Guest /root first when asked, then the
      // reset-while-booted path (stops the guest, deletes the rootfs
      // synchronously; the next boot reinstalls it from the bundled
      // zip). No relaunch required — reset is self-healing now
      // (retired the didResetWhileBooted flag, 2026-11-15).
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
      let message = "rootfs 已重置，下次启动时将从内置包重装。"
      DispatchQueue.main.async { [weak self] in
        self?.setPhase("notInstalled")
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
