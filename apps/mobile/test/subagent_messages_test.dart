import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('subagent responses and requests use correlated canonical fields', () {
    final list =
        ServerMessage.fromJson({
              'type': 'subagent_list',
              'sessionId': 's1',
              'requestId': 'r1',
              'truncated': true,
              'subagents': [
                {
                  'threadId': 'child-1',
                  'nickname': 'Aristotle',
                  'status': 'running',
                },
              ],
            })
            as SubagentListMessage;
    expect(list.subagents.single.threadId, 'child-1');
    expect(list.subagents.single.isActive, isTrue);
    expect(list.truncated, isTrue);

    final history =
        ServerMessage.fromJson({
              'type': 'subagent_history',
              'sessionId': 's1',
              'requestId': 'r2',
              'threadId': 'child-1',
              'truncated': true,
              'subagent': {'threadId': 'child-1', 'status': 'done'},
              'messages': [
                {'type': 'user_input', 'text': 'Inspect this'},
              ],
            })
            as SubagentHistoryMessage;
    expect(history.messages.single, isA<UserInputMessage>());
    expect(history.truncated, isTrue);

    expect(
      jsonDecode(
        requestSubagentHistory(
          sessionId: 's1',
          threadId: 'child-1',
          requestId: 'r2',
        ).toJson(),
      ),
      {
        'type': 'get_subagent_history',
        'sessionId': 's1',
        'threadId': 'child-1',
        'requestId': 'r2',
      },
    );
    final capabilities =
        jsonDecode(ClientMessage.clientCapabilities().toJson())
            as Map<String, dynamic>;
    expect(capabilities['supportedServerMessages'], contains('subagent_list'));
    expect(
      capabilities['supportedServerMessages'],
      contains('subagent_history'),
    );
  });
}
