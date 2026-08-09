import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_message_list.dart';
import 'package:ccpocket/features/chat_session/widgets/reading_position_auto_scroll_controller.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _HistoryBridge extends BridgeService {
  final _messages = StreamController<ServerMessage>.broadcast();

  @override
  bool get isConnected => true;

  @override
  Stream<ServerMessage> messagesForSession(String sessionId) =>
      _messages.stream;

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
  testWidgets('history viewport returns to the untouched live timeline', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    List<ServerMessage> turn(int order) => [
      UserInputMessage(
        text: 'prompt-$order',
        providerItemId: 'user-$order',
        historyTurnId: 'turn-$order',
      ),
      AssistantServerMessage(
        message: AssistantMessage(
          id: 'assistant-$order',
          role: 'assistant',
          content: [
            TextContent(text: List.filled(40, 'answer-$order').join(' ')),
          ],
          model: '',
        ),
        historyTurnId: 'turn-$order',
      ),
    ];

    final bridge = _HistoryBridge();
    final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
    final scrollController = ReadingPositionAutoScrollController();
    final scrollToUserEntry = ValueNotifier<UserChatEntry?>(null);
    final cubit = ChatSessionCubit(
      sessionId: 'history-thread',
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streaming,
      detachedPreview: true,
      initialHistoryMessages: turn(7),
      detachedUserMessageIndexLoader: () async => (
        messages: [
          for (var order = 0; order < 8; order++)
            UserInputMessage(
              text: 'prompt-$order',
              providerItemId: 'user-$order',
              historyTurnId: 'turn-$order',
            ),
        ],
        complete: true,
      ),
      detachedUserTurnLoader: (turnId) async =>
          turn(int.parse(turnId.substring('turn-'.length))),
    );
    addTearDown(bridge.dispose);
    addTearDown(streaming.close);
    addTearDown(scrollController.dispose);
    addTearDown(scrollToUserEntry.dispose);
    addTearDown(cubit.close);

    await tester.pumpWidget(
      RepositoryProvider<BridgeService>.value(
        value: bridge,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<ChatSessionCubit>.value(value: cubit),
            BlocProvider<StreamingStateCubit>.value(value: streaming),
          ],
          child: MaterialApp(
            theme: AppTheme.lightThemeForLocale(const Locale('zh')),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            home: Scaffold(
              body: ChatMessageList(
                sessionId: 'history-thread',
                scrollController: scrollController,
                scrollToUserEntry: scrollToUserEntry,
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

    final index = await cubit.loadAllUserMessagesForNavigation();
    final target = index.singleWhere(
      (entry) => entry.historyTurnId == 'turn-1',
    );
    final revealed = await cubit.revealUserMessage(target);
    expect(revealed, isNotNull);
    scrollToUserEntry.value = revealed;
    await tester.pumpAndSettle();

    expect(find.text('prompt-1'), findsOneWidget);
    expect(
      tester.getCenter(find.text('prompt-1')).dy,
      inInclusiveRange(0, 900),
    );
    expect(find.text('prompt-7'), findsNothing);
    scrollController.jumpTo(scrollController.position.minScrollExtent);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('local_history_newer_retry')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('local_history_return_latest')),
      findsOneWidget,
    );
    expect(
      cubit.state.entries.whereType<UserChatEntry>().single.text,
      'prompt-7',
    );

    await tester.tap(find.byKey(const ValueKey('local_history_return_latest')));
    await tester.pumpAndSettle();

    expect(cubit.historyNavigationActive, isFalse);
    expect(cubit.localHistoryPaging.value.loading, isFalse);
    expect(find.text('prompt-1'), findsNothing);
    expect(find.text('prompt-7'), findsOneWidget);
  });
}
