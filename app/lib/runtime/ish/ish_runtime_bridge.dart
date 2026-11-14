import 'dart:async';

import 'package:flutter/services.dart';

import '../runtime_bridge.dart';
import 'ish_runtime_service.dart';

sealed class IshEvent {
  const IshEvent();
}

class IshStatusEvent extends IshEvent {
  const IshStatusEvent(this.status);
  final IshStatus status;
}

class IshLogsEvent extends IshEvent {
  const IshLogsEvent(this.entries);
  final List<RuntimeLogEntry> entries;
}

/// Dart side of the `dsh/ish` platform channel (design §2.4(a)).
///
/// Parallel to [NativeNodeRuntimeBridge], but with its own phase machine
/// ([IshPhase]) and status shape ([IshStatus]): iSH stop/restart are
/// repeatable, and Node's terminal `nodeExited` semantics never leak
/// into this bridge. The channel name is new on purpose — reusing
/// `dsh/shellbox` would re-import that stub's error codes, and mixing
/// into `dsh/native_node` would tangle the two lifecycles.
final class IshRuntimeBridge {
  IshRuntimeBridge({
    MethodChannel methods = const MethodChannel('dsh/ish'),
    EventChannel events = const EventChannel('dsh/ish/events'),
  }) : _service = IshRuntimeService(channel: methods),
       _events = events;

  final IshRuntimeService _service;
  final EventChannel _events;
  Stream<IshEvent>? _stream;

  Stream<IshEvent> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map(_parse)
      .where((e) => e != null)
      .cast<IshEvent>();

  IshEvent? _parse(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['type']) {
      case 'status':
        final status = raw['status'];
        if (status is! Map) return null;
        return IshStatusEvent(IshStatus.fromMap(Map<Object?, Object?>.from(status)));
      case 'logs':
        final entries = raw['entries'];
        if (entries is! List) return null;
        return IshLogsEvent([
          for (final entry in entries)
            if (entry is Map) RuntimeLogEntry.fromMap(Map<Object?, Object?>.from(entry)),
        ]);
      default:
        return null;
    }
  }

  Future<IshStatus> status() => _service.status();

  /// Idempotent; installs the rootfs on first use, then boots the kernel.
  Future<void> boot() => _service.boot();

  /// Stops the guest only; the app lives and a later boot() works again.
  Future<void> stop() => _service.stop();

  /// Stop then run again (a boot when the kernel is not booted).
  Future<void> restart() => _service.restart();

  /// Deletes the rootfs; [keepUserData] backs up the guest's /root first.
  Future<void> reset({bool keepUserData = false}) => _service.reset(keepUserData: keepUserData);

  Future<List<String>> getLogs({int lines = 100}) => _service.getLogs(lines: lines);

  Future<RuntimeLogSnapshot> logSnapshot({int lines = 100}) => _service.logSnapshot(lines: lines);
}
