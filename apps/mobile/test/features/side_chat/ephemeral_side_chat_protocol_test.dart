import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

Map<String, dynamic> _entryJson({
  String childSessionId = 'child-1',
  String parentSessionId = 'parent-1',
}) => {
  'childSessionId': childSessionId,
  'parentSessionId': parentSessionId,
  'projectPath': '/tmp/project',
  'permissionMode': 'acceptEdits',
  'status': 'idle',
  'createdAt': '2026-07-25T00:00:00.000Z',
  'lastActivityAt': '2026-07-25T00:00:01.000Z',
};

void main() {
  test('advertises and encodes the official ephemeral side chat protocol', () {
    final capabilities = _json(ClientMessage.clientCapabilities());
    expect(
      capabilities['supportedServerMessages'],
      containsAll([
        'ephemeral_side_chat_opened',
        'ephemeral_side_chat_registry',
      ]),
    );
    expect(
      _json(
        requestOpenEphemeralSideChat(
          parentSessionId: 'parent-1',
          requestId: 'open-1',
        ),
      ),
      {
        'type': 'open_ephemeral_side_chat',
        'parentSessionId': 'parent-1',
        'requestId': 'open-1',
      },
    );
    expect(_json(requestListEphemeralSideChats(requestId: 'list-1')), {
      'type': 'list_ephemeral_side_chats',
      'requestId': 'list-1',
    });
    expect(
      _json(
        requestCloseEphemeralSideChat(
          childSessionId: 'child-1',
          requestId: 'close-1',
        ),
      ),
      {
        'type': 'close_ephemeral_side_chat',
        'childSessionId': 'child-1',
        'requestId': 'close-1',
      },
    );
  });

  test('decodes open and authoritative registry snapshots', () {
    final opened =
        ServerMessage.fromJson({
              'type': 'ephemeral_side_chat_opened',
              'parentSessionId': 'parent-1',
              'requestId': 'open-1',
              'entry': _entryJson(),
            })
            as EphemeralSideChatOpenedMessage;
    expect(opened.isSuccess, isTrue);
    expect(opened.entry?.childSessionId, 'child-1');

    final registry =
        ServerMessage.fromJson({
              'type': 'ephemeral_side_chat_registry',
              'requestId': 'list-1',
              'entries': [_entryJson()],
            })
            as EphemeralSideChatRegistryMessage;
    expect(registry.isSuccess, isTrue);
    expect(registry.entries?.single.parentSessionId, 'parent-1');
  });

  test('correlates every request without retaining transcript data', () {
    expect(
      LocalFeatureProtocolHost.describeRequest(
        requestOpenEphemeralSideChat(
          parentSessionId: 'parent-1',
          requestId: 'open-1',
        ),
      )?.metadata,
      {
        'featureId': 'ephemeral_side_chat',
        'requestType': 'open_ephemeral_side_chat',
        'ownerSessionId': 'parent-1',
        'requestId': 'open-1',
      },
    );
    expect(
      LocalFeatureProtocolHost.describeRequest(
        requestListEphemeralSideChats(requestId: 'list-1'),
      )?.metadata,
      {
        'featureId': 'ephemeral_side_chat',
        'requestType': 'list_ephemeral_side_chats',
        'ownerSessionId': 'ephemeral-side-chat-registry',
        'requestId': 'list-1',
      },
    );
  });

  test('tolerates additive fields and prefers a valid result over warnings', () {
    final openedWithWarning =
        ServerMessage.fromJson({
              'type': 'ephemeral_side_chat_opened',
              'parentSessionId': 'parent-1',
              'requestId': 'open-1',
              'entry': {..._entryJson(), 'futureField': 1},
              'error': 'non-fatal warning from a newer Bridge',
              'errorCode': 'future_warning',
            })
            as EphemeralSideChatOpenedMessage;
    expect(openedWithWarning.isSuccess, isTrue);
    expect(openedWithWarning.error, isNull);
    final extended =
        ServerMessage.fromJson({
              'type': 'ephemeral_side_chat_registry',
              'requestId': 'list-2',
              'entries': [
                {..._entryJson(), 'unexpected': true},
              ],
            })
            as EphemeralSideChatRegistryMessage;
    expect(extended.entries?.single.childSessionId, 'child-1');
    final malformedFailure =
        ServerMessage.fromJson({
              'type': 'ephemeral_side_chat_registry',
              'requestId': 'list-3',
            })
            as EphemeralSideChatRegistryMessage;
    expect(malformedFailure.isSuccess, isFalse);
    expect(malformedFailure.errorCode, 'unknown');
    expect(
      () => ServerMessage.fromJson({
        'type': 'ephemeral_side_chat_registry',
        'entries': [
          {..._entryJson(), 'createdAt': 'not-a-time'},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        'type': 'ephemeral_side_chat_opened',
        'parentSessionId': 'parent-1',
        'requestId': 'open-1',
        'entry': _entryJson(parentSessionId: 'different-parent'),
      }),
      throwsFormatException,
    );
  });
}
