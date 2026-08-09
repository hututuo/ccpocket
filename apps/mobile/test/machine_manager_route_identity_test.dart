import 'package:ccpocket/services/machine_manager_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecureStorage implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('legacy API key is shared only after Bridge identity matches', () async {
    final prefs = await SharedPreferences.getInstance();
    final manager = MachineManagerService(prefs, _MemorySecureStorage());
    final lan = await manager.recordConnection(
      host: '192.168.1.10',
      port: 8765,
      apiKey: 'legacy-secret',
    );
    final tailnet = await manager.recordConnection(
      host: '100.64.0.10',
      port: 8765,
    );

    expect(await manager.getApiKey(tailnet.id), isNull);

    await manager.bindBridgeIdentity(
      machineId: lan.id,
      bridgeInstanceId: 'same-bridge',
      codexSourceId: 'same-source',
    );
    await manager.bindBridgeIdentity(
      machineId: tailnet.id,
      bridgeInstanceId: 'same-bridge',
      codexSourceId: 'same-source',
    );

    expect(await manager.getApiKey(tailnet.id), 'legacy-secret');
    manager.dispose();
  });

  test('renaming a computer updates every proven route only', () async {
    final prefs = await SharedPreferences.getInstance();
    final manager = MachineManagerService(prefs, _MemorySecureStorage());
    final lan = await manager.recordConnection(
      host: '192.168.1.10',
      port: 8765,
    );
    final tailnet = await manager.recordConnection(
      host: '100.64.0.10',
      port: 8765,
    );
    final other = await manager.recordConnection(
      host: 'other.local',
      port: 8765,
    );
    for (final route in [lan, tailnet]) {
      await manager.bindBridgeIdentity(
        machineId: route.id,
        bridgeInstanceId: 'same-bridge',
      );
    }

    await manager.renameMachineGroup('legacy:same-bridge', 'Studio Mac');

    expect(manager.getMachine(lan.id)!.name, 'Studio Mac');
    expect(manager.getMachine(tailnet.id)!.name, 'Studio Mac');
    expect(manager.getMachine(other.id)!.name, isNull);
    manager.dispose();
  });
}
