import 'dart:async';

import 'package:ccpocket/features/claude_session/widgets/rewind_message_list_sheet.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
