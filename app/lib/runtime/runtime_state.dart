import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/read_list_epoch.dart';
import '../state/settings_state.dart';
import 'browser/browser_state.dart';
import 'runtime_bridge.dart';
import 'ish/ish_runtime_bridge.dart';
import 'ish/ish_runtime_service.dart';
import 'native_node/native_node_runtime_bridge.dart';
import 'shellbox/shellbox_runtime_bridge.dart';

final runtimeBridgeProvider = Provider<RuntimeBridge>((ref) => Platform.isIOS ? NativeNodeRuntimeBridge() : RuntimeBridge());

/// The `dsh/shellbox` background bridge (iOS only). Separate from
/// [runtimeBridgeProvider] (which stays NativeNodeRuntimeBridge on iOS):
/// the iOS background settings page reads this provider so it always
/// gets a ShellBoxRuntimeBridge. Only the background methods are used
/// through it (setBackgroundEnabled / updateActiveTasks /
/// requestContinuedProcessing / cancelContinuedProcessing /
/// getBackgroundExecutionState / getBackgroundCapabilities); the bridge's
/// other methods (start/stop/install/logs) are unimplemented on iOS and
/// must not be called through this provider.
final shellBoxBackgroundBridgeProvider = Provider<ShellBoxRuntimeBridge>((ref) => ShellBoxRuntimeBridge());

/// The agent browser bridge (MethodChannel `dsh/browser`) lives in
/// [browser_state.dart]: [browserRuntimeBridgeProvider] is defined there
/// (next to [browserStateProvider], the way the iSH provider sits next to
/// its controller below) — this import is the registration, do not define
/// a second provider here.
///
/// The iSH Linux guest bridge (MethodChannel `dsh/ish`), held next to
/// the Node bridge: the two runtimes have independent lifecycles and
/// phase machines, and Node's terminal `nodeExited` semantics must never
/// leak into the iSH side (design §2.4(a), stage 2.3).
final ishRuntimeBridgeProvider = Provider<IshRuntimeBridge>((ref) => IshRuntimeBridge());

/// [RuntimeBridge.batteryExempt]; invalidate to read it again.
final batteryExemptProvider = FutureProvider<bool?>((ref) => ref.watch(runtimeBridgeProvider).batteryExempt());

/// A one-off message from the runtime (e.g. "已用安全模式启动"); [seq] tells repeats apart.
class RuntimeNotice {
  const RuntimeNotice(this.seq, this.text);
  final int seq;
  final String text;
}

/// What the UI needs to know about the local runtime.
class LocalRuntimeState {
  const LocalRuntimeState({
    this.status = const RuntimeStatus.unknown(),
    this.progress,
    this.loaded = false,
    this.notice,
  });

  final RuntimeStatus status;
  final RuntimeProgressEvent? progress;

  /// False until the first status arrives from the native side.
  final bool loaded;

  /// The latest notice; shown once by `SafeModeNoticeListener`.
  final RuntimeNotice? notice;

  LocalRuntimeState copyWith({
    RuntimeStatus? status,
    RuntimeProgressEvent? progress,
    bool clearProgress = false,
    bool? loaded,
    RuntimeNotice? notice,
  }) => LocalRuntimeState(
    status: status ?? this.status,
    progress: clearProgress ? null : (progress ?? this.progress),
    loaded: loaded ?? this.loaded,
    notice: notice ?? this.notice,
  );
}

class LocalRuntimeController extends Notifier<LocalRuntimeState> {
  StreamSubscription<RuntimeEvent>? _sub;
  var _statusRevision = 0;

  RuntimeBridge get _bridge => ref.read(runtimeBridgeProvider);

  @override
  LocalRuntimeState build() {
    // Keep collecting before the log screen opens, without watching its updates.
    ref.read(localRuntimeLogsProvider);
    // Keep the iSH controller alive too: it auto-boots the Linux guest
    // once this (Node) runtime is running (design §2.4(c), stage 2.3).
    ref.read(ishRuntimeProvider);
    _sub = _bridge.events.listen(_onEvent, onError: (_) {});
    ref.onDispose(() => _sub?.cancel());
    unawaited(_refresh());
    return const LocalRuntimeState();
  }

