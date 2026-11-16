//  ShellBoxPlugin.swift
//  MethodChannel `dsh/shellbox` — iOS background execution.
//
//  Implements ONLY the background methods the Dart ShellBoxRuntimeBridge calls:
//  - `setBackgroundEnabled {enabled}`
//  - `updateActiveTasks {runtimeInstanceId, sessionId, taskId, title?}`
//  - `requestContinuedProcessing` → task identifier String, or null
//  - `cancelContinuedProcessing`
//  - `getBackgroundExecutionState` → {state, enabled, authorizationActive}
//  - `getBackgroundCapabilities` → {continuedProcessingOSSupported, reason?}
//  Native→Dart pushes:
//  - `backgroundExecutionChanged` (same shape as getBackgroundExecutionState)
//  - `cancelBackgroundTask` {runtimeInstanceId, sessionId, taskId} — on system
//    expiry or Stop on the system task card; Dart answers 'accepted' or
//    'unconfirmed'.
//
//  Keep-alive (OpenMinis BackgroundKeepAliveManager pattern, focused port):
//  - Silent audio (AVAudioEngine, 1 s silence looped) is the primary
//    keep-alive. Without it the process is suspended in the background.
//  - A standing location session (CLLocationManager, background updates)
//    is the other primary keep-alive; without it the lock screen freezes
//    ~30 s after backgrounding. Denial degrades to audio + continued only.
//  - iOS 26 BGContinuedProcessingTask is the supplement: submitted ONLY
//    from the foreground when a run starts; a 2 s timer reports progress
//    or the system expires it as stalled; the system task card has a Stop
//    button (indistinguishable from expiry via the API).
//
//  Deliberately NOT here (follow-ups, need their own UI + native work):
//  Live Activity, task notifications, privacy mode, background reading.

import AVFoundation
import BackgroundTasks
import CoreLocation
import Flutter
import UIKit

