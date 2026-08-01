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
    expect(event?.usesCodexActionBroker, isFalse);
  });

  test('parses a complete Codex Action Broker v2 action fence', () {
    final event =
        NotificationApprovalActionEvent.fromChannelValue(<String, Object>{
          'actionId': 'ccpocket_approve_once_v1',
          'actionPayloadVersion': '2',
          'sessionId': 'thread-1',
          'provider': 'codex',
          'providerSessionId': 'thread-1',
          'bridgeInstanceId': 'bridge-1',
          'codexSourceId': 'source-1',
          'opaqueRequestId': 'opaque-1',
          'threadId': 'thread-1',
          'turnId': 'turn-1',
          'authorityGeneration': 'cab:1:7',
          'allowedActions': 'approve,reject',
          'occurredAt': '2026-07-25T01:02:03Z',
        });

    expect(event?.usesCodexActionBroker, isTrue);
    expect(event?.permissionId, 'opaque-1');
    expect(event?.threadId, 'thread-1');
    expect(event?.turnId, 'turn-1');
    expect(event?.authorityGeneration, 'cab:1:7');
    expect(event?.allowedActions, {'approve', 'reject'});
  });

  test('rejects incomplete or cross-provider Codex broker actions', () {
    final valid = <String, Object>{
      'actionId': 'ccpocket_reject_v1',
      'actionPayloadVersion': 2,
      'sessionId': 'thread-1',
      'provider': 'codex',
      'bridgeInstanceId': 'bridge-1',
      'codexSourceId': 'source-1',
      'opaqueRequestId': 'opaque-1',
      'threadId': 'thread-1',
      'turnId': 'turn-1',
      'authorityGeneration': 'cab:1:7',
      'allowedActions': 'approve,reject',
      'occurredAt': '2026-07-25T01:02:03Z',
    };
    for (final invalid in <Map<String, Object>>[
      <String, Object>{...valid}..remove('turnId'),
      <String, Object>{...valid, 'provider': 'claude'},
      <String, Object>{...valid, 'allowedActions': 'answer'},
      <String, Object>{...valid, 'allowedActions': 'approve,delete'},
      <String, Object>{...valid, 'actionPayloadVersion': 3},
    ]) {
      expect(NotificationApprovalActionEvent.fromChannelValue(invalid), isNull);
    }
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