  Future<void> _refresh() async {
    final r = ref;
    // A later query or status event retires this in-flight snapshot.
    final revision = ++_statusRevision;
    try {
      final status = await _bridge.status();
      if (!r.mounted || revision != _statusRevision) return;
      state = state.copyWith(status: status, loaded: true, clearProgress: status.phase != RuntimePhase.installing);
    } catch (_) {
      if (r.mounted && revision == _statusRevision) state = state.copyWith(loaded: true);
    }
  }

  /// Foreground synchronization never starts or stops the resident native guest.
  Future<RuntimeStatus> resumeFromNative() async {
    final r = ref;
    final revision = ++_statusRevision;
    await _bridge.appLifecycle('resumed');
    final status = await _bridge.status();
    if (r.mounted && revision == _statusRevision) _onEvent(RuntimeStatusEvent(status));
    return status;
  }

  void _onEvent(RuntimeEvent event) {
    switch (event) {
      case RuntimeStatusEvent(:final status):
        _statusRevision++;
        state = state.copyWith(status: status, loaded: true, clearProgress: status.phase != RuntimePhase.installing);
      case RuntimeProgressEvent():
        state = state.copyWith(progress: event);
      case RuntimeLogsEvent():
        break;
      case RuntimeNoticeEvent(:final text):
        state = state.copyWith(notice: RuntimeNotice((state.notice?.seq ?? 0) + 1, text));
    }
  }

  Future<void> install() {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    return _bridge.install();
  }

  /// Installs without what a reset kept but could not put back.
  Future<void> installDroppingKept() {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    return _bridge.install(dropKept: true);
  }

  /// The API key is not passed here: it is written to DSH's own credential store
  /// after connecting (see connection_state.dart), so it can change without a restart.
  /// Keeps the current mode: in safe mode this starts safe mode again.
  Future<void> start() {
    final settings = ref.read(settingsProvider);
    return _bridge.start(phoneStorage: settings.phoneStorage, visualReplies: settings.visualReplies);
  }

  /// Starts in [mode]; [EngineMode.normal] from safe mode begins the two-minute trial.
  Future<void> startIn(EngineMode mode) {
    final settings = ref.read(settingsProvider);
    return _bridge.start(phoneStorage: settings.phoneStorage, visualReplies: settings.visualReplies, mode: mode);
  }

  Future<void> stop() => _bridge.stop();

  Future<void> reset() => resetKeeping(const ResetKeep());

  /// Resets the runtime; [keep] comes back with the next install.
  Future<void> resetKeeping(ResetKeep keep) async {
    final r = ref;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    await _bridge.reset(keep: keep);
    if (r.mounted) await _refresh();
  }
}

final localRuntimeProvider = NotifierProvider<LocalRuntimeController, LocalRuntimeState>(LocalRuntimeController.new);

/// The last 1000 engine log lines. The native snapshot and the live batches share
/// one sequence, so batches that arrive while the snapshot is read are neither lost
/// nor shown twice.
class LocalRuntimeLogsController extends Notifier<List<String>> {
  static const _maxLogs = 1000;

