import 'package:ccpocket/features/session_list/widgets/bridge_device_pairing_dialog.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Mac approval dialog shows the code and exact CLI command', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final bridge = BridgeService();
    addTearDown(bridge.dispose);
    final snapshot = BridgeDevicePairingSnapshot(
      phase: BridgeDevicePairingPhase.waitingForMacApproval,
      connectionEpoch: 7,
      bridgeIdentityId: 'bridge-test',
      confirmationCode: '482731',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showBridgeDevicePairingDialog(
                context: context,
                bridge: bridge,
                initial: snapshot,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('配对这台 iPhone'), findsOneWidget);
    expect(find.text('482731'), findsOneWidget);
    expect(find.text('ccpocket-bridge pair approve 482731'), findsOneWidget);
    expect(find.text('正在等待 Mac 批准…'), findsOneWidget);
  });
}
