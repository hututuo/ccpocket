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
import 'package:ccpocket/widgets/bubbles/guardian_approval_notice.dart';
import 'package:ccpocket/widgets/bubbles/streaming_bubble.dart';
import 'package:ccpocket/widgets/bubbles/todo_write_widget.dart';
import 'package:ccpocket/widgets/bubbles/tool_result_bubble.dart';
import 'package:ccpocket/widgets/chat_message_timestamp.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  final _messages = StreamController<(ServerMessage, String?)>.broadcast();
  final historyToolDetailRequests = <List<String>>[];
  Future<List<HistoryToolDetail>?> Function(List<String> toolUseIds)?
  historyToolDetailLoader;

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
  Future<List<HistoryToolDetail>?> requestHistoryToolDetails({
    required String runtimeSessionId,
    required List<String> toolUseIds,
    Duration timeout = const Duration(seconds: 12),
  }) {
    final ids = List<String>.unmodifiable(toolUseIds);
    historyToolDetailRequests.add(ids);
    return historyToolDetailLoader?.call(ids) ?? Future.value();
  }

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
      final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
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

      final disclosure = find.byKey(
        const ValueKey('chat_intermediate_disclosure_client:turn-phases'),
      );
      for (var step = 0; step <= 100; step++) {
        scrollController.jumpTo(
          scrollController.position.maxScrollExtent * step / 100,
        );
        await tester.pump();
        if (disclosure.evaluate().isNotEmpty) {
          final y = tester.getTopLeft(disclosure).dy;
          if (y >= 120 && y <= 400) break;
        }
      }
      expect(disclosure, findsOneWidget);
      expect(find.byType(ChatIntermediateOutputsDisclosure), findsOneWidget);
      expect(find.byType(ChatProcessDisclosure), findsNothing);
      final outerTimestamp = find.descendant(
        of: disclosure,
        matching: find.byType(ChatMessageTimestampText),
      );
      final outerChevron = find.descendant(
        of: disclosure,
        matching: find.byIcon(Icons.expand_more),
      );
      expect(outerTimestamp, findsOneWidget);
      expect(outerChevron, findsOneWidget);
      expect(
        tester.getTopRight(outerTimestamp).dx,
        lessThan(tester.getTopLeft(outerChevron).dx),
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
      final firstTimestamp = find.descendant(
        of: firstDisclosure,
        matching: find.byType(ChatMessageTimestampText),
      );
      final firstChevron = find.descendant(
        of: firstDisclosure,
        matching: find.byIcon(Icons.expand_more),
      );
      expect(firstTimestamp, findsOneWidget);
      expect(firstChevron, findsOneWidget);
      expect(
        tester.getTopRight(firstTimestamp).dx,
        lessThan(tester.getTopLeft(firstChevron).dx),
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

      final firstDisclosureY = tester.getTopLeft(firstDisclosure).dy;
      await tester.tap(firstDisclosure);
      await tester.pump();

      expect(
        tester.getTopLeft(firstDisclosure).dy,
        closeTo(firstDisclosureY, 1),
      );
      expect(find.text('first thought'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('first thought')).dy,
        greaterThan(tester.getBottomLeft(firstDisclosure).dy),
      );
      expect(find.byType(ToolResultBubble), findsNWidgets(2));
      expect(find.text('first result'), findsNothing);
      expect(find.text('second result'), findsNothing);
      await _expandToolResult(tester, 0);
      await _expandToolResult(tester, 1);
      expect(find.text('first result'), findsOneWidget);
      expect(find.text('second result'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('second result')).dy,
        greaterThan(tester.getBottomLeft(firstDisclosure).dy),
      );
      expect(
        tester.getBottomLeft(find.text('second result')).dy,
        lessThan(tester.getTopLeft(secondUpdate).dy),
      );
      expect(find.text('second thought'), findsNothing);
      expect(find.text('third result'), findsNothing);

      await tester.tap(secondDisclosure);
      await tester.pump();
      expect(find.text('second thought'), findsOneWidget);
      expect(find.text('third result'), findsNothing);
      await _expandToolResult(tester, 2);
      expect(find.text('third result'), findsOneWidget);
      scrollController.jumpTo(0);
      await tester.pump();
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
    final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
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
      final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
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
    'a large tool group uses an eight-row viewport and scrolls internally',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final bridge = _Bridge();
      final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
      final cubit = ChatSessionCubit(
        sessionId: 'session-bounded-tools',
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
          sessionId: 'session-bounded-tools',
        ),
      );
      bridge.emit(
        HistoryMessage(messages: _anchoringHistory(toolCount: 13)),
        'session-bounded-tools',
      );
      await tester.pump();

      final outerDisclosure = find.byKey(
        const ValueKey('chat_intermediate_disclosure_client:turn-anchor'),
      );
      for (var step = 0; step <= 30; step++) {
        scrollController.jumpTo(
          scrollController.position.maxScrollExtent * step / 30,
        );
        await tester.pump();
        if (outerDisclosure.evaluate().isNotEmpty) break;
      }
      await tester.tap(outerDisclosure);
      await tester.pump();

      final processDisclosure = find.byKey(
        const ValueKey(
          'chat_process_disclosure_client:turn-anchor:segment:id:anchor-update-1',
        ),
      );
      await tester.tap(processDisclosure);
      await tester.pump();

      final viewport = find.byKey(
        const ValueKey(
          'process_details_viewport_client:turn-anchor:segment:id:anchor-update-1',
        ),
      );
      expect(viewport, findsOneWidget);
      expect(tester.getSize(viewport).height, lessThanOrEqualTo(353));
      expect(find.byType(ToolUseTile), findsNWidgets(13));

      final detailsScroll = find.descendant(
        of: viewport,
        matching: find.byKey(const ValueKey('process_details_scroll_view')),
      );
      final nestedScrollable = find.descendant(
        of: detailsScroll,
        matching: find.byType(Scrollable),
      );
      final nestedPosition = tester
          .state<ScrollableState>(nestedScrollable)
          .position;
      expect(nestedPosition.maxScrollExtent, greaterThan(0));
      expect(nestedPosition.pixels, 0);
      await tester.drag(detailsScroll, const Offset(0, -1000));
      await tester.pumpAndSettle();
      expect(nestedPosition.pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
      await cubit.close();
    },
  );

  testWidgets('opening an old tool gap loads at most eight details per page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final bridge = _Bridge();
    bridge.historyToolDetailLoader = (toolUseIds) async => [
      for (final toolUseId in toolUseIds)
        HistoryToolDetail(
          toolUseId: toolUseId,
          toolName: 'Read',
          input: {'file_path': '$toolUseId.txt'},
          result: ToolResultMessage(
            toolUseId: toolUseId,
            toolName: 'Read',
            content: 'result for $toolUseId',
          ),
        ),
    ];
    final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
    final cubit = ChatSessionCubit(
      sessionId: 'session-history-tool-gap',
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
        sessionId: 'session-history-tool-gap',
      ),
    );
    final gap = HistoryToolDetailGap(
      gapId: 'gap-old-tools',
      toolUseIds: List.generate(10, (index) => 'old-tool-$index'),
      toolNames: List.generate(10, (_) => 'Read'),
      toolCallCount: 10,
    );
    bridge.emit(
      HistoryMessage(
        messages: [
          const UserInputMessage(
            text: 'show prior work',
            clientMessageId: 'turn-gap',
          ),
          AssistantServerMessage(
            message: const AssistantMessage(
              id: 'gap-update',
              role: 'assistant',
              content: [TextContent(text: 'Prior work is available.')],
              model: 'codex',
            ),
            historyToolDetailGaps: [gap],
          ),
          const ResultMessage(subtype: 'success'),
        ],
      ),
      'session-history-tool-gap',
    );
    await tester.pump();

    final disclosure = find.byKey(
      const ValueKey(
        'chat_process_disclosure_client:turn-gap:segment:id:gap-update',
      ),
    );
    expect(disclosure, findsOneWidget);
    expect(bridge.historyToolDetailRequests, isEmpty);
    expect(find.byType(ToolUseTile), findsNothing);

    await tester.tap(disclosure);
    await tester.pump();
    await tester.pump();

    expect(bridge.historyToolDetailRequests, hasLength(1));
    expect(bridge.historyToolDetailRequests.single, [
      'old-tool-0',
      'old-tool-1',
      'old-tool-2',
      'old-tool-3',
      'old-tool-4',
      'old-tool-5',
      'old-tool-6',
      'old-tool-7',
    ]);
    expect(find.byType(ToolUseTile), findsNWidgets(8));
    expect(find.byType(ToolResultBubble), findsNWidgets(8));
    expect(find.text('Load the next 2 tool details'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey(
          'process_details_viewport_client:turn-gap:segment:id:gap-update',
        ),
      ),
      findsOneWidget,
    );

    final loadMore = find.text('Load the next 2 tool details');
    await tester.ensureVisible(loadMore);
    await tester.pump();
    await tester.tap(loadMore);
    await tester.pump();
    await tester.pump();

    expect(bridge.historyToolDetailRequests, hasLength(2));
    expect(bridge.historyToolDetailRequests.last, ['old-tool-8', 'old-tool-9']);
    expect(find.byType(ToolUseTile), findsNWidgets(10));
    expect(find.byType(ToolResultBubble), findsNWidgets(10));
    expect(find.text('Load the next 2 tool details'), findsNothing);
    expect(tester.takeException(), isNull);
    await cubit.close();
  });

  testWidgets(
    'incremental output and app lifecycle keep current progress expanded',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final bridge = _Bridge();
      final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
      final cubit = ChatSessionCubit(
        sessionId: 'session-stable-disclosure',
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
          sessionId: 'session-stable-disclosure',
        ),
      );
      bridge.emit(
        HistoryMessage(messages: _activeHistory()),
        'session-stable-disclosure',
      );
      await tester.pump();

      final currentHeader = find.byKey(
        const ValueKey('chat_current_progress_turn:client:turn-active'),
      );
      await tester.tap(currentHeader);
      await tester.pump();
      expect(
        tester
            .widget<ChatCurrentProgressHeader>(
              find.byType(ChatCurrentProgressHeader),
            )
            .expanded,
        isTrue,
      );

      streaming.appendThinking('streamed follow-up thought');
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<ChatCurrentProgressHeader>(
              find.byType(ChatCurrentProgressHeader),
            )
            .expanded,
        isTrue,
      );
      expect(find.text('streamed follow-up thought'), findsOneWidget);

      streaming.reset();
      await tester.pump();
      expect(
        tester
            .widget<ChatCurrentProgressHeader>(
              find.byType(ChatCurrentProgressHeader),
            )
            .expanded,
        isTrue,
      );

      bridge.emit(
        AssistantServerMessage(
          message: AssistantMessage(
            id: 'current-follow-up',
            role: 'assistant',
            content: const [
              ThinkingContent(thinking: 'follow-up thought'),
              TextContent(text: 'The live update continued.'),
              ToolUseContent(
                id: 'tool-follow-up',
                name: 'Read',
                input: {'file_path': 'follow-up.txt'},
              ),
            ],
            model: 'codex',
          ),
        ),
        'session-stable-disclosure',
      );
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<ChatCurrentProgressHeader>(
              find.byType(ChatCurrentProgressHeader),
            )
            .expanded,
        isTrue,
      );

      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      expect(
        tester
            .widget<ChatCurrentProgressHeader>(
              find.byType(ChatCurrentProgressHeader),
            )
            .expanded,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await cubit.close();
    },
  );

  testWidgets(
    'a long intermediate hierarchy unfolds below a persistent outer header',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final bridge = _Bridge();
      final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
      final cubit = ChatSessionCubit(
        sessionId: 'session-long-hierarchy',
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
          sessionId: 'session-long-hierarchy',
        ),
      );
      bridge.emit(
        HistoryMessage(messages: _manyIntermediateHistory(13)),
        'session-long-hierarchy',
      );
      await tester.pump();

      final outerDisclosure = find.byKey(
        const ValueKey('chat_intermediate_disclosure_client:turn-many'),
      );
      for (var step = 0; step <= 20; step++) {
        scrollController.jumpTo(
          scrollController.position.maxScrollExtent * step / 20,
        );
        await tester.pump();
        if (outerDisclosure.evaluate().isNotEmpty) {
          final y = tester.getTopLeft(outerDisclosure).dy;
          if (y >= 120 && y <= 320) break;
        }
      }
      expect(outerDisclosure, findsOneWidget);

      final beforeY = tester.getTopLeft(outerDisclosure).dy;
      await tester.tap(outerDisclosure);
      await tester.pump();

      expect(outerDisclosure, findsOneWidget);
      expect(tester.getTopLeft(outerDisclosure).dy, closeTo(beforeY, 1));
      expect(find.byType(ChatIntermediateOutputsDisclosure), findsOneWidget);
      expect(find.byType(ChatProcessDisclosure), findsNWidgets(13));
      expect(find.text('Intermediate update 0'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Intermediate update 0')).dy,
        greaterThan(tester.getBottomLeft(outerDisclosure).dy),
      );

      final firstProcessDisclosure = find.byKey(
        const ValueKey(
          'chat_process_disclosure_client:turn-many:segment:id:many-update-0',
        ),
      );
      expect(
        tester.getTopLeft(firstProcessDisclosure).dy,
        greaterThan(
          tester.getBottomLeft(find.text('Intermediate update 0')).dy,
        ),
      );
      final processY = tester.getTopLeft(firstProcessDisclosure).dy;
      await tester.tap(firstProcessDisclosure);
      await tester.pump();
      expect(
        tester.getTopLeft(firstProcessDisclosure).dy,
        closeTo(processY, 1),
      );
      expect(
        tester.getTopLeft(find.text('Intermediate thought 0')).dy,
        greaterThan(tester.getBottomLeft(firstProcessDisclosure).dy),
      );
      expect(find.text('Intermediate result 0'), findsNothing);
      await _expandToolResult(tester, 0);
      expect(find.text('Intermediate result 0'), findsOneWidget);

      final outerY = tester.getTopLeft(outerDisclosure).dy;
      await tester.tap(outerDisclosure);
      await tester.pump();
      expect(tester.getTopLeft(outerDisclosure).dy, closeTo(outerY, 1));
      expect(find.byType(ChatIntermediateOutputsDisclosure), findsOneWidget);
      expect(find.byType(ChatProcessDisclosure), findsNothing);
      expect(find.text('Intermediate update 0'), findsNothing);
      expect(tester.takeException(), isNull);
      await cubit.close();
    },
  );

  testWidgets(
    'a render window starting mid-turn still owns one outer process fold',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final bridge = _Bridge();
      final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
      final cubit = ChatSessionCubit(
        sessionId: 'session-partial-window',
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
          sessionId: 'session-partial-window',
        ),
      );
      bridge.emit(
        HistoryMessage(messages: _partialTurnWindowHistory(13)),
        'session-partial-window',
      );
      await tester.pump();

      final outerDisclosure = find.byKey(
        const ValueKey(
          'chat_intermediate_disclosure_partial:id:partial-window-update-0',
        ),
      );
      for (var step = 0; step <= 30; step++) {
        scrollController.jumpTo(
          scrollController.position.maxScrollExtent * step / 30,
        );
        await tester.pump();
        if (outerDisclosure.evaluate().isNotEmpty) break;
      }

      expect(outerDisclosure, findsOneWidget);
      expect(find.byType(ChatIntermediateOutputsDisclosure), findsOneWidget);
      expect(find.byType(ChatProcessDisclosure), findsNothing);
      expect(find.text('Retained update 0'), findsNothing);
      expect(find.text('Retained thought 0'), findsNothing);

      await tester.tap(outerDisclosure);
      await tester.pump();

      expect(outerDisclosure, findsOneWidget);
      expect(find.byType(ChatProcessDisclosure), findsNWidgets(13));
      expect(find.text('Retained update 0'), findsOneWidget);
      expect(find.text('Retained thought 0'), findsNothing);
      expect(tester.takeException(), isNull);
      await cubit.close();
    },
  );

  testWidgets(
    'a standalone process disclosure also reveals every detail below its row',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final bridge = _Bridge();
      final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
      final cubit = ChatSessionCubit(
        sessionId: 'session-standalone-process',
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
          sessionId: 'session-standalone-process',
        ),
      );
      bridge.emit(
        HistoryMessage(messages: _standaloneProcessHistory()),
        'session-standalone-process',
      );
      await tester.pump();

      final output = find.text('Standalone final output');
      final disclosure = find.byKey(
        const ValueKey(
          'chat_process_disclosure_client:turn-standalone:segment:id:standalone-final',
        ),
      );
      for (var step = 0; step <= 100; step++) {
        scrollController.jumpTo(
          scrollController.position.maxScrollExtent * step / 100,
        );
        await tester.pump();
        if (disclosure.evaluate().isNotEmpty && output.evaluate().isNotEmpty) {
          final y = tester.getTopLeft(disclosure).dy;
          if (y >= 120 && y <= 650) break;
        }
      }
      expect(output, findsOneWidget);
      expect(disclosure, findsOneWidget);
      expect(find.text('Standalone thought'), findsNothing);
      expect(find.text('Standalone result'), findsNothing);
      expect(
        tester.getTopLeft(disclosure).dy,
        greaterThan(tester.getBottomLeft(output).dy),
      );

      await tester.tap(disclosure);
      await tester.pump();

      expect(
        tester.getTopLeft(find.text('Standalone thought')).dy,
        greaterThan(tester.getBottomLeft(disclosure).dy),
      );
      expect(find.text('Standalone result'), findsNothing);
      await _expandToolResult(tester, 0);
      expect(
        tester.getTopLeft(find.text('Standalone result')).dy,
        greaterThan(tester.getBottomLeft(disclosure).dy),
      );
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
      final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
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

      final currentHeader = find.byKey(
        const ValueKey('chat_current_progress_turn:client:turn-active'),
      );
      final currentOutput = find.text('The second file is being checked.');
      final currentToolLine = find.byType(ChatCurrentToolActivityLine);
      expect(
        tester.getTopLeft(currentOutput).dy,
        greaterThan(tester.getBottomLeft(currentHeader).dy),
      );
      expect(
        tester.getTopLeft(currentToolLine).dy,
        greaterThan(tester.getBottomLeft(currentOutput).dy),
      );

      await tester.tap(currentHeader);
      await tester.pump();

      expect(find.text('current thought'), findsOneWidget);
      expect(find.byType(ToolUseTile), findsOneWidget);
      expect(find.byType(ChatCurrentToolActivityLine), findsNothing);
      expect(
        tester.getTopLeft(find.text('current thought')).dy,
        greaterThan(tester.getBottomLeft(currentOutput).dy),
      );
      expect(find.text('Earlier update.'), findsNothing);
      expect(tester.takeException(), isNull);
      await cubit.close();
    },
  );

  testWidgets(
    'current Guardian review appears once below its tool and hides after three seconds',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final bridge = _Bridge();
      final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
      final cubit = ChatSessionCubit(
        sessionId: 'session-guardian',
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
          sessionId: 'session-guardian',
        ),
      );

      bridge.emit(
        HistoryMessage(messages: _guardianActiveHistory()),
        'session-guardian',
      );
      await tester.pump();

      final toolLine = find.byType(ChatCurrentToolActivityLine);
      final toolRow = find.byKey(
        const ValueKey('chat_current_tool_guardian-tool'),
      );
      final guardian = find.byType(GuardianApprovalNotice);
      expect(toolLine, findsOneWidget);
      expect(toolRow, findsOneWidget);
      expect(guardian, findsOneWidget);
      expect(find.text('Auto Review approved'), findsOneWidget);
      expect(
        tester.getTopLeft(guardian).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(toolRow).dy),
      );

      final currentHeader = find.byKey(
        const ValueKey('chat_current_progress_turn:client:turn-guardian'),
      );
      await tester.tap(currentHeader);
      await tester.pump();
      expect(find.byType(GuardianApprovalNotice), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 2900));
      expect(find.byType(GuardianApprovalNotice), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(GuardianApprovalNotice), findsNothing);
      expect(find.byType(ChatCurrentToolActivityLine), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'live stream stays outside the historical fold and reveals only its live details',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final bridge = _Bridge();
      final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
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
          const ValueKey('chat_current_progress_turn:client:turn-stream'),
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
          const ValueKey('chat_current_progress_turn:client:turn-stream'),
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

  testWidgets('latest plan checklist stays outside and updates in place', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _Bridge();
    final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
    final cubit = ChatSessionCubit(
      sessionId: 'session-live-plan',
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
        sessionId: 'session-live-plan',
      ),
    );

    bridge.emit(
      HistoryMessage(messages: _planHistory(completed: false)),
      'session-live-plan',
    );
    await tester.pump();
    final planKey = find.byKey(
      const ValueKey('live_plan_update_client:turn-live-plan'),
    );
    expect(planKey, findsOneWidget);
    expect(find.byType(TodoWriteWidget), findsOneWidget);
    expect(find.text('(0/2)'), findsOneWidget);
    expect(find.text('Update plan'), findsNothing);

    bridge.emit(_planUpdateMessage(completed: true), 'session-live-plan');
    await tester.pump();
    await tester.pump();

    expect(planKey, findsOneWidget);
    expect(find.byType(TodoWriteWidget), findsOneWidget);
    expect(find.text('(1/2)'), findsOneWidget);
    expect(find.text('Implement lazily'), findsOneWidget);
    await cubit.close();
  });

  testWidgets('collapse notifier closes the outer process hierarchy', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _Bridge();
    final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
    final cubit = ChatSessionCubit(
      sessionId: 'session-collapse-all',
      bridge: bridge,
      streamingCubit: streaming,
      provider: Provider.codex,
    );
    final scrollController = ReadingPositionAutoScrollController();
    final collapseNotifier = ValueNotifier<int>(0);
    addTearDown(bridge.dispose);
    addTearDown(streaming.close);
    addTearDown(scrollController.dispose);
    addTearDown(collapseNotifier.dispose);
    addTearDown(() async {
      if (!cubit.isClosed) await cubit.close();
    });
    await tester.pumpWidget(
      _chatHarness(
        bridge: bridge,
        cubit: cubit,
        streaming: streaming,
        scrollController: scrollController,
        sessionId: 'session-collapse-all',
        collapseNotifier: collapseNotifier,
      ),
    );
    bridge.emit(HistoryMessage(messages: _history()), 'session-collapse-all');
    await tester.pump();

    final disclosure = find.byKey(
      const ValueKey('chat_intermediate_disclosure_client:turn-phases'),
    );
    for (var step = 0; step <= 100; step++) {
      scrollController.jumpTo(
        scrollController.position.maxScrollExtent * step / 100,
      );
      await tester.pump();
      if (disclosure.evaluate().isNotEmpty) {
        final y = tester.getTopLeft(disclosure.first).dy;
        if (y >= 80 && y <= 820) break;
      }
    }
    await tester.tap(disclosure.first);
    await tester.pump();
    expect(find.text('I will inspect the first file.'), findsOneWidget);

    collapseNotifier.value++;
    await tester.pump();
    expect(find.text('I will inspect the first file.'), findsNothing);
    await cubit.close();
  });
}

