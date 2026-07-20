import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/session_list/desktop_session_list_continuity_tracker.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  _Bridge({
    this.advertisedCapabilities = const {
      codexDesktopContinuityBridgeCapability,
    },
  });

  final Set<String> advertisedCapabilities;
  final sent = <ClientMessage>[];
  final _sessions = StreamController<List<SessionInfo>>.broadcast();
  final _connections = StreamController<BridgeConnectionState>.broadcast();
  final _features = StreamController<LocalFeatureServerMessage>.broadcast();
  List<SessionInfo> snapshot = const [];
  bool connected = true;

  @override
  bool get isConnected => connected;

  @override
  Set<String> get bridgeCapabilities => advertisedCapabilities;

  @override
  List<SessionInfo> get sessions => snapshot;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessions.stream;

  @override
  Stream<BridgeConnectionState> get connectionStatus => _connections.stream;

  @override
  Stream<LocalFeatureServerMessage> get localFeatureMessages =>
      _features.stream;

  @override
  void send(ClientMessage message) => sent.add(message);

  void emitFeature(LocalFeatureServerMessage message) => _features.add(message);

  Future<void> closeFake() async {
    await _sessions.close();
    await _connections.close();
    await _features.close();
    dispose();
  }
}

const _session = SessionInfo(
  id: 'session-1',
  provider: 'codex',
  projectPath: '/tmp/project',
  claudeSessionId: 'thread-1',
  status: 'idle',
  createdAt: '',
  lastActivityAt: '',
);

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('older Bridge does not receive an unknown list-watch request', () async {
    final bridge = _Bridge(advertisedCapabilities: const {})
      ..snapshot = const [_session];
    final tracker = DesktopSessionListContinuityTracker(bridge);
    addTearDown(() async {
      tracker.close();
      await bridge.closeFake();
    });

    await _flush();
    expect(bridge.sent, isEmpty);
  });

  test(
    'list watch yields to the conversation and resumes after its exact unwatch',
    () async {
      final bridge = _Bridge()..snapshot = const [_session];
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
      await _flush();
      bridge.emitFeature(
        const CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.unwatched,
          requestId: 'stale-watch',
          bridgeInstanceId: 'bridge-1',
          sessionId: 'session-1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
        ),
      );
      await _flush();
      expect(bridge.sent, hasLength(1));

      bridge.emitFeature(
        const CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.unwatched,
          requestId: 'conversation-watch',
          bridgeInstanceId: 'bridge-1',
          sessionId: 'session-1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
        ),
      );
      await _flush();

      expect(
        bridge.sent.where(
          (message) => message.type == 'codex_desktop_continuity_watch',
        ),
        hasLength(2),
      );
    },
  );

  test(
    'same snapshot is idempotent and reconnect creates one fresh watch',
    () async {
      final bridge = _Bridge()..snapshot = const [_session];
      final tracker = DesktopSessionListContinuityTracker(bridge);
      addTearDown(() async {
        tracker.close();
        await bridge.closeFake();
      });

      bridge._sessions.add(bridge.snapshot);
      await _flush();
      expect(bridge.sent, hasLength(1));

      bridge.connected = false;
      bridge._connections.add(BridgeConnectionState.disconnected);
      await _flush();
      bridge.connected = true;
      bridge._connections.add(BridgeConnectionState.connected);
      await _flush();

      expect(bridge.sent, hasLength(2));
    },
  );
}
