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
    this.error,
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
    error: switch (map['error']) {
      final Map value => '${value['code']}: ${value['message']}',
      final String message => message,
      _ => null,
    },
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

  final String? error;

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
