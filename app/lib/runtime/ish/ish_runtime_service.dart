import 'package:flutter/services.dart';

import '../runtime_bridge.dart';

/// iSH phases — an independent state machine (design §2.4(a)).
///
/// Deliberately NOT [LocalRuntimeServicePhase] / [RuntimePhase]: iSH's
/// stop/restart are repeatable and must never inherit Node's `nodeExited`
/// terminal semantics. Node exit is terminal and needs an app relaunch;
/// iSH stop only stops the guest (pid >= 2) — the app lives and a later
/// boot() works again.
enum IshPhase {
  notInstalled,
  installing,
  installed,
  booting,
  running,
  stopping,
  stopped,
  stopBlocked,
  error;

  static IshPhase parse(Object? wire) =>
      IshPhase.values.firstWhere((p) => p.name == wire, orElse: () => IshPhase.error);
}

/// Resource-governor snapshot (stage 2.5), as reported by `dsh/ish`
/// status under the `governors` key. Best-effort diagnostics: a missing
/// or malformed map falls back to defaults, never to an invented state.
class IshGovernors {
  const IshGovernors({
    this.memoryState = 'off',
    this.memoryBraked = false,
    this.cpuState = 'off',
    this.cpuDuty = 1.0,
    this.windowCpuSeconds = 0,
    this.forkStalls = 0,
    this.forkRateThrottled = 0,
  });

  factory IshGovernors.fromMap(Object? wire) {
    if (wire is! Map) return const IshGovernors();
    final memory = wire['memoryGovernor'];
    final cpu = wire['cpuGovernor'];
    final forkGuard = wire['forkGuard'];
    final forkRate = wire['forkRate'];
    return IshGovernors(
      memoryState: memory is Map ? (memory['state'] as String? ?? 'off') : 'off',
      memoryBraked: memory is Map ? memory['state'] == 'brake' : false,
      cpuState: cpu is Map ? (cpu['state'] as String? ?? 'off') : 'off',
      cpuDuty: cpu is Map ? (cpu['duty'] as num?)?.toDouble() ?? 1.0 : 1.0,
      windowCpuSeconds:
          cpu is Map ? (cpu['windowCpuSeconds'] as num?)?.toDouble() ?? 0 : 0,
      forkStalls:
          forkGuard is Map ? (forkGuard['stalls'] as num?)?.toInt() ?? 0 : 0,
      forkRateThrottled:
          forkRate is Map ? (forkRate['throttled'] as num?)?.toInt() ?? 0 : 0,
    );
  }

  /// Memory governor state: "off" (not started), "ok", or "brake".
  final String memoryState;

  /// True when the kernel is refusing new anonymous commitments
  /// (headroom < 10%, OS pressure critical, or a stale feed).
  final bool memoryBraked;

  /// Background CPU governor state: "off", "green", "yellow", "red".
  final String cpuState;

  /// Current guest throttle duty, 0.05–1.0 (1.0 = full speed).
  final double cpuDuty;

  /// Whole-process CPU seconds in the last 60 s sliding window.
  final double windowCpuSeconds;

  /// Fork-guard stalls so far (forking threads held for memory pressure).
  final int forkStalls;

  /// Forks delayed by the fork-rate token bucket so far.
  final int forkRateThrottled;
}

/// Snapshot of the iSH Linux guest (design §2.4(a) `status` shape).
class IshStatus {
  const IshStatus({
    required this.phase,
    this.booted = false,
    this.rootfsReady = false,
    this.rootfsVersion,
    this.kernelVersion,
    this.guestMemoryBytes = 0,
    this.guestProcessCount = 0,
    this.governors = const IshGovernors(),
    this.error,
    this.loopbackRunning = false,
    this.loopbackPort = 0,
  });

  const IshStatus.unknown() : this(phase: IshPhase.notInstalled);

  factory IshStatus.fromMap(Map<Object?, Object?> map) => IshStatus(
    phase: IshPhase.parse(map['phase']),
    booted: map['booted'] == true,
    rootfsReady: map['rootfsReady'] == true,
    rootfsVersion: map['rootfsVersion'] as String?,
    kernelVersion: map['kernelVersion'] as String?,
    guestMemoryBytes: (map['guestMemoryBytes'] as num?)?.toInt() ?? 0,
    guestProcessCount: (map['guestProcessCount'] as num?)?.toInt() ?? 0,
    governors: IshGovernors.fromMap(map['governors']),
    error: switch (map['error']) {
      final Map value => '${value['code']}: ${value['message']}',
      final String message => message,
      _ => null,
    },
    loopbackRunning: map['loopbackRunning'] == true,
    loopbackPort: (map['loopbackPort'] as num?)?.toInt() ?? 0,
  );

