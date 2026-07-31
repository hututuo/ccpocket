import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../models/messages.dart'
    show
        BridgeConnectionState,
        ContextUsage,
        ContextUsageErrorMessage,
        ContextUsageMessage,
        ContextUsageResultMessage,
        LocalFeatureRequestErrorMessage,
        LocalFeatureServerMessage,
        SessionInfo,
        SessionUsageInfo,
        SessionUsageResultMessage,
        durableSessionInsightsCapability,
        requestContextUsage,
        requestSessionUsage;
import '../../../services/bridge_service.dart';
import 'session_insights_quota_cache.dart';

/// Standalone source of truth for one Codex session's context and quota data.
///
/// This controller intentionally does not depend on the chat-session Cubit. An old
/// Bridge can ignore either optional RPC: bounded timers then clear the loading
/// state without affecting the chat session.
class SessionInsightsController extends ChangeNotifier {
  static const _uuid = Uuid();
  static final Expando<_SessionInsightsSnapshotCache> _snapshotCaches =
      Expando<_SessionInsightsSnapshotCache>('sessionInsightsSnapshots');
  static final _persistentQuotaCache = SessionInsightsQuotaCache();

  SessionInsightsController({
    required this.sessionId,
    this.runtimeSessionId,
    required this.bridge,
    this.requestTimeout = const Duration(seconds: 12),
    this.contextCacheTimeToLive = const Duration(minutes: 10),
    this.quotaCacheTimeToLive = const Duration(minutes: 10),
    this.durableCacheIdentityConfirmed = false,
    DateTime Function()? clock,
  }) {
    _clock = clock ?? DateTime.now;
    _sourceKey = _stableSourceKey(bridge);
    _connectionEpoch = bridge.currentConnectionBootstrap.connectionEpoch;
    _durableCapabilityAdvertised = _supportsDurableSessionInsights;
    _restoreSnapshot();
    _queuePersistentQuotaRestore();
  }

  /// Stable provider thread identity. Cache entries are always keyed by this.
  final String sessionId;

  /// Bridge runtime alias used for live events and old-Bridge RPC fallback.
  final String? runtimeSessionId;
  final BridgeService bridge;
  final Duration requestTimeout;
  final Duration contextCacheTimeToLive;
  final Duration quotaCacheTimeToLive;

  /// Whether [sessionId] is a confirmed durable provider thread identity.
  ///
  /// Legacy runtime aliases can still be used for requests, but must never
  /// partition phone-local storage.
  final bool durableCacheIdentityConfirmed;
  late final DateTime Function() _clock;

  final List<StreamSubscription<LocalFeatureServerMessage>>
  _sessionSubscriptions = [];
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  StreamSubscription<List<SessionInfo>>? _sessionListSubscription;
  Timer? _contextTimeout;
  Timer? _quotaTimeout;
  Timer? _minuteTimer;
  ContextUsage? _contextUsage;
  SessionUsageResultMessage? _usage;
  bool _contextLoading = false;
  bool _quotaLoading = false;
  bool _started = false;
  bool _disposed = false;
  int _contextGeneration = 0;
  int _quotaGeneration = 0;
  int _quotaCacheRestoreGeneration = 0;
  String? _contextRequestId;
  String? _contextRequestSessionId;
  String? _contextRequestSourceKey;
  int? _contextRequestConnectionEpoch;
  bool _contextRequestUsesLegacyLane = false;
  final Object _legacyContextLaneOwner = Object();
  String? _quotaRequestId;
  String? _quotaRequestSessionId;
  String? _sourceKey;
  late int _connectionEpoch;
  late bool _durableCapabilityAdvertised;
  bool _waitingForAuthoritativeSessionList = false;
  String? _lastContextFingerprint;
  Future<void> _quotaCacheOperation = Future<void>.value();

