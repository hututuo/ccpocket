import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite/sqflite.dart' as sqflite show databaseFactory;

import 'conversation_repository_contract.dart';
import 'conversation_repository_models.dart';

export 'conversation_repository_contract.dart';
export 'conversation_repository_models.dart';

part 'conversation_repository_json.dart';
part 'conversation_repository_schema.dart';
part 'conversation_repository_validation.dart';
part 'conversation_repository_projection_safety.dart';
part 'conversation_repository_materialization.dart';
part 'conversation_repository_projection.dart';
part 'conversation_repository_readback.dart';

class _FenceTransition {
  const _FenceTransition({
    required this.connectionChanged,
    required this.sourceChanged,
    required this.providerChanged,
  });

  final bool connectionChanged;
  final bool sourceChanged;
  final bool providerChanged;

  bool get timelineEpochChanged => sourceChanged || providerChanged;
}

class _CanonicalEnvelope {
  _CanonicalEnvelope({
    required this.envelopeId,
    required this.key,
    required this.fence,
    required this.sourceRevision,
    required this.coverage,
    required this.health,
    required this.isSnapshot,
    required this.pageCount,
    required this.totalItemCount,
    required this.providerReadEvidenceDigest,
    this.problemCode,
    this.emptyProof,
    List<CanonicalItem> items = const <CanonicalItem>[],
    List<TypedGap> gaps = const <TypedGap>[],
  }) : items = List<CanonicalItem>.unmodifiable(items),
       gaps = List<TypedGap>.unmodifiable(gaps);

  final String envelopeId;
  final ThreadKey key;
  final EnvelopeFence fence;
  final int sourceRevision;
  final Coverage coverage;
  final ReadHealth health;
  final String? problemCode;
  final bool isSnapshot;
  final int pageCount;
  final int totalItemCount;
  final String providerReadEvidenceDigest;
  final ReplicaEmptyProof? emptyProof;
  final List<CanonicalItem> items;
  final List<TypedGap> gaps;

  int get pageIndex => pageCount == 0 ? -1 : 0;
}

class _ProjectionAdmission {
  const _ProjectionAdmission({
    required this.wasDuplicate,
    required this.wasAlreadyApplied,
  });

  final bool wasDuplicate;
  final bool wasAlreadyApplied;
}

/// The sole Mobile writer for the rebuildable conversation replica.
///
/// The facade deliberately contains lifecycle and public API only.  Schema,
/// validation, materialization, projection, and readback implementations are
/// private `part` modules of this same library, so no second writer or public
/// controller can be assembled accidentally.
class ConversationRepository {
  ConversationRepository({
    DatabaseFactory? databaseFactory,
    String? databasePath,
    int defaultWindowSize = 200,
    int maxEntriesPerThread = 100000,
    int maxBytesPerThread = 64 * 1024 * 1024,
    ConversationContractMapper? contractMapper,
    RepositoryFaultHook? faultHook,
    RepositoryReadHook? readHook,
  }) : this._internal(
         databaseFactory: databaseFactory,
         databasePath: databasePath,
         defaultWindowSize: defaultWindowSize,
         maxEntriesPerThread: maxEntriesPerThread,
         maxBytesPerThread: maxBytesPerThread,
         contractMapper:
             contractMapper ?? const UnavailableConversationContract(),
         allowFixtureContract: false,
         faultHook: faultHook,
         readHook: readHook,
       );

  /// Explicit fixture-only construction for repository unit tests.
  ///
  /// This API is intentionally visible to tests so that generated contract
  /// outputs do not have to be fabricated in this checkout.  The compile-time
  /// product-mode guard makes it impossible to enable the fixture adapter in a
  /// Flutter product build.
  @visibleForTesting
  factory ConversationRepository.forTesting({
    DatabaseFactory? databaseFactory,
    String? databasePath,
    int defaultWindowSize = 200,
    int maxEntriesPerThread = 100000,
    int maxBytesPerThread = 64 * 1024 * 1024,
    required ConversationContractMapper contractMapper,
    RepositoryFaultHook? faultHook,
    RepositoryReadHook? readHook,
    RepositoryProcessLivenessProbe? processLivenessProbe,
  }) {
    if (kReleaseMode || const bool.fromEnvironment('dart.vm.product')) {
      throw UnsupportedError(
        'fixture conversation repositories are unavailable in product builds',
      );
    }
    if (isGeneratedConversationAuthorityProfile(
      contractMapper.authorityProfile,
    )) {
      throw ArgumentError.value(
        contractMapper,
        'contractMapper',
        'forTesting requires an explicitly non-generated fixture adapter',
      );
    }
    return ConversationRepository._internal(
      databaseFactory: databaseFactory,
      databasePath: databasePath,
      defaultWindowSize: defaultWindowSize,
      maxEntriesPerThread: maxEntriesPerThread,
      maxBytesPerThread: maxBytesPerThread,
      contractMapper: contractMapper,
      allowFixtureContract: true,
      faultHook: faultHook,
      readHook: readHook,
      processLivenessProbe: processLivenessProbe,
    );
  }

