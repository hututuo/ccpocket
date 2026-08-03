import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses additive Codex settings persistence results', () {
    final durable = ServerMessage.fromJson(const {
      'type': 'system',
      'subtype': 'set_codex_model',
      'sessionId': 'runtime-1',
      'provider': 'codex',
      'model': 'gpt-5.6-sol',
      'modelReasoningEffort': 'ultra',
      'settingsPersistence': 'durable',
    });
    final runtimeOnly = ServerMessage.fromJson(const {
      'type': 'system',
      'subtype': 'set_codex_speed',
      'sessionId': 'runtime-1',
      'provider': 'codex',
      'serviceTier': 'fast',
      'settingsPersistence': 'runtime_only',
    });

    expect(durable, isA<SystemMessage>());
    expect((durable as SystemMessage).settingsPersistence, 'durable');
    expect(runtimeOnly, isA<SystemMessage>());
    expect((runtimeOnly as SystemMessage).settingsPersistence, 'runtime_only');
  });

  test('keeps old Bridge settings acknowledgements compatible', () {
    final message = ServerMessage.fromJson(const {
      'type': 'system',
      'subtype': 'set_codex_model',
      'sessionId': 'runtime-legacy',
      'provider': 'codex',
      'model': 'gpt-5.5',
    });

    expect(message, isA<SystemMessage>());
    expect((message as SystemMessage).settingsPersistence, isNull);
  });
}
