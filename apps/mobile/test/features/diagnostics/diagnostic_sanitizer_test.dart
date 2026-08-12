import 'dart:convert';

import 'package:ccpocket/features/diagnostics/diagnostic_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'recursively removes credentials while retaining real transcript text',
    () {
      final result = sanitizeDiagnosticValue(<String, Object?>{
        'transcript': <Object?>[
          'Token Bar is a product name and password rules are being discussed.',
          <String, Object?>{
            'authorizationHeader': 'Bearer should-never-leave-phone',
            'nested': <String, Object?>{
              'api_key': 'sk-1234567890abcdef',
              'githubToken': 'ghp_1234567890abcdef',
              'message': 'real development output',
            },
          },
        ],
        'signedUrl':
            'https://example.test/file?X-Amz-Signature=secret#private-fragment',
        'websocketUrl':
            'wss://bridge.example.test:8765/socket?token=must-not-leave',
        'plainUrl': 'https://example.test/public/path',
        'inline': 'request used Bearer abcdefghijklmnop',
        'assignment': 'BRIDGE_API_KEY=must-not-leave-either',
        'awsEnv': <String, Object?>{
          'AWS_SECRET_ACCESS_KEY': 'not-an-access-id-but-still-secret',
          'AWS_ACCESS_KEY_ID': 'ASIAABCDEFGHIJKLMNOP',
        },
        'awsAssignment': 'AWS_SECRET_ACCESS_KEY=another-high-confidence-secret',
        'awsHumanAssignment':
            'AWS Secret Access Key: natural-language-secret-value',
        'pem': [
          '-----BEGIN ',
          'PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----',
        ].join(),
        'openSsh': [
          '-----BEGIN OPENSSH ',
          'PRIVATE KEY-----\nssh-material\n-----END OPENSSH PRIVATE KEY-----',
        ].join(),
        'truncatedPem': [
          '-----BEGIN EC ',
          'PRIVATE KEY-----\ntruncated-material',
        ].join(),
      });

      final encoded = jsonEncode(result.value);
      expect(encoded, contains('Token Bar is a product name'));
      expect(encoded, contains('real development output'));
      expect(encoded, contains('https://example.test/public/path'));
      expect(encoded, contains('ccpocket_redacted=1'));
      expect(encoded, isNot(contains('should-never-leave-phone')));
      expect(encoded, isNot(contains('sk-1234567890abcdef')));
      expect(encoded, isNot(contains('ghp_1234567890abcdef')));
      expect(encoded, isNot(contains('X-Amz-Signature')));
      expect(encoded, isNot(contains('abcdefghijklmnop')));
      expect(encoded, isNot(contains('must-not-leave')));
      expect(encoded, isNot(contains('not-an-access-id-but-still-secret')));
      expect(encoded, isNot(contains('ASIAABCDEFGHIJKLMNOP')));
      expect(encoded, isNot(contains('another-high-confidence-secret')));
      expect(encoded, isNot(contains('natural-language-secret-value')));
      expect(encoded, isNot(contains('private-material')));
      expect(encoded, isNot(contains('ssh-material')));
      expect(encoded, isNot(contains('truncated-material')));
      expect(result.redactedCredentialCount, greaterThanOrEqualTo(11));
    },
  );

  test('bounds collections, strings, depth, and total nodes', () {
    final result = sanitizeDiagnosticValue(
      <String, Object?>{
        'items': List<Object?>.generate(20, (index) => 'value-$index'),
        'long': 'x' * 100,
        'deep': <String, Object?>{
          'a': <String, Object?>{
            'b': <String, Object?>{'c': 'too deep'},
          },
        },
      },
      maximumDepth: 2,
      maximumNodes: 12,
      maximumStringCharacters: 16,
      maximumCollectionEntries: 4,
    );

    final encoded = jsonEncode(result.value);
    expect(encoded, contains('ccpocketDiagnosticOmittedItems'));
    expect(encoded, contains('TRUNCATED'));
    expect(encoded, contains('DIAGNOSTIC_VALUE_TRUNCATED'));
    expect(result.truncatedValueCount, greaterThan(0));
    expect(result.visitedNodeCount, lessThanOrEqualTo(12));
  });
}
