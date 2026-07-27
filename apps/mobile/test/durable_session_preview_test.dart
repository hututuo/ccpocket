import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/durable_session_preview.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_screen/helpers/chat_test_helpers.dart';

void main() {
  testWidgets(
    'cache revisions update the detached cubit without rebuilding child state',
    (tester) async {
      final bridge = MockBridgeService();
      final streaming = StreamingStateCubit();
      final cubit = ChatSessionCubit(
        sessionId: 'durable-thread',
        provider: Provider.codex,
        bridge: bridge,
        streamingCubit: streaming,
        detachedPreview: true,
      );
      final revision = ValueNotifier('revision-1');
      addTearDown(revision.dispose);
      addTearDown(cubit.close);
      addTearDown(streaming.close);
      addTearDown(bridge.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider<ChatSessionCubit>.value(
            value: cubit,
            child: Scaffold(
              body: ValueListenableBuilder<String>(
                valueListenable: revision,
                builder: (context, value, _) {
                  final messages = value == 'revision-1'
                      ? const <ServerMessage>[
                          UserInputMessage(text: 'First cached turn'),
                        ]
                      : const <ServerMessage>[
                          UserInputMessage(text: 'First cached turn'),
                          AssistantServerMessage(
                            message: AssistantMessage(
                              id: 'assistant-2',
                              role: 'assistant',
                              content: [
                                TextContent(text: 'Incremental answer'),
                              ],
                              model: 'gpt-test',
                            ),
                          ),
                        ];
                  return DurableSessionPreviewUpdater(
                    revision: value,
                    messages: messages,
                    child: const TextField(key: ValueKey('durable-composer')),
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('durable-composer')),
        'unsent draft',
      );
      revision.value = 'revision-2';
      await tester.pump();
      await tester.pump();

      expect(find.text('unsent draft'), findsOneWidget);
      expect(
        cubit.state.entries.whereType<ServerChatEntry>().where(
          (entry) =>
              entry.message is AssistantServerMessage &&
              (entry.message as AssistantServerMessage).message.id ==
                  'assistant-2',
        ),
        hasLength(1),
      );
    },
  );
}
