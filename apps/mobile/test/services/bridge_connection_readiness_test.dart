import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/core/logger.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _testAuthorityTimeout = Duration(milliseconds: 150);
const _afterAuthorityTimeout = Duration(milliseconds: 250);

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

List<String> _connectionDiagnostics() => logger.history
    .map((entry) => entry.message ?? '')
    .where((message) => message.startsWith('[bridge_connection]'))
    .toList(growable: false);

Future<void> _closeFixture(
  BridgeService bridge,
  HttpServer server,
  Iterable<WebSocket> sockets,
) async {
  bridge.disconnect();
  bridge.dispose();
  for (final socket in sockets) {
    try {
      await socket.close();
    } catch (_) {
      // The watchdog may already have closed the first half-open socket.
    }
  }
  await server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    logger.cleanHistory();
  });

  tearDown(logger.cleanHistory);

  test(
    'half-open authority handshake rebuilds the socket and requests again',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      var listSessionRequests = 0;
      final requestsByConnection = <int, int>{};
      server.transform(WebSocketTransformer()).listen((socket) {
        sockets.add(socket);
        final connectionNumber = sockets.length;
        socket.listen((data) {
          final message = jsonDecode(data as String) as Map<String, dynamic>;
          if (message['type'] != 'list_sessions') return;
          listSessionRequests += 1;
          requestsByConnection.update(
            connectionNumber,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
          if (connectionNumber == 1) return;
          socket.add(
            jsonEncode({'type': 'session_list', 'sessions': const []}),
          );
        });
      });

      final bridge = BridgeService(
        authoritativeSessionListTimeout: _testAuthorityTimeout,
      )..reconnectDelayForTest = (_) => Duration.zero;
      try {
        bridge.connect(
          'ws://127.0.0.1:${server.port}?token=private-test-token',
        );
        await _waitUntil(() => listSessionRequests == 1);
        bridge.requestSessionList();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(requestsByConnection[1], 1);

        await _waitUntil(
          () =>
              sockets.length >= 2 &&
              bridge.hasAuthoritativeSessionListForCurrentConnection,
        );

        expect(listSessionRequests, greaterThanOrEqualTo(2));
        expect(requestsByConnection[1], 1);
        expect(requestsByConnection[2], 1);
        expect(
          bridge.currentBridgeConnectionState,
          BridgeConnectionState.connected,
        );
        expect(bridge.authoritativeSessionListGeneration, 1);

        final diagnostics = _connectionDiagnostics().join('\n');
        expect(diagnostics, contains('event=session_list_timeout'));
        expect(diagnostics, contains('event=reconnect_scheduled'));
        expect(diagnostics, contains('event=session_list_authoritative'));
        expect(diagnostics, isNot(contains('private-test-token')));
        expect(diagnostics, isNot(contains('127.0.0.1')));
      } finally {
        await _closeFixture(bridge, server, sockets);
      }
    },
  );

  test('legacy session_list cancels the authority watchdog', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    server.transform(WebSocketTransformer()).listen((socket) {
      sockets.add(socket);
      socket.listen((data) {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (message['type'] != 'list_sessions') return;
        socket.add(jsonEncode({'type': 'session_list', 'sessions': const []}));
      });
    });

    final bridge = BridgeService(
      authoritativeSessionListTimeout: _testAuthorityTimeout,
    )..reconnectDelayForTest = (_) => Duration.zero;
    try {
      bridge.connect('ws://127.0.0.1:${server.port}');
      await _waitUntil(
        () => bridge.hasAuthoritativeSessionListForCurrentConnection,
      );
      await Future<void>.delayed(_afterAuthorityTimeout);

      expect(sockets, hasLength(1));
      expect(bridge.bridgeInstanceId, isNull);
      expect(bridge.codexSourceId, isNull);
      expect(
        _connectionDiagnostics().join('\n'),
        isNot(contains('event=session_list_timeout')),
      );
    } finally {
      await _closeFixture(bridge, server, sockets);
    }
  });

  test(
    'malformed first frame is sanitized and recovered by the watchdog',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      server.transform(WebSocketTransformer()).listen((socket) {
        sockets.add(socket);
        final connectionNumber = sockets.length;
        socket.listen((data) {
          final message = jsonDecode(data as String) as Map<String, dynamic>;
          if (message['type'] != 'list_sessions') return;
          if (connectionNumber == 1) {
            socket.add('{private-payload-is-not-json');
            return;
          }
          socket.add(
            jsonEncode({'type': 'session_list', 'sessions': const []}),
          );
        });
      });

      final bridge = BridgeService(
        authoritativeSessionListTimeout: _testAuthorityTimeout,
      )..reconnectDelayForTest = (_) => Duration.zero;
      try {
        bridge.connect('ws://127.0.0.1:${server.port}');
        await _waitUntil(
          () =>
              sockets.length >= 2 &&
              bridge.hasAuthoritativeSessionListForCurrentConnection,
        );

        final diagnostics = _connectionDiagnostics().join('\n');
        expect(diagnostics, contains('event=frame_parse_failed'));
        expect(diagnostics, contains('error=FormatException'));
        expect(diagnostics, isNot(contains('private-payload-is-not-json')));
      } finally {
        await _closeFixture(bridge, server, sockets);
      }
    },
  );

  test('dispose cancels an armed authority watchdog', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    var sawSessionListRequest = false;
    server.transform(WebSocketTransformer()).listen((socket) {
      sockets.add(socket);
      socket.listen((data) {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (message['type'] == 'list_sessions') {
          sawSessionListRequest = true;
        }
      });
    });

    final bridge = BridgeService(
      authoritativeSessionListTimeout: _testAuthorityTimeout,
    )..reconnectDelayForTest = (_) => Duration.zero;
    bridge.connect('ws://127.0.0.1:${server.port}');
    await _waitUntil(() => sawSessionListRequest);
    bridge.dispose();
    await Future<void>.delayed(_afterAuthorityTimeout);

    expect(sockets, hasLength(1));
    expect(
      _connectionDiagnostics().join('\n'),
      isNot(contains('event=session_list_timeout')),
    );
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  });

  test(
    'notification-only reconnect stays lightweight until foreground',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final receivedByConnection = <List<Map<String, dynamic>>>[];
      server.transform(WebSocketTransformer()).listen((socket) {
        sockets.add(socket);
        final received = <Map<String, dynamic>>[];
        receivedByConnection.add(received);
        socket.listen((data) {
          final message = jsonDecode(data as String) as Map<String, dynamic>;
          received.add(message);
          switch (message['type']) {
            case 'list_sessions':
              socket.add(
                jsonEncode({'type': 'session_list', 'sessions': const []}),
              );
            case 'set_client_delivery_mode':
              socket.add(
                jsonEncode({
                  'type': 'client_delivery_mode_state_v1',
                  'requestId': message['requestId'],
                  'mode': message['mode'],
                  'activeWorkCount': 1,
                }),
              );
          }
        });
      });

      final bridge = BridgeService(
        authoritativeSessionListTimeout: _testAuthorityTimeout,
      )..reconnectDelayForTest = (_) => Duration.zero;
      try {
        bridge.connect('ws://127.0.0.1:${server.port}');
        await _waitUntil(
          () => bridge.hasAuthoritativeSessionListForCurrentConnection,
        );
        expect(
          (await bridge.setClientDeliveryMode(
            mode: BridgeClientDeliveryMode.notificationsOnly,
          ))?.mode,
          BridgeClientDeliveryMode.notificationsOnly,
        );

        await sockets.first.close();
        await _waitUntil(
          () =>
              sockets.length == 2 &&
              receivedByConnection[1].any(
                (message) =>
                    message['type'] == 'set_client_delivery_mode' &&
                    message['mode'] == 'notifications_only',
              ),
        );
        await Future<void>.delayed(_afterAuthorityTimeout);

        expect(sockets, hasLength(2));
        expect(
          receivedByConnection[1].where(
            (message) => message['type'] == 'list_sessions',
          ),
          isEmpty,
        );

        final interactive = bridge.setClientDeliveryMode(
          mode: BridgeClientDeliveryMode.interactive,
        );
        expect((await interactive)?.mode, BridgeClientDeliveryMode.interactive);
        await _waitUntil(
          () => bridge.hasAuthoritativeSessionListForCurrentConnection,
        );

        final foregroundMessages = receivedByConnection[1];
        final interactiveIndex = foregroundMessages.indexWhere(
          (message) =>
              message['type'] == 'set_client_delivery_mode' &&
              message['mode'] == 'interactive',
        );
        final sessionListIndex = foregroundMessages.indexWhere(
          (message) => message['type'] == 'list_sessions',
        );
        expect(interactiveIndex, greaterThanOrEqualTo(0));
        expect(sessionListIndex, greaterThan(interactiveIndex));
      } finally {
        await _closeFixture(bridge, server, sockets);
      }
    },
  );
}
