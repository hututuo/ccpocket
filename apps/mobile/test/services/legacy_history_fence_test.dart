import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// P0-3 regression: a late legacy `history` full frame must not overwrite
/// real-time messages that arrived after it was requested, and must not
/// reset the seq watermark of a snapshot-synced session.
void main() {
  late HttpServer server;
  late BridgeService bridge;
  late WebSocket socket;
  late Stream<Map<String, dynamic>> incoming;

  Future<void> setUpConnection() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final socketReady = Completer<WebSocket>();
    server.transform(WebSocketTransformer()).listen(socketReady.complete);

    bridge = BridgeService();
    bridge.connect('ws://127.0.0.1:${server.port}');
    socket = await socketReady.future;
    incoming = socket
        .map((data) => jsonDecode(data as String) as Map<String, dynamic>)
        .asBroadcastStream();
  }

  setUp(() async {
    await setUpConnection();
  });

  tearDown(() async {
    bridge.dispose();
    await server.close(force: true);
  });

  Map<String, dynamic> assistantJson(String text, {required String session}) =>
      {
        'type': 'assistant',
        'sessionId': session,
        'message': {
          'id': 'msg-$text',
          'role': 'assistant',
          'model': 'test-model',
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
      };

  Map<String, dynamic> historyFrame(
    String session,
    List<Map<String, dynamic>> messages,
  ) => {'type': 'history', 'sessionId': session, 'messages': messages};

  List<String> assistantTexts(BridgeService bridge, String session) => bridge
      .cachedSessionMessages(session)
      .whereType<AssistantServerMessage>()
      .map(
        (m) => m.message.content
            .whereType<TextContent>()
            .map((c) => c.text)
            .join(),
      )
      .toList();

  Future<void> pump() async {
    // Let socket frames cross the loopback and the app process them.
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('hydrates an empty store from the legacy full frame', () async {
    bridge.requestSessionHistory('s1');
    await incoming.firstWhere((m) => m['type'] == 'get_history');

    socket.add(
      jsonEncode(
        historyFrame('s1', [
          assistantJson('h1', session: 's1'),
          assistantJson('h2', session: 's1'),
        ]),
      ),
    );
    await pump();

    expect(assistantTexts(bridge, 's1'), ['h1', 'h2']);
  });

  test(
    'drops a late full frame once newer real-time content arrived',
    () async {
      // Seed the store so the next request takes the delta path first.
      socket.add(jsonEncode(assistantJson('live-A', session: 's1')));
      await pump();
      expect(assistantTexts(bridge, 's1'), ['live-A']);

      bridge.requestSessionHistory('s1');
      await incoming.firstWhere((m) => m['type'] == 'get_history_delta');

      // Old Bridge: delta unsupported → the app falls back to get_history.
      socket.add(
        jsonEncode({
          'type': 'error',
          'errorCode': 'unsupported_message',
          'message': 'get_history_delta',
        }),
      );
      await incoming.firstWhere((m) => m['type'] == 'get_history');

      // A newer real-time message lands before the full frame does.
      socket.add(jsonEncode(assistantJson('live-B', session: 's1')));
      await pump();

      // The stale frame (its content basis predates live-B) arrives late.
      socket.add(
        jsonEncode(historyFrame('s1', [assistantJson('h1', session: 's1')])),
      );
      await pump();

      // live-B must survive; the stale frame is discarded.
      expect(assistantTexts(bridge, 's1'), ['live-A', 'live-B']);
    },
  );

  test('applies the fallback full frame when nothing newer arrived', () async {
    socket.add(jsonEncode(assistantJson('live-A', session: 's1')));
    await pump();

    bridge.requestSessionHistory('s1');
    await incoming.firstWhere((m) => m['type'] == 'get_history_delta');
    socket.add(
      jsonEncode({
        'type': 'error',
        'errorCode': 'unsupported_message',
        'message': 'get_history_delta',
      }),
    );
    await incoming.firstWhere((m) => m['type'] == 'get_history');

    socket.add(
      jsonEncode(
        historyFrame('s1', [
          assistantJson('h1', session: 's1'),
          assistantJson('live-A', session: 's1'),
        ]),
      ),
    );
    await pump();

    // Pure resync: the frame replaces the store as before.
    expect(assistantTexts(bridge, 's1'), ['h1', 'live-A']);
  });

  test(
    'unsolicited full frame cannot clobber a snapshot-synced session',
    () async {
      socket.add(
        jsonEncode({
          'type': 'history_snapshot',
          'sessionId': 's1',
          'fromSeq': 1,
          'toSeq': 2,
          'reason': 'reset',
          'messages': [
            {'seq': 1, 'message': assistantJson('snap-1', session: 's1')},
            {'seq': 2, 'message': assistantJson('snap-2', session: 's1')},
          ],
        }),
      );
      await pump();
      expect(assistantTexts(bridge, 's1'), ['snap-1', 'snap-2']);
      expect(bridge.cachedSessionHistorySeq('s1'), 2);

      // No get_history is outstanding: a full frame arriving now would have
      // wiped the store and reset the watermark to 0 (full re-pull loop).
      socket.add(
        jsonEncode(historyFrame('s1', [assistantJson('h1', session: 's1')])),
      );
      await pump();

      expect(assistantTexts(bridge, 's1'), ['snap-1', 'snap-2']);
      expect(bridge.cachedSessionHistorySeq('s1'), 2);
    },
  );
}
