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
    },
  );

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
