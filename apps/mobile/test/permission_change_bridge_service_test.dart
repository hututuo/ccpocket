import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _CapturingBridgeService extends BridgeService {
  _CapturingBridgeService({
    required super.permissionChangeTimeout,
    this.failSend = false,
  });

  final bool failSend;
  final List<ClientMessage> sentMessages = [];

  @override
  void sendEphemeralRpc(ClientMessage message) {
    if (failSend) throw StateError('socket closed');
    sentMessages.add(message);
  }
}

void main() {
  test('permission change timeout emits a correlated session error', () async {
    final bridge = _CapturingBridgeService(
      permissionChangeTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(bridge.dispose);
    final errorFuture = bridge
        .messagesForSession('s1')
        .where((message) => message is ErrorMessage)
        .cast<ErrorMessage>()
        .first;

    bridge.send(
      ClientMessage.setSessionMode(
        legacyMode: 'acceptEdits',
        codexPermissionsMode: 'autoReview',
        applyStrategy: CodexPermissionApplyStrategy.nextTurn,
        permissionChangeId: 'permission-change-timeout',
        sessionId: 's1',
      ),
    );

    final error = await errorFuture.timeout(const Duration(seconds: 1));
    expect(bridge.sentMessages, hasLength(1));
    expect(error.errorCode, 'set_permission_mode_rejected');
    expect(error.sessionId, 's1');
    expect(error.permissionChangeId, 'permission-change-timeout');
  });

  test(
    'synchronous live-only send failure does not leave a timeout behind',
    () async {
      final bridge = _CapturingBridgeService(
        permissionChangeTimeout: const Duration(milliseconds: 20),
        failSend: true,
      );
      addTearDown(bridge.dispose);
      final received = <ServerMessage>[];
      final subscription = bridge.messagesForSession('s1').listen(received.add);
      addTearDown(subscription.cancel);

      expect(
        () => bridge.send(
          ClientMessage.setSessionMode(
            legacyMode: 'acceptEdits',
            codexPermissionsMode: 'autoReview',
            applyStrategy: CodexPermissionApplyStrategy.restartNow,
            permissionChangeId: 'permission-change-send-failure',
            sessionId: 's1',
          ),
        ),
        throwsStateError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(received, isEmpty);
    },
  );

  test(
    'same-identity reconnect does not publish cached sessions as authoritative',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstSocket = Completer<WebSocket>();
      final secondSocket = Completer<WebSocket>();
      server.transform(WebSocketTransformer()).listen((socket) {
        if (!firstSocket.isCompleted) {
          firstSocket.complete(socket);
        } else if (!secondSocket.isCompleted) {
          secondSocket.complete(socket);
        }
      });

      final bridge = BridgeService();
      final publishedSessions = <List<SessionInfo>>[];
      final subscription = bridge.sessionList.listen(publishedSessions.add);
      addTearDown(subscription.cancel);
      addTearDown(bridge.dispose);
      addTearDown(() => server.close(force: true));

      final url = 'ws://127.0.0.1:${server.port}';
      bridge.connect(url, logicalConnectionIdentity: 'machine:machine-a');
      final oldSocket = await firstSocket.future;
      oldSocket.add(
        jsonEncode({
          'type': 'session_list',
          'sessions': [
            {
              'id': 'runtime-old',
              'provider': 'codex',
              'projectPath': '/tmp/project',
              'status': 'waiting_approval',
              'createdAt': '2026-07-18T00:00:00Z',
              'lastActivityAt': '2026-07-18T00:00:00Z',
              'codexPermissionApplyStrategySupported': true,
              'pendingPermission': {
                'toolUseId': 'old-tool',
                'toolName': 'Bash',
                'input': {'command': 'pwd'},
              },
            },
          ],
        }),
      );
      for (
        var attempt = 0;
        attempt < 20 && bridge.sessions.isEmpty;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(bridge.sessions.single.id, 'runtime-old');
      expect(
        bridge.sessions.single.codexPermissionApplyStrategySupported,
        isTrue,
      );
      publishedSessions.clear();

      bridge.connect(url, logicalConnectionIdentity: 'machine:machine-a');
      final newSocket = await secondSocket.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        bridge.sessions.single.codexPermissionApplyStrategySupported,
        isFalse,
      );
      expect(publishedSessions, isEmpty);

      newSocket.add(
        jsonEncode({
          'type': 'session_list',
          'sessions': [
            {
              'id': 'runtime-new',
              'provider': 'codex',
              'projectPath': '/tmp/project',
              'status': 'idle',
              'createdAt': '2026-07-18T00:01:00Z',
              'lastActivityAt': '2026-07-18T00:01:00Z',
            },
          ],
        }),
      );
      for (
        var attempt = 0;
        attempt < 20 && publishedSessions.isEmpty;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(publishedSessions, hasLength(1));
      expect(publishedSessions.single.single.id, 'runtime-new');
    },
  );
}
