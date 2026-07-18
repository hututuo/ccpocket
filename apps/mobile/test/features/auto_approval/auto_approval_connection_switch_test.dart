import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/auto_approval/auto_approval_service.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'same endpoint machine switch clears stale pending approval before connect',
    () async {
      SharedPreferences.setMockInitialValues({
        AutoApprovalService.preferencesKey: [
          jsonEncode([1, 'machine:machine-b', 'codex', 'thread-1']),
        ],
      });
      final preferences = await SharedPreferences.getInstance();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstSocket = Completer<WebSocket>();
      final secondSocket = Completer<WebSocket>();
      final sockets = <WebSocket>[];
      server.transform(WebSocketTransformer()).listen((socket) {
        sockets.add(socket);
        if (!firstSocket.isCompleted) {
          firstSocket.complete(socket);
        } else if (!secondSocket.isCompleted) {
          secondSocket.complete(socket);
        }
      });

      final outgoing = <Map<String, dynamic>>[];
      final bridge = BridgeService()
        ..onOutgoingMessage = (message) {
          outgoing.add(jsonDecode(message.toJson()) as Map<String, dynamic>);
        };
      final service = AutoApprovalService(
        bridge: bridge,
        preferences: preferences,
      );
      addTearDown(service.dispose);
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
              'claudeSessionId': 'thread-1',
              'status': 'waiting_approval',
              'createdAt': '2026-07-18T00:00:00Z',
              'lastActivityAt': '2026-07-18T00:00:00Z',
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
      expect(bridge.sessions, hasLength(1));
      service.initialize();
      expect(
        outgoing.where((message) => message['type'] == 'approve'),
        isEmpty,
      );

      bridge.connect(url, logicalConnectionIdentity: 'machine:machine-b');
      expect(bridge.sessions, isEmpty);
      await secondSocket.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        outgoing.where((message) => message['type'] == 'approve'),
        isEmpty,
      );
    },
  );
}
