import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

Map<String, dynamic> _requestJson({
  String opaqueRequestId = 'opaque-1',
  String source = 'source-1',
  String thread = 'thread-1',
  String turn = 'turn-1',
  String generation = 'generation-1',
  String state = 'pending',
}) => {
  'opaqueRequestId': opaqueRequestId,
  'codexSourceId': source,
  'threadId': thread,
  'turnId': turn,
  'kind': 'command_approval',
  'state': state,
  'observedAt': '2026-08-01T00:00:00Z',
  'expiresAt': '2026-08-01T00:05:00Z',
  'updatedAt': '2026-08-01T00:00:01Z',
  'authorityGeneration': generation,
  'live': true,
  'toolName': 'Bash',
  'input': {'command': 'echo ok'},
  'allowedActions': ['approve', 'approve_always', 'reject'],
};

Map<String, dynamic> _healthJson({
  bool ready = true,
  bool writerLeaseHeld = true,
  String? generation = 'generation-1',
}) => {
  'ready': ready,
  'controlReady': ready,
  'degraded': false,
  'writerLeaseHeld': writerLeaseHeld,
  'authorityGeneration': ?generation,
};

void main() {
  test('builds exact ephemeral broker requests without a legacy sessionId', () {
    final snapshot = requestCodexActions(requestId: 'snapshot-1');
    expect(snapshot.delivery, ClientMessageDelivery.ephemeral);
    expect(_json(snapshot), {
      'type': 'get_codex_actions',
      'requestId': 'snapshot-1',
    });

    final request = CodexActionBrokerRequest.fromJson(_requestJson());
    final response = respondCodexAction(
      requestId: 'response-1',
      request: request,
      claimantId: 'mobile-1',
      operationId: 'operation-1',
      action: CodexActionBrokerDecision.approve,
    );
    expect(response.delivery, ClientMessageDelivery.ephemeral);
    expect(_json(response), {
      'type': 'respond_codex_action',
      'requestId': 'response-1',
      'opaqueRequestId': 'opaque-1',
      'codexSourceId': 'source-1',
      'threadId': 'thread-1',
      'turnId': 'turn-1',
      'authorityGeneration': 'generation-1',
      'claimantId': 'mobile-1',
      'operationId': 'operation-1',
      'action': 'approve',
    });
    expect(
      LocalFeatureProtocolHost.describeRequest(response),
      isA<LocalFeatureRequestDescriptor>()
          .having((value) => value.ownerSessionId, 'thread', 'thread-1')
          .having((value) => value.requestId, 'request', 'response-1'),
    );
  });

  test('decodes snapshot health, writer lease and fully fenced requests', () {
    final message =
        ServerMessage.fromJson({
              'type': codexActionBrokerBridgeCapability,
              'event': 'snapshot',
              'requestId': 'snapshot-1',
              'health': _healthJson(),
              'requests': [_requestJson()],
            })
            as CodexActionBrokerEventMessage;

    expect(message.health?.writerLeaseHeld, isTrue);
    expect(message.health?.authorityGeneration, 'generation-1');
    expect(
      message.requests.single,
      isA<CodexActionBrokerRequest>()
          .having((value) => value.codexSourceId, 'source', 'source-1')
          .having((value) => value.threadId, 'thread', 'thread-1')
          .having((value) => value.turnId, 'turn', 'turn-1')
          .having(
            (value) => value.authorityGeneration,
            'generation',
            'generation-1',
          ),
    );
  });

  test('outcomeUnknown remains a distinct correlated response outcome', () {
    final message =
        ServerMessage.fromJson({
              'type': codexActionBrokerBridgeCapability,
              'event': 'response',
              'requestId': 'response-1',
              'opaqueRequestId': 'opaque-1',
              'outcome': 'outcomeUnknown',
            })
            as CodexActionBrokerEventMessage;
    expect(message.outcome, CodexActionBrokerResponseOutcome.outcomeUnknown);
  });

  test(
    'rejects inconsistent health and input beyond Bridge-compatible bounds',
    () {
      expect(
        () => ServerMessage.fromJson({
          'type': codexActionBrokerBridgeCapability,
          'event': 'health',
          'health': _healthJson(generation: null),
        }),
        throwsFormatException,
      );

      Object legalDepth = 'leaf';
      for (var index = 0; index < 12; index++) {
        legalDepth = {'level': legalDepth};
      }
      final legal = _requestJson();
      legal['input'] = legalDepth;
      expect(CodexActionBrokerRequest.fromJson(legal).input, isNotEmpty);

      Object tooDeep = 'leaf';
      for (var index = 0; index < 13; index++) {
        tooDeep = {'level': tooDeep};
      }
      final request = _requestJson();
      request['input'] = tooDeep;
      expect(
        () => CodexActionBrokerRequest.fromJson(request),
        throwsFormatException,
      );

      final large = _requestJson();
      large['input'] = {'text': List.filled(70 * 1024, 'x').join()};
      expect(
        () => CodexActionBrokerRequest.fromJson(large),
        throwsFormatException,
      );
    },
  );

  test('accepts additive unsupported-server-request degraded health', () {
    final message =
        ServerMessage.fromJson({
              'type': codexActionBrokerBridgeCapability,
              'event': 'health',
              'health': {
                'ready': false,
                'controlReady': true,
                'degraded': true,
                'writerLeaseHeld': true,
                'degradedReason': 'unsupported_server_request',
                'authorityGeneration': 'generation-1',
              },
            })
            as CodexActionBrokerEventMessage;
    expect(message.health?.degradedReason, 'unsupported_server_request');
  });

  test('snapshot applies one aggregate input budget across requests', () {
    final requests = List.generate(65, (index) {
      final request = _requestJson(opaqueRequestId: 'opaque-$index');
      request['input'] = {'text': List.filled(16 * 1024, 'x').join()};
      return request;
    });

    expect(
      () => ServerMessage.fromJson({
        'type': codexActionBrokerBridgeCapability,
        'event': 'snapshot',
        'health': _healthJson(),
        'requests': requests,
      }),
      throwsFormatException,
    );
  });
}
