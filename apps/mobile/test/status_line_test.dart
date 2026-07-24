import 'package:ccpocket/features/chat_session/widgets/status_line.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(ProcessStatus status, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: AppTheme.darkTheme,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: StatusLine(status: status),
        ),
      ),
    ),
  );
}

BoxDecoration _decoration(WidgetTester tester) {
  final surface = tester.widget<Container>(
    find.byKey(const ValueKey('session_status_line_surface')),
  );
  return surface.decoration! as BoxDecoration;
}

void main() {
  testWidgets('only a running task uses the blue status color', (tester) async {
    await tester.pumpWidget(
      _wrap(ProcessStatus.running, disableAnimations: true),
    );
    expect(
      _decoration(tester).color,
      AppColors.dark().statusRunning.withValues(alpha: 0.9),
    );

    await tester.pumpWidget(
      _wrap(ProcessStatus.waitingApproval, disableAnimations: true),
    );
    expect(
      _decoration(tester).color,
      AppColors.dark().statusIdle.withValues(alpha: 0.4),
    );

    await tester.pumpWidget(
      _wrap(ProcessStatus.compacting, disableAnimations: true),
    );
    expect(
      _decoration(tester).color,
      AppColors.dark().statusIdle.withValues(alpha: 0.4),
    );
  });

  testWidgets('status animation stops when the task stops running', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(ProcessStatus.running));
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);

    await tester.pumpWidget(_wrap(ProcessStatus.idle));
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('reduced motion keeps running status static', (tester) async {
    await tester.pumpWidget(
      _wrap(ProcessStatus.running, disableAnimations: true),
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });
}