Widget _chatHarness({
  required _Bridge bridge,
  required ChatSessionCubit cubit,
  required StreamingStateCubit streaming,
  required AutoScrollController scrollController,
  required String sessionId,
  ValueNotifier<int>? collapseNotifier,
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
          collapseToolResults: collapseNotifier,
          isCodex: true,
        ),
      ),
    ),
  ),
);

Future<void> _expandToolResult(WidgetTester tester, int index) async {
  final bubble = find.byType(ToolResultBubble).at(index);
  final disclosure = find.descendant(
    of: bubble,
    matching: find.byKey(const ValueKey('tool_result_disclosure')),
  );
  expect(disclosure, findsOneWidget);
  await tester.ensureVisible(disclosure);
  await tester.pump();
  await tester.tap(disclosure);
  await tester.pump();
}

List<ServerMessage> _planHistory({required bool completed}) => [
  const UserInputMessage(text: 'implement', clientMessageId: 'turn-live-plan'),
  const AssistantServerMessage(
    message: AssistantMessage(
      id: 'plan-initial',
      role: 'assistant',
      model: 'codex',
      content: [
        ToolUseContent(
          id: 'plan-tool-1',
          name: 'UpdatePlan',
          input: {
            'title': 'Implementation plan',
            'todos': [
              {
                'content': 'Inspect current behavior',
                'status': 'in_progress',
                'activeForm': 'Inspecting',
              },
              {
                'content': 'Implement lazily',
                'status': 'pending',
                'activeForm': '',
              },
            ],
          },
        ),
      ],
    ),
  ),
  _planUpdateMessage(completed: completed),
];

