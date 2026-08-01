import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../models/messages.dart'
    show
        BridgeConnectionState,
        DetachedSubagentHistoryMessage,
        DetachedSubagentListMessage,
        LocalFeatureRequestErrorMessage,
        LocalFeatureServerMessage,
        SessionInfo,
        SubagentActivitySummaryMessage,
        SubagentHistoryMessage,
        SubagentInfo,
        SubagentListMessage,
        detachedSubagentsReadCapability,
        requestDetachedSubagentHistory,
        requestDetachedSubagents,
        requestSubagentHistory,
        requestSubagents,
        unwatchSubagentActivity,
        watchDetachedSubagentActivity,
        watchSubagentActivity;
import '../../../services/bridge_service.dart';

/// Standalone SSOT for the read-only subagent browser.
///
/// It needs only a parent session id and BridgeService, so it works from a
/// workspace sibling pane where no ChatSessionCubit ancestor exists.
class SubagentsController extends ChangeNotifier {
  static const _uuid = Uuid();

  SubagentsController({
    required this.sessionId,
    required this.bridge,
    this.detachedProviderThreadId,
    this.detachedCodexSourceId,
    this.requestTimeout = const Duration(seconds: 12),
  }) {
    _subscription = bridge
        .localFeatureMessagesForSession(sessionId)
        .listen(_onMessage);
    _connectionSubscription = bridge.connectionStatus.listen(
      _onConnectionState,
    );
    if (_isDetachedProviderRead) {
      _sessionListSubscription = bridge.sessionList.listen(
        (_) => _onAuthoritativeSessionList(),
      );
    }
  }

  final String sessionId;
  final BridgeService bridge;
  final String? detachedProviderThreadId;
  final String? detachedCodexSourceId;
  final Duration requestTimeout;
  StreamSubscription<LocalFeatureServerMessage>? _subscription;
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  StreamSubscription<List<SessionInfo>>? _sessionListSubscription;
  String? _listRequestId;
  final Map<String, String> _historyRequestIds = {};
  Timer? _listTimeout;
  Timer? _detailsRefreshTimer;
  final Map<String, Timer> _historyTimeouts = {};
  bool _disposed = false;
  bool _pendingRefresh = false;
  String? _pendingHistoryThreadId;
  String? _lastCompletedListRequestId;
  String? _pendingActivitySubscriptionId;
  String? _activitySubscriptionId;
  String? _activityRevision;
  int? _activityActiveCount;
  bool _detailsVisible = false;

  List<SubagentInfo> subagents = const [];
  bool listTruncated = false;
  bool listLoading = false;
  String? listError;
  final Map<String, SubagentHistoryMessage> histories = {};
  final Set<String> historyLoadingIds = {};
  final Map<String, String> historyErrors = {};

  int get activeCount =>
      _activityActiveCount ??
      subagents.where((subagent) => subagent.isActive).length;

  bool get _hasInFlight =>
      _listRequestId != null || _historyRequestIds.isNotEmpty;
  bool get _isDetachedProviderRead => detachedProviderThreadId != null;
  String? get _normalizedProviderThreadId =>
      _normalizedBoundedIdentity(detachedProviderThreadId);
  String? get _normalizedExpectedCodexSourceId =>
      _normalizedBoundedIdentity(detachedCodexSourceId);

  void setDetailsVisible(bool visible) {
    if (_disposed || _detailsVisible == visible) return;
    _detailsVisible = visible;
    if (!visible) _detailsRefreshTimer?.cancel();
  }

