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
        'capabilities': {'fileTransfer': 2, 'quickLook': 1},
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

    test('serializes bounded compatibility metadata for Bridge', () {
      const snapshot = MobileHostSnapshot(
        supported: true,
        schemaVersion: 1,
        capabilities: {'fileTransfer': 2},
        baseVersion: '1.107.2',
        buildNumber: '198',
      );

      expect(snapshot.toClientCapabilitiesJson(patchNumber: 7), {
        'baseVersion': '1.107.2',
        'buildNumber': '198',
        'patchNumber': 7,
        'hostSchemaVersion': 1,
        'nativeCapabilities': {'fileTransfer': 2},
      });
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
