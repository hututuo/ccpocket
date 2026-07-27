import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

Map<String, dynamic> _base(String event) => {
  'type': 'conversation_mirror_event_v1',
  'event': event,
  'requestId': 'request-1',
  'bridgeInstanceId': 'bridge-1',
  'provider': 'codex',
  'providerSessionId': 'thread-1',
};

Map<String, dynamic> _entry({
  String id = 'item-1',
  int index = 0,
  String text = 'hello',
}) => {
  'entryId': id,
  'index': index,
  'contentHash': 'hash-$id-$text',
  'message': {'type': 'user_input', 'text': text, 'userMessageUuid': id},
};

void main() {
  test('advertises mirror events and additive large-entry chunks', () {
    final capabilities = _json(ClientMessage.clientCapabilities());
    expect(
      capabilities['supportedServerMessages'],
      contains('conversation_mirror_event_v1'),
    );
    expect(
      capabilities['supportedServerMessages'],
      contains('conversation_mirror_entry_chunk_v1'),
    );
  });

  test('encodes bounded ephemeral mirror requests', () {
    expect(
      _json(
        requestConversationMirrorSync(
          requestId: 'sync-1',
          provider: 'codex',
          providerSessionId: 'thread-1',
          projectPath: '/tmp/project',
          knownRevision: 'rev-1',
        ),
      ),
      {
        'type': 'conversation_mirror_sync',
        'protocolVersion': 1,
        'requestId': 'sync-1',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'projectPath': '/tmp/project',
        'knownRevision': 'rev-1',
      },
    );
    expect(
      _json(
        requestConversationMirrorUnwatch(
          requestId: 'unwatch-1',
          provider: 'codex',
          providerSessionId: 'thread-1',
        ),
      ),
      {
        'type': 'conversation_mirror_unwatch',
        'protocolVersion': 1,
        'requestId': 'unwatch-1',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
      },
    );
    expect(
      LocalFeatureProtocolHost.describeRequest(
        requestConversationMirrorWatch(
          requestId: 'watch-1',
          provider: 'codex',
          providerSessionId: 'thread-1',
          projectPath: '/tmp/project',
        ),
      )?.metadata,
      {
        'featureId': 'conversation_mirror',
        'requestType': 'conversation_mirror_watch',
        'ownerSessionId': 'thread-1',
        'requestId': 'watch-1',
      },
    );
  });

  test('encodes source identity additively and rejects forged providers', () {
    expect(
      _json(
        requestConversationMirrorSync(
          requestId: 'source-aware',
          provider: 'codex',
          providerSessionId: 'thread-1',
          projectPath: '/tmp/project',
          codexSourceId: 'codex-home-source-a',
        ),
      ),
      {
        'type': 'conversation_mirror_sync',
        'protocolVersion': 1,
        'requestId': 'source-aware',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'codexSourceId': 'codex-home-source-a',
        'projectPath': '/tmp/project',
      },
    );
    expect(
      _json(
        requestConversationMirrorUnwatch(
          requestId: 'legacy-unwatch',
          provider: 'codex',
          providerSessionId: 'thread-1',
        ),
      ),
      isNot(contains('codexSourceId')),
    );
    expect(
      () => requestConversationMirrorWatch(
        requestId: 'forged-source',
        provider: 'claude',
        providerSessionId: 'session-1',
        projectPath: '/tmp/project',
        codexSourceId: 'codex-home-source-a',
      ),
      throwsArgumentError,
    );
  });

  test('parses snapshot framing and standard message envelopes', () {
    final accepted =
        ServerMessage.fromJson(_base('accepted'))
            as ConversationMirrorEventMessage;
    expect(accepted.event, ConversationMirrorEventKind.accepted);

    final begin =
        ServerMessage.fromJson({
              ..._base('snapshot_begin'),
              'revision': 'rev-2',
              'entryCount': 1,
              'totalBytes': 100,
              'pageCount': 1,
              'threadStatus': 'idle',
            })
            as ConversationMirrorEventMessage;
    expect(begin.event, ConversationMirrorEventKind.snapshotBegin);
    expect(begin.pageCount, 1);

    final page =
        ServerMessage.fromJson({
              ..._base('snapshot_page'),
              'revision': 'rev-2',
              'pageIndex': 0,
              'pageCount': 1,
              'entries': [_entry()],
            })
            as ConversationMirrorEventMessage;
    expect(page.entries.single.entryId, 'item-1');
    expect(page.entries.single.decodeMessage(), isA<UserInputMessage>());

    final complete =
        ServerMessage.fromJson({
              ..._base('snapshot_complete'),
              'revision': 'rev-2',
              'entryCount': 1,
              'threadStatus': 'idle',
            })
            as ConversationMirrorEventMessage;
    expect(complete.event, ConversationMirrorEventKind.snapshotComplete);
  });

  test('parses a bounded fragmented mirror entry', () {
    final chunk =
        ServerMessage.fromJson({
              'type': 'conversation_mirror_entry_chunk_v1',
              'requestId': 'request-1',
              'bridgeInstanceId': 'bridge-1',
              'provider': 'codex',
              'providerSessionId': 'thread-1',
              'revision': 'rev-2',
              'pageIndex': 0,
              'pageCount': 1,
              'entryId': 'large-entry',
              'index': 0,
              'contentHash': 'a' * 64,
              'chunkIndex': 1,
              'chunkCount': 3,
              'totalBytes': 600000,
              'payloadBase64': base64Encode([1, 2, 3]),
            })
            as ConversationMirrorEntryChunkMessage;

    expect(chunk.entryId, 'large-entry');
    expect(chunk.chunkIndex, 1);
    expect(chunk.chunkCount, 3);
    expect(chunk.totalBytes, 600000);
    expect(
      () => ServerMessage.fromJson({
        'type': 'conversation_mirror_entry_chunk_v1',
        'requestId': 'request-1',
        'bridgeInstanceId': 'bridge-1',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'revision': 'rev-2',
        'pageIndex': 0,
        'pageCount': 1,
        'entryId': 'large-entry',
        'index': 0,
        'contentHash': 'a' * 64,
        'chunkIndex': 3,
        'chunkCount': 3,
        'totalBytes': 600000,
        'payloadBase64': base64Encode([1]),
      }),
      throwsFormatException,
    );
  });

  test('parses same-count mutation and rollback patch operations', () {
    final patch =
        ServerMessage.fromJson({
              ..._base('patch'),
              'baseRevision': 'rev-1',
              'revision': 'rev-2',
              'upserts': [_entry(text: 'updated')],
              'deletes': ['item-2'],
              'threadStatus': 'running',
            })
            as ConversationMirrorEventMessage;

    expect(patch.event, ConversationMirrorEventKind.patch);
    expect(patch.baseRevision, 'rev-1');
    expect(patch.entries.single.rawMessage['text'], 'updated');
    expect(patch.deletes, ['item-2']);
  });

  test('ignores additive fields and preserves future message envelopes', () {
    final forwardCompatible =
        ServerMessage.fromJson({
              ..._base('snapshot_page'),
              'revision': 'rev-1',
              'pageIndex': 0,
              'pageCount': 1,
              'futureFrameField': {'version': 2},
              'entries': [
                {..._entry(), 'futureEntryField': true},
              ],
            })
            as ConversationMirrorEventMessage;
    expect(forwardCompatible.entries.single.entryId, 'item-1');
    final unknownEvent =
        ServerMessage.fromJson({
              ..._base('future_progress_event'),
              'progress': 0.5,
            })
            as ConversationMirrorEventMessage;
    expect(unknownEvent.event, ConversationMirrorEventKind.unknown);
    final futureEnvelope =
        ServerMessage.fromJson({
              ..._base('snapshot_page'),
              'revision': 'rev-1',
              'pageIndex': 0,
              'pageCount': 1,
              'entries': [
                {
                  ..._entry(),
                  'message': {
                    'type': 'future_server_message_v2',
                    'futurePayload': true,
                  },
                },
              ],
            })
            as ConversationMirrorEventMessage;
    expect(futureEnvelope.entries.single.rawMessage['futurePayload'], isTrue);
    expect(futureEnvelope.entries.single.decodeMessage(), isA<ErrorMessage>());
    expect(
      () => ServerMessage.fromJson({..._base('patch'), 'revision': 'rev-2'}),
      throwsFormatException,
    );
  });

  test('correlates old-Bridge errors only to the matching mirror request', () {
    final request = LocalFeatureProtocolHost.describeRequest(
      requestConversationMirrorSync(
        requestId: 'sync-1',
        provider: 'codex',
        providerSessionId: 'thread-1',
        projectPath: '/tmp/project',
      ),
    )!;
    expect(
      LocalFeatureProtocolHost.matchesRequestError(
        request,
        const ErrorMessage(
          errorCode: 'unsupported_capability',
          message: 'Conversation mirror capability was not negotiated',
        ),
      ),
      isTrue,
    );
    expect(
      LocalFeatureProtocolHost.matchesRequestError(
        request,
        const ErrorMessage(
          errorCode: 'unknown_error',
          message: 'Unknown message type: conversation_mirror_sync',
        ),
      ),
      isTrue,
    );
    expect(
      LocalFeatureProtocolHost.matchesRequestError(
        request,
        const ErrorMessage(
          errorCode: 'unknown_error',
          message: 'Unknown message type: conversation_mirror_watch',
        ),
      ),
      isFalse,
    );
    expect(
      LocalFeatureProtocolHost.matchesRequestError(
        request,
        const ErrorMessage(
          errorCode: 'unknown_error',
          message: 'thread/read failed for an unrelated session',
        ),
      ),
      isFalse,
    );
    expect(
      LocalFeatureProtocolHost.matchesTerminalResponse(
        request,
        ConversationMirrorEventMessage(
          event: ConversationMirrorEventKind.snapshotComplete,
          requestId: 'other-request',
          bridgeInstanceId: 'bridge-1',
          provider: 'codex',
          providerSessionId: 'thread-1',
          revision: 'rev-1',
          entryCount: 1,
        ),
      ),
      isFalse,
    );
  });
}
