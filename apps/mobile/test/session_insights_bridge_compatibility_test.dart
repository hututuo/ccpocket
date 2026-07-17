import 'dart:async';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final sent = <ClientMessage>[];

  @override
  void sendEphemeralRpc(ClientMessage message) => sent.add(message);
}

void main() {
  test('real insights requests isolate old Bridge errors end to end', () async {
    final bridge = _Bridge();
    addTearDown(bridge.dispose);
    final local = <LocalFeatureServerMessage>[];
    final global = <ServerMessage>[];
    final tagged = <ServerMessage>[];
    final subscriptions = <StreamSubscription<dynamic>>[
      bridge.localFeatureMessagesForSession('s1').listen(local.add),
      bridge.messages.listen(global.add),
      bridge.messagesForSession('s1').listen(tagged.add),
    ];
    addTearDown(() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    });

    bridge.send(requestContextUsage('s1'));
    bridge.send(requestSessionUsage(sessionId: 's1', requestId: 'usage-1'));
    expect(bridge.sent.map((message) => message.type), [
      'get_context_usage',
      'get_session_usage',
    ]);
    expect(
      bridge.consumeLocalFeatureInfrastructureMessageForTest(
        const ErrorMessage(
          message: 'get_context_usage',
          errorCode: 'unsupported_message',
        ),
      ),
      isTrue,
    );
    expect(
      bridge.consumeLocalFeatureInfrastructureMessageForTest(
        const ErrorMessage(
          message: 'get_session_usage',
          errorCode: 'unsupported_message',
        ),
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);

    expect(global, isEmpty);
    expect(tagged, isEmpty);
    expect(
      local.whereType<LocalFeatureRequestErrorMessage>().map(
        (message) => (message.requestType, message.requestId),
      ),
      [('get_context_usage', null), ('get_session_usage', 'usage-1')],
    );
    expect(bridge.pendingLocalFeatureRequestsForTest, isEmpty);
  });
}
