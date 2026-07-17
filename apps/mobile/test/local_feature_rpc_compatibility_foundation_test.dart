import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LocalRpcBridge extends BridgeService {
  final sent = <Map<String, dynamic>>[];
  Object? sendError;

  @override
  void sendEphemeralRpc(ClientMessage message) {
    final error = sendError;
    if (error != null) throw error;
    sent.add(jsonDecode(message.toJson()) as Map<String, dynamic>);
  }
}

class _ProbeProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _ProbeProtocolSlot();

  @override
  String get featureId => 'probe';

  @override
  List<String> get supportedServerMessageTypes => const ['probe_result'];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) => null;

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    if (request['type'] != 'probe_local_feature') return null;
    final sessionId = request['sessionId'];
    final requestId = request['requestId'];
    if (sessionId is! String || (requestId != null && requestId is! String)) {
      return null;
    }
    return LocalFeatureRequestDescriptor(
      featureId: featureId,
      requestType: 'probe_local_feature',
      ownerSessionId: sessionId,
      requestId: requestId as String?,
    );
  }

  @override
  bool matchesTerminalResponse(
    LocalFeatureRequestDescriptor request,
    ServerMessage response,
  ) {
    return response is _ProbeResultMessage &&
        response.sessionId == request.ownerSessionId &&
        response.requestId == request.requestId;
  }

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) {
    // The foundation must reject this legacy ambiguity before consulting a
    // feature matcher, even if a slot is accidentally over-broad.
    if (error.errorCode == null && error.message == 'Invalid message format') {
      return true;
    }
    return error.errorCode == 'unsupported_capability' &&
        error.message == 'probe capability unavailable';
  }
}

class _ProbeResultMessage implements LocalFeatureTransientMessage {
  @override
  final String sessionId;
  final String? requestId;

  const _ProbeResultMessage({required this.sessionId, this.requestId});

  @override
  String get featureId => 'probe';
}

ClientMessage _probeRequest(
  String sessionId, {
  String? requestId,
  Map<String, dynamic> fields = const {},
}) {
  return LocalFeatureProtocolHost.ephemeralRequest(
    type: 'probe_local_feature',
    sessionId: sessionId,
    requestId: requestId,
    fields: fields,
  );
}

