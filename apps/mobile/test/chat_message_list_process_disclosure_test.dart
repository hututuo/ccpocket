import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_message_list.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_process_disclosure.dart';
import 'package:ccpocket/features/chat_session/widgets/reading_position_auto_scroll_controller.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/assistant_bubble.dart'
    show ToolUseTile;
import 'package:ccpocket/widgets/bubbles/streaming_bubble.dart';
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
    'intermediate disclosure reveals updates while each thought and tool interval stays folded',
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
      final scrollController = ReadingPositionAutoScrollController();
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

      final disclosure = find.byKey(
        const ValueKey('chat_intermediate_disclosure_client:turn-phases'),
      );
      await tester.tap(disclosure);
      await tester.pump();
      await tester.pump();

      expect(find.text('I will inspect the first file.'), findsOneWidget);
      expect(find.text('The second file confirms the issue.'), findsOneWidget);
      expect(find.text('first result'), findsNothing);
      expect(find.text('second result'), findsNothing);
      expect(find.text('third result'), findsNothing);
      expect(find.byType(ChatProcessDisclosure), findsNWidgets(2));

      final firstUpdate = find.text('I will inspect the first file.');
      final secondUpdate = find.text('The second file confirms the issue.');
      final firstDisclosure = find.byKey(
        const ValueKey(
          'chat_process_disclosure_client:turn-phases:segment:id:update-1',
        ),
      );
      final secondDisclosure = find.byKey(
        const ValueKey(
          'chat_process_disclosure_client:turn-phases:segment:id:update-2',
        ),
      );
      expect(
        tester.getTopLeft(firstDisclosure).dy,
        greaterThan(tester.getBottomLeft(firstUpdate).dy),
      );
      expect(
        tester.getBottomLeft(firstDisclosure).dy,
        lessThan(tester.getTopLeft(secondUpdate).dy),
      );
      expect(
        tester.getTopLeft(secondDisclosure).dy,
        greaterThan(tester.getBottomLeft(secondUpdate).dy),
      );

      await tester.tap(firstDisclosure);
      await tester.pump();

      expect(find.text('first thought'), findsOneWidget);
      expect(find.text('first result'), findsOneWidget);
      expect(find.text('second result'), findsOneWidget);
      expect(find.text('second thought'), findsNothing);
      expect(find.text('third result'), findsNothing);

      await tester.tap(secondDisclosure);
      await tester.pump();
      expect(find.text('second thought'), findsOneWidget);
      expect(find.text('third result'), findsOneWidget);
      expect(find.text('Final answer'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await cubit.close();
    },
  );

  testWidgets('expanding an intermediate fold keeps its visible row anchored', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final bridge = _Bridge();
    final streaming = StreamingStateCubit();
    final cubit = ChatSessionCubit(
      sessionId: 'session-anchor',
      bridge: bridge,
      streamingCubit: streaming,
      provider: Provider.codex,
    );
    final scrollController = ReadingPositionAutoScrollController();
    addTearDown(bridge.dispose);
    addTearDown(streaming.close);
    addTearDown(scrollController.dispose);
    addTearDown(() async {
      if (!cubit.isClosed) await cubit.close();
    });

    await tester.pumpWidget(
      _chatHarness(
        bridge: bridge,
        cubit: cubit,
        streaming: streaming,
        scrollController: scrollController,
        sessionId: 'session-anchor',
      ),
    );

    bridge.emit(
      HistoryMessage(messages: _anchoringHistory()),
      'session-anchor',
    );
    await tester.pump();
    expect(scrollController.position.maxScrollExtent, greaterThan(0));
    final disclosure = find.byKey(
      const ValueKey('chat_intermediate_disclosure_client:turn-anchor'),
    );
    for (var step = 0; step <= 20; step++) {
      scrollController.jumpTo(
        scrollController.position.maxScrollExtent * step / 20,
      );
      await tester.pump();
      if (disclosure.evaluate().isNotEmpty) break;
    }
    expect(disclosure, findsOneWidget);

    final beforeY = tester.getTopLeft(disclosure).dy;
    await tester.tap(disclosure);
    await tester.pump();
    expect(tester.getTopLeft(disclosure).dy, closeTo(beforeY, 1));
    final firstUpdate = find.text('First historical update.');
    expect(firstUpdate, findsOneWidget);
    expect(
      tester.getTopLeft(firstUpdate).dy,
      greaterThan(tester.getBottomLeft(disclosure).dy),
    );
    expect(tester.takeException(), isNull);
    await cubit.close();
  });

  testWidgets(
    'a thirteen-tool expansion is anchored before its first painted frame',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final bridge = _Bridge();
      final streaming = StreamingStateCubit();
      final cubit = ChatSessionCubit(
        sessionId: 'session-large-anchor',
        bridge: bridge,
        streamingCubit: streaming,
        provider: Provider.codex,
      );
      final scrollController = ReadingPositionAutoScrollController();
      addTearDown(bridge.dispose);
      addTearDown(streaming.close);
      addTearDown(scrollController.dispose);
      addTearDown(() async {
        if (!cubit.isClosed) await cubit.close();
      });

      await tester.pumpWidget(
        _chatHarness(
          bridge: bridge,
          cubit: cubit,
          streaming: streaming,
          scrollController: scrollController,
          sessionId: 'session-large-anchor',
        ),
      );
      bridge.emit(
        HistoryMessage(
          messages: _anchoringHistory(toolCount: 13, includeActiveTail: true),
        ),
        'session-large-anchor',
      );
      await tester.pump();
      streaming.appendText('A live tail must not double-correct the anchor.');
      await tester.pump();

      final disclosure = find.byKey(
        const ValueKey('chat_intermediate_disclosure_client:turn-anchor'),
      );
      for (var step = 0; step <= 20; step++) {
        scrollController.jumpTo(
          scrollController.position.maxScrollExtent * step / 20,
        );
        await tester.pump();
        if (disclosure.evaluate().isNotEmpty) break;
      }
      expect(disclosure, findsOneWidget);

      final beforeY = tester.getTopLeft(disclosure).dy;
      await tester.tap(disclosure);
      await tester.pump();

      expect(tester.getTopLeft(disclosure).dy, closeTo(beforeY, 1));
      expect(
        scrollController.position.pixels,
        lessThan(scrollController.position.maxScrollExtent - 1),
      );
      final expandedY = tester.getTopLeft(disclosure).dy;
      await tester.tap(disclosure);
      await tester.pump();
      expect(tester.getTopLeft(disclosure).dy, closeTo(expandedY, 1));
      expect(tester.takeException(), isNull);
      await cubit.close();
    },
  );

  testWidgets(
    'active turn keeps only its latest output in the current-progress surface',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final bridge = _Bridge();
      final streaming = StreamingStateCubit();
      final cubit = ChatSessionCubit(
        sessionId: 'session-active',
        bridge: bridge,
        streamingCubit: streaming,
        provider: Provider.codex,
      );
      final scrollController = ReadingPositionAutoScrollController();
      addTearDown(bridge.dispose);
      addTearDown(streaming.close);
      addTearDown(scrollController.dispose);
      addTearDown(() async {
        if (!cubit.isClosed) await cubit.close();
      });

      await tester.pumpWidget(
        _chatHarness(
          bridge: bridge,
          cubit: cubit,
          streaming: streaming,
          scrollController: scrollController,
          sessionId: 'session-active',
        ),
      );

      bridge.emit(HistoryMessage(messages: _activeHistory()), 'session-active');
      await tester.pump();

      expect(find.text('Current progress'), findsOneWidget);
      expect(find.text('The second file is being checked.'), findsOneWidget);
      expect(find.text('Earlier update.'), findsNothing);
      expect(find.byType(ChatCurrentToolActivityLine), findsOneWidget);
      expect(find.text('first result'), findsNothing);

      await tester.tap(
        find.byKey(
          const ValueKey('chat_current_progress_entry:client:turn-active'),
        ),
      );
      await tester.pump();

      expect(find.text('current thought'), findsOneWidget);
      expect(find.byType(ToolUseTile), findsOneWidget);
      expect(find.text('Earlier update.'), findsNothing);
      expect(tester.takeException(), isNull);
      await cubit.close();
    },
  );

  testWidgets(
    'live stream stays outside the historical fold and reveals only its live details',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final bridge = _Bridge();
      final streaming = StreamingStateCubit();
      final cubit = ChatSessionCubit(
        sessionId: 'session-live',
        bridge: bridge,
        streamingCubit: streaming,
        provider: Provider.codex,
      );
      final scrollController = ReadingPositionAutoScrollController();
      addTearDown(bridge.dispose);
      addTearDown(streaming.close);
      addTearDown(scrollController.dispose);
      addTearDown(() async {
        if (!cubit.isClosed) await cubit.close();
      });

      await tester.pumpWidget(
        _chatHarness(
          bridge: bridge,
          cubit: cubit,
          streaming: streaming,
          scrollController: scrollController,
          sessionId: 'session-live',
        ),
      );

      bridge.emit(HistoryMessage(messages: _streamHistory()), 'session-live');
      await tester.pump();
      streaming.appendThinking('live reasoning');
      streaming.appendText('Live temporary output');
      await tester.pump();
      await tester.pump();

      expect(streaming.state.text, 'Live temporary output');
      expect(find.text('Current progress'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('chat_current_progress_live:client:turn-stream'),
        ),
        findsOneWidget,
      );
      expect(find.byType(StreamingBubble), findsOneWidget);
      final liveBubble = tester.widget<StreamingBubble>(
        find.byType(StreamingBubble),
      );
      expect(liveBubble.text, 'Live temporary output');
      expect(find.text('Persisted before the live delta.'), findsNothing);
      expect(find.byKey(const ValueKey('live_thinking_details')), findsNothing);

      await tester.tap(
        find.byKey(
          const ValueKey('chat_current_progress_live:client:turn-stream'),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('live_thinking_details')),
        findsOneWidget,
      );
      expect(find.text('live reasoning'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await cubit.close();
    },
  );
}

