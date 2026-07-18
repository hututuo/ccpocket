import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/codex_goal_request_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('routes legacy unscoped Goal errors to the owning session only', () {
    final router = CodexGoalRequestRouter();
    router.register(ClientMessage.getGoal('session-a'));
    router.register(
      ClientMessage.setGoal(
        sessionId: 'session-b',
        objective: 'Keep B isolated',
      ),
    );

    expect(
      router.route(
        const ErrorMessage(
          message: 'Could not update Goal',
          errorCode: 'goal_set_failed',
        ),
      ),
      'session-b',
    );
    expect(
      router.route(
        const ErrorMessage(
          message: 'Could not read Goal',
          errorCode: 'goal_get_failed',
        ),
      ),
      'session-a',
    );
  });

  test('recognizes pre-Goal Bridge unsupported responses', () {
    final router = CodexGoalRequestRouter();
    router.register(ClientMessage.getGoal('legacy-session'));

    expect(
      router.route(
        const ErrorMessage(
          message: 'get_goal',
          errorCode: 'unsupported_message',
        ),
      ),
      'legacy-session',
    );
  });

  test('keeps explicit session scope authoritative', () {
    final router = CodexGoalRequestRouter();
    router.register(ClientMessage.getGoal('session-a'));
    router.register(ClientMessage.getGoal('session-b'));

    expect(
      router.route(
        const ErrorMessage(
          message: 'Could not read Goal',
          errorCode: 'goal_get_failed',
          sessionId: 'session-b',
        ),
        wireSessionId: 'session-b',
      ),
      'session-b',
    );
    expect(
      router.route(
        const ErrorMessage(
          message: 'Could not read Goal',
          errorCode: 'goal_get_failed',
        ),
      ),
      'session-a',
    );
  });

  test('fails closed for ambiguous unscoped legacy errors', () {
    final router = CodexGoalRequestRouter();
    router.register(ClientMessage.getGoal('session-a'));
    router.register(ClientMessage.getGoal('session-b'));

    expect(
      router.route(
        const ErrorMessage(
          message: 'Could not read Goal',
          errorCode: 'goal_get_failed',
        ),
      ),
      isNull,
    );
    expect(
      router.route(
        const ErrorMessage(
          message: 'Could not read Goal',
          errorCode: 'goal_get_failed',
          sessionId: 'session-b',
        ),
        wireSessionId: 'session-b',
      ),
      'session-b',
    );
    expect(
      router.route(
        const ErrorMessage(
          message: 'Could not read Goal',
          errorCode: 'goal_get_failed',
        ),
      ),
      'session-a',
    );
  });

  test('fails closed for ambiguous unscoped legacy Goal states', () {
    final router = CodexGoalRequestRouter();
    router.register(ClientMessage.getGoal('session-a'));
    router.register(ClientMessage.getGoal('session-b'));

    expect(router.route(const GoalStateMessage(goal: null)), isNull);
  });

  test('expires ambiguous legacy request ownership', () {
    var now = DateTime(2026);
    final router = CodexGoalRequestRouter(
      ttl: const Duration(seconds: 5),
      clock: () => now,
    );
    router.register(ClientMessage.clearGoal('expired-session'));
    now = now.add(const Duration(seconds: 6));

    expect(
      router.route(const ErrorMessage(message: 'Invalid message format')),
      isNull,
    );
  });

  test('correlates Goal state acknowledgements by change id first', () {
    final router = CodexGoalRequestRouter();
    router.register(
      ClientMessage.setGoal(
        sessionId: 'session-a',
        objective: 'A',
        goalChangeId: 'change-a',
      ),
    );
    router.register(
      ClientMessage.setGoal(
        sessionId: 'session-b',
        objective: 'B',
        goalChangeId: 'change-b',
      ),
    );

    expect(
      router.route(
        const GoalStateMessage(goal: null, goalChangeId: 'change-b'),
      ),
      'session-b',
    );
  });

  test(
    'BridgeService scopes Goal-v1 errors and drops unmatched ones',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();
      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });
      final bridge = BridgeService();
      addTearDown(bridge.dispose);
      addTearDown(() => server.close(force: true));
      final sessionA = <ServerMessage>[];
      final sessionB = <ServerMessage>[];
      final subscriptionA = bridge
          .messagesForSession('session-a')
          .listen(sessionA.add);
      final subscriptionB = bridge
          .messagesForSession('session-b')
          .listen(sessionB.add);
      addTearDown(subscriptionA.cancel);
      addTearDown(subscriptionB.cancel);

      bridge.connect('ws://127.0.0.1:${server.port}');
      final socket = await socketReady.future;
      bridge.send(ClientMessage.getGoal('session-a'));
      await socket.firstWhere((data) {
        final json = jsonDecode(data as String) as Map<String, dynamic>;
        return json['type'] == 'get_goal';
      });
      socket.add(
        jsonEncode({
          'type': 'error',
          'message': 'legacy lookup failed',
          'errorCode': 'goal_get_failed',
        }),
      );
      for (var attempt = 0; attempt < 20 && sessionA.isEmpty; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        sessionA.whereType<ErrorMessage>().single.message,
        contains('legacy'),
      );
      expect(sessionB, isEmpty);

      sessionA.clear();
      socket.add(
        jsonEncode({
          'type': 'error',
          'message': 'orphan mutation failure',
          'errorCode': 'goal_set_failed',
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sessionA, isEmpty);
      expect(sessionB, isEmpty);

      socket.add(jsonEncode({'type': 'goal_state', 'goal': null}));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sessionA, isEmpty);
      expect(sessionB, isEmpty);
      await socket.close();
    },
  );
}