  ConversationRepository._internal({
    DatabaseFactory? databaseFactory,
    required this.databasePath,
    required this.defaultWindowSize,
    required this.maxEntriesPerThread,
    required this.maxBytesPerThread,
    required this._contractMapper,
    required this._allowFixtureContract,
    this.faultHook,
    this.readHook,
    this.processLivenessProbe,
  }) : _databaseFactory = databaseFactory ?? sqflite.databaseFactory,
       _ownerToken = _makeOwnerToken() {
    _updatesController.onListen = _onUpdatesListen;
    if (defaultWindowSize <= 0 || defaultWindowSize > maxWindowSize) {
      throw ArgumentError.value(
        defaultWindowSize,
        'defaultWindowSize',
        'must be between 1 and $maxWindowSize',
      );
    }
    if (maxEntriesPerThread <= 0 || maxEntriesPerThread > hardMaxEntries) {
      throw ArgumentError.value(
        maxEntriesPerThread,
        'maxEntriesPerThread',
        'must be between 1 and $hardMaxEntries',
      );
    }
    if (maxBytesPerThread <= 0 || maxBytesPerThread > hardMaxBytes) {
      throw ArgumentError.value(
        maxBytesPerThread,
        'maxBytesPerThread',
        'must be between 1 and $hardMaxBytes',
      );
    }
    if (_allowFixtureContract && !_usesFixtureContract) {
      throw ArgumentError.value(
        _contractMapper,
        'contractMapper',
        'fixture mode is only valid for an explicitly non-generated test adapter',
      );
    }
  }

  /// Opaque test-only profile passed to a fixture mapper.  The normal
  /// constructor rejects this profile, and [forTesting] is unavailable in a
  /// product build, so production construction cannot enable fixture bytes.
  @visibleForTesting
  static Object get testFixtureAuthorityProfile =>
      conversationFixtureAuthorityProfileForTesting();

  static const defaultDatabaseName = 'conversation_replica_v5.db';
  static const maxWindowSize = 200;
  static const maxPageBodyBytes = 256 * 1024;
  static const maxMaterializationPages = 128;
  static const hardMaxEntries = 100000;
  static const hardMaxBytes = 64 * 1024 * 1024;
  static const maxPublicationEventIdLength = 65536;
  static const maxJsonDepth = 64;
  static const maxJsonNodes = 10000;
  static const writerLeaseTimeout = Duration(minutes: 2);
  static const writerLeaseHeartbeatInterval = Duration(seconds: 30);
  // Retired epoch values are exact anti-rollback evidence.  They are never
  // garbage-collected; this cap keeps that immutable floor bounded and fails
  // closed before accepting a new distinct value.
  static const maxRetiredEpochValuesPerKind = 256;
  static const _schemaVersion = 5;
  static const _schemaIdentity = 'ccpocket.conversation_replica_v5';
  static const _leaseName = 'conversation-repository-writer';

  final DatabaseFactory _databaseFactory;
  final String? databasePath;
  final int defaultWindowSize;
  final int maxEntriesPerThread;
  final int maxBytesPerThread;
  final ConversationContractMapper _contractMapper;
  final bool _allowFixtureContract;
  final RepositoryFaultHook? faultHook;
  final RepositoryReadHook? readHook;
  final RepositoryProcessLivenessProbe? processLivenessProbe;
  final String _ownerToken;

  static const _maxRememberedPublicationEvents = 4096;

  static final String _bootIdentity = _makeOwnerToken();
  // Dart isolates do not share static state.  A second isolate with the same
  // PID therefore receives a different process-instance token; lease reclaim
  // must use an explicit liveness proof for any same-PID owner, while this
  // isolate also fails closed for its own idle owner.
  static final String _processInstanceIdentity = _makeOwnerToken();

