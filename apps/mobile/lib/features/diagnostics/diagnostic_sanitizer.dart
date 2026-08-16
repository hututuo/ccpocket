import 'package:flutter/foundation.dart';

/// Result of the fail-closed sanitization performed before a diagnostic
/// snapshot is serialized or staged for upload.
@immutable
class DiagnosticSanitizationResult {
  const DiagnosticSanitizationResult({
    required this.value,
    required this.redactedCredentialCount,
    required this.truncatedValueCount,
    required this.visitedNodeCount,
  });

  final Object? value;
  final int redactedCredentialCount;
  final int truncatedValueCount;
  final int visitedNodeCount;
}

const _credentialPlaceholder = '[REDACTED_CREDENTIAL]';
const _truncatedPlaceholder = '[DIAGNOSTIC_VALUE_TRUNCATED]';

final _credentialKeys = <String>{
  'apikey',
  'apisecret',
  'token',
  'idtoken',
  'oauthtoken',
  'accesstoken',
  'refreshtoken',
  'bearertoken',
  'authtoken',
  'sessiontoken',
  'devicetoken',
  'pairingtoken',
  'password',
  'passwd',
  'authorization',
  'authorizationheader',
  'clientsecret',
  'accesskeyid',
  'awsaccesskeyid',
  'secret',
  'privatekey',
  'sshkey',
  'credential',
  'credentials',
  'cookie',
  'setcookie',
  'proxyauthorization',
  'passphrase',
  'signingkey',
};

final _credentialStringPatterns = <RegExp>[
  RegExp(
    r'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----',
    caseSensitive: false,
  ),
  RegExp(
    r'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----[\s\S]*',
    caseSensitive: false,
  ),
  RegExp(
    r'-----BEGIN PGP PRIVATE KEY BLOCK-----[\s\S]*?-----END PGP PRIVATE KEY BLOCK-----',
    caseSensitive: false,
  ),
  RegExp(r'-----BEGIN PGP PRIVATE KEY BLOCK-----[\s\S]*', caseSensitive: false),
  RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
  RegExp(r'\b[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b'),
  RegExp(r'\bsk-[A-Za-z0-9_-]{8,}\b'),
  RegExp(r'\bgithub_pat_[A-Za-z0-9_]{8,}\b'),
  RegExp(r'\bgh[pousr]_[A-Za-z0-9_]{8,}\b'),
  RegExp(r'\bxox[baprs]-[A-Za-z0-9-]{8,}\b'),
  RegExp(r'\bAIza[0-9A-Za-z_-]{20,}\b'),
  RegExp(r'\b(?:AKIA|ASIA)[0-9A-Z]{16}\b'),
  RegExp(
    r'\b(?:bridge[ _-]*api[ _-]*key|api[ _-]*key|aws[ _-]*access[ _-]*key[ _-]*id|access[ _-]*key[ _-]*id|aws[ _-]*secret[ _-]*access[ _-]*key|secret[ _-]*access[ _-]*key|secret[ _-]*key|access[ _-]*token|refresh[ _-]*token|authorization|password|passwd|client[ _-]*secret|private[ _-]*key|signing[ _-]*key|passphrase|credentials?|cookie)\s*[=:]\s*\S{6,}',
    caseSensitive: false,
  ),
];

final _networkUrlPattern = RegExp(
  r'''(?:https?|wss?)://[^\s<>"']+''',
  caseSensitive: false,
);

