import 'package:ccpocket/services/notification_action_host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a bounded native approval action', () {
    final event =
        NotificationApprovalActionEvent.fromChannelValue(<String, Object>{
          'actionId': 'ccpocket_approve_once_v1',
          'sessionId': 'runtime-session',
          'provider': 'codex',
          'providerSessionId': 'durable-thread',
          'bridgeInstanceId': 'bridge-1',
          'codexSourceId': 'codex-source-1',
          'permissionId': 'opaque-permission',
          'occurredAt': '2026-07-25T01:02:03Z',
        });

    expect(event, isNotNull);
    expect(event?.providerSessionId, 'durable-thread');
    expect(event?.bridgeInstanceId, 'bridge-1');
    expect(event?.codexSourceId, 'codex-source-1');
    expect(event?.bridgeRouteIdentity, isNull);
    expect(event?.occurredAt.isUtc, isTrue);
  });

  test('rejects unknown actions, providers, times, and oversized fields', () {
    final valid = <String, Object>{
      'actionId': 'ccpocket_reject_v1',
      'sessionId': 'runtime-session',
      'provider': 'claude',
      'permissionId': 'opaque-permission',
      'occurredAt': '2026-07-25T01:02:03Z',
    };

    for (final invalid in <Map<String, Object>>[
      <String, Object>{...valid, 'actionId': 'approve_forever'},
      <String, Object>{...valid, 'provider': 'other'},
      <String, Object>{...valid, 'occurredAt': 'not-a-time'},
      <String, Object>{
        ...valid,
        'sessionId': List<String>.filled(257, 'x').join(),
      },
    ]) {
      expect(NotificationApprovalActionEvent.fromChannelValue(invalid), isNull);
    }
  });
}
