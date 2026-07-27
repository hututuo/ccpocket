import 'dart:collection';
import 'dart:convert';

/// Stable identity of one provider conversation on one Bridge installation.
///
/// Runtime session IDs and project paths are intentionally excluded: runtime
/// IDs are recreated on resume, while project paths are mutable metadata.
class ConversationMirrorKey {
  const ConversationMirrorKey({
    required this.bridgeInstanceId,
    required this.provider,
    required this.providerSessionId,
    this.codexSourceId,
  });

  static const _sourceStorageProviderPrefix =
      'ccpocket-codex-source-provider-v1:';

  final String bridgeInstanceId;
  final String provider;
  final String providerSessionId;
  final String? codexSourceId;

  /// Persists source identity without changing the v1 SQLite schema.
  ///
  /// Older apps see a source-scoped row as an unknown provider, so their
  /// `provider = codex` lookups fail closed instead of reusing the wrong Home.
  String get storageProvider {
    final sourceId = codexSourceId;
    if (provider != 'codex' || sourceId == null) return provider;
    final payload = base64Url.encode(utf8.encode(jsonEncode(sourceId)));
    return '$_sourceStorageProviderPrefix$payload';
  }

  factory ConversationMirrorKey.fromStorage({
    required String bridgeInstanceId,
    required String provider,
    required String providerSessionId,
  }) {
    if (provider.startsWith(_sourceStorageProviderPrefix)) {
      try {
        final payload = provider.substring(_sourceStorageProviderPrefix.length);
        final sourceId = jsonDecode(utf8.decode(base64Url.decode(payload)));
        if (sourceId is String && sourceId.isNotEmpty) {
          return ConversationMirrorKey(
            bridgeInstanceId: bridgeInstanceId,
            provider: 'codex',
            providerSessionId: providerSessionId,
            codexSourceId: sourceId,
          );
        }
      } catch (_) {
        // Malformed or future encodings remain isolated as an unknown
        // provider instead of being guessed or discarded.
      }
    }
    return ConversationMirrorKey(
      bridgeInstanceId: bridgeInstanceId,
      provider: provider,
      providerSessionId: providerSessionId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationMirrorKey &&
          bridgeInstanceId == other.bridgeInstanceId &&
          provider == other.provider &&
          providerSessionId == other.providerSessionId &&
          codexSourceId == other.codexSourceId;

  @override
  int get hashCode =>
      Object.hash(bridgeInstanceId, provider, providerSessionId, codexSourceId);

  @override
  String toString() =>
      'ConversationMirrorKey($bridgeInstanceId, $provider, '
      '$providerSessionId, $codexSourceId)';
}

/// An entry supplied by a snapshot page or incremental patch.
class ConversationMirrorEntryInput {
  ConversationMirrorEntryInput({
    required this.entryId,
    required this.ordinal,
    required this.contentHash,
    required Map<String, dynamic> message,
  }) : message = UnmodifiableMapView(Map<String, dynamic>.from(message));

  final String entryId;
  final int ordinal;
  final String contentHash;
  final Map<String, dynamic> message;
}

/// A decoded entry read from the active local generation.
class ConversationMirrorEntry {
  ConversationMirrorEntry({
    required this.generation,
    required this.entryId,
    required this.ordinal,
    required this.contentHash,
    required Map<String, dynamic> message,
  }) : message = UnmodifiableMapView(Map<String, dynamic>.from(message));

  final String generation;
  final String entryId;
  final int ordinal;
  final String contentHash;
  final Map<String, dynamic> message;
}

class ConversationMirrorMetadata {
  const ConversationMirrorMetadata({
    required this.key,
    required this.activeGeneration,
    required this.revision,
    required this.entryCount,
    required this.bytes,
    required this.autoSync,
    required this.projectPath,
    required this.lastSyncedAt,
    required this.error,
    this.name,
    this.summary,
    this.firstPrompt,
  });

  final ConversationMirrorKey key;
  final String? activeGeneration;

  /// Opaque SHA-256 digest supplied by the Bridge, or null before the first
  /// complete snapshot has been activated.
  final String? revision;
  final int entryCount;
  final int bytes;
  final bool autoSync;
  final String projectPath;
  final DateTime? lastSyncedAt;
  final String? error;
  final String? name;
  final String? summary;
  final String? firstPrompt;

  bool get hasLocalCopy => activeGeneration != null;

  String? get storedDisplayName {
    for (final value in [name, summary, firstPrompt]) {
      final normalized = value?.trim();
      if (normalized != null && normalized.isNotEmpty) return normalized;
    }
    return null;
  }
}

enum ConversationMirrorPatchOutcome {
  applied,
  revisionMismatch,
  noActiveGeneration,
}

class ConversationMirrorPatchResult {
  const ConversationMirrorPatchResult({
    required this.outcome,
    required this.baseRevision,
    required this.actualRevision,
    required this.revision,
  });

  final ConversationMirrorPatchOutcome outcome;
  final String baseRevision;
  final String? actualRevision;
  final String? revision;

  bool get applied => outcome == ConversationMirrorPatchOutcome.applied;
}

class ConversationMirrorLimits {
  const ConversationMirrorLimits({
    this.maxEntriesPerGeneration = 100000,
    this.maxEntriesPerPage = 100,
    this.maxEntryBytes = 512 * 1024,
    this.maxPageBytes = 512 * 1024,
    this.maxTotalBytes = 64 * 1024 * 1024,
    this.maxDatabaseBytes = 512 * 1024 * 1024,
  });

  final int maxEntriesPerGeneration;
  final int maxEntriesPerPage;
  final int maxEntryBytes;
  final int maxPageBytes;

  /// Maximum raw JSON payload bytes for one conversation generation.
  final int maxTotalBytes;

  /// Maximum raw JSON payload bytes stored across active and shadow copies.
  ///
  /// Metadata and SQLite page overhead are intentionally excluded; this is a
  /// deterministic protocol-payload limit, not a filesystem-size estimate.
  final int maxDatabaseBytes;
}

class ConversationMirrorStorageException implements Exception {
  const ConversationMirrorStorageException(this.message);

  final String message;

  @override
  String toString() => 'ConversationMirrorStorageException: $message';
}

class ConversationMirrorValidationException
    extends ConversationMirrorStorageException {
  const ConversationMirrorValidationException(super.message);

  @override
  String toString() => 'ConversationMirrorValidationException: $message';
}

class ConversationMirrorCorruptionException
    extends ConversationMirrorStorageException {
  const ConversationMirrorCorruptionException(super.message);

  @override
  String toString() => 'ConversationMirrorCorruptionException: $message';
}

/// A snapshot was based on an active copy that changed before activation.
class ConversationMirrorSnapshotConflictException
    extends ConversationMirrorStorageException {
  ConversationMirrorSnapshotConflictException({
    required this.expectedActiveGeneration,
    required this.expectedRevision,
    required this.actualActiveGeneration,
    required this.actualRevision,
  }) : super(
         'Active conversation changed while the snapshot was downloading; '
         'the stale snapshot was discarded.',
       );

  final String? expectedActiveGeneration;
  final String? expectedRevision;
  final String? actualActiveGeneration;
  final String? actualRevision;

  @override
  String toString() => 'ConversationMirrorSnapshotConflictException: $message';
}
