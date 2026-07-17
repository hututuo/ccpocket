import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/session_insights/state/session_insights_controller.dart';
import 'package:ccpocket/features/session_insights/widgets/session_insights_bar.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final tagged =
      StreamController<(LocalFeatureServerMessage, String?)>.broadcast();
  final sent = <ClientMessage>[];
  List<SessionUsageInfo> quotaProviders = const [];

  @override
  bool get isConnected => true;

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => tagged.stream
      .where((pair) => pair.$2 == sessionId)
      .map((pair) => pair.$1);

  @override
  void send(ClientMessage message) => sent.add(message);

  void emit(LocalFeatureServerMessage message, String sessionId) =>
      tagged.add((message, sessionId));

  @override
  void dispose() {
    tagged.close();
    super.dispose();
  }
}

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(body: SizedBox(width: 430, height: 760, child: child)),
);

String _latestUsageRequestId(_Bridge bridge) {
  final request = bridge.sent.lastWhere(
    (message) => message.type == 'get_session_usage',
  );
  return (jsonDecode(request.toJson()) as Map<String, dynamic>)['requestId']
      as String;
}

void main() {
  test('reset credits sort available first and then by expiry', () {
    const credits = [
      SessionUsageResetCredit(
        id: 'used',
        status: 'redeemed',
        expiresAt: '2028-01-01T00:00:00Z',
      ),
      SessionUsageResetCredit(
        id: 'later',
        status: 'available',
        expiresAt: '2030-01-01T00:00:00Z',
      ),
      SessionUsageResetCredit(
        id: 'earlier',
        status: 'available',
        expiresAt: '2029-01-01T00:00:00Z',
      ),
    ];

    expect(sortResetCreditsForDisplay(credits).map((credit) => credit.id), [
      'earlier',
      'later',
      'used',
    ]);
  });

  testWidgets('context bar opens quota cards and reset-credit details', (
    tester,
  ) async {
    final bridge = _Bridge()
      ..quotaProviders = const [
        SessionUsageInfo(
          provider: 'codex',
          source: 'account_api',
          limitCards: [
            SessionUsageLimitCard(
              id: 'pro',
              limitName: 'Pro',
              fiveHour: SessionUsageWindow(
                utilization: 25,
                resetsAt: '2030-01-01T00:00:00Z',
              ),
            ),
          ],
          resetCredits: SessionUsageResetCredits(
            availableCount: 1,
            credits: [
              SessionUsageResetCredit(
                id: 'credit-1',
                status: 'available',
                title: 'Free reset',
                expiresAt: '2030-02-01T00:00:00Z',
              ),
            ],
          ),
        ),
      ];
    addTearDown(bridge.dispose);
    final controller = SessionInsightsController(
      sessionId: 's1',
      bridge: bridge,
    );

    await tester.pumpWidget(
      _app(
        Center(
          child: SessionInsightsBar(
            sessionId: 's1',
            bridgeService: bridge,
            controller: controller,
          ),
        ),
      ),
    );
    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 's1',
        requestId: _latestUsageRequestId(bridge),
        providers: bridge.quotaProviders,
      ),
      's1',
    );
    bridge.emit(
      const ContextUsageMessage(
        usage: ContextUsage(
          sessionId: 's1',
          last: ContextTokenUsage(totalTokens: 80),
          total: ContextTokenUsage(totalTokens: 120),
          modelContextWindow: 100,
        ),
      ),
      's1',
    );
    await tester.pump();
    expect(find.textContaining('80%'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session_insights_bar')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Session insights'), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('Free reset'), findsOneWidget);
    expect(
      bridge.sent
          .where((message) => message.type == 'get_session_usage')
          .length,
      2,
    );

    bridge.emit(
      const ContextUsageMessage(
        usage: ContextUsage(
          sessionId: 's1',
          last: ContextTokenUsage(totalTokens: 90),
          total: ContextTokenUsage(totalTokens: 140),
          modelContextWindow: 100,
        ),
      ),
      's1',
    );
    final liveUsageRequestId = controller.debugPendingQuotaRequestId;
    expect(liveUsageRequestId, _latestUsageRequestId(bridge));
    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 's1',
        requestId: liveUsageRequestId!,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            limitCards: [
              SessionUsageLimitCard(
                id: 'pro',
                limitName: 'Pro',
                fiveHour: SessionUsageWindow(
                  utilization: 41,
                  windowDurationMins: 15,
                ),
              ),
            ],
          ),
        ],
      ),
      's1',
    );
    await tester.pumpAndSettle();
    expect(controller.codexUsage?.limitCards.single.fiveHour?.utilization, 41);
    expect(
      controller.codexUsage?.limitCards.single.fiveHour?.windowDurationMins,
      15,
    );
    expect(find.text('90%'), findsOneWidget);
    expect(find.text('15m'), findsOneWidget);
    expect(find.text('41%'), findsOneWidget);
    expect(find.textContaining('Resets in'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('quota-only snapshot keeps the insights entry visible', (
    tester,
  ) async {
    final bridge = _Bridge()
      ..quotaProviders = const [
        SessionUsageInfo(
          provider: 'codex',
          fiveHour: SessionUsageWindow(
            utilization: 33,
            windowDurationMins: 300,
          ),
        ),
      ];
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _app(SessionInsightsBar(sessionId: 's1', bridgeService: bridge)),
    );

    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 's1',
        requestId: _latestUsageRequestId(bridge),
        providers: bridge.quotaProviders,
      ),
      's1',
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('session_insights_bar')), findsOneWidget);
    expect(find.textContaining('5h'), findsOneWidget);
    expect(find.textContaining('33%'), findsOneWidget);
  });
}
