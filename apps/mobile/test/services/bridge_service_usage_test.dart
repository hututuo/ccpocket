import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/models/offline_pending_action.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _offlinePendingMessagesV1Key = 'bridge_offline_pending_messages_v1';
const _offlinePendingMessagesV2Key = 'bridge_offline_pending_messages_v2';

Map<String, dynamic> _offlineEnvelopeMessage(String raw) {
  final envelope = jsonDecode(raw) as Map<String, dynamic>;
  return Map<String, dynamic>.from(envelope['message'] as Map);
}

Map<String, dynamic>? _offlineEnvelopeTarget(String raw) {
  final envelope = jsonDecode(raw) as Map<String, dynamic>;
  final target = envelope['target'];
  return target is Map ? Map<String, dynamic>.from(target) : null;
}

String _offlineEnvelope({
  required Map<String, dynamic> message,
  required String routeIdentity,
  required String bridgeInstanceId,
  required String codexSourceId,
}) {
  return jsonEncode({
    'version': 2,
    'message': message,
    'target': {
      'routeIdentity': routeIdentity,
      'bridgeInstanceId': bridgeInstanceId,
      'codexSourceId': codexSourceId,
    },
  });
}

Future<void> _waitForBridgeConnection(BridgeService bridge) async {
  if (bridge.currentBridgeConnectionState == BridgeConnectionState.connected) {
    return;
  }
  await bridge.connectionStatus
      .firstWhere((state) => state == BridgeConnectionState.connected)
      .timeout(const Duration(seconds: 2));
}

