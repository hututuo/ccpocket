import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/session_runtime_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session-insights responses stay out of the chat timeline cache', () {
    final store = SessionRuntimeStore();

    store.applyServerMessage(
      's1',
      const ContextUsageMessage(
        usage: ContextUsage(
          sessionId: 's1',
          last: ContextTokenUsage(totalTokens: 10),
          total: ContextTokenUsage(totalTokens: 20),
          modelContextWindow: 100,
        ),
      ),
    );
    store.applyServerMessage(
      's1',
      const ContextUsageResultMessage(
        sessionId: 's1',
        usage: ContextUsage(
          sessionId: 's1',
          last: ContextTokenUsage(totalTokens: 10),
          total: ContextTokenUsage(totalTokens: 20),
          modelContextWindow: 100,
        ),
      ),
    );
    store.applyServerMessage(
      's1',
      const ContextUsageErrorMessage(
        sessionId: 's1',
        errorCode: 'context_usage_failed',
        message: 'scan failed',
      ),
    );
    store.applyServerMessage(
      's1',
      const SessionUsageResultMessage(
        sessionId: 's1',
        requestId: 'usage-1',
        providers: [SessionUsageInfo(provider: 'codex')],
      ),
    );

    expect(store.messages('s1'), isEmpty);
  });
}
