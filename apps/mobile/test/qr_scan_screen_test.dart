import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/screens/qr_scan_screen.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('invalid QR notice gate suppresses repeated camera frames', () {
    final gate = QrInvalidNoticeGate();

    expect(gate.tryAcquire(), isTrue);
    expect(gate.tryAcquire(), isFalse);
    gate.release();
    expect(gate.tryAcquire(), isTrue);
  });

  testWidgets('unsupported QR scanner explains the fallback in app language', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.lightTheme,
          home: const QrScanScreen(),
        ),
      );

      expect(find.text('扫描二维码'), findsOneWidget);
      expect(find.text('当前平台无法使用相机扫描二维码，请手动输入 Bridge URL。'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
