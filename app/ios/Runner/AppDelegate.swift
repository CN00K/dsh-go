import Flutter
import Security
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var companionVoice: IOSCompanionVoice?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before launch finishes, or the tap that launched the app is lost.
    UNUserNotificationCenter.current().delegate = NotifyTaps.shared
    forgetPreviousInstall()
    #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
    let preflight = ProcessInfo.processInfo.arguments.contains("--dsh-phone-preflight")
      || ProcessInfo.processInfo.environment["DSH_PHONE_PREFLIGHT"] == "1"
    IOSPhoneSelfRunner.diagnostic("launch preflight=\(preflight)")
    if preflight {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        Task { @MainActor in
          let owner = IOSPhoneSelfRunner.shared
          print("DSH_SELF_PREFLIGHT configured=\(owner.isConfigured)")
          IOSPhoneSelfRunner.diagnostic("preflight configured=\(owner.isConfigured)")
          for cycle in 1...2 {
            IOSPhoneSelfRunner.diagnostic("preflight cycle=\(cycle)")
            let result = await owner.prepare(ownerID: "device-preflight", current: { true })
            switch result {
            case .success:
              IOSPhoneSelfRunner.diagnostic("preflight ready cycle=\(cycle)")
            case .failure(let error):
              IOSPhoneSelfRunner.diagnostic("preflight failure=\(error)")
              owner.stop(ownerID: "device-preflight")
              return
            }
            owner.stop(ownerID: "device-preflight")
          }
          fflush(stdout)
        }
      }
    }
    #endif
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// The Keychain outlives an uninstall and UserDefaults doesn't. On a fresh install
  /// anything in there belongs to the last one, and must not sign this one in.
  private func forgetPreviousInstall() {
    let marker = "dsh.installed"
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: marker) else { return }
    // The phone-pairing record is device identity, not a user credential:
    // keep it across an in-place upgrade (see IOSPhonePairingStore).
    // NOTE (R9-3-3): the marker cannot tell an in-place upgrade from an
    // uninstall + reinstall (uninstall clears UserDefaults, not the Keychain),
    // so the pairing identity survives a reinstall too; revoke it via the
    // explicit unpair entry point (IOSPhonePairingStore.erase()).
    let pairingService = "io.github.ccch1mneyyy.dshgo.remote-pairing.v1"
    // NOTE (R9-3-1 / R10-3-1): the clear is scoped to the default Keychain
    // group only. Without scoping, the query is a wildcard over every group
    // this app belongs to, including the shared companion-widget group, whose
    // snapshot would be enumerated and deleted (R9-3-1). The group string
    // comes from Info.plist (DSHDefaultAccessGroup), the same
    // $(AppIdentifierPrefix) substitution as DSHCompanionAccessGroup (see
    // CompanionSnapshotStore).
    //
    // The plist value is only trusted as an exact group when it names the
    // default group: present, non-empty, fully substituted (no "$("), and
    // ending with "." + the bundle ID. Two failure modes both land in the
    // suffix-filter path below instead of an exact query:
    //  - unsubstituted (the Codemagic unsigned build never signs, so
    //    $(AppIdentifierPrefix) has no value and the plist value likely
    //    keeps the literal "$(...)"): an exact query with that string would
    //    match nothing, so the old guard's early return left the clear
    //    permanently undone on the only shipping channel (R10-3-1);
    //  - expanded to a bare bundle ID (empty-string expansion): the value
    //    names no real group, so an exact query would match nothing and the
    //    marker would be set after a silent no-op.
    //
    // Suffix filtering works because the groups this app can access are
    // the default group "<TeamID>.<bundleID>", the shared group
    // "<TeamID>.<bundleID>.companion-widget" (Runner.entitlements), and
    // the App Group-derived group "<TeamID>.group.<bundleID>"
    // (com.apple.security.application-groups): only the default group is
    // a bare "<TeamID>.<bundleID>" — the derived group has a dotted
    // prefix before the suffix, so the no-dot check below excludes it.
    // The enumeration in this path is unscoped (the exact value is
    // unavailable), but every item is checked against the suffix and only
    // suffix-matching items are deleted, each with its own exact access
    // group — never a wildcard delete, so the shared snapshot cannot be
    // caught by it.
    let bundleID = Bundle.main.bundleIdentifier
    let plistGroup = Bundle.main.object(forInfoDictionaryKey: "DSHDefaultAccessGroup") as? String
    let exactGroup: String? = {
      guard let plistGroup, !plistGroup.isEmpty, !plistGroup.contains("$("),
        let bundleID, plistGroup.hasSuffix("." + bundleID)
      else { return nil }
      return plistGroup
    }()
    // Without either an exact group or a bundle ID to build the suffix from,
    // the default group cannot be told apart from the shared group: skip
    // (the marker is left unset so it retries next launch).
    guard exactGroup != nil || bundleID != nil else { return }
    // Deletes one enumerated item in `group`, keeping the pairing record.
    let deleteItem: ([String: Any], String) -> Void = { item, group in
      guard let service = item[kSecAttrService as String] as? String, service != pairingService else { return }
      var deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccessGroup as String: group,
        kSecAttrService as String: service,
      ]
      if let account = item[kSecAttrAccount as String] as? String {
        deleteQuery[kSecAttrAccount as String] = account
      }
      SecItemDelete(deleteQuery as CFDictionary)
    }
    if let exactGroup {
      // Plist value substituted and names the default group: existing
      // exact-scoped clear, unchanged.
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccessGroup as String: exactGroup,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnAttributes as String: true,
      ]
      var result: CFTypeRef?
      if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
        let items = result as? [[String: Any]]
      {
        for item in items {
          deleteItem(item, exactGroup)
        }
      }
      defaults.set(true, forKey: marker)
      return
    }
    // Suffix-filter path: plist value missing, unsubstituted, or a bare
    // bundle ID. Enumerate unscoped, delete only items whose own access
    // group is the default group (ends with ".<bundleID>" with no "."
    // before the suffix, so the App Group-derived group is excluded).
    let suffix = "." + bundleID!
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      // No generic-password items in any accessible group: nothing to clear.
      defaults.set(true, forKey: marker)
      return
    }
    // Any other enumeration error: leave the marker unset so the clear
    // retries next launch.
    guard status == errSecSuccess, let items = result as? [[String: Any]] else { return }
    for item in items {
      guard let group = item[kSecAttrAccessGroup as String] as? String,
        group.hasSuffix(suffix) && !group.dropLast(suffix.count).contains(".")
      else { continue }
      deleteItem(item, group)
    }
    defaults.set(true, forKey: marker)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshPetLiveActivity") {
      PetLiveActivityPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshPlugin") {
      DshPlugin.register(with: registrar)
      IOSPhoneControl.shared.register(messenger: registrar.messenger())
      IOSPhoneLink.shared.register(messenger: registrar.messenger(), presenter: { topViewController() })
      IOSPetOverlay.shared.register(registrar: registrar)
      companionVoice?.dispose()
      companionVoice = IOSCompanionVoice(messenger: registrar.messenger(), pipAudioConfigured: {
        IOSPetOverlay.shared.statusSnapshot["audioSessionConfigured"] as? Bool == true
      })
      IOSPetOverlay.shared.onTaskPauseRequested = { IOSPhoneControl.shared.pausePhoneTask(id: $0) }
      IOSPetOverlay.shared.onTaskStopConfirmed = { IOSPhoneControl.shared.stopPhoneTaskConfirmed(id: $0) }
      IOSPetOverlay.shared.onTaskResumeConfirmed = { IOSPhoneControl.shared.resumePhoneTask(id: $0) }
    }
    // Ported from feat (iSH Linux sandbox, D1c loopback bridge): the
    // `dsh/ish` guest runtime, the `dsh/files` share/save channel and
    // the `dsh/browser` agent-browser channel. NOT ported: DshNotify
    // (feat's task-outcome notifications; upstream's notify system owns
    // that now), DshNativeNode (no such bridge in 1.1.1 — `dsh/runtime`
    // is the in-process NodeMobile host) and DshShellBox (deleted by
    // D5c; background state is NotifyPrefs + ContinuedRun).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshIshRuntime") {
      ISHRuntime.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshFiles") {
      FilesPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshBrowser") {
      BrowserUsePlugin.register(with: registrar)
    }
  }
}
