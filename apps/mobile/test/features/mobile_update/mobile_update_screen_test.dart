import 'dart:async';

import 'package:ccpocket/features/mobile_update/mobile_update_gateway.dart';
import 'package:ccpocket/features/mobile_update/mobile_update_models.dart';
import 'package:ccpocket/features/mobile_update/mobile_update_restart_prompt.dart';
import 'package:ccpocket/features/mobile_update/mobile_update_screen.dart';
import 'package:ccpocket/features/mobile_update/mobile_update_service.dart';
import 'package:ccpocket/features/mobile_update/mobile_update_settings_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'CC Pocket',
      packageName: 'dev.ccpocket.app',
      version: '1.107.2',
      buildNumber: '198',
      buildSignature: '',
    );
  });

  Future<MobileUpdateService> createService(_WidgetGateway gateway) async {
    final service = MobileUpdateService(
      preferences: await SharedPreferences.getInstance(),
      secureStore: _WidgetSecureStore(),
      gateway: gateway,
      now: () => DateTime.utc(2026, 7, 22, 8),
    );
    await service.initialize();
    return service;
  }

  Widget app(MobileUpdateService service, Widget home) {
    return ChangeNotifierProvider.value(
      value: service,
      child: MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: home,
      ),
    );
  }

  testWidgets('manual check shows loading then a separate download action', (
    tester,
  ) async {
    final check = Completer<MobileUpdateCheckResult>();
    final gateway = _WidgetGateway(checkCompleter: check);
    final service = await createService(gateway);
    await tester.pumpWidget(app(service, const MobileUpdateScreen()));

    await tester.tap(find.byKey(const ValueKey('mobile_update_check_button')));
    await tester.pump();
    expect(find.text('正在检查更新…'), findsWidgets);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('mobile_update_check_button')),
          )
          .onPressed,
      isNull,
    );

    check.complete(MobileUpdateCheckResult.outdated);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mobile_update_download_button')),
      findsOneWidget,
    );
    expect(gateway.downloadCalls, 0);
  });

  testWidgets('download uses indeterminate progress and shows restart state', (
    tester,
  ) async {
    final download = Completer<void>();
    final gateway = _WidgetGateway(
      result: MobileUpdateCheckResult.outdated,
      downloadCompleter: download,
    );
    final service = await createService(gateway);
    await service.checkManually();
    await tester.pumpWidget(app(service, const MobileUpdateScreen()));

    await tester.tap(
      find.byKey(const ValueKey('mobile_update_download_button')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('mobile_update_download_progress')),
      findsOneWidget,
    );

    gateway.nextPatch = 4;
    download.complete();
    await tester.pumpAndSettle();
    expect(find.text('更新已下载'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('failure exposes a retry button and localized reason', (
    tester,
  ) async {
    final gateway = _WidgetGateway(checkError: Exception('Socket timeout'));
    final service = await createService(gateway);
    await service.checkManually();

    await tester.pumpWidget(app(service, const MobileUpdateScreen()));

    expect(find.byKey(const ValueKey('mobile_update_error')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile_update_retry_button')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('mobile_update_error')))
          .data,
      contains('网络连接失败'),
    );
  });

  testWidgets('settings tile shows a dot for an available update', (
    tester,
  ) async {
    final gateway = _WidgetGateway(result: MobileUpdateCheckResult.outdated);
    final service = await createService(gateway);
    await service.checkManually();

    await tester.pumpWidget(
      app(service, const Scaffold(body: MobileUpdateSettingsTile())),
    );

    expect(
      find.byKey(const ValueKey('settings_mobile_update_badge')),
      findsOneWidget,
    );
    expect(find.text('发现可用更新'), findsOneWidget);
  });

  testWidgets('unavailable updater explains that a new base IPA is required', (
    tester,
  ) async {
    final service = await createService(_WidgetGateway(available: false));

    await tester.pumpWidget(app(service, const MobileUpdateScreen()));

    expect(find.textContaining('新的基础 IPA'), findsOneWidget);
  });

  testWidgets('automatic mode surfaces a restart-ready prompt globally', (
    tester,
  ) async {
    final service = await createService(
      _WidgetGateway(currentPatch: 2, nextPatch: 4),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        builder: (context, child) => MobileUpdateRestartPrompt(
          service: service,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const Scaffold(body: Text('home')),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mobile_update_restart_prompt')),
      findsOneWidget,
    );
  });
}

class _WidgetSecureStore implements MobileUpdateSecureStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

class _WidgetGateway implements MobileUpdateGateway {
  _WidgetGateway({
    this.available = true,
    this.result = MobileUpdateCheckResult.upToDate,
    this.checkCompleter,
    this.downloadCompleter,
    this.checkError,
    this.currentPatch,
    this.nextPatch,
  });

  final bool available;
  final MobileUpdateCheckResult result;
  final Completer<MobileUpdateCheckResult>? checkCompleter;
  final Completer<void>? downloadCompleter;
  final Object? checkError;
  int? currentPatch;
  int? nextPatch;
  int downloadCalls = 0;

  @override
  bool get isAvailable => available;

  @override
  Future<MobileUpdateCheckResult> check(MobileUpdateChannel channel) async {
    if (checkError case final error?) throw error;
    return checkCompleter?.future ?? result;
  }

  @override
  Future<void> download(MobileUpdateChannel channel) async {
    downloadCalls++;
    await (downloadCompleter?.future ?? Future<void>.value());
  }

  @override
  Future<int?> readCurrentPatchNumber() async => currentPatch;

  @override
  Future<int?> readNextPatchNumber() async => nextPatch;
}
