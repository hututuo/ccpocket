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
  DesktopSessionListContinuityTracker(this._bridge) {
    _sessionSubscription = _bridge.sessionList.listen(_syncSessions);
    _connectionSubscription = _bridge.connectionStatus.listen(_onConnection);
    _featureSubscription = _bridge.localFeatureMessages.listen(
      _onFeatureMessage,
    );
    _syncSessions(_bridge.sessions);
  }

  final BridgeService _bridge;
  final _uuid = const Uuid();
  StreamSubscription<List<SessionInfo>>? _sessionSubscription;
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  StreamSubscription<LocalFeatureServerMessage>? _featureSubscription;
  final Set<String> _trackedSessionIds = {};
  final Map<String, String> _ownedRequestIds = {};
  final Map<String, String> _displacedByConversation = {};
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
      _ownedRequestIds.remove(sessionId);
      _displacedByConversation.remove(sessionId);
    }
    _trackedSessionIds.addAll(codex.keys);
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
      for (final session in _bridge.sessions) {
        if (_trackedSessionIds.contains(session.id)) _ensureWatch(session);
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
        _displacedByConversation.containsKey(session.id) ||
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
    } catch (_) {
      _ownedRequestIds.remove(session.id);
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
      _ownedRequestIds.remove(ownerSessionId);
      if (errorCode == 'unsupported_message' ||
          errorCode == 'unsupported_capability') {
        _unsupported = true;
      }
      return;
    }
    if (message is! CodexDesktopContinuityEventMessage) return;
    final ownRequest = _ownedRequestIds[message.sessionId];
    if (message.requestId == ownRequest) {
      if (message.event == CodexDesktopContinuityEventKind.error ||
          message.event == CodexDesktopContinuityEventKind.unwatched) {
        _ownedRequestIds.remove(message.sessionId);
      }
      return;
    }

    if (message.event == CodexDesktopContinuityEventKind.watching) {
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
    _ownedRequestIds.remove(message.sessionId);
    for (final session in _bridge.sessions) {
      if (session.id == message.sessionId) {
        _ensureWatch(session);
        break;
      }
    }
  }

  void _onConnection(BridgeConnectionState state) {
    if (_closed) return;
    if (state != BridgeConnectionState.connected) {
      _ownedRequestIds.clear();
      _displacedByConversation.clear();
      _unsupported = false;
      return;
    }
    _syncSessions(_bridge.sessions);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _sessionSubscription?.cancel();
    _connectionSubscription?.cancel();
    _featureSubscription?.cancel();
    _trackedSessionIds.clear();
    _ownedRequestIds.clear();
    _displacedByConversation.clear();
  }
}