  bool get _usesGeneratedContract =>
      isGeneratedConversationAuthorityProfile(_contractMapper.authorityProfile);

  bool get _usesFixtureContract =>
      isFixtureConversationAuthorityProfile(_contractMapper.authorityProfile);

  final StreamController<RepositoryWindow> _updatesController =
      StreamController<RepositoryWindow>.broadcast(sync: true);
  final Set<String> _deliveredPublicationEvents = <String>{};
  Database? _database;
  Future<Database>? _opening;
  Future<void>? _closing;
  Future<void> _writeTail = Future<void>.value();
  Timer? _leaseHeartbeatTimer;
  Database? _leaseHeartbeatDatabase;
  bool _publicationDrainScheduled = false;
  bool _publicationDrainRunning = false;
  String? _resolvedDatabasePath;
  int? _usageDataVersion;
  final Set<ThreadKey> _verifiedUsageKeys = <ThreadKey>{};
  final Set<SourcePartition> _verifiedUsagePartitions = <SourcePartition>{};
  bool _closed = false;
  int _activeReads = 0;
  Completer<void>? _readsDrained;

  Stream<RepositoryWindow> get updates => _updatesController.stream;

  String? get resolvedDatabasePath => _resolvedDatabasePath;

  Future<void> open() async {
    if (_closed) {
      _throwFailure(RepositoryFailureCode.notOpen, 'repository is closed');
    }
    if (_database != null) return;
    final pending = _opening ??= _openDatabase();
    try {
      final database = await pending;
      if (_closed) {
        if (identical(_database, database)) _database = null;
        try {
          await _releaseLease(database);
        } finally {
          try {
            await database.close();
          } catch (_) {
            // A concurrent close may already have closed this handle.
          }
        }
        _throwFailure(
          RepositoryFailureCode.notOpen,
          'repository was closed while opening',
        );
      }
      _database = database;
      _schedulePublicationDrain();
    } finally {
      if (identical(_opening, pending)) _opening = null;
    }
  }

