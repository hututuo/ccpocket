import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../models/messages.dart';
import '../../services/bridge_service.dart';

/// Keeps Desktop-originated activity visible in the active-session list.
///
/// The conversation cubit temporarily replaces this watch while a chat is
/// open. Once that watch is released, this tracker reclaims list-level
/// observation without polling or creating a second Bridge runtime.
class DesktopSessionListContinuityTracker {
  DesktopSessionListContinuityTracker(
    this._bridge, {
    this.watchAckTimeout = const Duration(seconds: 4),
    this.watchRetryBase = const Duration(milliseconds: 750),
    this.watchRetryMax = const Duration(seconds: 8),
    this.maxWatchRetryAttempts = 6,
    this.watchHalfOpenDelay = const Duration(minutes: 1),
    this.historyFallbackDelay = const Duration(seconds: 2),
  }) {
    assert(maxWatchRetryAttempts > 0);
    assert(watchHalfOpenDelay > Duration.zero);
    _sessionSubscription = _bridge.sessionList.listen(_syncSessions);
    _connectionSubscription = _bridge.connectionStatus.listen(_onConnection);
    _featureSubscription = _bridge.localFeatureMessages.listen(
      _onFeatureMessage,
    );
    _syncSessions(_bridge.sessions);
  }

  final BridgeService _bridge;
  final Duration watchAckTimeout;
  final Duration watchRetryBase;
  final Duration watchRetryMax;
  final int maxWatchRetryAttempts;
  final Duration watchHalfOpenDelay;
  final Duration historyFallbackDelay;
  final _uuid = const Uuid();
  StreamSubscription<List<SessionInfo>>? _sessionSubscription;
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  StreamSubscription<LocalFeatureServerMessage>? _featureSubscription;
  final Set<String> _trackedSessionIds = {};
  final Map<String, SessionInfo> _trackedSessions = {};
  final Map<String, String> _ownedRequestIds = {};
  final Map<String, String> _displacedByConversation = {};
  final Set<String> _suppressedSessionIds = {};
  final Map<String, Timer> _watchAckTimers = {};
  final Map<String, Timer> _watchRetryTimers = {};
  final Map<String, int> _watchRetryAttempts = {};
  final Map<String, Timer> _historyFallbackTimers = {};
  final Set<String> _historyDirtySessionIds = {};
  final Map<String, String> _lastReconciledHistoryReadyKey = {};
  bool _ensureScheduled = false;
  bool _unsupported = false;
  bool _closed = false;

  void _syncSessions(List<SessionInfo> sessions) {
    if (_closed) return;
    final codex = <String, SessionInfo>{
      for (final session in sessions)
        if (session.provider == Provider.codex.value &&
            session.claudeSessionId?.trim().isNotEmpty == true)
          session.id: session,
    };

    for (final sessionId in _trackedSessionIds.toList(growable: false)) {
      if (codex.containsKey(sessionId)) continue;
      _trackedSessionIds.remove(sessionId);
      _trackedSessions.remove(sessionId);
      _ownedRequestIds.remove(sessionId);
      _displacedByConversation.remove(sessionId);
      _suppressedSessionIds.remove(sessionId);
      _historyDirtySessionIds.remove(sessionId);
      _lastReconciledHistoryReadyKey.remove(sessionId);
      _cancelSessionTimers(sessionId);
      _bridge.clearBackgroundDesktopContinuity(sessionId);
    }
    for (final session in codex.values) {
      final newlyTracked = _trackedSessionIds.add(session.id);
      _trackedSessions[session.id] = session;
      if (newlyTracked && _bridge.cachedSessionMessages(session.id).isEmpty) {
        // A cold list has no canonical preview yet. One initial fallback keeps
        // old Bridges useful; later tracker remounts reuse the runtime cache
        // instead of requesting the same history again.
        _markHistoryDirty(session.id);
      }
    }
    for (final session in codex.values) {
      _ensureWatch(session);
    }
    _scheduleEnsureAfterSessionList();
  }

