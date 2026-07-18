import 'dart:collection';

/// Stable identity of one provider conversation on one Bridge installation.
///
/// Runtime session IDs and project paths are intentionally excluded: runtime
/// IDs are recreated on resume, while project paths are mutable metadata.
class ConversationMirrorKey {
  const ConversationMirrorKey({
    required this.bridgeInstanceId,
    required this.provider,
    required this.providerSessionId,
  });

  final String bridgeInstanceId;
  final String provider;
  final String providerSessionId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationMirrorKey &&
          bridgeInstanceId == other.bridgeInstanceId &&
          provider == other.provider &&
          providerSessionId == other.providerSessionId;

  @override
  int get hashCode =>
      Object.hash(bridgeInstanceId, provider, providerSessionId);

  @override
  String toString() =>
      'ConversationMirrorKey($bridgeInstanceId, $provider, '
      '$providerSessionId)';
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

  bool get hasLocalCopy => activeGeneration != null;
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
