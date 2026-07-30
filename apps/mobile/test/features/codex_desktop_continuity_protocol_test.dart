import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('advertises and encodes Desktop continuity watch requests', () {
    expect(
      LocalFeatureProtocolHost.supportedServerMessageTypes,
      contains('codex_desktop_continuity_event_v1'),
    );
    final request = requestCodexDesktopContinuityWatch(
      requestId: 'watch-1',
      sessionId: 'runtime-1',
      threadId: 'thread-1',
      projectPath: '/project',
    );
    expect(jsonDecode(request.toJson()), {
      'type': 'codex_desktop_continuity_watch',
      'protocolVersion': 1,
      'requestId': 'watch-1',
      'sessionId': 'runtime-1',
      'threadId': 'thread-1',
      'projectPath': '/project',
    });
    expect(
      LocalFeatureProtocolHost.describeRequest(request)?.metadata,
      containsPair('ownerSessionId', 'runtime-1'),
    );
  });

  test(
    'decodes a nested normal chat payload without a second render model',
    () {
      final decoded = ServerMessage.fromJson({
        'type': 'codex_desktop_continuity_event_v1',
        'event': 'message',
        'requestId': 'watch-1',
        'bridgeInstanceId': 'bridge-1',
        'sessionId': 'runtime-1',
        'threadId': 'thread-1',
        'origin': 'desktop_rollout',
        'turnId': 'turn-1',
        'turnSteerable': true,
        'timestamp': '2026-07-31T01:02:03.456Z',
        'itemKey': 'assistant:item-1',
        'message': {
          'type': 'assistant',
          'message': {
            'id': 'item-1',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'progress'},
            ],
            'model': 'codex',
          },
        },
      });
      expect(decoded, isA<CodexDesktopContinuityEventMessage>());
      final event = decoded as CodexDesktopContinuityEventMessage;
      expect(event.payload, isA<AssistantServerMessage>());
      expect(event.sessionId, 'runtime-1');
      expect(event.itemKey, 'assistant:item-1');
      expect(event.turnSteerable, isTrue);
      expect(
        serverMessageTimestamp(event.payload!),
        isA<ServerMessageTimestamp>()
            .having(
              (value) => value.value,
              'value',
              DateTime.parse('2026-07-31T01:02:03.456Z'),
            )
            .having(
              (value) => value.isAuthoritative,
              'isAuthoritative',
              isTrue,
            ),
      );
    },
  );

  test('projects the envelope timestamp onto every live payload kind', () {
    final payloads = <Map<String, dynamic>>[
      {
        'type': 'assistant',
        'message': {
          'id': 'assistant-1',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'answer'},
          ],
          'model': 'codex',
        },
      },
      {'type': 'tool_result', 'toolUseId': 'tool-1', 'content': 'done'},
      {'type': 'thinking_delta', 'text': 'thinking'},
      {'type': 'stream_delta', 'text': 'streaming'},
    ];

    for (var index = 0; index < payloads.length; index += 1) {
      final timestamp = '2026-07-31T01:02:0$index.000Z';
      final event =
          ServerMessage.fromJson({
                'type': 'codex_desktop_continuity_event_v1',
                'event': 'message',
                'requestId': 'watch-$index',
                'bridgeInstanceId': 'bridge-1',
                'sessionId': 'runtime-1',
                'threadId': 'thread-1',
                'origin': 'desktop_rollout',
                'turnId': 'turn-1',
                'timestamp': timestamp,
                'itemKey': 'item-$index',
                'message': payloads[index],
              })
              as CodexDesktopContinuityEventMessage;

      expect(
        serverMessageTimestamp(event.payload!),
        isA<ServerMessageTimestamp>()
            .having((value) => value.value, 'value', DateTime.parse(timestamp))
            .having(
              (value) => value.isAuthoritative,
              'isAuthoritative',
              isTrue,
            ),
      );
    }
  });

  test('old Bridge events default turn steerability to false', () {
    final decoded =
        ServerMessage.fromJson({
              'type': 'codex_desktop_continuity_event_v1',
              'event': 'state',
              'requestId': 'watch-1',
              'bridgeInstanceId': 'bridge-1',
              'sessionId': 'runtime-1',
              'threadId': 'thread-1',
              'origin': 'desktop_rollout',
              'state': 'running',
              'turnId': 'turn-1',
            })
            as CodexDesktopContinuityEventMessage;

    expect(decoded.turnSteerable, isFalse);
  });

  test('decodes the additive canonical-history readiness marker', () {
    final decoded =
        ServerMessage.fromJson({
              'type': 'codex_desktop_continuity_event_v1',
              'event': 'state',
              'requestId': 'watch-1',
              'bridgeInstanceId': 'bridge-1',
              'sessionId': 'runtime-1',
              'threadId': 'thread-1',
              'origin': 'desktop_rollout',
              'state': 'idle',
              'turnId': 'turn-1',
              'historyReady': true,
            })
            as CodexDesktopContinuityEventMessage;

    expect(decoded.historyReady, isTrue);
    expect(
      () => ServerMessage.fromJson({
        'type': 'codex_desktop_continuity_event_v1',
        'event': 'state',
        'requestId': 'watch-1',
        'bridgeInstanceId': 'bridge-1',
        'sessionId': 'runtime-1',
        'threadId': 'thread-1',
        'origin': 'desktop_rollout',
        'state': 'running',
        'historyReady': true,
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        'type': 'codex_desktop_continuity_event_v1',
        'event': 'message',
        'requestId': 'watch-1',
        'bridgeInstanceId': 'bridge-1',
        'sessionId': 'runtime-1',
        'threadId': 'thread-1',
        'origin': 'desktop_rollout',
        'turnId': 'turn-1',
        'historyReady': true,
        'itemKey': 'assistant-1',
        'payload': {
          'type': 'assistant',
          'message': {
            'id': 'assistant-1',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'hello'},
            ],
            'model': 'codex',
          },
        },
      }),
      throwsFormatException,
    );
  });

  test('keeps future continuity semantics opaque for compatible clients', () {
    final futureOrigin =
        ServerMessage.fromJson({
              'type': 'codex_desktop_continuity_event_v1',
              'event': 'state',
              'requestId': 'watch-1',
              'bridgeInstanceId': 'bridge-1',
              'sessionId': 'runtime-1',
              'threadId': 'thread-1',
              'origin': 'desktop_live_v2',
              // A future origin may assign different meanings and shapes to
              // fields that happen to share today's names.
              'state': {'phase': 'running'},
              'historyReady': 'eventually',
              'message': 'not-a-v1-message',
            })
            as CodexDesktopContinuityEventMessage;
    expect(futureOrigin.origin, 'desktop_live_v2');
    expect(futureOrigin.usesSupportedSemantics, isFalse);
    expect(futureOrigin.state, isNull);
    expect(futureOrigin.payload, isNull);

    final futureEvent =
        ServerMessage.fromJson({
              'type': 'codex_desktop_continuity_event_v1',
              'event': 'checkpoint',
              'requestId': 'watch-2',
              'bridgeInstanceId': 'bridge-1',
              'sessionId': 'runtime-1',
              'threadId': 'thread-1',
              'origin': 'desktop_rollout',
              'message': 'future-event-shape',
            })
            as CodexDesktopContinuityEventMessage;
    expect(futureEvent.event, CodexDesktopContinuityEventKind.unknown);
    expect(futureEvent.usesSupportedSemantics, isFalse);
    expect(futureEvent.payload, isNull);
  });

  test('old-Bridge unsupported errors are isolated to the feature request', () {
    final request = LocalFeatureProtocolHost.describeRequest(
      requestCodexDesktopContinuityWatch(
        requestId: 'watch-1',
        sessionId: 'runtime-1',
        threadId: 'thread-1',
        projectPath: '/project',
      ),
    )!;
    expect(
      LocalFeatureProtocolHost.matchesRequestError(
        request,
        const ErrorMessage(
          errorCode: 'unsupported_capability',
          message: 'Codex Desktop continuity capability was not negotiated',
        ),
      ),
      isTrue,
    );
    expect(
      LocalFeatureProtocolHost.matchesRequestError(
        request,
        const ErrorMessage(
          errorCode: 'unsupported_capability',
          message: 'conversation_mirror_watch',
        ),
      ),
      isFalse,
    );
  });
}
