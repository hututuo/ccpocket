import 'package:ccpocket/features/session_list/widgets/bridge_connection_key_dialog.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<({Future<BridgeConnectionKeyPromptResult?> result})> openDialog(
    WidgetTester tester, {
    required bool rejectedSavedKey,
  }) async {
    late Future<BridgeConnectionKeyPromptResult?> result;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              result = showDialog<BridgeConnectionKeyPromptResult>(
                context: context,
                builder: (_) => BridgeConnectionKeyDialog(
                  rejectedSavedKey: rejectedSavedKey,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (result: result);
  }

  testWidgets('rejected saved key can be replaced and returned', (
    tester,
  ) async {
    final prompt = await openDialog(tester, rejectedSavedKey: true);

    expect(find.textContaining('不正确或已经更改'), findsOneWidget);
    final connectButton = find.byKey(
      const ValueKey('bridge_connection_key_connect'),
    );
    expect(tester.widget<FilledButton>(connectButton).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('bridge_connection_key_input')),
      '  replacement-key  ',
    );
    await tester.pump();
    await tester.tap(connectButton);
    await tester.pumpAndSettle();

    final value = await prompt.result;
    expect(value?.action, BridgeConnectionKeyPromptAction.connect);
    expect(value?.connectionKey, 'replacement-key');
  });

  testWidgets('missing key offers QR recovery', (tester) async {
    final prompt = await openDialog(tester, rejectedSavedKey: false);

    expect(find.textContaining('要求连接密钥'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('bridge_connection_key_scan_qr')),
    );
    await tester.pumpAndSettle();

    final value = await prompt.result;
    expect(value?.action, BridgeConnectionKeyPromptAction.scanQr);
    expect(value?.connectionKey, isNull);
  });
}
