import 'package:flutter/foundation.dart';

/// Last projection that was actually assembled by the Home session list.
///
/// This registry stores a lazy read-only capture closure over the presentation
/// inputs already assembled by Home. Diagnostic reporting therefore records
/// the real ordering/grouping result without paying serialization cost during
/// ordinary builds or re-running that business logic elsewhere.
class HomeDiagnosticProjectionRegistry {
  HomeDiagnosticProjectionRegistry._();

  static final HomeDiagnosticProjectionRegistry instance =
      HomeDiagnosticProjectionRegistry._();

  _HomeDiagnosticProjectionSource? _latest;

  void attach({
    required Object owner,
    required String bridgeInstanceId,
    String? codexSourceId,
    required Map<String, Object?> Function(String targetKey) capture,
  }) {
    _latest = _HomeDiagnosticProjectionSource(
      owner: owner,
      bridgeInstanceId: bridgeInstanceId,
      codexSourceId: codexSourceId,
      capture: capture,
    );
  }

  void detach(Object owner) {
    if (identical(_latest?.owner, owner)) _latest = null;
  }

  Map<String, Object?> capture({
    required String bridgeInstanceId,
    String? codexSourceId,
    required String provider,
    required String providerSessionId,
  }) {
    final source = _latest;
    if (source == null) {
      return const <String, Object?>{'available': false, 'reason': 'notBuilt'};
    }
    if (source.bridgeInstanceId != bridgeInstanceId ||
        source.codexSourceId != codexSourceId) {
      return const <String, Object?>{
        'available': false,
        'reason': 'sourceMismatch',
      };
    }
    final targetKey = '$provider\u0000$providerSessionId';
    final snapshot = source.capture(targetKey);
    final ordered = snapshot['orderedRows'];
    final visible = snapshot['visibleRowKeys'];
    int? orderedIndex = snapshot['targetOrderedIndex'] as int?;
    int? visibleIndex = snapshot['targetVisibleIndex'] as int?;
    if (ordered is List) {
      final capturedIndex = ordered.indexWhere(
        (row) => row is Map && row['identityKey'] == targetKey,
      );
      if (orderedIndex == null && capturedIndex >= 0) {
        final row = ordered[capturedIndex];
        orderedIndex = row is Map && row['originalIndex'] is int
            ? row['originalIndex'] as int
            : capturedIndex;
      }
    }
    if (visibleIndex == null && visible is List) {
      visibleIndex = visible.indexOf(targetKey);
    }
    return <String, Object?>{
      ...snapshot,
      'available': true,
      'target': <String, Object?>{
        'identityKey': targetKey,
        'orderedIndex': orderedIndex == null || orderedIndex < 0
            ? null
            : orderedIndex,
        'visibleIndex': visibleIndex == null || visibleIndex < 0
            ? null
            : visibleIndex,
      },
    };
  }

  @visibleForTesting
  void clear() => _latest = null;
}

class _HomeDiagnosticProjectionSource {
  const _HomeDiagnosticProjectionSource({
    required this.owner,
    required this.bridgeInstanceId,
    required this.codexSourceId,
    required this.capture,
  });

  final Object owner;
  final String bridgeInstanceId;
  final String? codexSourceId;
  final Map<String, Object?> Function(String targetKey) capture;
}
