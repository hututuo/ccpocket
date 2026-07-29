import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}

const _baseFrame = <String, dynamic>{
  'type': conversationSyncV2Capability,
  'subscriptionId': 'subscription-1',
  'bridgeInstanceId': 'bridge-1',
  'codexSourceId': 'source-1',
  'batchId': 'batch-1',
  'sequence': 1,
};
