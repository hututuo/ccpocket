import 'dart:async';

import 'package:ccpocket/features/claude_session/widgets/rewind_message_list_sheet.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('turn history uses the selected Japanese locale', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ja'),
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: UserMessageHistorySheet(
            messages: const [],
            onScrollToMessage: (_) async => true,
          ),
        ),
      ),
    );

    expect(find.text('ターン履歴'), findsOneWidget);
    expect(find.text('ターンはまだありません'), findsOneWidget);
    expect(find.text('メッセージを送信すると、各ターンの先頭がここに表示されます'), findsOneWidget);
  });

  testWidgets('Codex turn history presents the pencil edit action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: UserMessageHistorySheet(
            messages: [
              UserChatEntry(
                '修改这一轮',
                messageUuid: 'turn-edit',
                status: MessageStatus.sent,
              ),
            ],
            rewindAsEdit: true,
            onScrollToMessage: (_) async => true,
            onRewindMessage: (_) {},
          ),
        ),
      ),
    );

    final editAction = find.byKey(const ValueKey('edit_turn_1'));
    expect(editAction, findsOneWidget);
    expect(
      find.descendant(
        of: editAction,
        matching: find.byIcon(Icons.edit_outlined),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('编辑'), findsOneWidget);
    expect(find.byKey(const ValueKey('rewind_turn_1')), findsNothing);
  });

  testWidgets(
    'refreshes an already-open turn picker when the full index is ready',
    (tester) async {
      final revision = ValueNotifier(0);
      addTearDown(revision.dispose);
      var complete = false;
      var turnCount = 4;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: UserMessageHistoryLoaderSheet(
              loadMessages: () async => List.generate(
                turnCount,
                (index) => UserChatEntry(
                  '第 $index 轮',
                  messageUuid: 'turn-$index',
                  status: MessageStatus.sent,
                ),
              ),
              isUserMessageIndexComplete: () => complete,
              refreshListenable: revision,
              onScrollToMessage: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('partial_history_banner')), findsOne);
      expect(find.text('4 轮'), findsOne);
      expect(find.textContaining('轻量用户消息索引仍在同步'), findsOne);
      expect(
        find.byKey(const ValueKey('download_full_history_button')),
        findsNothing,
      );

      complete = true;
      turnCount = 8;
      revision.value += 1;
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('partial_history_banner')),
        findsNothing,
      );
      expect(find.text('8 轮'), findsOne);
      expect(find.text('第 7 轮'), findsOne);
    },
  );

  testWidgets(
    'partial index keeps visible entries clickable and only offers index retry',
    (tester) async {
      UserChatEntry? selected;
      var retryCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: UserMessageHistorySheet(
              messages: [
                UserChatEntry(
                  '仍可定位的旧消息',
                  messageUuid: 'partial-turn',
                  status: MessageStatus.sent,
                ),
              ],
              userMessageIndexComplete: false,
              onRetryUserMessageIndex: () => retryCount += 1,
              onScrollToMessage: (message) async {
                selected = message;
                return false;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('partial_history_banner')), findsOne);
      expect(
        find.byKey(const ValueKey('download_full_history_button')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('retry_user_message_index_button')),
        findsOne,
      );

      await tester.tap(find.text('仍可定位的旧消息'));
      await tester.pumpAndSettle();
      expect(selected?.text, '仍可定位的旧消息');

      await tester.tap(
        find.byKey(const ValueKey('retry_user_message_index_button')),
      );
      expect(retryCount, 1);
    },
  );

  testWidgets('shows message dates through seconds with a year when needed', (
    tester,
  ) async {
    final now = DateTime.now();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: UserMessageHistorySheet(
            messages: [
              UserChatEntry(
                '同年消息',
                timestamp: DateTime(now.year, 1, 2, 3, 4, 5),
              ),
              UserChatEntry(
                '跨年消息',
                timestamp: DateTime(now.year - 1, 12, 31, 23, 59, 58),
              ),
            ],
            onScrollToMessage: (_) async => true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('01-02 03:04:05'), findsOne);
    expect(find.text('${now.year - 1}-12-31 23:59:58'), findsOne);
    expect(find.text('03:04'), findsNothing);
  });

  testWidgets(
    'keeps the turn picker open with a loading barrier while paging to history',
    (tester) async {
      final reveal = Completer<bool>();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: UserMessageHistorySheet(
              messages: [
                UserChatEntry(
                  '很早以前的一轮',
                  messageUuid: 'old-turn',
                  status: MessageStatus.sent,
                ),
              ],
              onScrollToMessage: (_) => reveal.future,
            ),
          ),
        ),
      );

      await tester.tap(find.text('很早以前的一轮'));
      await tester.pump();

      expect(find.byKey(const ValueKey('history_target_loading')), findsOne);
      expect(find.text('正在加载并定位这轮会话…'), findsOne);

      reveal.complete(false);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('history_target_loading')),
        findsNothing,
      );
      expect(find.text('未能加载这轮会话，请重试'), findsOne);
      expect(find.text('很早以前的一轮'), findsOne);
    },
  );
}
