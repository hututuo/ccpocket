import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/session_insights/state/session_insights_controller.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  final tagged =
      StreamController<(LocalFeatureServerMessage, String?)>.broadcast();
  final directory = StreamController<List<SessionInfo>>.broadcast();
  final sent = <ClientMessage>[];
  bool connected = true;
  bool authoritativeSessionList = true;
  String? stableBridgeInstanceId = 'bridge-1';
  String? stableCodexSourceId = 'source-1';
  Set<String> advertisedCapabilities = const {};

  @override
  bool get isConnected => connected;

  @override
  String? get bridgeInstanceId => stableBridgeInstanceId;

  @override
  String? get codexSourceId => stableCodexSourceId;

  @override
  Set<String> get bridgeCapabilities => advertisedCapabilities;

  @override
  bool get hasAuthoritativeSessionListForCurrentConnection =>
      connected && authoritativeSessionList;

  @override
  Stream<List<SessionInfo>> get sessionList => directory.stream;

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => tagged.stream
      .where((pair) => pair.$2 == sessionId)
      .map((pair) => pair.$1);

  @override
  void send(ClientMessage message) => sent.add(message);

  void emit(LocalFeatureServerMessage message, {String? tag}) =>
      tagged.add((message, tag));

  void emitSessionList() => directory.add(const []);

  @override
  void dispose() {
    tagged.close();
    directory.close();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'new Bridge uses durable requests and safely consumes the runtime live alias',
    () async {
      final bridge = _Bridge()
        ..advertisedCapabilities = const {durableSessionInsightsCapability};
      final controller = SessionInsightsController(
        sessionId: 'durable-thread',
        runtimeSessionId: 'runtime-session',
        bridge: bridge,
      )..start();
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      final contextRequest =
          jsonDecode(
                bridge.sent
                    .firstWhere(
                      (message) => message.type == 'get_context_usage',
                    )
                    .toJson(),
              )
              as Map<String, dynamic>;
      final quotaRequest =
          jsonDecode(
                bridge.sent
                    .firstWhere(
                      (message) => message.type == 'get_session_usage',
                    )
                    .toJson(),
              )
              as Map<String, dynamic>;
      expect(contextRequest['sessionId'], 'durable-thread');
      expect(contextRequest['requestId'], isNotEmpty);
      expect(quotaRequest['sessionId'], 'durable-thread');

      bridge.emit(
        const ContextUsageResultMessage(
          sessionId: 'durable-thread',
          requestId: 'stale-request',
          usage: ContextUsage(
            sessionId: 'durable-thread',
            last: ContextTokenUsage(totalTokens: 90),
            total: ContextTokenUsage(totalTokens: 90),
            modelContextWindow: 100,
          ),
        ),
        tag: 'durable-thread',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.contextUsage, isNull);
      expect(controller.contextLoading, isTrue);

      bridge.emit(
        const ContextUsageMessage(
          usage: ContextUsage(
            sessionId: 'runtime-session',
            turnId: 'turn-live',
            last: ContextTokenUsage(totalTokens: 40),
            total: ContextTokenUsage(totalTokens: 40),
            modelContextWindow: 100,
          ),
        ),
        tag: 'runtime-session',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.contextUsage?.last.totalTokens, 40);
      expect(controller.contextLoading, isTrue);

      bridge.emit(
        ContextUsageResultMessage(
          sessionId: 'durable-thread',
          requestId: contextRequest['requestId'] as String,
          usage: const ContextUsage(
            sessionId: 'durable-thread',
            turnId: 'turn-live',
            last: ContextTokenUsage(totalTokens: 40),
            total: ContextTokenUsage(totalTokens: 40),
            modelContextWindow: 100,
          ),
        ),
        tag: 'durable-thread',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.contextLoading, isFalse);

      var duplicateNotifications = 0;
      controller.addListener(() => duplicateNotifications++);
      bridge.emit(
        const ContextUsageMessage(
          usage: ContextUsage(
            sessionId: 'runtime-session',
            turnId: 'turn-live',
            last: ContextTokenUsage(totalTokens: 40),
            total: ContextTokenUsage(totalTokens: 40),
            modelContextWindow: 100,
          ),
        ),
        tag: 'runtime-session',
      );
      bridge.emit(
        const ContextUsageMessage(
          usage: ContextUsage(
            sessionId: 'durable-thread',
            turnId: 'turn-live',
            last: ContextTokenUsage(totalTokens: 40),
            total: ContextTokenUsage(totalTokens: 40),
            modelContextWindow: 100,
          ),
        ),
        tag: 'durable-thread',
      );
      await Future<void>.delayed(Duration.zero);
      expect(duplicateNotifications, 0);
    },
  );

  test('old Bridge falls back to the attached runtime identity', () {
    final bridge = _Bridge();
    final controller = SessionInsightsController(
      sessionId: 'durable-thread',
      runtimeSessionId: 'runtime-session',
      bridge: bridge,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    final requests = bridge.sent
        .map((message) => jsonDecode(message.toJson()) as Map<String, dynamic>)
        .toList(growable: false);
    final context = requests.singleWhere(
      (message) => message['type'] == 'get_context_usage',
    );
    final quota = requests.singleWhere(
      (message) => message['type'] == 'get_session_usage',
    );
    expect(context['sessionId'], 'runtime-session');
    expect(context.containsKey('requestId'), isFalse);
    expect(quota['sessionId'], 'runtime-session');
  });

  test('accepts context usage only for the exact session', () async {
    final bridge = _Bridge();
    final controller = SessionInsightsController(
      sessionId: 's1',
      bridge: bridge,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    expect(bridge.sent.map((message) => message.type), [
      'get_context_usage',
      'get_session_usage',
    ]);
    bridge.emit(
      const ContextUsageMessage(
        usage: ContextUsage(
          sessionId: 'wrong',
          last: ContextTokenUsage(totalTokens: 90),
          total: ContextTokenUsage(),
          modelContextWindow: 100,
        ),
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.contextUsage, isNull);

    bridge.emit(
      const ContextUsageMessage(
        usage: ContextUsage(
          sessionId: 's1',
          last: ContextTokenUsage(totalTokens: 40),
          total: ContextTokenUsage(),
          modelContextWindow: 100,
        ),
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.contextUsage?.last.totalTokens, 40);
    expect(controller.contextLoading, isFalse);
  });

  test(
    'scoped live context requires exact Bridge source and current authority',
    () async {
      var authorityGeneration = 'daemon:1:2';
      final bridge = _Bridge()
        ..advertisedCapabilities = const {scopedContextUsageCapability};
      final controller = SessionInsightsController(
        sessionId: 's1',
        bridge: bridge,
        authorityGenerationProvider: () => authorityGeneration,
      )..start();
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      bridge.emit(
        const ContextUsageMessage(
          usage: ContextUsage(
            sessionId: 's1',
            threadId: 's1',
            bridgeInstanceId: 'bridge-other',
            codexSourceId: 'source-1',
            authorityGeneration: 'daemon:1:1',
            last: ContextTokenUsage(totalTokens: 70),
            total: ContextTokenUsage(totalTokens: 70),
            modelContextWindow: 100,
          ),
        ),
        tag: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.contextUsage, isNull);

      bridge.emit(
        const ContextUsageMessage(
          usage: ContextUsage(
            sessionId: 's1',
            threadId: 's1',
            bridgeInstanceId: 'bridge-1',
            codexSourceId: 'source-1',
            authorityGeneration: 'daemon:1:1',
            last: ContextTokenUsage(totalTokens: 70),
            total: ContextTokenUsage(totalTokens: 70),
            modelContextWindow: 100,
          ),
        ),
        tag: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.contextUsage, isNull);

      bridge.emit(
        const ContextUsageMessage(
          usage: ContextUsage(
            sessionId: 's1',
            threadId: 's1',
            bridgeInstanceId: 'bridge-1',
            codexSourceId: 'source-1',
            authorityGeneration: 'daemon:1:2',
            last: ContextTokenUsage(totalTokens: 71),
            total: ContextTokenUsage(totalTokens: 71),
            modelContextWindow: 100,
          ),
        ),
        tag: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.contextUsage?.last.totalTokens, 71);

      var notifications = 0;
      controller.addListener(() => notifications += 1);
      authorityGeneration = 'daemon:1:3';
      bridge.emit(
        const ContextUsageMessage(
          usage: ContextUsage(
            sessionId: 's1',
            threadId: 's1',
            bridgeInstanceId: 'bridge-1',
            codexSourceId: 'source-1',
            authorityGeneration: 'daemon:1:3',
            last: ContextTokenUsage(totalTokens: 71),
            total: ContextTokenUsage(totalTokens: 71),
            modelContextWindow: 100,
          ),
        ),
        tag: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
      expect(controller.contextUsage?.authorityGeneration, 'daemon:1:3');
    },
  );

  test(
    'scoped capability rejects incomplete events while legacy accepts unscoped',
    () async {
      final scopedBridge = _Bridge()
        ..advertisedCapabilities = const {scopedContextUsageCapability};
      final scoped = SessionInsightsController(
        sessionId: 's1',
        bridge: scopedBridge,
        authorityGenerationProvider: () => null,
      )..start();
      addTearDown(scoped.dispose);
      addTearDown(scopedBridge.dispose);

      scopedBridge.emit(
        const ContextUsageMessage(
          usage: ContextUsage(
            sessionId: 's1',
            last: ContextTokenUsage(totalTokens: 50),
            total: ContextTokenUsage(totalTokens: 50),
            modelContextWindow: 100,
          ),
        ),
        tag: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(scoped.contextUsage, isNull);

      final legacyBridge = _Bridge();
      final legacy = SessionInsightsController(
        sessionId: 's1',
        bridge: legacyBridge,
      )..start();
      addTearDown(legacy.dispose);
      addTearDown(legacyBridge.dispose);
      legacyBridge.emit(
        const ContextUsageMessage(
          usage: ContextUsage(
            sessionId: 's1',
            last: ContextTokenUsage(totalTokens: 51),
            total: ContextTokenUsage(totalTokens: 51),
            modelContextWindow: 100,
          ),
        ),
        tag: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(legacy.contextUsage?.last.totalTokens, 51);
    },
  );

  test('keeps quota data visible without a context response', () async {
    final bridge = _Bridge();
    final controller = SessionInsightsController(
      sessionId: 's1',
      bridge: bridge,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    final request = bridge.sent.lastWhere(
      (message) => message.type == 'get_session_usage',
    );
    final requestId =
        (jsonDecode(request.toJson()) as Map<String, dynamic>)['requestId']
            as String;
    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'wrong',
        requestId: requestId,
        providers: const [SessionUsageInfo(provider: 'codex')],
      ),
      tag: 's1',
    );
    bridge.emit(
      const SessionUsageResultMessage(
        sessionId: 's1',
        requestId: 'wrong-request',
        providers: [SessionUsageInfo(provider: 'codex')],
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.codexUsage, isNull);
    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 's1',
        requestId: requestId,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(
              utilization: 27,
              windowDurationMins: 15,
            ),
          ),
        ],
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.contextUsage, isNull);
    expect(controller.codexUsage?.fiveHour?.windowDurationMins, 15);
    expect(controller.hasVisibleData, isTrue);
  });

  test('typed explicit context result and error are session scoped', () async {
    final bridge = _Bridge();
    final controller = SessionInsightsController(
      sessionId: 's1',
      bridge: bridge,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    bridge.emit(
      const ContextUsageResultMessage(
        sessionId: 'wrong',
        usage: ContextUsage(
          sessionId: 'wrong',
          last: ContextTokenUsage(totalTokens: 90),
          total: ContextTokenUsage(),
          modelContextWindow: 100,
        ),
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.contextLoading, isTrue);

    bridge.emit(
      const ContextUsageResultMessage(
        sessionId: 's1',
        usage: ContextUsage(
          sessionId: 's1',
          last: ContextTokenUsage(totalTokens: 35),
          total: ContextTokenUsage(),
          modelContextWindow: 100,
        ),
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.contextLoading, isFalse);
    expect(controller.contextUsage?.last.totalTokens, 35);

    controller.refresh(force: true);
    expect(controller.contextLoading, isTrue);
    bridge.emit(
      const ContextUsageErrorMessage(
        sessionId: 's1',
        errorCode: 'context_usage_failed',
        message: 'scan failed',
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.contextLoading, isFalse);
    expect(controller.contextUsage?.last.totalTokens, 35);
  });

  test('old Bridge requests time out without permanent loading', () async {
    final bridge = _Bridge();
    final controller = SessionInsightsController(
      sessionId: 's1',
      bridge: bridge,
      requestTimeout: const Duration(milliseconds: 20),
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    expect(controller.isLoading, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(controller.isLoading, isFalse);
    expect(controller.hasVisibleData, isFalse);
  });

  test(
    'legacy context timeout quarantines rebuilt controllers until reconnect',
    () async {
      final bridge = _Bridge();
      addTearDown(bridge.dispose);
      final first = SessionInsightsController(
        sessionId: 'durable-thread',
        runtimeSessionId: 'runtime-session',
        bridge: bridge,
        requestTimeout: const Duration(milliseconds: 20),
      )..start();
      addTearDown(first.dispose);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        bridge.sent.where((message) => message.type == 'get_context_usage'),
        hasLength(1),
      );

      final rebuilt = SessionInsightsController(
        sessionId: 'durable-thread',
        runtimeSessionId: 'runtime-session',
        bridge: bridge,
      )..start();
      addTearDown(rebuilt.dispose);
      expect(rebuilt.contextLoading, isFalse);
      expect(
        bridge.sent.where((message) => message.type == 'get_context_usage'),
        hasLength(1),
      );

      final nextOwner = Object();
      expect(
        bridge.tryAcquireLegacySessionInsightsContextLane(
          'runtime-session',
          nextOwner,
        ),
        isFalse,
      );

      bridge.emit(
        const ContextUsageMessage(
          usage: ContextUsage(
            sessionId: 'runtime-session',
            last: ContextTokenUsage(totalTokens: 99),
            total: ContextTokenUsage(totalTokens: 99),
            modelContextWindow: 100,
          ),
        ),
        tag: 'runtime-session',
      );
      await Future<void>.delayed(Duration.zero);
      expect(first.contextUsage, isNull);
      expect(rebuilt.contextUsage, isNull);

      bridge.disconnect();
      expect(
        bridge.tryAcquireLegacySessionInsightsContextLane(
          'runtime-session',
          nextOwner,
        ),
        isTrue,
      );
      bridge.releaseLegacySessionInsightsContextLane(
        'runtime-session',
        nextOwner,
      );
      rebuilt.refresh(force: true);
      expect(
        bridge.sent.where((message) => message.type == 'get_context_usage'),
        hasLength(2),
      );
      bridge.emit(
        const ContextUsageMessage(
          usage: ContextUsage(
            sessionId: 'runtime-session',
            last: ContextTokenUsage(totalTokens: 42),
            total: ContextTokenUsage(totalTokens: 42),
            modelContextWindow: 100,
          ),
        ),
        tag: 'runtime-session',
      );
      await Future<void>.delayed(Duration.zero);
      expect(rebuilt.contextUsage?.last.totalTokens, 42);
    },
  );

  test(
    'refresh waits for the authoritative session list before legacy requests',
    () async {
      final bridge = _Bridge()..authoritativeSessionList = false;
      final controller = SessionInsightsController(
        sessionId: 'durable-thread',
        runtimeSessionId: 'runtime-session',
        bridge: bridge,
      )..start();
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      expect(bridge.sent, isEmpty);
      controller.refresh(force: true);
      expect(bridge.sent, isEmpty);

      bridge.authoritativeSessionList = true;
      bridge.emitSessionList();
      await Future<void>.delayed(Duration.zero);

      expect(
        bridge.sent.where((message) => message.type == 'get_context_usage'),
        hasLength(1),
      );
      expect(
        bridge.sent.where((message) => message.type == 'get_session_usage'),
        hasLength(1),
      );
      final contextRequest =
          jsonDecode(
                bridge.sent
                    .singleWhere(
                      (message) => message.type == 'get_context_usage',
                    )
                    .toJson(),
              )
              as Map<String, dynamic>;
      expect(contextRequest['sessionId'], 'runtime-session');
      expect(contextRequest.containsKey('requestId'), isFalse);
    },
  );

  test('old Bridge compatibility errors finish only matching loads', () async {
    final bridge = _Bridge();
    final controller = SessionInsightsController(
      sessionId: 's1',
      bridge: bridge,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    final quotaRequestId = controller.debugPendingQuotaRequestId!;
    bridge.emit(
      const LocalFeatureRequestErrorMessage(
        featureId: 'session_insights',
        ownerSessionId: 's1',
        requestType: 'get_context_usage',
        message: 'get_context_usage',
        errorCode: 'unsupported_message',
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.contextLoading, isFalse);
    expect(controller.quotaLoading, isTrue);

    bridge.emit(
      const LocalFeatureRequestErrorMessage(
        featureId: 'session_insights',
        ownerSessionId: 's1',
        requestType: 'get_session_usage',
        requestId: 'wrong-request',
        message: 'get_session_usage',
        errorCode: 'unsupported_message',
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.quotaLoading, isTrue);

    bridge.emit(
      LocalFeatureRequestErrorMessage(
        featureId: 'session_insights',
        ownerSessionId: 's1',
        requestType: 'get_session_usage',
        requestId: quotaRequestId,
        message: 'get_session_usage',
        errorCode: 'unsupported_message',
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.quotaLoading, isFalse);
    expect(controller.hasVisibleData, isFalse);
  });

  test(
    'correlated quota errors finish loading without global usage state',
    () async {
      final bridge = _Bridge();
      final controller = SessionInsightsController(
        sessionId: 's1',
        bridge: bridge,
      )..start();
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      final request = bridge.sent.lastWhere(
        (message) => message.type == 'get_session_usage',
      );
      final requestId =
          (jsonDecode(request.toJson()) as Map<String, dynamic>)['requestId']
              as String;
      bridge.emit(
        SessionUsageResultMessage(
          sessionId: 's1',
          requestId: requestId,
          providers: const [],
          error: 'account unavailable',
        ),
        tag: 's1',
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.quotaLoading, isFalse);
      expect(controller.usage?.error, 'account unavailable');
      expect(controller.codexUsage, isNull);
    },
  );

  test('failed refreshes preserve the last quota windows', () async {
    final bridge = _Bridge();
    final controller = SessionInsightsController(
      sessionId: 'stale-while-refresh-thread',
      bridge: bridge,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'stale-while-refresh-thread',
        requestId: controller.debugPendingQuotaRequestId!,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(utilization: 21),
            sevenDay: SessionUsageWindow(utilization: 62),
          ),
        ],
      ),
      tag: 'stale-while-refresh-thread',
    );
    await Future<void>.delayed(Duration.zero);

    controller.refresh(force: true);
    expect(controller.quotaLoading, isTrue);
    expect(controller.codexUsage?.fiveHour?.utilization, 21);
    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'stale-while-refresh-thread',
        requestId: controller.debugPendingQuotaRequestId!,
        providers: const [],
        error: 'account temporarily unavailable',
      ),
      tag: 'stale-while-refresh-thread',
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.quotaLoading, isFalse);
    expect(controller.codexUsage?.fiveHour?.utilization, 21);
    expect(controller.codexUsage?.sevenDay?.utilization, 62);

    controller.refresh(force: true);
    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'stale-while-refresh-thread',
        requestId: controller.debugPendingQuotaRequestId!,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            error: 'No rate limit data found in bounded rollout tails',
          ),
        ],
      ),
      tag: 'stale-while-refresh-thread',
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.quotaLoading, isFalse);
    expect(controller.codexUsage?.fiveHour?.utilization, 21);
    expect(controller.codexUsage?.sevenDay?.utilization, 62);

    controller.refresh(force: true);
    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'stale-while-refresh-thread',
        requestId: controller.debugPendingQuotaRequestId!,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            sevenDay: SessionUsageWindow(utilization: 77),
          ),
        ],
      ),
      tag: 'stale-while-refresh-thread',
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.codexUsage?.fiveHour, isNull);
    expect(controller.codexUsage?.sevenDay?.utilization, 77);
  });

  test('fresh Bridge restores phone-local quota while refreshing', () async {
    final firstBridge = _Bridge()
      ..stableBridgeInstanceId = 'persistent-bridge'
      ..stableCodexSourceId = 'persistent-source';
    final first = SessionInsightsController(
      sessionId: 'persistent-thread',
      bridge: firstBridge,
      durableCacheIdentityConfirmed: true,
    )..start();
    addTearDown(first.dispose);
    addTearDown(firstBridge.dispose);

    firstBridge.emit(
      SessionUsageResultMessage(
        sessionId: 'persistent-thread',
        requestId: first.debugPendingQuotaRequestId!,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(utilization: 33),
            sevenDay: SessionUsageWindow(utilization: 61),
            limitCards: [
              SessionUsageLimitCard(
                id: 'gpt-5.3-codex-spark',
                limitName: 'Spark',
                fiveHour: SessionUsageWindow(utilization: 44),
                sevenDay: SessionUsageWindow(utilization: 72),
              ),
            ],
            resetCredits: SessionUsageResetCredits(
              availableCount: 1,
              credits: [
                SessionUsageResetCredit(
                  id: 'private-credit',
                  status: 'available',
                  profileUserId: 'must-not-persist',
                ),
              ],
            ),
          ),
        ],
      ),
      tag: 'persistent-thread',
    );
    await Future<void>.delayed(Duration.zero);
    await first.debugQuotaCacheIdle;

    final freshBridge = _Bridge()
      ..stableBridgeInstanceId = 'persistent-bridge'
      ..stableCodexSourceId = 'persistent-source';
    final restored = SessionInsightsController(
      sessionId: 'persistent-thread',
      bridge: freshBridge,
      durableCacheIdentityConfirmed: true,
    );
    addTearDown(restored.dispose);
    addTearDown(freshBridge.dispose);
    await restored.debugQuotaCacheIdle;

    expect(restored.codexUsage?.fiveHour?.utilization, 33);
    expect(restored.codexUsage?.sevenDay?.utilization, 61);
    expect(restored.codexUsage?.limitCards.single.fiveHour?.utilization, 44);
    expect(restored.codexUsage?.limitCards.single.limitName, isNull);
    expect(restored.codexUsage?.resetCredits, isNull);

    restored.start();
    expect(restored.quotaLoading, isTrue);
    expect(restored.codexUsage?.fiveHour?.utilization, 33);

    final runtimeOnlyBridge = _Bridge()
      ..stableBridgeInstanceId = 'persistent-bridge'
      ..stableCodexSourceId = 'persistent-source';
    final runtimeOnly = SessionInsightsController(
      sessionId: 'persistent-thread',
      bridge: runtimeOnlyBridge,
      durableCacheIdentityConfirmed: false,
    );
    addTearDown(runtimeOnly.dispose);
    addTearDown(runtimeOnlyBridge.dispose);
    await runtimeOnly.debugQuotaCacheIdle;
    expect(runtimeOnly.codexUsage, isNull);

    final switchingBridge = _Bridge()
      ..stableBridgeInstanceId = 'persistent-bridge'
      ..stableCodexSourceId = 'persistent-source';
    final switching = SessionInsightsController(
      sessionId: 'persistent-thread',
      bridge: switchingBridge,
      durableCacheIdentityConfirmed: true,
    );
    addTearDown(switching.dispose);
    addTearDown(switchingBridge.dispose);
    switchingBridge.stableCodexSourceId = 'source-switched-before-restore';
    await switching.debugQuotaCacheIdle;
    expect(switching.codexUsage, isNull);

    final disposedBridge = _Bridge()
      ..stableBridgeInstanceId = 'persistent-bridge'
      ..stableCodexSourceId = 'persistent-source';
    final disposed = SessionInsightsController(
      sessionId: 'persistent-thread',
      bridge: disposedBridge,
      durableCacheIdentityConfirmed: true,
    );
    final disposedRestore = disposed.debugQuotaCacheIdle;
    disposed.dispose();
    addTearDown(disposedBridge.dispose);
    await disposedRestore;
    expect(disposed.codexUsage, isNull);

    final otherThread = SessionInsightsController(
      sessionId: 'different-thread',
      bridge: freshBridge,
      durableCacheIdentityConfirmed: true,
    );
    addTearDown(otherThread.dispose);
    await otherThread.debugQuotaCacheIdle;
    expect(otherThread.codexUsage, isNull);

    final otherSourceBridge = _Bridge()
      ..stableBridgeInstanceId = 'persistent-bridge'
      ..stableCodexSourceId = 'different-source';
    final otherSource = SessionInsightsController(
      sessionId: 'persistent-thread',
      bridge: otherSourceBridge,
      durableCacheIdentityConfirmed: true,
    );
    addTearDown(otherSource.dispose);
    addTearDown(otherSourceBridge.dispose);
    await otherSource.debugQuotaCacheIdle;
    expect(otherSource.codexUsage, isNull);
  });

  test('runtime-only identities never write phone-local quota', () async {
    final runtimeBridge = _Bridge()
      ..stableBridgeInstanceId = 'runtime-only-bridge'
      ..stableCodexSourceId = 'runtime-only-source';
    final runtimeOnly = SessionInsightsController(
      sessionId: 'runtime-alias',
      bridge: runtimeBridge,
      durableCacheIdentityConfirmed: false,
    )..start();
    addTearDown(runtimeOnly.dispose);
    addTearDown(runtimeBridge.dispose);

    runtimeBridge.emit(
      SessionUsageResultMessage(
        sessionId: 'runtime-alias',
        requestId: runtimeOnly.debugPendingQuotaRequestId!,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(utilization: 48),
          ),
        ],
      ),
      tag: 'runtime-alias',
    );
    await Future<void>.delayed(Duration.zero);
    await runtimeOnly.debugQuotaCacheIdle;

    final freshBridge = _Bridge()
      ..stableBridgeInstanceId = 'runtime-only-bridge'
      ..stableCodexSourceId = 'runtime-only-source';
    final durableReader = SessionInsightsController(
      sessionId: 'runtime-alias',
      bridge: freshBridge,
      durableCacheIdentityConfirmed: true,
    );
    addTearDown(durableReader.dispose);
    addTearDown(freshBridge.dispose);
    await durableReader.debugQuotaCacheIdle;
    expect(durableReader.codexUsage, isNull);
  });

  test(
    'successful durable insights survive a controller rebuild for one source',
    () async {
      final bridge = _Bridge();
      addTearDown(bridge.dispose);
      final first = SessionInsightsController(
        sessionId: 'durable-thread',
        bridge: bridge,
      )..start();

      final firstRequestId = first.debugPendingQuotaRequestId!;
      bridge.emit(
        const ContextUsageResultMessage(
          sessionId: 'durable-thread',
          usage: ContextUsage(
            sessionId: 'durable-thread',
            last: ContextTokenUsage(totalTokens: 61),
            total: ContextTokenUsage(totalTokens: 61),
            modelContextWindow: 100,
          ),
        ),
        tag: 'durable-thread',
      );
      bridge.emit(
        SessionUsageResultMessage(
          sessionId: 'durable-thread',
          requestId: firstRequestId,
          providers: const [
            SessionUsageInfo(
              provider: 'codex',
              fiveHour: SessionUsageWindow(utilization: 21),
            ),
          ],
        ),
        tag: 'durable-thread',
      );
      await Future<void>.delayed(Duration.zero);
      expect(first.contextUsage?.last.totalTokens, 61);
      expect(first.codexUsage?.fiveHour?.utilization, 21);
      first.dispose();

      final rebuilt = SessionInsightsController(
        sessionId: 'durable-thread',
        bridge: bridge,
      );
      addTearDown(rebuilt.dispose);
      expect(rebuilt.contextUsage?.last.totalTokens, 61);
      expect(rebuilt.codexUsage?.fiveHour?.utilization, 21);

      rebuilt.start();
      final currentRequestId = rebuilt.debugPendingQuotaRequestId!;
      expect(currentRequestId, isNot(firstRequestId));
      bridge.emit(
        SessionUsageResultMessage(
          sessionId: 'durable-thread',
          requestId: firstRequestId,
          providers: const [
            SessionUsageInfo(
              provider: 'codex',
              fiveHour: SessionUsageWindow(utilization: 99),
            ),
          ],
        ),
        tag: 'durable-thread',
      );
      await Future<void>.delayed(Duration.zero);
      expect(rebuilt.codexUsage?.fiveHour?.utilization, 21);

      bridge.emit(
        SessionUsageResultMessage(
          sessionId: 'durable-thread',
          requestId: currentRequestId,
          providers: const [
            SessionUsageInfo(
              provider: 'codex',
              fiveHour: SessionUsageWindow(utilization: 44),
            ),
          ],
        ),
        tag: 'durable-thread',
      );
      await Future<void>.delayed(Duration.zero);
      expect(rebuilt.codexUsage?.fiveHour?.utilization, 44);
    },
  );

  test('stable source changes isolate snapshots and old responses', () async {
    final bridge = _Bridge();
    addTearDown(bridge.dispose);
    final first = SessionInsightsController(
      sessionId: 'same-thread-id',
      bridge: bridge,
    )..start();

    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'same-thread-id',
        requestId: first.debugPendingQuotaRequestId!,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(utilization: 18),
          ),
        ],
      ),
      tag: 'same-thread-id',
    );
    await Future<void>.delayed(Duration.zero);
    expect(first.codexUsage?.fiveHour?.utilization, 18);
    final oldSourceRequestId = first.debugPendingQuotaRequestId;
    first.refresh(force: true);
    final inFlightOldSourceRequestId = first.debugPendingQuotaRequestId!;
    expect(inFlightOldSourceRequestId, isNot(oldSourceRequestId));

    bridge.stableCodexSourceId = 'source-2';
    bridge.emit(
      const ContextUsageResultMessage(
        sessionId: 'same-thread-id',
        usage: ContextUsage(
          sessionId: 'same-thread-id',
          last: ContextTokenUsage(totalTokens: 88),
          total: ContextTokenUsage(totalTokens: 88),
          modelContextWindow: 100,
        ),
      ),
      tag: 'same-thread-id',
    );
    await Future<void>.delayed(Duration.zero);

    expect(first.contextUsage, isNull);
    expect(first.codexUsage, isNull);
    final freshSourceRequestId = first.debugPendingQuotaRequestId!;
    expect(freshSourceRequestId, isNot(inFlightOldSourceRequestId));

    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'same-thread-id',
        requestId: inFlightOldSourceRequestId,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(utilization: 88),
          ),
        ],
      ),
      tag: 'same-thread-id',
    );
    await Future<void>.delayed(Duration.zero);

    expect(first.codexUsage, isNull);
    expect(first.debugPendingQuotaRequestId, freshSourceRequestId);
    bridge.emit(
      const ContextUsageResultMessage(
        sessionId: 'same-thread-id',
        usage: ContextUsage(
          sessionId: 'same-thread-id',
          last: ContextTokenUsage(totalTokens: 42),
          total: ContextTokenUsage(totalTokens: 42),
          modelContextWindow: 100,
        ),
      ),
      tag: 'same-thread-id',
    );
    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'same-thread-id',
        requestId: freshSourceRequestId,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(utilization: 24),
          ),
        ],
      ),
      tag: 'same-thread-id',
    );
    await Future<void>.delayed(Duration.zero);
    expect(first.contextUsage?.last.totalTokens, 42);
    expect(first.codexUsage?.fiveHour?.utilization, 24);
    first.dispose();

    final secondSource = SessionInsightsController(
      sessionId: 'same-thread-id',
      bridge: bridge,
    );
    addTearDown(secondSource.dispose);
    expect(secondSource.contextUsage?.last.totalTokens, 42);
    expect(secondSource.codexUsage?.fiveHour?.utilization, 24);
  });

  test(
    'missing source identity does not retain snapshots across controllers',
    () async {
      final bridge = _Bridge()..stableCodexSourceId = null;
      addTearDown(bridge.dispose);
      final first = SessionInsightsController(
        sessionId: 'legacy-thread',
        bridge: bridge,
      )..start();
      bridge.emit(
        const ContextUsageResultMessage(
          sessionId: 'legacy-thread',
          usage: ContextUsage(
            sessionId: 'legacy-thread',
            last: ContextTokenUsage(totalTokens: 37),
            total: ContextTokenUsage(totalTokens: 37),
            modelContextWindow: 100,
          ),
        ),
        tag: 'legacy-thread',
      );
      await Future<void>.delayed(Duration.zero);
      expect(first.contextUsage?.last.totalTokens, 37);
      first.dispose();

      final rebuilt = SessionInsightsController(
        sessionId: 'legacy-thread',
        bridge: bridge,
      );
      addTearDown(rebuilt.dispose);
      expect(rebuilt.contextUsage, isNull);
      expect(rebuilt.codexUsage, isNull);
    },
  );

  test('context and quota cache expiry are independent', () async {
    final bridge = _Bridge()
      ..advertisedCapabilities = const {durableSessionInsightsCapability};
    addTearDown(bridge.dispose);
    var now = DateTime.utc(2030);
    final first = SessionInsightsController(
      sessionId: 'durable-cache-thread',
      runtimeSessionId: 'runtime-cache-session',
      bridge: bridge,
      contextCacheTimeToLive: const Duration(minutes: 5),
      quotaCacheTimeToLive: const Duration(minutes: 10),
      clock: () => now,
    )..start();

    bridge.emit(
      ContextUsageResultMessage(
        sessionId: 'durable-cache-thread',
        requestId: first.debugPendingContextRequestId,
        usage: const ContextUsage(
          sessionId: 'durable-cache-thread',
          last: ContextTokenUsage(totalTokens: 50),
          total: ContextTokenUsage(totalTokens: 50),
          modelContextWindow: 100,
        ),
      ),
      tag: 'durable-cache-thread',
    );
    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'durable-cache-thread',
        requestId: first.debugPendingQuotaRequestId!,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(utilization: 20),
          ),
        ],
      ),
      tag: 'durable-cache-thread',
    );
    await Future<void>.delayed(Duration.zero);

    now = now.add(const Duration(minutes: 4));
    first.refresh(force: true);
    bridge.emit(
      SessionUsageResultMessage(
        sessionId: 'durable-cache-thread',
        requestId: first.debugPendingQuotaRequestId!,
        providers: const [
          SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(utilization: 30),
          ),
        ],
      ),
      tag: 'durable-cache-thread',
    );
    await Future<void>.delayed(Duration.zero);
    first.dispose();

    now = now.add(const Duration(minutes: 2));
    final rebuilt = SessionInsightsController(
      sessionId: 'durable-cache-thread',
      runtimeSessionId: 'runtime-cache-session',
      bridge: bridge,
      contextCacheTimeToLive: const Duration(minutes: 5),
      quotaCacheTimeToLive: const Duration(minutes: 10),
      clock: () => now,
    );
    addTearDown(rebuilt.dispose);
    expect(rebuilt.contextUsage, isNull);
    expect(rebuilt.codexUsage?.fiveHour?.utilization, 30);
  });
}