Future<void> _flushBroadcastStreams() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'unsupported local RPC is isolated to every owning dedicated stream',
    () async {
      final bridge = _LocalRpcBridge()
        ..setLocalFeatureProtocolSlotsForTest(const [_ProbeProtocolSlot()]);
      addTearDown(bridge.dispose);

      final global = <ServerMessage>[];
      final sessionOneTagged = <ServerMessage>[];
      final sessionTwoTagged = <ServerMessage>[];
      final sessionOneLocal = <LocalFeatureServerMessage>[];
      final sessionTwoLocal = <LocalFeatureServerMessage>[];
      final subscriptions = <StreamSubscription<dynamic>>[
        bridge.messages.listen(global.add),
        bridge.messagesForSession('session-1').listen(sessionOneTagged.add),
        bridge.messagesForSession('session-2').listen(sessionTwoTagged.add),
        bridge
            .localFeatureMessagesForSession('session-1')
            .listen(sessionOneLocal.add),
        bridge
            .localFeatureMessagesForSession('session-2')
            .listen(sessionTwoLocal.add),
      ];
      addTearDown(() async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      });

      bridge.send(_probeRequest('session-1', requestId: 'request-1'));
      bridge.send(_probeRequest('session-2', requestId: 'request-2'));

      for (var index = 0; index < 2; index++) {
        expect(
          bridge.consumeLocalFeatureInfrastructureMessageForTest(
            const ErrorMessage(
              message: 'probe_local_feature',
              errorCode: 'unsupported_message',
            ),
          ),
          isTrue,
        );
      }
      await _flushBroadcastStreams();

      expect(global, isEmpty);
      expect(sessionOneTagged, isEmpty);
      expect(sessionTwoTagged, isEmpty);
      expect(sessionOneLocal, hasLength(1));
      expect(sessionTwoLocal, hasLength(1));
      expect(
        sessionOneLocal.single,
        isA<LocalFeatureRequestErrorMessage>()
            .having((message) => message.featureId, 'featureId', 'probe')
            .having(
              (message) => message.requestType,
              'requestType',
              'probe_local_feature',
            )
            .having((message) => message.requestId, 'requestId', 'request-1'),
      );
      expect(
        sessionTwoLocal.single,
        isA<LocalFeatureRequestErrorMessage>().having(
          (message) => message.requestId,
          'requestId',
          'request-2',
        ),
      );
      expect(bridge.pendingLocalFeatureRequestsForTest, isEmpty);
    },
  );

  test('slot matcher owns unsupported capability correlation', () async {
    final bridge = _LocalRpcBridge()
      ..setLocalFeatureProtocolSlotsForTest(const [_ProbeProtocolSlot()]);
    addTearDown(bridge.dispose);
    final local = <LocalFeatureServerMessage>[];
    final global = <ServerMessage>[];
    bridge.localFeatureMessagesForSession('session-1').listen(local.add);
    bridge.messages.listen(global.add);

    bridge.send(_probeRequest('session-1', requestId: 'request-1'));
    expect(
      bridge.consumeLocalFeatureInfrastructureMessageForTest(
        const ErrorMessage(
          message: 'different capability failure',
          errorCode: 'unsupported_capability',
        ),
      ),
      isFalse,
    );
    expect(bridge.pendingLocalFeatureRequestsForTest, hasLength(1));

    expect(
      bridge.consumeLocalFeatureInfrastructureMessageForTest(
        const ErrorMessage(
          message: 'probe capability unavailable',
          errorCode: 'unsupported_capability',
        ),
      ),
      isTrue,
    );
    await _flushBroadcastStreams();

    expect(local, hasLength(1));
    expect(global, isEmpty);
    expect(bridge.pendingLocalFeatureRequestsForTest, isEmpty);
  });

  test('unrelated and legacy errors are never consumed', () {
    final bridge = _LocalRpcBridge()
      ..setLocalFeatureProtocolSlotsForTest(const [_ProbeProtocolSlot()]);
    addTearDown(bridge.dispose);

    expect(
      bridge.consumeLocalFeatureInfrastructureMessageForTest(
        const ErrorMessage(
          message: 'probe_local_feature',
          errorCode: 'unsupported_message',
        ),
      ),
      isFalse,
    );

    bridge.send(_probeRequest('session-1', requestId: 'request-1'));
    for (final error in const [
      ErrorMessage(message: 'ordinary failure', errorCode: 'ordinary_error'),
      ErrorMessage(
        message: 'get_history_delta',
        errorCode: 'unsupported_message',
      ),
      ErrorMessage(
        message: 'resolve_artifact',
        errorCode: 'unsupported_message',
      ),
      ErrorMessage(message: 'Invalid message format'),
    ]) {
      expect(
        bridge.consumeLocalFeatureInfrastructureMessageForTest(error),
        isFalse,
      );
    }
    expect(bridge.pendingLocalFeatureRequestsForTest, hasLength(1));
  });

  test('terminal matcher clears only its correlated request', () {
    final bridge = _LocalRpcBridge()
      ..setLocalFeatureProtocolSlotsForTest(const [_ProbeProtocolSlot()]);
    addTearDown(bridge.dispose);

    bridge.send(_probeRequest('session-1', requestId: 'request-1'));
    bridge.send(_probeRequest('session-1', requestId: 'request-2'));

    expect(
      bridge.consumeLocalFeatureInfrastructureMessageForTest(
        const _ProbeResultMessage(
          sessionId: 'session-1',
          requestId: 'request-2',
        ),
      ),
      isTrue,
    );
    expect(
      bridge.pendingLocalFeatureRequestsForTest.map(
        (request) => request.requestId,
      ),
      ['request-1'],
    );
  });

  test('send failure rolls back the pending descriptor', () {
    final bridge = _LocalRpcBridge()
      ..setLocalFeatureProtocolSlotsForTest(const [_ProbeProtocolSlot()])
      ..sendError = StateError('socket closed');
    addTearDown(bridge.dispose);

    expect(
      () => bridge.send(_probeRequest('session-1', requestId: 'request-1')),
      throwsStateError,
    );
    expect(bridge.pendingLocalFeatureRequestsForTest, isEmpty);
  });

  test('registry drops payloads, retains FIFO sends, and expires', () {
    var now = DateTime.utc(2026, 7, 18);
    final bridge = _LocalRpcBridge()
      ..setLocalFeatureProtocolSlotsForTest(const [_ProbeProtocolSlot()])
      ..setLocalFeatureRequestClockForTest(() => now);
    addTearDown(bridge.dispose);

    bridge.send(
      _probeRequest(
        'session-1',
        fields: const {'text': 'must not be retained'},
      ),
    );
    expect(bridge.pendingLocalFeatureRequestsForTest, hasLength(1));
    expect(bridge.pendingLocalFeatureRequestsForTest.single.metadata, {
      'featureId': 'probe',
      'requestType': 'probe_local_feature',
      'ownerSessionId': 'session-1',
      'requestId': null,
    });
    expect(
      bridge.pendingLocalFeatureRequestsForTest.single.metadata,
      isNot(contains('text')),
    );

    bridge.send(_probeRequest('session-1'));
    expect(bridge.pendingLocalFeatureRequestsForTest, hasLength(2));
    for (var remaining = 1; remaining >= 0; remaining--) {
      expect(
        bridge.consumeLocalFeatureInfrastructureMessageForTest(
          const ErrorMessage(
            message: 'probe_local_feature',
            errorCode: 'unsupported_message',
          ),
        ),
        isTrue,
      );
      expect(bridge.pendingLocalFeatureRequestsForTest, hasLength(remaining));
    }

    bridge.send(_probeRequest('session-1'));
    now = now.add(const Duration(seconds: 21));
    expect(bridge.pendingLocalFeatureRequestsForTest, isEmpty);
  });

  test('registry is globally bounded and explicit disconnect clears it', () {
    final bridge = _LocalRpcBridge()
      ..setLocalFeatureProtocolSlotsForTest(const [_ProbeProtocolSlot()]);
    addTearDown(bridge.dispose);

    for (var index = 0; index < 257; index++) {
      bridge.send(_probeRequest('session-$index', requestId: 'request-$index'));
    }
    expect(bridge.pendingLocalFeatureRequestsForTest, hasLength(256));
    expect(
      bridge.pendingLocalFeatureRequestsForTest.first.requestId,
      'request-1',
    );

    bridge.disconnect();
    expect(bridge.pendingLocalFeatureRequestsForTest, isEmpty);

    bridge.send(_probeRequest('session-new', requestId: 'request-new'));
    expect(bridge.pendingLocalFeatureRequestsForTest, hasLength(1));
    bridge.clearPendingLocalFeatureRequestsForTest();
    expect(bridge.pendingLocalFeatureRequestsForTest, isEmpty);
  });
}