Widget _chatHarness({
  required _Bridge bridge,
  required ChatSessionCubit cubit,
  required StreamingStateCubit streaming,
  required AutoScrollController scrollController,
  required String sessionId,
}) => RepositoryProvider<BridgeService>.value(
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
          sessionId: sessionId,
          scrollController: scrollController,
          httpBaseUrl: null,
          onRetryMessage: null,
          collapseToolResults: null,
          isCodex: true,
        ),
      ),
    ),
  ),
);

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
      content: const [
        ThinkingContent(thinking: 'second thought'),
        TextContent(text: 'The second file confirms the issue.'),
        ToolUseContent(
          id: 'tool-3',
          name: 'Bash',
          input: {'command': 'git diff --stat'},
        ),
      ],
      model: 'codex',
    ),
  ),
  const ToolResultMessage(
    toolUseId: 'tool-3',
    toolName: 'Bash',
    content: 'third result',
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

List<ServerMessage> _activeHistory() => [
  const UserInputMessage(text: 'investigate', clientMessageId: 'turn-active'),
  AssistantServerMessage(
    message: AssistantMessage(
      id: 'earlier',
      role: 'assistant',
      content: const [
        TextContent(text: 'Earlier update.'),
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
      id: 'current',
      role: 'assistant',
      content: const [
        ThinkingContent(thinking: 'current thought'),
        TextContent(text: 'The second file is being checked.'),
        ToolUseContent(
          id: 'tool-2',
          name: 'Bash',
          input: {'command': 'git status --short'},
        ),
      ],
      model: 'codex',
    ),
  ),
  const StatusMessage(status: ProcessStatus.running),
];

List<ServerMessage> _streamHistory() => [
  const UserInputMessage(text: 'investigate', clientMessageId: 'turn-stream'),
  AssistantServerMessage(
    message: AssistantMessage(
      id: 'persisted-before-stream',
      role: 'assistant',
      content: const [
        TextContent(text: 'Persisted before the live delta.'),
        ToolUseContent(
          id: 'tool-stream',
          name: 'WebSearch',
          input: {'query': 'Codex Desktop'},
        ),
      ],
      model: 'codex',
    ),
  ),
  const StatusMessage(status: ProcessStatus.running),
];

List<ServerMessage> _anchoringHistory({
  int toolCount = 2,
  bool includeActiveTail = false,
}) {
  final earlierText = List<String>.filled(
    18,
    'An earlier completed turn leaves real transcript space above the target.',
  ).join('\n');
  final finalText = List<String>.filled(
    36,
    'A later completed answer keeps this disclosure in the middle of the transcript.',
  ).join('\n');
  final toolUses = <AssistantContent>[
    for (var index = 0; index < toolCount; index++)
      ToolUseContent(
        id: 'anchor-tool-$index',
        name: index.isEven ? 'Read' : 'Bash',
        input: index.isEven
            ? {'file_path': 'file-$index.txt'}
            : {'command': 'printf tool-$index'},
      ),
  ];
  return [
    const UserInputMessage(
      text: 'earlier question',
      clientMessageId: 'turn-before-anchor',
    ),
    AssistantServerMessage(
      message: AssistantMessage(
        id: 'earlier-final',
        role: 'assistant',
        content: [TextContent(text: earlierText)],
        model: 'codex',
      ),
    ),
    const UserInputMessage(text: 'investigate', clientMessageId: 'turn-anchor'),
    AssistantServerMessage(
      message: AssistantMessage(
        id: 'anchor-update-1',
        role: 'assistant',
        content: [
          const TextContent(text: 'First historical update.'),
          ...toolUses,
        ],
        model: 'codex',
      ),
    ),
    for (var index = 0; index < toolCount; index++)
      ToolResultMessage(
        toolUseId: 'anchor-tool-$index',
        toolName: index.isEven ? 'Read' : 'Bash',
        content: 'historical result $index',
      ),
    AssistantServerMessage(
      message: AssistantMessage(
        id: 'anchor-update-2',
        role: 'assistant',
        content: const [
          ThinkingContent(thinking: 'second historical thought'),
          TextContent(text: 'Second historical update.'),
          ToolUseContent(
            id: 'anchor-tail-tool',
            name: 'Bash',
            input: {'command': 'git status --short'},
          ),
        ],
        model: 'codex',
      ),
    ),
    const ToolResultMessage(
      toolUseId: 'anchor-tail-tool',
      toolName: 'Bash',
      content: 'second historical result',
    ),
    AssistantServerMessage(
      message: AssistantMessage(
        id: 'anchor-final',
        role: 'assistant',
        content: [TextContent(text: finalText)],
        model: 'codex',
      ),
    ),
    if (includeActiveTail)
      const UserInputMessage(
        text: 'new active turn',
        clientMessageId: 'turn-after-anchor',
      ),
  ];
}
