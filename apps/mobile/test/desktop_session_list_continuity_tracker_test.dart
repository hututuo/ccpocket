import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/session_list/desktop_session_list_continuity_tracker.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final sent = <ClientMessage>[];
  final _sessions = StreamController<List<SessionInfo>>.broadcast();
  final _connections = StreamController<BridgeConnectionState>.broadcast();
  final _features =
      StreamController<(LocalFeatureServerMessage, String)>.broadcast();
  List<SessionInfo> snapshot = const [];
  bool connected = true;

  @override
  bool get isConnected => connected;

  @override
  List<SessionInfo> get sessions => snapshot;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessions.stream;

  @override
  Stream<BridgeConnectionState> get connectionStatus => _connections.stream;

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => _features.stream
      .where((entry) => entry.$2 == sessionId)
      .map((entry) => entry.$1);

  @override
  void send(ClientMessage message) => sent.add(message);

  void emitFeature(LocalFeatureServerMessage message) {
    _features.add((message, message.sessionId!));
  }

  Future<void> closeFake() async {
    await _sessions.close();
    await _connections.close();
    await _features.close();
    dispose();
  }
}

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

void main() {
  test(
    'list watch yields to the conversation and resumes after unwatch',
    () async {
      final bridge = _Bridge();
      bridge.snapshot = const [
        SessionInfo(
          id: 'session-1',
          provider: 'codex',
          projectPath: '/tmp/project',
          claudeSessionId: 'thread-1',
          status: 'idle',
          createdAt: '',
          lastActivityAt: '',
        ),
      ];
      final tracker = DesktopSessionListContinuityTracker(bridge);
      addTearDown(() async {
        tracker.close();
        await bridge.closeFake();
      });

      expect(bridge.sent, hasLength(1));
      expect(
        _json(bridge.sent.single),
        containsPair('type', 'codex_desktop_continuity_watch'),
      );

      bridge.emitFeature(
        const CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.watching,
          requestId: 'conversation-watch',
          bridgeInstanceId: 'bridge-1',
          sessionId: 'session-1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
          state: CodexDesktopContinuityState.running,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      bridge.emitFeature(
        const CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.unwatched,
          requestId: 'conversation-unwatch',
          bridgeInstanceId: 'bridge-1',
          sessionId: 'session-1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        bridge.sent.where(
          (message) => message.type == 'codex_desktop_continuity_watch',
        ),
        hasLength(2),
      );
    },
  );
}