  void _scheduleEnsureAfterSessionList() {
    if (_closed || _ensureScheduled) return;
    _ensureScheduled = true;
    scheduleMicrotask(() {
      _ensureScheduled = false;
      if (_closed) return;
      for (final session in _trackedSessions.values) {
        _ensureWatch(session);
      }
    });
  }

  void _ensureWatch(SessionInfo session) {
    if (_closed ||
        _unsupported ||
        !_bridge.isConnected ||
        !_bridge.bridgeCapabilities.contains(
          codexDesktopContinuityBridgeCapability,
        ) ||
        _suppressedSessionIds.contains(session.id) ||
        _displacedByConversation.containsKey(session.id) ||
        _watchRetryTimers.containsKey(session.id) ||
        _ownedRequestIds.containsKey(session.id)) {
      return;
    }
    final threadId = session.claudeSessionId?.trim();
    if (threadId == null || threadId.isEmpty || session.projectPath.isEmpty) {
      return;
    }
    final requestId = 'list-${_uuid.v4()}';
    _ownedRequestIds[session.id] = requestId;
    try {
      _bridge.send(
        requestCodexDesktopContinuityWatch(
          requestId: requestId,
          sessionId: session.id,
          threadId: threadId,
          projectPath: session.projectPath,
        ),
      );
      _startWatchAckTimer(session.id, requestId);
    } catch (_) {
      _ownedRequestIds.remove(session.id);
      _scheduleWatchRetry(session.id);
    }
  }

  void _onFeatureMessage(LocalFeatureServerMessage message) {
    if (_closed) return;
    if (message case LocalFeatureRequestErrorMessage(
      featureId: 'codex_desktop_continuity',
      :final ownerSessionId,
      :final requestId,
      :final errorCode,
    )) {
      if (_ownedRequestIds[ownerSessionId] != requestId) return;
      _cancelWatchAck(ownerSessionId);
      _ownedRequestIds.remove(ownerSessionId);
      if (errorCode == 'unsupported_message' ||
          errorCode == 'unsupported_capability') {
        _unsupported = true;
        _cancelAllWatchRetries();
      } else {
        _scheduleWatchRetry(ownerSessionId);
      }
      return;
    }
    if (message is! CodexDesktopContinuityEventMessage ||
        !message.usesSupportedSemantics) {
      return;
    }
    final ownRequest = _ownedRequestIds[message.sessionId];
    if (message.requestId == ownRequest) {
      if (message.event != CodexDesktopContinuityEventKind.error &&
          message.event != CodexDesktopContinuityEventKind.unwatched) {
        _acknowledgeWatch(message.sessionId, message.requestId);
      }
      final acceptedPayload = _bridge.recordBackgroundDesktopContinuity(
        message,
      );
      if (acceptedPayload) {
        _markHistoryDirty(message.sessionId);
      }
      if ((message.event == CodexDesktopContinuityEventKind.watching ||
              message.event == CodexDesktopContinuityEventKind.state) &&
          message.state == CodexDesktopContinuityState.running) {
        _markHistoryDirty(message.sessionId);
        _cancelHistoryFallback(message.sessionId);
      } else if ((message.event == CodexDesktopContinuityEventKind.watching ||
              message.event == CodexDesktopContinuityEventKind.state) &&
          message.state == CodexDesktopContinuityState.idle) {
        _refreshHistoryWhenReady(
          message.sessionId,
          historyReady: message.historyReady,
          turnId: message.turnId,
        );
      }
      if (message.event == CodexDesktopContinuityEventKind.error &&
          message.errorCode == 'runtime_rehydrate_failed') {
        // This error is advisory: the rollout monitor remains registered and
        // can recover on the next Desktop turn. Do not orphan the watch.
        _cancelHistoryFallback(message.sessionId);
        _bridge.requestSessionHistory(message.sessionId);
        return;
      }
      if (message.event == CodexDesktopContinuityEventKind.error ||
          message.event == CodexDesktopContinuityEventKind.unwatched) {
        _cancelWatchAck(message.sessionId);
        _cancelHistoryFallback(message.sessionId);
        _ownedRequestIds.remove(message.sessionId);
        if (message.errorCode == 'rollout_unavailable') {
          _enterWatchCooldownWithHistoryFallback(message.sessionId);
        } else if (message.event == CodexDesktopContinuityEventKind.unwatched ||
            (message.errorCode != 'path_not_allowed' &&
                message.errorCode != 'continuity_binding_mismatch')) {
          _scheduleWatchRetry(message.sessionId);
        } else {
          _suppressedSessionIds.add(message.sessionId);
        }
      }
      return;
    }

    if (message.event == CodexDesktopContinuityEventKind.watching) {
      // A timed-out list watch can finish after its replacement request. It is
      // not a conversation owner and must not suppress the fresh list watch.
      if (message.requestId.startsWith('list-')) return;
      _cancelWatchAck(message.sessionId);
      _cancelWatchRetry(message.sessionId);
      _cancelHistoryFallback(message.sessionId);
      _ownedRequestIds.remove(message.sessionId);
      _displacedByConversation[message.sessionId] = message.requestId;
      return;
    }
    if (message.event != CodexDesktopContinuityEventKind.unwatched &&
        message.event != CodexDesktopContinuityEventKind.error) {
      return;
    }
    if (_displacedByConversation[message.sessionId] != message.requestId) {
      return;
    }
    _displacedByConversation.remove(message.sessionId);
    _watchRetryAttempts.remove(message.sessionId);
    _ownedRequestIds.remove(message.sessionId);
    final session = _trackedSessions[message.sessionId];
    if (session != null) _ensureWatch(session);
  }