  ContextUsage? get contextUsage => _contextUsage;
  SessionUsageResultMessage? get usage => _usage;
  bool get contextLoading => _contextLoading;
  bool get quotaLoading => _quotaLoading;
  bool get isLoading => _contextLoading || _quotaLoading;

  @visibleForTesting
  String? get debugPendingQuotaRequestId => _quotaRequestId;

  @visibleForTesting
  String? get debugPendingContextRequestId => _contextRequestId;

  @visibleForTesting
  Future<void> get debugQuotaCacheIdle => _quotaCacheOperation;

  @visibleForTesting
  String? get debugContextRequestSessionId => _contextRequestSessionId;

  SessionUsageInfo? get codexUsage {
    for (final provider in _usage?.providers ?? const <SessionUsageInfo>[]) {
      if (provider.provider == 'codex') return provider;
    }
    return null;
  }

  bool get hasVisibleData =>
      (_contextUsage?.modelContextWindow ?? 0) > 0 ||
      (codexUsage?.hasData ?? false);

  void start() {
    if (_started || _disposed) return;
    _started = true;
    final aliases = <String>{sessionId, ?_normalizedRuntimeSessionId};
    for (final alias in aliases) {
      _sessionSubscriptions.add(
        bridge.localFeatureMessagesForSession(alias).listen(_onSessionMessage),
      );
    }
    _connectionSubscription = bridge.connectionStatus.listen(
      _onConnectionState,
    );
    _sessionListSubscription = bridge.sessionList.listen(_onSessionList);
    _minuteTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!_disposed) notifyListeners();
    });
    if (bridge.isConnected &&
        bridge.hasAuthoritativeSessionListForCurrentConnection) {
      refresh();
    } else {
      _waitingForAuthoritativeSessionList = bridge.isConnected;
    }
  }

  void refresh({bool force = false}) {
    if (_disposed || !bridge.isConnected) {
      _clearLoading();
      return;
    }
    if (!bridge.hasAuthoritativeSessionListForCurrentConnection) {
      _waitingForAuthoritativeSessionList = true;
      return;
    }
    _synchronizeSourceIdentity(clearWhenUnavailable: false);
    _requestContext(force: force);
    _requestQuota(force: force);
  }

  void _requestContext({required bool force}) {
    final correlated = _supportsDurableSessionInsights;
    if (_contextLoading && (!force || !correlated)) return;
    if (_contextLoading) {
      _abandonPendingContext(quarantineLegacy: true);
    }
    final requestSessionId = _insightsRequestSessionId;
    final requestId = correlated ? _uuid.v4() : null;
    if (!correlated &&
        !bridge.tryAcquireLegacySessionInsightsContextLane(
          requestSessionId,
          _legacyContextLaneOwner,
        )) {
      return;
    }
    _contextTimeout?.cancel();
    final generation = ++_contextGeneration;
    _contextRequestId = requestId;
    _contextRequestSessionId = requestSessionId;
    _contextRequestSourceKey = _sourceKey;
    _contextRequestConnectionEpoch = _connectionEpoch;
    _contextRequestUsesLegacyLane = !correlated;
    _contextLoading = true;
    notifyListeners();
    try {
      bridge.send(requestContextUsage(requestSessionId, requestId: requestId));
    } catch (_) {
      if (generation == _contextGeneration) {
        _finishContextRequest();
        notifyListeners();
      }
      return;
    }
    _contextTimeout = Timer(requestTimeout, () {
      if (_disposed || generation != _contextGeneration) return;
      _abandonPendingContext(quarantineLegacy: true);
      notifyListeners();
    });
  }

  void _requestQuota({required bool force}) {
    if (_quotaLoading && !force) return;
    _quotaTimeout?.cancel();
    final generation = ++_quotaGeneration;
    final requestId = _uuid.v4();
    _quotaRequestId = requestId;
    _quotaRequestSessionId = _insightsRequestSessionId;
    _quotaLoading = true;
    notifyListeners();
    try {
      bridge.send(
        requestSessionUsage(
          sessionId: _quotaRequestSessionId!,
          requestId: requestId,
        ),
      );
    } catch (_) {
      if (generation == _quotaGeneration) {
        _quotaRequestId = null;
        _quotaRequestSessionId = null;
        _quotaLoading = false;
        notifyListeners();
      }
      return;
    }
    _quotaTimeout = Timer(requestTimeout, () {
      if (_disposed || generation != _quotaGeneration) return;
      _quotaRequestId = null;
      _quotaRequestSessionId = null;
      _quotaLoading = false;
      notifyListeners();
    });
  }

  void _onSessionMessage(LocalFeatureServerMessage message) {
    final sourceChanged = _synchronizeSourceIdentity(
      clearWhenUnavailable: false,
    );
    if (sourceChanged) {
      if (!_disposed) {
        notifyListeners();
        scheduleMicrotask(() {
          if (!_disposed) refresh(force: true);
        });
      }
      // This event was emitted before the controller observed the source or
      // socket-generation transition. Live events and legacy replies remain
      // uncorrelated, so consuming it here could cross data-source identity.
      return;
    }
    if (message case LocalFeatureRequestErrorMessage()) {
      if (message.featureId != 'session_insights') return;
      if (message.requestType == 'get_context_usage' &&
          _matchesPendingContextRequest(
            sessionId: message.ownerSessionId,
            requestId: message.requestId,
          )) {
        _finishContextRequest();
        notifyListeners();
        return;
      }
      if (message.requestType == 'get_session_usage' &&
          message.requestId == _quotaRequestId) {
        _quotaRequestId = null;
        _quotaRequestSessionId = null;
        _quotaLoading = false;
        _quotaGeneration++;
        _quotaTimeout?.cancel();
        notifyListeners();
      }
      return;
    }
    if (message case ContextUsageMessage()) {
      if (!_isContextAlias(message.sessionId)) return;
      if (!_supportsDurableSessionInsights &&
          bridge.isLegacySessionInsightsContextLaneQuarantined(
            message.sessionId,
          )) {
        return;
      }
      final completesLegacyRequest =
          _contextRequestUsesLegacyLane &&
          _matchesPendingContextRequest(
            sessionId: message.sessionId,
            requestId: null,
          );
      final changed = _applyContextUsage(message.usage);
      if (completesLegacyRequest) _finishContextRequest();
      if (changed || completesLegacyRequest) notifyListeners();
      return;
    }
    if (message case ContextUsageResultMessage()) {
      if (!_matchesPendingContextRequest(
        sessionId: message.sessionId,
        requestId: message.requestId,
      )) {
        return;
      }
      _applyContextUsage(message.usage);
      _finishContextRequest();
      notifyListeners();
      return;
    }
    if (message case ContextUsageErrorMessage()) {
      if (!_matchesPendingContextRequest(
        sessionId: message.sessionId,
        requestId: message.requestId,
      )) {
        return;
      }
      _finishContextRequest();
      notifyListeners();
      return;
    }
    if (message case SessionUsageResultMessage()) {
      _onUsage(message);
    }
  }

  void _onUsage(SessionUsageResultMessage usage) {
    final expectedRequestId = _quotaRequestId;
    final expectedSessionId = _quotaRequestSessionId;
    if (expectedRequestId == null ||
        expectedSessionId == null ||
        usage.sessionId != expectedSessionId ||
        usage.requestId != expectedRequestId) {
      return;
    }
    if (_quotaWithWindows(usage) case final quota?) {
      _usage = usage;
      _rememberQuotaSnapshot(quota);
    } else if (_quotaWithWindows(_usage) == null) {
      // Preserve the last useful rings across transient top-level failures and
      // provider error-only compatibility fallbacks. With no prior snapshot,
      // keep the response so first-load diagnostics retain their old behavior.
      _usage = usage;
    }
    _quotaRequestId = null;
    _quotaRequestSessionId = null;
    _quotaLoading = false;
    _quotaGeneration++;
    _quotaTimeout?.cancel();
    notifyListeners();
  }

  void _onConnectionState(BridgeConnectionState state) {
    if (state == BridgeConnectionState.connected) {
      _synchronizeSourceIdentity(clearWhenUnavailable: true);
      if (bridge.hasAuthoritativeSessionListForCurrentConnection) {
        _durableCapabilityAdvertised = _supportsDurableSessionInsights;
        _waitingForAuthoritativeSessionList = false;
        refresh(force: true);
      } else {
        _waitingForAuthoritativeSessionList = true;
      }
      return;
    }
    _waitingForAuthoritativeSessionList = false;
    _clearLoading();
  }

  void _onSessionList(List<SessionInfo> _) {
    if (_disposed ||
        !bridge.isConnected ||
        !bridge.hasAuthoritativeSessionListForCurrentConnection) {
      return;
    }
    final sourceOrEpochChanged = _synchronizeSourceIdentity(
      clearWhenUnavailable: true,
    );
    final durableCapabilityAdvertised = _supportsDurableSessionInsights;
    final capabilityChanged =
        durableCapabilityAdvertised != _durableCapabilityAdvertised;
    final shouldRefresh =
        _waitingForAuthoritativeSessionList ||
        sourceOrEpochChanged ||
        capabilityChanged;
    _waitingForAuthoritativeSessionList = false;
    _durableCapabilityAdvertised = durableCapabilityAdvertised;
    if (shouldRefresh) refresh(force: true);
  }

  void _clearLoading() {
    final changed = _contextLoading || _quotaLoading;
    _abandonPendingContext(quarantineLegacy: false);
    _contextGeneration++;
    _quotaGeneration++;
    _quotaRequestId = null;
    _quotaRequestSessionId = null;
    _contextTimeout?.cancel();
    _quotaTimeout?.cancel();
    _contextLoading = false;
    _quotaLoading = false;
    if (changed && !_disposed) notifyListeners();
  }

  bool _synchronizeSourceIdentity({required bool clearWhenUnavailable}) {
    final nextSourceKey = _stableSourceKey(bridge);
    final nextConnectionEpoch =
        bridge.currentConnectionBootstrap.connectionEpoch;
    if (nextSourceKey == null &&
        !clearWhenUnavailable &&
        nextConnectionEpoch == _connectionEpoch) {
      return false;
    }
    final sourceChanged = nextSourceKey != _sourceKey;
    final connectionChanged = nextConnectionEpoch != _connectionEpoch;
    if (!sourceChanged && !connectionChanged) return false;
    _abandonPendingContext(quarantineLegacy: false);
    _contextGeneration++;
    _quotaGeneration++;
    _quotaRequestId = null;
    _quotaRequestSessionId = null;
    _contextTimeout?.cancel();
    _quotaTimeout?.cancel();
    _contextLoading = false;
    _quotaLoading = false;
    _sourceKey = nextSourceKey;
    _connectionEpoch = nextConnectionEpoch;
    if (sourceChanged) {
      _contextUsage = null;
      _usage = null;
      _lastContextFingerprint = null;
      _restoreSnapshot();
      _queuePersistentQuotaRestore();
    }
    return true;
  }

  void _restoreSnapshot() {
    final snapshotKey = _snapshotKey;
    if (snapshotKey == null) return;
    final snapshot = _cacheForBridge.read(
      snapshotKey,
      now: _clock(),
      contextTimeToLive: contextCacheTimeToLive,
      quotaTimeToLive: quotaCacheTimeToLive,
    );
    if (snapshot == null) return;
    _contextUsage = snapshot.contextUsage;
    _usage = snapshot.usage;
    _lastContextFingerprint = _contextFingerprint(_contextUsage);
  }

  void _rememberContextSnapshot() {
    final snapshotKey = _snapshotKey;
    final contextUsage = _contextUsage;
    if (snapshotKey == null || contextUsage == null) return;
    _cacheForBridge.writeContext(snapshotKey, contextUsage, cachedAt: _clock());
  }

  void _rememberQuotaSnapshot(
    SessionUsageInfo quota, {
    DateTime? cachedAt,
    bool persist = true,
  }) {
    final snapshotKey = _snapshotKey;
    final usage = _usage;
    if (snapshotKey == null || usage == null) return;
    final effectiveCachedAt = cachedAt ?? _clock();
    _cacheForBridge.writeQuota(snapshotKey, usage, cachedAt: effectiveCachedAt);
    final sourceKey = _sourceKey;
    if (!persist || !durableCacheIdentityConfirmed || sourceKey == null) {
      return;
    }
    _enqueueQuotaCacheOperation(
      () => _persistentQuotaCache.write(
        sourceKey: sourceKey,
        sessionId: sessionId,
        quota: quota,
        cachedAt: effectiveCachedAt,
      ),
    );
  }

  void _queuePersistentQuotaRestore() {
    final sourceKey = _sourceKey;
    final restoreGeneration = ++_quotaCacheRestoreGeneration;
    if (!durableCacheIdentityConfirmed || sourceKey == null) return;
    _enqueueQuotaCacheOperation(() async {
      final snapshot = await _persistentQuotaCache.read(
        sourceKey: sourceKey,
        sessionId: sessionId,
        now: _clock(),
        timeToLive: quotaCacheTimeToLive,
      );
      if (_disposed ||
          restoreGeneration != _quotaCacheRestoreGeneration ||
          sourceKey != _sourceKey ||
          sourceKey != _stableSourceKey(bridge) ||
          snapshot == null ||
          _quotaWithWindows(_usage) != null) {
        return;
      }
      _usage = SessionUsageResultMessage(
        sessionId: sessionId,
        requestId: 'phone-local-cache',
        providers: [snapshot.quota],
      );
      _rememberQuotaSnapshot(
        snapshot.quota,
        cachedAt: snapshot.cachedAt,
        persist: false,
      );
      notifyListeners();
    });
  }

  void _enqueueQuotaCacheOperation(Future<void> Function() operation) {
    final next = _quotaCacheOperation.then((_) => operation());
    _quotaCacheOperation = next.catchError((Object _) {});
    unawaited(_quotaCacheOperation);
  }

  static SessionUsageInfo? _quotaWithWindows(SessionUsageResultMessage? usage) {
    if (usage == null || usage.error != null) return null;
    for (final provider in usage.providers) {
      if (provider.provider == 'codex' &&
          SessionInsightsQuotaCache.hasQuotaWindows(provider)) {
        return provider;
      }
    }
    return null;
  }

  _SessionInsightsSnapshotCache get _cacheForBridge =>
      _snapshotCaches[bridge] ??= _SessionInsightsSnapshotCache();

  String? get _snapshotKey {
    final sourceKey = _sourceKey;
    if (sourceKey == null) return null;
    return '$sourceKey\u0000$sessionId';
  }

  bool get _supportsDurableSessionInsights =>
      bridge.bridgeCapabilities.contains(durableSessionInsightsCapability);

  String? get _normalizedRuntimeSessionId {
    final value = runtimeSessionId?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  String get _insightsRequestSessionId => _supportsDurableSessionInsights
      ? sessionId
      : (_normalizedRuntimeSessionId ?? sessionId);

  bool _isContextAlias(String? candidate) =>
      candidate == sessionId ||
      (_normalizedRuntimeSessionId != null &&
          candidate == _normalizedRuntimeSessionId);

  bool _matchesPendingContextRequest({
    required String? sessionId,
    required String? requestId,
  }) {
    if (!_contextLoading ||
        sessionId != _contextRequestSessionId ||
        _contextRequestSourceKey != _sourceKey ||
        _contextRequestConnectionEpoch != _connectionEpoch) {
      return false;
    }
    final expectedRequestId = _contextRequestId;
    if (expectedRequestId != null) return requestId == expectedRequestId;
    return requestId == null &&
        _contextRequestUsesLegacyLane &&
        bridge.ownsLegacySessionInsightsContextLane(
          _contextRequestSessionId!,
          _legacyContextLaneOwner,
        );
  }

  bool _applyContextUsage(ContextUsage usage) {
    final fingerprint = _contextFingerprint(usage);
    if (fingerprint == _lastContextFingerprint) return false;
    _lastContextFingerprint = fingerprint;
    _contextUsage = usage;
    _rememberContextSnapshot();
    return true;
  }

  void _finishContextRequest() {
    final requestSessionId = _contextRequestSessionId;
    if (_contextRequestUsesLegacyLane && requestSessionId != null) {
      bridge.releaseLegacySessionInsightsContextLane(
        requestSessionId,
        _legacyContextLaneOwner,
      );
    }
    _contextLoading = false;
    _contextGeneration++;
    _contextTimeout?.cancel();
    _contextRequestId = null;
    _contextRequestSessionId = null;
    _contextRequestSourceKey = null;
    _contextRequestConnectionEpoch = null;
    _contextRequestUsesLegacyLane = false;
  }

  void _abandonPendingContext({required bool quarantineLegacy}) {
    final requestSessionId = _contextRequestSessionId;
    if (_contextRequestUsesLegacyLane && requestSessionId != null) {
      if (quarantineLegacy) {
        bridge.quarantineLegacySessionInsightsContextLane(
          requestSessionId,
          _legacyContextLaneOwner,
        );
      } else {
        bridge.releaseLegacySessionInsightsContextLane(
          requestSessionId,
          _legacyContextLaneOwner,
        );
      }
    }
    _contextLoading = false;
    _contextTimeout?.cancel();
    _contextRequestId = null;
    _contextRequestSessionId = null;
    _contextRequestSourceKey = null;
    _contextRequestConnectionEpoch = null;
    _contextRequestUsesLegacyLane = false;
  }

  static String? _contextFingerprint(ContextUsage? usage) {
    if (usage == null) return null;
    final last = usage.last;
    final total = usage.total;
    return [
      usage.threadId ?? '',
      usage.turnId ?? '',
      last.totalTokens,
      last.inputTokens,
      last.cachedInputTokens,
      last.outputTokens,
      last.reasoningOutputTokens,
      total.totalTokens,
      total.inputTokens,
      total.cachedInputTokens,
      total.outputTokens,
      total.reasoningOutputTokens,
      usage.modelContextWindow,
    ].join(':');
  }

  static String? _stableSourceKey(BridgeService bridge) {
    final bridgeInstanceId = bridge.bridgeInstanceId?.trim();
    if (bridgeInstanceId == null || bridgeInstanceId.isEmpty) return null;
    final codexSourceId = bridge.codexSourceId?.trim();
    if (codexSourceId == null || codexSourceId.isEmpty) return null;
    return 'bridge:${Uri.encodeComponent(bridgeInstanceId)}'
        '|codex:${Uri.encodeComponent(codexSourceId)}';
  }

  @override
  void dispose() {
    _disposed = true;
    _quotaCacheRestoreGeneration++;
    _abandonPendingContext(quarantineLegacy: bridge.isConnected);
    for (final subscription in _sessionSubscriptions) {
      subscription.cancel();
    }
    _sessionSubscriptions.clear();
    _connectionSubscription?.cancel();
    _sessionListSubscription?.cancel();
    _contextTimeout?.cancel();
    _quotaTimeout?.cancel();
    _minuteTimer?.cancel();
    super.dispose();
  }
}

