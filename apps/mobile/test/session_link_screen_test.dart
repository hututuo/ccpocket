import 'package:ccpocket/features/session_link/session_link_screen.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    );
  }

  testWidgets('shows a friendly unavailable state with a recovery action', (
    tester,
  ) async {
    var openedRecentSessions = false;
    await tester.pumpWidget(
      wrap(
        SessionLinkStatusView(
          unavailable: true,
          resuming: false,
          onOpenRecentSessions: () => openedRecentSessions = true,
        ),
      ),
    );

    expect(find.text('Session unavailable'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('open_recent_sessions_button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('open_recent_sessions_button')));
    expect(openedRecentSessions, isTrue);
  });

  testWidgets('distinguishes resolving from resuming', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionLinkStatusView(
          unavailable: false,
          resuming: false,
          onOpenRecentSessions: () {},
        ),
      ),
    );
    expect(find.text('Finding session...'), findsOneWidget);

    await tester.pumpWidget(
      wrap(
        SessionLinkStatusView(
          unavailable: false,
          resuming: true,
          onOpenRecentSessions: () {},
        ),
      ),
    );
    expect(find.text('Resuming session...'), findsOneWidget);
  });

  testWidgets('shows a localized effective progress stage', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionLinkStatusView(
          unavailable: false,
          resuming: true,
          progress: const SessionLinkProgressMessage(
            requestId: 'link-1',
            sourceSessionId: 'thread-1',
            generation: 1,
            operation: SessionLinkProgressOperation.resume,
            stage: SessionLinkProgressStage.historyReading,
            sequence: 4,
            observedAt: '2026-07-31T00:00:00Z',
          ),
          onOpenRecentSessions: () {},
        ),
      ),
    );

    expect(find.text('Loading recent history...'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('session_link_progress_indicator')),
      findsOneWidget,
    );
  });
}
