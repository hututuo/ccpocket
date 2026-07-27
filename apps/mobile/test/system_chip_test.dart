import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/system_chip.dart';
import 'package:ccpocket/widgets/message_bubble.dart';

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    theme: AppTheme.darkTheme,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('renders codex init messages as environment summary', (
    tester,
  ) async {
    const message = SystemMessage(
      subtype: 'init',
      provider: 'codex',
      model: 'gpt-5.4',
      sandboxMode: 'workspace-write',
    );

    await tester.pumpWidget(_wrap(const SystemChip(message: message)));

    expect(find.text('Session started'), findsOneWidget);
    expect(find.text('gpt-5.4 Default'), findsOneWidget);
    expect(find.text('Sandbox'), findsOneWidget);
    expect(find.text('System: init'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('localizes the Codex session-start label', (tester) async {
    const message = SystemMessage(
      subtype: 'init',
      provider: 'codex',
      model: 'gpt-5.4',
    );

    await tester.pumpWidget(
      _wrap(const SystemChip(message: message), locale: const Locale('zh')),
    );

    expect(find.text('会话已开始'), findsOneWidget);
    expect(find.text('Session started'), findsNothing);
  });

  testWidgets(
    'renders non-session-created system messages even with model set',
    (tester) async {
      const message = SystemMessage(
        subtype: 'supported_commands',
        provider: 'codex',
        model: 'gpt-5.4',
      );

      await tester.pumpWidget(_wrap(const SystemChip(message: message)));

      expect(find.text('System: supported_commands'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('chat transcript hides runtime metadata system messages', (
    tester,
  ) async {
    const message = SystemMessage(
      subtype: 'set_codex_model',
      provider: 'codex',
      model: 'gpt-5.6-sol',
      modelReasoningEffort: 'ultra',
    );

    await tester.pumpWidget(_wrap(const ServerMessageWidget(message: message)));

    expect(find.textContaining('System:'), findsNothing);
    expect(find.byType(Chip), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
