import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

// browser_runtime_bridge.dart — dsh-go browser_use: Dart side of the
// `dsh/browser` platform channel.
//
// The agent's main path is the Node engine -> BrowserLoopbackService (not
// this channel); this bridge serves the visible browser UI page and
// debugging. Modeled on app/lib/runtime/ish/ish_runtime_bridge.dart
// (plain MethodChannel, no EventChannel — state arrives via the
// `browserStateChanged` method call the Swift side pushes after each
// execute).

/// Result of one browser_use action (mirrors Swift BrowserActionResult.toDict()).
class BrowserActionResult {
  const BrowserActionResult({
    required this.text,
    required this.success,
    this.base64Image,
    this.imageFilePath,
    this.pageURL,
    this.tabId,
  });

  factory BrowserActionResult.fromMap(Map<String, dynamic> map) => BrowserActionResult(
    text: map['text'] as String? ?? '',
    success: map['success'] as bool? ?? false,
    base64Image: map['base64Image'] as String?,
    imageFilePath: map['imageFilePath'] as String?,
    pageURL: map['pageURL'] as String?,
    tabId: map['tabId'] as int?,
  );

  final String text;
  final bool success;

  /// Base64 JPEG screenshot (only for the screenshot action).
  final String? base64Image;

  /// Local file path of the saved screenshot (Documents/DSH-Go/browser-screenshots/).
  final String? imageFilePath;
  final String? pageURL;
  final int? tabId;
}

/// One open tab (mirrors Swift BrowserTabPool.Tab).
class BrowserTabInfo {
  const BrowserTabInfo({
    required this.id,
    required this.url,
    required this.title,
    required this.isLoading,
  });

  factory BrowserTabInfo.fromMap(Map<String, dynamic> map) => BrowserTabInfo(
    id: map['id'] as int? ?? 0,
    url: map['url'] as String? ?? '',
    title: map['title'] as String? ?? '',
    isLoading: map['isLoading'] as bool? ?? false,
  );

  final int id;
  final String url;
  final String title;
  final bool isLoading;
}

/// Pool status (mirrors Swift BrowserUsePlugin.statusDict()).
class BrowserStatus {
  const BrowserStatus({required this.tabs, this.activeTabId, required this.maxTabs});

  factory BrowserStatus.fromMap(Map<String, dynamic> map) {
    final rawTabs = map['tabs'] as List? ?? const [];
    return BrowserStatus(
      tabs: [
        for (final entry in rawTabs)
          if (entry is Map) BrowserTabInfo.fromMap(Map<String, dynamic>.from(entry)),
      ],
      activeTabId: map['activeTabId'] as int?,
      maxTabs: map['maxTabs'] as int? ?? 3,
    );
  }

  final List<BrowserTabInfo> tabs;
  final int? activeTabId;
  final int maxTabs;
}

/// Dart side of the `dsh/browser` platform channel.
final class BrowserRuntimeBridge {
  BrowserRuntimeBridge({MethodChannel channel = const MethodChannel('dsh/browser')})
    : _channel = channel {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  final MethodChannel _channel;

  final _stateChanges = StreamController<BrowserStatus>.broadcast();

  /// Pushed by Swift after every execute (`browserStateChanged`).
  Stream<BrowserStatus> get stateChanges => _stateChanges.stream;

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'browserStateChanged') {
      final args = call.arguments;
      if (args is Map) {
        _stateChanges.add(BrowserStatus.fromMap(Map<String, dynamic>.from(args)));
      }
      return null;
    }
    throw MissingPluginException();
  }

  /// Run one browser_use action. [input] is the action JSON object
  /// (same fields as the tool schema: action, url, selector, text, ...).
  Future<BrowserActionResult> execute(Map<String, dynamic> input) async {
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'execute',
      {'input': jsonEncode(input)},
    );
    if (raw == null) throw const FormatException('browser execute returned null');
    return BrowserActionResult.fromMap(Map<String, dynamic>.from(raw));
  }

  Future<BrowserStatus> status() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>('status');
    if (raw == null) throw const FormatException('browser status returned null');
    return BrowserStatus.fromMap(Map<String, dynamic>.from(raw));
  }

  /// Ensure a tab exists (for the browser page). Returns the pool status.
  Future<BrowserStatus> openBrowser() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>('openBrowser');
    if (raw == null) throw const FormatException('browser openBrowser returned null');
    return BrowserStatus.fromMap(Map<String, dynamic>.from(raw));
  }
}
