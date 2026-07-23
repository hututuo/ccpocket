import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/guardian_approval_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a compact notice and expands approval details', (
    tester,
  ) async {
    const reason =
        'Launching the app writes build files outside the workspace.';
    await tester.pumpWidget(
      _wrap(
        const GuardianApprovalMessage(
          risk: GuardianApprovalRisk.medium,
          reason: reason,
          authorization: 'medium',
        ),
      ),
    );

    expect(find.text('Auto Review approved'), findsOneWidget);
    expect(find.text('· Medium risk'), findsOneWidget);
    expect(find.text(reason), findsNothing);
    expect(find.byIcon(Icons.warning_amber), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('guardian_approval_compact_content')),
          )
          .height,
      lessThan(36),
    );

    await tester.tap(
      find.byKey(const ValueKey('guardian_approval_details_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text(reason), findsOneWidget);
    expect(find.text('Authorization: Medium'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows localized risk, labels, and the exact reviewed command', (
    tester,
  ) async {
    const command = 'ls -la /tmp/simulator.db*';
    await tester.pumpWidget(
      _wrap(
        const GuardianApprovalMessage(
          risk: GuardianApprovalRisk.low,
          reason: 'The command only reads simulator database metadata.',
          authorization: 'high',
          action: {'type': 'command', 'command': command, 'cwd': '/tmp'},
        ),
        locale: const Locale('zh'),
      ),
    );

    expect(find.text('自动审查已批准'), findsOneWidget);
    expect(find.text('· 低风险'), findsOneWidget);
    expect(find.text(command), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('guardian_approval_details_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('审批理由'), findsOneWidget);
    expect(find.text('具体指令'), findsOneWidget);
    expect(find.text(command), findsOneWidget);
    expect(find.text('工作目录：/tmp'), findsOneWidget);
    expect(find.text('授权级别：高'), findsOneWidget);
  });

  testWidgets('localizes a denied critical-risk review', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const GuardianApprovalMessage(
          risk: GuardianApprovalRisk.critical,
          status: GuardianApprovalStatus.denied,
          reason: 'Would export private source files.',
        ),
        locale: const Locale('zh'),
      ),
    );

    expect(find.text('自动审查未批准'), findsOneWidget);
    expect(find.text('· 严重风险'), findsOneWidget);
  });

  testWidgets('localizes the high-risk label', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const GuardianApprovalMessage(
          risk: GuardianApprovalRisk.high,
          reason: 'ワークスペース外のファイルを変更します。',
        ),
        locale: const Locale('ja'),
      ),
    );

    expect(find.text('自動レビューで承認'), findsOneWidget);
    expect(find.text('· 高リスク'), findsOneWidget);
  });
}

Widget _wrap(GuardianApprovalMessage message, {Locale? locale}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: AppTheme.darkTheme,
    home: Scaffold(body: GuardianApprovalNotice(message: message)),
  );
}
