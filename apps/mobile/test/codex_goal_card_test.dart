import 'package:ccpocket/features/codex_session/widgets/codex_goal_card.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/mock/mock_scenarios.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const activeGoal = CodexGoalCardData(objective: 'Goal機能をCC Pocketに追加する');

  Widget buildSubject({
    CodexGoalCardData goal = activeGoal,
    VoidCallback? onEdit,
    VoidCallback? onTogglePaused,
    VoidCallback? onResolveBudget,
    VoidCallback? onClear,
    bool busy = false,
    String? busyLabel,
    bool controlsEnabled = true,
    Locale locale = const Locale('en'),
  }) {
    return MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF97316),
          brightness: Brightness.dark,
        ),
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: CodexGoalCard(
            goal: goal,
            busy: busy,
            busyLabel: busyLabel,
            controlsEnabled: controlsEnabled,
            onEdit: onEdit ?? () {},
            onTogglePaused: onTogglePaused ?? () {},
            onResolveBudget: onResolveBudget,
            onClear: onClear ?? () {},
          ),
        ),
      ),
    );
  }

  group('CodexGoalCard', () {
    testWidgets('shows a compact two-row active goal', (tester) async {
      await tester.pumpWidget(buildSubject());

      expect(find.byKey(const ValueKey('goal_card')), findsOneWidget);
      expect(find.text('Goal'), findsOneWidget);
      expect(find.text('Pursuing'), findsOneWidget);
      expect(find.text(activeGoal.objective), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      for (final key in [
        'goal_edit_button',
        'goal_pause_button',
        'goal_clear_button',
      ]) {
        expect(tester.getSize(find.byKey(ValueKey(key))), const Size(44, 44));
      }
    });

    testWidgets('dispatches edit, pause, and clear actions', (tester) async {
      var edited = false;
      var paused = false;
      var cleared = false;
      await tester.pumpWidget(
        buildSubject(
          onEdit: () => edited = true,
          onTogglePaused: () => paused = true,
          onClear: () => cleared = true,
        ),
      );

      await tester.tap(find.byKey(const ValueKey('goal_edit_button')));
      await tester.tap(find.byKey(const ValueKey('goal_pause_button')));
      await tester.tap(find.byKey(const ValueKey('goal_clear_button')));

      expect(edited, isTrue);
      expect(paused, isTrue);
      expect(cleared, isTrue);
    });

    testWidgets('shows paused status and resume affordance', (tester) async {
      await tester.pumpWidget(
        buildSubject(
          goal: const CodexGoalCardData(
            objective: 'Resume this goal',
            status: CodexGoalStatus.paused,
          ),
        ),
      );

      expect(find.text('Paused'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('disables pause for a completed goal', (tester) async {
      var toggled = false;
      await tester.pumpWidget(
        buildSubject(
          goal: const CodexGoalCardData(
            objective: 'Completed goal',
            status: CodexGoalStatus.complete,
          ),
          onTogglePaused: () => toggled = true,
        ),
      );

      final button = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(const ValueKey('goal_pause_button')),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('goal_pause_button')));
      expect(toggled, isFalse);
    });

    testWidgets('does not overflow on a narrow phone', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildSubject());

      expect(tester.takeException(), isNull);
    });

    testWidgets('shows localized status, usage, and budget progress', (
      tester,
    ) async {
      var budgetActions = 0;
      await tester.pumpWidget(
        buildSubject(
          goal: const CodexGoalCardData(
            objective: '完成跨端 Goal 管理',
            status: CodexGoalStatus.budgetLimited,
            tokensUsed: 12400,
            tokenBudget: 80000,
            timeUsedSeconds: 1080,
          ),
          onResolveBudget: () => budgetActions += 1,
          locale: const Locale('zh'),
        ),
      );

      expect(find.text('目标'), findsOneWidget);
      expect(find.text('预算耗尽'), findsOneWidget);
      expect(find.text('完成跨端 Goal 管理'), findsOneWidget);
      expect(find.text('12.4k / 80k 个 Token'), findsOneWidget);
      expect(find.text('18m'), findsOneWidget);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('goal_budget_progress')),
      );
      expect(progress.value, closeTo(0.155, 0.0001));

      await tester.tap(find.byKey(const ValueKey('goal_pause_button')));
      expect(budgetActions, 1);
    });

    testWidgets('pending mutation disables every destructive action', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildSubject(busy: true, busyLabel: 'Saving Goal…'),
      );

      expect(find.text('Saving Goal…'), findsOneWidget);
      for (final key in const [
        ValueKey('goal_edit_button'),
        ValueKey('goal_pause_button'),
        ValueKey('goal_clear_button'),
      ]) {
        final button = find.descendant(
          of: find.byKey(key),
          matching: find.byType(IconButton),
        );
        expect(tester.widget<IconButton>(button).onPressed, isNull);
      }
    });

    testWidgets('stale Goal stays visible but controls require reconnect', (
      tester,
    ) async {
      var edits = 0;
      await tester.pumpWidget(
        buildSubject(
          controlsEnabled: false,
          onEdit: () => edits += 1,
          locale: const Locale('zh'),
        ),
      );

      expect(find.text(activeGoal.objective), findsOneWidget);
      expect(
        find.byKey(const ValueKey('goal_controls_disabled')),
        findsOneWidget,
      );
      expect(find.text('重新连接并刷新后才能管理这个目标。'), findsOneWidget);
      final editButton = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(const ValueKey('goal_edit_button')),
          matching: find.byType(IconButton),
        ),
      );
      expect(editButton.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('goal_edit_button')));
      expect(edits, 0);
    });

    testWidgets('unknown future state preserves raw status and is read-only', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildSubject(
          goal: const CodexGoalCardData(
            objective: 'Future state',
            status: CodexGoalStatus.unknown,
            rawStatus: 'waitingForFutureResource',
          ),
        ),
      );

      expect(find.text('Unknown · waitingForFutureResource'), findsOneWidget);
      for (final key in const [
        ValueKey('goal_edit_button'),
        ValueKey('goal_pause_button'),
        ValueKey('goal_clear_button'),
      ]) {
        expect(
          tester
              .widget<IconButton>(
                find.descendant(
                  of: find.byKey(key),
                  matching: find.byType(IconButton),
                ),
              )
              .onPressed,
          isNull,
        );
      }
    });
  });

  test('Codex Goal is available from the mock preview catalog', () {
    expect(mockScenarios, contains(codexGoalPreviewScenario));
    expect(codexGoalPreviewScenario.provider, MockScenarioProvider.codex);
    expect(codexGoalPreviewScenario.name, 'Codex Goal');
  });
}