class _SessionInsightsSnapshot {
  const _SessionInsightsSnapshot({
    required this.contextUsage,
    required this.usage,
    required this.contextCachedAt,
    required this.quotaCachedAt,
  });

  final ContextUsage? contextUsage;
  final SessionUsageResultMessage? usage;
  final DateTime? contextCachedAt;
  final DateTime? quotaCachedAt;
}

class _SessionInsightsSnapshotCache {
  static const _maximumEntries = 32;

  final LinkedHashMap<String, _SessionInsightsSnapshot> _snapshots =
      LinkedHashMap<String, _SessionInsightsSnapshot>();

  _SessionInsightsSnapshot? read(
    String key, {
    required DateTime now,
    required Duration contextTimeToLive,
    required Duration quotaTimeToLive,
  }) {
    _removeEmptyOrExpired(
      now: now,
      contextTimeToLive: contextTimeToLive,
      quotaTimeToLive: quotaTimeToLive,
    );
    final snapshot = _snapshots.remove(key);
    if (snapshot == null) return null;
    final filtered = _filteredSnapshot(
      snapshot,
      now: now,
      contextTimeToLive: contextTimeToLive,
      quotaTimeToLive: quotaTimeToLive,
    );
    if (filtered == null) return null;
    _snapshots[key] = filtered;
    return filtered;
  }

