import 'package:ccpocket/features/permission_management/permission_host_service.dart';
import 'package:ccpocket/features/permission_management/permission_management_screen.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loads statuses without requesting any permission', (
    tester,
  ) async {
    final gateway = _ScreenPermissionGateway();

    await _pumpScreen(tester, gateway);

    expect(find.text('Permission Management'), findsOneWidget);
    expect(find.text('Not requested'), findsOneWidget);
    expect(gateway.snapshotCalls, 1);
    expect(gateway.requests, isEmpty);
  });

  testWidgets('requests a permission only after its button is tapped', (
    tester,
  ) async {
    final gateway = _ScreenPermissionGateway();
    await _pumpScreen(tester, gateway);
    final requestButton = find.byKey(
      const ValueKey('permission_camera_request_button'),
    );
    await tester.ensureVisible(requestButton);

    await tester.tap(requestButton);
    await tester.pumpAndSettle();

    expect(gateway.requests, [MobilePermission.camera]);
    expect(find.text('Allowed'), findsWidgets);
  });

  testWidgets('opens system settings for a denied permission', (tester) async {
    final gateway = _ScreenPermissionGateway();
    await _pumpScreen(tester, gateway);
    final settingsButton = find.byKey(
      const ValueKey('permission_notifications_settings_button'),
    );
    await tester.ensureVisible(settingsButton);

    await tester.tap(settingsButton);
    await tester.pump();

    expect(gateway.openSettingsCalls, 1);
    expect(gateway.requests, isEmpty);
  });

  testWidgets('refreshes statuses when the app resumes', (tester) async {
    final gateway = _ScreenPermissionGateway();
    await _pumpScreen(tester, gateway);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(gateway.snapshotCalls, 2);
    expect(gateway.requests, isEmpty);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _ScreenPermissionGateway gateway,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PermissionManagementScreen(
        service: PermissionHostService.test(gateway: gateway),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ScreenPermissionGateway implements PermissionHostGateway {
  int snapshotCalls = 0;
  int openSettingsCalls = 0;
  final requests = <MobilePermission>[];
  bool cameraAllowed = false;

  @override
  Future<PermissionHostSnapshot> getSnapshot() async {
    snapshotCalls += 1;
    return _snapshot();
  }

  @override
  Future<bool> openAppSettings() async {
    openSettingsCalls += 1;
    return true;
  }

  @override
  Future<PermissionHostSnapshot> requestPermission(
    MobilePermission permission,
  ) async {
    requests.add(permission);
    if (permission == MobilePermission.camera) cameraAllowed = true;
    return _snapshot();
  }

  PermissionHostSnapshot _snapshot() {
    return PermissionHostSnapshot(
      supported: true,
      nativeApiVersion: permissionHostNativeApiVersion,
      permissions: {
        MobilePermission.notifications: const MobilePermissionState(
          permission: MobilePermission.notifications,
          status: MobilePermissionStatus.denied,
          requestMode: MobilePermissionRequestMode.openSettings,
        ),
        MobilePermission.camera: MobilePermissionState(
          permission: MobilePermission.camera,
          status: cameraAllowed
              ? MobilePermissionStatus.authorized
              : MobilePermissionStatus.notDetermined,
          requestMode: cameraAllowed
              ? MobilePermissionRequestMode.none
              : MobilePermissionRequestMode.direct,
        ),
        MobilePermission.microphone: const MobilePermissionState(
          permission: MobilePermission.microphone,
          status: MobilePermissionStatus.authorized,
          requestMode: MobilePermissionRequestMode.none,
        ),
        MobilePermission.speechRecognition: const MobilePermissionState(
          permission: MobilePermission.speechRecognition,
          status: MobilePermissionStatus.authorized,
          requestMode: MobilePermissionRequestMode.none,
        ),
        MobilePermission.localNetwork: const MobilePermissionState(
          permission: MobilePermission.localNetwork,
          status: MobilePermissionStatus.systemManaged,
          requestMode: MobilePermissionRequestMode.featureTriggered,
        ),
        MobilePermission.files: const MobilePermissionState(
          permission: MobilePermission.files,
          status: MobilePermissionStatus.systemManaged,
          requestMode: MobilePermissionRequestMode.systemPicker,
        ),
      },
    );
  }
}
