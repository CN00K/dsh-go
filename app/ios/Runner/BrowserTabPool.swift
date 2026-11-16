import Foundation
import WebKit

// BrowserTabPool.swift — dsh-go browser_use: tab pool (max 3 tabs).
//
// Adapted from OpenMinis src/ios/Agent/BrowserUse/BrowserTabPool.swift
// (1793 lines). dsh-go keeps the tab model, the max-3 cap, per-tab serial
// execution and the tab-id stamping; dropped vs Minis:
//   - Cross-pool registry / global tab accounting (single pool in dsh-go)
//   - Privileged owners / agent-vs-UI tab ownership (one agent, one UI)
//   - Memory-warning eviction and registry-driven preemption
//   - The 60s serial-wait timeout ladder (v1: the action's own timeout is
//     the bound; a wedged tab blocks only its own queue)
//   - postActionGrace / abortAndRebuildTab (dead-tab rebuild is a TODO)

@MainActor
final class BrowserTabPool: ObservableObject {

    // MARK: - Tab

    struct Tab: Identifiable {
        let id: Int
        let manager: BrowserUseManager
        var createdAt: Date
        var lastUsedAt: Date

        var url: String { manager.currentURL }
        var title: String { manager.pageTitle }
        var isLoading: Bool { manager.isLoading }
    }

    /// Maximum concurrent tabs (matches Minis).
    static let maxTabs = 3

    /// Idle timeout for non-active tabs (30 minutes).
    private static let idleTimeout: TimeInterval = 30 * 60

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedTabId: Int?

    private var nextTabId = 1

    /// Per-tab serial tail: each execute chains onto the previous task for
    /// that tab, so concurrent click/type calls on one tab cannot interleave.
    /// All state is @MainActor, so no Sendable juggling is needed.
    private var tabTails: [Int: Task<Void, Never>] = [:]

    private var idleTimer: Timer?

    init() {
        startIdleTimer()
    }

    deinit {
        idleTimer?.invalidate()
    }

    // MARK: - Tab Lifecycle

    /// The active tab's manager, or nil when no tab exists.
    var activeManager: BrowserUseManager? {
        guard let id = selectedTabId else { return nil }
        return tabs.first { $0.id == id }?.manager
    }

    /// Create a tab if none exists (used by the browser UI page).
    func ensureTabForUI() {
        if tabs.isEmpty {
            _ = newTab()
        }
    }

    /// Create a new tab. Returns an error result when the pool is full —
    /// dsh-go does NOT silently close the oldest tab; the agent decides.
    func newTab(url: String? = nil) -> BrowserActionResult {
        if tabs.count >= Self.maxTabs {
            return .error("Tab limit reached (\(Self.maxTabs) tabs). Close a tab first (close_tab) — dsh-go does not evict tabs silently.")
        }
        let id = nextTabId
        nextTabId += 1
        let manager = BrowserUseManager()
        manager.newWindowHandler = { [weak self] configuration, url in
            self?.openWithConfiguration(configuration, url: url)
        }
        manager.closeHandler = { [weak self] webView in
            guard let self else { return }
            if let tab = self.tabs.first(where: { $0.manager.webView === webView }) {
                _ = self.closeTab(id: tab.id)
            }
        }
        tabs.append(Tab(id: id, manager: manager, createdAt: Date(), lastUsedAt: Date()))
        selectedTabId = id
        touchActivity()
        if let url, !url.isEmpty {
            // Navigate asynchronously; the result reports the tab, the
            // navigation itself completes in the background.
            Task {
                let input = BrowserActionInput(action: .navigate, url: url, selector: nil, text: nil, coordinateX: nil, coordinateY: nil, direction: nil, amount: nil, script: nil, userAgent: nil, maxDepth: nil, tabId: id)
                _ = try? await self.execute(input: input)
            }
            return BrowserActionResult(text: "Opened tab \(id), navigating to \(url)", tabId: id)
        }
        return BrowserActionResult(text: "Opened tab \(id) (about:blank)", tabId: id)
    }

    /// Open a URL with a pre-built configuration (window.open / target=_blank).
    /// Returns the new tab's WKWebView so the opener retains window.opener.
    func openWithConfiguration(_ configuration: WKWebViewConfiguration, url: URL?) -> WKWebView? {
        if tabs.count >= Self.maxTabs {
            // Pool full: reuse the active tab for the popup instead of
            // dropping it (a popup the agent never sees is worse than a
            // reused tab).
            guard let manager = activeManager else { return nil }
            if let url { manager.webView.load(URLRequest(url: url)) }
            return manager.webView
        }
        let id = nextTabId
        nextTabId += 1
        let manager = BrowserUseManager(profile: .mobileSafari, customString: nil, configuration: configuration)
        manager.newWindowHandler = { [weak self] config, url in
            self?.openWithConfiguration(config, url: url)
        }
        manager.closeHandler = { [weak self] webView in
            guard let self else { return }
            if let tab = self.tabs.first(where: { $0.manager.webView === webView }) {
                _ = self.closeTab(id: tab.id)
            }
        }
        tabs.append(Tab(id: id, manager: manager, createdAt: Date(), lastUsedAt: Date()))
        selectedTabId = id
        touchActivity()
        if let url { manager.webView.load(URLRequest(url: url)) }
        return manager.webView
    }