  void refresh() {
    if (_disposed) return;
    if (!bridge.isConnected) {
      listLoading = false;
      listError = 'bridge_disconnected';
      notifyListeners();
      return;
    }
    final detachedGate = _detachedReadGate();
    if (detachedGate != null) {
      _clearDetachedProviderData();
      listLoading = false;
      listError = detachedGate;
      notifyListeners();
      return;
    }
    if (_hasInFlight) {
      _pendingRefresh = true;
      return;
    }
    final requestId = _uuid.v4();
    _listRequestId = requestId;
    _listTimeout?.cancel();
    listLoading = true;
    listError = null;
    notifyListeners();
    try {
      bridge.send(
        _isDetachedProviderRead
            ? requestDetachedSubagents(
                ownerSessionId: sessionId,
                providerThreadId: _normalizedProviderThreadId!,
                codexSourceId: _normalizedExpectedCodexSourceId!,
                requestId: requestId,
              )
            : requestSubagents(sessionId: sessionId, requestId: requestId),
      );
      _listTimeout = Timer(requestTimeout, () {
        if (_listRequestId != requestId) return;
        _listRequestId = null;
        listLoading = false;
        listError = 'unsupported';
        notifyListeners();
        _drainPending();
      });
    } catch (_) {
      if (_listRequestId != requestId) return;
      _listRequestId = null;
      listLoading = false;
      listError = 'bridge_disconnected';
      notifyListeners();
      _drainPending();
    }
  }

  void loadHistory(String threadId) {
    if (_disposed) return;
    final normalized = threadId.trim();
    if (normalized.isEmpty) return;
    if (!bridge.isConnected) {
      historyErrors[normalized] = 'bridge_disconnected';
      notifyListeners();
      return;
    }
    final detachedGate = _detachedReadGate();
    if (detachedGate != null) {
      _clearDetachedProviderData();
      historyLoadingIds.remove(normalized);
      historyErrors[normalized] = detachedGate;
      notifyListeners();
      return;
    }
    if (_hasInFlight) {
      final previous = _pendingHistoryThreadId;
      if (previous != null && previous != normalized) {
        historyLoadingIds.remove(previous);
      }
      _pendingHistoryThreadId = normalized;
      historyLoadingIds.add(normalized);
      notifyListeners();
      return;
    }
    final requestId = _uuid.v4();
    _historyRequestIds[normalized] = requestId;
    _historyTimeouts.remove(normalized)?.cancel();
    historyLoadingIds.add(normalized);
    historyErrors.remove(normalized);
    notifyListeners();
    try {
      bridge.send(
        _isDetachedProviderRead
            ? requestDetachedSubagentHistory(
                ownerSessionId: sessionId,
                providerThreadId: _normalizedProviderThreadId!,
                codexSourceId: _normalizedExpectedCodexSourceId!,
                threadId: normalized,
                requestId: requestId,
              )
            : requestSubagentHistory(
                sessionId: sessionId,
                threadId: normalized,
                requestId: requestId,
              ),
      );
      _historyTimeouts[normalized] = Timer(requestTimeout, () {
        if (_historyRequestIds[normalized] != requestId) return;
        _historyRequestIds.remove(normalized);
        _historyTimeouts.remove(normalized);
        historyLoadingIds.remove(normalized);
        historyErrors[normalized] = 'unsupported';
        notifyListeners();
        _drainPending();
      });
    } catch (_) {
      if (_historyRequestIds[normalized] != requestId) return;
      _historyRequestIds.remove(normalized);
      historyLoadingIds.remove(normalized);
      historyErrors[normalized] = 'bridge_disconnected';
      notifyListeners();
      _drainPending();
    }
  }