  @override
  List<String> build() {
    final r = ref;
    final bridge = r.read(runtimeBridgeProvider);
    final lines = ListQueue<String>();
    final pending = ListQueue<RuntimeLogEntry>();
    var loading = true;
    var throughSeq = 0;

    bool append(Iterable<RuntimeLogEntry> entries) {
      var changed = false;
      for (final entry in entries) {
        if (entry.seq <= throughSeq) continue;
        lines.addLast(entry.line);
        if (lines.length > _maxLogs) lines.removeFirst();
        throughSeq = entry.seq;
        changed = true;
      }
      return changed;
    }

    final sub = bridge.events.listen((event) {
      if (event is! RuntimeLogsEvent) return;
      if (loading) {
        pending.addAll(event.entries);
        while (pending.length > _maxLogs) {
          pending.removeFirst();
        }
      } else if (append(event.entries)) {
        state = List.unmodifiable(lines);
      }
    }, onError: (_) {});
    r.onDispose(sub.cancel);

    Future<void> bootstrap() async {
      try {
        final snapshot = await bridge.logSnapshot();
        if (!r.mounted) return;
        append(snapshot.entries);
        throughSeq = snapshot.throughSeq;
      } catch (_) {
        // Live batches still give a useful tail.
        if (!r.mounted) return;
      }
      append(pending);
      pending.clear();
      loading = false;
      state = List.unmodifiable(lines);
    }

    unawaited(bootstrap());
    return const [];
  }
}

final localRuntimeLogsProvider = NotifierProvider<LocalRuntimeLogsController, List<String>>(
  LocalRuntimeLogsController.new,
);

// ---------------------------------------------------------------------------
// iSH Linux guest (stage 2.3, MethodChannel `dsh/ish`).
//
// The guest has its own lifecycle and phase machine ([IshPhase]), held
// next to the Node runtime above — never merged into it. Node exit is
// terminal (reopen the app); iSH stop only stops the guest and a later
// boot() works again.
// ---------------------------------------------------------------------------

/// What the UI needs to know about the iSH Linux guest.
class IshRuntimeState {
  const IshRuntimeState({this.status = const IshStatus.unknown(), this.loaded = false});

  final IshStatus status;

  /// False until the first status arrives from the native side.
  final bool loaded;

  IshRuntimeState copyWith({IshStatus? status, bool? loaded}) => IshRuntimeState(
    status: status ?? this.status,
    loaded: loaded ?? this.loaded,
  );
}

class IshRuntimeController extends Notifier<IshRuntimeState> {
  StreamSubscription<IshEvent>? _sub;
  var _autoBootTried = false;

  IshRuntimeBridge get _bridge => ref.read(ishRuntimeBridgeProvider);

  @override
  IshRuntimeState build() {
    // Auto-boot (design §2.4(c)): once the local Node engine is running
    // and DSH is connected, boot iSH in the background so the terminal
    // and agent commands find it ready. Boot failure is non-fatal.
    ref.listen(localRuntimeProvider, (previous, next) {
      if (next.status.isRunning) unawaited(_autoBoot());
    });
    // The Node runtime may already be running when this controller is
    // first read; check once after build (a plain ref.read here would
    // run while LocalRuntimeController is still building, so defer it).
    Future.microtask(() {
      if (!ref.mounted) return;
      if (ref.read(localRuntimeProvider).status.isRunning) unawaited(_autoBoot());
    });
    _sub = _bridge.events.listen(_onEvent, onError: (_) {});
    ref.onDispose(() => _sub?.cancel());
    unawaited(_refresh());
    return const IshRuntimeState();
  }