Future<void> _authorizeLegacyBridge(
  BridgeService bridge,
  WebSocket socket,
) async {
  final previousGeneration = bridge.authoritativeSessionListGeneration;
  socket.add(jsonEncode({'type': 'session_list', 'sessions': const []}));
  for (var attempt = 0; attempt < 100; attempt++) {
    if (bridge.authoritativeSessionListGeneration > previousGeneration) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TimeoutException(
    'Bridge did not publish an authoritative session list',
  );
}

Future<void> _authorizeBridgeIdentity(
  BridgeService bridge,
  WebSocket socket, {
  required String bridgeInstanceId,
  required String codexSourceId,
  List<String> bridgeCapabilities = const [],
}) async {
  final previousGeneration = bridge.authoritativeSessionListGeneration;
  socket.add(
    jsonEncode({
      'type': 'session_list',
      'sessions': const [],
      'bridgeInstanceId': bridgeInstanceId,
      'codexSourceId': codexSourceId,
      'bridgeCapabilities': bridgeCapabilities,
    }),
  );
  for (var attempt = 0; attempt < 100; attempt++) {
    if (bridge.authoritativeSessionListGeneration > previousGeneration &&
        bridge.bridgeInstanceId == bridgeInstanceId &&
        bridge.codexSourceId == codexSourceId) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TimeoutException('Bridge did not publish the expected identity');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BridgeService usage cache', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test(
      'transport failures use reconnect state without chat errors',
      () async {
        final closedServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final port = closedServer.port;
        await closedServer.close(force: true);

        final bridge = BridgeService();
        final messages = <ServerMessage>[];
        final connectionStates = <BridgeConnectionState>[];
        final reconnecting = Completer<void>();
        final subscription = bridge.messages.listen(messages.add);
        final connectionSubscription = bridge.connectionStatus.listen((state) {
          connectionStates.add(state);
          if (state == BridgeConnectionState.reconnecting &&
              !reconnecting.isCompleted) {
            reconnecting.complete();
          }
        });

        bridge.connect('ws://127.0.0.1:$port');
        await reconnecting.future.timeout(const Duration(seconds: 5));

        expect(
          messages.whereType<ErrorMessage>().where(
            (message) =>
                message.message.startsWith('WebSocket error:') ||
                message.message.startsWith('Connection failed:'),
          ),
          isEmpty,
        );
        expect(
          connectionStates,
          isNot(contains(BridgeConnectionState.connected)),
        );
        expect(
          bridge.currentBridgeConnectionState,
          BridgeConnectionState.reconnecting,
        );

        bridge.disconnect();
        await subscription.cancel();
        await connectionSubscription.cancel();
        bridge.dispose();
      },
    );

    test('disconnect clears last usage result cache', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final socketReady = Completer<void>();

      server.transform(WebSocketTransformer()).listen((socket) {
        sockets.add(socket);
        socket.add(
          jsonEncode({
            'type': 'usage_result',
            'providers': [
              {
                'provider': 'codex',
                'fiveHour': {
                  'utilization': 0.08,
                  'resetsAt': '2026-04-12T10:19:42Z',
                },
              },
            ],
          }),
        );
        socketReady.complete();
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');

      await socketReady.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.lastUsageResult, isNotNull);

      bridge.disconnect();

      expect(bridge.lastUsageResult, isNull);

      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
      bridge.dispose();
    });

    test('disconnect clears bridge-scoped metadata caches', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final socketReady = Completer<void>();

      server.transform(WebSocketTransformer()).listen((socket) {
        sockets.add(socket);
        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': [],
            'allowedDirs': ['/old-bridge'],
            'claudeModels': ['sonnet'],
            'codexModels': ['gpt-5.2'],
            'codexProfiles': ['old-profile'],
            'defaultCodexProfile': 'old-profile',
            'bridgeVersion': '1.2.3',
            'clientBridgeCompatibilityRevision': 3,
          }),
        );
        socket.add(
          jsonEncode({
            'type': 'project_history',
            'projects': ['/old-bridge/project'],
          }),
        );
        socketReady.complete();
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');

      await socketReady.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.allowedDirs, ['/old-bridge']);
      expect(bridge.projectHistory, ['/old-bridge/project']);
      expect(bridge.codexProfiles, ['old-profile']);
      expect(bridge.bridgeVersion, '1.2.3');
      expect(bridge.clientBridgeCompatibilityRevision, 3);

      bridge.disconnect();

      expect(bridge.allowedDirs, isEmpty);
      expect(bridge.projectHistory, isEmpty);
      expect(bridge.codexProfiles, isEmpty);
      expect(bridge.bridgeVersion, isNull);
      expect(bridge.clientBridgeCompatibilityRevision, isNull);

      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
      bridge.dispose();
    });

    test('correlated catalog responses ignore superseded queries', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();
      server.transform(WebSocketTransformer()).listen(socketReady.complete);

      final outgoing = <ClientMessage>[];
      final responses = <RecentSessionsMessage>[];
      final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
      final responseSubscription = bridge.recentSessionResponses.listen(
        responses.add,
      );
      bridge.connect('ws://127.0.0.1:${server.port}');
      final socket = await socketReady.future;
      socket.add(
        jsonEncode({
          'type': 'session_list',
          'bridgeInstanceId': 'bridge-a',
          'sessions': [],
          'bridgeCapabilities': [sessionCatalogRequestCorrelationCapability],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      bridge.requestRecentSessionsCatalog();
      final warmRequest = outgoing
          .map(
            (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
          )
          .singleWhere((message) => message['type'] == 'list_recent_sessions');
      expect(warmRequest['requestScope'], 'catalog');
      expect(warmRequest['limit'], 1000);
      outgoing.clear();

      bridge.switchFilter(searchQuery: 'old');
      bridge.switchFilter(searchQuery: 'new');
      final requests = outgoing
          .map(
            (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
          )
          .where((message) => message['type'] == 'list_recent_sessions')
          .toList();
      expect(requests, hasLength(2));
      final oldRequest = requests.first;
      final newRequest = requests.last;
      expect(bridge.bridgeInstanceId, 'bridge-a');

      Map<String, dynamic> session(String id, String prompt) => {
        'sessionId': id,
        'provider': 'codex',
        'firstPrompt': prompt,
        'created': '2026-07-26T00:00:00Z',
        'modified': '2026-07-26T00:00:01Z',
        'gitBranch': '',
        'projectPath': '/project',
        'isSidechain': false,
      };

      void sendResponse(
        Map<String, dynamic> request,
        String id,
        String prompt,
      ) {
        socket.add(
          jsonEncode({
            'type': 'recent_sessions',
            'sessions': [session(id, prompt)],
            'hasMore': false,
            'limit': request['limit'],
            'offset': request['offset'],
            'projectPath': request['projectPath'],
            'requestScope': request['requestScope'],
            'requestId': request['requestId'],
            'queryGeneration': request['queryGeneration'],
            'catalogRevision': 9,
            'provider': request['provider'],
            'namedOnly': request['namedOnly'],
            'searchQuery': request['searchQuery'],
          }),
        );
      }

      sendResponse(newRequest, 'new-session', 'new result');
      sendResponse(oldRequest, 'old-session', 'stale result');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(bridge.recentSessions.single.sessionId, 'new-session');
      expect(responses, hasLength(1));
      expect(responses.single.searchQuery, 'new');

      bridge.disconnect();
      await responseSubscription.cancel();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test(
      'same-target reconnect does not reuse an old catalog as authoritative',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final acceptedSockets = StreamController<WebSocket>();
        final sockets = <WebSocket>[];
        server.transform(WebSocketTransformer()).listen((socket) {
          sockets.add(socket);
          acceptedSockets.add(socket);
        });
        final socketIterator = StreamIterator(acceptedSockets.stream);

        final outgoing = <ClientMessage>[];
        final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
        final url = 'ws://127.0.0.1:${server.port}';
        bridge.connect(url);
        expect(await socketIterator.moveNext(), isTrue);
        final firstSocket = socketIterator.current;
        firstSocket.add(
          jsonEncode({
            'type': 'session_list',
            'bridgeInstanceId': 'bridge-a',
            'sessions': [],
            'bridgeCapabilities': [sessionCatalogRequestCorrelationCapability],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        bridge.requestRecentSessions();
        final request = outgoing
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .lastWhere((message) => message['type'] == 'list_recent_sessions');
        firstSocket.add(
          jsonEncode({
            'type': 'recent_sessions',
            'sessions': const [],
            'hasMore': false,
            'limit': request['limit'],
            'offset': request['offset'],
            'projectPath': request['projectPath'],
            'requestScope': request['requestScope'],
            'requestId': request['requestId'],
            'queryGeneration': request['queryGeneration'],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          bridge.hasAuthoritativeRecentSessionsForCurrentConnection,
          isTrue,
        );

        final reconnected = bridge.connectionStatus.firstWhere(
          (state) => state == BridgeConnectionState.connected,
        );
        bridge.connect(url);
        expect(await socketIterator.moveNext(), isTrue);
        await reconnected.timeout(const Duration(seconds: 2));

        expect(
          bridge.hasAuthoritativeRecentSessionsForCurrentConnection,
          isFalse,
        );

        bridge.disconnect();
        await socketIterator.cancel();
        await acceptedSockets.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'same-target reconnect resends a stale in-flight history delta',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final acceptedSockets = StreamController<WebSocket>();
        final sockets = <WebSocket>[];
        server.transform(WebSocketTransformer()).listen((socket) {
          sockets.add(socket);
          acceptedSockets.add(socket);
        });
        final socketIterator = StreamIterator(acceptedSockets.stream);

        final outgoing = <ClientMessage>[];
        final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
        final url = 'ws://127.0.0.1:${server.port}';
        bridge.connect(url);
        expect(await socketIterator.moveNext(), isTrue);
        final firstSocket = socketIterator.current;
        firstSocket.add(
          jsonEncode({
            'type': 'status',
            'status': 'running',
            'sessionId': 's1',
            'historySeq': 1,
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        bridge.requestSessionHistoryDeltaOnly('s1');
        expect(
          outgoing
              .map(
                (message) =>
                    jsonDecode(message.toJson()) as Map<String, dynamic>,
              )
              .where((message) => message['type'] == 'get_history_delta'),
          hasLength(1),
        );

        final reconnected = bridge.connectionStatus.firstWhere(
          (state) => state == BridgeConnectionState.connected,
        );
        bridge.connect(url);
        expect(await socketIterator.moveNext(), isTrue);
        await reconnected.timeout(const Duration(seconds: 2));

        bridge.requestSessionHistoryDeltaOnly('s1');
        expect(
          outgoing
              .map(
                (message) =>
                    jsonDecode(message.toJson()) as Map<String, dynamic>,
              )
              .where((message) => message['type'] == 'get_history_delta'),
          hasLength(2),
        );

        bridge.disconnect();
        await socketIterator.cancel();
        await acceptedSockets.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'legacy catalog requests serialize and discard stale results',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen(socketReady.complete);

        final outgoing = <ClientMessage>[];
        final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': [],
            'bridgeCapabilities': const <String>[],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        bridge.switchFilter(searchQuery: 'old');
        bridge.switchFilter(searchQuery: 'new');
        List<Map<String, dynamic>> requests() => outgoing
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .where((message) => message['type'] == 'list_recent_sessions')
            .toList();
        expect(requests(), hasLength(1));
        expect(requests().single['searchQuery'], 'old');

        Map<String, dynamic> response(String id, String prompt) => {
          'type': 'recent_sessions',
          'sessions': [
            {
              'sessionId': id,
              'provider': 'codex',
              'firstPrompt': prompt,
              'created': '2026-07-26T00:00:00Z',
              'modified': '2026-07-26T00:00:01Z',
              'gitBranch': '',
              'projectPath': '/project',
              'isSidechain': false,
            },
          ],
          'hasMore': false,
        };

        socket.add(jsonEncode(response('old-session', 'stale result')));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(bridge.recentSessions, isEmpty);
        expect(requests(), hasLength(2));
        expect(requests().last['searchQuery'], 'new');

        socket.add(jsonEncode(response('new-session', 'new result')));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(bridge.recentSessions.single.sessionId, 'new-session');
        expect(bridge.lastRecentSessionsMessage?.searchQuery, 'new');

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'catalog invalidation refreshes a bounded metadata window without activating sessions',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final outgoing = <ClientMessage>[];
        final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': [],
            'bridgeCapabilities': [sessionCatalogWatchCapability],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        bridge.requestRecentSessions();
        socket.add(
          jsonEncode({
            'type': 'recent_sessions',
            'sessions': [
              {
                'sessionId': 'shared-id',
                'provider': 'claude',
                'firstPrompt': 'Claude old',
                'created': '2026-07-25T00:00:00Z',
                'modified': '2026-07-25T00:00:01Z',
                'gitBranch': '',
                'projectPath': '/project',
                'isSidechain': false,
              },
              {
                'sessionId': 'shared-id',
                'provider': 'codex',
                'firstPrompt': 'Codex old',
                'created': '2026-07-25T00:00:00Z',
                'modified': '2026-07-25T00:00:02Z',
                'gitBranch': '',
                'projectPath': '/project',
                'isSidechain': false,
              },
              {
                'sessionId': 'removed-id',
                'provider': 'codex',
                'firstPrompt': 'Removed',
                'created': '2026-07-25T00:00:00Z',
                'modified': '2026-07-25T00:00:00Z',
                'gitBranch': '',
                'projectPath': '/project',
                'isSidechain': false,
              },
            ],
            'hasMore': false,
            'limit': 20,
            'offset': 0,
            'requestScope': 'list',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(bridge.recentSessions, hasLength(3));
        outgoing.clear();

        socket.add(
          jsonEncode({
            'type': sessionCatalogChangedMessageType,
            'revision': 1,
            'occurredAt': '2026-07-25T00:00:03Z',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final catalogRequests = outgoing
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .where((message) => message['type'] == 'list_recent_sessions')
            .toList();
        expect(catalogRequests, hasLength(1));
        expect(catalogRequests.single, containsPair('requestScope', 'catalog'));
        expect(catalogRequests.single, containsPair('limit', 20));
        expect(
          outgoing.any((message) => message.type == 'resume_session'),
          isFalse,
        );

        socket.add(
          jsonEncode({
            'type': 'recent_sessions',
            'sessions': [
              {
                'sessionId': 'shared-id',
                'provider': 'codex',
                'firstPrompt': 'Codex updated',
                'created': '2026-07-25T00:00:00Z',
                'modified': '2026-07-25T00:00:04Z',
                'gitBranch': '',
                'projectPath': '/project',
                'isSidechain': false,
              },
              {
                'sessionId': 'shared-id',
                'provider': 'claude',
                'firstPrompt': 'Claude updated',
                'created': '2026-07-25T00:00:00Z',
                'modified': '2026-07-25T00:00:03Z',
                'gitBranch': '',
                'projectPath': '/project',
                'isSidechain': false,
              },
            ],
            'hasMore': false,
            'limit': 20,
            'offset': 0,
            'requestScope': 'catalog',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(
          bridge.recentSessions.map(
            (session) => '${session.provider}:${session.sessionId}',
          ),
          ['codex:shared-id', 'claude:shared-id'],
        );
        expect(bridge.recentSessions.map((session) => session.firstPrompt), [
          'Codex updated',
          'Claude updated',
        ]);
        expect(bridge.recentSessionsHasMore, isFalse);

        outgoing.clear();
        socket.add(
          jsonEncode({'type': sessionCatalogChangedMessageType, 'revision': 1}),
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(outgoing, isEmpty);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'a complete catalog refresh removes stale entries beyond the old prefix',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        Map<String, Object?> sessionJson(int index) => {
          'sessionId': 'session-$index',
          'provider': 'codex',
          'firstPrompt': 'Session $index',
          'created': '2026-07-25T00:00:00Z',
          'modified': '2026-07-25T00:00:00Z',
          'gitBranch': '',
          'projectPath': '/project',
          'isSidechain': false,
        };

        final outgoing = <ClientMessage>[];
        final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': [],
            'bridgeCapabilities': [sessionCatalogWatchCapability],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        bridge.requestRecentSessions(limit: 201);
        socket.add(
          jsonEncode({
            'type': 'recent_sessions',
            'sessions': List.generate(201, sessionJson),
            'hasMore': false,
            'limit': 201,
            'offset': 0,
            'requestScope': 'list',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(bridge.recentSessions, hasLength(201));
        outgoing.clear();

        socket.add(
          jsonEncode({
            'type': sessionCatalogChangedMessageType,
            'revision': 1,
            'occurredAt': '2026-07-25T00:00:03Z',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final refresh = outgoing
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .firstWhere(
              (message) =>
                  message['type'] == 'list_recent_sessions' &&
                  message['requestScope'] == 'catalog',
            );
        expect(refresh['limit'], 200);

        socket.add(
          jsonEncode({
            'type': 'recent_sessions',
            'sessions': List.generate(199, sessionJson),
            'hasMore': false,
            'limit': 200,
            'offset': 0,
            'requestScope': 'catalog',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(bridge.recentSessions, hasLength(199));
        expect(bridge.recentSessionsHasMore, isFalse);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'tool activity stays separate from assistant ordering checkpoints',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final bridge = BridgeService();
        final published = <List<SessionInfo>>[];
        final subscription = bridge.sessionList.listen(
          (sessions) => published.add(List<SessionInfo>.from(sessions)),
        );
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': [
              {
                'id': 's1',
                'provider': 'codex',
                'claudeSessionId': 'thread-1',
                'projectPath': '/tmp/project',
                'status': 'running',
                'createdAt': '2026-07-25T00:00:00Z',
                'lastActivityAt': '2026-07-25T00:00:00Z',
              },
            ],
          }),
        );
        for (var i = 0; i < 30 && published.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        socket.add(
          jsonEncode({
            'type': 'status',
            'sessionId': 's1',
            'status': 'running',
            'activityAt': '2026-07-25T00:00:05Z',
          }),
        );
        for (
          var i = 0;
          i < 30 &&
              bridge.sessions.single.lastActivityAt !=
                  '2026-07-25T00:00:05.000Z';
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          bridge.sessions.single.lastActivityAt,
          '2026-07-25T00:00:05.000Z',
        );
        final afterFirstActivity = published.length;

        socket.add(
          jsonEncode({
            'type': 'stream_delta',
            'sessionId': 's1',
            'text': 'small follow-up',
            'activityAt': '2026-07-25T00:00:05.500Z',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(published, hasLength(afterFirstActivity));
        expect(
          bridge.sessions.single.lastActivityAt,
          '2026-07-25T00:00:05.000Z',
        );

        socket.add(
          jsonEncode({
            'type': 'thinking_delta',
            'sessionId': 's1',
            'text': 'later update',
            'activityAt': '2026-07-25T00:00:07Z',
          }),
        );
        for (
          var i = 0;
          i < 30 &&
              bridge.sessions.single.lastActivityAt !=
                  '2026-07-25T00:00:07.000Z';
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(published, hasLength(afterFirstActivity + 1));
        expect(
          bridge.sessions.single.lastActivityAt,
          '2026-07-25T00:00:07.000Z',
        );
        expect(bridge.sessions.single.lastAssistantOutputAt, isNull);

        socket.add(
          jsonEncode({
            'type': 'assistant',
            'sessionId': 's1',
            'activityAt': '2026-07-25T00:00:09Z',
            'receivedAt': '2026-07-25T00:00:09Z',
            'message': {
              'role': 'assistant',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'tool-1',
                  'name': 'Read',
                  'input': {'path': '/tmp/example'},
                },
              ],
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(bridge.sessions.single.lastAssistantOutputAt, isNull);

        socket.add(
          jsonEncode({
            'type': 'assistant',
            'sessionId': 's1',
            'activityAt': '2026-07-25T00:00:10Z',
            'receivedAt': '2026-07-25T00:00:10Z',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'Visible intermediate update'},
              ],
            },
          }),
        );
        for (
          var i = 0;
          i < 30 &&
              bridge.sessions.single.lastAssistantOutputAt !=
                  '2026-07-25T00:00:10.000Z';
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          bridge.sessions.single.lastAssistantOutputAt,
          '2026-07-25T00:00:10.000Z',
        );

        socket.add(
          jsonEncode({
            'type': 'assistant',
            'sessionId': 's1',
            'activityAt': '2026-07-25T00:00:11Z',
            'receivedAt': '2026-07-25T00:00:11Z',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'future_tool_action', 'payload': 'ignored'},
              ],
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          bridge.sessions.single.lastAssistantOutputAt,
          '2026-07-25T00:00:10.000Z',
        );

        socket.add(
          jsonEncode({
            'type': 'thinking_delta',
            'sessionId': 's1',
            'text': 'tool-era activity',
            'activityAt': '2026-07-25T00:00:12Z',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          bridge.sessions.single.lastAssistantOutputAt,
          '2026-07-25T00:00:10.000Z',
        );

        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': [
              {
                'id': 's1',
                'provider': 'codex',
                'claudeSessionId': 'thread-1',
                'projectPath': '/tmp/project',
                'status': 'running',
                'createdAt': '2026-07-25T00:00:00Z',
                'lastActivityAt': '2026-07-25T00:00:21Z',
                'lastAssistantOutputAt': '2026-07-25T00:00:15Z',
              },
            ],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          bridge.sessions.single.lastAssistantOutputAt,
          '2026-07-25T00:00:15.000Z',
        );

        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': [
              {
                'id': 's1',
                'provider': 'codex',
                'claudeSessionId': 'thread-1',
                'projectPath': '/tmp/project',
                'status': 'running',
                'createdAt': '2026-07-25T00:00:00Z',
                'lastActivityAt': '2026-07-25T00:00:22Z',
                'lastAssistantOutputAt': '2026-07-25T00:00:08Z',
              },
            ],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          bridge.sessions.single.lastAssistantOutputAt,
          '2026-07-25T00:00:15.000Z',
        );

        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': [
              {
                'id': 's1',
                'provider': 'codex',
                'claudeSessionId': 'thread-1',
                'projectPath': '/tmp/project',
                'status': 'running',
                'createdAt': '2026-07-25T00:00:00Z',
                'lastActivityAt': '2026-07-25T00:00:20Z',
              },
            ],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          bridge.sessions.single.lastAssistantOutputAt,
          '2026-07-25T00:00:15.000Z',
        );

        socket.add(
          jsonEncode({
            'type': 'status',
            'sessionId': 's1',
            'status': 'reviewing_future',
          }),
        );
        for (
          var i = 0;
          i < 30 && bridge.sessions.single.status != 'reviewing_future';
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(bridge.sessions.single.status, 'reviewing_future');

        bridge.disconnect();
        await subscription.cancel();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'session listeners observe the matching dynamic Codex model catalog',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final bridge = BridgeService();
        final observedCatalogs = <List<String>>[];
        final observedEfforts = <Map<String, List<String>>>[];
        final revisions = <int>[];
        final sessionSubscription = bridge.sessionList.listen((_) {
          observedCatalogs.add(List<String>.from(bridge.codexModels));
          observedEfforts.add(
            bridge.codexModelReasoningEfforts.map(
              (model, efforts) => MapEntry(model, List<String>.from(efforts)),
            ),
          );
        });
        final catalogSubscription = bridge.codexModelCatalogChanges.listen(
          revisions.add,
        );
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;

        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': const [],
            'codexModels': ['gpt-5.6'],
            'codexModelReasoningEfforts': {
              'gpt-5.6': ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
            },
          }),
        );
        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': const [],
            'codexModels': ['gpt-5.7', 'gpt-5.6'],
            'codexModelReasoningEfforts': {
              'gpt-5.7': ['medium', 'high', 'ultra'],
              'gpt-5.6': ['low', 'medium', 'high'],
            },
            'codexModelServiceTiers': {
              'gpt-5.7': ['default', 'fast'],
            },
          }),
        );

        for (
          var attempt = 0;
          attempt < 30 && observedCatalogs.length < 2;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(observedCatalogs, [
          ['gpt-5.6'],
          ['gpt-5.7', 'gpt-5.6'],
        ]);
        expect(observedEfforts.last['gpt-5.7'], ['medium', 'high', 'ultra']);
        expect(bridge.codexModelServiceTiers['gpt-5.7'], ['default', 'fast']);
        expect(revisions, hasLength(2));
        expect(revisions[1], greaterThan(revisions[0]));

        bridge.disconnect();
        await sessionSubscription.cancel();
        await catalogSubscription.cancel();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'switching bridge drops pending starts from previous target',
      () async {
        final oldServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final oldSocketReady = Completer<WebSocket>();
        oldServer.transform(WebSocketTransformer()).listen((socket) {
          oldSocketReady.complete(socket);
        });

        final newServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final newSocketReady = Completer<WebSocket>();
        final newReceived = <Map<String, dynamic>>[];
        final firstNewMessage = Completer<void>();
        newServer.transform(WebSocketTransformer()).listen((socket) {
          newSocketReady.complete(socket);
          socket.listen((data) {
            newReceived.add(jsonDecode(data as String) as Map<String, dynamic>);
            if (!firstNewMessage.isCompleted) firstNewMessage.complete();
          });
        });

        final bridge = BridgeService();
        bridge.connect('ws://127.0.0.1:${oldServer.port}');

        final oldSocket = await oldSocketReady.future;
        await oldSocket.close();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        bridge.send(
          ClientMessage.start(
            '/old-bridge/project',
            provider: Provider.codex.value,
          ),
        );
        expect(bridge.offlinePendingActions, hasLength(1));

        bridge.connect('ws://127.0.0.1:${newServer.port}');

        final newSocket = await newSocketReady.future;
        await firstNewMessage.future;
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          newReceived.map((message) => message['type']),
          isNot(contains('start')),
        );
        expect(bridge.offlinePendingActions, isEmpty);

        await newSocket.close();
        await oldServer.close(force: true);
        await newServer.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'requestSessionHistory uses delta when cached sequence exists',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final outgoing = <ClientMessage>[];
        final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
        bridge.connect('ws://127.0.0.1:${server.port}');

        final socket = await socketReady.future;
        final reconciledSession = bridge.sessionHistoryReconciliations.first;
        final previousReconciliationGeneration = bridge
            .sessionHistoryReconciliationGeneration('s1');
        socket.add(
          jsonEncode({
            'type': 'history_delta',
            'sessionId': 's1',
            'fromSeq': 1,
            'toSeq': 1,
            'messages': [
              {
                'seq': 1,
                'message': {'type': 'status', 'status': 'running'},
              },
            ],
          }),
        );
        expect(await reconciledSession, 's1');
        expect(
          bridge.sessionHistoryReconciliationGeneration('s1'),
          previousReconciliationGeneration + 1,
        );

        bridge.requestSessionHistory('s1');

        final request =
            jsonDecode(outgoing.last.toJson()) as Map<String, dynamic>;
        expect(request, {
          'type': 'get_history_delta',
          'sessionId': 's1',
          'sinceSeq': 1,
        });

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'foreground history sync activity follows actual transport reconciliation',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final bridge = BridgeService();
        final connected = bridge.connectionStatus.firstWhere(
          (state) => state == BridgeConnectionState.connected,
        );
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await connected.timeout(const Duration(seconds: 2));

        final changes = <String>[];
        final activitySubscription = bridge.sessionHistorySyncChanges.listen(
          changes.add,
        );
        bridge.requestSessionHistory('s1');
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(bridge.isSessionHistorySyncing('s1'), isTrue);
        expect(changes, ['s1']);

        final reconciled = bridge.sessionHistoryReconciliations.first;
        socket.add(
          jsonEncode({
            'type': 'history',
            'sessionId': 's1',
            'messages': const [
              {'type': 'status', 'status': 'idle'},
            ],
          }),
        );
        expect(await reconciled.timeout(const Duration(seconds: 2)), 's1');
        await Future<void>.delayed(Duration.zero);

        expect(bridge.isSessionHistorySyncing('s1'), isFalse);
        expect(changes, ['s1', 's1']);

        await activitySubscription.cancel();
        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'queued foreground history only becomes active after reconnect send',
      () async {
        final bridge = BridgeService();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });
        final becameActive = bridge.sessionHistorySyncChanges.first;
        bridge.connect('ws://127.0.0.1:${server.port}');
        bridge.requestSessionHistory('queued-session');
        expect(bridge.isSessionHistorySyncing('queued-session'), isFalse);
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        socket.add(jsonEncode({'type': 'session_list', 'sessions': const []}));

        expect(
          await becameActive.timeout(const Duration(seconds: 2)),
          'queued-session',
        );
        expect(bridge.isSessionHistorySyncing('queued-session'), isTrue);

        bridge.disconnect();
        expect(bridge.isSessionHistorySyncing('queued-session'), isFalse);
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'remote history paging is correlated, single-flight, and bounded',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        var pageRequestCount = 0;

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
          socket.listen((data) {
            final request = jsonDecode(data as String) as Map<String, dynamic>;
            if (request['type'] != 'get_history_page') return;
            pageRequestCount++;
            Future<void>.delayed(const Duration(milliseconds: 20), () {
              socket.add(
                jsonEncode({
                  'type': 'history_page',
                  'requestId': request['requestId'],
                  'sessionId': 's1',
                  'beforeSeq': 101,
                  'nextBeforeSeq': 96,
                  'hasMore': false,
                  'messages': [
                    {
                      'seq': 96,
                      'message': {
                        'type': 'user_input',
                        'text': 'older question',
                      },
                    },
                  ],
                }),
              );
            });
          });
        });

        final bridge = BridgeService();
        final historyReceived = bridge.messages
            .where((message) => message is HistoryMessage)
            .cast<HistoryMessage>()
            .first;
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': const [],
            'bridgeCapabilities': const [
              historyPageCapability,
              turnAwareHistoryWindowCapability,
            ],
          }),
        );
        socket.add(
          jsonEncode({
            'type': 'history',
            'sessionId': 's1',
            'messages': [
              {'type': 'user_input', 'text': 'latest question'},
            ],
            'historyWindow': {
              'capability': turnAwareHistoryWindowCapability,
              'fromSeq': 101,
              'hasMore': true,
            },
          }),
        );
        await historyReceived.timeout(const Duration(seconds: 2));
        expect(bridge.hasRemoteSessionHistoryPaging('s1'), isTrue);
        expect(bridge.hasOlderRemoteSessionHistory('s1'), isTrue);

        final first = bridge.tryLoadOlderLocalSessionHistory(
          runtimeSessionId: 's1',
        );
        final second = bridge.tryLoadOlderLocalSessionHistory(
          runtimeSessionId: 's1',
        );
        final pages = await Future.wait([first, second]);

        expect(pageRequestCount, 1);
        expect(pages[0]?.messages, hasLength(1));
        expect(
          pages[0]?.messages.single,
          isA<UserInputMessage>().having(
            (message) => message.text,
            'text',
            'older question',
          ),
        );
        expect(pages[0]?.hasMore, isFalse);
        expect(bridge.hasOlderRemoteSessionHistory('s1'), isFalse);

        bridge.migrateExplorerHistory('s1', 's2');
        expect(bridge.hasRemoteSessionHistoryPaging('s1'), isFalse);
        expect(bridge.hasRemoteSessionHistoryPaging('s2'), isTrue);

        bridge.clearExplorerHistory('s2');
        expect(bridge.hasRemoteSessionHistoryPaging('s2'), isFalse);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'remote history page errors preserve the cursor for explicit retry',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        final requestedCursors = <String?>[];

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
          socket.listen((data) {
            final request = jsonDecode(data as String) as Map<String, dynamic>;
            if (request['type'] != 'get_history_page') return;
            requestedCursors.add(request['beforeCursor'] as String?);
            if (requestedCursors.length == 1) {
              socket.add(
                jsonEncode({
                  'type': 'history_page',
                  'requestId': request['requestId'],
                  'sessionId': 's1',
                  'beforeSeq': 101,
                  'nextBeforeSeq': 101,
                  'hasMore': false,
                  'messages': const [],
                  'error': 'temporary provider page failure',
                }),
              );
              return;
            }
            socket.add(
              jsonEncode({
                'type': 'history_page',
                'requestId': request['requestId'],
                'sessionId': 's1',
                'beforeSeq': 101,
                'nextBeforeSeq': 101,
                'hasMore': false,
                'messages': [
                  {
                    'seq': -1,
                    'message': {
                      'type': 'user_input',
                      'text': 'older after retry',
                    },
                  },
                ],
              }),
            );
          });
        });

        final bridge = BridgeService();
        final historyReceived = bridge.messages
            .where((message) => message is HistoryMessage)
            .cast<HistoryMessage>()
            .first;
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': const [],
            'bridgeCapabilities': const [
              historyPageCapability,
              turnAwareHistoryWindowCapability,
            ],
          }),
        );
        socket.add(
          jsonEncode({
            'type': 'history',
            'sessionId': 's1',
            'messages': const [],
            'historyWindow': const {
              'capability': turnAwareHistoryWindowCapability,
              'fromSeq': 101,
              'hasMore': true,
              'cursor': 'v2:retry-token',
            },
          }),
        );
        await historyReceived.timeout(const Duration(seconds: 2));

        await expectLater(
          bridge.tryLoadOlderLocalSessionHistory(runtimeSessionId: 's1'),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('temporary provider page failure'),
            ),
          ),
        );
        expect(bridge.hasOlderRemoteSessionHistory('s1'), isTrue);

        final retried = await bridge.tryLoadOlderLocalSessionHistory(
          runtimeSessionId: 's1',
        );
        expect(retried?.messages.single, isA<UserInputMessage>());
        expect(retried?.hasMore, isFalse);
        expect(requestedCursors, ['v2:retry-token', 'v2:retry-token']);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'history tool details are correlated, bounded, and connection fenced',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        final secondRequestReady = Completer<void>();
        final requests = <Map<String, dynamic>>[];
        final runtimeSessionId = List.filled(200, 's').join();

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
          socket.listen((data) {
            final request = jsonDecode(data as String) as Map<String, dynamic>;
            if (request['type'] != 'get_history_tool_details') return;
            requests.add(request);
            if (requests.length == 1) {
              socket.add(
                jsonEncode({
                  'type': 'history_tool_details',
                  'requestId': request['requestId'],
                  'sessionId': runtimeSessionId,
                  'details': [
                    {
                      'toolUseId': 'tool-1',
                      'toolName': 'Read',
                      'input': {'file_path': '/tmp/a.txt'},
                      'result': {'content': 'contents', 'toolName': 'Read'},
                    },
                  ],
                }),
              );
            } else if (requests.length == 2) {
              socket.add(
                jsonEncode({
                  'type': 'history_tool_details',
                  'requestId': request['requestId'],
                  'sessionId': runtimeSessionId,
                  'details': const [],
                  'error': 'remote detail unavailable',
                }),
              );
            } else if (!secondRequestReady.isCompleted) {
              secondRequestReady.complete();
            }
          });
        });

        final bridge = BridgeService();
        final sessionListReceived = bridge.sessionList.first;
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': const [],
            'bridgeCapabilities': const [historyToolDetailCapability],
          }),
        );
        await sessionListReceived.timeout(const Duration(seconds: 2));
        bridge.configureSessionHistoryToolDetails(({
          required runtimeSessionId,
          required toolUseIds,
          required historyTurnId,
        }) async {
          return toolUseIds.contains('tool-local')
              ? const [
                  HistoryToolDetail(
                    toolUseId: 'tool-local',
                    toolName: 'Read',
                    input: {'file_path': '/tmp/local.txt'},
                  ),
                ]
              : const [];
        });

        final details = await bridge.requestHistoryToolDetails(
          runtimeSessionId: runtimeSessionId,
          historyTurnId: 'provider-turn-one',
          toolUseIds: const [
            'tool-local',
            'tool-1',
            'tool-1',
            'tool-2',
            'tool-3',
            'tool-4',
            'tool-5',
            'tool-6',
            'tool-7',
            'tool-8',
            'tool-9',
          ],
        );
        expect(requests.single['toolUseIds'], [
          'tool-1',
          'tool-2',
          'tool-3',
          'tool-4',
          'tool-5',
          'tool-6',
          'tool-7',
        ]);
        expect(requests.single['historyTurnId'], 'provider-turn-one');
        expect((requests.single['requestId'] as String).length, lessThan(128));
        expect(details, hasLength(2));
        expect(details?.first.toolUseId, 'tool-local');
        expect(details?.last.result?.content, 'contents');

        final localAfterRemoteError = await bridge.requestHistoryToolDetails(
          runtimeSessionId: runtimeSessionId,
          toolUseIds: const ['tool-local', 'tool-error'],
        );
        expect(localAfterRemoteError, hasLength(1));
        expect(localAfterRemoteError?.single.toolUseId, 'tool-local');

        final interrupted = bridge.requestHistoryToolDetails(
          runtimeSessionId: runtimeSessionId,
          toolUseIds: const ['tool-pending'],
        );
        await secondRequestReady.future.timeout(const Duration(seconds: 2));
        bridge.disconnect();
        expect(await interrupted, isNull);

        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'history tool details remain available from a local mirror offline',
      () async {
        final bridge = BridgeService();
        bridge.configureSessionHistoryToolDetails(({
          required runtimeSessionId,
          required toolUseIds,
          required historyTurnId,
        }) async {
          expect(runtimeSessionId, 's1');
          expect(toolUseIds, ['tool-local', 'missing']);
          return const [
            HistoryToolDetail(
              toolUseId: 'tool-local',
              toolName: 'Read',
              input: {'file_path': '/tmp/local.txt'},
              result: ToolResultMessage(
                toolUseId: 'tool-local',
                toolName: 'Read',
                content: 'local contents',
              ),
            ),
          ];
        });

        final details = await bridge.requestHistoryToolDetails(
          runtimeSessionId: 's1',
          toolUseIds: const ['tool-local', 'missing'],
        );

        expect(details, hasLength(1));
        expect(details?.single.toolUseId, 'tool-local');
        expect(details?.single.result?.content, 'local contents');
        bridge.dispose();
      },
    );

    test('requestSessionHistory uses last complete cached sequence', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final outgoing = <ClientMessage>[];
      final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
      bridge.connect('ws://127.0.0.1:${server.port}');

      final socket = await socketReady.future;
      socket.add(
        jsonEncode({
          'type': 'history_delta',
          'sessionId': 's1',
          'fromSeq': 1,
          'toSeq': 3,
          'messages': [
            {
              'seq': 1,
              'message': {'type': 'status', 'status': 'starting'},
            },
            {
              'seq': 2,
              'message': {'type': 'status', 'status': 'running'},
            },
            {
              'seq': 3,
              'message': {'type': 'status', 'status': 'idle'},
            },
          ],
        }),
      );
      socket.add(
        jsonEncode({
          'type': 'assistant',
          'message': {
            'id': 'msg-1',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Hi. What do you want to work on?'},
            ],
            'model': 'gpt-5.5',
          },
          'sessionId': 's1',
          'historySeq': 6,
        }),
      );
      socket.add(
        jsonEncode({
          'type': 'result',
          'subtype': 'success',
          'sessionId': 's1',
          'historySeq': 7,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      bridge.requestSessionHistory('s1');

      final request =
          jsonDecode(outgoing.last.toJson()) as Map<String, dynamic>;
      expect(request, {
        'type': 'get_history_delta',
        'sessionId': 's1',
        'sinceSeq': 3,
      });

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test(
      'requestSessionHistory falls back when delta is unsupported',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final outgoing = <ClientMessage>[];
        final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
        bridge.connect('ws://127.0.0.1:${server.port}');

        final socket = await socketReady.future;
        socket.add(
          jsonEncode({
            'type': 'status',
            'status': 'running',
            'sessionId': 's1',
            'historySeq': 3,
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        bridge.requestSessionHistory('s1');
        expect(bridge.isSessionHistorySyncing('s1'), isTrue);
        socket.add(
          jsonEncode({
            'type': 'error',
            'errorCode': 'unsupported_message',
            'message': 'get_history_delta',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final requests = outgoing
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .toList();
        expect(
          requests.any(
            (request) =>
                request['type'] == 'get_history_delta' &&
                request['sessionId'] == 's1',
          ),
          isTrue,
        );
        expect(requests.last, {'type': 'get_history', 'sessionId': 's1'});
        expect(bridge.isSessionHistorySyncing('s1'), isTrue);

        final reconciled = bridge.sessionHistoryReconciliations.first;
        socket.add(
          jsonEncode({
            'type': 'history',
            'sessionId': 's1',
            'messages': const [],
          }),
        );
        await reconciled.timeout(const Duration(seconds: 2));
        expect(bridge.isSessionHistorySyncing('s1'), isFalse);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'background delta-only history never falls back to full history',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final outgoing = <ClientMessage>[];
        final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
        bridge.connect('ws://127.0.0.1:${server.port}');

        final socket = await socketReady.future;
        socket.add(
          jsonEncode({
            'type': 'status',
            'status': 'running',
            'sessionId': 's1',
            'historySeq': 3,
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        bridge.requestSessionHistoryDeltaOnly('s1');
        expect(bridge.isSessionHistorySyncing('s1'), isFalse);
        bridge.requestSessionHistoryDeltaOnly('s1');
        socket.add(
          jsonEncode({
            'type': 'error',
            'errorCode': 'unsupported_message',
            'message': 'get_history_delta',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final requests = outgoing
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .toList();
        expect(
          requests.any(
            (request) =>
                request['type'] == 'get_history_delta' &&
                request['sessionId'] == 's1',
          ),
          isTrue,
        );
        expect(
          requests.where((request) => request['type'] == 'get_history'),
          isEmpty,
        );
        expect(bridge.isSessionHistorySyncing('s1'), isFalse);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'background history cannot downgrade a concurrent foreground fallback',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final outgoing = <ClientMessage>[];
        final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
        bridge.connect('ws://127.0.0.1:${server.port}');

        final socket = await socketReady.future;
        socket.add(
          jsonEncode({
            'type': 'status',
            'status': 'running',
            'sessionId': 's1',
            'historySeq': 3,
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        bridge.requestSessionHistoryDeltaOnly('s1');
        bridge.requestSessionHistory('s1');
        bridge.requestSessionHistoryDeltaOnly('s1');
        expect(bridge.isSessionHistorySyncing('s1'), isTrue);
        expect(
          outgoing
              .map(
                (message) =>
                    jsonDecode(message.toJson()) as Map<String, dynamic>,
              )
              .where((request) => request['type'] == 'get_history_delta'),
          hasLength(1),
        );

        socket.add(
          jsonEncode({
            'type': 'error',
            'errorCode': 'unsupported_message',
            'message': 'get_history_delta',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final requests = outgoing
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .toList();
        expect(requests.last, {'type': 'get_history', 'sessionId': 's1'});

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test('coalesced history requests run one dirty follow-up', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final outgoing = <ClientMessage>[];
      final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
      bridge.connect('ws://127.0.0.1:${server.port}');

      final socket = await socketReady.future;
      socket.add(
        jsonEncode({
          'type': 'status',
          'status': 'running',
          'sessionId': 's1',
          'historySeq': 1,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      bridge.requestSessionHistory('s1');
      bridge.requestSessionHistory('s1');
      expect(
        outgoing
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .where((request) => request['type'] == 'get_history_delta'),
        hasLength(1),
      );

      socket.add(
        jsonEncode({
          'type': 'history_delta',
          'sessionId': 's1',
          'fromSeq': 1,
          'toSeq': 1,
          'messages': [
            {
              'seq': 1,
              'message': {'type': 'status', 'status': 'running'},
            },
          ],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final deltaRequests = outgoing
          .map(
            (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
          )
          .where((request) => request['type'] == 'get_history_delta')
          .toList();
      expect(deltaRequests, hasLength(2));
      expect(deltaRequests.last, {
        'type': 'get_history_delta',
        'sessionId': 's1',
        'sinceSeq': 1,
      });

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test('resolveSessionLink completes with the matching response', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');
      final socket = await socketReady.future;
      final requestFuture = socket
          .where((event) {
            final json = jsonDecode(event as String) as Map<String, dynamic>;
            return json['type'] == 'resolve_session_link';
          })
          .map((event) => jsonDecode(event as String) as Map<String, dynamic>)
          .first;

      final resolutionFuture = bridge.resolveSessionLink(
        'claude-uuid',
        provider: 'claude',
      );
      final request = await requestFuture.timeout(const Duration(seconds: 2));
      socket.add(
        jsonEncode({
          'type': 'session_link_resolution',
          'requestId': request['requestId'],
          'sourceSessionId': 'claude-uuid',
          'status': 'live',
          'bridgeSessionId': 'bridge-1',
          'provider': 'claude',
        }),
      );

      final result = await resolutionFuture.timeout(const Duration(seconds: 2));
      expect(result.support, SessionLinkResolveSupport.resolved);
      expect(result.resolution?.bridgeSessionId, 'bridge-1');

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test(
      'resolveSessionLink renews only for effective progress on a capable Bridge',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen(socketReady.complete);

        final bridge = BridgeService();
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        await _authorizeBridgeIdentity(
          bridge,
          socket,
          bridgeInstanceId: 'bridge-progress',
          codexSourceId: 'source-progress',
          bridgeCapabilities: const [sessionLinkProgressCapability],
        );
        final requestFuture = socket
            .where((event) {
              final json = jsonDecode(event as String) as Map<String, dynamic>;
              return json['type'] == 'resolve_session_link';
            })
            .map((event) => jsonDecode(event as String) as Map<String, dynamic>)
            .first;
        final observed = <SessionLinkProgressMessage>[];

        final resolution = bridge.resolveSessionLink(
          'claude-progress',
          provider: 'claude',
          progressIdleTimeout: const Duration(milliseconds: 250),
          progressHardTimeout: const Duration(seconds: 2),
          onProgress: observed.add,
        );
        final request = await requestFuture.timeout(const Duration(seconds: 2));
        final generation = request['sessionLinkGeneration'] as int;

        await Future<void>.delayed(const Duration(milliseconds: 150));
        socket.add(
          jsonEncode({
            'type': sessionLinkProgressCapability,
            'requestId': request['requestId'],
            'sourceSessionId': 'claude-progress',
            'generation': generation,
            'operation': 'resolve',
            'stage': 'request_accepted',
            'sequence': 1,
            'observedAt': '2026-07-31T00:00:00Z',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        socket.add(
          jsonEncode({
            'type': sessionLinkProgressCapability,
            'requestId': request['requestId'],
            'sourceSessionId': 'claude-progress',
            'generation': generation,
            'operation': 'resolve',
            'stage': 'catalog_scanning',
            'sequence': 2,
            'completedUnits': 1,
            'observedAt': '2026-07-31T00:00:01Z',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        socket.add(
          jsonEncode({
            'type': 'session_link_resolution',
            'requestId': request['requestId'],
            'sourceSessionId': 'claude-progress',
            'sessionLinkGeneration': generation,
            'status': 'live',
            'bridgeSessionId': 'bridge-live',
            'provider': 'claude',
          }),
        );

        final result = await resolution.timeout(const Duration(seconds: 2));
        expect(result.support, SessionLinkResolveSupport.resolved);
        expect(result.generation, generation);
        expect(
          observed.map((progress) => progress.stage),
          containsAllInOrder([
            SessionLinkProgressStage.requestSent,
            SessionLinkProgressStage.requestAccepted,
            SessionLinkProgressStage.catalogScanning,
          ]),
        );

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'progress-capable resolution survives the former hard deadline',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen(socketReady.complete);

        final bridge = BridgeService();
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        await _authorizeBridgeIdentity(
          bridge,
          socket,
          bridgeInstanceId: 'bridge-long-running',
          codexSourceId: 'source-long-running',
          bridgeCapabilities: const [sessionLinkProgressCapability],
        );
        final requestFuture = socket
            .where((event) {
              final json = jsonDecode(event as String) as Map<String, dynamic>;
              return json['type'] == 'resolve_session_link';
            })
            .map((event) => jsonDecode(event as String) as Map<String, dynamic>)
            .first;
        final resolution = bridge.resolveSessionLink(
          'claude-long-running',
          progressIdleTimeout: const Duration(seconds: 1),
          progressHardTimeout: const Duration(milliseconds: 50),
        );
        final request = await requestFuture.timeout(const Duration(seconds: 2));
        final generation = request['sessionLinkGeneration'] as int;

        await Future<void>.delayed(const Duration(milliseconds: 150));
        socket.add(
          jsonEncode({
            'type': sessionLinkProgressCapability,
            'requestId': request['requestId'],
            'sourceSessionId': 'claude-long-running',
            'generation': generation,
            'operation': 'resolve',
            'stage': 'catalog_scanning',
            'sequence': 1,
            'completedUnits': 1,
            'observedAt': '2026-07-31T00:00:01Z',
          }),
        );
        socket.add(
          jsonEncode({
            'type': 'session_link_resolution',
            'requestId': request['requestId'],
            'sourceSessionId': 'claude-long-running',
            'sessionLinkGeneration': generation,
            'status': 'live',
            'bridgeSessionId': 'bridge-live',
            'provider': 'claude',
          }),
        );

        final result = await resolution.timeout(const Duration(seconds: 2));
        expect(result.support, SessionLinkResolveSupport.resolved);
        expect(result.resolution?.bridgeSessionId, 'bridge-live');

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'duplicate session link heartbeat does not renew the idle timeout',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen(socketReady.complete);

        final bridge = BridgeService();
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        await _authorizeBridgeIdentity(
          bridge,
          socket,
          bridgeInstanceId: 'bridge-progress',
          codexSourceId: 'source-progress',
          bridgeCapabilities: const [sessionLinkProgressCapability],
        );
        final requestFuture = socket
            .where((event) {
              final json = jsonDecode(event as String) as Map<String, dynamic>;
              return json['type'] == 'resolve_session_link';
            })
            .map((event) => jsonDecode(event as String) as Map<String, dynamic>)
            .first;
        final resolution = bridge.resolveSessionLink(
          'claude-stalled',
          progressIdleTimeout: const Duration(milliseconds: 200),
          progressHardTimeout: const Duration(seconds: 2),
        );
        final request = await requestFuture.timeout(const Duration(seconds: 2));
        final generation = request['sessionLinkGeneration'] as int;
        Map<String, Object?> progress(int sequence) => {
          'type': sessionLinkProgressCapability,
          'requestId': request['requestId'],
          'sourceSessionId': 'claude-stalled',
          'generation': generation,
          'operation': 'resolve',
          'stage': 'request_accepted',
          'sequence': sequence,
          'observedAt': '2026-07-31T00:00:00Z',
        };

        socket.add(jsonEncode(progress(1)));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        socket.add(jsonEncode(progress(2)));
        final race = await Future.any<String>([
          resolution.then((_) => 'timed-out'),
          Future<String>.delayed(
            const Duration(milliseconds: 120),
            () => 'still-waiting',
          ),
        ]);

        expect(race, 'timed-out');
        expect(
          (await resolution).support,
          SessionLinkResolveSupport.unavailable,
        );

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test('resolveSessionLink degrades for an older Bridge', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');
      final socket = await socketReady.future;
      final requestFuture = socket
          .where((event) {
            final json = jsonDecode(event as String) as Map<String, dynamic>;
            return json['type'] == 'resolve_session_link';
          })
          .map((event) => jsonDecode(event as String) as Map<String, dynamic>)
          .first;

      final resolutionFuture = bridge.resolveSessionLink('claude-uuid');
      await requestFuture.timeout(const Duration(seconds: 2));
      socket.add(
        jsonEncode({
          'type': 'error',
          'errorCode': 'unsupported_message',
          'message': 'resolve_session_link',
        }),
      );

      final result = await resolutionFuture.timeout(const Duration(seconds: 2));
      expect(result.support, SessionLinkResolveSupport.unsupported);

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test(
      'resolveSessionLink rejects a different Codex source without sending',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen(socketReady.complete);

        final bridge = BridgeService();
        final outgoing = <ClientMessage>[];
        bridge.onOutgoingMessage = outgoing.add;
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        await _authorizeBridgeIdentity(
          bridge,
          socket,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'source-b',
        );
        outgoing.clear();

        final result = await bridge.resolveSessionLink(
          'shared-thread',
          provider: 'codex',
          expectedDataSourceIdentity: const BridgeDataSourceIdentity(
            bridgeInstanceId: 'bridge-1',
            codexSourceId: 'source-a',
          ),
        );

        expect(result.support, SessionLinkResolveSupport.unavailable);
        expect(
          outgoing.where(
            (message) =>
                jsonDecode(message.toJson())['type'] == 'resolve_session_link',
          ),
          isEmpty,
        );

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'resolveSessionLink fails closed when the source changes in flight',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen(socketReady.complete);

        final bridge = BridgeService();
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        await _authorizeBridgeIdentity(
          bridge,
          socket,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'source-a',
        );
        final requestFuture = socket.where((event) {
          final json = jsonDecode(event as String) as Map<String, dynamic>;
          return json['type'] == 'resolve_session_link';
        }).first;

        final resolution = bridge.resolveSessionLink(
          'shared-thread',
          provider: 'codex',
          expectedDataSourceIdentity: const BridgeDataSourceIdentity(
            bridgeInstanceId: 'bridge-1',
            codexSourceId: 'source-a',
          ),
        );
        await requestFuture.timeout(const Duration(seconds: 2));
        await _authorizeBridgeIdentity(
          bridge,
          socket,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'source-b',
        );

        final result = await resolution.timeout(const Duration(seconds: 2));
        expect(result.support, SessionLinkResolveSupport.unavailable);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'resolveSessionLink waits for a connection without queueing a stale request',
      () async {
        final bridge = BridgeService();
        final outgoing = <ClientMessage>[];
        bridge.onOutgoingMessage = outgoing.add;

        final result = await bridge.resolveSessionLink(
          'claude-uuid',
          timeout: const Duration(milliseconds: 20),
        );

        expect(result.support, SessionLinkResolveSupport.unavailable);
        expect(outgoing, isEmpty);
        bridge.dispose();
      },
    );

    test(
      'resolveSessionLink gives connection identity and legacy response independent budgets',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen(socketReady.complete);
        final bridge = BridgeService();
        const phaseBudget = Duration(milliseconds: 400);
        const phaseDelay = Duration(milliseconds: 250);

        final resolution = bridge.resolveSessionLink(
          'shared-thread',
          provider: 'codex',
          timeout: phaseBudget,
          expectedDataSourceIdentity: const BridgeDataSourceIdentity(
            bridgeInstanceId: 'bridge-delayed',
            codexSourceId: 'source-delayed',
          ),
        );

        await Future<void>.delayed(phaseDelay);
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        final requestFuture = socket
            .where((event) {
              final json = jsonDecode(event as String) as Map<String, dynamic>;
              return json['type'] == 'resolve_session_link';
            })
            .map((event) => jsonDecode(event as String) as Map<String, dynamic>)
            .first;

        await Future<void>.delayed(phaseDelay);
        await _authorizeBridgeIdentity(
          bridge,
          socket,
          bridgeInstanceId: 'bridge-delayed',
          codexSourceId: 'source-delayed',
        );
        final request = await requestFuture.timeout(phaseBudget);

        await Future<void>.delayed(phaseDelay);
        socket.add(
          jsonEncode({
            'type': 'session_link_resolution',
            'requestId': request['requestId'],
            'sourceSessionId': 'shared-thread',
            'status': 'live',
            'bridgeSessionId': 'bridge-session',
            'provider': 'codex',
          }),
        );

        final result = await resolution.timeout(const Duration(seconds: 2));
        expect(result.support, SessionLinkResolveSupport.resolved);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'resolveSessionLink fails closed when the connection stream closes',
      () async {
        final bridge = BridgeService();
        final resolution = bridge.resolveSessionLink(
          'claude-uuid',
          timeout: const Duration(seconds: 1),
        );
        await Future<void>.delayed(Duration.zero);

        bridge.dispose();

        final result = await resolution;
        expect(result.support, SessionLinkResolveSupport.unavailable);
      },
    );

    test('session list does not expose delivery pending as a queue', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final bridge = BridgeService();
      bridge.setDeliveryPendingInput(
        's1',
        const QueuedInputItem(
          itemId: 'pending:cm-1',
          text: 'Pending delivery',
          createdAt: '2026-04-28T00:00:00.000Z',
        ),
      );
      bridge.connect('ws://127.0.0.1:${server.port}');

      final socket = await socketReady.future;
      socket.add(
        jsonEncode({
          'type': 'session_list',
          'sessions': [
            {
              'id': 's1',
              'provider': 'codex',
              'projectPath': '/tmp/project',
              'status': 'running',
            },
          ],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.sessions.single.queuedInput, isNull);
      expect(
        bridge.deliveryPendingInputForSession('s1')?.itemId,
        'pending:cm-1',
      );

      socket.add(
        jsonEncode({
          'type': 'input_ack',
          'sessionId': 's1',
          'clientMessageId': 'cm-1',
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.sessions.single.queuedInput, isNull);
      expect(bridge.deliveryPendingInputForSession('s1'), isNull);

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test('delivery recovery metadata is bounded per session', () {
      final bridge = BridgeService();
      addTearDown(bridge.dispose);

      for (
        var index = 0;
        index < BridgeService.maxDeliveryPendingInputsPerSession;
        index++
      ) {
        expect(
          bridge.setDeliveryPendingInput(
            'bounded-session',
            QueuedInputItem(
              itemId: 'pending:$index',
              text: 'Pending $index',
              createdAt: '2026-08-04T00:00:00.000Z',
            ),
          ),
          isTrue,
        );
      }

      expect(
        bridge.setDeliveryPendingInput(
          'bounded-session',
          const QueuedInputItem(
            itemId: 'pending:overflow',
            text: 'Overflow',
            createdAt: '2026-08-04T00:00:01.000Z',
          ),
        ),
        isFalse,
      );
      expect(
        bridge.deliveryPendingInputsForSession('bounded-session'),
        hasLength(BridgeService.maxDeliveryPendingInputsPerSession),
      );
    });

    test('conversation queue updates cached session queued input', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');

      final socket = await socketReady.future;
      socket.add(
        jsonEncode({
          'type': 'session_list',
          'sessions': [
            {
              'id': 's1',
              'provider': 'codex',
              'projectPath': '/tmp/project',
              'status': 'running',
            },
          ],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      bridge.setDeliveryPendingInput(
        's1',
        const QueuedInputItem(
          itemId: 'pending:cm-queued',
          text: 'Queued while busy',
          createdAt: '2026-04-28T00:00:00.000Z',
        ),
      );
      expect(bridge.deliveryPendingInputForSession('s1'), isNotNull);

      socket.add(
        jsonEncode({
          'type': 'conversation_queue',
          'sessionId': 's1',
          'limit': 1,
          'items': [
            {
              'itemId': 'q1',
              'text': 'Queued while busy',
              'createdAt': '2026-04-28T00:00:00.000Z',
            },
          ],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.sessions.single.queuedInput?.itemId, 'q1');
      expect(bridge.sessions.single.queuedInput?.text, 'Queued while busy');
      expect(bridge.deliveryPendingInputForSession('s1'), isNull);

      socket.add(
        jsonEncode({
          'type': 'conversation_queue',
          'sessionId': 's1',
          'limit': 1,
          'items': [],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.sessions.single.queuedInput, isNull);

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test(
      'legacy same-text queue does not discard ambiguous delivery recovery',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final bridge = BridgeService();
        bridge.setDeliveryPendingInput(
          's1',
          const QueuedInputItem(
            itemId: 'pending:cm-1',
            text: 'Same follow up',
            createdAt: '2026-04-28T00:00:00.000Z',
          ),
        );
        bridge.setDeliveryPendingInput(
          's1',
          const QueuedInputItem(
            itemId: 'pending:cm-2',
            text: 'Same follow up',
            createdAt: '2026-04-28T00:00:01.000Z',
          ),
        );
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;

        socket.add(
          jsonEncode({
            'type': 'conversation_queue',
            'sessionId': 's1',
            'limit': 1,
            'items': [
              {
                'itemId': 'legacy-q1',
                'text': 'Same follow up',
                'createdAt': '2026-04-28T00:00:02.000Z',
              },
            ],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bridge.deliveryPendingInputsForSession('s1'), hasLength(2));

        socket.add(
          jsonEncode({
            'type': 'conversation_queue',
            'sessionId': 's1',
            'limit': 1,
            'items': [
              {
                'itemId': 'q1',
                'text': 'Same follow up',
                'createdAt': '2026-04-28T00:00:03.000Z',
                'clientMessageId': 'cm-1',
              },
            ],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          bridge
              .deliveryPendingInputsForSession('s1')
              .map((item) => item.itemId),
          ['pending:cm-2'],
        );

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test('input_ack alone does not advance cached history sequence', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');

      final socket = await socketReady.future;
      socket.add(
        jsonEncode({
          'type': 'input_ack',
          'sessionId': 's1',
          'clientMessageId': 'cm-1',
          'acceptedSeq': 8,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.cachedSessionHistorySeq('s1'), 0);

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test(
      'input_ack caches accepted in-flight user input for re-entry',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final bridge = BridgeService();
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        await _authorizeLegacyBridge(bridge, socket);

        socket.add(
          jsonEncode({
            'type': 'history_delta',
            'sessionId': 's1',
            'fromSeq': 1,
            'toSeq': 7,
            'messages': List.generate(7, (index) {
              return {
                'seq': index + 1,
                'message': {'type': 'status', 'status': 'running'},
              };
            }),
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        bridge.send(
          ClientMessage.input('hi', sessionId: 's1', clientMessageId: 'cm-hi'),
        );
        socket.add(
          jsonEncode({
            'type': 'input_ack',
            'sessionId': 's1',
            'clientMessageId': 'cm-hi',
            'acceptedSeq': 8,
            'queued': false,
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final cachedUserInputs = bridge
            .cachedSessionMessages('s1')
            .whereType<UserInputMessage>()
            .toList();
        expect(cachedUserInputs, hasLength(1));
        expect(cachedUserInputs.single.text, 'hi');
        expect(cachedUserInputs.single.clientMessageId, 'cm-hi');
        expect(bridge.cachedSessionHistorySeq('s1'), 8);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'image input ack does not hide canonical history image refs',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final outgoing = <ClientMessage>[];
        final bridge = BridgeService()..onOutgoingMessage = outgoing.add;
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        await _authorizeLegacyBridge(bridge, socket);

        socket.add(
          jsonEncode({
            'type': 'history_delta',
            'sessionId': 's1',
            'fromSeq': 1,
            'toSeq': 7,
            'messages': List.generate(7, (index) {
              return {
                'seq': index + 1,
                'message': {'type': 'status', 'status': 'running'},
              };
            }),
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        bridge.send(
          ClientMessage.input(
            '',
            sessionId: 's1',
            clientMessageId: 'cm-img',
            images: const [
              {'base64': 'aW1hZ2U=', 'mimeType': 'image/png'},
            ],
          ),
        );
        socket.add(
          jsonEncode({
            'type': 'input_ack',
            'sessionId': 's1',
            'clientMessageId': 'cm-img',
            'acceptedSeq': 8,
            'queued': false,
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          bridge.cachedSessionMessages('s1').whereType<UserInputMessage>(),
          isEmpty,
        );
        expect(bridge.cachedSessionHistorySeq('s1'), 7);

        outgoing.clear();
        bridge.requestSessionHistory('s1');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final historyRequest =
            jsonDecode(outgoing.single.toJson()) as Map<String, dynamic>;
        expect(historyRequest, {
          'type': 'get_history_delta',
          'sessionId': 's1',
          'sinceSeq': 7,
        });

        socket.add(
          jsonEncode({
            'type': 'history_delta',
            'sessionId': 's1',
            'fromSeq': 8,
            'toSeq': 8,
            'messages': [
              {
                'seq': 8,
                'message': {
                  'type': 'user_input',
                  'text': '',
                  'clientMessageId': 'cm-img',
                  'imageCount': 1,
                  'images': [
                    {
                      'id': 'img-1',
                      'url': '/images/img-1',
                      'mimeType': 'image/png',
                    },
                  ],
                },
              },
            ],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final cachedUserInputs = bridge
            .cachedSessionMessages('s1')
            .whereType<UserInputMessage>()
            .toList();
        expect(cachedUserInputs, hasLength(1));
        expect(cachedUserInputs.single.imageCount, 1);
        expect(cachedUserInputs.single.imageUrls, ['/images/img-1']);
        expect(bridge.cachedSessionHistorySeq('s1'), 8);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test('unacked in-flight input is requeued when socket closes', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');
      final socket = await socketReady.future;
      await _waitForBridgeConnection(bridge);
      await _authorizeLegacyBridge(bridge, socket);

      bridge.send(
        ClientMessage.input(
          'retry after reconnect',
          sessionId: 's1',
          clientMessageId: 'cm-retry',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_offlinePendingMessagesV2Key);
      expect(raw, hasLength(1));
      expect(_offlineEnvelopeMessage(raw!.single), {
        'type': 'input',
        'text': 'retry after reconnect',
        'sessionId': 's1',
        'clientMessageId': 'cm-retry',
      });

      bridge.disconnect();
      await server.close(force: true);
      bridge.dispose();
    });

    test(
      'unacked input survives app disposal and replays idempotently',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final firstSocketReady = Completer<WebSocket>();
        final secondSocketReady = Completer<WebSocket>();
        final firstReceived = <Map<String, dynamic>>[];
        final secondReceived = <Map<String, dynamic>>[];
        var connectionCount = 0;

        server.transform(WebSocketTransformer()).listen((socket) {
          connectionCount += 1;
          final received = connectionCount == 1
              ? firstReceived
              : secondReceived;
          socket.listen((data) {
            received.add(jsonDecode(data as String) as Map<String, dynamic>);
          });
          if (connectionCount == 1) {
            firstSocketReady.complete(socket);
          } else {
            secondSocketReady.complete(socket);
          }
        });

        final firstBridge = BridgeService();
        firstBridge.connect('ws://127.0.0.1:${server.port}');
        final firstSocket = await firstSocketReady.future;
        await _waitForBridgeConnection(firstBridge);
        await _authorizeLegacyBridge(firstBridge, firstSocket);

        firstBridge.send(
          ClientMessage.input(
            'keep after app exit',
            sessionId: 's1',
            clientMessageId: 'cm-app-exit',
          ),
        );
        for (var attempt = 0; attempt < 100; attempt++) {
          final prefs = await SharedPreferences.getInstance();
          if (prefs.getStringList(_offlinePendingMessagesV2Key)?.isNotEmpty ==
              true) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        var prefs = await SharedPreferences.getInstance();
        var raw = prefs.getStringList(_offlinePendingMessagesV2Key);
        expect(raw, hasLength(1));
        expect(_offlineEnvelopeMessage(raw!.single), {
          'type': 'input',
          'text': 'keep after app exit',
          'sessionId': 's1',
          'clientMessageId': 'cm-app-exit',
        });
        expect(
          firstReceived.where(
            (message) =>
                message['type'] == 'input' &&
                message['clientMessageId'] == 'cm-app-exit',
          ),
          hasLength(1),
        );

        firstBridge.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList(_offlinePendingMessagesV2Key), hasLength(1));

        final secondBridge = BridgeService();
        secondBridge.connect('ws://127.0.0.1:${server.port}');
        final secondSocket = await secondSocketReady.future;
        await _waitForBridgeConnection(secondBridge);
        await _authorizeLegacyBridge(secondBridge, secondSocket);
        for (var attempt = 0; attempt < 100; attempt++) {
          if (secondReceived.any(
            (message) =>
                message['type'] == 'input' &&
                message['clientMessageId'] == 'cm-app-exit',
          )) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        expect(
          secondReceived.where(
            (message) =>
                message['type'] == 'input' &&
                message['clientMessageId'] == 'cm-app-exit',
          ),
          hasLength(1),
        );
        secondSocket.add(
          jsonEncode({
            'type': 'input_ack',
            'sessionId': 's1',
            'clientMessageId': 'cm-app-exit',
            'queued': true,
          }),
        );
        for (var attempt = 0; attempt < 100; attempt++) {
          prefs = await SharedPreferences.getInstance();
          if (prefs.getStringList(_offlinePendingMessagesV2Key) == null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        raw = prefs.getStringList(_offlinePendingMessagesV2Key);
        expect(raw, isNull);

        secondBridge.disconnect();
        await firstSocket.close();
        await secondSocket.close();
        await server.close(force: true);
        secondBridge.dispose();
      },
    );

    test('acked in-flight input is not requeued when socket closes', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');
      final socket = await socketReady.future;
      await _waitForBridgeConnection(bridge);
      await _authorizeLegacyBridge(bridge, socket);

      bridge.send(
        ClientMessage.input(
          'already accepted',
          sessionId: 's1',
          clientMessageId: 'cm-acked',
        ),
      );
      socket.add(
        jsonEncode({
          'type': 'input_ack',
          'sessionId': 's1',
          'clientMessageId': 'cm-acked',
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_offlinePendingMessagesV2Key), isNull);
      expect(prefs.getStringList(_offlinePendingMessagesV1Key), isNull);

      bridge.disconnect();
      await server.close(force: true);
      bridge.dispose();
    });

    test(
      'persists selected offline messages and excludes transient reads',
      () async {
        final bridge = BridgeService();

        bridge.send(
          ClientMessage.input(
            'offline',
            sessionId: 's1',
            clientMessageId: 'cm-1',
            baseSeq: 4,
          ),
        );
        bridge.send(ClientMessage.getHistory('s1'));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getStringList(_offlinePendingMessagesV2Key);
        expect(raw, isNotNull);
        expect(raw, hasLength(1));
        expect(_offlineEnvelopeMessage(raw!.single), {
          'type': 'input',
          'text': 'offline',
          'sessionId': 's1',
          'clientMessageId': 'cm-1',
          'baseSeq': 4,
        });

        bridge.dispose();
      },
    );

    test(
      'publishes offline pending start and resume actions with dedupe',
      () async {
        final bridge = BridgeService();
        await pumpEventQueue();

        bridge.send(ClientMessage.start('/home/user/app', provider: 'codex'));
        bridge.send(ClientMessage.start('/home/user/app', provider: 'codex'));
        bridge.send(
          ClientMessage.resumeSession(
            'session-1',
            '/home/user/app',
            provider: 'claude',
          ),
        );
        bridge.send(
          ClientMessage.resumeSession(
            'session-1',
            '/home/user/app',
            provider: 'claude',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bridge.offlinePendingActions, hasLength(2));
        expect(
          bridge.offlinePendingActions.map((action) => action.kind),
          containsAll([
            OfflinePendingActionKind.start,
            OfflinePendingActionKind.resume,
          ]),
        );

        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getStringList(_offlinePendingMessagesV2Key);
        expect(raw, hasLength(2));

        bridge.dispose();
      },
    );

    test('recovers the correlation id for an existing queued resume', () async {
      final bridge = BridgeService();
      await pumpEventQueue();

      bridge.send(
        ClientMessage.resumeSession(
          'session-1',
          '/home/user/app',
          provider: 'codex',
          resumeRequestId: 'resume-request-1',
        ),
      );
      await pumpEventQueue();

      expect(
        bridge.pendingSessionResumeRequestId(
          sessionId: 'session-1',
          provider: 'codex',
        ),
        'resume-request-1',
      );
      expect(
        bridge.pendingSessionResumeRequestId(
          sessionId: 'another-session',
          provider: 'codex',
        ),
        isNull,
      );

      bridge.dispose();
    });

    test('tracks connected start as pending until session_created', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();
      final received = <Map<String, dynamic>>[];

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
        socket.listen((data) {
          received.add(jsonDecode(data as String) as Map<String, dynamic>);
        });
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');
      final socket = await socketReady.future;
      await _waitForBridgeConnection(bridge);
      await _authorizeLegacyBridge(bridge, socket);

      bridge.send(
        ClientMessage.start(
          '/home/user/app',
          provider: 'codex',
          startRequestId: 'start-request-1',
        ),
      );
      bridge.send(
        ClientMessage.start(
          '/home/user/app',
          provider: 'codex',
          startRequestId: 'start-request-2',
        ),
      );
      expect(
        bridge.hasPendingSessionStart(
          projectPath: '/home/user/app',
          provider: 'codex',
        ),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.offlinePendingActions, isEmpty);
      expect(
        received.where((message) => message['type'] == 'start'),
        hasLength(1),
      );

      await Future<void>.delayed(const Duration(milliseconds: 650));

      expect(bridge.offlinePendingActions, hasLength(1));
      expect(
        bridge.offlinePendingActions.single.kind,
        OfflinePendingActionKind.start,
      );
      expect(bridge.offlinePendingActions.single.canCancel, isFalse);

      socket.add(
        jsonEncode({
          'type': 'session_list',
          'bridgeCapabilities': [sessionRequestCorrelationCapability],
          'sessions': [
            {
              'id': 'running-before-created',
              'provider': 'codex',
              'projectPath': '/home/user/app',
              'status': 'starting',
            },
          ],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bridge.offlinePendingActions, hasLength(1));

      socket.add(
        jsonEncode({
          'type': 'system',
          'subtype': 'session_start_failed',
          'provider': 'codex',
          'projectPath': '/home/user/app',
          'startRequestId': 'another-request',
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bridge.offlinePendingActions, hasLength(1));

      socket.add(
        jsonEncode({
          'type': 'system',
          'subtype': 'session_created',
          'sessionId': 'running-1',
          'provider': 'codex',
          'projectPath': '/home/user/app',
          'startRequestId': 'start-request-1',
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.offlinePendingActions, isEmpty);

      bridge.send(
        ClientMessage.start(
          '/home/user/app',
          provider: 'codex',
          startRequestId: 'start-request-failed',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(bridge.offlinePendingActions, hasLength(1));

      socket.add(
        jsonEncode({
          'type': 'system',
          'subtype': 'session_start_failed',
          'provider': 'codex',
          'projectPath': '/home/user/app',
          'startRequestId': 'start-request-failed',
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bridge.offlinePendingActions, isEmpty);

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test(
      'resume failure clears the processing action and allows retry',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final bridge = BridgeService();
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        await _authorizeLegacyBridge(bridge, socket);

        bridge.send(
          ClientMessage.resumeSession(
            'thread-with-images',
            '/home/user/app',
            provider: 'codex',
            resumeRequestId: 'resume-request-1',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(bridge.offlinePendingActions, isEmpty);

        socket.add(
          jsonEncode({
            'type': 'system',
            'subtype': 'session_resume_started',
            'sourceSessionId': 'thread-with-images',
            'provider': 'codex',
            'projectPath': '/home/user/app',
            'resumeRequestId': 'resume-request-1',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bridge.offlinePendingActions, hasLength(1));
        expect(
          bridge.offlinePendingActions.single.state,
          OfflinePendingActionState.processing,
        );
        expect(bridge.offlinePendingActions.single.canCancel, isFalse);

        socket.add(
          jsonEncode({
            'type': 'system',
            'subtype': 'session_resume_failed',
            'sourceSessionId': 'thread-with-images',
            'provider': 'codex',
            'projectPath': '/home/user/app',
            'resumeRequestId': 'another-request',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(bridge.offlinePendingActions, hasLength(1));

        socket.add(
          jsonEncode({
            'type': 'system',
            'subtype': 'session_resume_failed',
            'sourceSessionId': 'thread-with-images',
            'provider': 'codex',
            'projectPath': '/home/user/app',
            'resumeRequestId': 'resume-request-1',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bridge.offlinePendingActions, isEmpty);

        bridge.send(
          ClientMessage.resumeSession(
            'thread-with-images',
            '/home/user/app',
            provider: 'codex',
          ),
        );
        socket.add(
          jsonEncode({
            'type': 'system',
            'subtype': 'session_resume_started',
            'sourceSessionId': 'thread-with-images',
            'provider': 'codex',
            'projectPath': '/home/user/app',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bridge.offlinePendingActions, hasLength(1));
        expect(
          bridge.offlinePendingActions.single.state,
          OfflinePendingActionState.processing,
        );

        socket.add(
          jsonEncode({
            'type': 'system',
            'subtype': 'session_created',
            'sessionId': 'running-1',
            'claudeSessionId': 'thread-with-images',
            'provider': 'codex',
            'projectPath': '/home/user/app',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bridge.offlinePendingActions, isEmpty);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'clears connected pending start when session_created path differs',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final bridge = BridgeService();
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        await _authorizeLegacyBridge(bridge, socket);

        bridge.send(
          ClientMessage.start(
            '/mnt/obsidian-data/obsidian-vault',
            provider: 'codex',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 650));

        expect(bridge.offlinePendingActions, hasLength(1));

        socket.add(
          jsonEncode({
            'type': 'system',
            'subtype': 'session_created',
            'sessionId': 'running-1',
            'provider': 'codex',
            'projectPath': '/home/user/obsidian-vault',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bridge.offlinePendingActions, isEmpty);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'session_list clears stale pending start for active session',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });

        final bridge = BridgeService();
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        await _authorizeLegacyBridge(bridge, socket);

        bridge.send(
          ClientMessage.start(
            '/mnt/obsidian-data/obsidian-vault',
            provider: 'codex',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 650));

        expect(bridge.offlinePendingActions, hasLength(1));

        socket.add(
          jsonEncode({
            'type': 'session_list',
            'sessions': [
              {
                'id': 'running-1',
                'provider': 'codex',
                'projectPath': '/home/user/obsidian-vault',
                'status': 'running',
              },
            ],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bridge.offlinePendingActions, isEmpty);
        expect(bridge.sessions.single.id, 'running-1');

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test('session_list keeps pending start for a different project', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');
      final socket = await socketReady.future;
      await _waitForBridgeConnection(bridge);
      await _authorizeLegacyBridge(bridge, socket);

      bridge.send(
        ClientMessage.start('/home/user/project-a', provider: 'codex'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 650));

      expect(bridge.offlinePendingActions, hasLength(1));

      socket.add(
        jsonEncode({
          'type': 'session_list',
          'sessions': [
            {
              'id': 'running-1',
              'provider': 'codex',
              'projectPath': '/home/user/project-b',
              'status': 'running',
            },
          ],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.offlinePendingActions, hasLength(1));
      expect(
        bridge.offlinePendingActions.single.projectPath,
        '/home/user/project-a',
      );

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test('requeues in-flight pending start when socket closes', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');
      final socket = await socketReady.future;
      await _waitForBridgeConnection(bridge);
      await _authorizeLegacyBridge(bridge, socket);

      bridge.send(ClientMessage.start('/home/user/app', provider: 'codex'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bridge.offlinePendingActions, isEmpty);

      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(bridge.offlinePendingActions, hasLength(1));
      expect(bridge.offlinePendingActions.single.canCancel, isTrue);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_offlinePendingMessagesV2Key);
      expect(raw, hasLength(1));
      expect(
        _offlineEnvelopeMessage(raw!.single),
        containsPair('type', 'start'),
      );

      bridge.disconnect();
      await server.close(force: true);
      bridge.dispose();
    });

    test(
      'cancelOfflinePendingAction removes queued action and persistence',
      () async {
        final bridge = BridgeService();
        await pumpEventQueue();

        bridge.send(
          ClientMessage.resumeSession(
            'session-1',
            '/home/user/app',
            provider: 'claude',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final actionId = bridge.offlinePendingActions.single.id;
        await bridge.cancelOfflinePendingAction(actionId);

        expect(bridge.offlinePendingActions, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList(_offlinePendingMessagesV2Key), isNull);

        bridge.dispose();
      },
    );

    test(
      'updates and cancels offline pending input by clientMessageId',
      () async {
        final bridge = BridgeService();
        await pumpEventQueue();

        bridge.send(
          ClientMessage.input(
            'Original',
            sessionId: 's1',
            clientMessageId: 'cm-1',
            baseSeq: 2,
            skills: const [
              {'name': 'skill-a', 'path': '/tmp/skill-a/SKILL.md'},
            ],
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final updated = await bridge.updateOfflinePendingInput(
          sessionId: 's1',
          clientMessageId: 'cm-1',
          text: 'Edited',
          mentions: const [
            {'name': 'Demo App', 'path': 'app://demo'},
          ],
        );
        expect(updated, isTrue);

        var prefs = await SharedPreferences.getInstance();
        var raw = prefs.getStringList(_offlinePendingMessagesV2Key);
        expect(raw, hasLength(1));
        expect(_offlineEnvelopeMessage(raw!.single), {
          'type': 'input',
          'text': 'Edited',
          'sessionId': 's1',
          'clientMessageId': 'cm-1',
          'baseSeq': 2,
          'mentions': [
            {'name': 'Demo App', 'path': 'app://demo'},
          ],
        });

        final canceled = await bridge.cancelOfflinePendingInput(
          sessionId: 's1',
          clientMessageId: 'cm-1',
        );
        expect(canceled, isTrue);
        prefs = await SharedPreferences.getInstance();
        raw = prefs.getStringList(_offlinePendingMessagesV2Key);
        expect(raw, isNull);

        bridge.dispose();
      },
    );

    test(
      'waits for authoritative identity then replays on another route to the '
      'same Bridge',
      () async {
        SharedPreferences.setMockInitialValues({
          _offlinePendingMessagesV2Key: [
            _offlineEnvelope(
              message: {
                'type': 'rename_session',
                'sessionId': 's1',
                'name': 'Renamed',
              },
              routeIdentity: 'logical:machine:old-route',
              bridgeInstanceId: 'bridge-1',
              codexSourceId: 'source-1',
            ),
          ],
        });
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        final sawCapabilities = Completer<void>();
        final sawRename = Completer<void>();
        final received = <Map<String, dynamic>>[];

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
          socket.listen((data) {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            received.add(json);
            if (json['type'] == 'client_capabilities' &&
                !sawCapabilities.isCompleted) {
              sawCapabilities.complete();
            }
            if (json['type'] == 'rename_session' && !sawRename.isCompleted) {
              sawRename.complete();
            }
          });
        });

        final bridge = BridgeService();
        bridge.connect(
          'ws://127.0.0.1:${server.port}',
          logicalConnectionIdentity: 'machine:new-route',
          expectedBridgeInstanceId: 'bridge-1',
          expectedCodexSourceId: 'source-1',
        );
        final socket = await socketReady.future;
        await sawCapabilities.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          received.where((message) => message['type'] == 'rename_session'),
          isEmpty,
          reason:
              'WebSocket readiness and a remembered identity are not '
              'authoritative enough to replay a mutation.',
        );
        expect(bridge.queuedMessageCountForTest, 1);

        socket.add(
          jsonEncode({
            'type': 'session_list',
            'bridgeInstanceId': 'bridge-1',
            'codexSourceId': 'source-1',
            'sessions': [],
          }),
        );

        await sawRename.future.timeout(const Duration(seconds: 2));
        expect(
          received.any(
            (message) =>
                message['type'] == 'rename_session' &&
                message['sessionId'] == 's1' &&
                message['name'] == 'Renamed',
          ),
          isTrue,
        );
        expect(bridge.queuedMessageCountForTest, 0);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList(_offlinePendingMessagesV2Key), isNull);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    for (final scenario in [
      (
        name: 'different Bridge',
        bridgeInstanceId: 'bridge-2',
        codexSourceId: 'source-1',
      ),
      (
        name: 'same Bridge with a different Codex source',
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'source-2',
      ),
    ]) {
      test('keeps queued mutation for ${scenario.name}', () async {
        SharedPreferences.setMockInitialValues({
          _offlinePendingMessagesV2Key: [
            _offlineEnvelope(
              message: {
                'type': 'rename_session',
                'sessionId': 's1',
                'name': 'Renamed',
              },
              routeIdentity: 'logical:machine:old-route',
              bridgeInstanceId: 'bridge-1',
              codexSourceId: 'source-1',
            ),
          ],
        });
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        final sawCapabilities = Completer<void>();
        final received = <Map<String, dynamic>>[];

        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
          socket.listen((data) {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            received.add(json);
            if (json['type'] == 'client_capabilities' &&
                !sawCapabilities.isCompleted) {
              sawCapabilities.complete();
            }
          });
        });

        final bridge = BridgeService();
        bridge.connect(
          'ws://127.0.0.1:${server.port}',
          logicalConnectionIdentity: 'machine:new-route',
          expectedBridgeInstanceId: 'bridge-1',
          expectedCodexSourceId: 'source-1',
        );
        final socket = await socketReady.future;
        await sawCapabilities.future.timeout(const Duration(seconds: 2));
        socket.add(
          jsonEncode({
            'type': 'session_list',
            'bridgeInstanceId': scenario.bridgeInstanceId,
            'codexSourceId': scenario.codexSourceId,
            'sessions': [],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(
          received.where((message) => message['type'] == 'rename_session'),
          isEmpty,
        );
        expect(bridge.queuedMessageCountForTest, 1);
        final prefs = await SharedPreferences.getInstance();
        final persisted = prefs.getStringList(_offlinePendingMessagesV2Key);
        expect(persisted, hasLength(1));
        expect(_offlineEnvelopeMessage(persisted!.single), {
          'type': 'rename_session',
          'sessionId': 's1',
          'name': 'Renamed',
        });

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      });
    }

    test(
      'clears runtime bindings when one route changes Codex source',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen(socketReady.complete);

        final bridge = BridgeService();
        bridge.connect(
          'ws://127.0.0.1:${server.port}',
          logicalConnectionIdentity: 'machine:one-route',
          expectedBridgeInstanceId: 'bridge-1',
          expectedCodexSourceId: 'source-1',
        );
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        socket.add(
          jsonEncode({
            'type': 'session_list',
            'bridgeInstanceId': 'bridge-1',
            'codexSourceId': 'source-1',
            'allowedDirs': ['/source-1'],
            'sessions': [
              {
                'id': 'runtime-source-1',
                'provider': 'codex',
                'claudeSessionId': 'provider-source-1',
                'projectPath': '/source-1/project',
                'status': 'idle',
              },
            ],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          bridge.providerSessionIdForRuntime(
            'runtime-source-1',
            provider: 'codex',
          ),
          'provider-source-1',
        );
        expect(bridge.allowedDirs, ['/source-1']);

        socket.add(
          jsonEncode({
            'type': 'session_list',
            'bridgeInstanceId': 'bridge-1',
            'codexSourceId': 'source-2',
            'allowedDirs': ['/source-2'],
            'sessions': [
              {
                'id': 'runtime-source-2',
                'provider': 'codex',
                'claudeSessionId': 'provider-source-2',
                'projectPath': '/source-2/project',
                'status': 'idle',
              },
            ],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bridge.codexSourceId, 'source-2');
        expect(bridge.sessions.map((session) => session.id), [
          'runtime-source-2',
        ]);
        expect(
          bridge.providerSessionIdForRuntime(
            'runtime-source-1',
            provider: 'codex',
          ),
          isNull,
        );
        expect(
          bridge.providerSessionIdForRuntime(
            'runtime-source-2',
            provider: 'codex',
          ),
          'provider-source-2',
        );
        expect(bridge.allowedDirs, ['/source-2']);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'promotes a current-epoch endpoint queue after first identity proof',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        final sawRename = Completer<void>();
        final received = <Map<String, dynamic>>[];
        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
          socket.listen((data) {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            received.add(json);
            if (json['type'] == 'rename_session' && !sawRename.isCompleted) {
              sawRename.complete();
            }
          });
        });

        final bridge = BridgeService();
        bridge.connect(
          'ws://127.0.0.1:${server.port}',
          logicalConnectionIdentity: 'machine:first-route',
        );
        final socket = await socketReady.future;
        await _waitForBridgeConnection(bridge);
        bridge.send(
          ClientMessage.renameSession(
            sessionId: 's1',
            name: 'Queued before identity',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          received.where((message) => message['type'] == 'rename_session'),
          isEmpty,
        );
        expect(bridge.queuedMessageCountForTest, 1);

        socket.add(
          jsonEncode({
            'type': 'session_list',
            'bridgeInstanceId': 'bridge-1',
            'codexSourceId': 'source-1',
            'sessions': [],
          }),
        );

        await sawRename.future.timeout(const Duration(seconds: 2));
        expect(bridge.queuedMessageCountForTest, 0);

        bridge.disconnect();
        await socket.close();
        await server.close(force: true);
        bridge.dispose();
      },
    );

    test(
      'connection switch during flush requeues and resumes on the same source',
      () async {
        SharedPreferences.setMockInitialValues({
          _offlinePendingMessagesV2Key: [
            _offlineEnvelope(
              message: {
                'type': 'rename_session',
                'sessionId': 's1',
                'name': 'Fenced rename',
              },
              routeIdentity: 'logical:machine:old-route',
              bridgeInstanceId: 'bridge-1',
              codexSourceId: 'source-1',
            ),
          ],
        });
        final firstServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final secondServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final firstSocketReady = Completer<WebSocket>();
        final secondSocketReady = Completer<WebSocket>();
        final firstReceived = <Map<String, dynamic>>[];
        final secondReceived = <Map<String, dynamic>>[];
        firstServer.transform(WebSocketTransformer()).listen((socket) {
          firstSocketReady.complete(socket);
          socket.listen((data) {
            firstReceived.add(
              jsonDecode(data as String) as Map<String, dynamic>,
            );
          });
        });
        secondServer.transform(WebSocketTransformer()).listen((socket) {
          secondSocketReady.complete(socket);
          socket.listen((data) {
            secondReceived.add(
              jsonDecode(data as String) as Map<String, dynamic>,
            );
          });
        });

        final firstFlushEntered = Completer<void>();
        final releaseFirstFlush = Completer<void>();
        var barrierCalls = 0;
        final bridge = BridgeService()
          ..offlineFlushBarrierForTest = () {
            barrierCalls += 1;
            if (barrierCalls != 1) return Future<void>.value();
            firstFlushEntered.complete();
            return releaseFirstFlush.future;
          };
        bridge.connect(
          'ws://127.0.0.1:${firstServer.port}',
          logicalConnectionIdentity: 'machine:first-route',
          expectedBridgeInstanceId: 'bridge-1',
          expectedCodexSourceId: 'source-1',
        );
        final firstSocket = await firstSocketReady.future;
        await _waitForBridgeConnection(bridge);
        firstSocket.add(
          jsonEncode({
            'type': 'session_list',
            'bridgeInstanceId': 'bridge-1',
            'codexSourceId': 'source-1',
            'sessions': [],
          }),
        );
        await firstFlushEntered.future.timeout(const Duration(seconds: 2));

        bridge.connect(
          'ws://127.0.0.1:${secondServer.port}',
          logicalConnectionIdentity: 'machine:second-route',
          expectedBridgeInstanceId: 'bridge-1',
          expectedCodexSourceId: 'source-1',
        );
        final secondSocket = await secondSocketReady.future;
        await _waitForBridgeConnection(bridge);
        secondSocket.add(
          jsonEncode({
            'type': 'session_list',
            'bridgeInstanceId': 'bridge-1',
            'codexSourceId': 'source-1',
            'sessions': [],
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        releaseFirstFlush.complete();

        for (var attempt = 0; attempt < 100; attempt++) {
          if (secondReceived.any(
            (message) => message['type'] == 'rename_session',
          )) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          firstReceived.where((message) => message['type'] == 'rename_session'),
          isEmpty,
        );
        expect(
          secondReceived.where(
            (message) => message['type'] == 'rename_session',
          ),
          hasLength(1),
        );
        expect(bridge.queuedMessageCountForTest, 0);

        bridge.disconnect();
        await firstSocket.close();
        await secondSocket.close();
        await firstServer.close(force: true);
        await secondServer.close(force: true);
        bridge.dispose();
      },
    );

    test('cancel only removes the current Bridge source action', () async {
      const pendingStart = {
        'type': 'start',
        'projectPath': '/home/user/app',
        'provider': 'codex',
      };
      SharedPreferences.setMockInitialValues({
        _offlinePendingMessagesV2Key: [
          _offlineEnvelope(
            message: pendingStart,
            routeIdentity: 'logical:machine:source-1-route',
            bridgeInstanceId: 'bridge-1',
            codexSourceId: 'source-1',
          ),
          _offlineEnvelope(
            message: pendingStart,
            routeIdentity: 'logical:machine:source-2-route',
            bridgeInstanceId: 'bridge-1',
            codexSourceId: 'source-2',
          ),
        ],
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();
      server.transform(WebSocketTransformer()).listen(socketReady.complete);

      final bridge = BridgeService();
      bridge.connect(
        'ws://127.0.0.1:${server.port}',
        logicalConnectionIdentity: 'machine:source-1-route',
        expectedBridgeInstanceId: 'bridge-1',
        expectedCodexSourceId: 'source-1',
      );
      final socket = await socketReady.future;
      await _waitForBridgeConnection(bridge);
      for (var attempt = 0; attempt < 100; attempt++) {
        if (bridge.offlinePendingActions.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(bridge.offlinePendingActions, hasLength(1));
      await bridge.cancelOfflinePendingAction(
        bridge.offlinePendingActions.single.id,
      );

      expect(bridge.offlinePendingActions, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      final persisted = prefs.getStringList(_offlinePendingMessagesV2Key);
      expect(persisted, hasLength(1));
      expect(_offlineEnvelopeMessage(persisted!.single), pendingStart);
      expect(_offlineEnvelopeTarget(persisted.single), {
        'routeIdentity': 'logical:machine:source-2-route',
        'bridgeInstanceId': 'bridge-1',
        'codexSourceId': 'source-2',
      });

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test('legacy queue stays tied to the exact endpoint route', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final currentRoute =
          'logical:machine:shared-machine|endpoint:'
          'ws://127.0.0.1:${server.port}/';
      final previousRoute =
          'logical:machine:shared-machine|endpoint:'
          'ws://127.0.0.1:${server.port == 1 ? 2 : server.port - 1}/';
      SharedPreferences.setMockInitialValues({
        _offlinePendingMessagesV2Key: [
          jsonEncode({
            'version': 2,
            'message': {
              'type': 'rename_session',
              'sessionId': 's1',
              'name': 'Legacy route rename',
            },
            'target': {
              'routeIdentity': previousRoute,
              'bridgeInstanceId': null,
              'codexSourceId': null,
            },
          }),
        ],
      });
      final socketReady = Completer<WebSocket>();
      final received = <Map<String, dynamic>>[];
      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
        socket.listen((data) {
          received.add(jsonDecode(data as String) as Map<String, dynamic>);
        });
      });

      final bridge = BridgeService();
      bridge.connect(
        'ws://127.0.0.1:${server.port}',
        logicalConnectionIdentity: 'machine:shared-machine',
      );
      final socket = await socketReady.future;
      await _waitForBridgeConnection(bridge);
      socket.add(jsonEncode({'type': 'session_list', 'sessions': []}));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(currentRoute, isNot(previousRoute));
      expect(
        received.where((message) => message['type'] == 'rename_session'),
        isEmpty,
      );
      expect(bridge.queuedMessageCountForTest, 1);

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });

    test('does not replay legacy v1 queue without target identity', () async {
      SharedPreferences.setMockInitialValues({
        _offlinePendingMessagesV1Key: [
          jsonEncode({
            'type': 'rename_session',
            'sessionId': 's1',
            'name': 'Legacy rename',
          }),
        ],
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();
      final sawCapabilities = Completer<void>();
      final received = <Map<String, dynamic>>[];

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
        socket.listen((data) {
          final json = jsonDecode(data as String) as Map<String, dynamic>;
          received.add(json);
          if (json['type'] == 'client_capabilities' &&
              !sawCapabilities.isCompleted) {
            sawCapabilities.complete();
          }
        });
      });

      final bridge = BridgeService();
      bridge.connect(
        'ws://127.0.0.1:${server.port}',
        logicalConnectionIdentity: 'machine:new-route',
        expectedBridgeInstanceId: 'bridge-1',
        expectedCodexSourceId: 'source-1',
      );
      final socket = await socketReady.future;
      await sawCapabilities.future.timeout(const Duration(seconds: 2));
      socket.add(
        jsonEncode({
          'type': 'session_list',
          'bridgeInstanceId': 'bridge-1',
          'codexSourceId': 'source-1',
          'sessions': [],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        received.where((message) => message['type'] == 'rename_session'),
        isEmpty,
      );
      expect(bridge.queuedMessageCountForTest, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_offlinePendingMessagesV1Key), hasLength(1));

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
    });
  });
}
