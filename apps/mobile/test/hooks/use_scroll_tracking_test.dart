import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/hooks/use_scroll_tracking.dart';
import 'package:ccpocket/l10n/app_localizations.dart';

void main() {
  group('useScrollTracking', () {
    testWidgets('returns a ScrollController and initial state', (tester) async {
      late ScrollTrackingResult result;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: HookBuilder(
            builder: (context) {
              result = useScrollTracking('session-1');
              // Use reverse: true — offset 0 = bottom of chat
              return ListView.builder(
                controller: result.controller,
                reverse: true,
                itemCount: 100,
                itemBuilder: (_, i) => SizedBox(height: 50, child: Text('$i')),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(result.controller, isA<ScrollController>());
      // Initially at offset 0 with reverse list → at bottom → not scrolled up
    });

    testWidgets('isScrolledUp becomes false when at bottom', (tester) async {
      late ScrollTrackingResult result;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: HookBuilder(
            builder: (context) {
              result = useScrollTracking('session-2');
              // Use reverse: true — offset 0 = bottom of chat
              return ListView.builder(
                controller: result.controller,
                reverse: true,
                itemCount: 200,
                itemBuilder: (_, i) => SizedBox(height: 50, child: Text('$i')),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // With reverse list, offset 0 = bottom → isScrolledUp should be false
      expect(result.isScrolledUp, isFalse);
    });

    testWidgets('isScrolledUp false when near bottom', (tester) async {
      late ScrollTrackingResult result;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: HookBuilder(
            builder: (context) {
              result = useScrollTracking('session-4');
              // Use reverse: true — offset 0 = bottom of chat
              return ListView.builder(
                controller: result.controller,
                reverse: true,
                itemCount: 200,
                itemBuilder: (_, i) => SizedBox(height: 50, child: Text('$i')),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Near bottom (within 100px threshold) → not scrolledUp
      // With reverse list, offset 50 is near bottom (offset 0)
      result.controller.jumpTo(50);
      await tester.pumpAndSettle();
      expect(result.isScrolledUp, isFalse);
    });

    testWidgets('can ignore a raw offset saved by an older content revision', (
      tester,
    ) async {
      late ScrollTrackingResult result;

      Widget build({required bool persistRawOffset}) => MaterialApp(
        home: HookBuilder(
          builder: (context) {
            result = useScrollTracking(
              'durable-revision-sensitive-session',
              persistRawOffset: persistRawOffset,
            );
            return ListView.builder(
              controller: result.controller,
              reverse: true,
              itemCount: 100,
              itemBuilder: (_, i) => SizedBox(height: 50, child: Text('$i')),
            );
          },
        ),
      );

      await tester.pumpWidget(build(persistRawOffset: true));
      await tester.pumpAndSettle();
      result.controller.jumpTo(300);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      await tester.pumpWidget(build(persistRawOffset: false));
      await tester.pumpAndSettle();
      expect(result.controller.offset, 0);
    });
  });
}
