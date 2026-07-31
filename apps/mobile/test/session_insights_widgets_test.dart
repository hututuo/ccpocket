import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/session_insights/state/session_insights_controller.dart';
import 'package:ccpocket/features/session_insights/widgets/session_insights_bar.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  final tagged =
      StreamController<(LocalFeatureServerMessage, String?)>.broadcast();
  final sent = <ClientMessage>[];
  List<SessionUsageInfo> quotaProviders = const [];
  bool connected = true;
  String? stableBridgeInstanceId = 'bridge-1';
  String? stableCodexSourceId = 'source-1';

  @override
  bool get isConnected => connected;

  @override
  String? get bridgeInstanceId => stableBridgeInstanceId;

  @override
  String? get codexSourceId => stableCodexSourceId;

  @override
  bool get hasAuthoritativeSessionListForCurrentConnection => connected;

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
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
    var compactRequests = 0;
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
            onCompact: () => compactRequests += 1,
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
    expect(find.text('Compact context'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session_insights_compact')));
    await tester.pumpAndSettle();
    expect(compactRequests, 1);
    expect(find.text('Session insights'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('session_insights_bar')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      bridge.sent
          .where((message) => message.type == 'get_session_usage')
          .length,
      3,
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

  testWidgets(
    'successful insights remain visible across same-thread widget replacement',
    (tester) async {
      final bridge = _Bridge();
      addTearDown(bridge.dispose);

      await tester.pumpWidget(_app(const SizedBox(key: ValueKey('host'))));
      await tester.pumpWidget(
        _app(
          SessionInsightsBar(
            key: const ValueKey('durable-insights'),
            sessionId: 'durable-thread',
            bridgeService: bridge,
          ),
        ),
      );
      bridge.emit(
        SessionUsageResultMessage(
          sessionId: 'durable-thread',
          requestId: _latestUsageRequestId(bridge),
          providers: const [
            SessionUsageInfo(
              provider: 'codex',
              fiveHour: SessionUsageWindow(utilization: 39),
            ),
          ],
        ),
        'durable-thread',
      );
      bridge.emit(
        const ContextUsageResultMessage(
          sessionId: 'durable-thread',
          usage: ContextUsage(
            sessionId: 'durable-thread',
            last: ContextTokenUsage(totalTokens: 57),
            total: ContextTokenUsage(totalTokens: 57),
            modelContextWindow: 100,
          ),
        ),
        'durable-thread',
      );
      await tester.pump();
      expect(find.textContaining('57%'), findsOneWidget);

      await tester.pumpWidget(_app(const SizedBox.shrink()));
      await tester.pumpWidget(
        _app(
          SessionInsightsBar(
            key: const ValueKey('durable-insights'),
            sessionId: 'durable-thread',
            bridgeService: bridge,
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('57%'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('session_insights_bar')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'details pane rebuilds its owned controller when session identity changes',
    (tester) async {
      final bridge = _Bridge();
      addTearDown(bridge.dispose);

      await tester.pumpWidget(
        _app(
          SessionInsightsPanel(
            key: const ValueKey('insights-pane'),
            sessionId: 'durable-one',
            runtimeSessionId: 'runtime-one',
            bridgeService: bridge,
            requestTimeout: const Duration(seconds: 1),
          ),
        ),
      );
      expect(
        bridge.sent
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .where((message) => message['sessionId'] == 'runtime-one'),
        hasLength(2),
      );

      await tester.pumpWidget(
        _app(
          SessionInsightsPanel(
            key: const ValueKey('insights-pane'),
            sessionId: 'durable-two',
            runtimeSessionId: 'runtime-two',
            bridgeService: bridge,
            requestTimeout: const Duration(seconds: 2),
          ),
        ),
      );
      expect(
        bridge.sent
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .where((message) => message['sessionId'] == 'runtime-two'),
        hasLength(2),
      );

      await tester.pumpWidget(
        _app(
          SessionInsightsPanel(
            key: const ValueKey('insights-pane'),
            sessionId: 'durable-two',
            runtimeSessionId: 'runtime-two',
            bridgeService: bridge,
            requestTimeout: const Duration(seconds: 3),
          ),
        ),
      );
      expect(
        bridge.sent
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .where((message) => message['sessionId'] == 'runtime-two'),
        hasLength(3),
      );
      expect(
        bridge.sent
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .where(
              (message) =>
                  message['sessionId'] == 'runtime-two' &&
                  message['type'] == 'get_session_usage',
            ),
        hasLength(2),
      );
    },
  );

  testWidgets('compact context ring fits the session mode toolbar', (
    tester,
  ) async {
    final bridge = _Bridge()
      ..quotaProviders = const [
        SessionUsageInfo(
          provider: 'codex',
          fiveHour: SessionUsageWindow(
            utilization: 25,
            windowDurationMins: 300,
          ),
          sevenDay: SessionUsageWindow(
            utilization: 61,
            windowDurationMins: 10080,
          ),
        ),
      ];
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _app(
        Center(
          child: SessionInsightsBar(
            sessionId: 's1',
            bridgeService: bridge,
            compact: true,
            showLeadingDivider: true,
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
          last: ContextTokenUsage(totalTokens: 53),
          total: ContextTokenUsage(totalTokens: 53),
          modelContextWindow: 100,
        ),
      ),
      's1',
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('session_insights_mode_chip')),
      findsOneWidget,
    );
    expect(find.text('53%'), findsOneWidget);
    expect(find.textContaining('53% ·'), findsNothing);
    expect(find.byType(VerticalDivider), findsOneWidget);
    expect(
      find.byKey(const ValueKey('session_insights_context_ring')),
      findsOneWidget,
    );
    final fiveHourRing = find.byKey(
      const ValueKey('session_insights_five_hour_ring'),
    );
    final sevenDayRing = find.byKey(
      const ValueKey('session_insights_seven_day_ring'),
    );
    expect(fiveHourRing, findsOneWidget);
    expect(sevenDayRing, findsOneWidget);
    expect(
      find.descendant(of: fiveHourRing, matching: find.text('5h')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sevenDayRing, matching: find.text('7d')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.descendant(
              of: fiveHourRing,
              matching: find.byType(CircularProgressIndicator),
            ),
          )
          .value,
      0.25,
    );
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.descendant(
              of: sevenDayRing,
              matching: find.byType(CircularProgressIndicator),
            ),
          )
          .value,
      0.61,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact quota rings follow the selected Codex model', (
    tester,
  ) async {
    final bridge = _Bridge()
      ..quotaProviders = const [
        SessionUsageInfo(
          provider: 'codex',
          limitCards: [
            SessionUsageLimitCard(
              id: 'codex',
              fiveHour: SessionUsageWindow(utilization: 12),
              sevenDay: SessionUsageWindow(utilization: 24),
            ),
            SessionUsageLimitCard(
              id: 'gpt-5.3-codex-spark',
              fiveHour: SessionUsageWindow(utilization: 73),
              sevenDay: SessionUsageWindow(utilization: 88),
            ),
          ],
        ),
      ];
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _app(
        Center(
          child: SessionInsightsBar(
            sessionId: 's1',
            bridgeService: bridge,
            selectedModel: 'gpt-5.3-codex-spark',
            compact: true,
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
    await tester.pump();

    final fiveHourRing = find.byKey(
      const ValueKey('session_insights_five_hour_ring'),
    );
    final sevenDayRing = find.byKey(
      const ValueKey('session_insights_seven_day_ring'),
    );
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.descendant(
              of: fiveHourRing,
              matching: find.byType(CircularProgressIndicator),
            ),
          )
          .value,
      0.73,
    );
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.descendant(
              of: sevenDayRing,
              matching: find.byType(CircularProgressIndicator),
            ),
          )
          .value,
      0.88,
    );
  });

  testWidgets('compact quota rings stay mounted through a failed refresh', (
    tester,
  ) async {
    final bridge = _Bridge();
    addTearDown(bridge.dispose);
    final controller = SessionInsightsController(
      sessionId: 'refresh-thread',
      bridge: bridge,
    );

    await tester.pumpWidget(
      _app(
        Center(
          child: SessionInsightsBar(
            sessionId: 'refresh-thread',
            bridgeService: bridge,
            controller: controller,
            compact: true,
          ),
        ),
      ),
    );
    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'refresh-thread',
        requestId: _latestUsageRequestId(bridge),
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(utilization: 25),
            sevenDay: SessionUsageWindow(utilization: 61),
          ),
        ],
      ),
      'refresh-thread',
    );
    await tester.pump();

    controller.refresh(force: true);
    await tester.pump();
    expect(controller.quotaLoading, isTrue);
    final fiveHourRing = find.byKey(
      const ValueKey('session_insights_five_hour_ring'),
    );
    final sevenDayRing = find.byKey(
      const ValueKey('session_insights_seven_day_ring'),
    );
    expect(fiveHourRing, findsOneWidget);
    expect(sevenDayRing, findsOneWidget);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.descendant(
              of: fiveHourRing,
              matching: find.byType(CircularProgressIndicator),
            ),
          )
          .value,
      0.25,
    );

    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'refresh-thread',
        requestId: controller.debugPendingQuotaRequestId!,
        providers: const [
          SessionUsageInfo(provider: 'codex', error: 'temporary failure'),
        ],
      ),
      'refresh-thread',
    );
    await tester.pump();

    expect(controller.quotaLoading, isFalse);
    expect(fiveHourRing, findsOneWidget);
    expect(sevenDayRing, findsOneWidget);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.descendant(
              of: sevenDayRing,
              matching: find.byType(CircularProgressIndicator),
            ),
          )
          .value,
      0.61,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('compact quota rings omit windows the Bridge does not report', (
    tester,
  ) async {
    final bridge = _Bridge()
      ..quotaProviders = const [
        SessionUsageInfo(
          provider: 'codex',
          sevenDay: SessionUsageWindow(
            utilization: 42,
            windowDurationMins: 10080,
          ),
        ),
      ];
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _app(
        Center(
          child: SessionInsightsBar(
            sessionId: 's1',
            bridgeService: bridge,
            compact: true,
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
    await tester.pump();

    expect(
      find.byKey(const ValueKey('session_insights_five_hour_ring')),
      findsNothing,
    );
    final sevenDayRing = find.byKey(
      const ValueKey('session_insights_seven_day_ring'),
    );
    expect(sevenDayRing, findsOneWidget);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.descendant(
              of: sevenDayRing,
              matching: find.byType(CircularProgressIndicator),
            ),
          )
          .value,
      0.42,
    );

    await tester.tap(find.byKey(const ValueKey('session_insights_mode_chip')));
    await tester.pumpAndSettle();
    expect(find.text('5h'), findsNothing);
    expect(find.text('7d'), findsWidgets);
    expect(find.text('42%'), findsOneWidget);
  });

  testWidgets('empty compact insight slot hides its leading divider', (
    tester,
  ) async {
    final bridge = _Bridge()..connected = false;
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _app(
        SessionInsightsBar(
          sessionId: 's1',
          bridgeService: bridge,
          compact: true,
          showLeadingDivider: true,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('session_insights_mode_chip')),
      findsNothing,
    );
    expect(find.byType(VerticalDivider), findsNothing);
  });
}