  void _onConnection(BridgeConnectionState state) {
    if (_closed) return;
    if (state != BridgeConnectionState.connected) {
      _historyDirtySessionIds.addAll(_trackedSessionIds);
      _lastReconciledHistoryReadyKey.clear();
      _cancelAllTimers();
      _ownedRequestIds.clear();
      _displacedByConversation.clear();
      _suppressedSessionIds.clear();
      _unsupported = false;
      return;
    }
    _syncSessions(_bridge.sessions);
  }

  void _startWatchAckTimer(String sessionId, String requestId) {
    _cancelWatchAck(sessionId);
    _watchAckTimers[sessionId] = Timer(watchAckTimeout, () {
      _watchAckTimers.remove(sessionId);
      if (_closed || _ownedRequestIds[sessionId] != requestId) return;
      _ownedRequestIds.remove(sessionId);
      _scheduleWatchRetry(sessionId);
    });
  }

  void _acknowledgeWatch(String sessionId, String requestId) {
    if (_ownedRequestIds[sessionId] != requestId) return;
    _cancelWatchAck(sessionId);
    _cancelWatchRetry(sessionId);
    _watchRetryAttempts.remove(sessionId);
  }

  void _scheduleWatchRetry(String sessionId) {
    if (_closed || _unsupported || !_trackedSessionIds.contains(sessionId)) {
      return;
    }
    if (_watchRetryTimers.containsKey(sessionId) ||
        _displacedByConversation.containsKey(sessionId)) {
      return;
    }
    final attempt = _watchRetryAttempts[sessionId] ?? 0;
    if (attempt >= maxWatchRetryAttempts) {
      _enterWatchCooldownWithHistoryFallback(sessionId);
      return;
    }
    final multiplier = 1 << attempt.clamp(0, 4);
    final delayMs = (watchRetryBase.inMilliseconds * multiplier).clamp(
      watchRetryBase.inMilliseconds,
      watchRetryMax.inMilliseconds,
    );
    _watchRetryAttempts[sessionId] = attempt + 1;
    _watchRetryTimers[sessionId] = Timer(Duration(milliseconds: delayMs), () {
      _watchRetryTimers.remove(sessionId);
      if (_closed || !_bridge.isConnected) return;
      final session = _trackedSessions[sessionId];
      if (session != null) _ensureWatch(session);
    });
  }

