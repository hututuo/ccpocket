import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes strict Bridge-owned state', () {
    final message = ServerMessage.fromJson({
      'type': 'auto_approval_state_v1',
      'sessionId': 'runtime-1',
      'requestId': 'request-1',
      'providerSessionId': 'thread-1',
      'enabled': true,
      'enabledConversationCount': 2,
      'approvedCount': 3,
      'reason': 'auto_approved',
    });

    expect(message, isA<AutoApprovalStateMessage>());
    expect(
      message,
      isA<AutoApprovalStateMessage>()
          .having((value) => value.sessionId, 'sessionId', 'runtime-1')
          .having((value) => value.enabled, 'enabled', isTrue)
          .having((value) => value.approvedCount, 'approvedCount', 3),
    );
  });

  test('rejects unbounded or extended state payloads', () {
    expect(
      () => ServerMessage.fromJson({
        'type': 'auto_approval_state_v1',
        'sessionId': 'runtime-1',
        'enabledConversationCount': 0,
        'reason': 'query',
        'unexpected': true,
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        'type': 'auto_approval_state_v1',
        'sessionId': 'runtime-1',
        'enabledConversationCount': 4097,
        'reason': 'query',
      }),
      throwsFormatException,
    );
  });

  test(
    'builds ephemeral state, toggle, import, and emergency-stop requests',
    () {
      final requests = [
        requestAutoApprovalState(sessionId: 'runtime-1', requestId: 'get-1'),
        requestSetAutoApproval(
          sessionId: 'runtime-1',
          requestId: 'set-1',
          enabled: true,
        ),
        requestImportLegacyAutoApprovals(
          sessionId: 'bridge-auto-approval',
          requestId: 'import-1',
          providerSessionIds: const ['thread-1', 'thread-1'],
        ),
        requestDisableAllAutoApprovals(
          sessionId: 'bridge-auto-approval',
          requestId: 'disable-1',
        ),
      ];

      expect(
        requests.every(
          (request) => request.delivery == ClientMessageDelivery.ephemeral,
        ),
        isTrue,
      );
      expect(jsonDecode(requests[0].toJson()), {
        'type': 'get_auto_approval_state',
        'sessionId': 'runtime-1',
        'requestId': 'get-1',
      });
      expect(jsonDecode(requests[1].toJson()), {
        'type': 'set_auto_approval',
        'sessionId': 'runtime-1',
        'requestId': 'set-1',
        'enabled': true,
      });
      expect(jsonDecode(requests[2].toJson()), {
        'type': 'import_legacy_auto_approvals',
        'sessionId': 'bridge-auto-approval',
        'requestId': 'import-1',
        'providerSessionIds': ['thread-1'],
      });
    },
  );
}
