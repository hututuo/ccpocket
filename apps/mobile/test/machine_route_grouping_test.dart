import 'package:ccpocket/models/machine.dart';
import 'package:flutter_test/flutter_test.dart';

MachineWithStatus route({
  required String id,
  required String host,
  String? signedId,
  String? bridgeInstanceId,
  String? computerName,
  String? name,
  MachineStatus status = MachineStatus.online,
  int? latencyMs,
  DateTime? lastConnected,
}) {
  return MachineWithStatus(
    machine: Machine(
      id: id,
      host: host,
      name: name,
      bridgeIdentityId: signedId,
      bridgeInstanceId: bridgeInstanceId,
      bridgeComputerName: computerName,
      lastConnected: lastConnected,
    ),
    status: status,
    latencyMs: latencyMs,
  );
}

void main() {
  test('signed Bridge identity groups LAN and Tailnet routes', () {
    final groups = groupBridgeMachineRoutes([
      route(
        id: 'lan',
        host: '192.168.1.10',
        signedId: 'bridge_key_1',
        computerName: 'Studio Mac',
        latencyMs: 8,
      ),
      route(
        id: 'tailnet',
        host: '100.64.0.10',
        signedId: 'bridge_key_1',
        computerName: 'Studio Mac',
        latencyMs: 32,
      ),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.routes, hasLength(2));
    expect(groups.single.displayName, 'Studio Mac');
    expect(groups.single.preferredRoute.machine.id, 'lan');
  });

  test(
    'legacy authenticated identity groups routes without signed identity',
    () {
      final groups = groupBridgeMachineRoutes([
        route(
          id: 'lan',
          host: '192.168.1.10',
          bridgeInstanceId: 'legacy-bridge',
        ),
        route(
          id: 'tailnet',
          host: '100.64.0.10',
          bridgeInstanceId: 'legacy-bridge',
        ),
      ]);

      expect(groups, hasLength(1));
    },
  );

  test('unproven endpoints never merge by name or address similarity', () {
    final groups = groupBridgeMachineRoutes([
      route(id: 'first', host: 'mac.local', name: 'My Mac'),
      route(id: 'second', host: '192.168.1.10', name: 'My Mac'),
    ]);

    expect(groups, hasLength(2));
  });

  test('identity conflict blocks aggregate online state', () {
    final groups = groupBridgeMachineRoutes([
      route(id: 'first', host: 'mac.local', signedId: 'bridge_key_1'),
      route(
        id: 'second',
        host: '192.168.1.10',
        signedId: 'bridge_key_1',
        status: MachineStatus.identityChanged,
      ),
    ]);

    expect(groups.single.status, MachineStatus.identityChanged);
    expect(groups.single.hasOnlineRoute, isTrue);
  });

  test(
    'preferred route uses latency then recency and stable endpoint order',
    () {
      final groups = groupBridgeMachineRoutes([
        route(
          id: 'older-fast',
          host: '192.168.1.10',
          signedId: 'bridge_key_1',
          latencyMs: 5,
          lastConnected: DateTime.utc(2026, 1, 1),
        ),
        route(
          id: 'newer-slow',
          host: '100.64.0.10',
          signedId: 'bridge_key_1',
          latencyMs: 30,
          lastConnected: DateTime.utc(2026, 8, 1),
        ),
      ]);

      expect(groups.single.preferredRoute.machine.id, 'older-fast');
    },
  );
}
