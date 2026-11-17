import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui/onboarding/runtime_setup_page.dart';
import 'package:dsh_app/ui/onboarding/setup_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

class _Runtime extends FakeRuntime {
  _Runtime() : super(const LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: RuntimePhase.installing)));

  void progress(String step, int done, int total) => state = state.copyWith(
    progress: RuntimeProgressEvent(step: step, done: done, total: total),
  );
}

class _Eta extends InstallEtaController {
  void seed(Duration estimate) => state = estimate;
}

void main() {
  test('phase changes clear the previous phase time estimate', () {
    final runtime = _Runtime();
    final container = ProviderContainer(
      overrides: [localRuntimeProvider.overrideWith(() => runtime), installEtaProvider.overrideWith(_Eta.new)],
    );
    addTearDown(container.dispose);
    final eta = container.read(installEtaProvider.notifier) as _Eta;

    runtime.progress('download', 20, 100);
    eta.seed(const Duration(seconds: 30));
    runtime.progress('download', 40, 100);
    expect(container.read(installEtaProvider), const Duration(seconds: 30));

    runtime.progress('verify-download', 0, 100);
    expect(container.read(installEtaProvider), isNull);
    eta.seed(const Duration(seconds: 10));
    runtime.progress('verify', 0, 8);
    expect(container.read(installEtaProvider), isNull);
  });

  test('file verification is counted as files instead of megabytes', () {
    final zh = lookupL10n(const Locale('zh', 'CN'));
    final en = lookupL10n(const Locale('en'));
    const progress = RuntimeProgressEvent(step: 'verify', done: 2, total: 8);
    expect(installMetaLine(zh, progress, null), '2 / 8 个文件');
    expect(installMetaLine(en, progress, null), '2 / 8 files');
    expect(installMetaLine(zh, const RuntimeProgressEvent(step: 'configure', done: 0, total: 1), null), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('download, verification and install have distinct feedback ($brightness)', (tester) async {
      usePhoneSurface(tester);
      final runtime = _Runtime();
      await tester.pumpWidget(
        goldenApp(
          home: RuntimeSetupPage(onDone: () {}),
          brightness: brightness,
          overrides: [localRuntimeProvider.overrideWith(() => runtime)],
        ),
      );
      await tester.pump();

      runtime.progress('download', 22 * 1024 * 1024, 44 * 1024 * 1024);
      await tester.pump();
      expect(find.text('正在下载引擎'), findsOneWidget);
      expect(find.text('下载完成后会自动安装，请保持网络连接'), findsOneWidget);
      expect(find.text('22 / 44 MB'), findsOneWidget);

      runtime.progress('verify-download', 22 * 1024 * 1024, 44 * 1024 * 1024);
      await tester.pump();
      expect(find.text('正在校验引擎'), findsOneWidget);
      expect(find.text('22 / 44 MB'), findsOneWidget);

      runtime.progress('verify', 2, 8);
      await tester.pump();
      expect(find.text('2 / 8 个文件'), findsOneWidget);

      runtime.progress('extract', 22 * 1024 * 1024, 44 * 1024 * 1024);
      await tester.pump();
      expect(find.text('正在安装引擎'), findsOneWidget);
      expect(find.text('22 / 44 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
