import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browser_runtime_bridge.dart';

// browser_state.dart — dsh-go browser_use: Riverpod state for the agent browser.
//
// The bridge is held next to the other runtime bridges (see
// app/lib/runtime/runtime_state.dart: runtimeBridgeProvider,
// ishRuntimeBridgeProvider). The agent's main path is the Node engine ->
// BrowserLoopbackService; this state serves the visible browser UI page
// and debugging. Registration in runtime_state.dart is an integration step
// (see DESIGN.md §8).

/// The browser bridge (MethodChannel `dsh/browser`).
final browserRuntimeBridgeProvider = Provider<BrowserRuntimeBridge>(
  (ref) => BrowserRuntimeBridge(),
);

/// What the browser page needs to know.
class BrowserState {
  const BrowserState({
    this.status = const BrowserStatus(tabs: [], maxTabs: 3),
    this.loaded = false,
    this.lastResult,
  });

  final BrowserStatus status;

  /// False until the first status arrives from the native side.
  final bool loaded;

  /// The most recent action result (its screenshot path drives the preview).
  final BrowserActionResult? lastResult;

  BrowserState copyWith({
    BrowserStatus? status,
    bool? loaded,
    BrowserActionResult? lastResult,
  }) => BrowserState(
    status: status ?? this.status,
    loaded: loaded ?? this.loaded,
    lastResult: lastResult ?? this.lastResult,
  );
}

class BrowserController extends Notifier<BrowserState> {
  StreamSubscription<BrowserStatus>? _sub;

  BrowserRuntimeBridge get _bridge => ref.read(browserRuntimeBridgeProvider);

  @override
  BrowserState build() {
    _sub = _bridge.stateChanges.listen((status) {
      if (ref.mounted) state = state.copyWith(status: status, loaded: true);
    });
    ref.onDispose(() => _sub?.cancel());
    unawaited(_refresh());
    return const BrowserState();
  }

  Future<void> _refresh() async {
    try {
      final status = await _bridge.status();
      if (ref.mounted) state = state.copyWith(status: status, loaded: true);
    } catch (_) {
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  Future<void> refresh() => _refresh();

  /// Run one browser_use action from the UI (e.g. navigate from the URL bar).
  Future<BrowserActionResult> execute(Map<String, dynamic> input) async {
    final result = await _bridge.execute(input);
    if (ref.mounted) {
      state = state.copyWith(lastResult: result);
      await _refresh();
    }
    return result;
  }

  /// Ensure a tab exists (called when the browser page opens).
  Future<void> openBrowser() async {
    try {
      final status = await _bridge.openBrowser();
      if (ref.mounted) state = state.copyWith(status: status, loaded: true);
    } catch (_) {
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }
}

final browserStateProvider = NotifierProvider<BrowserController, BrowserState>(
  BrowserController.new,
);