  void writeContext(
    String key,
    ContextUsage contextUsage, {
    required DateTime cachedAt,
  }) {
    final previous = _snapshots.remove(key);
    _snapshots[key] = _SessionInsightsSnapshot(
      contextUsage: contextUsage,
      usage: previous?.usage,
      contextCachedAt: cachedAt,
      quotaCachedAt: previous?.quotaCachedAt,
    );
    _trim();
  }

  void writeQuota(
    String key,
    SessionUsageResultMessage usage, {
    required DateTime cachedAt,
  }) {
    final previous = _snapshots.remove(key);
    _snapshots[key] = _SessionInsightsSnapshot(
      contextUsage: previous?.contextUsage,
      usage: usage,
      contextCachedAt: previous?.contextCachedAt,
      quotaCachedAt: cachedAt,
    );
    _trim();
  }

  void _removeEmptyOrExpired({
    required DateTime now,
    required Duration contextTimeToLive,
    required Duration quotaTimeToLive,
  }) {
    _snapshots.updateAll(
      (_, snapshot) =>
          _filteredSnapshot(
            snapshot,
            now: now,
            contextTimeToLive: contextTimeToLive,
            quotaTimeToLive: quotaTimeToLive,
          ) ??
          const _SessionInsightsSnapshot(
            contextUsage: null,
            usage: null,
            contextCachedAt: null,
            quotaCachedAt: null,
          ),
    );
    _snapshots.removeWhere(
      (_, snapshot) => snapshot.contextUsage == null && snapshot.usage == null,
    );
  }

  _SessionInsightsSnapshot? _filteredSnapshot(
    _SessionInsightsSnapshot snapshot, {
    required DateTime now,
    required Duration contextTimeToLive,
    required Duration quotaTimeToLive,
  }) {
    final contextFresh = _isFresh(
      snapshot.contextCachedAt,
      contextTimeToLive,
      now,
    );
    final quotaFresh = _isFresh(snapshot.quotaCachedAt, quotaTimeToLive, now);
    if (!contextFresh && !quotaFresh) return null;
    return _SessionInsightsSnapshot(
      contextUsage: contextFresh ? snapshot.contextUsage : null,
      usage: quotaFresh ? snapshot.usage : null,
      contextCachedAt: contextFresh ? snapshot.contextCachedAt : null,
      quotaCachedAt: quotaFresh ? snapshot.quotaCachedAt : null,
    );
  }

  bool _isFresh(DateTime? cachedAt, Duration timeToLive, DateTime now) {
    if (cachedAt == null) return false;
    return !cachedAt.isBefore(now.subtract(timeToLive));
  }

  void _trim() {
    while (_snapshots.length > _maximumEntries) {
      _snapshots.remove(_snapshots.keys.first);
    }
  }
}
