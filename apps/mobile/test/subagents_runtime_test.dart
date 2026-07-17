import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/session_runtime_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('subagent responses stay out of the chat timeline cache', () {
    final store = SessionRuntimeStore();

    store.applyServerMessage(
      's1',
      const SubagentListMessage(
        sessionId: 's1',
        requestId: 'list-1',
        subagents: [],
      ),
    );
    store.applyServerMessage(
      's1',
      const SubagentHistoryMessage(
        sessionId: 's1',
        requestId: 'history-1',
        threadId: 'child-1',
        messages: [],
      ),
    );

    expect(store.messages('s1'), isEmpty);
  });
}
