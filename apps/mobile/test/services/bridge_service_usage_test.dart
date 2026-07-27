import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/models/offline_pending_action.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

      bridge.disconnect();

      expect(bridge.allowedDirs, isEmpty);
      expect(bridge.projectHistory, isEmpty);
      expect(bridge.codexProfiles, isEmpty);
      expect(bridge.bridgeVersion, isNull);

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
      'computer activity timestamps reorder cached sessions without delta spam',
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
        bridge.requestSessionHistory('queued-session');
        expect(bridge.isSessionHistorySyncing('queued-session'), isFalse);

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.transform(WebSocketTransformer()).listen((socket) {
          socketReady.complete(socket);
        });
        final becameActive = bridge.sessionHistorySyncChanges.first;
        bridge.connect('ws://127.0.0.1:${server.port}');
        final socket = await socketReady.future;

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
        // A stale foreground request must not leave full-history fallback
        // enabled after the latest bounded background request takes ownership.
        bridge.requestSessionHistory('s1');
        expect(bridge.isSessionHistorySyncing('s1'), isTrue);
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

    test('session list preserves visible delivery pending input', () async {
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

      expect(bridge.sessions.single.queuedInput?.itemId, 'pending:cm-1');
      expect(bridge.sessions.single.queuedInput?.text, 'Pending delivery');

      socket.add(
        jsonEncode({
          'type': 'input_ack',
          'sessionId': 's1',
          'clientMessageId': 'cm-1',
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.sessions.single.queuedInput, isNull);

      bridge.disconnect();
      await socket.close();
      await server.close(force: true);
      bridge.dispose();
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
        await Future<void>.delayed(const Duration(milliseconds: 50));

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
        await Future<void>.delayed(const Duration(milliseconds: 50));

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
      await Future<void>.delayed(const Duration(milliseconds: 50));

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
      final raw = prefs.getStringList('bridge_offline_pending_messages_v1');
      expect(raw, hasLength(1));
      expect(jsonDecode(raw!.single), {
        'type': 'input',
        'text': 'retry after reconnect',
        'sessionId': 's1',
        'clientMessageId': 'cm-retry',
      });

      bridge.disconnect();
      await server.close(force: true);
      bridge.dispose();
    });

    test('acked in-flight input is not requeued when socket closes', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();

      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });

      final bridge = BridgeService();
      bridge.connect('ws://127.0.0.1:${server.port}');
      final socket = await socketReady.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

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
      expect(prefs.getStringList('bridge_offline_pending_messages_v1'), isNull);

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
        final raw = prefs.getStringList('bridge_offline_pending_messages_v1');
        expect(raw, isNotNull);
        expect(raw, hasLength(1));
        expect(jsonDecode(raw!.single), {
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
        final raw = prefs.getStringList('bridge_offline_pending_messages_v1');
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
      await Future<void>.delayed(const Duration(milliseconds: 50));

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
        await Future<void>.delayed(const Duration(milliseconds: 50));

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
        await Future<void>.delayed(const Duration(milliseconds: 50));

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
        await Future<void>.delayed(const Duration(milliseconds: 50));

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
      await Future<void>.delayed(const Duration(milliseconds: 50));

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
      await Future<void>.delayed(const Duration(milliseconds: 50));

      bridge.send(ClientMessage.start('/home/user/app', provider: 'codex'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bridge.offlinePendingActions, isEmpty);

      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(bridge.offlinePendingActions, hasLength(1));
      expect(bridge.offlinePendingActions.single.canCancel, isTrue);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('bridge_offline_pending_messages_v1');
      expect(raw, hasLength(1));
      expect(jsonDecode(raw!.single), containsPair('type', 'start'));

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
        expect(
          prefs.getStringList('bridge_offline_pending_messages_v1'),
          isNull,
        );

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
        var raw = prefs.getStringList('bridge_offline_pending_messages_v1');
        expect(raw, hasLength(1));
        expect(jsonDecode(raw!.single), {
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
        raw = prefs.getStringList('bridge_offline_pending_messages_v1');
        expect(raw, isNull);

        bridge.dispose();
      },
    );

    test(
      'restores persisted offline messages and clears them after flush',
      () async {
        SharedPreferences.setMockInitialValues({
          'bridge_offline_pending_messages_v1': [
            jsonEncode({
              'type': 'rename_session',
              'sessionId': 's1',
              'name': 'Renamed',
            }),
          ],
        });
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final received = <Map<String, dynamic>>[];
        final sawRename = Completer<void>();

        server.transform(WebSocketTransformer()).listen((socket) {
          socket.listen((data) {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            received.add(json);
            if (json['type'] == 'rename_session' && !sawRename.isCompleted) {
              sawRename.complete();
            }
          });
        });

        final bridge = BridgeService();
        bridge.connect('ws://127.0.0.1:${server.port}');

        await sawRename.future.timeout(const Duration(seconds: 2));
        expect(
          received.any(
            (message) =>
                message['type'] == 'client_capabilities' &&
                message['supportedServerMessages'] is List,
          ),
          isTrue,
        );
        expect(
          received.any(
            (message) =>
                message['type'] == 'rename_session' &&
                message['sessionId'] == 's1' &&
                message['name'] == 'Renamed',
          ),
          isTrue,
        );

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getStringList('bridge_offline_pending_messages_v1'),
          isNull,
        );

        bridge.disconnect();
        await server.close(force: true);
        bridge.dispose();
      },
    );
  });
}
