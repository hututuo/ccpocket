import 'package:ccpocket/features/mobile_host/mobile_host_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MobileHostSnapshot', () {
    test('parses a v1 native host snapshot and checks capability versions', () {
      final snapshot = MobileHostSnapshot.fromChannelValue({
        'supported': true,
        'schemaVersion': 1,
        'platform': 'ios',
        'baseVersion': '1.107.2',
        'buildNumber': '198',
        'capabilities': {
          'fileTransfer': 2,
          'quickLook': 1,
          'permissionHost': 2,
          'photoLibrary': 1,
          'biometrics': 1,
          'fileMutationBiometricAuth': 1,
          'backgroundLocationKeepAlive': 1,
        },
      });

      expect(snapshot.supported, isTrue);
      expect(
        snapshot.supports(MobileHostCapability.fileTransfer, minimumVersion: 2),
        isTrue,
      );
      expect(
        snapshot.supports(MobileHostCapability.fileTransfer, minimumVersion: 3),
        isFalse,
      );
      expect(snapshot.supports(MobileHostCapability.dragDrop), isFalse);
      expect(
        snapshot.supports(
          MobileHostCapability.permissionHost,
          minimumVersion: 2,
        ),
        isTrue,
      );
      expect(snapshot.supports(MobileHostCapability.photoLibrary), isTrue);
      expect(snapshot.supports(MobileHostCapability.biometrics), isTrue);
      expect(
        snapshot.supports(MobileHostCapability.fileMutationBiometricAuth),
        isTrue,
      );
      expect(
        snapshot.supports(MobileHostCapability.backgroundLocationKeepAlive),
        isTrue,
      );
      expect(
        snapshot.supports(MobileHostCapability.backgroundContinuation),
        isFalse,
      );
      expect(
        snapshot.supports(MobileHostCapability.backgroundRefreshWarmRuntime),
        isFalse,
      );
    });

    test('fails closed for malformed capability maps', () {
      final snapshot = MobileHostSnapshot.fromChannelValue({
        'supported': true,
        'schemaVersion': 1,
        'capabilities': {'fileTransfer': 0},
      });

      expect(snapshot.supported, isFalse);
      expect(snapshot.reason, 'invalid_snapshot_response');
    });

    test('recognizes the versioned background host capabilities', () {
      final snapshot = MobileHostSnapshot.fromChannelValue({
        'supported': true,
        'schemaVersion': 1,
        'capabilities': {
          'backgroundContinuation': 1,
          'backgroundRefreshWarmRuntime': 1,
        },
      });

      expect(
        snapshot.supports(MobileHostCapability.backgroundContinuation),
        isTrue,
      );
      expect(
        snapshot.supports(MobileHostCapability.backgroundRefreshWarmRuntime),
        isTrue,
      );
    });

    test('serializes bounded compatibility metadata for Bridge', () {
      const snapshot = MobileHostSnapshot(
        supported: true,
        schemaVersion: 1,
        capabilities: {'fileTransfer': 2},
        baseVersion: '1.107.2',
        buildNumber: '198',
      );

      expect(
        snapshot.toClientCapabilitiesJson(
          patchNumber: 7,
          clientBridgeCompatibilityRevision: 1,
        ),
        {
          'baseVersion': '1.107.2',
          'buildNumber': '198',
          'patchNumber': 7,
          'clientBridgeCompatibilityRevision': 1,
          'hostSchemaVersion': 1,
          'nativeCapabilities': {'fileTransfer': 2},
        },
      );
    });
  });

  test('MobileHostService caches the base IPA snapshot', () async {
    final gateway = _CountingGateway();
    final service = MobileHostService(gateway: gateway);

    await service.loadSnapshot();
    await service.loadSnapshot();

    expect(gateway.calls, 1);
  });
}

class _CountingGateway implements MobileHostGateway {
  int calls = 0;

  @override
  Future<MobileHostSnapshot> getSnapshot() async {
    calls++;
    return const MobileHostSnapshot(
      supported: true,
      schemaVersion: 1,
      capabilities: {},
    );
  }
}
