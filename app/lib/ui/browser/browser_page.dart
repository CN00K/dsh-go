import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/browser/browser_runtime_bridge.dart';
import '../../runtime/browser/browser_state.dart';
import '../shell/page_frame.dart';

// browser_page.dart — dsh-go browser_use: the visible browser page.
//
// dsh-go's own UI style (AppPage.list + ListTile/TextButton, same as
// IosBackgroundPage); NOT Minis's BrowserSheetView/BrowserManagementView
// style. The page is normally hidden — it exists so the user can see what
// the agent is doing in the browser. It shows the open tabs, the active
// tab's URL/title, the latest screenshot preview, and a URL bar to open a
// page by hand.
//
// TODO(l10n): strings are hardcoded Chinese for v1; move them into
// app/lib/l10n/parts/ (a new browser_zh/en.arb part, like
// ios_background_zh/en.arb) when the page gets its entry point.

// TODO(route): this page is not wired into any navigation yet. The main
// agent decides the entry point (settings page / session overflow menu);
// v1 only provides the page itself.

class BrowserPage extends ConsumerStatefulWidget {
  const BrowserPage({super.key});

  @override
  ConsumerState<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends ConsumerState<BrowserPage> {
  final _urlController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(browserStateProvider.notifier).openBrowser());
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _run(Map<String, dynamic> input) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(browserStateProvider.notifier).execute(input);
      if (!result.success && mounted) {
        setState(() => _error = result.text);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _navigate() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    await _run({'action': 'navigate', 'url': url});
  }

  Future<void> _screenshot() async {
    await _run({'action': 'screenshot'});
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(browserStateProvider);
    final status = state.status;
    final active = status.tabs.where((t) => t.id == status.activeTabId).firstOrNull;

    return AppPage.list(
      title: '浏览器',
      children: [
        // URL bar: open a page by hand.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    hintText: '输入网址，如 example.com',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _navigate(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : _navigate,
                child: const Text('打开'),
              ),
            ],
          ),
        ),
        if (active != null) ...[
          ListTile(
            title: Text(active.title.isEmpty ? '(无标题)' : active.title),
            subtitle: Text(active.url.isEmpty ? 'about:blank' : active.url),
            trailing: active.isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
          ),
        ] else if (state.loaded)
          const ListTile(title: Text('没有打开的标签页')),
        if (_error != null)
          ListTile(
            title: const Text('操作失败'),
            subtitle: Text(_error!),
          ),
        // Latest screenshot preview (from the last action that produced one).
        if (state.lastResult?.imageFilePath case final path?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('最新截图'),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(path)),
                ),
                const SizedBox(height: 4),
                Text(
                  path,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        // Tabs.
        if (status.tabs.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('标签页'),
          ),
          for (final tab in status.tabs)
            ListTile(
              title: Text(tab.title.isEmpty ? '(无标题)' : tab.title),
              subtitle: Text(tab.url.isEmpty ? 'about:blank' : tab.url),
              selected: tab.id == status.activeTabId,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tab.isLoading)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '关闭标签页',
                    onPressed: _busy
                        ? null
                        : () => _run({'action': 'close_tab', 'tab_id': tab.id}),
                  ),
                ],
              ),
              onTap: _busy
                  ? null
                  : () => _run({'action': 'navigate', 'tab_id': tab.id, 'url': tab.url}),
            ),
        ],
        TextButton(
          onPressed: _busy ? null : _screenshot,
          child: const Text('截图'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => _run({'action': 'new_tab'}),
          child: const Text('新标签页'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => ref.read(browserStateProvider.notifier).refresh(),
          child: const Text('刷新'),
        ),
        if (!state.loaded)
          const ListTile(title: Text('正在读取浏览器状态…')),
      ],
    );
  }
}