  void _onMessage(LocalFeatureServerMessage message) {
    if (_disposed) return;
    switch (message) {
      case SubagentActivitySummaryMessage():
        if (!_matchesActivityScope(message)) return;
        if (!message.subscribed) {
          final listRequestId = message.listRequestId;
          if (listRequestId == null ||
              (listRequestId != _listRequestId &&
                  listRequestId != _lastCompletedListRequestId) ||
              _activitySubscriptionId != null ||
              _pendingActivitySubscriptionId != null) {
            return;
          }
          _applyActivitySummary(message);
          final subscriptionId = _uuid.v4();
          _pendingActivitySubscriptionId = subscriptionId;
          try {
            bridge.send(
              _isDetachedProviderRead
                  ? watchDetachedSubagentActivity(
                      ownerSessionId: sessionId,
                      providerThreadId: _normalizedProviderThreadId!,
                      codexSourceId: _normalizedExpectedCodexSourceId!,
                      listRequestId: listRequestId,
                      subscriptionId: subscriptionId,
                    )
                  : watchSubagentActivity(
                      sessionId: sessionId,
                      listRequestId: listRequestId,
                      subscriptionId: subscriptionId,
                    ),
            );
          } catch (_) {
            _pendingActivitySubscriptionId = null;
          }
          notifyListeners();
          return;
        }
        final subscriptionId = message.subscriptionId;
        if (subscriptionId == null ||
            (subscriptionId != _activitySubscriptionId &&
                subscriptionId != _pendingActivitySubscriptionId)) {
          return;
        }
        _pendingActivitySubscriptionId = null;
        _activitySubscriptionId = subscriptionId;
        final changed = message.revision != _activityRevision;
        _applyActivitySummary(message);
        notifyListeners();
        if (changed && _detailsVisible) _scheduleDetailsRefresh();
      case LocalFeatureRequestErrorMessage():
        if (message.featureId != 'subagents') return;
        final requestId = message.requestId;
        final expectedListRequestType = _isDetachedProviderRead
            ? 'get_detached_subagents'
            : 'get_subagents';
        final expectedHistoryRequestType = _isDetachedProviderRead
            ? 'get_detached_subagent_history'
            : 'get_subagent_history';
        final expectedActivityRequestType = _isDetachedProviderRead
            ? 'watch_detached_subagent_activity_v1'
            : 'watch_subagent_activity_v1';
        if (message.requestType == expectedActivityRequestType &&
            requestId != null &&
            requestId == _pendingActivitySubscriptionId) {
          _pendingActivitySubscriptionId = null;
          return;
        }
        if (message.requestType == expectedListRequestType &&
            requestId != null &&
            requestId == _listRequestId) {
          _listRequestId = null;
          _listTimeout?.cancel();
          listLoading = false;
          listError = 'unsupported';
          if (_isDetachedProviderRead) {
            _clearDetachedProviderData();
          }
          notifyListeners();
          _drainPending();
          return;
        }
        if (message.requestType == expectedHistoryRequestType &&
            requestId != null) {
          String? threadId;
          for (final entry in _historyRequestIds.entries) {
            if (entry.value == requestId) {
              threadId = entry.key;
              break;
            }
          }
          if (threadId == null) return;
          _historyRequestIds.remove(threadId);
          _historyTimeouts.remove(threadId)?.cancel();
          historyLoadingIds.remove(threadId);
          historyErrors[threadId] = 'unsupported';
          notifyListeners();
          _drainPending();
        }
      case DetachedSubagentListMessage():
        if (!_isDetachedProviderRead ||
            message.ownerSessionId != sessionId ||
            message.providerThreadId != _normalizedProviderThreadId) {
          return;
        }
        final expectedRequestId = _listRequestId;
        if (expectedRequestId == null ||
            message.requestId != expectedRequestId) {
          return;
        }
        _listRequestId = null;
        _lastCompletedListRequestId = expectedRequestId;
        _listTimeout?.cancel();
        listLoading = false;
        if (message.error == null &&
            message.codexSourceId != _normalizedExpectedCodexSourceId) {
          _clearDetachedProviderData();
          listError = 'codex_source_mismatch';
        } else {
          listError = _normalizedDetachedError(
            message.errorCode,
            message.error,
          );
          if (listError == 'codex_source_mismatch') {
            _clearDetachedProviderData();
          }
          if (message.error == null) {
            subagents = message.subagents;
            listTruncated = message.truncated;
          }
        }
        notifyListeners();
        _drainPending();
      case DetachedSubagentHistoryMessage():
        if (!_isDetachedProviderRead ||
            message.ownerSessionId != sessionId ||
            message.providerThreadId != _normalizedProviderThreadId) {
          return;
        }
        final threadId = message.threadId;
        final expected = _historyRequestIds[threadId];
        if (expected == null || message.requestId != expected) {
          return;
        }
        _historyRequestIds.remove(threadId);
        _historyTimeouts.remove(threadId)?.cancel();
        historyLoadingIds.remove(threadId);
        if (message.error == null &&
            message.codexSourceId != _normalizedExpectedCodexSourceId) {
          histories.remove(threadId);
          historyErrors[threadId] = 'codex_source_mismatch';
        } else if (message.error == null) {
          histories[threadId] = message;
          historyErrors.remove(threadId);
        } else {
          final normalizedError =
              _normalizedDetachedError(message.errorCode, message.error) ??
              'read_failed';
          if (normalizedError == 'codex_source_mismatch') {
            _clearDetachedProviderData();
          }
          historyErrors[threadId] = normalizedError;
        }
        final incoming = message.subagent;
        if (message.error == null && incoming != null) {
          _mergeSubagent(incoming);
        }
        notifyListeners();
        _drainPending();
      case SubagentListMessage():
        if (_isDetachedProviderRead) return;
        if (message.sessionId != sessionId) return;
        final expectedRequestId = _listRequestId;
        if (expectedRequestId == null ||
            message.requestId != expectedRequestId) {
          return;
        }
        _listRequestId = null;
        _lastCompletedListRequestId = expectedRequestId;
        _listTimeout?.cancel();
        listLoading = false;
        listError = _normalizedError(message.error);
        if (message.error == null) {
          subagents = message.subagents;
          listTruncated = message.truncated;
        }
        notifyListeners();
        _drainPending();
      case SubagentHistoryMessage():
        if (_isDetachedProviderRead) return;
        if (message.sessionId != sessionId) return;
        final threadId = message.threadId;
        if (threadId.isEmpty) return;
        final expected = _historyRequestIds[threadId];
        if (expected == null || message.requestId != expected) {
          return;
        }
        _historyRequestIds.remove(threadId);
        _historyTimeouts.remove(threadId)?.cancel();
        historyLoadingIds.remove(threadId);
        if (message.error == null) {
          histories[threadId] = message;
          historyErrors.remove(threadId);
        } else {
          historyErrors[threadId] = _normalizedError(message.error)!;
        }
        final incoming = message.subagent;
        if (incoming != null) {
          _mergeSubagent(incoming);
        }
        notifyListeners();
        _drainPending();
      default:
        break;
    }
  }