  void _enterWatchCooldownWithHistoryFallback(String sessionId) {
    _cancelWatchAck(sessionId);
    _cancelWatchRetry(sessionId);
    _ownedRequestIds.remove(sessionId);
    _suppressedSessionIds.remove(sessionId);
    _watchRetryAttempts[sessionId] = maxWatchRetryAttempts;
    _watchRetryTimers[sessionId] = Timer(watchHalfOpenDelay, () {
      _watchRetryTimers.remove(sessionId);
      if (_closed || !_bridge.isConnected) return;
      final session = _trackedSessions[sessionId];
      if (session != null) _ensureWatch(session);
    });
    _bridge.clearBackgroundDesktopContinuity(sessionId);
    if (!_historyDirtySessionIds.contains(sessionId) &&
        _bridge.cachedSessionMessages(sessionId).isNotEmpty) {
      return;
    }
    _bridge.requestSessionHistory(sessionId);
    _historyDirtySessionIds.remove(sessionId);
    _lastReconciledHistoryReadyKey.remove(sessionId);
  }

  void _refreshHistoryWhenReady(
    String sessionId, {
    required bool historyReady,
    required String? turnId,
  }) {
    _cancelHistoryFallback(sessionId);
    if (historyReady) {
      final readyKey = turnId?.trim().isNotEmpty == true
          ? turnId!.trim()
          : '<no-turn>';
      if (!_historyDirtySessionIds.contains(sessionId) &&
          _lastReconciledHistoryReadyKey[sessionId] == readyKey) {
        return;
      }
      _bridge.requestSessionHistory(sessionId);
      _historyDirtySessionIds.remove(sessionId);
      _lastReconciledHistoryReadyKey[sessionId] = readyKey;
      return;
    }
    if (!_historyDirtySessionIds.contains(sessionId)) return;
    // Compatibility fallback for a Bridge that predates historyReady. A
    // delayed canonical read is less likely to race its runtime rehydrate.
    _historyFallbackTimers[sessionId] = Timer(historyFallbackDelay, () {
      _historyFallbackTimers.remove(sessionId);
      if (_closed ||
          !_bridge.isConnected ||
          !_ownedRequestIds.containsKey(sessionId) ||
          !_historyDirtySessionIds.contains(sessionId)) {
        return;
      }
      _bridge.requestSessionHistory(sessionId);
      _historyDirtySessionIds.remove(sessionId);
      _lastReconciledHistoryReadyKey.remove(sessionId);
    });
  }

  void _markHistoryDirty(String sessionId) {
    _historyDirtySessionIds.add(sessionId);
    _lastReconciledHistoryReadyKey.remove(sessionId);
  }

  void _cancelWatchAck(String sessionId) {
    _watchAckTimers.remove(sessionId)?.cancel();
  }

  void _cancelWatchRetry(String sessionId) {
    _watchRetryTimers.remove(sessionId)?.cancel();
  }

  void _cancelHistoryFallback(String sessionId) {
    _historyFallbackTimers.remove(sessionId)?.cancel();
  }

  void _cancelSessionTimers(String sessionId) {
    _cancelWatchAck(sessionId);
    _cancelWatchRetry(sessionId);
    _cancelHistoryFallback(sessionId);
    _watchRetryAttempts.remove(sessionId);
  }

  void _cancelAllWatchRetries() {
    for (final timer in _watchRetryTimers.values) {
      timer.cancel();
    }
    _watchRetryTimers.clear();
    _watchRetryAttempts.clear();
  }

  void _cancelAllTimers() {
    for (final timer in [
      ..._watchAckTimers.values,
      ..._watchRetryTimers.values,
      ..._historyFallbackTimers.values,
    ]) {
      timer.cancel();
    }
    _watchAckTimers.clear();
    _watchRetryTimers.clear();
    _historyFallbackTimers.clear();
    _watchRetryAttempts.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _cancelAllTimers();
    _sessionSubscription?.cancel();
    _connectionSubscription?.cancel();
    _featureSubscription?.cancel();
    _trackedSessionIds.clear();
    _trackedSessions.clear();
    _ownedRequestIds.clear();
    _displacedByConversation.clear();
    _suppressedSessionIds.clear();
    _historyDirtySessionIds.clear();
    _lastReconciledHistoryReadyKey.clear();
  }
}
