import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/session_insights/state/session_insights_controller.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final tagged =
      StreamController<(LocalFeatureServerMessage, String?)>.broadcast();
  final sent = <ClientMessage>[];
  bool connected = true;

  @override
  bool get isConnected => connected;

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

  @override
  void dispose() {
    tagged.close();
    super.dispose();
  }
}

void main() {
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
}
