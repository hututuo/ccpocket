import 'package:ccpocket/features/chat_session/widgets/status_indicator.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('localizes active and unknown process status tooltips', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const StatusIndicator(status: ProcessStatus.running)),
    );

    expect(find.byTooltip('运行中 (0s)'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(const StatusIndicator(status: ProcessStatus.unknown)),
    );
    await tester.pump();

    expect(find.byTooltip('状态暂不可用'), findsOneWidget);
    expect(find.text('Status unavailable'), findsNothing);
  });
}

Widget _wrap(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: AppTheme.darkTheme,
  home: Scaffold(body: child),
);
