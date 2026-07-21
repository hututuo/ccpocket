// Public constructor labels intentionally stay `bridge`, `store`, and
// `database`; initializing formals would expose private names to callers.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math' as math;

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
  final Set<String> _acceptedRequestIds = {};
  final Set<ConversationMirrorKey> _syncing = {};

  StreamSubscription<LocalFeatureServerMessage>? _localFeatureSub;
  StreamSubscription<PromptHistoryStatusMessage>? _bridgeIdentitySub;
  StreamSubscription<BridgeConnectionState>? _connectionSub;
  Future<void> _storageSerial = Future<void>.value();
  String? _currentBridgeInstanceId;
  bool _initialized = false;
  bool _closed = false;
  bool _storageAvailable = false;
  bool _featureUnsupported = false;

  String? get currentBridgeInstanceId =>
      _currentBridgeInstanceId ?? _bridge.promptHistoryBridgeId;

  bool get featureUnsupported => _featureUnsupported;
  bool get isAvailable => !_closed && !kIsWeb && _storageAvailable;

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

  Future<void> initialize() async {
    if (_initialized || _closed) return;
    _initialized = true;
    _localFeatureSub = _bridge.localFeatureMessages.listen(_onLocalFeature);
    _bridgeIdentitySub = _bridge.promptHistoryStatus.listen((status) {
      unawaited(
        _enqueueStorage(() => _adoptBridgeIdentity(status.bridgeInstanceId)),
      );
    });
    _connectionSub = _bridge.connectionStatus.listen((state) {
      if (state == BridgeConnectionState.connected) {
        _featureUnsupported = false;
        final bridgeId = _bridge.promptHistoryBridgeId;
        if (bridgeId != null && bridgeId.isNotEmpty) {
          unawaited(_enqueueStorage(() => _adoptBridgeIdentity(bridgeId)));
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
      }
    });
    _bridge.configureSessionHistoryBootstrap(_bootstrapRuntimeSession);
    _bridge.configureSessionHistoryPaging(
      loader: _loadOlderRuntimeHistory,
      hasMore: (runtimeSessionId) =>
          (_pageCursorsByRuntime[runtimeSessionId]?.nextOffset ?? 0) > 0,
      invalidate: _pageCursorsByRuntime.remove,
    );
    _bridge.configureSessionHistoryUserIndex(_loadRuntimeUserIndex);
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
        await _enqueueStorage(() => _adoptBridgeIdentity(bridgeId));
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
    return _metadata[ConversationMirrorKey(
      bridgeInstanceId: bridgeId,
      provider: target.provider,
      providerSessionId: target.providerSessionId,
    )];
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
    return _syncing.contains(
      ConversationMirrorKey(
        bridgeInstanceId: bridgeId,
        provider: target.provider,
        providerSessionId: target.providerSessionId,
      ),
    );
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
      );
      if (unique != null) _metadata[unique.key] = unique;
      return unique;
    }
    final key = ConversationMirrorKey(
      bridgeInstanceId: bridgeId,
      provider: target.provider,
      providerSessionId: target.providerSessionId,
    );
    final cached = _metadata[key];
    if (cached != null) return cached;
    final loaded = await _store.readMetadata(key);
    if (loaded != null) _metadata[key] = loaded;
    return loaded;
  }

  ConversationMirrorMetadata? _uniqueCachedMetadata(
    ConversationMirrorTarget target,
  ) {
    final candidates = _metadata.values
        .where(
          (metadata) =>
              metadata.hasLocalCopy &&
              metadata.key.provider == target.provider &&
              metadata.key.providerSessionId == target.providerSessionId,
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
            bridgeId == null || metadata.key.bridgeInstanceId == bridgeId,
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
        (bridgeId == null
            ? null
            : ConversationMirrorKey(
                bridgeInstanceId: bridgeId,
                provider: target.provider,
                providerSessionId: target.providerSessionId,
              ));
    if (key == null) return;
    _cancelTargetRequests(
      key,
      errorCode: 'local_copy_removed',
      error: 'The local conversation copy was removed.',
    );
    await _enqueueStorage(() async {
      await _store.deleteLocalCopy(key);
      _metadata.remove(key);
      _syncing.remove(key);
      _pageCursorsByRuntime.removeWhere((_, cursor) => cursor.key == key);
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
        )] ??
        _watchRequestIds[key];
    final pendingToCancel = _pending.values
        .where(
          (request) =>
              request.provider == key.provider &&
              request.providerSessionId == key.providerSessionId,
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
    final existing = await metadataForTarget(target);
    final currentBridgeId = currentBridgeInstanceId;
    final pendingKey =
        existing?.key ??
        (currentBridgeId == null
            ? null
            : ConversationMirrorKey(
                bridgeInstanceId: currentBridgeId,
                provider: target.provider,
                providerSessionId: target.providerSessionId,
              ));
    final requestId = _uuid.v4();
    final logicalWatchKey = _logicalWatchKey(
      target.provider,
      target.providerSessionId,
    );
    if (watch) {
      final existingWatch = _existingWatch(
        provider: target.provider,
        providerSessionId: target.providerSessionId,
        key: pendingKey,
        entryCount: existing?.entryCount ?? 0,
      );
      if (existingWatch != null) return existingWatch;
    }
    final pending = _PendingMirrorRequest(
      requestId: requestId,
      provider: target.provider,
      providerSessionId: target.providerSessionId,
      projectPath: target.effectiveProjectPath,
      key: pendingKey,
      autoSync: watch || (existing?.autoSync ?? false),
      createsWatch: watch,
      previousEntryCount: existing?.entryCount ?? 0,
      previousRevision: existing?.revision,
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
              )
            : requestConversationMirrorSync(
                requestId: requestId,
                provider: pending.provider,
                providerSessionId: pending.providerSessionId,
                projectPath: pending.projectPath,
                knownRevision: force ? null : existing?.revision,
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
    if (!isAvailable || provider != Provider.codex.value) return false;
    final bridgeId = currentBridgeInstanceId;
    if (providerSessionId == null) return false;
    final strictKey = bridgeId == null
        ? null
        : ConversationMirrorKey(
            bridgeInstanceId: bridgeId,
            provider: provider!,
            providerSessionId: providerSessionId,
          );
    final metadata = strictKey == null
        ? await _store.findUniqueLocalCopy(
            provider!,
            providerSessionId,
            projectPath: projectPath,
          )
        : await _store.readMetadata(strictKey);
    if (metadata == null || !metadata.hasLocalCopy) return false;
    final key = metadata.key;
    _metadata[key] = metadata;

    // A canonical runtime snapshot may already have arrived before bootstrap
    // starts. Never replace that newer content with an older durable mirror;
    // the watch below will reconcile the independent copy in the background.
    if (!_hasCanonicalRuntimeHistory(runtimeSessionId)) {
      final publishGuard = _captureRuntimePublishGuard(
        key,
        runtimeSessionId,
        expectedBridgeInstanceId: currentBridgeInstanceId,
      );
      if (publishGuard == null) return false;
      final published = await _publishKeyToRuntime(key, publishGuard);
      if (published != _MirrorPublishResult.published) return false;
    } else {
      _pageCursorsByRuntime.remove(runtimeSessionId);
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
  }) {
    final requestId = _uuid.v4();
    final pending = _PendingMirrorRequest(
      requestId: requestId,
      provider: key.provider,
      providerSessionId: key.providerSessionId,
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
    try {
      _bridge.send(
        requestConversationMirrorSync(
          requestId: requestId,
          provider: key.provider,
          providerSessionId: key.providerSessionId,
          projectPath: projectPath,
          knownRevision: knownRevision,
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
    if (message is ConversationMirrorEventMessage) {
      if (!_acceptedRequestIds.contains(message.requestId)) return;
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

  Future<void> _handleMirrorEvent(ConversationMirrorEventMessage event) async {
    if (!_acceptedRequestIds.contains(event.requestId)) return;
    final key = ConversationMirrorKey(
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
      if (ownedWatchKey != null && ownedWatchKey != key) return;
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
          await _store.beginShadowGeneration(
            key: key,
            generation: generation,
            revision: event.revision!,
            entryCount: event.entryCount!,
            pageCount: event.pageCount!,
            totalBytes: event.totalBytes!,
            autoSync: pending?.autoSync,
            projectPath: pending?.projectPath,
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
          if (event.entries.isNotEmpty || event.deletes.isNotEmpty) {
            await _publishTransferToBoundRuntimes(
              key,
              _transferGuardsByRequestId[event.requestId],
            );
          }
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
            );
          }
          await _refreshMetadata(key);
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
      _transferGuardsByRequestId.remove(event.requestId);
    }
    _notifyListeners();
  }

  ConversationMirrorEntryInput _entryInput(ConversationMirrorWireEntry entry) =>
      ConversationMirrorEntryInput(
        entryId: entry.entryId,
        ordinal: entry.index,
        contentHash: entry.contentHash,
        message: entry.rawMessage,
      );

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
  }) {
    final ownsWatch = _releaseWatchOwnership(
      key: key,
      requestId: requestId,
      provider: provider,
      providerSessionId: providerSessionId,
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
    required int entryCount,
  }) {
    final logicalKey = _logicalWatchKey(provider, providerSessionId);
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
    );
    return null;
  }

  bool _releaseWatchOwnership({
    required ConversationMirrorKey? key,
    required String requestId,
    required String provider,
    required String providerSessionId,
  }) {
    var owned = false;
    final logicalKey = _logicalWatchKey(provider, providerSessionId);
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
          candidate.providerSessionId == providerSessionId;
      if (matches) owned = true;
      return matches;
    });
    return owned;
  }

  String _logicalWatchKey(String provider, String providerSessionId) =>
      '$provider\u0000$providerSessionId';

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

  Future<void> _publishTransferToBoundRuntimes(
    ConversationMirrorKey key,
    _MirrorTransferGuard? transferGuard,
  ) async {
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

  Future<_MirrorPublishResult> _publishKeyToRuntime(
    ConversationMirrorKey key,
    _RuntimePublishGuard guard,
  ) async {
    final initialFailure = _publishGuardFailure(key, guard);
    if (initialFailure != null) return initialFailure;
    _pageCursorsByRuntime.remove(guard.runtimeSessionId);
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
    final postReadFailure = _publishGuardFailure(key, guard);
    if (postReadFailure != null) return postReadFailure;
    final metadataAfter = await _store.readMetadata(key);
    if (metadataAfter == null ||
        metadataAfter.activeGeneration != metadataBefore.activeGeneration ||
        metadataAfter.revision != metadataBefore.revision ||
        metadataAfter.entryCount != metadataBefore.entryCount) {
      return _MirrorPublishResult.invalidated;
    }
    final messages = _decodeRenderableEntries(entries);
    final postDecodeFailure = _publishGuardFailure(key, guard);
    if (postDecodeFailure != null) return postDecodeFailure;
    _pageCursorsByRuntime[guard.runtimeSessionId] = _RuntimeMirrorPageCursor(
      key: key,
      revision: metadataBefore.revision,
      activeGeneration: metadataBefore.activeGeneration,
      entryCount: metadataBefore.entryCount,
      bootstrapGeneration: guard.bootstrapGeneration,
      nextOffset: startOffset,
    );
    _bridge.publishExternalSessionHistory(
      guard.runtimeSessionId,
      messages,
      timestampAnchor: timestampAnchor,
    );
    return _MirrorPublishResult.published;
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
      _pageCursorsByRuntime.remove(runtimeSessionId);
      return const LocalSessionHistoryPage(messages: [], hasMore: false);
    }
    cursor.loading = true;
    try {
      final endOffset = cursor.nextOffset;
      final startOffset = math.max(0, endOffset - limit);
      final metadataBefore = await _store.readMetadata(cursor.key);
      if (!_pageCursorMetadataMatches(cursor, metadataBefore)) {
        if (identical(_pageCursorsByRuntime[runtimeSessionId], cursor)) {
          _pageCursorsByRuntime.remove(runtimeSessionId);
        }
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
        if (identical(_pageCursorsByRuntime[runtimeSessionId], cursor)) {
          _pageCursorsByRuntime.remove(runtimeSessionId);
        }
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

  Future<List<UserInputMessage>?> _loadRuntimeUserIndex({
    required String runtimeSessionId,
  }) async {
    final cursor = _pageCursorsByRuntime[runtimeSessionId];
    if (cursor == null ||
        !_pageCursorIdentityMatches(runtimeSessionId, cursor)) {
      return null;
    }
    final metadataBefore = await _store.readMetadata(cursor.key);
    if (!_pageCursorMetadataMatches(cursor, metadataBefore)) return null;
    final entries = await _store.readUserEntries(cursor.key);
    final metadataAfter = await _store.readMetadata(cursor.key);
    if (!_pageCursorMetadataMatches(cursor, metadataAfter) ||
        !_pageCursorIdentityMatches(runtimeSessionId, cursor) ||
        !identical(_pageCursorsByRuntime[runtimeSessionId], cursor)) {
      return null;
    }
    final messages = <UserInputMessage>[];
    for (final entry in entries) {
      try {
        final message = ServerMessage.fromJson(entry.message);
        if (message is UserInputMessage &&
            !message.isSynthetic &&
            !message.isMeta) {
          messages.add(message);
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
    final key = ConversationMirrorKey(
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
      contentEpoch: _bridge.cachedSessionContentEpoch(runtimeSessionId),
      bootstrapGeneration: _bootstrapGenerationByRuntime[runtimeSessionId],
    );
  }

  _MirrorPublishResult? _publishGuardFailure(
    ConversationMirrorKey key,
    _RuntimePublishGuard guard,
  ) {
    if (!_publishIdentityMatches(key, guard)) {
      return _MirrorPublishResult.invalidated;
    }
    if (_bridge.cachedSessionContentEpoch(guard.runtimeSessionId) !=
        guard.contentEpoch) {
      return _MirrorPublishResult.contentChanged;
    }
    return null;
  }

  bool _publishIdentityMatches(
    ConversationMirrorKey key,
    _RuntimePublishGuard guard,
  ) =>
      !_closed &&
      guard.matches(key) &&
      currentBridgeInstanceId == guard.bridgeInstanceId &&
      _bootstrapGenerationByRuntime[guard.runtimeSessionId] ==
          guard.bootstrapGeneration &&
      _bridge.providerSessionIdForRuntime(
            guard.runtimeSessionId,
            provider: key.provider,
          ) ==
          key.providerSessionId;

  bool _hasCanonicalRuntimeHistory(String runtimeSessionId) => _bridge
      .cachedSessionMessages(runtimeSessionId)
      .any(
        (message) =>
            message is UserInputMessage ||
            message is AssistantServerMessage ||
            message is ToolResultMessage,
      );

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

  Future<void> _adoptBridgeIdentity(String bridgeInstanceId) async {
    if (_closed || !_storageAvailable || bridgeInstanceId.isEmpty) return;
    final changed = _currentBridgeInstanceId != bridgeInstanceId;
    _currentBridgeInstanceId = bridgeInstanceId;
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
      _pageCursorsByRuntime.clear();
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
      await _restoreAutoWatches(bridgeInstanceId, records);
    }
  }

  Future<void> _restoreAutoWatches(
    String bridgeInstanceId,
    List<ConversationMirrorMetadata> autoSyncRecords,
  ) async {
    if (_closed) return;
    final records = autoSyncRecords
        .where(
          (record) =>
              record.key.bridgeInstanceId == bridgeInstanceId &&
              record.autoSync &&
              record.hasLocalCopy,
        )
        .take(maxResidentConversations);
    for (final record in records) {
      if (!_bridge.isConnected || _closed) return;
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
          result.success &&
          pending.createsWatch &&
          (_watchRequestIds[key] == requestId ||
              _watchRequestIdsByConversation[_logicalWatchKey(
                    pending.provider,
                    pending.providerSessionId,
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
        );
      } else {
        _stopWatchForRequest(
          key: null,
          requestId: requestId,
          provider: pending.provider,
          providerSessionId: pending.providerSessionId,
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
    await _localFeatureSub?.cancel();
    await _bridgeIdentitySub?.cancel();
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
    _pageCursorsByRuntime.clear();
    _transferGuardsByRequestId.clear();
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
    required this.contentEpoch,
    required this.bootstrapGeneration,
  });

  final String runtimeSessionId;
  final String? bridgeInstanceId;
  final String provider;
  final String providerSessionId;
  final int contentEpoch;
  final int? bootstrapGeneration;

  bool matches(ConversationMirrorKey key) =>
      provider == key.provider && providerSessionId == key.providerSessionId;
}

class _PendingMirrorRequest {
  _PendingMirrorRequest({
    required this.requestId,
    required this.provider,
    required this.providerSessionId,
    required this.projectPath,
    required this.key,
    required this.autoSync,
    required this.createsWatch,
    required this.previousEntryCount,
    required this.previousRevision,
  });

  final String requestId;
  final String provider;
  final String providerSessionId;
  final String projectPath;
  ConversationMirrorKey? key;
  final bool autoSync;
  final bool createsWatch;
  final int previousEntryCount;
  final String? previousRevision;
  String? shadowGeneration;
  bool acceptedByBridge = false;
  final Completer<ConversationMirrorSyncResult> completer = Completer();
  Timer? timer;
}
