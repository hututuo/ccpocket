import 'package:ccpocket/features/session_list/widgets/session_list_app_bar.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: CustomScrollView(slivers: [child]),
  );
}

void main() {
  testWidgets('shows app title without supporter badge', (tester) async {
    await tester.pumpWidget(
      _wrap(SessionListSliverAppBar(onTitleTap: () {}, onDisconnect: () {})),
    );

    final l = AppLocalizations.of(
      tester.element(find.byType(SessionListSliverAppBar)),
    );
    expect(find.text(l.appTitle), findsOneWidget);
    expect(find.text(l.supporterTitle), findsNothing);
  });

  testWidgets('session list toolbar exposes an explicit refresh action', (
    tester,
  ) async {
    var refreshes = 0;
    await tester.pumpWidget(
      _wrap(
        SessionListSliverAppBar(
          onTitleTap: () {},
          onDisconnect: () {},
          onRefresh: () async {
            refreshes++;
          },
        ),
      ),
    );

    final refresh = find.byKey(const ValueKey('refresh_sessions_button'));
    expect(refresh, findsOneWidget);
    await tester.tap(refresh);
    await tester.pump();
    expect(refreshes, 1);
  });

  testWidgets('session list toolbar shows bounded refresh progress', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        SessionListSliverAppBar(
          onTitleTap: () {},
          onDisconnect: () {},
          onRefresh: () async {},
          isRefreshing: true,
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('refresh_sessions_button')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('workspace session pane exposes the same refresh action', (
    tester,
  ) async {
    var refreshes = 0;
    await tester.pumpWidget(
      _wrap(
        SliverToBoxAdapter(
          child: SessionListPaneHeader(
            onTitleTap: () {},
            onOpenSettings: () {},
            onRefresh: () async {
              refreshes++;
            },
          ),
        ),
      ),
    );

    final refresh = find.byKey(const ValueKey('refresh_sessions_button'));
    expect(refresh, findsOneWidget);
    await tester.tap(refresh);
    await tester.pump();
    expect(refreshes, 1);
  });
}
