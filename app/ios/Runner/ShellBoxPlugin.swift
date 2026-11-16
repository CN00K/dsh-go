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
//  Also here (settings page, 6 toggles):
//  - Prefer continued processing (iOS 26+): gates requestContinuedProcessing.
//  - Live Activity (DSHActivityAttributes, shared file): started when the app
//    backgrounds with an active task, ended on task outcome / expiry / toggle
//    off. Rendered by the PetLiveActivity widget extension (a second
//    ActivityConfiguration in the same bundle); no new target was needed.
//  - Task notifications (UNUserNotificationCenter): posted when a background
//    task completes / fails / expires; auth requested on toggle-on only.
//  - Privacy mode: Live Activity + notification + speech show a generic
//    message only, never the task title / summary.
//  - Background reading (AVSpeechSynthesizer): reads the reply aloud when a
//    background task completes; background only, never in the foreground.
//  Preferences live in UserDefaults (single source of truth); Dart reads and
//  writes them through getBackgroundPreferences / setBackgroundPreference.
//  notifyTaskOutcome is the completion hook for the runtime to call when a
//  background task finishes (caller wiring is a follow-up, same as the
//  requestContinuedProcessing run-start hook).

import ActivityKit
import AVFoundation
import BackgroundTasks
import CoreLocation
import Flutter
import UIKit
import UserNotifications

