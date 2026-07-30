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
        SessionUsageInfo,
        SessionUsageResultMessage,
        requestContextUsage,
        requestSessionUsage;
import '../../../services/bridge_service.dart';

/// Standalone source of truth for one Codex session's context and quota data.
///
/// This controller intentionally does not depend on the chat-session Cubit. An old
/// Bridge can ignore either optional RPC: bounded timers then clear the loading
/// state without affecting the chat session.
class SessionInsightsController extends ChangeNotifier {
  static const _uuid = Uuid();
  static final Expando<_SessionInsightsSnapshotCache> _snapshotCaches =
      Expando<_SessionInsightsSnapshotCache>('sessionInsightsSnapshots');

  SessionInsightsController({
    required this.sessionId,
    required this.bridge,
    this.requestTimeout = const Duration(seconds: 12),
  }) {
    _sourceKey = _stableSourceKey(bridge);
    _restoreSnapshot();
  }

  final String sessionId;
  final BridgeService bridge;
  final Duration requestTimeout;

  StreamSubscription<LocalFeatureServerMessage>? _sessionSubscription;
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
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
  String? _quotaRequestId;
  String? _sourceKey;

  ContextUsage? get contextUsage => _contextUsage;
  SessionUsageResultMessage? get usage => _usage;
  bool get contextLoading => _contextLoading;
  bool get quotaLoading => _quotaLoading;
  bool get isLoading => _contextLoading || _quotaLoading;

