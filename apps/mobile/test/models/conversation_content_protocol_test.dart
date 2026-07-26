import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes a bounded conversation content snapshot page', () {
    final message = ServerMessage.fromJson(<String, dynamic>{
      'type': conversationContentEventCapability,
      'event': 'snapshot_page',
      'subscriptionId': 'subscription-1',
      'bridgeInstanceId': 'bridge-1',
      'provider': 'codex',
      'providerSessionId': 'thread-1',
      'revision': 'revision-1',
      'pageIndex': 0,
      'pageCount': 1,
      'entries': [
        {
          'entryId': 'entry-1',
          'index': 3,
          'contentHash': 'hash-1',
          'message': {'type': 'status', 'status': 'idle'},
        },
      ],
    });

    expect(message, isA<ConversationContentEventMessage>());
    final event = message as ConversationContentEventMessage;
    expect(event.event, ConversationContentEventKind.snapshotPage);
    expect(event.sessionId, 'thread-1');
    expect(event.entries.single.decodeMessage(), isA<StatusMessage>());
  });

  test('rejects malformed or incomplete snapshot events', () {
    expect(
      () => ServerMessage.fromJson(<String, dynamic>{
        'type': conversationContentEventCapability,
        'event': 'snapshot_page',
        'subscriptionId': 'subscription-1',
        'bridgeInstanceId': 'bridge-1',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'revision': 'revision-1',
        'pageIndex': 1,
        'pageCount': 1,
        'entries': const [],
      }),
      throwsFormatException,
    );
  });

  test('builds one ephemeral subscription with bounded cursors', () {
    final message = conversationContentSubscribe(
      requestId: 'subscription-1',
      knownRevisions: List.generate(
        300,
        (index) => ConversationContentCursor(
          provider: 'codex',
          providerSessionId: 'thread-$index',
          revision: 'revision-$index',
        ),
      ),
      focused: const ConversationContentTarget(
        provider: 'codex',
        providerSessionId: 'thread-1',
      ),
    );
    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;

    expect(message.delivery, ClientMessageDelivery.ephemeral);
    expect(json['type'], 'conversation_content_subscribe');
    expect(json['knownRevisions'], hasLength(256));
    expect(
      (json['focused'] as Map<String, dynamic>)['providerSessionId'],
      'thread-1',
    );
  });
}
