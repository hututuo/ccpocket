import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

void main() {
  test('declares legacy and persisted side chat response capabilities', () {
    final capabilities = _json(ClientMessage.clientCapabilities());
    expect(
      capabilities['supportedServerMessages'],
      contains('side_chat_event'),
    );
    expect(
      capabilities['supportedServerMessages'],
      contains('persisted_side_chat_opened'),
    );
  });

  test('encodes and decodes the persisted side chat handshake', () {
    final request = requestOpenPersistedSideChat(
      parentSessionId: 'parent-1',
      requestId: 'persisted-1',
    );
    expect(_json(request), {
      'type': 'open_persisted_side_chat',
      'parentSessionId': 'parent-1',
      'requestId': 'persisted-1',
    });
    expect(LocalFeatureProtocolHost.describeRequest(request)?.metadata, {
      'featureId': 'persisted_side_chat',
      'requestType': 'open_persisted_side_chat',
      'ownerSessionId': 'parent-1',
      'requestId': 'persisted-1',
    });

    final response =
        ServerMessage.fromJson({
              'type': 'persisted_side_chat_opened',
              'parentSessionId': 'parent-1',
              'requestId': 'persisted-1',
              'childSessionId': 'child-1',
              'projectPath': '/tmp/project',
            })
            as PersistedSideChatOpenedMessage;
    expect(response.isSuccess, isTrue);
    expect(response.childSessionId, 'child-1');
  });

  test('describes requests without retaining side chat text', () {
    final request = requestSideChatInput(
      parentSessionId: 'parent-1',
      sideChatId: 'side-1',
      requestId: 'request-1',
      clientMessageId: 'client-1',
      text: 'private prompt',
    );
    final descriptor = LocalFeatureProtocolHost.describeRequest(request);

    expect(descriptor?.metadata, {
      'featureId': 'side_chat',
      'requestType': 'side_chat_input',
      'ownerSessionId': 'parent-1',
      'requestId': 'request-1',
    });
    expect(descriptor?.metadata, isNot(contains('text')));
  });

  test('encodes canonical client request names and correlation fields', () {
    expect(
      _json(
        requestOpenSideChat(parentSessionId: 'parent-1', requestId: 'open-1'),
      ),
      {
        'type': 'open_side_chat',
        'parentSessionId': 'parent-1',
        'requestId': 'open-1',
      },
    );
    expect(
      _json(
        requestSideChatInput(
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          requestId: 'input-1',
          clientMessageId: 'client-1',
          text: 'hello',
        ),
      ),
      {
        'type': 'side_chat_input',
        'parentSessionId': 'parent-1',
        'sideChatId': 'side-1',
        'requestId': 'input-1',
        'clientMessageId': 'client-1',
        'text': 'hello',
      },
    );
    expect(
      _json(
        requestSideChatPermissionResponse(
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          requestId: 'response-1',
          permissionRequestId: 'permission-1',
          decision: SideChatPermissionDecision.allowAlways,
        ),
      ),
      {
        'type': 'side_chat_permission_response',
        'parentSessionId': 'parent-1',
        'sideChatId': 'side-1',
        'requestId': 'response-1',
        'permissionRequestId': 'permission-1',
        'decision': 'allow_always',
      },
    );
    expect(
      _json(
        requestSideChatAnswer(
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          requestId: 'answer-1',
          questionRequestId: 'question-1',
          answer: '{"answers":{"q1":"A"}}',
        ),
      ),
      {
        'type': 'side_chat_answer',
        'parentSessionId': 'parent-1',
        'sideChatId': 'side-1',
        'requestId': 'answer-1',
        'questionRequestId': 'question-1',
        'answer': '{"answers":{"q1":"A"}}',
      },
    );
    expect(
      _json(
        requestSideChatInterrupt(
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          requestId: 'interrupt-1',
        ),
      )['type'],
      'side_chat_interrupt',
    );
    expect(
      _json(
        requestCloseSideChat(
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          requestId: 'close-1',
        ),
      )['type'],
      'close_side_chat',
    );
  });

  test('parses every canonical server event payload', () {
    final opened =
        ServerMessage.fromJson({
              'type': 'side_chat_event',
              'event': 'opened',
              'parentSessionId': 'parent-1',
              'sideChatId': 'side-1',
              'requestId': 'open-1',
            })
            as SideChatEventMessage;
    expect(opened.event, SideChatEventKind.opened);

    final accepted =
        ServerMessage.fromJson({
              'type': 'side_chat_event',
              'event': 'input_accepted',
              'parentSessionId': 'parent-1',
              'sideChatId': 'side-1',
              'requestId': 'input-1',
              'clientMessageId': 'client-1',
              'queued': true,
            })
            as SideChatEventMessage;
    expect(accepted.clientMessageId, 'client-1');
    expect(accepted.queued, isTrue);

    final message =
        ServerMessage.fromJson({
              'type': 'side_chat_event',
              'event': 'message',
              'parentSessionId': 'parent-1',
              'sideChatId': 'side-1',
              'message': {'id': 'm1', 'role': 'assistant', 'text': 'answer'},
            })
            as SideChatEventMessage;
    expect(message.message?.text, 'answer');

    final status =
        ServerMessage.fromJson({
              'type': 'side_chat_event',
              'event': 'status',
              'parentSessionId': 'parent-1',
              'sideChatId': 'side-1',
              'status': 'running',
            })
            as SideChatEventMessage;
    expect(status.status, 'running');

    final permission =
        ServerMessage.fromJson({
              'type': 'side_chat_event',
              'event': 'permission_request',
              'parentSessionId': 'parent-1',
              'sideChatId': 'side-1',
              'permission': {
                'requestId': 'permission-1',
                'toolName': 'Bash',
                'input': {'command': 'pwd'},
              },
            })
            as SideChatEventMessage;
    expect(permission.permission?.toolName, 'Bash');

    final question =
        ServerMessage.fromJson({
              'type': 'side_chat_event',
              'event': 'question',
              'parentSessionId': 'parent-1',
              'sideChatId': 'side-1',
              'question': {
                'requestId': 'question-1',
                'questions': [
                  {
                    'id': 'q1',
                    'question': 'Choose?',
                    'options': [
                      {'label': 'A'},
                      {'label': 'B'},
                    ],
                  },
                ],
              },
            })
            as SideChatEventMessage;
    expect(question.question?.questions.single['id'], 'q1');

    final closed =
        ServerMessage.fromJson({
              'type': 'side_chat_event',
              'event': 'closed',
              'parentSessionId': 'parent-1',
              'sideChatId': 'side-1',
              'requestId': 'close-1',
            })
            as SideChatEventMessage;
    expect(closed.event, SideChatEventKind.closed);

    final error =
        ServerMessage.fromJson({
              'type': 'side_chat_event',
              'event': 'error',
              'parentSessionId': 'parent-1',
              'requestId': 'open-1',
              'error': {'code': 'fork_failed', 'message': 'Could not fork'},
            })
            as SideChatEventMessage;
    expect(error.error?.code, 'fork_failed');
  });

  test('rejects missing correlation and malformed event payloads', () {
    expect(
      () => ServerMessage.fromJson({
        'type': 'side_chat_event',
        'event': 'opened',
        'parentSessionId': 'parent-1',
        'sideChatId': 'side-1',
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        'type': 'side_chat_event',
        'event': 'input_accepted',
        'parentSessionId': 'parent-1',
        'sideChatId': 'side-1',
        'requestId': 'input-1',
        'clientMessageId': 'client-1',
        'queued': 'yes',
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        'type': 'side_chat_event',
        'event': 'input_accepted',
        'parentSessionId': 'parent-1',
        'sideChatId': 'side-1',
        'requestId': 'input-1',
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        'type': 'side_chat_event',
        'event': 'message',
        'parentSessionId': 'parent-1',
        'sideChatId': 'side-1',
        'message': {'id': 'm1', 'role': 'invalid', 'text': 'bad'},
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        'type': 'side_chat_event',
        'event': 'unknown',
        'parentSessionId': 'parent-1',
      }),
      throwsFormatException,
    );
  });
}
