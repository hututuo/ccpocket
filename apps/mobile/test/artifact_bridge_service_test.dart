import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestBridgeService extends BridgeService {
  final sent = <Map<String, dynamic>>[];
  bool connected = true;
  String? baseUrl = 'http://100.105.41.82:8765';
  Object? artifactSendError;
  int artifactSendAttempts = 0;

  @override
  bool get isConnected => connected;

  @override
  String? get httpBaseUrl => baseUrl;

  @override
  void sendArtifactResolutionRequest(ClientMessage message) {
    artifactSendAttempts++;
    sent.add(jsonDecode(message.toJson()) as Map<String, dynamic>);
    final error = artifactSendError;
    if (error != null) throw error;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('resolveArtifact correlates concurrent responses by requestId', () async {
    final bridge = _TestBridgeService();
    addTearDown(bridge.dispose);
    final firstFuture = bridge.resolveArtifact(
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-shared',
    );
    final secondFuture = bridge.resolveArtifact(
      sessionId: 'session-1',
      messageId: 'message-2',
      artifactId: 'artifact-shared',
    );

    expect(bridge.sent, hasLength(2));
    final firstRequest = bridge.sent[0]['requestId'] as String;
    final secondRequest = bridge.sent[1]['requestId'] as String;
    expect(firstRequest, isNot(secondRequest));

    bridge.completeArtifactResolutionForTest(
      ArtifactResolvedMessage(
        requestId: secondRequest,
        artifactId: 'artifact-shared',
        relativeUrl: '/artifacts/${List.filled(43, 'B').join()}',
      ),
    );
    bridge.completeArtifactResolutionForTest(
      ArtifactResolvedMessage(
        requestId: firstRequest,
        artifactId: 'artifact-shared',
        relativeUrl: '/artifacts/${List.filled(43, 'A').join()}',
      ),
    );

    expect(
      (await firstFuture).url.toString(),
      contains('/${List.filled(43, 'A').join()}'),
    );
    expect(
      (await secondFuture).url.toString(),
      contains('/${List.filled(43, 'B').join()}'),
    );
  });

  test('resolveArtifact propagates errors and cleans up timeout', () async {
    final bridge = _TestBridgeService();
    addTearDown(bridge.dispose);
    final errorFuture = bridge.resolveArtifact(
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-1',
    );
    final requestId = bridge.sent.single['requestId'] as String;
    bridge.completeArtifactResolutionForTest(
      ArtifactResolvedMessage(
        requestId: requestId,
        artifactId: 'artifact-1',
        error: 'gone',
        errorCode: 'artifact_gone',
      ),
    );
    await expectLater(
      errorFuture,
      throwsA(
        isA<ArtifactResolveException>().having(
          (error) => error.code,
          'code',
          'artifact_gone',
        ),
      ),
    );

    await expectLater(
      bridge.resolveArtifact(
        sessionId: 'session-1',
        messageId: 'message-timeout',
        artifactId: 'artifact-timeout',
        timeout: const Duration(milliseconds: 1),
      ),
      throwsA(
        isA<ArtifactResolveException>().having(
          (error) => error.code,
          'code',
          'artifact_resolve_timeout',
        ),
      ),
    );
  });

  test('one-shot resolve send failure is not queued or replayed', () async {
    final bridge = _TestBridgeService()
      ..artifactSendError = StateError('socket closed');
    addTearDown(bridge.dispose);

    await expectLater(
      bridge.resolveArtifact(
        sessionId: 'session-1',
        messageId: 'message-1',
        artifactId: 'artifact-1',
      ),
      throwsA(
        isA<ArtifactResolveException>().having(
          (error) => error.code,
          'code',
          'bridge_disconnected',
        ),
      ),
    );
    expect(bridge.artifactSendAttempts, 1);
    expect(bridge.queuedMessageCountForTest, 0);

    bridge.artifactSendError = null;
    await bridge.flushQueuedMessagesForTest();
    expect(bridge.artifactSendAttempts, 1);
    expect(bridge.queuedMessageCountForTest, 0);
  });

  test('artifact infrastructure responses are consumed without broadcast', () async {
    final bridge = _TestBridgeService();
    addTearDown(bridge.dispose);
    final broadcast = <ServerMessage>[];
    final subscription = bridge.messages.listen(broadcast.add);
    addTearDown(subscription.cancel);
    final future = bridge.resolveArtifact(
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-1',
    );
    final requestId = bridge.sent.single['requestId'] as String;

    expect(
      bridge.consumeArtifactInfrastructureMessageForTest(
        ArtifactResolvedMessage(
          requestId: requestId,
          artifactId: 'artifact-1',
          relativeUrl: '/artifacts/${List.filled(43, 'A').join()}',
        ),
      ),
      isTrue,
    );

    expect((await future).artifactId, 'artifact-1');
    await Future<void>.delayed(Duration.zero);
    expect(broadcast, isEmpty);
  });

  test('unsupported resolve failure is consumed without broadcast', () async {
    final bridge = _TestBridgeService();
    addTearDown(bridge.dispose);
    final broadcast = <ServerMessage>[];
    final subscription = bridge.messages.listen(broadcast.add);
    addTearDown(subscription.cancel);
    final future = bridge.resolveArtifact(
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-1',
    );

    expect(
      bridge.consumeArtifactInfrastructureMessageForTest(
        const ErrorMessage(
          message: 'resolve_artifact',
          errorCode: 'unsupported_message',
        ),
      ),
      isTrue,
    );

    await expectLater(
      future,
      throwsA(
        isA<ArtifactResolveException>().having(
          (error) => error.code,
          'code',
          'artifact_resolve_unsupported',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(broadcast, isEmpty);
  });

  test('legacy invalid-format resolve failure is consumed immediately', () async {
    final bridge = _TestBridgeService();
    addTearDown(bridge.dispose);
    final future = bridge.resolveArtifact(
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-1',
    );

    expect(
      bridge.consumeArtifactInfrastructureMessageForTest(
        const ErrorMessage(message: 'Invalid message format'),
      ),
      isTrue,
    );
    await expectLater(
      future,
      throwsA(
        isA<ArtifactResolveException>().having(
          (error) => error.code,
          'code',
          'artifact_resolve_unsupported',
        ),
      ),
    );
  });

  test('rejects a response completed just before disconnect', () async {
    final bridge = _TestBridgeService();
    addTearDown(bridge.dispose);
    final future = bridge.resolveArtifact(
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-1',
    );
    final expectation = expectLater(
      future,
      throwsA(
        isA<ArtifactResolveException>().having(
          (error) => error.code,
          'code',
          'bridge_disconnected',
        ),
      ),
    );
    final requestId = bridge.sent.single['requestId'] as String;

    bridge.completeArtifactResolutionForTest(
      ArtifactResolvedMessage(
        requestId: requestId,
        artifactId: 'artifact-1',
        relativeUrl: '/artifacts/${List.filled(43, 'A').join()}',
      ),
    );
    // Models onDone changing connection state before the await continuation.
    bridge.connected = false;

    await expectation;
  });

  test('rejects a response from an obsolete connection epoch', () async {
    final bridge = _TestBridgeService();
    addTearDown(bridge.dispose);
    final future = bridge.resolveArtifact(
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-1',
    );
    final expectation = expectLater(
      future,
      throwsA(
        isA<ArtifactResolveException>().having(
          (error) => error.code,
          'code',
          'bridge_changed',
        ),
      ),
    );
    final requestId = bridge.sent.single['requestId'] as String;

    bridge.completeArtifactResolutionForTest(
      ArtifactResolvedMessage(
        requestId: requestId,
        artifactId: 'artifact-1',
        relativeUrl: '/artifacts/${List.filled(43, 'A').join()}',
      ),
    );
    // disconnect increments the same epoch that a reconnect invalidates.
    // The test override remains connected so this exercises the epoch guard.
    bridge.disconnect();

    await expectation;
  });

  test('rejects a response when the Bridge origin changes', () async {
    final bridge = _TestBridgeService();
    addTearDown(bridge.dispose);
    final future = bridge.resolveArtifact(
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-1',
    );
    final expectation = expectLater(
      future,
      throwsA(
        isA<ArtifactResolveException>().having(
          (error) => error.code,
          'code',
          'bridge_changed',
        ),
      ),
    );
    final requestId = bridge.sent.single['requestId'] as String;

    bridge.completeArtifactResolutionForTest(
      ArtifactResolvedMessage(
        requestId: requestId,
        artifactId: 'artifact-1',
        relativeUrl: '/artifacts/${List.filled(43, 'A').join()}',
      ),
    );
    bridge.baseUrl = 'http://100.105.41.83:8765';

    await expectation;
  });

  test('only accepts token-only artifact paths on the current origin', () {
    final token = List.filled(43, 'A').join();
    expect(
      BridgeService.resolveArtifactRelativeUrl(
        'http://100.105.41.82:8765',
        '/artifacts/$token',
      ).toString(),
      'http://100.105.41.82:8765/artifacts/$token',
    );
    for (final invalid in [
      '/health',
      '/artifacts/$token/download',
      '/artifacts/../health',
      'https://evil.example/artifacts/$token',
    ]) {
      expect(
        () => BridgeService.resolveArtifactRelativeUrl(
          'http://100.105.41.82:8765',
          invalid,
        ),
        throwsA(isA<ArtifactResolveException>()),
      );
    }
  });
}
