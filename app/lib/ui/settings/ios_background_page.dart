import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../runtime/shellbox/shellbox_runtime_bridge.dart';
import '../shell/page_frame.dart';

class IosBackgroundPage extends ConsumerStatefulWidget {
  const IosBackgroundPage({super.key});

  @override
  ConsumerState<IosBackgroundPage> createState() => _IosBackgroundPageState();
}

class _IosBackgroundPageState extends ConsumerState<IosBackgroundPage> {
  Map<String, dynamic>? _capabilities;
  Map<String, dynamic>? _snapshot;
  Map<String, dynamic>? _prefs;
  bool _failed = false;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  late final AppLifecycleListener _lifecycle;

  late final ShellBoxRuntimeBridge _bridge;

  @override
  void initState() {
    super.initState();
    // The background bridge is separate from runtimeBridgeProvider (which
    // stays NativeNodeRuntimeBridge on iOS): it talks to the native
    // `dsh/shellbox` channel and only the background methods are used.
    _bridge = ref.read(shellBoxBackgroundBridgeProvider);
    _subscription = _bridge.backgroundChanges.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final bridge = _bridge;
    try {
      final capabilities = await bridge.getBackgroundCapabilities();
      final snapshot = await bridge.getBackgroundExecutionState();
      if (mounted) {
        setState(() {
          _capabilities = capabilities;
          _snapshot = snapshot;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
    // Preferences are best-effort: a failure leaves the last known values
    // in place instead of blanking the whole page.
    try {
      final prefs = await bridge.getBackgroundPreferences();
      if (mounted) setState(() => _prefs = prefs);
    } catch (_) {
      // Keep the previous _prefs; toggles stay at their last known state.
    }
  }

  Future<void> _change(Future<void> Function() action) async {
    try {
      await action();
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _setPref(String key, bool value) async {
    await _change(() => _bridge.setBackgroundPreference(key, value));
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bridge = _bridge;
    final state = switch (_snapshot?['state']) {
      'foreground' => l10n.iosBackgroundForeground,
      'resuming' => l10n.iosBackgroundResuming,
      'backgroundGrace' => l10n.iosBackgroundGraceState,
      'continuedProcessing' => l10n.iosBackgroundContinuedState,
      'expired' => l10n.iosBackgroundExpired,
      'failed' => l10n.iosBackgroundFailed,
      'completed' => l10n.iosBackgroundCompleted,
      'error' => l10n.iosBackgroundError,
      _ => l10n.iosBackgroundUnknown,
    };
    final reason = switch (_capabilities?['reason']) {
      'requires_ios_26' => l10n.iosBackgroundUnsupported,
      'registration_failed' => l10n.iosBackgroundRegistrationFailed,
      _ => l10n.iosBackgroundSystemMayDecline,
    };
    final continuedSupported = _capabilities?['continuedProcessingOSSupported'] == true;
    final masterOn = _snapshot?['enabled'] == true;
    return AppPage.list(
      title: l10n.iosBackgroundTitle,
      children: [
        SwitchListTile.adaptive(
          title: Text(l10n.iosBackgroundEnable),
          subtitle: Text(l10n.iosBackgroundContinued),
          value: masterOn,
          onChanged: continuedSupported
              ? (enabled) => _change(() => bridge.setBackgroundEnabled(enabled)) : null,
        ),
        SwitchListTile.adaptive(
          title: Text(l10n.iosBackgroundPreferContinued),
          subtitle: Text(l10n.iosBackgroundPreferContinuedSub),
          value: _prefs?['preferContinuedProcessing'] == true,
          onChanged: masterOn && continuedSupported
              ? (enabled) => _setPref('preferContinuedProcessing', enabled) : null,
        ),
        SwitchListTile.adaptive(
          title: Text(l10n.iosBackgroundLiveActivity),
          subtitle: Text(l10n.iosBackgroundLiveActivitySub),
          value: _prefs?['liveActivity'] == true,
          onChanged: masterOn
              ? (enabled) => _setPref('liveActivity', enabled) : null,
        ),
        SwitchListTile.adaptive(
          title: Text(l10n.iosBackgroundNotifications),
          subtitle: Text(l10n.iosBackgroundNotificationsSub),
          value: _prefs?['notifications'] == true,
          onChanged: masterOn
              ? (enabled) => _setPref('notifications', enabled) : null,
        ),
        SwitchListTile.adaptive(
          title: Text(l10n.iosBackgroundPrivacy),
          subtitle: Text(l10n.iosBackgroundPrivacySub),
          value: _prefs?['privacyMode'] == true,
          onChanged: masterOn
              ? (enabled) => _setPref('privacyMode', enabled) : null,
        ),
        SwitchListTile.adaptive(
          title: Text(l10n.iosBackgroundSpeak),
          subtitle: Text(l10n.iosBackgroundSpeakSub),
          value: _prefs?['backgroundSpeak'] == true,
          onChanged: masterOn
              ? (enabled) => _setPref('backgroundSpeak', enabled) : null,
        ),
        ListTile(title: Text(reason)),
        ListTile(title: Text(l10n.iosBackgroundGrace)),
        ListTile(title: Text(l10n.iosBackgroundState), subtitle: Text(state)),
        if (_failed) ListTile(title: Text(l10n.iosBackgroundUnavailable)),
        ListTile(title: Text(l10n.iosBackgroundLimits)),
        TextButton(onPressed: _refresh, child: Text(l10n.iosBackgroundRefresh)),
        if (_snapshot?['authorizationActive'] == true)
          TextButton(
            onPressed: () => _change(bridge.cancelContinuedProcessing),
            child: Text(l10n.iosBackgroundCancel),
          ),
      ],
    );
  }
}