public final class ShellBoxPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dsh/shellbox", binaryMessenger: registrar.messenger())
        let instance = ShellBoxPlugin(channel: channel)
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
    }

    private static let enabledKey = "dsh.shellbox.backgroundEnabled"
    private static let preferContinuedKey = "dsh.shellbox.preferContinuedProcessing"
    private static let liveActivityKey = "dsh.shellbox.liveActivityEnabled"
    private static let notificationsKey = "dsh.shellbox.notificationsEnabled"
    private static let privacyKey = "dsh.shellbox.privacyMode"
    private static let speakKey = "dsh.shellbox.backgroundSpeakEnabled"

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
    // MARK: - Preferences (UserDefaults is the single source of truth)

    /// Default true: the pre-existing behaviour submits a continued task when
    /// enabled + foreground + iOS 26.
    private var preferContinued: Bool {
        UserDefaults.standard.object(forKey: Self.preferContinuedKey) as? Bool ?? true
    }
    private var liveActivityEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.liveActivityKey)
    }
    private var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.notificationsKey)
    }
    private var privacyMode: Bool {
        UserDefaults.standard.bool(forKey: Self.privacyKey)
    }
    private var backgroundSpeak: Bool {
        UserDefaults.standard.bool(forKey: Self.speakKey)
    }

    // MARK: - Live Activity / speech state

    /// The running DSH agent Live Activity, stored as Any so this property
    /// compiles on older deployment targets (same pattern as continuedTask).
    private var liveActivity: Any?
    private var liveActivityStatus = "running"
    /// When the current task started; used by the privacy notification body
    /// ("1 task completed · 2m 30s").
    private var taskStartedAt: Date?
    private let speechSynthesizer = AVSpeechSynthesizer()

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
        // A Live Activity from a previous process has no task behind it any
        // more; end it so a stale card does not linger.
        if #available(iOS 16.2, *) { cleanupStaleLiveActivities() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Method channel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
        case "getBackgroundPreferences":
            result(backgroundPreferences())
        case "setBackgroundPreference":
            if let args = call.arguments as? [String: Any],
               let key = args["key"] as? String {
                setBackgroundPreference(key: key, value: args["value"] as? Bool ?? false)
            }
            result(nil)
        case "notifyTaskOutcome":
            if let args = call.arguments as? [String: Any] {
                notifyTaskOutcome(args)
            }
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
        // A new taskId restarts the clock (privacy notification body) and
        // refreshes the Live Activity title if one is showing.
        if activeTaskInfo?.taskId != taskId {
            taskStartedAt = Date()
        }
        activeTaskInfo = (runtimeInstanceId, sessionId, taskId, title)
        if liveActivity != nil, #available(iOS 16.2, *) {
            updateLiveActivity(status: liveActivityStatus, detail: nil)
        }
    }

    // MARK: - Continued processing (iOS 26+)

    private func requestContinuedProcessing(result: @escaping FlutterResult) {
        // The system only accepts the request from the foreground app.
        guard enabled else { result(nil); return }
        // Toggle 2: when the user prefers audio + location only, do not submit.
        guard preferContinued else { result(nil); return }
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
        // The background authorization ended: surface it like a task outcome.
        if #available(iOS 16.2, *) { endLiveActivity(status: "expired", detail: nil) }
        if UIApplication.shared.applicationState != .active {
            postTaskNotification(title: activeTaskInfo?.title, summary: nil,
                                 outcome: "expired", sessionId: activeTaskInfo?.sessionId ?? "")
            speakTaskOutcome(title: activeTaskInfo?.title, summary: nil, outcome: "expired")
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


    // MARK: - Preferences (toggles 2-6)

    private func backgroundPreferences() -> [String: Any] {
        return [
            "preferContinuedProcessing": preferContinued,
            "liveActivity": liveActivityEnabled,
            "notifications": notificationsEnabled,
            "privacyMode": privacyMode,
            "backgroundSpeak": backgroundSpeak,
        ]
    }

    private func setBackgroundPreference(key: String, value: Bool) {
        switch key {
        case "preferContinuedProcessing":
            UserDefaults.standard.set(value, forKey: Self.preferContinuedKey)
            // Turning it off ends the continued task in flight; the silent
            // audio + location keep-alive is unaffected.
            if !value, finishContinuedTask(success: true, reason: "preferContinuedOff") {
                state = .completed
                pushState()
            }
        case "liveActivity":
            UserDefaults.standard.set(value, forKey: Self.liveActivityKey)
            if value {
                if UIApplication.shared.applicationState != .active, #available(iOS 16.2, *) {
                    startLiveActivity()
                }
            } else if #available(iOS 16.2, *) {
                endLiveActivity(status: "expired", detail: nil)
            }
        case "notifications":
            UserDefaults.standard.set(value, forKey: Self.notificationsKey)
            // Authorization is requested only when the user turns this on,
            // never at launch.
            if value { requestNotificationAuthorization() }
        case "privacyMode":
            UserDefaults.standard.set(value, forKey: Self.privacyKey)
            // Apply the new privacy level to a showing Live Activity at once.
            if liveActivity != nil, #available(iOS 16.2, *) {
                updateLiveActivity(status: liveActivityStatus, detail: nil)
            }
        case "backgroundSpeak":
            UserDefaults.standard.set(value, forKey: Self.speakKey)
        default:
            NSLog("[ShellBox] unknown background preference key: \(key)")
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { NSLog("[ShellBox] notification authorization error: \(error)") }
            NSLog("[ShellBox] notification authorization granted=\(granted)")
        }
    }

    // MARK: - Task outcome (completion hook)

    /// Called by the runtime when a background task finishes. Ends the Live
    /// Activity; while the app is in the background it also posts the
    /// notification and reads the reply aloud (both honour the toggles and
    /// privacy mode). In the foreground the user can see the result, so
    /// nothing is posted or spoken.
    private func notifyTaskOutcome(_ args: [String: Any]) {
        let outcome = args["outcome"] as? String ?? "completed"
        let title = args["title"] as? String
        let summary = args["summary"] as? String
        let sessionId = args["sessionId"] as? String ?? ""
        if #available(iOS 16.2, *) { endLiveActivity(status: outcome, detail: summary) }
        guard UIApplication.shared.applicationState != .active else { return }
        postTaskNotification(title: title, summary: summary, outcome: outcome, sessionId: sessionId)
        speakTaskOutcome(title: title, summary: summary, outcome: outcome)
    }

    // MARK: - Live Activity (DSH agent task)

    @available(iOS 16.2, *)
    private func startLiveActivity() {
        guard liveActivityEnabled else { return }
        guard liveActivity == nil else { return }
        guard let info = activeTaskInfo else { return }
        // Adopt an activity that is already running instead of requesting a
        // second one (e.g. after the toggle was flipped off and on again).
        if let existing = Activity<DSHActivityAttributes>.activities.first {
            liveActivity = existing
            liveActivityStatus = "running"
            return
        }
        let attrs = DSHActivityAttributes(startedAt: taskStartedAt ?? Date())
        liveActivityStatus = "running"
        let state = DSHActivityAttributes.ContentState(
            title: displayTitle(for: info.title),
            status: liveActivityStatus,
            detail: displayDetail(for: nil))
        do {
            let activity = try Activity<DSHActivityAttributes>.request(
                attributes: attrs,
                content: ActivityContent(state: state, staleDate: nil))
            liveActivity = activity
            NSLog("[ShellBox] Live Activity started")
        } catch {
            NSLog("[ShellBox] Live Activity start failed: \(error)")
        }
    }

    @available(iOS 16.2, *)
    private func updateLiveActivity(status: String, detail: String?) {
        guard let activity = liveActivity as? Activity<DSHActivityAttributes> else { return }
        liveActivityStatus = status
        let title = displayTitle(for: activeTaskInfo?.title ?? "DSH agent")
        let state = DSHActivityAttributes.ContentState(
            title: title, status: status, detail: displayDetail(for: detail))
        Task { @MainActor in
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    @available(iOS 16.2, *)
    private func endLiveActivity(status: String, detail: String?) {
        guard let activity = liveActivity as? Activity<DSHActivityAttributes> else { return }
        liveActivity = nil
        liveActivityStatus = status
        let title = displayTitle(for: activeTaskInfo?.title ?? "DSH agent")
        let state = DSHActivityAttributes.ContentState(
            title: title, status: status, detail: displayDetail(for: detail))
        Task { @MainActor in
            await activity.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .immediate)
        }
    }

    @available(iOS 16.2, *)
    private func cleanupStaleLiveActivities() {
        // From a previous process: no task behind them any more.
        for activity in Activity<DSHActivityAttributes>.activities {
            Task { @MainActor in
                let state = DSHActivityAttributes.ContentState(
                    title: "DSH agent", status: "expired", detail: nil)
                await activity.end(ActivityContent(state: state, staleDate: nil),
                                   dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Task notifications

    private func postTaskNotification(title: String?, summary: String?, outcome: String, sessionId: String) {
        guard notificationsEnabled else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized else {
                NSLog("[ShellBox] notifications not authorized; skipping task notification")
                return
            }
            self?.deliverTaskNotification(title: title, summary: summary,
                                          outcome: outcome, sessionId: sessionId, center: center)
        }
    }

    private func deliverTaskNotification(title: String?, summary: String?, outcome: String,
                                         sessionId: String, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        if privacyMode {
            // Generic only: never the task title or the reply summary.
            switch outcome {
            case "failed": content.title = isChinese ? "❌ 任务失败" : "❌ Task failed"
            case "expired": content.title = isChinese ? "⏸ 后台运行已结束" : "⏸ Background run ended"
            default: content.title = isChinese ? "✅ 任务已完成" : "✅ Task completed"
            }
            content.body = privacyNotificationBody(outcome: outcome)
        } else {
            let mark: String
            switch outcome {
            case "failed": mark = "❌"
            case "expired": mark = "⏸"
            default: mark = "✅"
            }
            let shownTitle = (title?.isEmpty == false) ? title! : "DSH agent"
            content.title = "\(mark) \(shownTitle)"
            content.body = (summary?.isEmpty == false) ? summary! : genericSpokenText(outcome: outcome)
        }
        content.sound = .default
        content.categoryIdentifier = "dsh.background.task"
        if !sessionId.isEmpty { content.userInfo = ["sessionId": sessionId] }
        // One notification per session: a later outcome replaces the earlier one.
        let identifier = sessionId.isEmpty
            ? "dsh.background.task.\(UUID().uuidString)"
            : "dsh.background.task.\(sessionId)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error { NSLog("[ShellBox] notification post failed: \(error)") }
        }
    }

    private func privacyNotificationBody(outcome: String) -> String {
        let base: String
        switch outcome {
        case "failed": base = isChinese ? "1 个任务失败" : "1 task failed"
        case "expired": base = isChinese ? "1 个后台任务已结束" : "1 background task ended"
        default: base = isChinese ? "1 个任务已完成" : "1 task completed"
        }
        guard let startedAt = taskStartedAt else { return base }
        let elapsed = Int(Date().timeIntervalSince(startedAt).rounded())
        guard elapsed > 0 else { return base }
        let formatted: String
        if elapsed >= 3600 {
            formatted = String(format: "%dh %dm", elapsed / 3600, (elapsed % 3600) / 60)
        } else if elapsed >= 60 {
            formatted = String(format: "%dm %ds", elapsed / 60, elapsed % 60)
        } else {
            formatted = String(format: "%ds", elapsed)
        }
        return "\(base) · \(formatted)"
    }

    // MARK: - Background reading (text-to-speech)

    private func speakTaskOutcome(title: String?, summary: String?, outcome: String) {
        guard backgroundSpeak else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        let text: String
        if privacyMode {
            // Spoken words can be overheard: generic message only.
            text = genericSpokenText(outcome: outcome)
        } else if let summary, !summary.isEmpty {
            text = summary
        } else if let title, !title.isEmpty {
            text = title
        } else {
            text = genericSpokenText(outcome: outcome)
        }
        let utterance = AVSpeechUtterance(string: text)
        // Voice matching the device language; nil falls back to the system
        // default voice.
        if let code = Locale.current.languageCode,
           let voice = AVSpeechSynthesisVoice(language: code) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    private func genericSpokenText(outcome: String) -> String {
        switch outcome {
        case "failed": return isChinese ? "任务失败" : "Task failed"
        case "expired": return isChinese ? "后台运行已结束" : "Background run ended"
        default: return isChinese ? "任务已完成" : "Task completed"
        }
    }

    // MARK: - Display helpers (privacy)

    private var isChinese: Bool { Locale.current.languageCode == "zh" }

    /// Title shown in the Live Activity. Privacy mode hides the real title.
    private func displayTitle(for title: String) -> String {
        privacyMode ? "DSH agent" : title
    }

    /// Detail shown in the Live Activity. Privacy mode hides it entirely.
    private func displayDetail(for detail: String?) -> String? {
        guard !privacyMode else { return nil }
        guard let detail, !detail.isEmpty else { return nil }
        return detail
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
        // Show the Live Activity while the task runs in the background.
        if enabled, liveActivityEnabled, activeTaskInfo != nil, #available(iOS 16.2, *) {
            startLiveActivity()
        }
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
