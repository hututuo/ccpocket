import 'dart:async';

import 'package:ccpocket/features/claude_session/widgets/rewind_message_list_sheet.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
              isComplete: () => complete,
              refreshListenable: revision,
              onScrollToMessage: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('partial_history_banner')), findsOne);
      expect(find.text('4 轮'), findsOne);
      expect(find.textContaining('完整历史索引尚未就绪'), findsOne);

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
    'offers a full-history download instead of presenting a partial list as complete',
    (tester) async {
      var complete = false;
      var requestCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: UserMessageHistoryLoaderSheet(
              loadMessages: () async => List.generate(
                complete ? 6 : 4,
                (index) => UserChatEntry(
                  '下载轮次 $index',
                  messageUuid: 'download-turn-$index',
                  status: MessageStatus.sent,
                ),
              ),
              isComplete: () => complete,
              onRequestFullHistory: () async {
                requestCount += 1;
                complete = true;
              },
              onScrollToMessage: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('download_full_history_button')),
      );
      await tester.pumpAndSettle();

      expect(requestCount, 1);
      expect(find.text('6 轮'), findsOne);
      expect(
        find.byKey(const ValueKey('partial_history_banner')),
        findsNothing,
      );
    },
  );

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