AssistantServerMessage _planUpdateMessage({required bool completed}) =>
    AssistantServerMessage(
      message: AssistantMessage(
        id: completed ? 'plan-completed' : 'plan-latest',
        role: 'assistant',
        model: 'codex',
        content: [
          ToolUseContent(
            id: completed ? 'plan-tool-completed' : 'plan-tool-2',
            name: 'UpdatePlan',
            input: {
              'title': 'Implementation plan',
              'todos': [
                {
                  'content': 'Inspect current behavior',
                  'status': completed ? 'completed' : 'in_progress',
                  'activeForm': completed ? '' : 'Inspecting',
                },
                {
                  'content': 'Implement lazily',
                  'status': completed ? 'in_progress' : 'pending',
                  'activeForm': completed ? 'Implementing' : '',
                },
              ],
            },
          ),
        ],
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
  // Deliberately arrives after the next visible update. The UI must still
  // render it under the process segment that issued tool-2.
  const ToolResultMessage(
    toolUseId: 'tool-2',
    toolName: 'Read',
    content: 'second result',
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
      content: [
        const TextContent(text: 'Final answer'),
        TextContent(
          text: List<String>.filled(
            18,
            'Completed answer context remains below the intermediate process.',
          ).join('\n\n'),
        ),
      ],
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

List<ServerMessage> _guardianActiveHistory() => [
  const UserInputMessage(text: 'run it', clientMessageId: 'turn-guardian'),
  AssistantServerMessage(
    message: const AssistantMessage(
      id: 'guardian-current',
      role: 'assistant',
      content: [
        TextContent(text: 'The command has been reviewed.'),
        ToolUseContent(
          id: 'guardian-tool',
          name: 'Bash',
          input: {'command': 'git status --short'},
        ),
      ],
      model: 'codex',
    ),
  ),
  const ToolResultMessage(
    toolUseId: 'guardian-tool',
    toolName: 'Bash',
    content: 'clean',
  ),
  const GuardianApprovalMessage(
    risk: GuardianApprovalRisk.medium,
    reason: 'The command inspects repository state.',
    reviewId: 'guardian-review-1',
    targetItemId: 'guardian-tool',
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

List<ServerMessage> _manyIntermediateHistory(int count) => [
  const UserInputMessage(
    text: 'earlier question',
    clientMessageId: 'turn-before-many',
  ),
  AssistantServerMessage(
    message: AssistantMessage(
      id: 'before-many-final',
      role: 'assistant',
      content: [
        TextContent(
          text: List<String>.filled(
            24,
            'Earlier completed content keeps the target away from the transcript boundary.',
          ).join('\n'),
        ),
      ],
      model: 'codex',
    ),
  ),
  const UserInputMessage(text: 'investigate', clientMessageId: 'turn-many'),
  for (var index = 0; index < count; index++) ...[
    AssistantServerMessage(
      message: AssistantMessage(
        id: 'many-update-$index',
        role: 'assistant',
        content: [
          ThinkingContent(thinking: 'Intermediate thought $index'),
          TextContent(text: 'Intermediate update $index'),
          ToolUseContent(
            id: 'many-tool-$index',
            name: index.isEven ? 'Read' : 'Bash',
            input: index.isEven
                ? {'file_path': 'file-$index.txt'}
                : {'command': 'printf $index'},
          ),
        ],
        model: 'codex',
      ),
    ),
    ToolResultMessage(
      toolUseId: 'many-tool-$index',
      toolName: index.isEven ? 'Read' : 'Bash',
      content: 'Intermediate result $index',
    ),
  ],
  AssistantServerMessage(
    message: AssistantMessage(
      id: 'many-final',
      role: 'assistant',
      content: [
        TextContent(
          text: List<String>.filled(
            20,
            'Final answer after many updates keeps content below the target.',
          ).join('\n'),
        ),
      ],
      model: 'codex',
    ),
  ),
];

List<ServerMessage> _standaloneProcessHistory() => [
  const UserInputMessage(
    text: 'finish the task',
    clientMessageId: 'turn-standalone',
  ),
  AssistantServerMessage(
    message: AssistantMessage(
      id: 'standalone-final',
      role: 'assistant',
      content: const [
        ThinkingContent(thinking: 'Standalone thought'),
        TextContent(text: 'Standalone final output'),
        ToolUseContent(
          id: 'standalone-tool',
          name: 'Read',
          input: {'file_path': 'standalone.txt'},
        ),
      ],
      model: 'codex',
    ),
  ),
  const ToolResultMessage(
    toolUseId: 'standalone-tool',
    toolName: 'Read',
    content: 'Standalone result',
  ),
  const ResultMessage(subtype: 'success'),
  const UserInputMessage(
    text: 'next question',
    clientMessageId: 'turn-after-standalone',
  ),
  AssistantServerMessage(
    message: AssistantMessage(
      id: 'after-standalone-final',
      role: 'assistant',
      content: [
        TextContent(
          text: List<String>.filled(
            40,
            'A later completed answer keeps the standalone process in the middle.',
          ).join('\n\n'),
        ),
      ],
      model: 'codex',
    ),
  ),
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

List<ServerMessage> _partialTurnWindowHistory(int updateCount) {
  final messages = <ServerMessage>[];
  for (var index = 0; index < updateCount; index++) {
    messages.add(
      AssistantServerMessage(
        message: AssistantMessage(
          id: 'partial-window-update-$index',
          role: 'assistant',
          content: [
            ThinkingContent(thinking: 'Retained thought $index'),
            TextContent(text: 'Retained update $index'),
            ToolUseContent(
              id: 'partial-window-tool-$index',
              name: index.isEven ? 'Read' : 'Bash',
              input: index.isEven
                  ? {'file_path': 'retained-$index.txt'}
                  : {'command': 'printf retained-$index'},
            ),
          ],
          model: 'codex',
        ),
      ),
    );
    messages.add(
      ToolResultMessage(
        toolUseId: 'partial-window-tool-$index',
        toolName: index.isEven ? 'Read' : 'Bash',
        content: 'Retained result $index',
      ),
    );
  }
  messages.addAll([
    AssistantServerMessage(
      message: const AssistantMessage(
        id: 'partial-window-final',
        role: 'assistant',
        content: [TextContent(text: 'Retained final answer')],
        model: 'codex',
      ),
    ),
    const ResultMessage(subtype: 'success'),
    const UserInputMessage(
      text: 'A later complete turn',
      clientMessageId: 'turn-after-partial-window',
    ),
    AssistantServerMessage(
      message: const AssistantMessage(
        id: 'after-partial-window-final',
        role: 'assistant',
        content: [TextContent(text: 'Later final answer')],
        model: 'codex',
      ),
    ),
  ]);
  return messages;
}
