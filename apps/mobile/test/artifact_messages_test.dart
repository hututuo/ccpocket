import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const artifactJson = <String, dynamic>{
    'id': 'artifact-1',
    'filename': 'report final.pdf',
    'mimeType': 'application/pdf',
    'sizeBytes': 2048,
    'kind': 'preview',
    'source': 'assistant_markdown',
    'textContentIndex': 2,
    'originalHref': '/Users/me/report%20final.pdf',
    'line': 12,
    'column': 3,
  };

  test('assistant parses and preserves top-level artifacts', () {
    final parsed = ServerMessage.fromJson({
      'type': 'assistant',
      'messageUuid': 'uuid-1',
      'message': {
        'id': 'message-1',
        'role': 'assistant',
        'model': 'codex',
        'content': [
          {'type': 'text', 'text': 'Done'},
        ],
      },
      'artifacts': [artifactJson],
    });

    expect(parsed, isA<AssistantServerMessage>());
    final assistant = parsed as AssistantServerMessage;
    expect(assistant.artifactMessageId, 'message-1');
    expect(assistant.artifacts, hasLength(1));
    expect(assistant.artifacts.single.toJson(), artifactJson);
  });

  test('tool result and past history preserve artifacts', () {
    final tool = ServerMessage.fromJson({
      'type': 'tool_result',
      'toolUseId': 'tool-1',
      'content': 'created',
      'artifacts': [artifactJson],
    }) as ToolResultMessage;
    final past = PastMessage.fromJson({
      'role': 'tool_result',
      'toolUseId': 'tool-1',
      'content': 'created',
      'artifacts': [artifactJson],
    });

    expect(tool.artifacts.single.id, 'artifact-1');
    expect(past.artifacts.single, tool.artifacts.single);
  });

  test('artifact_resolved parses request correlation and errors', () {
    final success = ServerMessage.fromJson({
      'type': 'artifact_resolved',
      'requestId': 'request-1',
      'artifactId': 'artifact-1',
      'relativeUrl': '/artifacts/${List.filled(43, 'A').join()}',
      'expiresAt': '2026-07-16T12:00:00.000Z',
    }) as ArtifactResolvedMessage;
    final failure = ServerMessage.fromJson({
      'type': 'artifact_resolved',
      'requestId': 'request-2',
      'artifactId': 'artifact-1',
      'error': 'gone',
      'errorCode': 'artifact_gone',
    }) as ArtifactResolvedMessage;

    expect(success.requestId, 'request-1');
    expect(success.isSuccess, isTrue);
    expect(failure.isSuccess, isFalse);
    expect(failure.errorCode, 'artifact_gone');
  });

  test('client capabilities and resolve request use fixed protocol fields', () {
    final capabilities = jsonDecode(
      ClientMessage.clientCapabilities().toJson(),
    ) as Map<String, dynamic>;
    final resolve = jsonDecode(
      ClientMessage.resolveArtifact(
        requestId: 'request-1',
        sessionId: 'session-1',
        messageId: 'message-1',
        artifactId: 'artifact-1',
      ).toJson(),
    ) as Map<String, dynamic>;

    expect(
      capabilities['supportedServerMessages'],
      contains('artifact_resolved'),
    );
    expect(resolve, {
      'type': 'resolve_artifact',
      'requestId': 'request-1',
      'sessionId': 'session-1',
      'messageId': 'message-1',
      'artifactId': 'artifact-1',
    });
    expect(resolve, isNot(contains('path')));
  });

  test('read_artifact_source uses a fail-closed identity protocol', () {
    final read = jsonDecode(
      ClientMessage.readArtifactSource(
        requestId: 'file-request-1',
        sessionId: 'session-1',
        messageId: 'message-1',
        artifactId: 'artifact-1',
        filePath: 'lib/main.dart',
        maxLines: 120,
      ).toJson(),
    ) as Map<String, dynamic>;

    expect(read, {
      'type': 'read_artifact_source',
      'requestId': 'file-request-1',
      'sessionId': 'session-1',
      'messageId': 'message-1',
      'artifactId': 'artifact-1',
      'filePath': 'lib/main.dart',
      'maxLines': 120,
    });
    expect(
      () => ClientMessage.readArtifactSource(
        requestId: 'file-request-1',
        sessionId: 'session-1',
        messageId: 'message-1',
        artifactId: '',
        filePath: 'lib/main.dart',
      ),
      throwsArgumentError,
    );
  });

  test('file content preserves artifact source error codes', () {
    final message = ServerMessage.fromJson({
      'type': 'file_content',
      'requestId': 'file-request-1',
      'filePath': 'lib/main.dart',
      'content': '',
      'error': 'changed',
      'errorCode': 'artifact_changed',
    }) as FileContentMessage;

    expect(message.error, 'changed');
    expect(message.errorCode, 'artifact_changed');
  });
}
