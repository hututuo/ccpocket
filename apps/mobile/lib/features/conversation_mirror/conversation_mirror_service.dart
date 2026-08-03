// Public constructor labels intentionally stay `bridge`, `store`, and
// `database`; initializing formals would expose private names to callers.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/messages.dart';
import '../../services/bridge_service.dart';
import 'conversation_mirror_target.dart';
import 'storage/conversation_mirror_storage.dart';

class ConversationMirrorSyncResult {
  const ConversationMirrorSyncResult({
    required this.success,
    required this.changed,
    this.entryCount = 0,
    this.errorCode,
    this.error,
  });

  final bool success;
  final bool changed;
  final int entryCount;
  final String? errorCode;
  final String? error;
}

/// A dependency-neutral cancellation seam for bounded mirror work.
///
/// The mirror feature intentionally does not depend on iOS background task
/// types. Callers may adapt any lifecycle or deadline signal to this interface.
abstract interface class ConversationMirrorCancellation {
  bool get isCancelled;

  void addListener(VoidCallback listener);

  void removeListener(VoidCallback listener);
}

/// Coordinates the optional Bridge mirror protocol with an independent local
/// database. Canonical Codex/app-server history remains authoritative.
class ConversationMirrorService extends ChangeNotifier {
  ConversationMirrorService({
    required BridgeService bridge,
    required ConversationMirrorStore store,
    required ConversationMirrorDatabase database,
    Duration initialResponseTimeout = const Duration(seconds: 10),
  }) : _bridge = bridge,
       _store = store,
       _database = database,
       _initialResponseTimeout = initialResponseTimeout;

  static const _uuid = Uuid();
  // Bridge may need up to 100 bounded 15-second app-server page reads before
  // the first snapshot frame. This is an idle timeout and is re-armed by every
  // frame; socket disconnects still fail immediately.
  static const _requestIdleTimeout = Duration(minutes: 30);
  static const _bootstrapWatchTimeout = Duration(milliseconds: 2500);
  static const maxResidentConversations = 8;
  static const _initialRenderEntryCount = 200;
  static const _timestampAnchorScanLimit = 1000;
  static const _timestampAnchorBatchSize = 200;
  static const _maxBufferedEntryChunkBytes = 96 * 1024 * 1024;

  final BridgeService _bridge;
  final ConversationMirrorStore _store;
  final ConversationMirrorDatabase _database;
  final Duration _initialResponseTimeout;
  final Map<ConversationMirrorKey, ConversationMirrorMetadata> _metadata = {};
  final Map<String, _PendingMirrorRequest> _pending = {};
  final Map<ConversationMirrorKey, String> _watchRequestIds = {};
  final Map<String, String> _watchRequestIdsByConversation = {};
  final Map<ConversationMirrorKey, String> _resetRequestIds = {};
  final Map<String, int> _bootstrapGenerationByRuntime = {};
  final Map<String, _RuntimeMirrorPageCursor> _pageCursorsByRuntime = {};
  final Map<String, _MirrorTransferGuard> _transferGuardsByRequestId = {};
  final Map<String, _MirrorEntryChunkAssembly> _entryChunkAssemblies = {};
  final Set<String> _completedEntryChunkPages = {};
  final Set<String> _acceptedRequestIds = {};
  final Set<ConversationMirrorKey> _syncing = {};

  StreamSubscription<LocalFeatureServerMessage>? _localFeatureSub;
  StreamSubscription<PromptHistoryStatusMessage>? _bridgeIdentitySub;
  StreamSubscription<List<SessionInfo>>? _sessionListSub;
  StreamSubscription<BridgeConnectionState>? _connectionSub;
  Future<void> _storageSerial = Future<void>.value();
  String? _currentBridgeInstanceId;
  String? _currentCodexSourceId;
  bool _initialized = false;
  bool _closed = false;
  bool _storageAvailable = false;
  bool _featureUnsupported = false;
  bool _automaticWatchRestorationEnabled = true;
  String? _deferredAutoWatchBridgeInstanceId;

  String? get currentBridgeInstanceId =>
      _currentBridgeInstanceId ?? _bridge.promptHistoryBridgeId;
  String? get currentCodexSourceId => _currentCodexSourceId;

  bool get featureUnsupported => _featureUnsupported;
  bool get isAvailable => !_closed && !kIsWeb && _storageAvailable;

  ConversationMirrorKey _targetKey(
    String bridgeInstanceId,
    ConversationMirrorTarget target,
  ) => ConversationMirrorKey(
    bridgeInstanceId: bridgeInstanceId,
    provider: target.provider,
    providerSessionId: target.providerSessionId,
    codexSourceId: target.provider == Provider.codex.value
        ? (target.codexSourceId ?? currentCodexSourceId)
        : null,
  );

  ConversationMirrorKey _currentRuntimeKey({
    required String bridgeInstanceId,
    required String provider,
    required String providerSessionId,
  }) => ConversationMirrorKey(
    bridgeInstanceId: bridgeInstanceId,
    provider: provider,
    providerSessionId: providerSessionId,
    codexSourceId: provider == Provider.codex.value
        ? currentCodexSourceId
        : null,
  );

  bool _keyBelongsToCurrentSource(ConversationMirrorKey key) =>
      key.provider != Provider.codex.value ||
      key.codexSourceId == currentCodexSourceId;

  bool _targetBelongsToCurrentSource(ConversationMirrorTarget target) =>
      target.provider != Provider.codex.value ||
      target.codexSourceId == null ||
      target.codexSourceId == currentCodexSourceId;

  String? _wireCodexSourceId(ConversationMirrorKey? key) {
    if (!_bridge.bridgeCapabilities.contains(
      conversationMirrorSourceIdentityCapability,
    )) {
      return null;
    }
    return key?.provider == Provider.codex.value ? key?.codexSourceId : null;
  }

  /// Controls whether connection/identity adoption may recreate missing
  /// resident watches.
  ///
  /// Existing watches are intentionally left running. Background refresh
  /// disables only automatic recreation so a reconnect cannot unexpectedly
  /// start a large first snapshot inside iOS's short execution budget.
  Future<void> setAutomaticWatchRestorationEnabled(bool enabled) async {
    if (_closed) return;
    _automaticWatchRestorationEnabled = enabled;
    if (!enabled) return;
    await _enqueueStorage(_restoreDeferredAutoWatches);
  }

  List<ConversationMirrorMetadata> get residentMetadata {
    final result =
        _metadata.values
            .where((metadata) => metadata.autoSync && metadata.hasLocalCopy)
            .toList(growable: false)
          ..sort((a, b) {
            final aTime =
                a.lastSyncedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bTime =
                b.lastSyncedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            return bTime.compareTo(aTime);
          });
    return List.unmodifiable(result);
  }

  /// Every complete phone copy, including copies whose automatic watch is
  /// paused and copies belonging to another known Bridge installation.
  List<ConversationMirrorMetadata> get localCopyMetadata {
    final result =
        _metadata.values
            .where((metadata) => metadata.hasLocalCopy)
            .toList(growable: false)
          ..sort((a, b) {
            final aTime =
                a.lastSyncedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bTime =
                b.lastSyncedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            return bTime.compareTo(aTime);
          });
    return List.unmodifiable(result);
  }

  Future<void> initialize() async {
    if (_initialized || _closed) return;
    _initialized = true;
    _localFeatureSub = _bridge.localFeatureMessages.listen(_onLocalFeature);
    _bridgeIdentitySub = _bridge.promptHistoryStatus.listen((status) {
      unawaited(
        _enqueueStorage(
          () => _adoptBridgeIdentity(
            status.bridgeInstanceId,
            codexSourceId: _bridge.codexSourceId,
          ),
        ),
      );
    });
    _sessionListSub = _bridge.sessionList.listen((_) {
      final bridgeId = _bridge.bridgeInstanceId;
      if (bridgeId == null || bridgeId.isEmpty) return;
      final sourceId = _bridge.codexSourceId;
      unawaited(
        _enqueueStorage(
          () => _adoptBridgeIdentity(bridgeId, codexSourceId: sourceId),
        ),
      );
    });
    _connectionSub = _bridge.connectionStatus.listen((state) {
      if (state == BridgeConnectionState.connected) {
        _featureUnsupported = false;
        final bridgeId = _bridge.promptHistoryBridgeId;
        if (bridgeId != null && bridgeId.isNotEmpty) {
          final sourceId = _bridge.codexSourceId;
          unawaited(
            _enqueueStorage(
              () => _adoptBridgeIdentity(bridgeId, codexSourceId: sourceId),
            ),
          );
        }
        _notifyListeners();
      } else {
        _watchRequestIds.clear();
        for (final requestId in List<String>.from(_pending.keys)) {
          _finishPending(
            requestId,
            const ConversationMirrorSyncResult(
              success: false,
              changed: false,
              errorCode: 'bridge_disconnected',
              error: 'Bridge disconnected during conversation sync.',
            ),
          );
        }
        _acceptedRequestIds.clear();
        _resetRequestIds.clear();
        _watchRequestIdsByConversation.clear();
        _transferGuardsByRequestId.clear();
        _entryChunkAssemblies.clear();
        _completedEntryChunkPages.clear();
      }
    });
    _bridge.configureSessionHistoryBootstrap(_bootstrapRuntimeSession);
    _bridge.configureSessionHistoryPaging(
      loader: _loadOlderRuntimeHistory,
      windowLoader: _loadRuntimeHistoryWindow,
      hasMore: _hasOlderRuntimeHistory,
      available: _hasRuntimeHistory,
      invalidate: _removeRuntimePageCursor,
    );
    _bridge.configureSessionHistoryUserIndex(_loadRuntimeUserIndex);
    _bridge.configureSessionHistoryToolDetails(
      _loadRuntimeHistoryToolDetails,
    );
    if (kIsWeb) return;
    try {
      // Opening also removes interrupted shadow generations while preserving
      // the previous active copy.
      await _database.database;
      if (_closed) {
        await _database.close();
        return;
      }
      _storageAvailable = true;
      final localRecords = await _store.listLocalCopies();
      if (_closed) {
        await _database.close();
        return;
      }
      _metadata.addEntries(
        localRecords.map((record) => MapEntry(record.key, record)),
      );
      _notifyListeners();
      final bridgeId = _bridge.promptHistoryBridgeId;
      if (bridgeId != null && bridgeId.isNotEmpty) {
        await _enqueueStorage(
          () => _adoptBridgeIdentity(
            bridgeId,
            codexSourceId: _bridge.codexSourceId,
          ),
        );
      }
    } catch (error) {
      _storageAvailable = false;
      _notifyListeners();
      debugPrint('[conversation-mirror] database unavailable: $error');
    }
  }

  ConversationMirrorMetadata? cachedMetadataFor(
    RecentSession session, {
    String? bridgeInstanceId,
  }) => cachedMetadataForTarget(
    ConversationMirrorTarget.fromRecent(session),
    bridgeInstanceId: bridgeInstanceId,
  );

  ConversationMirrorMetadata? cachedMetadataForTarget(
    ConversationMirrorTarget target, {
    String? bridgeInstanceId,
  }) {
    final bridgeId = bridgeInstanceId ?? currentBridgeInstanceId;
    if (!isAvailable) return null;
    if (bridgeId == null) return _uniqueCachedMetadata(target);
    return _metadata[_targetKey(bridgeId, target)];
  }

  bool hasLocalCopy(RecentSession session) =>
      cachedMetadataFor(session)?.hasLocalCopy ?? false;

  bool hasLocalCopyTarget(ConversationMirrorTarget target) =>
      hasLocalCopy(target.toRecentSession());

  bool isResident(RecentSession session) =>
      cachedMetadataFor(session)?.autoSync == true;

  bool isResidentTarget(ConversationMirrorTarget target) =>
      isResident(target.toRecentSession());

  bool isSyncing(RecentSession session) =>
      _isSyncingTarget(ConversationMirrorTarget.fromRecent(session));

  bool isSyncingTarget(ConversationMirrorTarget target) =>
      isSyncing(target.toRecentSession());

