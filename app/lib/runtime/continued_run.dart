// iOS 26 lets a task the user started keep running after the app leaves the screen. The native
// side has to ask while the app is in front, so it needs to know as soon as a local turn starts
// (ios/Runner/ContinuedRun.swift). HarmonyOS and older iOS have nothing to ask for.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/android_features.dart';
import '../state/chat_state.dart';
import '../state/hosts_state.dart';
import '../state/notify_state.dart';
import '../state/read_list_cache.dart';
import '../state/read_list_identity.dart';
import '../state/sessions_state.dart';
import 'runtime_state.dart';

/// Whether a turn is going on the on-device engine: in any listed conversation, or in the open
/// one, which a list doesn't show until it has its first message.
final localTurnRunningProvider = Provider<bool>((ref) {
  if (!ref.watch(activeHostProvider).isLocal) return false;
  final sessions = ref.watch(sessionsProvider.select((state) => state.value));
  final connection = ref.watch(readListLiveConnectionProvider);
  final identity = ref.watch(readListIdentityProvider);
  final cache = ref.watch(readListCacheProvider);
  // AsyncValue may retain another host's rows while loading or after a failed
  // read. Keep same-source refreshes, but never treat display carryover as a
  // running turn on the current local client.
  final listed =
      sessions != null &&
      connection != null &&
      connection.isLocal &&
      cache.current(sessions, identity, connection.client) &&
      sessions.any((session) => session.running);
  if (listed) return true;
  final open = ref.watch(currentSessionProvider);
  return open != null && ref.watch(chatProvider(open).select((chat) => chat.running));
});

final continuedRunEnabledProvider = Provider<bool>((ref) {
  final prefs = ref.watch(notifyPrefsProvider);
  return prefs.enabled && prefs.continuedRun;
});

/// Keep this watched while the shell is up. Draws nothing and holds nothing.
final continuedRunProvider = Provider<void>((ref) {
  if (ref.watch(operatingSystemProvider) != 'ios') return;
  ref.listen<bool>(continuedRunEnabledProvider, (was, enabled) {
    if (was == enabled) return;
    unawaited(_setEnabled(ref, enabled));
  });
  ref.listen<bool>(localTurnRunningProvider, (was, running) {
    if (was == running) return;
    unawaited(_tell(ref, running && ref.read(continuedRunEnabledProvider)));
  }, fireImmediately: true);
});

Future<void> _setEnabled(Ref ref, bool enabled) async {
  try {
    await ref.read(runtimeBridgeProvider).setContinuedEnabled(enabled);
    await ref.read(runtimeBridgeProvider).setTurnRunning(enabled && ref.read(localTurnRunningProvider));
  } on MissingPluginException {
    // A build without the engine.
  } on PlatformException {
    // The engine's channel refused. Nothing depends on this: it would pause, as it does anyway.
  }
}

Future<void> _tell(Ref ref, bool running) async {
  try {
    await ref.read(runtimeBridgeProvider).setTurnRunning(running);
  } on MissingPluginException {
    // A build without the engine.
  } on PlatformException {
    // The engine's channel refused. Nothing depends on this: it would pause, as it does anyway.
  }
}
