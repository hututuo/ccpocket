import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('durable Bridge and Codex identities survive endpoint changes', () {
    final first = BridgeDataSourceIdentity.fromConnection(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-source-a',
      websocketUrl: 'wss://first.example/ws?token=secret',
    );
    final second = BridgeDataSourceIdentity.fromConnection(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-source-a',
      websocketUrl: 'wss://second.example/ws?token=other-secret',
    );

    expect(
      first.scopeKeyForProvider('codex'),
      second.scopeKeyForProvider('codex'),
    );
    expect(first.matchesRequest(second, provider: 'codex'), isTrue);
    expect(
      first.notificationDiscriminatorForProvider('codex'),
      second.notificationDiscriminatorForProvider('codex'),
    );
  });

  test('Codex sources remain isolated on the same Bridge', () {
    const first = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-source-a',
    );
    const second = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-source-b',
    );

    expect(first.matchesRequest(second, provider: 'codex'), isFalse);
    expect(
      first.scopeKeyForProvider('codex'),
      isNot(second.scopeKeyForProvider('codex')),
    );
    expect(first.matchesRequest(second, provider: 'claude'), isTrue);
    expect(
      first.scopeKeyForProvider('claude'),
      second.scopeKeyForProvider('claude'),
    );
  });

  test('legacy routes omit credentials and remain locally scoped', () {
    final identity = BridgeDataSourceIdentity.fromConnection(
      websocketUrl: 'wss://Bridge.EXAMPLE/ws?token=do-not-persist',
    );

    expect(
      identity.scopeKeyForProvider('codex'),
      'url:wss://bridge.example:443/ws',
    );
    expect(identity.scopeKeyForProvider('codex'), isNot(contains('token')));
    expect(identity.scopeKeyForProvider('codex'), isNot(contains('persist')));
  });

  test('scoped payloads fail closed but legacy payloads remain compatible', () {
    const expected = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-source-a',
    );
    const current = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-source-b',
    );

    expect(expected.isSatisfiedBy(current, provider: 'codex'), isFalse);
    expect(
      BridgeDataSourceIdentity.unscoped.isSatisfiedBy(
        current,
        provider: 'codex',
      ),
      isTrue,
    );
  });
}