  bool _isSyncingTarget(ConversationMirrorTarget target) {
    final bridgeId = currentBridgeInstanceId;
    if (bridgeId == null) {
      final metadata = _uniqueCachedMetadata(target);
      return metadata != null && _syncing.contains(metadata.key);
    }
    return _syncing.contains(_targetKey(bridgeId, target));
  }

  Future<ConversationMirrorMetadata?> metadataFor(RecentSession session) =>
      metadataForTarget(ConversationMirrorTarget.fromRecent(session));

  Future<ConversationMirrorMetadata?> metadataForTarget(
    ConversationMirrorTarget target,
  ) async {
    final bridgeId = currentBridgeInstanceId;
    if (!isAvailable) return null;
    if (bridgeId == null) {
      final cached = _uniqueCachedMetadata(target);
      if (cached != null) return cached;
      final unique = await _store.findUniqueLocalCopy(
        target.provider,
        target.providerSessionId,
        projectPath: target.effectiveProjectPath,
        codexSourceId: target.codexSourceId,
      );
      if (unique != null) _metadata[unique.key] = unique;
      return unique;
    }
    final key = _targetKey(bridgeId, target);
    final cached = _metadata[key];
    if (cached != null) return cached;
    final loaded = await _store.readMetadata(key);
    if (loaded != null) _metadata[key] = loaded;
    return loaded;
  }