  Future<void> _refresh() async {
    try {
      final status = await _bridge.status();
      if (!ref.mounted) return;
      state = state.copyWith(status: status, loaded: true);
    } catch (_) {
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  void _onEvent(IshEvent event) {
    switch (event) {
      case IshStatusEvent(:final status):
        state = state.copyWith(status: status, loaded: true);
      case IshLogsEvent():
        break; // Logs live in ishRuntimeLogsProvider.
    }
  }

  /// One-shot background boot once Node is running. Never loops: a
  /// failed boot stays visible as an error phase until the user retries.
  /// A failed boot resets [_autoBootTried] so a later trigger (Node
  /// status change, or opening a terminal) can try again — without
  /// this, one failed boot (e.g. a first-launch rootfs failure) made
  /// every later open fail the same way with no retry (stage 3 device
  /// test, build 21: restart + 60 s wait still failed). Still never
  /// loops: _autoBoot only runs on a trigger, never on a timer.
  Future<void> _autoBoot() async {
    if (_autoBootTried) return;
    _autoBootTried = true;
    if (!ref.mounted) return;
    final phase = state.status.phase;
    if (phase == IshPhase.running || phase == IshPhase.booting || phase == IshPhase.installing) {
      return;
    }
    try {
      await _bridge.boot();
    } catch (_) {
      // Non-fatal (design §2.4(c)): the terminal shows "starting/failed"
      // and agent bash keeps reporting unavailable, i.e. today's behavior.
      // But allow a later trigger to retry: a failed boot is not proof
      // the next one fails (and the terminal pre-flight boots on demand).
      _autoBootTried = false;
    }
    if (ref.mounted) await _refresh();
  }

  /// Re-reads the native status (the terminal pre-flight uses this
  /// after a failed boot, so the diagnosis shows the fresh phase and
  /// error code instead of the pre-boot state).
  Future<void> refresh() async {
    await _refresh();
  }

  Future<void> boot() async {
    await _bridge.boot();
    if (ref.mounted) await _refresh();
  }

  /// Ensure the host workspace directory exists right now (build 46).
  /// Idempotent; called immediately before backend.create so the
  /// gateway always sees an existing working directory. Refreshes the
  /// status afterwards so a failed ensure (ish_workspace_missing, the
  /// Swift side sets phase error) shows up in the diagnosis.
  Future<void> ensureWorkspace() async {
    await _bridge.ensureWorkspace();
    if (ref.mounted) await _refresh();
  }

  Future<void> stop() async {
    await _bridge.stop();
    if (ref.mounted) await _refresh();
  }

  Future<void> restart() async {
    await _bridge.restart();
    if (ref.mounted) await _refresh();
  }

  Future<void> reset({bool keepUserData = false}) async {
    await _bridge.reset(keepUserData: keepUserData);
    if (ref.mounted) await _refresh();
  }
}

final ishRuntimeProvider = NotifierProvider<IshRuntimeController, IshRuntimeState>(IshRuntimeController.new);

/// The last 1000 iSH log lines (guest stdout + channel system lines).
/// Same dedup-by-seq scheme as [LocalRuntimeLogsController].
class IshRuntimeLogsController extends Notifier<List<String>> {
  static const _maxLogs = 1000;

  @override
  List<String> build() {
    final r = ref;
    final bridge = r.read(ishRuntimeBridgeProvider);
    final lines = ListQueue<String>();
    final pending = ListQueue<RuntimeLogEntry>();
    var loading = true;
    var throughSeq = 0;

    bool append(Iterable<RuntimeLogEntry> entries) {
      var changed = false;
      for (final entry in entries) {
        if (entry.seq <= throughSeq) continue;
        lines.addLast(entry.line);
        if (lines.length > _maxLogs) lines.removeFirst();
        throughSeq = entry.seq;
        changed = true;
      }
      return changed;
    }

    final sub = bridge.events.listen((event) {
      if (event is! IshLogsEvent) return;
      if (loading) {
        pending.addAll(event.entries);
        while (pending.length > _maxLogs) {
          pending.removeFirst();
        }
      } else if (append(event.entries)) {
        state = List.unmodifiable(lines);
      }
    }, onError: (_) {});
    r.onDispose(sub.cancel);

    Future<void> bootstrap() async {
      try {
        final snapshot = await bridge.logSnapshot();
        if (!r.mounted) return;
        append(snapshot.entries);
        throughSeq = snapshot.throughSeq;
      } catch (_) {
        // Live batches still give a useful tail.
        if (!r.mounted) return;
      }
      append(pending);
      pending.clear();
      loading = false;
      state = List.unmodifiable(lines);
    }

    unawaited(bootstrap());
    return const [];
  }
}

final ishRuntimeLogsProvider = NotifierProvider<IshRuntimeLogsController, List<String>>(
  IshRuntimeLogsController.new,
);
