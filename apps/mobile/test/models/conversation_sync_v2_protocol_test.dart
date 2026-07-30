import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'advertises app-server status semantics to compatible Bridge versions',
    () {
      expect(
        LocalFeatureProtocolHost.supportedServerMessageTypes,
        contains(appServerStatusV1Capability),
      );
    },
  );

  test('decodes an authoritative unknown status without inventing idle', () {
    final decoded =
        ServerMessage.fromJson(<String, dynamic>{
              ..._baseFrame,
              'event': 'status_changes',
              'statusState': 'status-1',
              'pageIndex': 0,
              'pageCount': 1,
              'changes': [
                {
                  'provider': 'codex',
                  'providerSessionId': 'thread-1',
                  'activity': 'unknown',
                  'attention': 'none',
                  'result': 'none',
                  'runtimeAttachment': 'notLoaded',
                  'source': 'appServer',
                  'confidence': 'authoritative',
                  'observedAt': '2026-07-30T00:00:00.000Z',
                },
              ],
            })
            as ConversationSyncV2EventMessage;

    expect(decoded.event, ConversationSyncV2EventKind.statusChanges);
    expect(decoded.statusChanges.single.activity, 'unknown');
    expect(decoded.statusChanges.single.runtimeAttachment, 'notLoaded');
  });

  test(
    'bounds legacy Bridge catalog display text instead of dropping sync',
    () {
      final decoded =
          ServerMessage.fromJson(<String, dynamic>{
                ..._baseFrame,
                'event': 'catalog_changes',
                'catalogState': 'catalog-1',
                'pageIndex': 0,
                'pageCount': 1,
                'created': [
                  {
                    'provider': 'codex',
                    'providerSessionId': 'thread-1',
                    'revision': 'revision-1',
                    'projectPath': '/workspace',
                    'name': 'n' * 800,
                    'summary': 's' * 8000,
                    'firstPrompt': '${'p' * 4094}😀${'x' * 24000}',
                    'createdAt': '2026-07-30T00:00:00.000Z',
                    'modifiedAt': '2026-07-30T00:01:00.000Z',
                    'recencyAt': '2026-07-30T00:02:00.000Z',
                    'availability': 'durable',
                  },
                ],
                'updated': const [],
                'destroyed': const [],
              })
              as ConversationSyncV2EventMessage;

      final entry = decoded.created.single;
      expect(entry.name, hasLength(512));
      expect(entry.summary, hasLength(4096));
      expect(entry.firstPrompt, hasLength(4095));
      expect(entry.firstPrompt, endsWith('…'));
      expect(entry.firstPrompt, isNot(contains('\ud83d')));
    },
  );

  test('builds a bounded subscription without endpoint identity', () {
    final message = conversationSyncV2Subscribe(
      requestId: 'request-1',
      catalogState: 'catalog-1',
      statusState: 'status-1',
      threadContentStates: [
        const ConversationSyncV2ThreadState(
          provider: 'codex',
          providerSessionId: 'thread-1',
          revision: 'revision-1',
        ),
      ],
      readWatermarks: [
        const ConversationSyncV2ReadWatermark(
          provider: 'codex',
          providerSessionId: 'thread-1',
          readAt: '2026-07-30T00:00:00.000Z',
        ),
      ],
    );

    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    expect(json['type'], 'conversation_sync_subscribe');
    expect(json['protocolVersion'], 2);
    expect(json['threadContentStates'], hasLength(1));
    expect(json, isNot(contains('host')));
    expect(json, isNot(contains('ip')));
  });

  test('builds an ephemeral per-subscription read watermark', () {
    final message = conversationSyncV2Read(
      subscriptionId: 'subscription-1',
      watermark: const ConversationSyncV2ReadWatermark(
        provider: 'codex',
        providerSessionId: 'thread-1',
        readAt: '2026-07-30T00:00:00.000Z',
      ),
    );

    expect(
      jsonDecode(message.toJson()),
      containsPair('type', 'conversation_sync_read'),
    );
    expect(message.delivery, ClientMessageDelivery.ephemeral);
  });

  test('rejects malformed timeline pagination and oversized data', () {
    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'timeline_page',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'revision': 'revision-1',
        'mode': 'snapshot',
        'pageIndex': 1,
        'pageCount': 1,
        'entries': const [],
        'deletes': const [],
        'hasEarlier': false,
        'sourceEntryCount': 0,
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'timeline_page',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'revision': 'revision-1',
        'mode': 'snapshot',
        'phase': 'priority',
        'timelineIndex': 1,
        'pageIndex': 0,
        'pageCount': 1,
        'entries': const [],
        'deletes': const [],
        'hasEarlier': false,
        'sourceEntryCount': 0,
      }),
      throwsFormatException,
    );
    final positioned =
        ServerMessage.fromJson({
              ..._baseFrame,
              'event': 'timeline_page',
              'provider': 'codex',
              'providerSessionId': 'thread-1',
              'revision': 'revision-1',
              'mode': 'snapshot',
              'phase': 'priority',
              'timelineIndex': 1,
              'timelineCount': 3,
              'pageIndex': 0,
              'pageCount': 1,
              'entries': const [],
              'deletes': const [],
              'hasEarlier': false,
              'sourceEntryCount': 0,
            })
            as ConversationSyncV2EventMessage;
    expect(positioned.timelineIndex, 1);
    expect(positioned.timelineCount, 3);
    for (final timelineCount in const [4096, 4097, 10000]) {
      final boundary =
          ServerMessage.fromJson({
                ..._baseFrame,
                'event': 'timeline_page',
                'provider': 'codex',
                'providerSessionId': 'thread-1',
                'revision': 'revision-1',
                'mode': 'snapshot',
                'phase': 'priority',
                'timelineIndex': timelineCount - 1,
                'timelineCount': timelineCount,
                'pageIndex': 0,
                'pageCount': 1,
                'entries': const [],
                'deletes': const [],
                'hasEarlier': false,
                'sourceEntryCount': 0,
              })
              as ConversationSyncV2EventMessage;
      expect(boundary.timelineCount, timelineCount);
    }
    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'timeline_page',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'revision': 'revision-1',
        'mode': 'snapshot',
        'phase': 'priority',
        'timelineIndex': 10000,
        'timelineCount': 10001,
        'pageIndex': 0,
        'pageCount': 1,
        'entries': const [],
        'deletes': const [],
        'hasEarlier': false,
        'sourceEntryCount': 0,
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'turns_page_response',
        'requestId': 'request-1',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'data': List<Object?>.filled(201, const {}),
        'nextCursor': null,
      }),
      throwsFormatException,
    );
  });

  test('validates normalized messages inside turn page responses', () {
    final message =
        ServerMessage.fromJson({
              ..._baseFrame,
              'event': 'turns_page_response',
              'requestId': 'request-1',
              'provider': 'codex',
              'providerSessionId': 'thread-1',
              'data': [
                {
                  'turnId': 'turn-1',
                  'messages': [
                    {
                      'type': 'user_input',
                      'text': 'Earlier prompt',
                      'userMessageUuid': 'user-earlier',
                    },
                  ],
                  'itemCount': 1,
                  'itemsView': 'summary',
                },
              ],
              'nextCursor': 'cursor-2',
            })
            as ConversationSyncV2EventMessage;

    expect(message.pageRawMessages().single['text'], 'Earlier prompt');
    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'turns_page_response',
        'requestId': 'request-2',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'data': [
          {
            'turnId': 'turn-bad',
            'messages': ['not-a-message-map'],
          },
        ],
        'nextCursor': null,
      }),
      throwsFormatException,
    );
  });
}

const _baseFrame = <String, dynamic>{
  'type': conversationSyncV2Capability,
  'subscriptionId': 'subscription-1',
  'bridgeInstanceId': 'bridge-1',
  'codexSourceId': 'source-1',
  'batchId': 'batch-1',
  'sequence': 1,
};