  /// Performs a bounded one-shot reconciliation of resident conversations.
  ///
  /// Foreground callers may restore a missing watch. Background refresh callers
  /// must set [restoreMissingWatches] to false so a disconnected watch cannot
  /// unexpectedly turn into a large first snapshot inside iOS's short task
  /// budget.
  Future<int> reconcileResidents({
    int maximumConversations = maxResidentConversations,
    Duration budget = const Duration(seconds: 12),
    bool restoreMissingWatches = true,
    ConversationMirrorCancellation? cancellation,
  }) async {
    if (!isAvailable ||
        !_bridge.isConnected ||
        _closed ||
        cancellation?.isCancelled == true ||
        maximumConversations <= 0 ||
        budget <= Duration.zero) {
      return 0;
    }
    final bridgeId = currentBridgeInstanceId;
    if (bridgeId == null || bridgeId.isEmpty) return 0;
    final deadline = DateTime.now().add(budget);
    final operationCancellation = _ConversationMirrorDeadlineCancellation(
      parent: cancellation,
      budget: budget,
    );
    final records = residentMetadata
        .where(
          (record) =>
              record.key.bridgeInstanceId == bridgeId &&
              _keyBelongsToCurrentSource(record.key),
        )
        .take(math.min(maximumConversations, maxResidentConversations))
        .toList(growable: false);
    var completed = 0;
    try {
      for (final record in records) {
        if (_closed ||
            !_bridge.isConnected ||
            _featureUnsupported ||
            operationCancellation.isCancelled) {
          break;
        }
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) break;

        final logicalKey = _logicalWatchKey(
          record.key.provider,
          record.key.providerSessionId,
          record.key.codexSourceId,
        );
        final existingRequestId =
            _watchRequestIdsByConversation[logicalKey] ??
            _watchRequestIds[record.key];
        final existingWasPending =
            existingRequestId != null &&
            _pending.containsKey(existingRequestId);
        final existing = _existingWatch(
          provider: record.key.provider,
          providerSessionId: record.key.providerSessionId,
          key: record.key,
          entryCount: record.entryCount,
        );
        final Future<ConversationMirrorSyncResult>? operation;
        if (existing == null) {
          operation = restoreMissingWatches
              ? _ensureWatch(
                  record.key,
                  projectPath: record.projectPath,
                  knownRevision: record.revision,
                )
              : null;
        } else if (existingWasPending && restoreMissingWatches) {
          operation = existing;
        } else if (existingWasPending) {
          operation = null;
        } else {
          operation = _requestKeySync(
            record.key,
            projectPath: record.projectPath,
            knownRevision: record.revision,
            cancellation: operationCancellation,
          );
        }
        if (operation == null) continue;
        try {
          final result = await operation.timeout(remaining);
          if (result.success) completed++;
        } on TimeoutException {
          operationCancellation.cancel();
          break;
        }
      }
      return completed;
    } finally {
      operationCancellation.dispose();
    }
  }

  ConversationMirrorMetadata? _uniqueCachedMetadata(
    ConversationMirrorTarget target,
  ) {
    final candidates = _metadata.values
        .where(
          (metadata) =>
              metadata.hasLocalCopy &&
              metadata.key.provider == target.provider &&
              metadata.key.providerSessionId == target.providerSessionId &&
              metadata.key.codexSourceId == target.codexSourceId,
        )
        .take(2)
        .toList(growable: false);
    if (candidates.length != 1) return null;
    final unique = candidates.single;
    final sessionProjectPath = target.effectiveProjectPath;
    if (sessionProjectPath.isNotEmpty &&
        unique.projectPath != sessionProjectPath) {
      return null;
    }
    return unique;
  }

  Future<ConversationMirrorSyncResult> downloadAndWatch(
    RecentSession session,
  ) => _makeResidentTarget(ConversationMirrorTarget.fromRecent(session));

  Future<ConversationMirrorSyncResult> makeResidentTarget(
    ConversationMirrorTarget target,
  ) => downloadAndWatch(target.toRecentSession());

  Future<ConversationMirrorSyncResult> _makeResidentTarget(
    ConversationMirrorTarget target,
  ) async {
    if (target.provider != Provider.codex.value) {
      return const ConversationMirrorSyncResult(
        success: false,
        changed: false,
        errorCode: 'unsupported_provider',
        error: 'Only Codex conversations are supported.',
      );
    }
    final existing = await metadataForTarget(target);
    if (existing?.autoSync != true) {
      final bridgeId = currentBridgeInstanceId;
      final activeResidents = residentMetadata.where(
        (metadata) =>
            (bridgeId == null || metadata.key.bridgeInstanceId == bridgeId) &&
            _keyBelongsToCurrentSource(metadata.key),
      );
      if (activeResidents.length >= maxResidentConversations) {
        return const ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: 'resident_limit_reached',
          error: 'At most 8 conversations can stay resident at once.',
        );
      }
    }
    if (existing?.hasLocalCopy == true && !_bridge.isConnected) {
      await _enqueueStorage(() async {
        await _store.setAutoSync(
          existing!.key,
          true,
          projectPath: target.effectiveProjectPath,
          displayName: target.name,
          summary: target.summary,
          firstPrompt: target.firstPrompt,
        );
        await _refreshMetadata(existing.key);
      });
      _notifyListeners();
      return ConversationMirrorSyncResult(
        success: true,
        changed: false,
        entryCount: existing!.entryCount,
      );
    }
    return _requestTargetSync(
      target,
      watch: true,
      force: existing?.hasLocalCopy != true,
    );
  }

  Future<ConversationMirrorSyncResult> syncNow(RecentSession session) =>
      _syncTargetNow(ConversationMirrorTarget.fromRecent(session));

  Future<ConversationMirrorSyncResult> syncTargetNow(
    ConversationMirrorTarget target,
  ) => syncNow(target.toRecentSession());

  Future<ConversationMirrorSyncResult> _syncTargetNow(
    ConversationMirrorTarget target,
  ) => _requestTargetSync(target, watch: false, force: false);

  Future<void> stopBeingResident(RecentSession session) =>
      _stopBeingResidentTarget(ConversationMirrorTarget.fromRecent(session));

  Future<void> stopBeingResidentTarget(ConversationMirrorTarget target) =>
      stopBeingResident(target.toRecentSession());

  Future<void> _stopBeingResidentTarget(ConversationMirrorTarget target) async {
    if (!isAvailable) return;
    final metadata = await metadataForTarget(target);
    if (metadata == null || !metadata.autoSync) return;
    _cancelTargetRequests(
      metadata.key,
      errorCode: 'residency_disabled',
      error: 'Conversation residency was disabled.',
    );
    await _enqueueStorage(() async {
      await _store.setAutoSync(
        metadata.key,
        false,
        projectPath: target.effectiveProjectPath,
        displayName: target.name,
        summary: target.summary,
        firstPrompt: target.firstPrompt,
      );
      await _refreshMetadata(metadata.key);
    });
    _notifyListeners();
  }

  Future<void> removeLocalCopy(RecentSession session) =>
      _removeLocalCopyTarget(ConversationMirrorTarget.fromRecent(session));

  Future<void> removeLocalCopyTarget(ConversationMirrorTarget target) =>
      removeLocalCopy(target.toRecentSession());

  Future<void> _removeLocalCopyTarget(ConversationMirrorTarget target) async {
    if (!isAvailable) return;
    final metadata = await metadataForTarget(target);
    final bridgeId = currentBridgeInstanceId;
    final key =
        metadata?.key ??
        (bridgeId == null ? null : _targetKey(bridgeId, target));
    if (key == null) return;
    await removeLocalCopyByKey(key);
  }

  /// Removes an exact cached copy selected from storage management.
  ///
  /// Unlike a target-only removal, the key keeps two Bridge installations
  /// with the same provider thread ID isolated.
  Future<void> removeLocalCopyByKey(ConversationMirrorKey key) async {
    if (!isAvailable) return;
    _cancelTargetRequests(
      key,
      errorCode: 'local_copy_removed',
      error: 'The local conversation copy was removed.',
    );
    await _enqueueStorage(() async {
      await _store.deleteLocalCopy(key);
      _metadata.remove(key);
      _syncing.remove(key);
      _removeRuntimePageCursorsWhere((cursor) => cursor.key == key);
    });
    _notifyListeners();
  }

  void _cancelTargetRequests(
    ConversationMirrorKey key, {
    required String errorCode,
    required String error,
  }) {
    final watchRequestId =
        _watchRequestIdsByConversation[_logicalWatchKey(
          key.provider,
          key.providerSessionId,
          key.codexSourceId,
        )] ??
        _watchRequestIds[key];
    final pendingToCancel = _pending.values
        .where(
          (request) =>
              request.provider == key.provider &&
              request.providerSessionId == key.providerSessionId &&
              request.codexSourceId == key.codexSourceId,
        )
        .toList(growable: false);
    final ownerIsPending = pendingToCancel.any(
      (request) => request.requestId == watchRequestId,
    );
    for (final request in pendingToCancel) {
      _finishPending(
        request.requestId,
        ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: errorCode,
          error: error,
        ),
      );
    }
    if (watchRequestId != null && !ownerIsPending) {
      _stopWatchForRequest(
        key: key,
        requestId: watchRequestId,
        provider: key.provider,
        providerSessionId: key.providerSessionId,
      );
    }
  }

  Future<ConversationMirrorSyncResult> _requestTargetSync(
    ConversationMirrorTarget target, {
    required bool watch,
    required bool force,
  }) async {
    if (kIsWeb) {
      return const ConversationMirrorSyncResult(
        success: false,
        changed: false,
        errorCode: 'unsupported_platform',
        error: 'Local conversation mirrors are unavailable on web.',
      );
    }
    if (!_storageAvailable) {
      return const ConversationMirrorSyncResult(
        success: false,
        changed: false,
        errorCode: 'local_storage_unavailable',
        error: 'Local conversation mirror storage is unavailable.',
      );
    }
    if (!_bridge.isConnected) {
      return const ConversationMirrorSyncResult(
        success: false,
        changed: false,
        errorCode: 'bridge_disconnected',
        error: 'Bridge is disconnected.',
      );
    }
    if (!_targetBelongsToCurrentSource(target)) {
      return const ConversationMirrorSyncResult(
        success: false,
        changed: false,
        errorCode: 'codex_source_mismatch',
        error: 'This conversation belongs to a different Codex source.',
      );
    }
    final existing = await metadataForTarget(target);
    final currentBridgeId = currentBridgeInstanceId;
    final effectiveCodexSourceId = target.provider == Provider.codex.value
        ? (target.codexSourceId ?? currentCodexSourceId)
        : null;
    final pendingKey =
        existing?.key ??
        (currentBridgeId == null ? null : _targetKey(currentBridgeId, target));
    final requestId = _uuid.v4();
    final logicalWatchKey = _logicalWatchKey(
      target.provider,
      target.providerSessionId,
      effectiveCodexSourceId,
    );
    if (watch) {
      final existingWatch = _existingWatch(
        provider: target.provider,
        providerSessionId: target.providerSessionId,
        key: pendingKey,
        codexSourceId: effectiveCodexSourceId,
        entryCount: existing?.entryCount ?? 0,
      );
      if (existingWatch != null) return existingWatch;
    }
    final pending = _PendingMirrorRequest(
      requestId: requestId,
      provider: target.provider,
      providerSessionId: target.providerSessionId,
      codexSourceId: effectiveCodexSourceId,
      projectPath: target.effectiveProjectPath,
      key: pendingKey,
      autoSync: watch || (existing?.autoSync ?? false),
      createsWatch: watch,
      previousEntryCount: existing?.entryCount ?? 0,
      previousRevision: existing?.revision,
      displayName: target.name,
      summary: target.summary,
      firstPrompt: target.firstPrompt,
    );
    if (watch) {
      _watchRequestIdsByConversation[logicalWatchKey] = requestId;
      if (pendingKey != null) _watchRequestIds[pendingKey] = requestId;
    }
    _registerPending(pending);
    if (pendingKey != null) _syncing.add(pendingKey);
    _notifyListeners();
    try {
      _bridge.send(
        watch
            ? requestConversationMirrorWatch(
                requestId: requestId,
                provider: pending.provider,
                providerSessionId: pending.providerSessionId,
                projectPath: pending.projectPath,
                knownRevision: force ? null : existing?.revision,
                codexSourceId: _wireCodexSourceId(pending.key),
              )
            : requestConversationMirrorSync(
                requestId: requestId,
                provider: pending.provider,
                providerSessionId: pending.providerSessionId,
                projectPath: pending.projectPath,
                knownRevision: force ? null : existing?.revision,
                codexSourceId: _wireCodexSourceId(pending.key),
              ),
      );
    } catch (error) {
      _finishPending(
        requestId,
        ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: 'bridge_disconnected',
          error: '$error',
        ),
      );
    }
    return pending.completer.future;
  }

  Future<bool> _bootstrapRuntimeSession({
    required String runtimeSessionId,
    required String? provider,
    required String? providerSessionId,
    required String? projectPath,
    required bool force,
  }) async {
    final bootstrapGeneration =
        (_bootstrapGenerationByRuntime[runtimeSessionId] ?? 0) + 1;
    _bootstrapGenerationByRuntime[runtimeSessionId] = bootstrapGeneration;
    _removeRuntimePageCursor(runtimeSessionId);
    if (!isAvailable || provider != Provider.codex.value) return false;
    final bridgeId = currentBridgeInstanceId;
    if (providerSessionId == null) return false;
    final strictKey = bridgeId == null
        ? null
        : _currentRuntimeKey(
            bridgeInstanceId: bridgeId,
            provider: provider!,
            providerSessionId: providerSessionId,
          );
    final metadata = strictKey == null
        ? await _store.findUniqueLocalCopy(
            provider!,
            providerSessionId,
            projectPath: projectPath,
            codexSourceId: currentCodexSourceId,
          )
        : await _store.readMetadata(strictKey);
    if (metadata == null || !metadata.hasLocalCopy) return false;
    final key = metadata.key;
    _metadata[key] = metadata;

    // Always establish the durable paging cursor. A list-level continuity
    // snapshot may have filled the bounded runtime cache before this screen
    // opens; that cache is merged into the local render window below instead
    // of disabling access to the rest of the downloaded conversation.
    final publishGuard = _captureRuntimePublishGuard(
      key,
      runtimeSessionId,
      expectedBridgeInstanceId: currentBridgeInstanceId,
    );
    if (publishGuard == null) return false;
    final published = await _publishKeyToRuntime(key, publishGuard);
    if (published == _MirrorPublishResult.invalidated) return false;
    if (published == _MirrorPublishResult.contentChanged &&
        _publishIdentityMatches(key, publishGuard)) {
      // The durable cursor is already usable, but replacing the visible live
      // tail would race a newer canonical event. Reconcile that tail through
      // the ordinary Bridge history path without discarding local paging.
      _bridge.requestSessionHistory(runtimeSessionId);
    }

    if (!_bridge.isConnected) return true;
    final effectiveProjectPath = projectPath ?? metadata.projectPath;
    final alreadyWatching = _watchRequestIds.containsKey(key);
    final watchFuture = _ensureWatch(
      key,
      projectPath: effectiveProjectPath,
      knownRevision: metadata.revision,
    );
    final reconciliation = force && alreadyWatching
        ? _requestKeySync(
            key,
            projectPath: effectiveProjectPath,
            knownRevision: metadata.revision,
          )
        : watchFuture;
    try {
      final result = await reconciliation.timeout(_bootstrapWatchTimeout);
      return result.success;
    } on TimeoutException {
      // The durable local copy is already usable. The existing ChatSession
      // status timer performs a bounded Bridge-history fallback if startup
      // remains unresolved.
      return true;
    }
  }

  Future<ConversationMirrorSyncResult> _ensureWatch(
    ConversationMirrorKey key, {
    required String projectPath,
    String? knownRevision,
  }) {
    final existingWatch = _existingWatch(
      provider: key.provider,
      providerSessionId: key.providerSessionId,
      key: key,
      entryCount: _metadata[key]?.entryCount ?? 0,
    );
    if (existingWatch != null) return existingWatch;
    final requestId = _uuid.v4();
    final pending = _PendingMirrorRequest(
      requestId: requestId,
      provider: key.provider,
      providerSessionId: key.providerSessionId,
      codexSourceId: key.codexSourceId,
      projectPath: projectPath,
      key: key,
      autoSync: true,
      createsWatch: true,
      previousEntryCount: _metadata[key]?.entryCount ?? 0,
      previousRevision: _metadata[key]?.revision,
    );
    _watchRequestIds[key] = requestId;
    _watchRequestIdsByConversation[_logicalWatchKey(
          key.provider,
          key.providerSessionId,
          key.codexSourceId,
        )] =
        requestId;
    _registerPending(pending);
    try {
      _bridge.send(
        requestConversationMirrorWatch(
          requestId: requestId,
          provider: key.provider,
          providerSessionId: key.providerSessionId,
          projectPath: projectPath,
          knownRevision: knownRevision,
          codexSourceId: _wireCodexSourceId(key),
        ),
      );
    } catch (error) {
      _finishPending(
        requestId,
        ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: 'bridge_disconnected',
          error: '$error',
        ),
      );
    }
    return pending.completer.future;
  }

  Future<ConversationMirrorSyncResult> _requestKeySync(
    ConversationMirrorKey key, {
    required String projectPath,
    String? knownRevision,
    ConversationMirrorCancellation? cancellation,
  }) {
    if (cancellation?.isCancelled == true) {
      return Future.value(
        const ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: 'cancelled',
          error: 'Conversation mirror reconciliation was cancelled.',
        ),
      );
    }
    final requestId = _uuid.v4();
    final pending = _PendingMirrorRequest(
      requestId: requestId,
      provider: key.provider,
      providerSessionId: key.providerSessionId,
      codexSourceId: key.codexSourceId,
      projectPath: projectPath,
      key: key,
      autoSync: _metadata[key]?.autoSync ?? true,
      createsWatch: false,
      previousEntryCount: _metadata[key]?.entryCount ?? 0,
      previousRevision: _metadata[key]?.revision,
    );
    _registerPending(pending);
    _syncing.add(key);
    _notifyListeners();
    void cancelPending() {
      _finishPending(
        requestId,
        const ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: 'cancelled',
          error: 'Conversation mirror reconciliation was cancelled.',
        ),
      );
    }

    cancellation?.addListener(cancelPending);
    try {
      if (!pending.completer.isCompleted) {
        _bridge.send(
          requestConversationMirrorSync(
            requestId: requestId,
            provider: key.provider,
            providerSessionId: key.providerSessionId,
            projectPath: projectPath,
            knownRevision: knownRevision,
            codexSourceId: _wireCodexSourceId(key),
          ),
        );
      }
    } catch (error) {
      _finishPending(
        requestId,
        ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: 'bridge_disconnected',
          error: '$error',
        ),
      );
    }
    return pending.completer.future.whenComplete(() {
      cancellation?.removeListener(cancelPending);
    });
  }

  void _registerPending(_PendingMirrorRequest request) {
    _pending[request.requestId] = request;
    _acceptedRequestIds.add(request.requestId);
    _armPendingTimeout(
      request,
      timeout: _initialResponseTimeout,
      waitingForAcceptance: true,
    );
  }

  void _armPendingTimeout(
    _PendingMirrorRequest request, {
    Duration timeout = _requestIdleTimeout,
    bool waitingForAcceptance = false,
  }) {
    request.timer?.cancel();
    request.timer = Timer(timeout, () {
      final capabilityNotNegotiated =
          waitingForAcceptance && !request.acceptedByBridge;
      if (capabilityNotNegotiated) _featureUnsupported = true;
      _finishPending(
        request.requestId,
        ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: capabilityNotNegotiated
              ? 'capability_not_negotiated'
              : 'timeout',
          error: capabilityNotNegotiated
              ? 'The connected Bridge did not acknowledge conversation mirror v1.'
              : 'Conversation mirror request timed out.',
        ),
      );
    });
  }

  void _onLocalFeature(LocalFeatureServerMessage message) {
    if (message is ConversationMirrorEntryChunkMessage) {
      if (!_acceptedRequestIds.contains(message.requestId)) return;
      final pending = _pending[message.requestId];
      if (pending != null) {
        pending.acceptedByBridge = true;
        _armPendingTimeout(pending);
      }
      unawaited(_enqueueStorage(() => _handleEntryChunk(message)));
      return;
    }
    if (message is ConversationMirrorEventMessage) {
      if (!_acceptedRequestIds.contains(message.requestId)) return;
      if (message.malformedEntryCount > 0 ||
          message.malformedDeleteCount > 0) {
        // Keep diagnostics bounded and privacy-safe: never include the
        // malformed item, path, or provider thread identity.
        debugPrint(
          '[conversation-mirror] dropped malformed inline items '
          '(entries=${message.malformedEntryCount}, '
          'deletes=${message.malformedDeleteCount})',
        );
      }
      if (message.event == ConversationMirrorEventKind.accepted) {
        // Capture before the storage queue or any await. `accepted` marks the
        // provider-read boundary for this transfer, so later canonical content
        // must win if its epoch changes while the mirror is being persisted.
        _transferGuardsByRequestId[message.requestId] = _captureTransferGuard(
          message,
          providerReadGuarded: true,
        );
      } else if ((message.event == ConversationMirrorEventKind.snapshotBegin ||
              message.event == ConversationMirrorEventKind.patch ||
              message.event == ConversationMirrorEventKind.snapshotComplete) &&
          !_transferGuardsByRequestId.containsKey(message.requestId)) {
        // Compatibility with an earlier mirror-capable Bridge that predates
        // repeated `accepted` frames. This guards the local write window, but
        // not the earlier provider read, so active runtimes must converge via
        // canonical history instead of publishing this mirror directly.
        _transferGuardsByRequestId[message.requestId] = _captureTransferGuard(
          message,
          providerReadGuarded: false,
        );
      }
      final pending = _pending[message.requestId];
      if (pending != null) {
        pending.acceptedByBridge = true;
        _armPendingTimeout(pending);
      }
      unawaited(_enqueueStorage(() => _handleMirrorEvent(message)));
      return;
    }
    if (message is LocalFeatureRequestErrorMessage &&
        message.featureId == 'conversation_mirror') {
      final requestId = message.requestId;
      if (requestId == null || !_acceptedRequestIds.contains(requestId)) return;
      final explicitCapabilityRejection =
          message.errorCode == 'unsupported_message' ||
          message.errorCode == 'unsupported_capability';
      final genericCapabilityRejection =
          message.message.toLowerCase().contains(
            message.requestType.toLowerCase(),
          ) &&
          RegExp(
            r'\b(unknown|unsupported|unrecognized)\b|not supported|invalid message type',
          ).hasMatch(message.message.toLowerCase());
      final capabilityRejected =
          explicitCapabilityRejection || genericCapabilityRejection;
      _featureUnsupported = capabilityRejected;
      _finishPending(
        requestId,
        ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: genericCapabilityRejection
              ? 'capability_not_negotiated'
              : message.errorCode ?? 'unsupported',
          error: message.message,
        ),
      );
      _notifyListeners();
    }
  }

  Future<void> _enqueueStorage(Future<void> Function() operation) {
    final result = _storageSerial.then((_) => operation());
    _storageSerial = result.catchError((error) {
      debugPrint('[conversation-mirror] storage event failed: $error');
    });
    return result;
  }

  ConversationMirrorKey _incomingMirrorKey({
    required String requestId,
    required String bridgeInstanceId,
    required String provider,
    required String providerSessionId,
  }) {
    final pending = _pending[requestId];
    ConversationMirrorKey? watchKey;
    if (pending == null) {
      for (final entry in _watchRequestIds.entries) {
        if (entry.value == requestId) {
          watchKey = entry.key;
          break;
        }
      }
    }
    return ConversationMirrorKey(
      bridgeInstanceId: bridgeInstanceId,
      provider: provider,
      providerSessionId: providerSessionId,
      codexSourceId: provider == Provider.codex.value
          ? (pending?.codexSourceId ??
                watchKey?.codexSourceId ??
                currentCodexSourceId)
          : null,
    );
  }

  Future<void> _handleMirrorEvent(ConversationMirrorEventMessage event) async {
    if (!_acceptedRequestIds.contains(event.requestId)) return;
    final key = _incomingMirrorKey(
      requestId: event.requestId,
      bridgeInstanceId: event.bridgeInstanceId,
      provider: event.provider,
      providerSessionId: event.providerSessionId,
    );
    final pending = _pending[event.requestId];
    if (pending != null &&
        (pending.provider != event.provider ||
            pending.providerSessionId != event.providerSessionId)) {
      _finishPending(
        event.requestId,
        const ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: 'response_identity_mismatch',
          error: 'Bridge returned a different conversation for this request.',
        ),
      );
      return;
    }
    if (pending == null) {
      ConversationMirrorKey? ownedWatchKey;
      for (final entry in _watchRequestIds.entries) {
        if (entry.value == event.requestId) {
          ownedWatchKey = entry.key;
          break;
        }
      }
      if (ownedWatchKey != key) return;
    }
    _currentBridgeInstanceId = event.bridgeInstanceId;
    _featureUnsupported = false;
    if (pending != null) _adoptPendingEventKey(pending, key);
    final generation = _generation(event);
    try {
      switch (event.event) {
        case ConversationMirrorEventKind.accepted:
          break;
        case ConversationMirrorEventKind.probe:
          _finishPending(
            event.requestId,
            ConversationMirrorSyncResult(
              success: true,
              changed: event.notModified == false,
              entryCount: event.entryCount ?? 0,
            ),
          );
          break;
        case ConversationMirrorEventKind.snapshotBegin:
          _clearEntryChunksForRequest(event.requestId);
          await _store.beginShadowGeneration(
            key: key,
            generation: generation,
            revision: event.revision!,
            entryCount: event.entryCount!,
            pageCount: event.pageCount!,
            totalBytes: event.totalBytes!,
            autoSync: pending?.autoSync,
            projectPath: pending?.projectPath,
            displayName: pending?.displayName,
            summary: pending?.summary,
            firstPrompt: pending?.firstPrompt,
          );
          if (pending != null) pending.shadowGeneration = generation;
          break;
        case ConversationMirrorEventKind.snapshotPage:
          await _store.appendShadowPage(
            key: key,
            generation: generation,
            pageIndex: event.pageIndex!,
            pageCount: event.pageCount!,
            entries: event.entries.map(_entryInput).toList(growable: false),
          );
          break;
        case ConversationMirrorEventKind.snapshotComplete:
          if (_entryChunkAssemblies.values.any(
            (assembly) =>
                assembly.requestId == event.requestId &&
                assembly.revision == event.revision,
          )) {
            throw const ConversationMirrorValidationException(
              'Mirror snapshot completed with an incomplete entry chunk.',
            );
          }
          final metadata = await _store.completeShadowGeneration(
            key: key,
            generation: generation,
            revision: event.revision!,
            entryCount: event.entryCount!,
          );
          if (pending?.autoSync == true && !metadata.autoSync) {
            await _store.setAutoSync(
              key,
              true,
              projectPath: pending?.projectPath,
              displayName: pending?.displayName,
              summary: pending?.summary,
              firstPrompt: pending?.firstPrompt,
            );
          }
          await _refreshMetadata(key);
          await _publishTransferToBoundRuntimes(
            key,
            _transferGuardsByRequestId[event.requestId],
          );
          _finishPending(
            event.requestId,
            ConversationMirrorSyncResult(
              success: true,
              changed:
                  pending?.previousRevision != event.revision ||
                  pending?.previousEntryCount != event.entryCount,
              entryCount: event.entryCount!,
            ),
          );
          break;
        case ConversationMirrorEventKind.patch:
          if (event.malformedEntryCount > 0 ||
              event.malformedDeleteCount > 0) {
            // A patch revision covers the complete mutation set. Applying
            // only the surviving items would advance the local revision while
            // silently losing the dropped mutations, so fail closed and
            // rebuild from a complete snapshot instead.
            _finishPending(
              event.requestId,
              const ConversationMirrorSyncResult(
                success: false,
                changed: false,
                errorCode: 'malformed_items',
                error: 'Mirror patch contained malformed inline items.',
              ),
            );
            await _requestSnapshotReset(key, pending?.projectPath);
            break;
          }
          final result = await _store.applyPatch(
            key: key,
            baseRevision: event.baseRevision!,
            revision: event.revision!,
            upserts: event.entries.map(_entryInput).toList(growable: false),
            deletes: event.deletes,
          );
          if (!result.applied) {
            await _requestSnapshotReset(key, pending?.projectPath);
            break;
          }
          await _refreshMetadata(key);
          await _publishTransferToBoundRuntimes(
            key,
            _transferGuardsByRequestId[event.requestId],
            onlyIfCursorStale:
                event.entries.isEmpty && event.deletes.isEmpty,
          );
          _finishPending(
            event.requestId,
            ConversationMirrorSyncResult(
              success: true,
              changed: event.entries.isNotEmpty || event.deletes.isNotEmpty,
              entryCount: _metadata[key]?.entryCount ?? 0,
            ),
          );
          break;
        case ConversationMirrorEventKind.notModified:
          if (pending?.autoSync == true) {
            await _store.setAutoSync(
              key,
              true,
              projectPath: pending?.projectPath,
              displayName: pending?.displayName,
              summary: pending?.summary,
              firstPrompt: pending?.firstPrompt,
            );
          }
          await _refreshMetadata(key);
          await _publishTransferToBoundRuntimes(
            key,
            _transferGuardsByRequestId[event.requestId],
            onlyIfCursorStale: true,
          );
          _finishPending(
            event.requestId,
            ConversationMirrorSyncResult(
              success: true,
              changed: false,
              entryCount: _metadata[key]?.entryCount ?? 0,
            ),
          );
          break;
        case ConversationMirrorEventKind.watching:
          _watchRequestIds[key] = event.requestId;
          break;
        case ConversationMirrorEventKind.unwatched:
          _watchRequestIds.remove(key);
          _finishPending(
            event.requestId,
            ConversationMirrorSyncResult(
              success: true,
              changed: false,
              entryCount: _metadata[key]?.entryCount ?? 0,
            ),
          );
          break;
        case ConversationMirrorEventKind.error:
          await _store.setSyncError(
            key,
            event.error,
            projectPath: pending?.projectPath,
          );
          await _refreshMetadata(key);
          _stopWatchForRequest(
            key: key,
            requestId: event.requestId,
            provider: event.provider,
            providerSessionId: event.providerSessionId,
          );
          _finishPending(
            event.requestId,
            ConversationMirrorSyncResult(
              success: false,
              changed: false,
              errorCode: event.errorCode,
              error: event.error,
            ),
          );
          break;
        case ConversationMirrorEventKind.unknown:
          break;
      }
    } on ConversationMirrorSnapshotConflictException {
      await _refreshMetadata(key);
      _finishPending(
        event.requestId,
        ConversationMirrorSyncResult(
          success: true,
          changed: true,
          entryCount: _metadata[key]?.entryCount ?? 0,
        ),
      );
      await _requestSnapshotReset(key, pending?.projectPath);
    } catch (error) {
      try {
        await _store.setSyncError(
          key,
          '$error',
          projectPath: pending?.projectPath,
        );
        await _refreshMetadata(key);
      } catch (recordError) {
        debugPrint(
          '[conversation-mirror] could not persist sync error: $recordError',
        );
      }
      _stopWatchForRequest(
        key: key,
        requestId: event.requestId,
        provider: event.provider,
        providerSessionId: event.providerSessionId,
      );
      _finishPending(
        event.requestId,
        ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: 'local_storage_failed',
          error: '$error',
        ),
      );
    }
    if (_isTransferTerminal(event.event)) {
      _clearEntryChunksForRequest(event.requestId);
      _transferGuardsByRequestId.remove(event.requestId);
    }
    // Snapshot pages only populate an invisible staging generation. Nothing
    // observable changes until snapshotComplete atomically promotes it, so
    // rebuilding every Home badge for every page is pure UI work.
    if (event.event != ConversationMirrorEventKind.snapshotPage) {
      _notifyListeners();
    }
  }

  ConversationMirrorEntryInput _entryInput(ConversationMirrorWireEntry entry) =>
      ConversationMirrorEntryInput(
        entryId: entry.entryId,
        ordinal: entry.index,
        contentHash: entry.contentHash,
        message: entry.rawMessage,
      );

  Future<void> _handleEntryChunk(
    ConversationMirrorEntryChunkMessage chunk,
  ) async {
    if (!_acceptedRequestIds.contains(chunk.requestId)) return;
    final key = _incomingMirrorKey(
      requestId: chunk.requestId,
      bridgeInstanceId: chunk.bridgeInstanceId,
      provider: chunk.provider,
      providerSessionId: chunk.providerSessionId,
    );
    final pending = _pending[chunk.requestId];
    if (pending != null &&
        (pending.provider != chunk.provider ||
            pending.providerSessionId != chunk.providerSessionId)) {
      _finishPending(
        chunk.requestId,
        const ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: 'response_identity_mismatch',
          error: 'Bridge returned a different conversation for this request.',
        ),
      );
      return;
    }
    if (pending == null) {
      ConversationMirrorKey? ownedWatchKey;
      for (final entry in _watchRequestIds.entries) {
        if (entry.value == chunk.requestId) {
          ownedWatchKey = entry.key;
          break;
        }
      }
      if (ownedWatchKey != key) return;
    }
    if (pending != null) _adoptPendingEventKey(pending, key);
    _currentBridgeInstanceId = chunk.bridgeInstanceId;
    final assemblyKey = _entryChunkAssemblyKey(chunk);
    if (_completedEntryChunkPages.contains(assemblyKey)) return;
    try {
      final bytes = base64Decode(chunk.payloadBase64);
      if (bytes.isEmpty || bytes.length > 256 * 1024) {
        throw const ConversationMirrorValidationException(
          'Mirror entry chunk has an invalid decoded size.',
        );
      }
      final assembly = _entryChunkAssemblies.putIfAbsent(
        assemblyKey,
        () => _MirrorEntryChunkAssembly.fromMessage(chunk),
      );
      assembly.validateMetadata(chunk);
      final additionalBytes = assembly.hasChunk(chunk.chunkIndex)
          ? 0
          : bytes.length;
      final bufferedBytes = _entryChunkAssemblies.values.fold<int>(
        0,
        (total, candidate) => total + candidate.receivedBytes,
      );
      if (bufferedBytes + additionalBytes > _maxBufferedEntryChunkBytes) {
        throw const ConversationMirrorValidationException(
          'Mirror entry chunks exceed the in-memory transfer limit.',
        );
      }
      assembly.addChunk(chunk.chunkIndex, bytes);
      if (!assembly.isComplete) return;

      final messageBytes = assembly.join();
      if (messageBytes.length != chunk.totalBytes ||
          sha256.convert(messageBytes).toString() != chunk.contentHash) {
        throw const ConversationMirrorValidationException(
          'Reassembled mirror entry failed its length or SHA-256 check.',
        );
      }
      final decoded = jsonDecode(
        utf8.decode(messageBytes, allowMalformed: false),
      );
      if (decoded is! Map) {
        throw const ConversationMirrorValidationException(
          'Reassembled mirror entry is not a message map.',
        );
      }
      await _store.appendShadowPage(
        key: key,
        generation: '${chunk.requestId}:${chunk.revision}',
        pageIndex: chunk.pageIndex,
        pageCount: chunk.pageCount,
        entries: [
          ConversationMirrorEntryInput(
            entryId: chunk.entryId,
            ordinal: chunk.index,
            contentHash: chunk.contentHash,
            message: Map<String, dynamic>.from(decoded),
          ),
        ],
        transportFragmented: true,
      );
      _entryChunkAssemblies.remove(assemblyKey);
      _completedEntryChunkPages.add(assemblyKey);
    } catch (error) {
      _clearEntryChunksForRequest(chunk.requestId);
      try {
        await _store.setSyncError(
          key,
          '$error',
          projectPath: pending?.projectPath,
        );
        await _refreshMetadata(key);
      } catch (_) {}
      _stopWatchForRequest(
        key: key,
        requestId: chunk.requestId,
        provider: chunk.provider,
        providerSessionId: chunk.providerSessionId,
      );
      _finishPending(
        chunk.requestId,
        ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: 'local_storage_failed',
          error: '$error',
        ),
      );
      _notifyListeners();
    }
  }

  String _entryChunkAssemblyKey(ConversationMirrorEntryChunkMessage chunk) =>
      '${chunk.requestId}\u0000${chunk.revision}\u0000${chunk.pageIndex}';

  void _clearEntryChunksForRequest(String requestId) {
    _entryChunkAssemblies.removeWhere(
      (_, assembly) => assembly.requestId == requestId,
    );
    _completedEntryChunkPages.removeWhere(
      (key) => key.startsWith('$requestId\u0000'),
    );
  }

  void _adoptPendingEventKey(
    _PendingMirrorRequest pending,
    ConversationMirrorKey eventKey,
  ) {
    final oldKey = pending.key;
    if (oldKey == eventKey) return;
    if (oldKey != null) {
      if (_syncing.remove(oldKey)) _syncing.add(eventKey);
      if (_watchRequestIds[oldKey] == pending.requestId) {
        _watchRequestIds.remove(oldKey);
        _watchRequestIds[eventKey] = pending.requestId;
      }
      if (_resetRequestIds[oldKey] == pending.requestId) {
        _resetRequestIds.remove(oldKey);
        _resetRequestIds[eventKey] = pending.requestId;
      }
    }
    pending.key = eventKey;
  }

  void _stopWatchForRequest({
    required ConversationMirrorKey? key,
    required String requestId,
    required String provider,
    required String providerSessionId,
    String? codexSourceId,
  }) {
    final ownsWatch = _releaseWatchOwnership(
      key: key,
      requestId: requestId,
      provider: provider,
      providerSessionId: providerSessionId,
      codexSourceId: codexSourceId,
    );
    if (!ownsWatch) return;
    _acceptedRequestIds.remove(requestId);
    _transferGuardsByRequestId.remove(requestId);
    if (!_bridge.isConnected) return;
    try {
      _bridge.send(
        requestConversationMirrorUnwatch(
          requestId: _uuid.v4(),
          provider: provider,
          providerSessionId: providerSessionId,
          codexSourceId: _wireCodexSourceId(key),
        ),
      );
    } catch (_) {
      // Disconnect cleanup owns the remaining server-side watch lifetime.
    }
  }

  Future<ConversationMirrorSyncResult>? _existingWatch({
    required String provider,
    required String providerSessionId,
    required ConversationMirrorKey? key,
    String? codexSourceId,
    required int entryCount,
  }) {
    final sourceId = key == null ? codexSourceId : key.codexSourceId;
    final logicalKey = _logicalWatchKey(
      provider,
      providerSessionId,
      sourceId,
    );
    final requestId =
        _watchRequestIdsByConversation[logicalKey] ??
        (key == null ? null : _watchRequestIds[key]);
    if (requestId == null) return null;
    final pending = _pending[requestId];
    if (pending != null) return pending.completer.future;
    if (_acceptedRequestIds.contains(requestId)) {
      _watchRequestIdsByConversation[logicalKey] = requestId;
      if (key != null) _watchRequestIds[key] = requestId;
      return Future.value(
        ConversationMirrorSyncResult(
          success: true,
          changed: false,
          entryCount: entryCount,
        ),
      );
    }
    _releaseWatchOwnership(
      key: key,
      requestId: requestId,
      provider: provider,
      providerSessionId: providerSessionId,
      codexSourceId: sourceId,
    );
    return null;
  }

  bool _releaseWatchOwnership({
    required ConversationMirrorKey? key,
    required String requestId,
    required String provider,
    required String providerSessionId,
    String? codexSourceId,
  }) {
    var owned = false;
    final sourceId = key == null ? codexSourceId : key.codexSourceId;
    final logicalKey = _logicalWatchKey(
      provider,
      providerSessionId,
      sourceId,
    );
    if (_watchRequestIdsByConversation[logicalKey] == requestId) {
      _watchRequestIdsByConversation.remove(logicalKey);
      owned = true;
    }
    if (key != null && _watchRequestIds[key] == requestId) {
      _watchRequestIds.remove(key);
      owned = true;
    }
    _watchRequestIds.removeWhere((candidate, owner) {
      final matches =
          owner == requestId &&
          candidate.provider == provider &&
          candidate.providerSessionId == providerSessionId &&
          candidate.codexSourceId == sourceId;
      if (matches) owned = true;
      return matches;
    });
    return owned;
  }

  String _logicalWatchKey(
    String provider,
    String providerSessionId,
    String? codexSourceId,
  ) => '$provider\u0000${codexSourceId ?? ''}\u0000$providerSessionId';

  String _generation(ConversationMirrorEventMessage event) =>
      '${event.requestId}:${event.revision}';

  Future<void> _refreshMetadata(ConversationMirrorKey key) async {
    final metadata = await _store.readMetadata(key);
    if (metadata == null) {
      _metadata.remove(key);
    } else {
      _metadata[key] = metadata;
    }
  }

  bool _hasOlderRuntimeHistory(String runtimeSessionId) {
    final cursor = _pageCursorsByRuntime[runtimeSessionId];
    if (cursor == null) return false;
    if (!_pageCursorIdentityMatches(runtimeSessionId, cursor)) {
      _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
      return false;
    }
    return cursor.nextOffset > 0;
  }

  bool _hasRuntimeHistory(String runtimeSessionId) {
    final cursor = _pageCursorsByRuntime[runtimeSessionId];
    if (cursor == null) return false;
    if (!_pageCursorIdentityMatches(runtimeSessionId, cursor)) {
      _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
      return false;
    }
    return true;
  }

  void _setRuntimePageCursor(
    String runtimeSessionId,
    _RuntimeMirrorPageCursor cursor,
  ) {
    final previous = _pageCursorsByRuntime[runtimeSessionId];
    _pageCursorsByRuntime[runtimeSessionId] = cursor;
    final changed =
        previous == null ||
        previous.key != cursor.key ||
        previous.revision != cursor.revision ||
        previous.activeGeneration != cursor.activeGeneration ||
        previous.entryCount != cursor.entryCount ||
        previous.bootstrapGeneration != cursor.bootstrapGeneration ||
        previous.nextOffset != cursor.nextOffset;
    if (changed) {
      _bridge.notifySessionHistoryAvailabilityChanged(
        runtimeSessionId,
        available: true,
      );
    }
  }

  void _removeRuntimePageCursor(
    String runtimeSessionId, {
    _RuntimeMirrorPageCursor? expected,
  }) {
    final existing = _pageCursorsByRuntime[runtimeSessionId];
    if (existing == null ||
        (expected != null && !identical(existing, expected))) {
      return;
    }
    _pageCursorsByRuntime.remove(runtimeSessionId);
    _bridge.notifySessionHistoryAvailabilityChanged(
      runtimeSessionId,
      available: false,
    );
  }

  void _removeRuntimePageCursorsWhere(
    bool Function(_RuntimeMirrorPageCursor cursor) test,
  ) {
    final runtimeSessionIds = _pageCursorsByRuntime.entries
        .where((entry) => test(entry.value))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final runtimeSessionId in runtimeSessionIds) {
      _removeRuntimePageCursor(runtimeSessionId);
    }
  }

  void _clearRuntimePageCursors() {
    final runtimeSessionIds = _pageCursorsByRuntime.keys.toList(
      growable: false,
    );
    for (final runtimeSessionId in runtimeSessionIds) {
      _removeRuntimePageCursor(runtimeSessionId);
    }
  }

  Future<void> _publishTransferToBoundRuntimes(
    ConversationMirrorKey key,
    _MirrorTransferGuard? transferGuard, {
    bool onlyIfCursorStale = false,
  }) async {
    if (transferGuard == null || !transferGuard.matches(key)) return;
    if (!transferGuard.providerReadGuarded) {
      for (final runtimeGuard in transferGuard.runtimes) {
        if (_publishIdentityMatches(key, runtimeGuard)) {
          _bridge.requestSessionHistory(runtimeGuard.runtimeSessionId);
        }
      }
      return;
    }
    final canonicalFallbacks = <_RuntimePublishGuard>[];
    for (final runtimeGuard in transferGuard.runtimes) {
      if (onlyIfCursorStale &&
          _runtimeCursorMatchesMetadata(key, runtimeGuard)) {
        continue;
      }
      final result = await _publishKeyToRuntime(key, runtimeGuard);
      if (result == _MirrorPublishResult.contentChanged) {
        canonicalFallbacks.add(runtimeGuard);
      }
    }
    for (final runtimeGuard in canonicalFallbacks) {
      // Re-check identity after the await above. Content changes ask the
      // authoritative Bridge history to converge; a rebind, restart, or Bridge
      // change merely invalidates this old transfer and must not target the new
      // runtime generation.
      if (_publishIdentityMatches(key, runtimeGuard)) {
        _bridge.requestSessionHistory(runtimeGuard.runtimeSessionId);
      }
    }
  }

  bool _runtimeCursorMatchesMetadata(
    ConversationMirrorKey key,
    _RuntimePublishGuard guard,
  ) {
    final cursor = _pageCursorsByRuntime[guard.runtimeSessionId];
    final metadata = _metadata[key];
    return cursor != null &&
        metadata != null &&
        _publishIdentityMatches(key, guard) &&
        cursor.key == key &&
        cursor.revision == metadata.revision &&
        cursor.activeGeneration == metadata.activeGeneration &&
        cursor.entryCount == metadata.entryCount &&
        cursor.bootstrapGeneration == guard.bootstrapGeneration;
  }

  Future<_MirrorPublishResult> _publishKeyToRuntime(
    ConversationMirrorKey key,
    _RuntimePublishGuard guard,
  ) async {
    if (!_publishIdentityMatches(key, guard)) {
      return _MirrorPublishResult.invalidated;
    }
    final metadataBefore = await _store.readMetadata(key);
    if (metadataBefore == null || !metadataBefore.hasLocalCopy) {
      return _MirrorPublishResult.invalidated;
    }
    final startOffset = math.max(
      0,
      metadataBefore.entryCount - _initialRenderEntryCount,
    );
    late final List<ConversationMirrorEntry> entries;
    try {
      entries = await _store.readEntries(
        key,
        offset: startOffset,
        limit: _initialRenderEntryCount,
      );
    } catch (_) {
      if (_closed) return _MirrorPublishResult.invalidated;
      rethrow;
    }
    final timestampAnchor = await _timestampAnchorBeforePage(
      key,
      startOffset,
      entries,
    );
    if (!_publishIdentityMatches(key, guard)) {
      return _MirrorPublishResult.invalidated;
    }
    final metadataAfter = await _store.readMetadata(key);
    if (metadataAfter == null ||
        metadataAfter.activeGeneration != metadataBefore.activeGeneration ||
        metadataAfter.revision != metadataBefore.revision ||
        metadataAfter.entryCount != metadataBefore.entryCount) {
      return _MirrorPublishResult.invalidated;
    }
    final mirrorMessages = _decodeRenderableEntries(entries);
    final canonicalMessages = _bridge
        .cachedSessionMessages(guard.runtimeSessionId)
        .where(_isRenderableHistoryMessage)
        .toList(growable: false);
    final messages = _mergeMirrorWindowWithCanonicalTail(
      mirrorMessages: mirrorMessages,
      canonicalMessages: canonicalMessages,
    );
    if (!_publishIdentityMatches(key, guard)) {
      return _MirrorPublishResult.invalidated;
    }
    final contentChanged =
        _bridge.cachedSessionContentEpoch(guard.runtimeSessionId) !=
        guard.contentEpoch;
    final nextOffset = contentChanged
        ? _nextOffsetBeforeCanonicalTail(
            entries: entries,
            canonicalMessages: canonicalMessages,
            entryCount: metadataBefore.entryCount,
          )
        : startOffset;
    _setRuntimePageCursor(
      guard.runtimeSessionId,
      _RuntimeMirrorPageCursor(
        key: key,
        revision: metadataBefore.revision,
        activeGeneration: metadataBefore.activeGeneration,
        entryCount: metadataBefore.entryCount,
        bootstrapGeneration: guard.bootstrapGeneration,
        nextOffset: nextOffset,
      ),
    );
    if (contentChanged) return _MirrorPublishResult.contentChanged;
    _bridge.publishExternalSessionHistory(
      guard.runtimeSessionId,
      messages,
      timestampAnchor: timestampAnchor,
    );
    return _MirrorPublishResult.published;
  }

  int _nextOffsetBeforeCanonicalTail({
    required List<ConversationMirrorEntry> entries,
    required List<ServerMessage> canonicalMessages,
    required int entryCount,
  }) {
    if (canonicalMessages.isEmpty) return entryCount;
    final mirrorOrdinalByKey = <String, int>{};
    for (final entry in entries) {
      try {
        final message = ServerMessage.fromJson(entry.message);
        final stableKey = _historyMessageStableKey(message);
        if (stableKey != null) {
          mirrorOrdinalByKey[stableKey] = entry.ordinal;
        }
      } catch (_) {
        // Corrupt/future envelopes remain retained in storage but cannot
        // participate in the visible canonical-tail overlap calculation.
      }
    }
    for (final canonical in canonicalMessages) {
      final stableKey = _historyMessageStableKey(canonical);
      final ordinal = stableKey == null
          ? null
          : mirrorOrdinalByKey[stableKey];
      if (ordinal != null) return ordinal;
    }
    // No overlap normally means the canonical cache begins after the last
    // downloaded revision. Page from the local end so no stored range is
    // skipped between that durable copy and the newer live tail.
    return entryCount;
  }

  List<ServerMessage> _decodeRenderableEntries(
    List<ConversationMirrorEntry> entries,
  ) {
    final messages = <ServerMessage>[];
    for (final entry in entries) {
      if (!const {
        'user_input',
        'assistant',
        'tool_result',
      }.contains(entry.message['type'])) {
        debugPrint(
          '[conversation-mirror] retained but did not render future envelope '
          '${entry.entryId} (${entry.message['type']})',
        );
        continue;
      }
      try {
        messages.add(ServerMessage.fromJson(entry.message));
      } catch (error) {
        debugPrint(
          '[conversation-mirror] skipped corrupt envelope ${entry.entryId}: '
          '$error',
        );
      }
    }
    return messages;
  }

  List<ServerMessage> _mergeMirrorWindowWithCanonicalTail({
    required List<ServerMessage> mirrorMessages,
    required List<ServerMessage> canonicalMessages,
  }) {
    if (canonicalMessages.isEmpty) return mirrorMessages;
    if (mirrorMessages.isEmpty) return canonicalMessages;

    final mirrorIndexByKey = <String, int>{};
    for (var index = 0; index < mirrorMessages.length; index++) {
      final key = _historyMessageStableKey(mirrorMessages[index]);
      if (key != null) mirrorIndexByKey[key] = index;
    }

    var firstOverlap = -1;
    for (var index = 0; index < canonicalMessages.length; index++) {
      final key = _historyMessageStableKey(canonicalMessages[index]);
      if (key != null && mirrorIndexByKey.containsKey(key)) {
        firstOverlap = index;
        break;
      }
    }

    // With no overlap, the bounded runtime cache normally starts after the
    // last downloaded revision (for example a Desktop turn completed while
    // the phone was away). Provider identity and the publish guard fence the
    // merge, so keep the complete local window and append the canonical tail.
    if (firstOverlap == -1) {
      return List.unmodifiable([...mirrorMessages, ...canonicalMessages]);
    }

    final merged = List<ServerMessage>.from(mirrorMessages);
    final mergedIndexByKey = Map<String, int>.from(mirrorIndexByKey);
    for (final canonical in canonicalMessages.skip(firstOverlap)) {
      final key = _historyMessageStableKey(canonical);
      final existingIndex = key == null ? null : mergedIndexByKey[key];
      if (existingIndex == null) {
        if (key != null) mergedIndexByKey[key] = merged.length;
        merged.add(canonical);
      } else {
        // Canonical runtime content wins for an overlapping envelope because
        // it may include a newer live assistant/tool representation.
        merged[existingIndex] = canonical;
      }
    }
    return List.unmodifiable(merged);
  }

  bool _isRenderableHistoryMessage(ServerMessage message) =>
      message is UserInputMessage ||
      message is AssistantServerMessage ||
      message is ToolResultMessage;

  String? _historyMessageStableKey(ServerMessage message) {
    switch (message) {
      case UserInputMessage(:final userMessageUuid, :final clientMessageId):
        final uuid = userMessageUuid?.trim();
        if (uuid?.isNotEmpty == true) return 'user:uuid:$uuid';
        final clientId = clientMessageId?.trim();
        if (clientId?.isNotEmpty == true) return 'user:client:$clientId';
        return null;
      case AssistantServerMessage(:final messageUuid, :final message):
        final uuid = messageUuid?.trim();
        if (uuid?.isNotEmpty == true) return 'assistant:uuid:$uuid';
        final id = message.id.trim();
        return id.isEmpty ? null : 'assistant:id:$id';
      case ToolResultMessage(:final toolUseId):
        final id = toolUseId.trim();
        return id.isEmpty ? null : 'tool-result:$id';
      default:
        return null;
    }
  }

  Future<LocalSessionHistoryPage?> _loadOlderRuntimeHistory({
    required String runtimeSessionId,
    required int limit,
  }) async {
    final cursor = _pageCursorsByRuntime[runtimeSessionId];
    if (cursor == null || cursor.nextOffset <= 0) {
      return const LocalSessionHistoryPage(messages: [], hasMore: false);
    }
    if (cursor.loading) return null;
    if (!_pageCursorIdentityMatches(runtimeSessionId, cursor)) {
      _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
      return const LocalSessionHistoryPage(messages: [], hasMore: false);
    }
    cursor.loading = true;
    try {
      final endOffset = cursor.nextOffset;
      final startOffset = math.max(0, endOffset - limit);
      final metadataBefore = await _store.readMetadata(cursor.key);
      if (!_pageCursorMetadataMatches(cursor, metadataBefore)) {
        _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
        return null;
      }
      final entries = await _store.readEntries(
        cursor.key,
        offset: startOffset,
        limit: endOffset - startOffset,
      );
      final timestampAnchor = await _timestampAnchorBeforePage(
        cursor.key,
        startOffset,
        entries,
      );
      final metadataAfter = await _store.readMetadata(cursor.key);
      if (!_pageCursorMetadataMatches(cursor, metadataAfter) ||
          !_pageCursorIdentityMatches(runtimeSessionId, cursor) ||
          !identical(_pageCursorsByRuntime[runtimeSessionId], cursor)) {
        _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
        return null;
      }
      cursor.nextOffset = startOffset;
      return LocalSessionHistoryPage(
        messages: List.unmodifiable(_decodeRenderableEntries(entries)),
        hasMore: startOffset > 0,
        timestampAnchor: timestampAnchor,
      );
    } finally {
      cursor.loading = false;
    }
  }

  Future<LocalSessionHistoryPage?> _loadRuntimeHistoryWindow({
    required String runtimeSessionId,
    required int startOrdinal,
    required int limit,
  }) async {
    final cursor = _pageCursorsByRuntime[runtimeSessionId];
    if (cursor == null ||
        cursor.loading ||
        startOrdinal < 0 ||
        startOrdinal >= cursor.entryCount) {
      return null;
    }
    if (!_pageCursorIdentityMatches(runtimeSessionId, cursor)) {
      _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
      return null;
    }
    cursor.loading = true;
    try {
      final metadataBefore = await _store.readMetadata(cursor.key);
      if (!_pageCursorMetadataMatches(cursor, metadataBefore)) {
        _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
        return null;
      }
      final boundedLimit = math.min(limit, cursor.entryCount - startOrdinal);
      final entries = await _store.readEntries(
        cursor.key,
        offset: startOrdinal,
        limit: boundedLimit,
      );
      final timestampAnchor = await _timestampAnchorBeforePage(
        cursor.key,
        startOrdinal,
        entries,
      );
      final metadataAfter = await _store.readMetadata(cursor.key);
      if (!_pageCursorMetadataMatches(cursor, metadataAfter) ||
          !_pageCursorIdentityMatches(runtimeSessionId, cursor) ||
          !identical(_pageCursorsByRuntime[runtimeSessionId], cursor)) {
        _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
        return null;
      }
      // The displayed mirror prefix now begins at this target. Ordinary
      // upward paging continues immediately before it instead of walking
      // through every skipped page.
      cursor.nextOffset = startOrdinal;
      return LocalSessionHistoryPage(
        messages: List.unmodifiable(_decodeRenderableEntries(entries)),
        hasMore: startOrdinal > 0,
        timestampAnchor: timestampAnchor,
      );
    } finally {
      cursor.loading = false;
    }
  }

  Future<List<HistoryToolDetail>?> _loadRuntimeHistoryToolDetails({
    required String runtimeSessionId,
    required List<String> toolUseIds,
  }) async {
    final cursor = _pageCursorsByRuntime[runtimeSessionId];
    if (cursor == null || toolUseIds.isEmpty) return null;
    if (!_pageCursorIdentityMatches(runtimeSessionId, cursor)) {
      _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
      return null;
    }
    final metadataBefore = await _store.readMetadata(cursor.key);
    if (!_pageCursorMetadataMatches(cursor, metadataBefore)) {
      _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
      return null;
    }
    final entries = await _store.readToolEntries(cursor.key, toolUseIds);
    final metadataAfter = await _store.readMetadata(cursor.key);
    if (!_pageCursorMetadataMatches(cursor, metadataAfter) ||
        !_pageCursorIdentityMatches(runtimeSessionId, cursor) ||
        !identical(_pageCursorsByRuntime[runtimeSessionId], cursor)) {
      _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
      return null;
    }
    return _historyToolDetailsFromMessages(
      _decodeRenderableEntries(entries),
      toolUseIds,
    );
  }

  List<HistoryToolDetail> _historyToolDetailsFromMessages(
    List<ServerMessage> messages,
    List<String> toolUseIds,
  ) {
    const maximumFieldBytes = 64 * 1024;
    const maximumAttachments = 32;
    final requested = toolUseIds.toSet();
    final details = <String, HistoryToolDetail>{};
    for (final message in messages) {
      if (message is AssistantServerMessage) {
        for (final content in message.message.content) {
          if (content is! ToolUseContent || !requested.contains(content.id)) {
            continue;
          }
          final existing = details[content.id];
          details[content.id] = HistoryToolDetail(
            toolUseId: content.id,
            toolName: content.name,
            input: _boundedHistoryToolInput(
              content.input,
              maximumFieldBytes,
            ),
            result: existing?.result,
          );
        }
        continue;
      }
      if (message is! ToolResultMessage ||
          !requested.contains(message.toolUseId)) {
        continue;
      }
      final existing = details[message.toolUseId];
      details[message.toolUseId] = HistoryToolDetail(
        toolUseId: message.toolUseId,
        toolName:
            existing?.toolName ??
            (message.toolName?.trim().isNotEmpty == true
                ? message.toolName!
                : 'Tool'),
        input: existing?.input ?? const {},
        result: ToolResultMessage(
          toolUseId: message.toolUseId,
          content: _boundedHistoryToolText(
            message.content,
            maximumFieldBytes,
          ),
          toolName: message.toolName,
          images: message.images.take(maximumAttachments).toList(
            growable: false,
          ),
          userMessageUuid: message.userMessageUuid,
          artifacts: message.artifacts.take(maximumAttachments).toList(
            growable: false,
          ),
        ),
      );
    }
    return [
      for (final toolUseId in toolUseIds) ?details[toolUseId],
    ];
  }

  Map<String, dynamic> _boundedHistoryToolInput(
    Map<String, dynamic> input,
    int maximumBytes,
  ) {
    String encoded;
    try {
      encoded = jsonEncode(input);
    } catch (_) {
      return const {
        'truncated': true,
        'preview': '[Tool input could not be serialized locally]',
      };
    }
    if (utf8.encode(encoded).length <= maximumBytes) return input;
    return {
      'truncated': true,
      'preview': _boundedHistoryToolText(encoded, maximumBytes),
    };
  }

  String _boundedHistoryToolText(String value, int maximumBytes) {
    final encoded = utf8.encode(value);
    if (encoded.length <= maximumBytes) return value;
    return '${utf8.decode(
      encoded.sublist(0, maximumBytes),
      allowMalformed: true,
    )}\n…[truncated by local mirror]';
  }

  Future<List<LocalSessionUserIndexEntry>?> _loadRuntimeUserIndex({
    required String runtimeSessionId,
  }) async {
    final cursor = _pageCursorsByRuntime[runtimeSessionId];
    if (cursor == null ||
        !_pageCursorIdentityMatches(runtimeSessionId, cursor)) {
      if (cursor != null) {
        _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
      }
      return null;
    }
    final metadataBefore = await _store.readMetadata(cursor.key);
    if (!_pageCursorMetadataMatches(cursor, metadataBefore)) {
      _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
      return null;
    }
    final entries = await _store.readUserEntries(cursor.key);
    final metadataAfter = await _store.readMetadata(cursor.key);
    if (!_pageCursorMetadataMatches(cursor, metadataAfter) ||
        !_pageCursorIdentityMatches(runtimeSessionId, cursor) ||
        !identical(_pageCursorsByRuntime[runtimeSessionId], cursor)) {
      _removeRuntimePageCursor(runtimeSessionId, expected: cursor);
      return null;
    }
    final messages = <LocalSessionUserIndexEntry>[];
    for (final entry in entries) {
      try {
        final message = ServerMessage.fromJson(entry.message);
        if (message is UserInputMessage &&
            !message.isSynthetic &&
            !message.isMeta) {
          messages.add(
            LocalSessionUserIndexEntry(
              message: message,
              ordinal: entry.ordinal,
            ),
          );
        }
      } catch (error) {
        debugPrint(
          '[conversation-mirror] skipped invalid user index envelope '
          '${entry.entryId}: $error',
        );
      }
    }
    return List.unmodifiable(messages);
  }

  bool _pageCursorMetadataMatches(
    _RuntimeMirrorPageCursor cursor,
    ConversationMirrorMetadata? metadata,
  ) =>
      metadata != null &&
      metadata.activeGeneration == cursor.activeGeneration &&
      metadata.revision == cursor.revision &&
      metadata.entryCount == cursor.entryCount;

  Future<DateTime?> _timestampAnchorBeforePage(
    ConversationMirrorKey key,
    int startOffset,
    List<ConversationMirrorEntry> pageEntries,
  ) async {
    if (startOffset <= 0 || _startsWithUserInput(pageEntries)) return null;
    var endOffset = startOffset;
    var remaining = _timestampAnchorScanLimit;
    while (endOffset > 0 && remaining > 0) {
      final batchSize = math.min(
        math.min(_timestampAnchorBatchSize, remaining),
        endOffset,
      );
      final batchStart = endOffset - batchSize;
      final entries = await _store.readEntries(
        key,
        offset: batchStart,
        limit: batchSize,
      );
      for (final entry in entries.reversed) {
        final message = entry.message;
        if (message['type'] != 'user_input' ||
            message['isSynthetic'] == true ||
            message['isMeta'] == true) {
          continue;
        }
        final rawTimestamp = message['timestamp'];
        if (rawTimestamp is String) {
          return DateTime.tryParse(rawTimestamp)?.toLocal();
        }
        return null;
      }
      endOffset = batchStart;
      remaining -= batchSize;
    }
    return null;
  }

  bool _startsWithUserInput(List<ConversationMirrorEntry> entries) {
    for (final entry in entries) {
      final message = entry.message;
      if (!const {
        'system',
        'user_input',
        'assistant',
        'tool_result',
        'status',
        'result',
        'permission_request',
        'permission_resolved',
        'conversation_queue',
      }.contains(message['type'])) {
        continue;
      }
      return message['type'] == 'user_input';
    }
    return false;
  }

  bool _pageCursorIdentityMatches(
    String runtimeSessionId,
    _RuntimeMirrorPageCursor cursor,
  ) =>
      !_closed &&
      currentBridgeInstanceId == cursor.key.bridgeInstanceId &&
      _keyBelongsToCurrentSource(cursor.key) &&
      _bootstrapGenerationByRuntime[runtimeSessionId] ==
          cursor.bootstrapGeneration &&
      _bridge.providerSessionIdForRuntime(
            runtimeSessionId,
            provider: cursor.key.provider,
          ) ==
          cursor.key.providerSessionId;

  _MirrorTransferGuard _captureTransferGuard(
    ConversationMirrorEventMessage event, {
    required bool providerReadGuarded,
  }) {
    final key = _incomingMirrorKey(
      requestId: event.requestId,
      bridgeInstanceId: event.bridgeInstanceId,
      provider: event.provider,
      providerSessionId: event.providerSessionId,
    );
    final runtimes = <_RuntimePublishGuard>[];
    for (final runtimeSessionId in _bridge.runtimeSessionIdsForProviderSession(
      key.provider,
      key.providerSessionId,
    )) {
      final guard = _captureRuntimePublishGuard(
        key,
        runtimeSessionId,
        expectedBridgeInstanceId: event.bridgeInstanceId,
      );
      if (guard != null) runtimes.add(guard);
    }
    return _MirrorTransferGuard(
      key: key,
      runtimes: List.unmodifiable(runtimes),
      providerReadGuarded: providerReadGuarded,
    );
  }

  _RuntimePublishGuard? _captureRuntimePublishGuard(
    ConversationMirrorKey key,
    String runtimeSessionId, {
    required String? expectedBridgeInstanceId,
  }) {
    if (_bridge.providerSessionIdForRuntime(
          runtimeSessionId,
          provider: key.provider,
        ) !=
        key.providerSessionId) {
      return null;
    }
    return _RuntimePublishGuard(
      runtimeSessionId: runtimeSessionId,
      bridgeInstanceId: expectedBridgeInstanceId,
      provider: key.provider,
      providerSessionId: key.providerSessionId,
      codexSourceId: key.codexSourceId,
      contentEpoch: _bridge.cachedSessionContentEpoch(runtimeSessionId),
      bootstrapGeneration: _bootstrapGenerationByRuntime[runtimeSessionId],
    );
  }

  bool _publishIdentityMatches(
    ConversationMirrorKey key,
    _RuntimePublishGuard guard,
  ) =>
      !_closed &&
      guard.matches(key) &&
      currentBridgeInstanceId == guard.bridgeInstanceId &&
      _keyBelongsToCurrentSource(key) &&
      _bootstrapGenerationByRuntime[guard.runtimeSessionId] ==
          guard.bootstrapGeneration &&
      _bridge.providerSessionIdForRuntime(
            guard.runtimeSessionId,
            provider: key.provider,
          ) ==
          key.providerSessionId;

  bool _isTransferTerminal(ConversationMirrorEventKind event) =>
      switch (event) {
        ConversationMirrorEventKind.probe ||
        ConversationMirrorEventKind.snapshotComplete ||
        ConversationMirrorEventKind.patch ||
        ConversationMirrorEventKind.notModified ||
        ConversationMirrorEventKind.unwatched ||
        ConversationMirrorEventKind.error => true,
        _ => false,
      };

  Future<void> _requestSnapshotReset(
    ConversationMirrorKey key,
    String? projectPath,
  ) async {
    if (!_bridge.isConnected || _resetRequestIds.containsKey(key)) return;
    final requestId = _uuid.v4();
    final pending = _PendingMirrorRequest(
      requestId: requestId,
      provider: key.provider,
      providerSessionId: key.providerSessionId,
      codexSourceId: key.codexSourceId,
      projectPath: projectPath ?? _metadata[key]?.projectPath ?? '',
      key: key,
      autoSync: _metadata[key]?.autoSync ?? true,
      createsWatch: false,
      previousEntryCount: _metadata[key]?.entryCount ?? 0,
      previousRevision: _metadata[key]?.revision,
    );
    _resetRequestIds[key] = requestId;
    _registerPending(pending);
    try {
      _bridge.send(
        requestConversationMirrorSync(
          requestId: requestId,
          provider: key.provider,
          providerSessionId: key.providerSessionId,
          projectPath: pending.projectPath,
          codexSourceId: _wireCodexSourceId(key),
        ),
      );
    } catch (error) {
      _finishPending(
        requestId,
        ConversationMirrorSyncResult(
          success: false,
          changed: false,
          errorCode: 'bridge_disconnected',
          error: '$error',
        ),
      );
    }
  }

  Future<void> _adoptBridgeIdentity(
    String bridgeInstanceId, {
    required String? codexSourceId,
  }) async {
    if (_closed || !_storageAvailable || bridgeInstanceId.isEmpty) return;
    final changed =
        _currentBridgeInstanceId != bridgeInstanceId ||
        _currentCodexSourceId != codexSourceId;
    _currentBridgeInstanceId = bridgeInstanceId;
    _currentCodexSourceId = codexSourceId;
    final records = await _store.listLocalCopies();
    if (_closed) return;
    _metadata
      ..removeWhere((key, _) => key.bridgeInstanceId == bridgeInstanceId)
      ..addEntries(
        records
            .where((record) => record.key.bridgeInstanceId == bridgeInstanceId)
            .map((record) => MapEntry(record.key, record)),
      );
    if (changed) {
      final staleRequestIds = List<String>.from(_pending.keys);
      _acceptedRequestIds.removeAll(_watchRequestIds.values);
      _transferGuardsByRequestId.clear();
      _watchRequestIds.clear();
      _watchRequestIdsByConversation.clear();
      _clearRuntimePageCursors();
      for (final requestId in staleRequestIds) {
        _finishPending(
          requestId,
          const ConversationMirrorSyncResult(
            success: false,
            changed: false,
            errorCode: 'bridge_identity_changed',
            error: 'Bridge identity changed during conversation sync.',
          ),
        );
      }
    }
    _notifyListeners();
    if (_bridge.isConnected) {
      if (_automaticWatchRestorationEnabled) {
        _deferredAutoWatchBridgeInstanceId = null;
        await _restoreAutoWatches(bridgeInstanceId, records);
      } else {
        _deferredAutoWatchBridgeInstanceId = bridgeInstanceId;
      }
    }
  }

  Future<void> _restoreDeferredAutoWatches() async {
    if (_closed || !_automaticWatchRestorationEnabled || !_bridge.isConnected) {
      return;
    }
    final bridgeInstanceId =
        _deferredAutoWatchBridgeInstanceId ?? currentBridgeInstanceId;
    if (bridgeInstanceId == null || bridgeInstanceId.isEmpty) return;
    _deferredAutoWatchBridgeInstanceId = null;
    await _restoreAutoWatches(
      bridgeInstanceId,
      _metadata.values.toList(growable: false),
    );
  }

  Future<void> _restoreAutoWatches(
    String bridgeInstanceId,
    List<ConversationMirrorMetadata> autoSyncRecords,
  ) async {
    if (_closed || !_automaticWatchRestorationEnabled) {
      _deferredAutoWatchBridgeInstanceId = bridgeInstanceId;
      return;
    }
    final records = autoSyncRecords
        .where(
          (record) =>
              record.key.bridgeInstanceId == bridgeInstanceId &&
              _keyBelongsToCurrentSource(record.key) &&
              record.autoSync &&
              record.hasLocalCopy,
        )
        .take(maxResidentConversations);
    for (final record in records) {
      if (!_bridge.isConnected || _closed) return;
      if (!_automaticWatchRestorationEnabled) {
        _deferredAutoWatchBridgeInstanceId = bridgeInstanceId;
        return;
      }
      unawaited(
        _ensureWatch(
          record.key,
          projectPath: record.projectPath,
          knownRevision: record.revision,
        ),
      );
    }
  }

  void _finishPending(String requestId, ConversationMirrorSyncResult result) {
    _clearEntryChunksForRequest(requestId);
    final pending = _pending.remove(requestId);
    if (pending == null) return;
    _transferGuardsByRequestId.remove(requestId);
    pending.timer?.cancel();
    var keepAcceptedWatch = false;
    final bridgeId = currentBridgeInstanceId;
    final key =
        pending.key ??
        (bridgeId == null
            ? null
            : ConversationMirrorKey(
                bridgeInstanceId: bridgeId,
                provider: pending.provider,
                providerSessionId: pending.providerSessionId,
                codexSourceId: pending.provider == Provider.codex.value
                    ? pending.codexSourceId
                    : null,
              ));
    if (key != null) {
      _syncing.remove(key);
      if (_resetRequestIds[key] == requestId) {
        _resetRequestIds.remove(key);
      }
      if (!result.success && pending.createsWatch) {
        final capabilityRejected =
            result.errorCode == 'unsupported_message' ||
            result.errorCode == 'unsupported_capability' ||
            result.errorCode == 'capability_not_negotiated';
        if (capabilityRejected) {
          _releaseWatchOwnership(
            key: key,
            requestId: requestId,
            provider: pending.provider,
            providerSessionId: pending.providerSessionId,
          );
        } else {
          _stopWatchForRequest(
            key: key,
            requestId: requestId,
            provider: pending.provider,
            providerSessionId: pending.providerSessionId,
          );
        }
      }
      final shadowGeneration = pending.shadowGeneration;
      if (!result.success && shadowGeneration != null && isAvailable) {
        unawaited(
          _enqueueStorage(() async {
            await _store.abortShadowGeneration(
              key,
              generation: shadowGeneration,
            );
          }),
        );
      }
      keepAcceptedWatch =
          (result.success || result.errorCode == 'malformed_items') &&
          pending.createsWatch &&
          (_watchRequestIds[key] == requestId ||
              _watchRequestIdsByConversation[_logicalWatchKey(
                    pending.provider,
                    pending.providerSessionId,
                    pending.codexSourceId,
                  )] ==
                  requestId);
    } else if (!result.success && pending.createsWatch) {
      final capabilityRejected =
          result.errorCode == 'unsupported_message' ||
          result.errorCode == 'unsupported_capability' ||
          result.errorCode == 'capability_not_negotiated';
      if (capabilityRejected) {
        _releaseWatchOwnership(
          key: null,
          requestId: requestId,
          provider: pending.provider,
          providerSessionId: pending.providerSessionId,
          codexSourceId: pending.codexSourceId,
        );
      } else {
        _stopWatchForRequest(
          key: null,
          requestId: requestId,
          provider: pending.provider,
          providerSessionId: pending.providerSessionId,
          codexSourceId: pending.codexSourceId,
        );
      }
    }
    if (!keepAcceptedWatch) _acceptedRequestIds.remove(requestId);
    if (!pending.completer.isCompleted) pending.completer.complete(result);
    _notifyListeners();
  }

  void _notifyListeners() {
    if (!_closed) notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _bridge.configureSessionHistoryBootstrap(null);
    _bridge.configureSessionHistoryPaging();
    _bridge.configureSessionHistoryUserIndex(null);
    _bridge.configureSessionHistoryToolDetails(null);
    await _localFeatureSub?.cancel();
    await _bridgeIdentitySub?.cancel();
    await _sessionListSub?.cancel();
    await _connectionSub?.cancel();
    for (final pending in _pending.values) {
      pending.timer?.cancel();
      final key = pending.key;
      final shadowGeneration = pending.shadowGeneration;
      if (_storageAvailable && key != null && shadowGeneration != null) {
        unawaited(
          _enqueueStorage(() async {
            await _store.abortShadowGeneration(
              key,
              generation: shadowGeneration,
            );
          }),
        );
      }
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          const ConversationMirrorSyncResult(
            success: false,
            changed: false,
            errorCode: 'disposed',
            error: 'Conversation mirror service was disposed.',
          ),
        );
      }
    }
    _pending.clear();
    _acceptedRequestIds.clear();
    _watchRequestIds.clear();
    _watchRequestIdsByConversation.clear();
    _resetRequestIds.clear();
    _bootstrapGenerationByRuntime.clear();
    _clearRuntimePageCursors();
    _transferGuardsByRequestId.clear();
    _entryChunkAssemblies.clear();
    _completedEntryChunkPages.clear();
    await _storageSerial;
    await _database.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

