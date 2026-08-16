import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/logger.dart';

const _traceWindow = Duration(minutes: 1);
const _maxTraceEventsPerWindow = 240;
const _traceEnabled = bool.fromEnvironment(
  'CCPOCKET_SYNC_TRACE',
  defaultValue: true,
);

DateTime? _traceWindowStartedAt;
int _traceEventCount = 0;

/// Emits privacy-safe conversation-sync diagnostics with a process-wide cap.
///
/// Disable at build time with `--dart-define=CCPOCKET_SYNC_TRACE=false`.
/// Callers must only pass hashed target/batch identifiers and structural
/// counters; never include titles, paths, message bodies, or credentials.
void conversationSyncTrace(String message, {bool warning = false}) {
  if (!_traceEnabled) return;
  final now = DateTime.now();
  final startedAt = _traceWindowStartedAt;
  if (startedAt == null || now.difference(startedAt) >= _traceWindow) {
    _traceWindowStartedAt = now;
    _traceEventCount = 0;
  }
  if (_traceEventCount >= _maxTraceEventsPerWindow) {
    if (_traceEventCount == _maxTraceEventsPerWindow) {
      logger.warning(
        '[conversation_sync_v2] trace rate limit reached; '
        'set CCPOCKET_SYNC_TRACE=false at build time to disable',
      );
    }
    _traceEventCount += 1;
    return;
  }
  _traceEventCount += 1;
  if (warning) {
    logger.warning(message);
  } else {
    logger.info(message);
  }
}

String conversationSyncTargetTrace(String provider, String providerSessionId) {
  final key = '$provider\u0000$providerSessionId';
  return _conversationSyncHash(['conversation-sync-target', key]);
}

String conversationSyncBatchTrace(String? batchId) {
  if (batchId == null || batchId.isEmpty) return 'none';
  return _conversationSyncHash(['conversation-sync-batch', batchId]);
}

String shortConversationSyncToken(String? value) {
  if (value == null || value.isEmpty) return 'none';
  return value.length <= 12 ? value : value.substring(0, 12);
}

String _conversationSyncHash(List<String> value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString().substring(0, 12);
