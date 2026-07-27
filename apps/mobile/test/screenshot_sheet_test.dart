import 'dart:async';

import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/screenshot_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScreenshotBridge extends BridgeService {
  final windowLists = StreamController<List<WindowInfo>>.broadcast();
  final results = StreamController<ScreenshotResultMessage>.broadcast();
  final capturedModes = <String>[];
  int windowListRequests = 0;

  @override
  Stream<List<WindowInfo>> get windowList => windowLists.stream;

  @override
  Stream<ScreenshotResultMessage> get screenshotResults => results.stream;

  @override
  void requestWindowList() => windowListRequests += 1;

  @override
  void takeScreenshot({
    required String mode,
    int? windowId,
    required String projectPath,
    String? sessionId,
  }) {
    capturedModes.add(mode);
  }

  @override
  void dispose() {
    windowLists.close();
    results.close();
    super.dispose();
  }
}

Widget _app(_ScreenshotBridge bridge) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    theme: AppTheme.darkTheme,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => showScreenshotSheet(
            context: context,
            bridge: bridge,
            projectPath: '/project',
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('localizes the screenshot picker and success notice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = _ScreenshotBridge();
    addTearDown(bridge.dispose);
    await tester.pumpWidget(_app(bridge));

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(bridge.windowListRequests, 1);

    bridge.windowLists.add(const []);
    await tester.pump();

    expect(find.text('截图'), findsOneWidget);
    expect(find.text('全屏'), findsOneWidget);
    expect(find.text('截取整个桌面'), findsOneWidget);
    expect(find.text('未找到窗口'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
          .tooltip,
      '刷新',
    );

    await tester.tap(find.text('全屏'));
    await tester.pump();
    expect(bridge.capturedModes, ['fullscreen']);

    bridge.results.add(const ScreenshotResultMessage(success: true));
    await tester.pumpAndSettle();
    expect(find.text('截图已保存'), findsOneWidget);
  });
}