enum _MirrorPublishResult { published, contentChanged, invalidated }

class _ConversationMirrorDeadlineCancellation
    implements ConversationMirrorCancellation {
  _ConversationMirrorDeadlineCancellation({
    required ConversationMirrorCancellation? parent,
    required Duration budget,
  }) : _parent = parent {
    _parent?.addListener(cancel);
    if (!_cancelled) {
      _timer = Timer(budget, cancel);
    }
  }

  final ConversationMirrorCancellation? _parent;
  final Set<VoidCallback> _listeners = {};
  Timer? _timer;
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled || _parent?.isCancelled == true;

  @override
  void addListener(VoidCallback listener) {
    if (isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _timer?.cancel();
    final listeners = List<VoidCallback>.from(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void dispose() {
    _timer?.cancel();
    _parent?.removeListener(cancel);
    _listeners.clear();
  }
}

class _RuntimeMirrorPageCursor {
  _RuntimeMirrorPageCursor({
    required this.key,
    required this.revision,
    required this.activeGeneration,
    required this.entryCount,
    required this.bootstrapGeneration,
    required this.nextOffset,
  });

  final ConversationMirrorKey key;
  final String? revision;
  final String? activeGeneration;
  final int entryCount;
  final int? bootstrapGeneration;
  int nextOffset;
  bool loading = false;
}

class _MirrorTransferGuard {
  const _MirrorTransferGuard({
    required this.key,
    required this.runtimes,
    required this.providerReadGuarded,
  });

  final ConversationMirrorKey key;
  final List<_RuntimePublishGuard> runtimes;
  final bool providerReadGuarded;

  bool matches(ConversationMirrorKey candidate) => key == candidate;
}

class _RuntimePublishGuard {
  const _RuntimePublishGuard({
    required this.runtimeSessionId,
    required this.bridgeInstanceId,
    required this.provider,
    required this.providerSessionId,
    required this.codexSourceId,
    required this.contentEpoch,
    required this.bootstrapGeneration,
  });

  final String runtimeSessionId;
  final String? bridgeInstanceId;
  final String provider;
  final String providerSessionId;
  final String? codexSourceId;
  final int contentEpoch;
  final int? bootstrapGeneration;

  bool matches(ConversationMirrorKey key) =>
      provider == key.provider &&
      providerSessionId == key.providerSessionId &&
      codexSourceId == key.codexSourceId;
}

class _PendingMirrorRequest {
  _PendingMirrorRequest({
    required this.requestId,
    required this.provider,
    required this.providerSessionId,
    required this.codexSourceId,
    required this.projectPath,
    required this.key,
    required this.autoSync,
    required this.createsWatch,
    required this.previousEntryCount,
    required this.previousRevision,
    this.displayName,
    this.summary,
    this.firstPrompt,
  });

  final String requestId;
  final String provider;
  final String providerSessionId;
  final String? codexSourceId;
  final String projectPath;
  ConversationMirrorKey? key;
  final bool autoSync;
  final bool createsWatch;
  final int previousEntryCount;
  final String? previousRevision;
  final String? displayName;
  final String? summary;
  final String? firstPrompt;
  String? shadowGeneration;
  bool acceptedByBridge = false;
  final Completer<ConversationMirrorSyncResult> completer = Completer();
  Timer? timer;
}

class _MirrorEntryChunkAssembly {
  _MirrorEntryChunkAssembly.fromMessage(
    ConversationMirrorEntryChunkMessage message,
  ) : requestId = message.requestId,
      bridgeInstanceId = message.bridgeInstanceId,
      provider = message.provider,
      providerSessionId = message.providerSessionId,
      revision = message.revision,
      pageIndex = message.pageIndex,
      pageCount = message.pageCount,
      entryId = message.entryId,
      index = message.index,
      contentHash = message.contentHash,
      chunkCount = message.chunkCount,
      totalBytes = message.totalBytes,
      chunks = List<Uint8List?>.filled(message.chunkCount, null);

  final String requestId;
  final String bridgeInstanceId;
  final String provider;
  final String providerSessionId;
  final String revision;
  final int pageIndex;
  final int pageCount;
  final String entryId;
  final int index;
  final String contentHash;
  final int chunkCount;
  final int totalBytes;
  final List<Uint8List?> chunks;
  int receivedBytes = 0;

  bool get isComplete => chunks.every((chunk) => chunk != null);

  bool hasChunk(int chunkIndex) => chunks[chunkIndex] != null;

  void validateMetadata(ConversationMirrorEntryChunkMessage message) {
    if (requestId != message.requestId ||
        bridgeInstanceId != message.bridgeInstanceId ||
        provider != message.provider ||
        providerSessionId != message.providerSessionId ||
        revision != message.revision ||
        pageIndex != message.pageIndex ||
        pageCount != message.pageCount ||
        entryId != message.entryId ||
        index != message.index ||
        contentHash != message.contentHash ||
        chunkCount != message.chunkCount ||
        totalBytes != message.totalBytes) {
      throw const ConversationMirrorValidationException(
        'Mirror entry chunks disagree on their transfer metadata.',
      );
    }
  }

  void addChunk(int chunkIndex, Uint8List bytes) {
    final existing = chunks[chunkIndex];
    if (existing != null) {
      if (!listEquals(existing, bytes)) {
        throw const ConversationMirrorValidationException(
          'Mirror entry chunk was repeated with different bytes.',
        );
      }
      return;
    }
    if (receivedBytes + bytes.length > totalBytes) {
      throw const ConversationMirrorValidationException(
        'Mirror entry chunks exceed the declared entry length.',
      );
    }
    chunks[chunkIndex] = bytes;
    receivedBytes += bytes.length;
  }

  Uint8List join() {
    final builder = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      if (chunk == null) {
        throw const ConversationMirrorValidationException(
          'Mirror entry chunk assembly is incomplete.',
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
