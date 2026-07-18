import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _request = PermissionRequestMessage(
  toolUseId: 'tool-1',
  toolName: 'Bash',
  input: {'command': 'pwd'},
);

void main() {
  test('permission observers are optional', () {
    final bridge = BridgeService();
    addTearDown(bridge.dispose);

    bridge.notifyPermissionRequestObserversForTest('session-1', _request);
  });

  test('observers are ordered, isolated, and removable', () {
    final bridge = BridgeService();
    addTearDown(bridge.dispose);
    final calls = <String>[];

    final removeThrowing = bridge.registerPermissionRequestObserver((
      sessionId,
      request,
    ) {
      calls.add('throwing:$sessionId:${request.toolUseId}');
      throw StateError('feature failed');
    });
    final removePassive = bridge.registerPermissionRequestObserver((
      sessionId,
      request,
    ) {
      calls.add('passive');
    });
    final removeConsumer = bridge.registerPermissionRequestObserver((
      sessionId,
      request,
    ) {
      calls.add('consumer');
    });
    bridge.registerPermissionRequestObserver((sessionId, request) {
      calls.add('last');
    });

    bridge.notifyPermissionRequestObserversForTest('session-1', _request);
    expect(calls, ['throwing:session-1:tool-1', 'passive', 'consumer', 'last']);

    calls.clear();
    removeThrowing();
    removeThrowing();
    removePassive();
    removeConsumer();
    bridge.notifyPermissionRequestObserversForTest('session-1', _request);
    expect(calls, ['last']);
  });

  test('each removal callback owns one duplicate registration', () {
    final bridge = BridgeService();
    addTearDown(bridge.dispose);
    final calls = <String>[];

    void duplicate(String sessionId, PermissionRequestMessage request) {
      calls.add('duplicate');
    }

    final removeFirst = bridge.registerPermissionRequestObserver(duplicate);
    final removeSecond = bridge.registerPermissionRequestObserver(duplicate);

    removeSecond();
    bridge.notifyPermissionRequestObserversForTest('session-1', _request);
    expect(calls, ['duplicate']);

    calls.clear();
    removeFirst();
    bridge.notifyPermissionRequestObserversForTest('session-1', _request);
    expect(calls, isEmpty);
  });
}
