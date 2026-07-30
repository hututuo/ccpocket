import 'package:ccpocket/features/settings/licenses_screen.dart';
import 'package:ccpocket/features/settings/widgets/theme_bottom_sheet.dart';
import 'package:ccpocket/features/claude_session/widgets/cost_badge.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/assistant_bubble.dart';
import 'package:ccpocket/widgets/codex_effort_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _localizedApp(Widget home, {Locale locale = const Locale('zh')}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    theme: AppTheme.lightTheme,
    home: home,
  );
}

void main() {
  testWidgets('theme picker exposes Chinese labels', (tester) async {
    await tester.pumpWidget(
      _localizedApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showThemeBottomSheet(
                context: context,
                current: ThemeMode.system,
                onChanged: (_) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('主题'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
  });

  testWidgets('license screen exposes Chinese title and search hint', (
    tester,
  ) async {
    await tester.pumpWidget(_localizedApp(const LicensesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('开源许可'), findsOneWidget);
    expect(find.widgetWithText(TextField, '搜索软件包…'), findsOneWidget);
  });

  testWidgets('Codex speed labels follow the active locale', (tester) async {
    await tester.pumpWidget(
      _localizedApp(
        Builder(
          builder: (context) => Column(
            children: [
              Text(codexSpeedDisplayLabel(context, CodexSpeed.standard)),
              Text(codexSpeedDisplayLabel(context, CodexSpeed.fast)),
              Text(codexSpeedDisplayLabel(context, CodexSpeed.unknown)),
            ],
          ),
        ),
      ),
    );

    expect(find.text('标准'), findsOneWidget);
    expect(find.text('快速'), findsOneWidget);
    expect(find.text('自定义'), findsOneWidget);
  });

  testWidgets('Plan toggle keeps its established English labels in Chinese', (
    tester,
  ) async {
    await tester.pumpWidget(
      _localizedApp(
        Builder(
          builder: (context) {
            final localizations = AppLocalizations.of(context);
            return Column(
              children: [
                Text(localizations.planOnShort),
                Text(localizations.planOffShort),
              ],
            );
          },
        ),
      ),
    );

    expect(find.text('Plan On'), findsOneWidget);
    expect(find.text('Plan Off'), findsOneWidget);
    expect(find.text('规划开启'), findsNothing);
    expect(find.text('规划关闭'), findsNothing);
  });

  testWidgets('session cost tooltip follows the active locale', (tester) async {
    await tester.pumpWidget(
      _localizedApp(
        const Scaffold(body: CostBadge(totalCost: 0.5, messageCount: 75)),
      ),
    );

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, '75 条消息（约占上下文 50%）');
  });

  testWidgets('older tool detail prompt uses the selected Japanese locale', (
    tester,
  ) async {
    await tester.pumpWidget(
      _localizedApp(
        const Scaffold(
          body: HistoryToolDetailGapTile(
            gap: HistoryToolDetailGap(
              gapId: 'older-tools',
              toolUseIds: ['tool-1'],
              toolNames: ['Read'],
              toolCallCount: 3,
            ),
          ),
        ),
        locale: const Locale('ja'),
      ),
    );

    expect(find.text('以前のツール詳細 3 件はまだ読み込まれていません'), findsOneWidget);
    expect(find.text('読み込む'), findsOneWidget);
  });
}
