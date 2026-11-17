import Flutter
import UIKit

// BrowserUsePlugin.swift — dsh-go browser_use: MethodChannel `dsh/browser`.
//
// The Dart side of the agent browser (the agent's main path is the Node
// engine -> BrowserLoopbackService, not this channel; this channel serves
// the visible browser UI page and debugging).
//
// Methods:
//   - `execute {input}` -> result dict {text, success, base64Image?,
//     imageFilePath?, pageURL?, tabId?}. `input` is the action JSON string
//     (same fields as Minis BrowserActionInput.parse).
//   - `status` -> {tabs: [{id, url, title, isLoading}], activeTabId, maxTabs}
//   - `openBrowser` -> ensures a tab exists, returns status (Dart navigates
//     to the browser page itself).
//
// Swift -> Dart push: `browserStateChanged` with the status dict, sent after
// every execute so the browser page refreshes without polling.
//
// The pool is shared with BrowserLoopbackService (one set of tabs no matter
// which side drives them): both use `BrowserUsePlugin.sharedPool`.

public final class BrowserUsePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dsh/browser", binaryMessenger: registrar.messenger())
        let instance = BrowserUsePlugin(channel: channel)
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
        // Start the loopback service so the Node engine can reach the same
        // pool (the agent's main path). Failures are non-fatal: the Dart
        // channel still works, the agent path just reports unavailable.
        BrowserLoopbackService.shared.start()
    }

    /// The single tab pool for the app: the MethodChannel and the loopback
    /// service share it, so Dart and the agent see the same tabs.
    /// @MainActor: BrowserTabPool.init is main-actor-isolated, so the
    /// shared instance must be too; all users already hop to @MainActor.
    @MainActor static let sharedPool = BrowserTabPool()

    private let channel: FlutterMethodChannel

    private init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "execute":
            execute(call, result: result)
        case "status":
            Task { @MainActor in
                result(Self.statusDict())
            }
        case "openBrowser":
            Task { @MainActor in
                Self.sharedPool.ensureTabForUI()
                result(Self.statusDict())
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func execute(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        guard let inputJSON = args?["input"] as? String,
              let input = BrowserActionInput.parse(from: inputJSON) else {
            result(FlutterError(code: "invalid_input", message: "execute needs {input: <action JSON string>}", details: nil))
            return
        }
        Task { @MainActor in
            do {
                let actionResult = try await Self.sharedPool.execute(input: input)
                self.pushStateChanged()
                result(actionResult.toDict())
            } catch {
                self.pushStateChanged()
                result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
            }
        }
    }

    /// Current pool status for Dart / the browser page.
    /// @MainActor: reads the @MainActor pool (tabs, selectedTabId, maxTabs);
    /// all callers already run on the main actor (channel handler hops via
    /// Task, loopback service hops via Task).
    @MainActor static func statusDict() -> [String: Any] {
        let pool = sharedPool
        var tabs: [[String: Any]] = []
        for tab in pool.tabs {
            tabs.append([
                "id": tab.id,
                "url": tab.url,
                "title": tab.title,
                "isLoading": tab.isLoading,
            ])
        }
        var dict: [String: Any] = ["tabs": tabs, "maxTabs": BrowserTabPool.maxTabs]
        if let active = pool.selectedTabId { dict["activeTabId"] = active }
        return dict
    }

    /// Tell Dart the browser state changed (after every execute).
    /// @MainActor: reads the pool via statusDict; callers run in @MainActor Tasks.
    @MainActor private func pushStateChanged() {
        channel.invokeMethod("browserStateChanged", arguments: Self.statusDict())
    }
}