public final class ShellBoxPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dsh/shellbox", binaryMessenger: registrar.messenger())
        let instance = ShellBoxPlugin(channel: channel)
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
    }

    private static let enabledKey = "dsh.shellbox.backgroundEnabled"

    private let channel: FlutterMethodChannel

    // MARK: - State

    private enum BgState: String {
        case foreground
        case resuming
        case backgroundGrace
        case continuedProcessing
        case expired
        case failed
        case completed
        case error
    }

    private var state: BgState = .foreground
    private var enabled: Bool
    private var registrationFailed = false
    private var resumeTimer: Timer?

    /// The active task's identity (for the continued-task card + the
    /// cancelBackgroundTask push). Set by updateActiveTasks.
    private var activeTaskInfo: (runtimeInstanceId: String, sessionId: String, taskId: String, title: String)?

    /// The running BGContinuedProcessingTask (iOS 26+), stored as Any so
    /// this property compiles on older deployment targets.
    private var continuedTask: Any?
    private var pendingContinuedId: String?
    private var continuedHandlerHold: DispatchSemaphore?
    private var continuedProgressTimer: Timer?

    // MARK: - Keep-alive

    private var audioEngine: AVAudioEngine?
    private var silentPlayerNode: AVAudioPlayerNode?
    private var silentAudioActive = false

    private lazy var locationManager = CLLocationManager()
    private var locationUpdating = false

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        self.enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        // Restore the keep-alive if the user had it enabled. Location is
        // only started when already authorized (no prompt at launch).
        if enabled {
            startSilentAudio()
            startLocation(requestAuthorization: false)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Method channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setBackgroundEnabled":
            let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
            setBackgroundEnabled(enabled)
            result(nil)
        case "updateActiveTasks":
            if let args = call.arguments as? [String: Any] {
                updateActiveTasks(args)
            }
            result(nil)
        case "requestContinuedProcessing":
            requestContinuedProcessing(result: result)
        case "cancelContinuedProcessing":
            cancelContinuedProcessing()
            result(nil)
        case "getBackgroundExecutionState":
            result(snapshot())
        case "getBackgroundCapabilities":
            result(capabilities())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - State snapshot

    private func snapshot() -> [String: Any] {
        return [
            "state": state.rawValue,
            "enabled": enabled,
            "authorizationActive": continuedTask != nil,
        ]
    }

    private func capabilities() -> [String: Any] {
        if #available(iOS 26.0, *) {
            var caps: [String: Any] = ["continuedProcessingOSSupported": true]
            if registrationFailed {
                caps["reason"] = "registration_failed"
            }
            return caps
        }
        return ["continuedProcessingOSSupported": false, "reason": "requires_ios_26"]
    }

    private func pushState() {
        let snap = snapshot()
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod("backgroundExecutionChanged", arguments: snap)
        }
    }

    // MARK: - setBackgroundEnabled / updateActiveTasks

    private func setBackgroundEnabled(_ enabled: Bool) {
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startKeepAlive()
        } else {
            stopKeepAlive()
            // No reason to keep a continued task running once disabled.
            if finishContinuedTask(success: true, reason: "disabled") {
                state = .completed
            }
        }
        pushState()
    }

    private func updateActiveTasks(_ args: [String: Any]) {
        let runtimeInstanceId = args["runtimeInstanceId"] as? String ?? ""
        let sessionId = args["sessionId"] as? String ?? ""
        let taskId = args["taskId"] as? String ?? ""
        let title = args["title"] as? String ?? "DSH agent"
        activeTaskInfo = (runtimeInstanceId, sessionId, taskId, title)
    }

    // MARK: - Continued processing (iOS 26+)

    private func requestContinuedProcessing(result: @escaping FlutterResult) {
        // The system only accepts the request from the foreground app.
        guard enabled else { result(nil); return }
        guard UIApplication.shared.applicationState == .active else { result(nil); return }
        guard #available(iOS 26.0, *) else { result(nil); return }
        submitContinuedTask(result: result)
    }

    @available(iOS 26.0, *)
    private func submitContinuedTask(result: @escaping FlutterResult) {
        // A fresh identifier per request: registering one identifier twice
        // kills the app (BGTaskScheduler).
        let prefix = (Bundle.main.bundleIdentifier ?? "io.github.ccch1mneyyy.dshApp") + ".dsh.continued."
        let id = prefix + UUID().uuidString.prefix(8)
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            task.expirationHandler = { [weak self] in
                DispatchQueue.main.async { self?.continuedTaskExpired(id: id) }
            }
            let hold = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self] in
                self?.continuedTaskStarted(task, id: id, hold: hold)
            }
            // Keep the launch handler alive until the task completes
            // (Apple's examples do the work inside the handler).
            hold.wait()
        }
        guard registered else {
            registrationFailed = true
            state = .failed
            pushState()
            result(nil)
            return
        }
        let title = activeTaskInfo?.title ?? "DSH agent"
        let request = BGContinuedProcessingTaskRequest(
            identifier: id, title: title, subtitle: "Agent running in the background")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            pendingContinuedId = id
            result(id)
        } catch {
            registrationFailed = true
            state = .failed
            pushState()
            result(nil)
        }
    }

    @available(iOS 26.0, *)
    private func continuedTaskStarted(_ task: BGContinuedProcessingTask, id: String, hold: DispatchSemaphore) {
        guard pendingContinuedId == id else {
            // The run ended before the task started; complete at once.
            task.setTaskCompleted(success: true)
            hold.signal()
            return
        }
        pendingContinuedId = nil
        continuedTask = task
        continuedHandlerHold = hold
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 0
        state = .continuedProcessing
        pushState()
        continuedProgressTimer?.invalidate()
        continuedProgressTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tickContinuedProgress()
        }
    }

    @available(iOS 26.0, *)
    private func tickContinuedProgress() {
        guard let task = continuedTask as? BGContinuedProcessingTask else { return }
        let p = task.progress
        // Unknown length: keep moving, never reaching the end.
        if p.totalUnitCount - p.completedUnitCount < 10 { p.totalUnitCount += 100 }
        p.completedUnitCount += 1
        let title = activeTaskInfo?.title ?? "DSH agent"
        task.updateTitle(title, subtitle: "Agent running in the background")
    }

    private func continuedTaskExpired(id: String) {
        // Also what the system task card's Stop button produces: the API
        // does not tell the two apart. No new request this run.
        finishContinuedTask(success: false, reason: "expired")
        state = .expired
        // Tell Dart the task was cancelled, so the runtime can run its
        // cancel callback (the page's own Cancel flow already knows).
        if let info = activeTaskInfo {
            channel.invokeMethod("cancelBackgroundTask", arguments: [
                "runtimeInstanceId": info.runtimeInstanceId,
                "sessionId": info.sessionId,
                "taskId": info.taskId,
            ])
        }
        pushState()
    }

    private func cancelContinuedProcessing() {
        if finishContinuedTask(success: true, reason: "userCancelled") {
            state = .completed
            pushState()
        }
    }

    /// Completes the active continued task, if any. Returns true when a
    /// task was running.
    @discardableResult
    private func finishContinuedTask(success: Bool, reason: String) -> Bool {
        continuedProgressTimer?.invalidate()
        continuedProgressTimer = nil
        pendingContinuedId = nil
        NSLog("[ShellBox] continued task finishing success=\(success) reason=\(reason)")
        guard #available(iOS 26.0, *) else {
            continuedTask = nil
            continuedHandlerHold = nil
            return false
        }
        return finishContinuedTask26(success: success)
    }

    @available(iOS 26.0, *)
    private func finishContinuedTask26(success: Bool) -> Bool {
        guard let task = continuedTask as? BGContinuedProcessingTask else {
            continuedTask = nil
            continuedHandlerHold = nil
            return false
        }
        continuedTask = nil
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: success)
        continuedHandlerHold?.signal()
        continuedHandlerHold = nil
        return true
    }

    // MARK: - Keep-alive: silent audio

    private func startKeepAlive() {
        startSilentAudio()
        startLocation(requestAuthorization: true)
    }

    private func stopKeepAlive() {
        stopSilentAudio()
        stopLocation()
    }

    private func startSilentAudio() {
        guard !silentAudioActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("[ShellBox] audio session setup failed: \(error)")
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        // 1 second of silence, looped. The buffer is zero-filled.
        let sampleRate: Double = 44100
        let frameCount = AVAudioFrameCount(sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            NSLog("[ShellBox] failed to create silent audio buffer")
            return
        }
        buffer.frameLength = frameCount
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.001
        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            audioEngine = engine
            silentPlayerNode = player
            silentAudioActive = true
            NSLog("[ShellBox] silent audio keep-alive ACTIVE")
        } catch {
            NSLog("[ShellBox] audio engine start failed: \(error)")
        }
    }

    private func stopSilentAudio() {
        silentPlayerNode?.stop()
        audioEngine?.stop()
        silentPlayerNode = nil
        audioEngine = nil
        silentAudioActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("[ShellBox] audio session deactivate failed: \(error)")
        }
    }

    // MARK: - Keep-alive: location

    private func startLocation(requestAuthorization: Bool) {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        if requestAuthorization {
            locationManager.requestAlwaysAuthorization()
        }
        maybeStartLocationUpdates()
    }

    private func maybeStartLocationUpdates() {
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        guard !locationUpdating else { return }
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = false
        locationManager.startUpdatingLocation()
        locationUpdating = true
        NSLog("[ShellBox] location keep-alive started")
    }

    private func stopLocation() {
        if locationUpdating {
            locationManager.stopUpdatingLocation()
            locationUpdating = false
        }
        locationManager.allowsBackgroundLocationUpdates = false
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Start once the user grants; if denied, keep-alive degrades to
        // audio + continued processing only.
        if enabled {
            maybeStartLocationUpdates()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Keep-alive only; the locations are not used.
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[ShellBox] location error: \(error)")
    }

    // MARK: - App lifecycle

    @objc private func appDidEnterBackground() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        state = continuedTask != nil ? .continuedProcessing : .backgroundGrace
        pushState()
    }

    @objc private func appWillEnterForeground() {
        if continuedTask != nil {
            state = .continuedProcessing
            pushState()
            return
        }
        // Terminal states (expired/failed/completed) stay as-is; only a
        // plain background grace becomes the transient resuming state.
        guard state == .backgroundGrace else { return }
        state = .resuming
        pushState()
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.state == .resuming {
                self.state = .foreground
                self.pushState()
            }
        }
    }
}
