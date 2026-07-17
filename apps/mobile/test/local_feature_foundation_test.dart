import 'dart:convert';

import 'package:ccpocket/features/local_session_features/host/local_session_feature_host.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('protocol host composes capabilities without duplicates', () {
    final capabilities =
        jsonDecode(ClientMessage.clientCapabilities().toJson())
            as Map<String, dynamic>;
    final supported = (capabilities['supportedServerMessages'] as List)
        .cast<String>();

    expect(supported, contains('conversation_queue'));
    expect(supported.toSet(), hasLength(supported.length));
    expect(
      ServerMessage.fromJson(const {'type': '__unknown_local_feature__'}),
      isA<ErrorMessage>(),
    );
  });

  test('local requests carry an in-memory ephemeral delivery policy', () {
    final message = LocalFeatureProtocolHost.ephemeralRequest(
      type: 'probe_local_feature',
      sessionId: 'session-1',
      requestId: 'request-1',
      fields: const {'value': 7},
    );
    final payload = jsonDecode(message.toJson()) as Map<String, dynamic>;

    expect(message.delivery, ClientMessageDelivery.ephemeral);
    expect(payload, {
      'type': 'probe_local_feature',
      'sessionId': 'session-1',
      'requestId': 'request-1',
      'value': 7,
    });
    expect(payload, isNot(contains('delivery')));
  });

  test('UI host rejects unknown panes and parses its own menu namespace', () {
    expect(LocalSessionFeatureHost.paneDescriptor('__missing__'), isNull);
    expect(LocalSessionFeatureHost.featureIdFromMenuValue('rename'), isNull);
    expect(
      LocalSessionFeatureHost.featureIdFromMenuValue(
        '${LocalSessionFeatureHost.menuValuePrefix}subagents',
      ),
      'subagents',
    );
  });
}
