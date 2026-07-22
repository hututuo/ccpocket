import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_message_list.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_process_disclosure.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  final _messages = StreamController<(ServerMessage, String?)>.broadcast();

  @override
  bool get isConnected => true;

  @override
  Stream<ServerMessage> messagesForSession(String sessionId) => _messages.stream
      .where((event) => event.$2 == sessionId)
      .map((event) => event.$1);

  void emit(ServerMessage message, String sessionId) {
    _messages.add((message, sessionId));
  }

  @override
  void send(ClientMessage message) {}

  @override
  void requestSessionHistory(String sessionId) {}

  @override
  void dispose() {
    _messages.close();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'turn disclosure reveals intermediate outputs while process segments stay independent',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final bridge = _Bridge();
      final streaming = StreamingStateCubit();
      final cubit = ChatSessionCubit(
        sessionId: 'session-1',
        bridge: bridge,
        streamingCubit: streaming,
        provider: Provider.codex,
      );
      final scrollController = AutoScrollController();
      addTearDown(bridge.dispose);
      addTearDown(streaming.close);
      addTearDown(scrollController.dispose);
      addTearDown(() async {
        if (!cubit.isClosed) await cubit.close();
      });

      await tester.pumpWidget(
        RepositoryProvider<BridgeService>.value(
          value: bridge,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<ChatSessionCubit>.value(value: cubit),
              BlocProvider<StreamingStateCubit>.value(value: streaming),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('en'),
              theme: AppTheme.darkTheme,
              home: Scaffold(
                body: ChatMessageList(
                  sessionId: 'session-1',
                  scrollController: scrollController,
                  httpBaseUrl: null,
                  onRetryMessage: null,
                  collapseToolResults: null,
                  isCodex: true,
                ),
              ),
            ),
          ),
        ),
      );

      bridge.emit(HistoryMessage(messages: _history()), 'session-1');
      await tester.pump();

      expect(find.text('Final answer'), findsOneWidget);
      expect(find.text('I will inspect the first file.'), findsNothing);
      expect(find.text('The second file confirms the issue.'), findsNothing);
      expect(find.byType(ChatIntermediateOutputsDisclosure), findsOneWidget);
      expect(find.byType(ChatProcessDisclosure), findsNothing);

      await tester.tap(find.byType(ChatIntermediateOutputsDisclosure));
      await tester.pump();

      expect(find.text('I will inspect the first file.'), findsOneWidget);
      expect(find.text('The second file confirms the issue.'), findsOneWidget);
      expect(find.byType(ChatProcessDisclosure), findsNWidgets(2));
      expect(find.text('first result'), findsNothing);
      expect(find.text('second result'), findsNothing);

      await tester.tap(
        find.byKey(
          const ValueKey(
            'chat_process_disclosure_client:turn-phases:segment:id:update-1',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('first result'), findsOneWidget);
      expect(find.text('second result'), findsNothing);

      await tester.tap(
        find.byKey(
          const ValueKey(
            'chat_process_disclosure_client:turn-phases:segment:id:update-2',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('first result'), findsOneWidget);
      expect(find.text('second result'), findsOneWidget);
      expect(find.text('Final answer'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await cubit.close();
    },
  );
}

List<ServerMessage> _history() => [
  const UserInputMessage(text: 'investigate', clientMessageId: 'turn-phases'),
  AssistantServerMessage(
    message: AssistantMessage(
      id: 'update-1',
      role: 'assistant',
      content: const [
        ThinkingContent(thinking: 'first thought'),
        TextContent(text: 'I will inspect the first file.'),
        ToolUseContent(
          id: 'tool-1',
          name: 'Read',
          input: {'file_path': 'first.txt'},
        ),
      ],
      model: 'codex',
    ),
  ),
  const ToolResultMessage(
    toolUseId: 'tool-1',
    toolName: 'Read',
    content: 'first result',
  ),
  AssistantServerMessage(
    message: AssistantMessage(
      id: 'hidden-work',
      role: 'assistant',
      content: const [
        ToolUseContent(
          id: 'tool-2',
          name: 'Read',
          input: {'file_path': 'second.txt'},
        ),
      ],
      model: 'codex',
    ),
  ),
  const ToolResultMessage(
    toolUseId: 'tool-2',
    toolName: 'Read',
    content: 'second result',
  ),
  AssistantServerMessage(
    message: AssistantMessage(
      id: 'update-2',
      role: 'assistant',
      content: const [TextContent(text: 'The second file confirms the issue.')],
      model: 'codex',
    ),
  ),
  AssistantServerMessage(
    message: AssistantMessage(
      id: 'final',
      role: 'assistant',
      content: const [TextContent(text: 'Final answer')],
      model: 'codex',
    ),
  ),
  const ResultMessage(subtype: 'success'),
];
