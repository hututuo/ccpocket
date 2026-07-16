import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadBridgeService extends BridgeService {
  final controller = StreamController<FileContentMessage>.broadcast();
  final messageController = StreamController<ServerMessage>.broadcast();
  final sent = <Map<String, dynamic>>[];
  Object? sendError;
  int sendAttempts = 0;

  @override
  bool get isConnected => true;

  @override
  Stream<FileContentMessage> get fileContent => controller.stream;

  @override
  Stream<ServerMessage> get messages => messageController.stream;

  @override
  void sendEphemeralRpc(ClientMessage message) {
    sendAttempts++;
    sent.add(jsonDecode(message.toJson()) as Map<String, dynamic>);
    final error = sendError;
    if (error != null) throw error;
  }

  @override
  void dispose() {
    controller.close();
    messageController.close();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('readFile correlates requestId and serializes legacy fallback', () async {
    final bridge = _ReadBridgeService();
    addTearDown(bridge.dispose);

    final first = bridge.readArtifactSource(
      filePath: 'lib/main.dart',
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-1',
      timeout: const Duration(seconds: 1),
    );
    final second = bridge.readFile(
      projectPath: '/tmp/project',
      filePath: 'lib/main.dart',
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);

    expect(bridge.sent, hasLength(1));
    expect(bridge.sent.single['type'], 'read_artifact_source');
    expect(bridge.sent.single['sessionId'], 'session-1');
    expect(bridge.sent.single['messageId'], 'message-1');
    expect(bridge.sent.single['artifactId'], 'artifact-1');
    final firstRequestId = bridge.sent.single['requestId'] as String;
    var firstCompleted = false;
    unawaited(first.then((_) => firstCompleted = true));

    bridge.controller.add(
      const FileContentMessage(
        filePath: 'lib/main.dart',
        content: 'uncorrelated response',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(firstCompleted, isFalse);

    bridge.controller.add(
      const FileContentMessage(
        requestId: 'different-request',
        filePath: 'lib/main.dart',
        content: 'wrong response',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(firstCompleted, isFalse);

    bridge.controller.add(
      FileContentMessage(
        requestId: firstRequestId,
        filePath: 'lib/main.dart',
        content: 'first response',
      ),
    );
    expect((await first).content, 'first response');
    await Future<void>.delayed(Duration.zero);

    expect(bridge.sent, hasLength(2));
    final secondRequestId = bridge.sent.last['requestId'] as String;
    expect(secondRequestId, isNot(firstRequestId));

    // A legacy Bridge omits requestId. Serialization makes exact filePath a
    // safe compatibility fallback because only one read is in flight.
    bridge.controller.add(
      const FileContentMessage(
        filePath: 'lib/main.dart',
        content: 'legacy response',
      ),
    );
    expect((await second).content, 'legacy response');
  });

  test('file read send failures are not queued or replayed', () async {
    final bridge = _ReadBridgeService()
      ..sendError = StateError('socket closed');
    addTearDown(bridge.dispose);

    await expectLater(
      bridge.readFile(
        projectPath: '/tmp/project',
        filePath: 'lib/main.dart',
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<StateError>()),
    );
    expect(bridge.sendAttempts, 1);
    expect(bridge.queuedMessageCountForTest, 0);

    await expectLater(
      bridge.readArtifactSource(
        sessionId: 'session-1',
        messageId: 'message-1',
        artifactId: 'artifact-1',
        filePath: 'lib/main.dart',
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(
        isA<ArtifactSourceReadException>().having(
          (error) => error.code,
          'code',
          'bridge_disconnected',
        ),
      ),
    );
    expect(bridge.sendAttempts, 2);
    expect(bridge.queuedMessageCountForTest, 0);

    bridge.sendError = null;
    await bridge.flushQueuedMessagesForTest();
    expect(bridge.sendAttempts, 2);
    expect(bridge.queuedMessageCountForTest, 0);
  });

  test('artifact source read rejects an incomplete identity', () async {
    final bridge = _ReadBridgeService();
    addTearDown(bridge.dispose);

    await expectLater(
      bridge.readArtifactSource(
        filePath: 'lib/main.dart',
        sessionId: 'session-1',
        messageId: 'message-1',
        artifactId: '',
      ),
      throwsArgumentError,
    );
    expect(bridge.sendAttempts, 0);
  });

  test('disconnect fails an in-flight read without replay', () async {
    final bridge = _ReadBridgeService();
    addTearDown(bridge.dispose);
    final future = bridge.readFile(
      projectPath: '/tmp/project',
      filePath: 'lib/main.dart',
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);
    expect(bridge.sendAttempts, 1);
    expect(bridge.queuedMessageCountForTest, 0);

    bridge.disconnect();
    await expectLater(future, throwsA(isA<StateError>()));
    await bridge.flushQueuedMessagesForTest();
    expect(bridge.sendAttempts, 1);
    expect(bridge.queuedMessageCountForTest, 0);
  });

  test('unsupported atomic read fails immediately and remains unqueued', () async {
    final bridge = _ReadBridgeService();
    addTearDown(bridge.dispose);
    final future = bridge.readArtifactSource(
      filePath: 'lib/main.dart',
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-1',
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);

    bridge.messageController.add(
      const ErrorMessage(message: 'Invalid message format'),
    );
    await expectLater(
      future,
      throwsA(
        isA<ArtifactSourceReadException>().having(
          (error) => error.code,
          'code',
          'artifact_source_read_unsupported',
        ),
      ),
    );
    expect(bridge.sendAttempts, 1);
    expect(bridge.queuedMessageCountForTest, 0);
  });

  test('unsupported artifact read errors are consumed without broadcast', () async {
    final bridge = _ReadBridgeService();
    addTearDown(bridge.dispose);
    final broadcast = <ServerMessage>[];
    final subscription = bridge.messages.listen(broadcast.add);
    addTearDown(subscription.cancel);

    final future = bridge.readArtifactSource(
      filePath: 'lib/main.dart',
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-1',
      timeout: const Duration(seconds: 1),
    );
    final expectation = expectLater(
      future,
      throwsA(
        isA<ArtifactSourceReadException>().having(
          (error) => error.code,
          'code',
          'artifact_source_read_unsupported',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      bridge.consumeArtifactInfrastructureMessageForTest(
        const ErrorMessage(
          message: 'read_artifact_source',
          errorCode: 'unsupported_message',
        ),
      ),
      isTrue,
    );
    await expectation;
    await Future<void>.delayed(Duration.zero);
    expect(broadcast, isEmpty);
    expect(bridge.queuedMessageCountForTest, 0);
  });

  test('legacy invalid-format artifact read error is consumed', () async {
    final bridge = _ReadBridgeService();
    addTearDown(bridge.dispose);
    final broadcast = <ServerMessage>[];
    final subscription = bridge.messages.listen(broadcast.add);
    addTearDown(subscription.cancel);

    final future = bridge.readArtifactSource(
      filePath: 'lib/main.dart',
      sessionId: 'session-1',
      messageId: 'message-1',
      artifactId: 'artifact-1',
      timeout: const Duration(seconds: 1),
    );
    final expectation = expectLater(
      future,
      throwsA(isA<ArtifactSourceReadException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      bridge.consumeArtifactInfrastructureMessageForTest(
        const ErrorMessage(message: 'Invalid message format'),
      ),
      isTrue,
    );
    await expectation;
    await Future<void>.delayed(Duration.zero);
    expect(broadcast, isEmpty);
  });
}