/// Recursively removes credential-bearing fields and high-confidence secret
/// strings while retaining the real development transcript and structural
/// state needed to diagnose synchronization bugs.
///
/// The traversal is also bounded. This is a second memory guard in addition
/// to the per-source diagnostic budgets and the final encoded byte limit.
DiagnosticSanitizationResult sanitizeDiagnosticValue(
  Object? input, {
  int maximumDepth = 64,
  int maximumNodes = 100000,
  int maximumStringCharacters = 256 * 1024,
  int maximumCollectionEntries = 4096,
}) {
  if (maximumDepth < 1 ||
      maximumNodes < 1 ||
      maximumStringCharacters < 1 ||
      maximumCollectionEntries < 1) {
    throw ArgumentError('Diagnostic sanitization limits must be positive.');
  }
  var redactedCredentials = 0;
  var truncatedValues = 0;
  var visitedNodes = 0;

  Object? visit(Object? value, int depth) {
    if (visitedNodes >= maximumNodes || depth > maximumDepth) {
      truncatedValues += 1;
      return _truncatedPlaceholder;
    }
    visitedNodes += 1;
    if (value == null || value is bool || value is num) return value;
    if (value is String) {
      var sanitized = _sanitizeDiagnosticString(value, () {
        redactedCredentials += 1;
      });
      if (sanitized.length > maximumStringCharacters) {
        truncatedValues += 1;
        sanitized =
            '${sanitized.substring(0, maximumStringCharacters)}'
            '\n[TRUNCATED ${sanitized.length - maximumStringCharacters} CHARS]';
      }
      return sanitized;
    }
    if (value is Map) {
      final result = <String, Object?>{};
      var emitted = 0;
      var localCredentialRedactions = 0;
      var localTruncations = 0;
      for (final entry in value.entries) {
        if (emitted >= maximumCollectionEntries) {
          localTruncations += 1;
          truncatedValues += 1;
          continue;
        }
        final key = entry.key.toString();
        if (_isCredentialKey(key)) {
          localCredentialRedactions += 1;
          redactedCredentials += 1;
          continue;
        }
        result[key] = visit(entry.value, depth + 1);
        emitted += 1;
      }
      if (localCredentialRedactions > 0) {
        result['ccpocketDiagnosticRedactedCredentialFields'] =
            localCredentialRedactions;
      }
      if (localTruncations > 0) {
        result['ccpocketDiagnosticTruncatedFields'] = localTruncations;
      }
      return result;
    }
    if (value is Iterable) {
      final result = <Object?>[];
      var omitted = 0;
      for (final item in value) {
        if (result.length >= maximumCollectionEntries) {
          omitted += 1;
          truncatedValues += 1;
          continue;
        }
        result.add(visit(item, depth + 1));
      }
      if (omitted > 0) {
        result.add(<String, Object?>{
          'ccpocketDiagnosticOmittedItems': omitted,
        });
      }
      return result;
    }
    return visit(value.toString(), depth + 1);
  }

  return DiagnosticSanitizationResult(
    value: visit(input, 0),
    redactedCredentialCount: redactedCredentials,
    truncatedValueCount: truncatedValues,
    visitedNodeCount: visitedNodes,
  );
}

bool _isCredentialKey(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  return _credentialKeys.contains(normalized) ||
      normalized.endsWith('apikey') ||
      normalized.endsWith('token') ||
      normalized.endsWith('secret') ||
      normalized.endsWith('secretkey') ||
      normalized.endsWith('accesskeyid') ||
      normalized.contains('secretaccesskey') ||
      normalized.endsWith('password') ||
      normalized.contains('authorization') ||
      normalized.contains('privatekey') ||
      normalized.contains('signingkey') ||
      normalized.endsWith('passphrase') ||
      normalized.endsWith('credential') ||
      normalized.endsWith('credentials') ||
      normalized.endsWith('cookie');
}

String _sanitizeDiagnosticString(String input, VoidCallback onRedaction) {
  var output = input;
  for (final pattern in _credentialStringPatterns) {
    output = output.replaceAllMapped(pattern, (_) {
      onRedaction();
      return _credentialPlaceholder;
    });
  }
  output = output.replaceAllMapped(_networkUrlPattern, (match) {
    final raw = match.group(0)!;
    try {
      final uri = Uri.parse(raw);
      if (!uri.hasAuthority || uri.host.isEmpty) {
        onRedaction();
        return '[REDACTED_URL]';
      }
      // Reading `port` performs stricter validation than Uri.parse itself.
      // It catches transcript fragments such as `ws://host:8765`` where a
      // Markdown delimiter was consumed by the URL regex. Node's WHATWG URL
      // parser rejects the same fragment at the Bridge archive gate.
      final port = uri.hasPort ? uri.port : null;
      final unsafeComponents =
          uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment;
      final normalized = Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: port,
        path: uri.path,
        query: unsafeComponents && uri.hasQuery ? 'ccpocket_redacted=1' : null,
      ).toString();
      if (unsafeComponents) onRedaction();
      return normalized;
    } catch (_) {
      onRedaction();
      return '[REDACTED_URL]';
    }
  });
  return output;
}
