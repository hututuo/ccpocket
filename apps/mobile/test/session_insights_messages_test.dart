import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses canonical context usage and nested compatibility shape', () {
    final canonical =
        ServerMessage.fromJson({
              'type': 'context_usage',
              'sessionId': 's1',
              'turnId': 't1',
              'last': {'totalTokens': 296753, 'inputTokens': 290000},
              'total': {'totalTokens': 500000},
              'modelContextWindow': 353400,
            })
            as ContextUsageMessage;

    expect(canonical.sessionId, 's1');
    expect(canonical.last.totalTokens, 296753);
    expect(canonical.modelContextWindow, 353400);
    expect(canonical.usage.utilization, closeTo(0.8397, 0.001));

    final nested =
        ServerMessage.fromJson({
              'type': 'context_usage',
              'sessionId': 's1',
              'usage': {
                'last': {'total_tokens': 10},
                'total': {'total_tokens': 20},
                'modelContextWindow': 100,
              },
            })
            as ContextUsageMessage;
    expect(nested.last.totalTokens, 10);
    expect(nested.total.totalTokens, 20);

    final explicitResult =
        ServerMessage.fromJson({
              'type': 'context_usage_result',
              'sessionId': 's1',
              'last': {'totalTokens': 30},
              'total': {'totalTokens': 40},
              'modelContextWindow': 100,
            })
            as ContextUsageResultMessage;
    expect(explicitResult.sessionId, 's1');
    expect(explicitResult.usage.last.totalTokens, 30);
    expect(
      () => ServerMessage.fromJson({
        'type': 'context_usage_result',
        'last': {'totalTokens': 1},
        'total': {'totalTokens': 1},
        'modelContextWindow': 100,
      }),
      throwsFormatException,
    );

    final explicitError =
        ServerMessage.fromJson({
              'type': 'context_usage_error',
              'sessionId': 's1',
              'errorCode': 'context_usage_failed',
              'message': 'scan failed',
            })
            as ContextUsageErrorMessage;
    expect(explicitError.sessionId, 's1');
    expect(explicitError.errorCode, 'context_usage_failed');
  });

  test('parses multiple limit cards and read-only reset credits', () {
    final result =
        ServerMessage.fromJson({
              'type': 'session_usage_result',
              'sessionId': 's1',
              'requestId': 'usage-1',
              'providers': [
                {
                  'provider': 'codex',
                  'source': 'account_api',
                  'limitCards': [
                    {
                      'id': 'codex',
                      'limitName': 'Pro',
                      'fiveHour': {'utilization': 23, 'windowDurationMins': 15},
                    },
                    {
                      'id': 'individual',
                      'name': 'Individual',
                      'sevenDay': {
                        'utilization': 50,
                        'resetsAt': '2030-01-07T01:00:00Z',
                      },
                      'spendControlReached': false,
                    },
                  ],
                  'resetCredits': {
                    'availableCount': 1,
                    'credits': [
                      {
                        'id': 'credit-1',
                        'status': 'available',
                        'expires_at': '2030-02-01T00:00:00Z',
                      },
                    ],
                  },
                },
              ],
            })
            as SessionUsageResultMessage;

    final codex = result.providers.single;
    expect(codex.limitCards, hasLength(2));
    expect(codex.limitCards.first.fiveHour?.windowDurationMins, 15);
    expect(codex.limitCards.first.fiveHour?.resetsAt, isNull);
    expect(codex.limitCards.last.displayName, 'Individual');
    expect(codex.resetCredits?.availableCount, 1);
    expect(codex.resetCredits?.credits.single.isAvailable, isTrue);
    expect(codex.source, 'account_api');
  });

  test('session usage request and result preserve correlation fields', () {
    expect(
      jsonDecode(
        requestSessionUsage(sessionId: 's1', requestId: 'usage-1').toJson(),
      ),
      {'type': 'get_session_usage', 'sessionId': 's1', 'requestId': 'usage-1'},
    );
    final result =
        ServerMessage.fromJson({
              'type': 'session_usage_result',
              'sessionId': 's1',
              'requestId': 'usage-1',
              'error': 'partial account response',
              'providers': const [],
            })
            as SessionUsageResultMessage;
    expect(result.sessionId, 's1');
    expect(result.requestId, 'usage-1');
    expect(result.error, 'partial account response');

    expect(
      () => requestSessionUsage(sessionId: ' ', requestId: 'usage-1'),
      throwsArgumentError,
    );
    expect(
      () => ServerMessage.fromJson({
        'type': 'session_usage_result',
        'sessionId': 's1',
        'providers': const [],
      }),
      throwsFormatException,
    );
    final capabilities =
        jsonDecode(ClientMessage.clientCapabilities().toJson())
            as Map<String, dynamic>;
    expect(capabilities['supportedServerMessages'], contains('context_usage'));
    expect(
      capabilities['supportedServerMessages'],
      contains('context_usage_result'),
    );
    expect(
      capabilities['supportedServerMessages'],
      contains('context_usage_error'),
    );
    expect(
      capabilities['supportedServerMessages'],
      contains('session_usage_result'),
    );
  });

  test('official usage protocol keeps its baseline shape', () {
    expect(jsonDecode(ClientMessage.getUsage().toJson()), {
      'type': 'get_usage',
    });
    final result =
        ServerMessage.fromJson({
              'type': 'usage_result',
              'providers': [
                {
                  'provider': 'codex',
                  'fiveHour': {
                    'utilization': 25,
                    'resetsAt': '2030-01-01T00:00:00Z',
                  },
                },
              ],
            })
            as UsageResultMessage;
    expect(result.providers.single.fiveHour?.utilization, 25);
    expect(result.providers.single.fiveHour?.resetsAt, '2030-01-01T00:00:00Z');
  });
}
