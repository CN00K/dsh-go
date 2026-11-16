import Foundation
import WebKit
import UIKit

// BrowserUseManager.swift — dsh-go browser_use: one manager per tab.
//
// Adapted from OpenMinis src/ios/Agent/BrowserUse/BrowserUseManager.swift
// (3070 lines). dsh-go keeps the action semantics, screenshot path and
// timeout ladder; dropped vs Minis:
//   - CookieBackupStore (login-cookie backup/restore; ITP + background sync)
//   - Downloads (WKDownload center)
//   - Print bridge (window.print -> UIPrintInteractionController)
//   - JS dialog interception (alert/confirm/prompt auto-answer)
//   - `minis://` URL scheme handler (dsh-go has no minis://)
//   - Full DOM-change summary after visual actions (v1: short settle wait +
//     UI preview snapshot only; the MutationObserver summary is a TODO)
// Screenshots go to Documents/DSH-Go/browser-screenshots/ (visible in the
// Files app, same DSH-Go folder FilesPlugin uses) instead of Minis's tmp dir.

@MainActor
final class BrowserUseManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var currentURL: String = ""
    @Published var pageTitle: String = ""
    @Published var isLoading: Bool = false
    @Published var lastScreenshot: UIImage?

    // MARK: - Internal

    private(set) var webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    @Published private(set) var currentProfile: UserAgentProfile = .mobileSafari

    /// Called when a page requests a new window (target="_blank" / window.open).
    /// The pool creates a new tab using the provided configuration to share the session.
    var newWindowHandler: ((_ configuration: WKWebViewConfiguration, _ url: URL?) -> WKWebView?)?

    /// Called when a child window calls window.close() — the pool should close this tab.
    var closeHandler: ((_ webView: WKWebView) -> Void)?

    private static let navigationTimeout: TimeInterval = 30

    /// Wall-clock bound on a single `execute_js`. Deliberately BELOW the
    /// pool's serial-wait timeout (60s): the timeout ladder must be
    /// innermost-shortest, so a wedged script releases the tab's serial slot
    /// *before* the next caller's wait expires.
    private static let executeJSTimeout: TimeInterval = 45

    /// Bound on the shared read-action JS helper (get_page_info and friends).
    /// These are fixed, self-contained, synchronous scripts that take
    /// milliseconds on a healthy page — the only way one runs long is a JS
    /// main thread pinned by someone else, and in that case failing fast with
    /// a clear message beats blocking the caller.
    private static let readActionTimeout: TimeInterval = 10

    /// Shared process pool so all tabs share cookies/sessions (needed for OAuth flows).
    static let sharedProcessPool = WKProcessPool()

    /// Directory for saving browser screenshots (Documents, visible in Files app).
    static let screenshotsDir: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSH-Go/browser-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Max captured page height in CSS pixels — guards against runaway memory
    /// allocation for infinite-scroll or pathologically tall pages. 32768 px ×
    /// 1280 px wide × 4 bytes (ARGB) ≈ 160 MB raw bitmap; JPEG-80 keeps the
    /// output file much smaller, but the in-memory snapshot is the limit.
    private static let fullPageMaxHeight: CGFloat = 32_768

    // MARK: - Init

    /// Current effective viewport. Defaults track the UA profile; the pool
    /// rebuilds the webView via `setViewport(...)` when a custom size is set.
    private(set) var currentViewport: (width: Int, height: Int) = (390, 844)

    init(profile: UserAgentProfile = .mobileSafari, customString: String? = nil,
         viewportWidth: Int? = nil, viewportHeight: Int? = nil) {
        self.currentProfile = profile
        let vp = Self.resolveViewport(profile: profile, width: viewportWidth, height: viewportHeight)
        self.currentViewport = vp
        self.webView = Self.makeWebView(profile: profile, customString: customString,
                                        viewportWidth: vp.width, viewportHeight: vp.height)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// The user-agent string this tab's page requests are sent with. Lets the
    /// pool rebuild the tab at another viewport without changing its UA.
    var effectiveUserAgent: String? { webView.customUserAgent }

    /// Init with a pre-built configuration (used for window.open popups that share the opener's session).
    init(profile: UserAgentProfile, customString: String?, configuration: WKWebViewConfiguration,
         viewportWidth: Int? = nil, viewportHeight: Int? = nil) {
        self.currentProfile = profile
        let vp = Self.resolveViewport(profile: profile, width: viewportWidth, height: viewportHeight)
        self.currentViewport = vp
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: vp.width, height: vp.height), configuration: configuration)
        wv.customUserAgent = Self.resolveUA(profile: profile, customString: customString)
        wv.allowsBackForwardNavigationGestures = true
        self.webView = wv
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    private static func resolveViewport(profile: UserAgentProfile,
                                        width: Int?, height: Int?) -> (width: Int, height: Int) {
        if let w = width, let h = height, w > 0, h > 0 {
            return (w, h)
        }
        return profile.viewportSize
    }

    // MARK: - WebView Factory

    /// Resolve the effective UA string. For `.custom` with an empty custom string,
    /// fall back to mobile Safari so WebKit never reverts to its default UA.
    private static func resolveUA(profile: UserAgentProfile, customString: String?) -> String {
        if let custom = customString, !custom.isEmpty {
            return custom
        }
        return profile.userAgentString ?? UserAgentProfile.mobileSafari.userAgentString!
    }

    private static func makeWebView(profile: UserAgentProfile,
                                    customString: String? = nil,
                                    viewportWidth: Int? = nil,
                                    viewportHeight: Int? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = sharedProcessPool
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let vp = resolveViewport(profile: profile, width: viewportWidth, height: viewportHeight)

        // Force a fixed CSS viewport width when the profile is desktop or the
        // caller supplied a custom viewport (so pages lay out at the requested
        // width instead of the container-derived size).
        let hasCustom = (viewportWidth ?? 0) > 0 && (viewportHeight ?? 0) > 0
        let wantsDesktop = (profile == .desktopSafari) || (hasCustom && vp.width >= 1024)
        if profile == .desktopSafari || hasCustom {
            config.userContentController.addUserScript(desktopViewportScript(width: vp.width))
        }
        // preferredContentMode is what WebKit actually uses to decide
        // mobile-vs-desktop layout (UA string + viewport meta-injection alone
        // are not enough — many sites still negotiate by content mode).
        config.defaultWebpagePreferences.preferredContentMode = wantsDesktop ? .desktop : .mobile

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: vp.width, height: vp.height), configuration: config)
        webView.customUserAgent = resolveUA(profile: profile, customString: customString)
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    /// Force a desktop-width viewport by replacing any `<meta name="viewport">` tag
    /// with a fixed-width one. Injected at document start so the page's layout engine
    /// reads the desktop width before first paint.
    private static func desktopViewportScript(width: Int) -> WKUserScript {
        let js = """
        (function() {
            var w = \(width);
            function apply() {
                var metas = document.querySelectorAll('meta[name="viewport"]');
                metas.forEach(function(m) { m.parentNode.removeChild(m); });
                var m = document.createElement('meta');
                m.name = 'viewport';
                m.content = 'width=' + w + ', initial-scale=1.0, user-scalable=yes';
                (document.head || document.documentElement).appendChild(m);
            }
            apply();
            document.addEventListener('DOMContentLoaded', apply);
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: - Execute Action

    /// Actions that visually change the page — after these we wait briefly for
    /// the DOM to settle and take a snapshot for UI preview.
    private static let visualChangeActions: Set<BrowserAction> = [
        .navigate, .click, .scroll, .scrollAndCollect, .hover, .type
    ]

    func execute(action input: BrowserActionInput) async throws -> BrowserActionResult {
        var result: BrowserActionResult
        switch input.action {
        case .navigate:
            result = try await navigate(to: input.url)
        case .screenshot:
            return try await screenshot(fullPage: input.fullPage ?? false)
        case .click:
            result = try await click(selector: input.selector, x: input.coordinateX, y: input.coordinateY)
        case .type:
            result = try await type(selector: input.selector, text: input.text)
        case .getText:
            return try await getText(selector: input.selector)
        case .scroll:
            result = try await scroll(selector: input.selector, direction: input.direction, amount: input.amount)
        case .scrollAndCollect:
            result = try await scrollAndCollect(selector: input.selector, direction: input.direction, amount: input.amount, scrollCount: input.scrollCount, itemSelector: input.itemSelector)
        case .getPageInfo:
            return try await getPageInfo()
        case .executeJS:
            return try await executeJS(script: input.script)
        case .findElements:
            return try await findElements(selector: input.selector)
        case .hover:
            result = try await hover(selector: input.selector)
        case .getReadable:
            return try await getReadable()
        case .setUserAgent:
            guard let profile = input.userAgent else {
                return .error(UserAgentProfile.invalidArgumentMessage(raw: input.userAgentRaw))
            }
            return setUserAgent(profile: profile)
        case .setViewport:
            // Routed by BrowserTabPool.execute — pool rebuilds the tab; this
            // path only hits if execute is called directly on a detached manager.
            return .error("set_viewport must be routed through BrowserTabPool")
        case .getBackbone:
            return try await getBackbone(maxDepth: input.maxDepth)
        case .fetch:
            return try await fetch(url: input.url)
        case .newTab, .closeTab, .listTabs:
            return .error("Tab management actions must be routed through BrowserTabPool")
        case .getCookies:
            return await getCookies(keywords: input.keywords, fuzzy: input.fuzzy ?? true)
        case .setCookies:
            return await setCookies(input.cookies)
        case .waitForDomStable:
            return try await waitForDomStable(timeout: input.timeout)
        }

        // After visual-change actions: brief settle wait, then a snapshot for
        // UI preview (file only, not sent to the model). The DOM-change
        // summary of Minis is a TODO (see VERIFY.md).
        if result.success, Self.visualChangeActions.contains(input.action) {
            result = await settleAndSnapshot(result: result)
        }
        return result
    }

    /// v1 settle: wait 800ms for the page to react, then snapshot for UI
    /// preview (imageFilePath only, no base64Image). Detects a URL change and
    /// tells the model to screenshot before continuing.
    private func settleAndSnapshot(result: BrowserActionResult) async -> BrowserActionResult {
        let prevURL = webView.url
        try? await Task.sleep(nanoseconds: 800_000_000)
        var snapshotPath: String? = nil
        do {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: CGSize(width: CGFloat(currentViewport.width), height: CGFloat(currentViewport.height)))
            let image = try await webView.takeSnapshot(configuration: config)
            lastScreenshot = image
            if let jpegData = image.jpegData(compressionQuality: 0.7) {
                let filename = "snapshot_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
                let fileURL = Self.screenshotsDir.appendingPathComponent(filename)
                try jpegData.write(to: fileURL)
                snapshotPath = fileURL.path
            }
        } catch {
            // Preview snapshot is best-effort; the action result stands.
        }
        var text = result.text
        if let prev = prevURL, let cur = webView.url {
            let prevNoHash = prev.absoluteString.components(separatedBy: "#").first ?? prev.absoluteString
            let curNoHash = cur.absoluteString.components(separatedBy: "#").first ?? cur.absoluteString
            if prevNoHash != curNoHash {
                text += "\n[URL Changed] Page navigated: \(prev.absoluteString) -> \(cur.absoluteString). Take a screenshot to see the current state before continuing."
            }
        }
        return BrowserActionResult(
            text: text,
            success: result.success,
            base64Image: result.base64Image,
            imageFilePath: snapshotPath ?? result.imageFilePath,
            pageURL: result.pageURL,
            tabId: result.tabId
        )
    }

    // MARK: - Bounded JS evaluation

    /// Evaluate a script with a wall-clock bound. Uses a GCD timer, not
    /// Task.sleep: a Task timer is stretched several-fold by background CPU
    /// throttling, which would let the bound overrun the pool's serial wait.
    private func evaluateJavaScriptBounded(_ js: String, timeout: TimeInterval = 10) async throws -> Any? {
        try await withThrowingTaskGroup(of: Any?.self) { group in
            group.addTask {
                try await self.webView.evaluateJavaScript(js)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BrowserJSTimeout()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func callAsyncJavaScriptBounded(_ js: String, timeout: TimeInterval) async throws -> Any? {
        try await withThrowingTaskGroup(of: Any?.self) { group in
            group.addTask {
                try await self.webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BrowserJSTimeout()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private struct BrowserJSTimeout: Error {}

    /// Parse a JS IIFE result that is a JSON string into a dict; returns nil
    /// when the script returned something else (caller falls back to raw text).
    private static func parseJSONResult(_ value: Any?) -> [String: Any]? {
        guard let str = value as? String,
              let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func navigationMetadata() async -> String {
        let js = """
        JSON.stringify({
            url: location.href,
            title: document.title,
            readyState: document.readyState
        })
        """
        guard let str = try? await evaluateJavaScriptBounded(js, timeout: Self.readActionTimeout) as? String,
              let data = str.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Loaded \(currentURL)"
        }
        var lines: [String] = []
        if let url = info["url"] as? String { lines.append("URL: \(url)") }
        if let title = info["title"] as? String, !title.isEmpty { lines.append("Title: \(title)") }
        if let rs = info["readyState"] as? String { lines.append("Ready state: \(rs)") }
        return lines.isEmpty ? "Loaded \(currentURL)" : lines.joined(separator: "\n")
    }

    // MARK: - Navigate

    private func navigate(to urlString: String?) async throws -> BrowserActionResult {
        guard let urlString, !urlString.isEmpty else {
            return .error("Missing 'url' parameter")
        }

        // Support bare domains like "google.com" → "https://google.com"
        var normalized = urlString
        if !normalized.contains("://") {
            normalized = "https://\(normalized)"
        }

        guard let url = URL(string: normalized) else {
            return .error("Invalid URL: \(urlString)")
        }

        // Only allow HTTP(S) for direct navigation (dsh-go has no minis://).
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https"].contains(scheme) {
            return .error("Cannot navigate to \(scheme):// URLs. Only http:// and https:// are supported.")
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.navigationTimeout)
        webView.load(request)
        isLoading = true

        // Track whether we left the wait via the delegate or via the timeout,
        // so the RESULT can say so. A frozen renderer previously reported
        // `ok: true` while the DOM never updated.
        var timedOut = false

        // GCD wall-clock timer, not Task.sleep (background CPU throttling
        // stretches Task timers several-fold).
        let navTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        navTimer.schedule(deadline: .now() + Self.navigationTimeout)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.navigationContinuation = continuation
            navTimer.setEventHandler {
                Task { @MainActor in
                    if let cont = self.navigationContinuation {
                        self.navigationContinuation = nil
                        self.isLoading = false
                        timedOut = true
                        cont.resume()  // Don't fail on timeout, page may be partially loaded
                    }
                }
            }
            navTimer.resume()
        }
        navTimer.cancel()

        currentURL = webView.url?.absoluteString ?? normalized
        pageTitle = webView.title ?? ""
        isLoading = false

        let meta = await navigationMetadata()
        if timedOut {
            return BrowserActionResult(text: "Navigation did not complete within \(Int(Self.navigationTimeout))s — the page may be partially loaded or the renderer may be stalled. Content below reflects the current (possibly stale) state.\n\n\(meta)")
        }
        return BrowserActionResult(text: meta)
    }

    // MARK: - Screenshot

    /// The JPEG the screenshot action returns and writes.
    nonisolated static func screenshotJPEGData(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: 0.8)
    }

    private func screenshot(fullPage: Bool = false) async throws -> BrowserActionResult {
        // If the webView's current bounds don't match the intended viewport
        // (e.g. the browser page stretched the WKWebView to fill its frame),
        // takeSnapshot only captures that cropped region. Re-apply the
        // configured viewport for the duration of the snapshot, then restore.
        let viewportSize = CGSize(width: CGFloat(currentViewport.width),
                                  height: CGFloat(currentViewport.height))
        let savedFrame = webView.frame

        // Resolve target capture height: viewport height (default) or
        // scrollHeight (full_page). Width is always the viewport width.
        var originalPageHeight: CGFloat = 0
        var truncated = false
        var captureHeight = viewportSize.height
        if fullPage {
            if let h = try? await webView.evaluateJavaScript(
                "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"
            ) as? NSNumber, h.doubleValue > 0 {
                originalPageHeight = CGFloat(h.doubleValue)
                captureHeight = max(viewportSize.height, originalPageHeight)
                if captureHeight > Self.fullPageMaxHeight {
                    captureHeight = Self.fullPageMaxHeight
                    truncated = true
                }
            }
        }

        let targetSize = CGSize(width: viewportSize.width, height: captureHeight)
        let shouldResize = abs(savedFrame.size.width - targetSize.width) > 0.5 ||
                           abs(savedFrame.size.height - targetSize.height) > 0.5
        if shouldResize {
            webView.frame = CGRect(origin: savedFrame.origin, size: targetSize)
            webView.setNeedsLayout()
            webView.layoutIfNeeded()
            // Let the page re-flow at the new visual viewport before snapshotting.
            try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
        }
        defer {
            if shouldResize {
                restoreViewportFrame()
            }
        }

        // For full_page, force any `loading="lazy"` images to load eagerly and
        // wait two RAFs so IntersectionObserver-driven decoders kick in before
        // the snapshot. Best-effort; ignore failures.
        if fullPage {
            let lazyEager = """
            (async () => {
              const imgs = document.querySelectorAll('img[loading="lazy"]');
              imgs.forEach(i => { i.loading = 'eager'; });
              await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
              return imgs.length;
            })()
            """
            _ = try? await webView.evaluateJavaScript(lazyEager)
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: targetSize)
        let image = try await webView.takeSnapshot(configuration: config)
        lastScreenshot = image

        guard let jpegData = Self.screenshotJPEGData(image) else {
            return .error("Failed to encode screenshot as JPEG")
        }

        // Save to disk (Documents/DSH-Go/browser-screenshots/, visible in Files app).
        let filename = "screenshot_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        let fileURL = Self.screenshotsDir.appendingPathComponent(filename)
        try jpegData.write(to: fileURL)

        let base64 = jpegData.base64EncodedString()
        let size = image.size
        let meta = await viewportMetadata(
            imageSize: size,
            fileSize: jpegData.count,
            fullPage: fullPage,
            truncated: truncated,
            originalHeight: Int(originalPageHeight)
        )

        return BrowserActionResult(
            text: meta,
            base64Image: base64,
            imageFilePath: fileURL.path
        )
    }

    /// Collect viewport and page metadata for screenshot results.
    private func viewportMetadata(
        imageSize: CGSize,
        fileSize: Int,
        fullPage: Bool = false,
        truncated: Bool = false,
        originalHeight: Int = 0
    ) async -> String {
        let vp = currentViewport
        let url = webView.url?.absoluteString ?? currentURL
        let title = webView.title ?? pageTitle

        var scrollX = 0, scrollY = 0, pageW = 0, pageH = 0
        if let js = try? await webView.evaluateJavaScript(
            "JSON.stringify({sx:window.scrollX,sy:window.scrollY,pw:document.documentElement.scrollWidth,ph:document.documentElement.scrollHeight})"
        ) as? String,
           let data = js.data(using: .utf8),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            scrollX = info["sx"] as? Int ?? 0
            scrollY = info["sy"] as? Int ?? 0
            pageW = info["pw"] as? Int ?? 0
            pageH = info["ph"] as? Int ?? 0
        }

        var lines: [String] = []
        lines.append("Screenshot captured")
        lines.append("  URL: \(url)")
        if !title.isEmpty { lines.append("  Title: \(title)") }
        lines.append("  Image: \(Int(imageSize.width))x\(Int(imageSize.height)) (\(fileSize / 1024)KB)")
        lines.append("  Viewport: \(vp.width)x\(vp.height)")
        if pageW > 0 || pageH > 0 {
            lines.append("  Page size: \(pageW)x\(pageH)")
        }
        lines.append("  Scroll position: (\(scrollX), \(scrollY))")
        if fullPage {
            lines.append("  Full page: true")
            if truncated && originalHeight > 0 {
                lines.append("  Truncated: true (original height \(originalHeight)px capped at \(Int(Self.fullPageMaxHeight))px)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Click

    private func click(selector: String?, x: Int?, y: Int?) async throws -> BrowserActionResult {
        let js: String
        if let selector, !selector.isEmpty {
            js = BrowserUseJS.click(selector: selector)
        } else if let x, let y {
            js = BrowserUseJS.clickCoordinate(x: x, y: y)
        } else {
            return .error("click needs a selector or coordinate_x/coordinate_y")
        }
        guard let value = try? await evaluateJavaScriptBounded(js, timeout: Self.readActionTimeout),
              let info = Self.parseJSONResult(value) else {
            return .error("click: no result from page")
        }
        if let err = info["error"] as? String { return .error(err) }
        let tag = info["tag"] as? String ?? ""
        let text = info["text"] as? String ?? ""
        return BrowserActionResult(text: "Clicked <\(tag)> \(text)")
    }

    // MARK: - Type

    private func type(selector: String?, text: String?) async throws -> BrowserActionResult {
        guard let selector, !selector.isEmpty else { return .error("type needs a selector") }
        guard let text else { return .error("type needs text") }
        let js = BrowserUseJS.type(selector: selector, text: text)
        guard let value = try? await evaluateJavaScriptBounded(js, timeout: Self.readActionTimeout),
              let info = Self.parseJSONResult(value) else {
            return .error("type: no result from page")
        }
        if let err = info["error"] as? String { return .error(err) }
        return BrowserActionResult(text: "Typed \(text.count) characters into \(selector)")
    }

    // MARK: - Get Text

    private func getText(selector: String?) async throws -> BrowserActionResult {
        let js = BrowserUseJS.getText(selector: selector)
        guard let value = try? await evaluateJavaScriptBounded(js, timeout: Self.readActionTimeout),
              let info = Self.parseJSONResult(value) else {
            return .error("get_text: no result from page")
        }
        if let err = info["error"] as? String { return .error(err) }
        let text = info["text"] as? String ?? ""
        let length = info["length"] as? Int ?? text.count
        return BrowserActionResult(text: text.isEmpty ? "(no text)" : text + "\n[\(length) chars]")
    }

    // MARK: - Get Readable

    private func getReadable() async throws -> BrowserActionResult {
        let js = BrowserUseJS.getReadable()
        guard let value = try? await evaluateJavaScriptBounded(js, timeout: Self.readActionTimeout),
              let info = Self.parseJSONResult(value) else {
            return .error("get_readable: no result from page")
        }
        if let err = info["error"] as? String { return .error(err) }
        let title = info["title"] as? String ?? ""
        let text = info["text"] as? String ?? ""
        var out = ""
        if !title.isEmpty { out += "Title: \(title)\n\n" }
        out += text
        return BrowserActionResult(text: out.isEmpty ? "(no readable content)" : out)
    }

    // MARK: - Scroll

    private func scroll(selector: String?, direction: BrowserActionInput.ScrollDirection?, amount: Int?) async throws -> BrowserActionResult {
        let dir = direction ?? .down
        let px = amount ?? 500
        let js = BrowserUseJS.scroll(direction: dir, amount: px, selector: selector)
        guard let value = try? await callAsyncJavaScriptBounded(js, timeout: Self.readActionTimeout),
              let info = Self.parseJSONResult(value) else {
            return .error("scroll: no result from page")
        }
        if let err = info["error"] as? String { return .error(err) }
        let element = info["element"] as? String ?? "window"
        let scrollY = info["scrollY"] as? Int ?? info["scrollTop"] as? Int ?? 0
        return BrowserActionResult(text: "Scrolled \(dir.rawValue) \(px)px in \(element) (now at \(scrollY))")
    }

    // MARK: - Scroll And Collect

    private func scrollAndCollect(selector: String?, direction: BrowserActionInput.ScrollDirection?, amount: Int?, scrollCount: Int?, itemSelector: String?) async throws -> BrowserActionResult {
        let dir = direction ?? .down
        let px = amount ?? 500
        let count = scrollCount ?? 5
        let js = BrowserUseJS.scrollAndCollect(direction: dir, amount: px, scrollCount: count, selector: selector, itemSelector: itemSelector)
        guard let value = try? await callAsyncJavaScriptBounded(js, timeout: 60),
              let info = Self.parseJSONResult(value) else {
            return .error("scroll_and_collect: no result from page")
        }
        if let err = info["error"] as? String { return .error(err) }
        let items = info["items"] as? [String] ?? []
        let collected = info["itemsCollected"] as? Int ?? items.count
        let steps = info["scrollSteps"] as? Int ?? 0
        var out = "Collected \(collected) items in \(steps) scroll steps"
        if !items.isEmpty {
            out += ":\n" + items.joined(separator: "\n---\n")
        }
        return BrowserActionResult(text: out)
    }

    // MARK: - Get Page Info

    private func getPageInfo() async throws -> BrowserActionResult {
        let js = BrowserUseJS.getPageInfo()
        guard let value = try? await evaluateJavaScriptBounded(js, timeout: Self.readActionTimeout),
              let info = Self.parseJSONResult(value) else {
            return .error("get_page_info: no result from page")
        }
        if let err = info["error"] as? String { return .error(err) }
        var lines: [String] = []
        if let url = info["url"] as? String { lines.append("URL: \(url)") }
        if let title = info["title"] as? String, !title.isEmpty { lines.append("Title: \(title)") }
        if let rs = info["readyState"] as? String { lines.append("Ready state: \(rs)") }
        if let sy = info["scrollY"] as? Int, let sh = info["scrollHeight"] as? Int {
            lines.append("Scroll: y=\(sy) height=\(sh)")
        }
        if let vw = info["viewportWidth"] as? Int, let vh = info["viewportHeight"] as? Int {
            lines.append("Viewport: \(vw)x\(vh)")
        }
        if let forms = info["forms"] as? Int { lines.append("Forms: \(forms)") }
        if let links = info["links"] as? Int { lines.append("Links: \(links)") }
        if let images = info["images"] as? Int { lines.append("Images: \(images)") }
        return BrowserActionResult(text: lines.isEmpty ? "(no page info)" : lines.joined(separator: "\n"))
    }

    // MARK: - Execute JS

    private func executeJS(script: String?) async throws -> BrowserActionResult {
        guard let script, !script.isEmpty else { return .error("execute_js needs a script") }
        // The script runs inside an async function wrapper — await and
        // top-level return are both supported.
        let wrapped = "(async () => { \(script) })()"
        do {
            let value = try await callAsyncJavaScriptBounded(wrapped, timeout: Self.executeJSTimeout)
            if value == nil { return BrowserActionResult(text: "Script ran (no return value)") }
            if let str = value as? String { return BrowserActionResult(text: str) }
            if let data = try? JSONSerialization.data(withJSONObject: value as Any, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return BrowserActionResult(text: str)
            }
            return BrowserActionResult(text: "\(value!)")
        } catch {
            return .error(BrowserJSErrorFormatter.message(error))
        }
    }

    // MARK: - Wait for DOM Stable

    private func waitForDomStable(timeout: Int?) async throws -> BrowserActionResult {
        let timeoutSeconds = Double(timeout ?? 10_000) / 1000.0
        let setupJS = """
        window.__dshDomStable = { mutations: 0 };
        window.__dshDomObserver = new MutationObserver(function(muts) {
            window.__dshDomStable.mutations += muts.length;
        });
        window.__dshDomObserver.observe(document.documentElement, {
            childList: true, subtree: true, attributes: true, characterData: true
        });
        return 'ok';
        """
        _ = try? await webView.callAsyncJavaScript(setupJS, arguments: [:], contentWorld: .page)
        let pollNs: UInt64 = 500_000_000
        var lastTotal = 0
        var stableRuns = 0
        let start = CFAbsoluteTimeGetCurrent()
        while true {
            try? await Task.sleep(nanoseconds: pollNs)
            if CFAbsoluteTimeGetCurrent() - start >= timeoutSeconds { break }
            let countResult = try? await webView.callAsyncJavaScript(
                "return window.__dshDomStable ? window.__dshDomStable.mutations : 0;",
                arguments: [:], contentWorld: .page
            )
            let total: Int
            if let n = countResult as? Int { total = n }
            else if let n = countResult as? Double { total = Int(n) }
            else { break }
            if total == lastTotal {
                stableRuns += 1
            } else {
                stableRuns = 0
            }
            lastTotal = total
            if stableRuns >= 3 { break }
        }
        _ = try? await webView.callAsyncJavaScript(
            "if (window.__dshDomObserver) { window.__dshDomObserver.disconnect(); window.__dshDomObserver = null; } return 'ok';",
            arguments: [:], contentWorld: .page)
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let stable = stableRuns >= 3
        return BrowserActionResult(
            text: stable
                ? "DOM stable after \(elapsed)ms (\(lastTotal) mutations observed)"
                : "DOM did not fully settle within \(Int(timeoutSeconds * 1000))ms (\(lastTotal) mutations observed)"
        )
    }

    // MARK: - Find Elements

    private func findElements(selector: String?) async throws -> BrowserActionResult {
        guard let selector, !selector.isEmpty else { return .error("find_elements needs a selector") }
        let js = BrowserUseJS.findElements(selector: selector)
        guard let value = try? await evaluateJavaScriptBounded(js, timeout: Self.readActionTimeout),
              let info = Self.parseJSONResult(value) else {
            return .error("find_elements: no result from page")
        }
        if let err = info["error"] as? String { return .error(err) }
        let count = info["count"] as? Int ?? 0
        let shown = info["shown"] as? Int ?? 0
        let elements = info["elements"] as? [[String: Any]] ?? []
        var lines: [String] = ["Found \(count) elements matching \(selector) (showing \(shown))"]
        for el in elements {
            let index = el["index"] as? Int ?? 0
            let tag = el["tag"] as? String ?? ""
            let text = el["text"] as? String ?? ""
            var desc = "[\(index)] <\(tag)>"
            if let id = el["id"] as? String, !id.isEmpty { desc += "#\(id)" }
            if let href = el["href"] as? String, !href.isEmpty { desc += " href=\(href)" }
            if !text.isEmpty { desc += " \"\(text)\"" }
            if let rect = el["rect"] as? [String: Any],
               let x = rect["pageX"] as? Int, let y = rect["pageY"] as? Int {
                desc += " at (\(x), \(y))"
            }
            lines.append(desc)
        }
        return BrowserActionResult(text: lines.joined(separator: "\n"))
    }

    // MARK: - Hover

    private func hover(selector: String?) async throws -> BrowserActionResult {
        guard let selector, !selector.isEmpty else { return .error("hover needs a selector") }
        let js = BrowserUseJS.hover(selector: selector)
        guard let value = try? await evaluateJavaScriptBounded(js, timeout: Self.readActionTimeout),
              let info = Self.parseJSONResult(value) else {
            return .error("hover: no result from page")
        }
        if let err = info["error"] as? String { return .error(err) }
        let tag = info["tag"] as? String ?? ""
        let text = info["text"] as? String ?? ""
        return BrowserActionResult(text: "Hovered <\(tag)> \(text)")
    }

    // MARK: - Get Backbone

    private func getBackbone(maxDepth: Int?) async throws -> BrowserActionResult {
        let depth = maxDepth ?? 5
        let js = BrowserUseJS.getBackbone(maxDepth: depth)
        guard let value = try? await evaluateJavaScriptBounded(js, timeout: Self.readActionTimeout),
              let info = Self.parseJSONResult(value) else {
            return .error("get_backbone: no result from page")
        }
        if let err = info["error"] as? String { return .error(err) }
        guard let tree = info["backbone"] else {
            return BrowserActionResult(text: "(empty backbone)")
        }
        var lines: [String] = []
        if let nodeCount = info["nodeCount"] as? Int { lines.append("Nodes: \(nodeCount) (depth \(info["depth"] as? Int ?? 0))") }
        Self.formatBackboneNode(tree, indent: 0, lines: &lines)
        return BrowserActionResult(text: lines.joined(separator: "\n"))
    }

    private static func formatBackboneNode(_ node: Any, indent: Int, lines: inout [String]) {
        guard let dict = node as? [String: Any] else { return }
        let pad = String(repeating: "  ", count: indent)
        var desc = pad
        if let tag = dict["tag"] as? String { desc += "<\(tag)>" } else { desc += "<?>" }
        if let id = dict["id"] as? String { desc += "#\(id)" }
        if let cls = dict["cls"] as? String, !cls.isEmpty { desc += ".\(cls)" }
        if let sel = dict["sel"] as? String { desc += " [\(sel)]" }
        if let text = dict["text"] as? String, !text.isEmpty { desc += " \"\(text)\"" }
        if let href = dict["href"] as? String { desc += " -> \(href)" }
        if let input = dict["input"] as? String { desc += " (\(input))" }
        if let rect = dict["rect"] as? String { desc += " @\(rect)" }
        lines.append(desc)
        if let children = dict["children"] as? [Any] {
            for child in children {
                formatBackboneNode(child, indent: indent + 1, lines: &lines)
            }
        }
    }

    // MARK: - Fetch

    private func fetch(url urlString: String?) async throws -> BrowserActionResult {
        guard let urlString, !urlString.isEmpty else { return .error("fetch needs a url") }
        var normalized = urlString
        if !normalized.contains("://") { normalized = "https://\(normalized)" }
        guard let url = URL(string: normalized) else { return .error("Invalid URL: \(urlString)") }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https"].contains(scheme) {
            return .error("Cannot fetch \(scheme):// URLs. Only http:// and https:// are supported.")
        }
        let request = URLRequest(url: url, timeoutInterval: 30)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .error("fetch failed: \(error.localizedDescription)")
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let mime = http?.mimeType ?? "application/octet-stream"
        let filename = Self.parseContentDispositionFilename(http?.value(forHTTPHeaderField: "Content-Disposition"))
            ?? url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
        // Text-ish content comes back inline (truncated); anything else is
        // saved to Documents and the path is returned instead of the bytes.
        let textTypes = ["text/", "application/json", "application/xml", "+json", "+xml"]
        let isText = textTypes.contains { mime.hasPrefix($0) || mime.contains($0) }
        if isText, let text = String(data: data, encoding: .utf8) {
            let capped = text.count > 20000 ? String(text.prefix(20000)) + "\n[truncated, \(data.count) bytes total]" : text
            return BrowserActionResult(text: "Fetched \(url.absoluteString) (HTTP \(status), \(mime), \(data.count) bytes):\n\(capped)")
        }
        let name = filename ?? "fetch_\(Int(Date().timeIntervalSince1970)).bin"
        let fileURL = Self.screenshotsDir.appendingPathComponent(name)
        do {
            try data.write(to: fileURL)
        } catch {
            return .error("fetch: could not save \(name): \(error.localizedDescription)")
        }
        return BrowserActionResult(
            text: "Fetched \(url.absoluteString) (HTTP \(status), \(mime), \(data.count) bytes) — saved to \(fileURL.path)",
            fetchedFileData: data,
            fetchedFileName: name
        )
    }

    private static func parseContentDispositionFilename(_ cd: String?) -> String? {
        guard let cd else { return nil }
        // filename="x.pdf" or filename*=UTF-8''x.pdf
        if let range = cd.range(of: "filename*=") {
            let rest = String(cd[range.upperBound...])
            let parts = rest.components(separatedBy: "''")
            if parts.count == 2 { return parts[1].trimmingCharacters(in: .whitespaces) }
        }
        if let range = cd.range(of: "filename=") {
            var rest = String(cd[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\"") { rest = String(rest.dropFirst()) }
            if let end = rest.firstIndex(of: "\"") { rest = String(rest[..<end]) }
            if let semi = rest.firstIndex(of: ";") { rest = String(rest[..<semi]) }
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    // MARK: - Get Cookies

    private func getCookies(keywords: [String]?, fuzzy: Bool) async -> BrowserActionResult {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.getAllCookies()
        let filtered: [HTTPCookie]
        if let keywords, !keywords.isEmpty {
            filtered = cookies.filter { cookie in
                let hay = "\(cookie.name) \(cookie.domain) \(cookie.path)".lowercased()
                if fuzzy {
                    return keywords.contains { hay.contains($0.lowercased()) }
                } else {
                    return keywords.contains { hay == $0.lowercased() || cookie.name.lowercased() == $0.lowercased() }
                }
            }
        } else {
            filtered = cookies
        }
        if filtered.isEmpty {
            return BrowserActionResult(text: keywords == nil ? "No cookies for this site" : "No cookies matching \(keywords!.joined(separator: ", "))")
        }
        var lines: [String] = ["Cookies (\(filtered.count)):"]
        for cookie in filtered.prefix(50) {
            var line = "  \(cookie.name)=\(cookie.value)"
            line += " (domain=\(cookie.domain), path=\(cookie.path)"
            if cookie.isSecure { line += ", secure" }
            if cookie.isHTTPOnly { line += ", httpOnly" }
            if let expires = cookie.expiresDate { line += ", expires=\(Int(expires.timeIntervalSince1970))" }
            line += ")"
            lines.append(line)
        }
        if filtered.count > 50 { lines.append("  ... and \(filtered.count - 50) more") }
        return BrowserActionResult(text: lines.joined(separator: "\n"))
    }

    // MARK: - Set Cookies

    private func setCookies(_ cookies: [[String: Any]]?) async -> BrowserActionResult {
        guard let cookies, !cookies.isEmpty else { return .error("set_cookies needs a cookies array") }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        var set = 0
        var errors: [String] = []
        for dict in cookies {
            guard let name = Self.cookieString(dict, ["name"]),
                  let value = Self.cookieString(dict, ["value"]) else {
                errors.append("cookie entry missing name/value")
                continue
            }
            let domain = Self.cookieString(dict, ["domain"]) ?? (webView.url?.host ?? "")
            let path = Self.cookieString(dict, ["path"]) ?? "/"
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
            ]
            if let secure = Self.cookieBool(dict, ["secure"]) { props[.secure] = secure ? "TRUE" : "FALSE" }
            if let expires = Self.cookieNumber(dict, ["expires", "expiresDate"]) {
                props[.expires] = Date(timeIntervalSince1970: expires)
            }
            guard let cookie = HTTPCookie(properties: props) else {
                errors.append("could not build cookie \(name)")
                continue
            }
            await store.setCookie(cookie)
            set += 1
        }
        var text = "Set \(set) cookie(s)"
        if !errors.isEmpty { text += "\nErrors: " + errors.joined(separator: "; ") }
        return BrowserActionResult(text: text, success: errors.isEmpty)
    }

    /// Format-tolerant field readers (the model may send snake_case or camelCase, string or number).
    private static func cookieString(_ dict: [String: Any], _ aliases: [String]) -> String? {
        for key in aliases {
            if let v = dict[key] as? String, !v.isEmpty { return v }
            if let v = dict[key] as? NSNumber { return v.stringValue }
        }
        return nil
    }

    private static func cookieBool(_ dict: [String: Any], _ aliases: [String]) -> Bool? {
        for key in aliases {
            if let v = dict[key] as? Bool { return v }
            if let v = dict[key] as? NSNumber { return v.boolValue }
            if let v = dict[key] as? String {
                if v.lowercased() == "true" { return true }
                if v.lowercased() == "false" { return false }
            }
        }
        return nil
    }

    private static func cookieNumber(_ dict: [String: Any], _ aliases: [String]) -> Double? {
        for key in aliases {
            if let v = dict[key] as? Double { return v }
            if let v = dict[key] as? NSNumber { return v.doubleValue }
            if let v = dict[key] as? String, let d = Double(v) { return d }
        }
        return nil
    }

    // MARK: - Set User Agent

    func setUserAgent(profile: UserAgentProfile, customString: String? = nil) -> BrowserActionResult {
        currentProfile = profile
        webView.customUserAgent = Self.resolveUA(profile: profile, customString: customString)
        // The UA only takes effect on the next navigation; tell the model so
        // it navigates (or reloads) instead of assuming the current page changed.
        return BrowserActionResult(text: "User agent set to \(profile.displayName). Takes effect on the next navigation — navigate or reload the page to apply it.")
    }

    // MARK: - Set Viewport

    func setViewport(width: Int, height: Int) -> BrowserActionResult {
        currentViewport = (width, height)
        restoreViewportFrame()
        return BrowserActionResult(text: "Viewport set to \(width)x\(height).")
    }

    func restoreViewportFrame() {
        let target = CGSize(width: CGFloat(currentViewport.width), height: CGFloat(currentViewport.height))
        webView.frame = CGRect(origin: webView.frame.origin, size: target)
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
    }

    // MARK: - User Navigation

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    func reload() {
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }
}

// MARK: - WKNavigationDelegate

extension BrowserUseManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url?.absoluteString ?? currentURL
        pageTitle = webView.title ?? pageTitle
        isLoading = false
        if let cont = navigationContinuation {
            navigationContinuation = nil
            cont.resume()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        if let cont = navigationContinuation {
            navigationContinuation = nil
            cont.resume()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        if let cont = navigationContinuation {
            navigationContinuation = nil
            cont.resume()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Target _blank / window.open: hand the configuration to the pool so it
        // opens a new tab sharing the session (window.opener keeps working).
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if let newView = newWindowHandler?(webView.configuration, url) {
                _ = newView
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate

extension BrowserUseManager: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        newWindowHandler?(configuration, navigationAction.request.url)
    }

    func webViewDidClose(_ webView: WKWebView) {
        closeHandler?(webView)
    }
}