  @visibleForTesting
  String? get debugPendingQuotaRequestId => _quotaRequestId;

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
    _sessionSubscription = bridge
        .localFeatureMessagesForSession(sessionId)
        .listen(_onSessionMessage);
    _connectionSubscription = bridge.connectionStatus.listen(
      _onConnectionState,
    );
    _minuteTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!_disposed) notifyListeners();
    });
    if (bridge.isConnected) refresh();
  }

  void refresh({bool force = false}) {
    if (_disposed || !bridge.isConnected) {
      _clearLoading();
      return;
    }
    _synchronizeSourceIdentity(clearWhenUnavailable: false);
    _requestContext(force: force);
    _requestQuota(force: force);
  }

  void _requestContext({required bool force}) {
    if (_contextLoading && !force) return;
    _contextTimeout?.cancel();
    final generation = ++_contextGeneration;
    _contextLoading = true;
    notifyListeners();
    try {
      bridge.send(requestContextUsage(sessionId));
    } catch (_) {
      if (generation == _contextGeneration) {
        _contextLoading = false;
        notifyListeners();
      }
      return;
    }
    _contextTimeout = Timer(requestTimeout, () {
      if (_disposed || generation != _contextGeneration) return;
      _contextLoading = false;
      notifyListeners();
    });
  }

  void _requestQuota({required bool force}) {
    if (_quotaLoading && !force) return;
    _quotaTimeout?.cancel();
    final generation = ++_quotaGeneration;
    final requestId = _uuid.v4();
    _quotaRequestId = requestId;
    _quotaLoading = true;
    notifyListeners();
    try {
      bridge.send(
        requestSessionUsage(sessionId: sessionId, requestId: requestId),
      );
    } catch (_) {
      if (generation == _quotaGeneration) {
        _quotaRequestId = null;
        _quotaLoading = false;
        notifyListeners();
      }
      return;
    }
    _quotaTimeout = Timer(requestTimeout, () {
      if (_disposed || generation != _quotaGeneration) return;
      _quotaRequestId = null;
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
      // This event was emitted before the controller observed the source
      // transition. Context replies have no requestId, so consuming it here
      // could associate an old source's result with the new source.
      return;
    }
    if (message case LocalFeatureRequestErrorMessage()) {
      if (message.featureId != 'session_insights') return;
      if (message.requestType == 'get_context_usage') {
        _contextLoading = false;
        _contextGeneration++;
        _contextTimeout?.cancel();
        notifyListeners();
        return;
      }
      if (message.requestType == 'get_session_usage' &&
          message.requestId == _quotaRequestId) {
        _quotaRequestId = null;
        _quotaLoading = false;
        _quotaGeneration++;
        _quotaTimeout?.cancel();
        notifyListeners();
      }
      return;
    }
    if (message case ContextUsageMessage()) {
      if (message.sessionId != sessionId) return;
      _contextUsage = message.usage;
      _rememberSnapshot();
      _contextLoading = false;
      _contextGeneration++;
      _contextTimeout?.cancel();
      notifyListeners();
      return;
    }
    if (message case ContextUsageResultMessage()) {
      if (message.sessionId != sessionId) return;
      _contextUsage = message.usage;
      _rememberSnapshot();
      _contextLoading = false;
      _contextGeneration++;
      _contextTimeout?.cancel();
      notifyListeners();
      return;
    }
    if (message case ContextUsageErrorMessage()) {
      if (message.sessionId != sessionId) return;
      _contextLoading = false;
      _contextGeneration++;
      _contextTimeout?.cancel();
      notifyListeners();
      return;
    }
    if (message case SessionUsageResultMessage()) {
      _onUsage(message);
    }
  }

  void _onUsage(SessionUsageResultMessage usage) {
    final expectedRequestId = _quotaRequestId;
    if (expectedRequestId == null ||
        usage.sessionId != sessionId ||
        usage.requestId != expectedRequestId) {
      return;
    }
    _usage = usage;
    if (usage.error == null) _rememberSnapshot();
    _quotaRequestId = null;
    _quotaLoading = false;
    _quotaGeneration++;
    _quotaTimeout?.cancel();
    notifyListeners();
  }

  void _onConnectionState(BridgeConnectionState state) {
    if (state == BridgeConnectionState.connected) {
      _synchronizeSourceIdentity(clearWhenUnavailable: true);
      refresh(force: true);
      return;
    }
    _clearLoading();
  }

  void _clearLoading() {
    _contextGeneration++;
    _quotaGeneration++;
    _quotaRequestId = null;
    _contextTimeout?.cancel();
    _quotaTimeout?.cancel();
    final changed = _contextLoading || _quotaLoading;
    _contextLoading = false;
    _quotaLoading = false;
    if (changed && !_disposed) notifyListeners();
  }

  bool _synchronizeSourceIdentity({required bool clearWhenUnavailable}) {
    final nextSourceKey = _stableSourceKey(bridge);
    if (nextSourceKey == null && !clearWhenUnavailable) return false;
    if (nextSourceKey == _sourceKey) return false;
    _contextGeneration++;
    _quotaGeneration++;
    _quotaRequestId = null;
    _contextTimeout?.cancel();
    _quotaTimeout?.cancel();
    _contextLoading = false;
    _quotaLoading = false;
    _sourceKey = nextSourceKey;
    _contextUsage = null;
    _usage = null;
    _restoreSnapshot();
    return true;
  }

  void _restoreSnapshot() {
    final snapshotKey = _snapshotKey;
    if (snapshotKey == null) return;
    final snapshot = _cacheForBridge.read(snapshotKey);
    if (snapshot == null) return;
    _contextUsage = snapshot.contextUsage;
    _usage = snapshot.usage;
  }

  void _rememberSnapshot() {
    final snapshotKey = _snapshotKey;
    if (snapshotKey == null) return;
    _cacheForBridge.write(
      snapshotKey,
      contextUsage: _contextUsage,
      usage: _usage?.error == null ? _usage : null,
    );
  }

  _SessionInsightsSnapshotCache get _cacheForBridge =>
      _snapshotCaches[bridge] ??= _SessionInsightsSnapshotCache();

  String? get _snapshotKey {
    final sourceKey = _sourceKey;
    if (sourceKey == null) return null;
    return '$sourceKey\u0000$sessionId';
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
    _sessionSubscription?.cancel();
    _connectionSubscription?.cancel();
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
    required this.cachedAt,
  });

  final ContextUsage? contextUsage;
  final SessionUsageResultMessage? usage;
  final DateTime cachedAt;
}

class _SessionInsightsSnapshotCache {
  static const _maximumEntries = 32;
  static const _timeToLive = Duration(minutes: 10);

  final LinkedHashMap<String, _SessionInsightsSnapshot> _snapshots =
      LinkedHashMap<String, _SessionInsightsSnapshot>();

  _SessionInsightsSnapshot? read(String key) {
    _removeExpired();
    final snapshot = _snapshots.remove(key);
    if (snapshot == null) return null;
    _snapshots[key] = snapshot;
    return snapshot;
  }

  void write(
    String key, {
    required ContextUsage? contextUsage,
    required SessionUsageResultMessage? usage,
  }) {
    if (contextUsage == null && usage == null) return;
    _removeExpired();
    final previous = _snapshots.remove(key);
    _snapshots[key] = _SessionInsightsSnapshot(
      contextUsage: contextUsage ?? previous?.contextUsage,
      usage: usage ?? previous?.usage,
      cachedAt: DateTime.now(),
    );
    while (_snapshots.length > _maximumEntries) {
      _snapshots.remove(_snapshots.keys.first);
    }
  }

  void _removeExpired() {
    final cutoff = DateTime.now().subtract(_timeToLive);
    _snapshots.removeWhere((_, snapshot) => snapshot.cachedAt.isBefore(cutoff));
  }
}
