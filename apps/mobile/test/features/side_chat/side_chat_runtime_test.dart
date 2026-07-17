import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/session_runtime_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('routes side chat only to dedicated and global streams', () async {
    SharedPreferences.setMockInitialValues({});
    final bridge = BridgeService();
    addTearDown(bridge.dispose);
    final dedicated = <SideChatEventMessage>[];
    final global = <ServerMessage>[];
    final parent = <ServerMessage>[];
    final dedicatedSub = bridge
        .localFeatureMessagesForSession('parent-1')
        .where((message) => message is SideChatEventMessage)
        .cast<SideChatEventMessage>()
        .listen(dedicated.add);
    final globalSub = bridge.messages.listen(global.add);
    final parentSub = bridge.messagesForSession('parent-1').listen(parent.add);
    addTearDown(dedicatedSub.cancel);
    addTearDown(globalSub.cancel);
    addTearDown(parentSub.cancel);

    const event = SideChatEventMessage(
      event: SideChatEventKind.status,
      parentSessionId: 'parent-1',
      sideChatId: 'side-1',
      status: 'running',
    );
    expect(
      bridge.consumeLocalFeatureInfrastructureMessageForTest(event),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);

    expect(dedicated, [same(event)]);
    expect(global, [same(event)]);
    expect(parent, isEmpty);
  });

  test('does not consume ordinary parent session messages', () {
    SharedPreferences.setMockInitialValues({});
    final bridge = BridgeService();
    addTearDown(bridge.dispose);
    expect(
      bridge.consumeLocalFeatureInfrastructureMessageForTest(
        const StatusMessage(status: ProcessStatus.running),
      ),
      isFalse,
    );
  });

  test('defensively ignores side chat events in the parent runtime store', () {
    final store = SessionRuntimeStore();
    store.applyServerMessage(
      'parent-1',
      const SideChatEventMessage(
        event: SideChatEventKind.message,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        message: SideChatTranscriptMessage(
          id: 'm1',
          role: 'assistant',
          text: 'isolated',
        ),
      ),
    );
    expect(store.messages('parent-1'), isEmpty);
  });
}
