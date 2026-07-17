import 'dart:async';

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

  SessionInsightsController({
    required this.sessionId,
    required this.bridge,
    this.requestTimeout = const Duration(seconds: 12),
  });

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
      _contextLoading = false;
      _contextGeneration++;
      _contextTimeout?.cancel();
      notifyListeners();
      return;
    }
    if (message case ContextUsageResultMessage()) {
      if (message.sessionId != sessionId) return;
      _contextUsage = message.usage;
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
    _quotaRequestId = null;
    _quotaLoading = false;
    _quotaGeneration++;
    _quotaTimeout?.cancel();
    notifyListeners();
  }

  void _onConnectionState(BridgeConnectionState state) {
    if (state == BridgeConnectionState.connected) {
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