  final IshPhase phase;

  /// The kernel is booted (PID 1 supervisor parked). Note this stays
  /// true after stop: stop only kills pid >= 2, it does not un-boot.
  final bool booted;

  /// The rootfs is installed (data/ + .arch + .ready all present).
  final bool rootfsReady;

  /// Installed rootfs zip SHA-256 (full hex), or null when not installed.
  final String? rootfsVersion;

  /// Pinned ish-arm64 commit (short hash, e.g. "0fd17a13").
  final String? kernelVersion;

  /// Guest anonymous memory in bytes (0 when the task table is busy).
  final int guestMemoryBytes;

  /// Live guest tasks (pid 1 + children; zombies are not counted).
  final int guestProcessCount;

  /// Resource-governor snapshot (stage 2.5). Defaults to "off"
  /// when the native side has not started the governors yet.
  final IshGovernors governors;

  final String? error;

  /// The loopback service (IShLoopbackService) is up and listening, so
  /// Node's ish-bridge can reach the guest. Diagnostic (build 31): the
  /// kernel can be "running" while this is false (no token file), which
  /// is exactly the failure that shows a bare generic error.
  final bool loopbackRunning;

  /// The loopback service's ephemeral port (0 when down).
  final int loopbackPort;

  bool get isRunning => phase == IshPhase.running;

  bool get isBusy =>
      phase == IshPhase.installing || phase == IshPhase.booting || phase == IshPhase.stopping;
}

/// Fail-closed iOS iSH runtime boundary (mirrors NativeNodeRuntimeService).
///
/// The native side owns the phase machine; this adapter only validates
/// the wire shape and never invents a phase. No guest filesystem,
/// process, or user data is modified by this adapter.
final class IshRuntimeService {
  IshRuntimeService({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('dsh/ish');

  final MethodChannel _channel;

  PlatformException get _notLinked => PlatformException(
    code: 'ish_not_linked',
    message: 'The iOS iSH runtime has not been linked.',
  );

  PlatformException get _invalidStatus => PlatformException(
    code: 'ish_status_invalid_response',
    message: 'iSH returned an invalid status.',
  );

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      throw _notLinked;
    }
  }

  /// Idempotent: a no-op when already running (or already booting).
  /// Installs the rootfs on first use, then boots the kernel.
  Future<void> boot() => _invoke('boot');

  /// Stops the guest (kills pid >= 2). The kernel stays booted; a later
  /// boot() works without relaunching the app.
  Future<void> stop() => _invoke('stop');

  /// Stop then run again. When the kernel is not booted this is a boot.
  Future<void> restart() => _invoke('restart');

  /// Deletes the rootfs. [keepUserData] backs up the guest's /root
  /// first. While the kernel is booted this arms `didResetWhileBooted`:
  /// the terminal then refuses new shells until the app is relaunched.
  Future<void> reset({bool keepUserData = false}) => _invoke('reset', {'keepUserData': keepUserData});

  /// Validated status map, for adapters that need the raw fields.
  /// A phase of running is accepted as-is: unlike Node, iSH running
  /// needs no loopback endpoint or token to be meaningful.
  Future<Map<String, dynamic>> statusMap() async {
    Map<String, dynamic>? response;
    try {
      response = await _channel.invokeMapMethod<String, dynamic>('status');
    } on MissingPluginException {
      throw _notLinked;
    }
    if (response == null) throw _invalidStatus;

    final phase = response['phase'];
    if (phase is! String || !IshPhase.values.any((value) => value.name == phase)) {
      throw _invalidStatus;
    }

    final error = response['error'];
    if (error is! String &&
        error != null &&
        (error is! Map || error['code'] is! String || error['message'] is! String)) {
      throw _invalidStatus;
    }

    return response;
  }

  Future<IshStatus> status() async => IshStatus.fromMap(await statusMap());

  /// Last log lines (newest last). Same shape as `dsh/native_node` logs.
  Future<List<String>> getLogs({int lines = 100}) async {
    try {
      return (await _channel.invokeListMethod<String>('getLogs', {'lines': lines})) ?? const [];
    } on MissingPluginException {
      throw _notLinked;
    }
  }

  /// Log snapshot with sequence numbers, for the dedup-by-seq log
  /// controller ({entries: [{seq, line, stream}], throughSeq}).
  Future<RuntimeLogSnapshot> logSnapshot({int lines = 100}) async {
    Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<Object?, Object?>('getLogSnapshot', {'lines': lines});
    } on MissingPluginException {
      throw _notLinked;
    }
    if (raw == null) throw _invalidStatus;
    return RuntimeLogSnapshot.fromMap(raw);
  }
}
