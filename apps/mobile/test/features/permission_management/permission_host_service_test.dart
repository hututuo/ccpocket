import 'package:ccpocket/features/permission_management/permission_host_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelPermissionHostGateway', () {
    const channel = MethodChannel('ccpocket/permission_host_test');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('parses the versioned native snapshot', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getSnapshot');
            return _snapshotPayload();
          });

      final snapshot = await const MethodChannelPermissionHostGateway(
        channel,
      ).getSnapshot();

      expect(snapshot.supported, isTrue);
      expect(snapshot.nativeApiVersion, permissionHostNativeApiVersion);
      expect(
        snapshot.stateFor(MobilePermission.notifications).status,
        MobilePermissionStatus.notDetermined,
      );
      expect(
        snapshot.stateFor(MobilePermission.camera).status,
        MobilePermissionStatus.authorized,
      );
      expect(
        snapshot.stateFor(MobilePermission.photoLibrary).status,
        MobilePermissionStatus.limited,
      );
      expect(
        snapshot.stateFor(MobilePermission.localNetwork).requestMode,
        MobilePermissionRequestMode.featureTriggered,
      );
    });

    test('passes only the stable permission id when requesting', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'requestPermission');
            expect(call.arguments, {'permissionId': 'camera'});
            return _snapshotPayload(cameraStatus: 'authorized');
          });

      final snapshot = await const MethodChannelPermissionHostGateway(
        channel,
      ).requestPermission(MobilePermission.camera);

      expect(
        snapshot.stateFor(MobilePermission.camera).status,
        MobilePermissionStatus.authorized,
      );
    });

    test('fails closed when the native plugin is absent', () async {
      final snapshot = await const MethodChannelPermissionHostGateway(
        channel,
      ).getSnapshot();

      expect(snapshot.supported, isFalse);
      expect(snapshot.reason, 'native_plugin_missing');
    });

    test('fails closed on an older native api', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return _snapshotPayload(nativeApiVersion: 0);
          });

      final snapshot = await const MethodChannelPermissionHostGateway(
        channel,
      ).getSnapshot();

      expect(snapshot.supported, isFalse);
      expect(snapshot.reason, 'native_api_unsupported');
    });
  });

  group('PermissionHostService', () {
    test(
      'classifies known, blocked, managed, and unknown requirements',
      () async {
        final service = PermissionHostService.test(
          gateway: _FakePermissionHostGateway(
            snapshot: _snapshot(
              notifications: const MobilePermissionState(
                permission: MobilePermission.notifications,
                status: MobilePermissionStatus.notDetermined,
                requestMode: MobilePermissionRequestMode.direct,
              ),
              camera: const MobilePermissionState(
                permission: MobilePermission.camera,
                status: MobilePermissionStatus.denied,
                requestMode: MobilePermissionRequestMode.openSettings,
              ),
            ),
          ),
        );

        final check = await service.checkRequirements([
          'notifications',
          'camera',
          'localNetwork',
          'futurePermission',
        ]);

        expect(
          check.requirements['notifications'],
          PermissionRequirementDisposition.requestable,
        );
        expect(
          check.requirements['camera'],
          PermissionRequirementDisposition.blocked,
        );
        expect(
          check.requirements['localNetwork'],
          PermissionRequirementDisposition.featureManaged,
        );
        expect(
          check.requirements['futurePermission'],
          PermissionRequirementDisposition.requiresAppUpdate,
        );
        expect(check.requiresAppUpdate, isTrue);
        expect(check.allSatisfied, isFalse);
      },
    );

    test('requests only through the explicit user-action method', () async {
      final gateway = _FakePermissionHostGateway(snapshot: _snapshot());
      final service = PermissionHostService.test(gateway: gateway);

      await service.getSnapshot();
      expect(gateway.requests, isEmpty);

      await service.requestFromUserAction(MobilePermission.microphone);
      expect(gateway.requests, [MobilePermission.microphone]);
    });
  });
}

Map<String, Object> _snapshotPayload({
  int nativeApiVersion = permissionHostNativeApiVersion,
  String cameraStatus = 'authorized',
}) {
  return {
    'supported': true,
    'nativeApiVersion': nativeApiVersion,
    'appVersion': '1.107.2',
    'buildNumber': '197',
    'permissions': {
      'notifications': {'status': 'notDetermined', 'requestMode': 'direct'},
      'camera': {'status': cameraStatus, 'requestMode': 'none'},
      'photoLibrary': {'status': 'limited', 'requestMode': 'none'},
      'microphone': {'status': 'denied', 'requestMode': 'openSettings'},
      'speechRecognition': {
        'status': 'restricted',
        'requestMode': 'openSettings',
      },
      'localNetwork': {
        'status': 'systemManaged',
        'requestMode': 'featureTriggered',
      },
      'files': {'status': 'systemManaged', 'requestMode': 'systemPicker'},
      'biometrics': {
        'status': 'systemManaged',
        'requestMode': 'featureTriggered',
      },
    },
  };
}

PermissionHostSnapshot _snapshot({
  MobilePermissionState? notifications,
  MobilePermissionState? camera,
}) {
  return PermissionHostSnapshot(
    supported: true,
    nativeApiVersion: permissionHostNativeApiVersion,
    permissions: {
      MobilePermission.notifications:
          notifications ??
          const MobilePermissionState(
            permission: MobilePermission.notifications,
            status: MobilePermissionStatus.authorized,
            requestMode: MobilePermissionRequestMode.none,
          ),
      MobilePermission.camera:
          camera ??
          const MobilePermissionState(
            permission: MobilePermission.camera,
            status: MobilePermissionStatus.authorized,
            requestMode: MobilePermissionRequestMode.none,
          ),
      MobilePermission.localNetwork: const MobilePermissionState(
        permission: MobilePermission.localNetwork,
        status: MobilePermissionStatus.systemManaged,
        requestMode: MobilePermissionRequestMode.featureTriggered,
      ),
    },
  );
}

class _FakePermissionHostGateway implements PermissionHostGateway {
  _FakePermissionHostGateway({required this.snapshot});

  PermissionHostSnapshot snapshot;
  final requests = <MobilePermission>[];

  @override
  Future<PermissionHostSnapshot> getSnapshot() async => snapshot;

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<PermissionHostSnapshot> requestPermission(
    MobilePermission permission,
  ) async {
    requests.add(permission);
    return snapshot;
  }
}