  Future<Database> _openDatabase() async {
    final dbPath =
        databasePath ??
        path.join(
          await _databaseFactory.getDatabasesPath(),
          defaultDatabaseName,
        );
    final basename = path.basename(dbPath);
    if (basename == 'ccpocket.db' ||
        basename == 'conversation_mirror_v1.db' ||
        basename == 'conversation_replica_v4.db') {
      _throwFailure(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'v5 replica cannot open legacy database $basename',
      );
    }
    _resolvedDatabasePath = dbPath;
    Database? database;
    try {
      database = await _databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: _schemaVersion,
          // The persistent lease, rather than sqflite's isolate-local
          // singleton cache, is the authority for same-path ownership.
          singleInstance: false,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: _createSchema,
          onUpgrade: (db, oldVersion, newVersion) async {
            // There is intentionally no guessed migration from the previous
            // v4 candidate schema.  A future generated-authority integration
            // must define and attest its own migration before opening it.
            throw ConversationRepositoryException(
              RepositoryFailureCode.invalidDatabaseIdentity,
              'conversation replica schema upgrade $oldVersion->$newVersion is unsupported; recreate or migrate under an explicit authority',
            );
          },
          onOpen: _verifySchema,
        ),
      );
      await _acquireLease(database);
      _resetUsageVerification();
      _usageDataVersion = await _readDataVersion(database);
      // Recovery can span many bounded batches.  Start the independent lease
      // heartbeat before any recovery work so a long-lived open cannot let a
      // live owner be reclaimed while it is repairing durable rows.
      _startLeaseHeartbeat(database);
      // Recovery is part of opening the leased handle.  Keeping it inside the
      // shared open future prevents concurrent callers from observing a
      // database before pending inbox rows have been replayed.
      await _recoverInbox(database);
      await _recoverPublicationOutbox(database);
      return database;
    } catch (_) {
      _leaseHeartbeatTimer?.cancel();
      _leaseHeartbeatTimer = null;
      _leaseHeartbeatDatabase = null;
      if (database != null) {
        try {
          await _releaseLease(database);
        } catch (_) {
          // Preserve the original open/recovery failure.
        }
        try {
          await database.close();
        } catch (_) {
          // Preserve the original open/recovery failure.
        }
      }
      rethrow;
    }
  }

  Future<StagingReceipt> beginMaterialization(MaterializationBegin begin) =>
      _beginMaterialization(this, begin);

  Future<StagingReceipt> stageMaterializationPage(MaterializationPage page) =>
      _stageMaterializationPage(this, page);

  Future<void> discardMaterialization(MaterializationBegin begin) =>
      _discardMaterialization(this, begin);

  Future<CommitReceipt> commitMaterialization(
    MaterializationCommit commit, {
    int? readLimit,
  }) => _commitMaterialization(this, commit, readLimit: readLimit);

  Future<CommitReceipt> commitRuntimeProjections(
    RuntimeProjectionEnvelope projection, {
    int? readLimit,
  }) => _commitRuntimeProjectionSafely(
    this,
    projection,
    readLimit: readLimit,
  );

  Future<RepositoryWindow> readWindow(
    ThreadKey key, {
    int? beforeOrdinal,
    int? limit,
  }) => _readWindow(this, key, beforeOrdinal: beforeOrdinal, limit: limit);

  String materializationPageDigest(MaterializationPageBody body) =>
      _verifiedPreimage(_contractMapper.pageBody(body), 'page body').digest;

  String materializationPageManifestDigest(Iterable<String> pageDigests) =>
      _verifiedPreimage(
        _contractMapper.pageManifest(pageDigests),
        'page manifest',
      ).digest;

  String replicaEmptyProofDigest(ReplicaEmptyProof proof) => _verifiedPreimage(
    _contractMapper.emptyProof(proof),
    'empty proof',
  ).digest;

  ContractPreimage _verifiedPreimage(ContractPreimage value, String field) =>
      _verifyContractPreimage(this, value, field);

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _leaseHeartbeatTimer?.cancel();
    _leaseHeartbeatTimer = null;
    _leaseHeartbeatDatabase = null;
    _publicationDrainScheduled = false;
    await _writeTail;
    await _waitForReads();
    Database? database;
    try {
      database = _opening == null ? _database : await _opening;
    } catch (_) {
      // Preserve the original open failure for its caller.
    }
    if (database != null) {
      try {
        await _releaseLease(database);
      } finally {
        try {
          await database.close();
        } catch (_) {
          // A failed/open-race database may already be closed.  Lease release
          // is the safety-critical operation; close is best effort here.
        }
      }
    }
    _database = null;
    _resetUsageVerification();
    await _updatesController.close();
  }

  void _resetUsageVerification() {
    _usageDataVersion = null;
    _verifiedUsageKeys.clear();
    _verifiedUsagePartitions.clear();
  }

  static String _makeOwnerToken() {
    return '${pid.toString()}-${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}';
  }

  Never _throwFailure(RepositoryFailureCode code, String message) {
    throw ConversationRepositoryException(code, message);
  }

  Database _requireDatabase() {
    final database = _database;
    if (database == null || _closed) {
      return _throwFailure(
        RepositoryFailureCode.notOpen,
        'open the repository before reading or writing',
      );
    }
    return database;
  }

  ConversationContractMapper _requireContract() {
    if (!_usesGeneratedContract &&
        !(_allowFixtureContract && _usesFixtureContract)) {
      return _throwFailure(
        RepositoryFailureCode.contractUnavailable,
        'generated conversation contract outputs are unavailable; operation is fail-closed',
      );
    }
    return _contractMapper;
  }

  Future<T> _serialize<T>(Future<T> Function(Database database) operation) {
    final database = _requireDatabase();
    final next = _writeTail.then((_) async {
      await _assertWriterLease(database, this);
      return operation(database);
    });
    _writeTail = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  Future<void> _acquireLease(Database database) =>
      _acquireWriterLease(this, database);

  Future<void> _releaseLease(Database database) =>
      _releaseWriterLease(this, database);

  Future<void> _recoverInbox(Database database) =>
      _recoverProjectionInboxSafely(this, database);

  Future<void> _recoverPublicationOutbox(Database database) =>
      _recoverPublicationOutboxRows(this, database);

  void _startLeaseHeartbeat(Database database) {
    _leaseHeartbeatTimer?.cancel();
    _leaseHeartbeatDatabase = database;
    _leaseHeartbeatTimer = Timer.periodic(
      writerLeaseHeartbeatInterval,
      (_) => unawaited(_heartbeatLease()),
    );
  }

  Future<void> _heartbeatLease() async {
    final database = _leaseHeartbeatDatabase ?? _database;
    if (_closed || database == null) return;
    try {
      // This direct transaction also works while open() is still replaying
      // rows and _database has not yet been published to public callers.
      await database.transaction((txn) async {
        await _assertWriterLease(txn, this);
      });
    } catch (_) {
      // A lost lease is surfaced by the next public mutation/readback.  The
      // timer must not create an unhandled asynchronous error while an app is
      // backgrounded or closing.
    }
  }

  Future<T> _trackRead<T>(Future<T> Function() operation) {
    _activeReads += 1;
    late Future<T> result;
    try {
      result = operation();
    } catch (_) {
      _finishRead();
      rethrow;
    }
    return result.whenComplete(_finishRead);
  }

  void _finishRead() {
    _activeReads -= 1;
    if (_activeReads == 0) {
      _readsDrained?.complete();
      _readsDrained = null;
    }
  }

  Future<void> _waitForReads() {
    if (_activeReads == 0) return Future<void>.value();
    return (_readsDrained ??= Completer<void>()).future;
  }

  /// A publication is delivered at least once.  A consumer must call this
  /// method with the [RepositoryWindow.publicationEventId] from its listener
  /// after it has durably consumed the event.  Calling it without a delivery
  /// or before a listener receives the event returns false and never marks the
  /// outbox row as notified.
  Future<bool> acknowledgePublication(String publicationEventId) {
    // During open() recovery the durable lease is held before _database is
    // exposed.  A synchronous stream listener may acknowledge that first
    // replay, so use the same leased handle for this one read/ack operation.
    final database = _database ?? _leaseHeartbeatDatabase;
    if (_closed || database == null) {
      _throwFailure(
        RepositoryFailureCode.notOpen,
        'open the repository before acknowledging a publication',
      );
    }
    _requireIdentity(
      publicationEventId,
      'publicationEventId',
      maxLength: maxPublicationEventIdLength,
    );
    Future<bool> acknowledgeOnDatabase() async {
      var acknowledged = false;
      await database.transaction((txn) async {
        await _assertWriterLease(txn, this);
        final rows = await txn.query(
          'publication_outbox',
          columns: const <String>['notification_state', 'delivery_token'],
          where: 'event_id = ?',
          whereArgs: <Object?>[publicationEventId],
          limit: 1,
        );
        if (rows.isEmpty) return;
        final state = rows.single['notification_state'];
        if (state == 'notified') {
          // Consumer acknowledgements are idempotent, including a duplicate
          // callback for an at-least-once replay.
          acknowledged = true;
          return;
        }
        if (state != 'delivering' ||
            rows.single['delivery_token'] != _ownerToken ||
            !_deliveredPublicationEvents.contains(publicationEventId)) {
          return;
        }
        final updated = await txn.update(
          'publication_outbox',
          const <String, Object?>{
            'notification_state': 'notified',
            'delivery_token': null,
            'delivery_claimed_at': null,
          },
          where:
              'event_id = ? AND notification_state = ? AND delivery_token = ?',
          whereArgs: <Object?>[publicationEventId, 'delivering', _ownerToken],
        );
        acknowledged = updated == 1;
      });
      if (acknowledged) _deliveredPublicationEvents.remove(publicationEventId);
      return acknowledged;
    }

    if (identical(database, _database)) {
      return _serialize((_) => acknowledgeOnDatabase());
    }
    return acknowledgeOnDatabase();
  }

  void _onUpdatesListen() {
    _schedulePublicationDrain();
  }

  void _schedulePublicationDrain() {
    if (_publicationDrainScheduled ||
        _closed ||
        _database == null ||
        !_updatesController.hasListener) {
      return;
    }
    _publicationDrainScheduled = true;
    scheduleMicrotask(() {
      _publicationDrainScheduled = false;
      unawaited(_drainPublicationOutbox());
    });
  }

  Future<void> _drainPublicationOutbox() async {
    if (_publicationDrainRunning ||
        _closed ||
        _database == null ||
        !_updatesController.hasListener) {
      return;
    }
    _publicationDrainRunning = true;
    try {
      await _recoverPublicationOutbox(_database!);
    } catch (_) {
      // The next listener/open or explicit retry rechecks the durable row. A
      // timer/drain callback must not become an unhandled app error.
    } finally {
      _publicationDrainRunning = false;
    }
  }

  void _rememberDeliveredPublication(String eventId) {
    if (_deliveredPublicationEvents.length >= _maxRememberedPublicationEvents) {
      _deliveredPublicationEvents.remove(_deliveredPublicationEvents.first);
    }
    _deliveredPublicationEvents.add(eventId);
  }
}