  void _mergeSubagent(SubagentInfo incoming) {
    final index = subagents.indexWhere(
      (agent) => agent.threadId == incoming.threadId,
    );
    final next = List<SubagentInfo>.from(subagents);
    if (index < 0) {
      next.add(incoming);
    } else {
      next[index] = incoming;
    }
    subagents = List.unmodifiable(next);
  }

  bool _matchesActivityScope(SubagentActivitySummaryMessage message) {
    if (message.ownerSessionId != sessionId) return false;
    if (_isDetachedProviderRead) {
      return message.scope == 'provider' &&
          message.providerThreadId == _normalizedProviderThreadId &&
          message.codexSourceId == _normalizedExpectedCodexSourceId &&
          message.codexSourceId ==
              _normalizedBoundedIdentity(bridge.codexSourceId);
    }
    return message.scope == 'runtime';
  }

  void _applyActivitySummary(SubagentActivitySummaryMessage message) {
    _activityRevision = message.revision;
    _activityActiveCount = message.activeCount;
  }

  void _scheduleDetailsRefresh() {
    if (_disposed || !_detailsVisible) return;
    _detailsRefreshTimer?.cancel();
    _detailsRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      _detailsRefreshTimer = null;
      if (!_disposed && _detailsVisible) refresh();
    });
  }

  void _stopActivityWatch({required bool sendUnwatch}) {
    _detailsRefreshTimer?.cancel();
    _detailsRefreshTimer = null;
    final subscriptionId =
        _activitySubscriptionId ?? _pendingActivitySubscriptionId;
    _activitySubscriptionId = null;
    _pendingActivitySubscriptionId = null;
    _activityRevision = null;
    _activityActiveCount = null;
    if (sendUnwatch && subscriptionId != null && bridge.isConnected) {
      try {
        bridge.send(unwatchSubagentActivity(subscriptionId));
      } catch (_) {
        // The socket can disappear between the connection check and send.
      }
    }
  }

  void _clearDetachedProviderData() {
    if (!_isDetachedProviderRead) return;
    _stopActivityWatch(sendUnwatch: true);
    _listTimeout?.cancel();
    _listRequestId = null;
    _lastCompletedListRequestId = null;
    listLoading = false;
    for (final timer in _historyTimeouts.values) {
      timer.cancel();
    }
    _historyTimeouts.clear();
    _historyRequestIds.clear();
    historyLoadingIds.clear();
    historyErrors.clear();
    _pendingRefresh = false;
    _pendingHistoryThreadId = null;
    subagents = const [];
    listTruncated = false;
    histories.clear();
  }

  String? _detachedReadGate() {
    if (!_isDetachedProviderRead) return null;
    if (!bridge.hasAuthoritativeSessionListForCurrentConnection) {
      return 'source_unavailable';
    }
    if (!bridge.bridgeCapabilities.contains(detachedSubagentsReadCapability)) {
      return 'unsupported';
    }
    if (_normalizedProviderThreadId == null) {
      return 'invalid_provider_thread';
    }
    final expectedSourceId = _normalizedExpectedCodexSourceId;
    final authoritativeSourceId = _normalizedBoundedIdentity(
      bridge.codexSourceId,
    );
    if (expectedSourceId == null || authoritativeSourceId == null) {
      return 'codex_source_unavailable';
    }
    if (expectedSourceId != authoritativeSourceId) {
      return 'codex_source_mismatch';
    }
    return null;
  }

  void _onAuthoritativeSessionList() {
    if (_disposed ||
        !_isDetachedProviderRead ||
        !bridge.hasAuthoritativeSessionListForCurrentConnection ||
        _hasInFlight) {
      return;
    }
    final gate = _detachedReadGate();
    if (gate != null) {
      _clearDetachedProviderData();
      listError = gate;
      notifyListeners();
      return;
    }
    if (listError == 'source_unavailable' ||
        listError == 'codex_source_unavailable' ||
        listError == 'codex_source_mismatch' ||
        listError == 'unsupported') {
      refresh();
    }
  }

  void _onConnectionState(BridgeConnectionState state) {
    if (_disposed) return;
    if (state == BridgeConnectionState.connected) {
      refresh();
      return;
    }

    _listTimeout?.cancel();
    _listRequestId = null;
    _lastCompletedListRequestId = null;
    _stopActivityWatch(sendUnwatch: false);
    listLoading = false;
    listError = 'bridge_disconnected';
    for (final timer in _historyTimeouts.values) {
      timer.cancel();
    }
    for (final threadId in _historyRequestIds.keys) {
      historyErrors[threadId] = 'bridge_disconnected';
    }
    _historyTimeouts.clear();
    _historyRequestIds.clear();
    historyLoadingIds.clear();
    _pendingRefresh = false;
    _pendingHistoryThreadId = null;
    notifyListeners();
  }

  void _drainPending() {
    if (_disposed || _hasInFlight || !bridge.isConnected) return;
    final pendingHistory = _pendingHistoryThreadId;
    if (pendingHistory != null) {
      _pendingHistoryThreadId = null;
      loadHistory(pendingHistory);
      return;
    }
    if (_pendingRefresh) {
      _pendingRefresh = false;
      refresh();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopActivityWatch(sendUnwatch: true);
    _subscription?.cancel();
    _connectionSubscription?.cancel();
    _sessionListSubscription?.cancel();
    _listTimeout?.cancel();
    for (final timer in _historyTimeouts.values) {
      timer.cancel();
    }
    _historyTimeouts.clear();
    super.dispose();
  }
}

String? _normalizedError(String? error) {
  if (error == null) return null;
  final normalized = error.toLowerCase();
  if (normalized.contains('unsupported') ||
      normalized.contains('invalid message')) {
    return 'unsupported';
  }
  return error;
}

String? _normalizedDetachedError(String? errorCode, String? error) {
  if (error == null && errorCode == null) return null;
  if (errorCode == 'capability_not_negotiated' ||
      errorCode == 'unsupported_message') {
    return 'unsupported';
  }
  if (errorCode == 'read_failed') {
    return _normalizedError(error) ?? errorCode;
  }
  return errorCode ?? _normalizedError(error) ?? 'read_failed';
}

String? _normalizedBoundedIdentity(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty || normalized.length > 256) {
    return null;
  }
  return normalized;
}
