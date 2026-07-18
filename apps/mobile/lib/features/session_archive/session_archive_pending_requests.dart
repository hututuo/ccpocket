import 'dart:async';

import '../../models/messages.dart';

enum ArchiveResultUnknownReason { timeout, disconnected }

class PendingArchiveRequest {
  PendingArchiveRequest({
    required this.requestId,
    required this.sessionId,
    required this.provider,
    required this.identityKey,
  });

  final String requestId;
  final String sessionId;
  final String provider;
  final String identityKey;
  Timer? _timer;
}

typedef ArchiveResultUnknownCallback =
    void Function(
      List<PendingArchiveRequest> requests,
      ArchiveResultUnknownReason reason,
    );
typedef ArchiveTimerFactory =
    Timer Function(Duration duration, void Function() callback);

/// Owns the short-lived archive intents issued from the normal session list.
///
/// A timeout or disconnect only releases local busy state and reports that the
/// result is unknown. It never sends or replays the destructive request.
class SessionArchivePendingRequests {
  SessionArchivePendingRequests({
    this.timeout = const Duration(seconds: 20),
    required this.onResultUnknown,
    ArchiveTimerFactory? timerFactory,
  }) : _timerFactory = timerFactory ?? _createTimer;

  final Duration timeout;
  final ArchiveResultUnknownCallback onResultUnknown;
  final ArchiveTimerFactory _timerFactory;
  final Map<String, PendingArchiveRequest> _requests = {};
  bool _disposed = false;

  Set<String> get identityKeys =>
      Set.unmodifiable(_requests.values.map((request) => request.identityKey));

  bool hasIdentity(String identityKey) =>
      _requests.values.any((request) => request.identityKey == identityKey);

  bool hasSessionId(String sessionId) =>
      _requests.values.any((request) => request.sessionId == sessionId);

  bool register({
    required String requestId,
    required String sessionId,
    required String provider,
    required String identityKey,
  }) {
    if (_disposed ||
        _requests.containsKey(requestId) ||
        hasIdentity(identityKey)) {
      return false;
    }
    final request = PendingArchiveRequest(
      requestId: requestId,
      sessionId: sessionId,
      provider: provider,
      identityKey: identityKey,
    );
    _requests[requestId] = request;
    try {
      request._timer = _timerFactory(timeout, () => _expire(requestId));
    } catch (_) {
      _requests.remove(requestId);
      rethrow;
    }
    return true;
  }

  /// Resolve only an exactly correlated modern response. For an old Bridge
  /// that omitted requestId, accept one and only one provider/session candidate.
  PendingArchiveRequest? resolve(ArchiveResultMessage message) {
    final requestId = message.requestId;
    if (requestId != null && requestId.isNotEmpty) {
      final request = _requests[requestId];
      if (request == null ||
          message.provider == null ||
          request.sessionId != message.sessionId ||
          request.provider != message.provider) {
        return null;
      }
      return _take(requestId);
    }

    final candidates = _requests.values.where((request) {
      if (request.sessionId != message.sessionId) return false;
      final provider = message.provider;
      return provider == null ||
          provider.isEmpty ||
          request.provider == provider;
    }).toList();
    if (candidates.length != 1) return null;
    return _take(candidates.single.requestId);
  }

  /// Cancel local ownership after a synchronous send failure.
  PendingArchiveRequest? cancel(String requestId) => _take(requestId);

  void connectionLost() {
    if (_disposed) return;
    final requests = _takeAll();
    if (requests.isNotEmpty) {
      onResultUnknown(requests, ArchiveResultUnknownReason.disconnected);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _takeAll();
  }

  void _expire(String requestId) {
    if (_disposed) return;
    final request = _take(requestId);
    if (request != null) {
      onResultUnknown([request], ArchiveResultUnknownReason.timeout);
    }
  }

  PendingArchiveRequest? _take(String requestId) {
    final request = _requests.remove(requestId);
    request?._timer?.cancel();
    return request;
  }

  List<PendingArchiveRequest> _takeAll() {
    final requests = _requests.values.toList(growable: false);
    _requests.clear();
    for (final request in requests) {
      request._timer?.cancel();
    }
    return requests;
  }

  static Timer _createTimer(Duration duration, void Function() callback) =>
      Timer(duration, callback);
}