    func closeTab(id: Int) -> BrowserActionResult {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return .error("No tab with id \(id)")
        }
        let tab = tabs[index]
        tab.manager.stopLoading()
        tabTails[id] = nil
        tabs.remove(at: index)
        if selectedTabId == id {
            selectedTabId = tabs.last?.id
        }
        touchActivity()
        return BrowserActionResult(text: "Closed tab \(id) (\(tab.url.isEmpty ? "about:blank" : tab.url))", tabId: id)
    }

    func listTabs() -> BrowserActionResult {
        if tabs.isEmpty {
            return BrowserActionResult(text: "No tabs open")
        }
        var lines: [String] = ["Tabs (\(tabs.count)/\(Self.maxTabs)):"]
        for tab in tabs {
            let active = tab.id == selectedTabId ? " (active)" : ""
            let title = tab.title.isEmpty ? "(no title)" : tab.title
            lines.append("  [\(tab.id)] \(title)\(active)")
            lines.append("      \(tab.url.isEmpty ? "about:blank" : tab.url)")
        }
        return BrowserActionResult(text: lines.joined(separator: "\n"))
    }

    func selectTab(id: Int) -> BrowserActionResult {
        guard tabs.contains(where: { $0.id == id }) else {
            return .error("No tab with id \(id)")
        }
        selectedTabId = id
        touchActivity()
        return BrowserActionResult(text: "Selected tab \(id)")
    }

    func releaseAllTabs() {
        for tab in tabs {
            tab.manager.stopLoading()
        }
        tabs.removeAll()
        selectedTabId = nil
        tabTails.removeAll()
    }

    // MARK: - Execute

    /// Dispatch one action. Tab-management actions run on the pool; everything
    /// else runs on the target tab (explicit `tab_id`, else the active tab),
    /// serialized per tab. The result is stamped with the tab id it actually
    /// ran on.
    func execute(input: BrowserActionInput) async throws -> BrowserActionResult {
        switch input.action {
        case .newTab:
            return newTab(url: input.url)
        case .closeTab:
            guard let id = input.tabId else { return .error("close_tab needs tab_id") }
            return closeTab(id: id)
        case .listTabs:
            return listTabs()
        case .setUserAgent:
            // Apply to the target tab (or active tab). The manager answers
            // directly; the UA takes effect on the next navigation.
            guard let manager = targetManager(for: input) else {
                return .error("set_user_agent: no tab open")
            }
            guard let profile = input.userAgent else {
                return .error(UserAgentProfile.invalidArgumentMessage(raw: input.userAgentRaw))
            }
            return manager.setUserAgent(profile: profile)
        case .setViewport:
            guard let manager = targetManager(for: input) else {
                return .error("set_viewport: no tab open")
            }
            if input.viewportReset == true {
                let size = manager.currentProfile.viewportSize
                return manager.setViewport(width: size.width, height: size.height)
            }
            guard let w = input.viewportWidth, let h = input.viewportHeight, w > 0, h > 0 else {
                return .error("set_viewport needs viewport_width and viewport_height (or reset=true)")
            }
            return manager.setViewport(width: w, height: h)
        default:
            break
        }

        // Resolve the target tab (explicit tab_id, else active tab; create one
        // for navigate when none exists so the first action just works).
        let targetId: Int
        if let id = input.tabId {
            guard tabs.contains(where: { $0.id == id }) else {
                return .error("No tab with id \(id)")
            }
            targetId = id
        } else if let active = selectedTabId {
            targetId = active
        } else if input.action == .navigate {
            let created = newTab()
            guard let id = created.tabId else { return created }
            targetId = id
        } else {
            return .error("No tab open — navigate first (or new_tab)")
        }

        guard let manager = tabs.first(where: { $0.id == targetId })?.manager else {
            return .error("No tab with id \(targetId)")
        }
        touchTab(targetId)

        // Per-tab serial execution: chain onto the previous task for this tab.
        let previous = tabTails[targetId]
        let task = Task<BrowserActionResult, Error> {
            await previous?.value
            var result = try await manager.execute(action: input)
            result.tabId = targetId
            result.pageURL = manager.currentURL.isEmpty ? result.pageURL : manager.currentURL
            return result
        }
        tabTails[targetId] = Task { _ = try? await task.value }
        return try await task.value
    }

    /// The manager an action targets (explicit tab_id, else the active tab).
    private func targetManager(for input: BrowserActionInput) -> BrowserUseManager? {
        if let id = input.tabId {
            return tabs.first { $0.id == id }?.manager
        }
        return activeManager
    }

    private func touchTab(_ id: Int) {
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            tabs[index].lastUsedAt = Date()
        }
        touchActivity()
    }

    func touchActivity() {
        // (Idle timer reads lastUsedAt; no-op here beyond the touch.)
    }

    // MARK: - Idle Eviction

    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evictIdleTabs()
            }
        }
    }

    /// Close non-active tabs idle for more than the timeout. The active tab
    /// is never evicted (the user may be looking at it).
    func evictIdleTabs() {
        let now = Date()
        let idle = tabs.filter { tab in
            tab.id != selectedTabId && now.timeIntervalSince(tab.lastUsedAt) > Self.idleTimeout
        }
        for tab in idle {
            _ = closeTab(id: tab.id)
        }
    }
}
