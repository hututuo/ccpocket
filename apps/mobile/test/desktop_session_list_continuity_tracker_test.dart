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
  int historyRequests = 0;

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

  @override
  void requestSessionHistory(String sessionId) {
    historyRequests++;
  }

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

  test(
    'list watch caches completed payloads and hands off live deltas',
    () async {
      final bridge = _Bridge()..snapshot = const [_session];
      final tracker = DesktopSessionListContinuityTracker(bridge);
      addTearDown(() async {
        tracker.close();
        await bridge.closeFake();
      });
      final requestId = _json(bridge.sent.single)['requestId'] as String;

      bridge.emitFeature(
        CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.watching,
          requestId: requestId,
          bridgeInstanceId: 'bridge-1',
          sessionId: 'session-1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
          state: CodexDesktopContinuityState.running,
          turnId: 'turn-1',
        ),
      );
      bridge.emitFeature(
        CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.message,
          requestId: requestId,
          bridgeInstanceId: 'bridge-1',
          sessionId: 'session-1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
          turnId: 'turn-1',
          itemKey: 'assistant-1',
          payload: const AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-1',
              role: 'assistant',
              content: [TextContent(text: 'Desktop reply')],
              model: 'codex',
            ),
          ),
        ),
      );
      bridge.emitFeature(
        CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.message,
          requestId: requestId,
          bridgeInstanceId: 'bridge-1',
          sessionId: 'session-1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
          turnId: 'turn-1',
          itemKey: 'thinking-1',
          payload: const ThinkingDeltaMessage(text: 'Still working'),
        ),
      );
      await _flush();

      expect(
        bridge
            .cachedSessionMessages('session-1')
            .whereType<AssistantServerMessage>()
            .single
            .message
            .id,
        'assistant-1',
      );
      final handoff = bridge.takeBackgroundDesktopContinuity(
        'session-1',
        threadId: 'thread-1',
      );
      expect(handoff!.state, CodexDesktopContinuityState.running);
      expect(handoff.itemKeys, containsAll({'assistant-1', 'thinking-1'}));
      expect(
        (handoff.transientPayloads.single.payload as ThinkingDeltaMessage).text,
        'Still working',
      );

      bridge.emitFeature(
        CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.state,
          requestId: requestId,
          bridgeInstanceId: 'bridge-1',
          sessionId: 'session-1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
          state: CodexDesktopContinuityState.idle,
          turnId: 'turn-1',
          historyReady: true,
        ),
      );
      await _flush();

      expect(bridge.historyRequests, 1);
    },
  );

  test(
    'rehydrate failure keeps the live watch and later payloads flowing',
    () async {
      final bridge = _Bridge()..snapshot = const [_session];
      final tracker = DesktopSessionListContinuityTracker(bridge);
      addTearDown(() async {
        tracker.close();
        await bridge.closeFake();
      });
      final requestId = _json(bridge.sent.single)['requestId'] as String;

      bridge.emitFeature(
        CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.watching,
          requestId: requestId,
          bridgeInstanceId: 'bridge-1',
          sessionId: 'session-1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
          state: CodexDesktopContinuityState.running,
        ),
      );
      bridge.emitFeature(
        CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.error,
          requestId: requestId,
          bridgeInstanceId: 'bridge-1',
          sessionId: 'session-1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
          errorCode: 'runtime_rehydrate_failed',
          error: 'temporary refresh failure',
        ),
      );
      bridge.emitFeature(
        CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.message,
          requestId: requestId,
          bridgeInstanceId: 'bridge-1',
          sessionId: 'session-1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
          turnId: 'turn-2',
          itemKey: 'assistant-after-error',
          payload: const AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-after-error',
              role: 'assistant',
              content: [TextContent(text: 'Still synchronized')],
              model: 'codex',
            ),
          ),
        ),
      );
      await _flush();

      expect(bridge.historyRequests, 1);
      expect(
        bridge
            .cachedSessionMessages('session-1')
            .whereType<AssistantServerMessage>()
            .single
            .message
            .id,
        'assistant-after-error',
      );
      expect(
        bridge.sent.where(
          (message) => message.type == 'codex_desktop_continuity_watch',
        ),
        hasLength(1),
      );
    },
  );

  test('old Bridge idle state gets one delayed history fallback', () async {
    final bridge = _Bridge()..snapshot = const [_session];
    final tracker = DesktopSessionListContinuityTracker(
      bridge,
      historyFallbackDelay: const Duration(milliseconds: 1),
    );
    addTearDown(() async {
      tracker.close();
      await bridge.closeFake();
    });
    final requestId = _json(bridge.sent.single)['requestId'] as String;

    bridge.emitFeature(
      CodexDesktopContinuityEventMessage(
        event: CodexDesktopContinuityEventKind.state,
        requestId: requestId,
        bridgeInstanceId: 'bridge-old',
        sessionId: 'session-1',
        threadId: 'thread-1',
        origin: 'desktop_rollout',
        state: CodexDesktopContinuityState.idle,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(bridge.historyRequests, 1);
  });

  test('silent list watch automatically retries', () async {
    final bridge = _Bridge()..snapshot = const [_session];
    final tracker = DesktopSessionListContinuityTracker(
      bridge,
      watchAckTimeout: const Duration(milliseconds: 1),
      watchRetryBase: const Duration(milliseconds: 1),
      watchRetryMax: const Duration(milliseconds: 1),
    );
    addTearDown(() async {
      tracker.close();
      await bridge.closeFake();
    });

    await Future<void>.delayed(const Duration(milliseconds: 6));
    final watches = bridge.sent
        .where((message) => message.type == 'codex_desktop_continuity_watch')
        .toList(growable: false);
    expect(watches.length, greaterThan(1));
  });

  test('binding rejection stays quiet until reconnect', () async {
    final bridge = _Bridge()..snapshot = const [_session];
    final tracker = DesktopSessionListContinuityTracker(
      bridge,
      watchRetryBase: const Duration(milliseconds: 1),
      watchRetryMax: const Duration(milliseconds: 1),
    );
    addTearDown(() async {
      tracker.close();
      await bridge.closeFake();
    });
    final requestId = _json(bridge.sent.single)['requestId'] as String;

    bridge.emitFeature(
      CodexDesktopContinuityEventMessage(
        event: CodexDesktopContinuityEventKind.error,
        requestId: requestId,
        bridgeInstanceId: 'bridge-1',
        sessionId: 'session-1',
        threadId: 'thread-1',
        origin: 'desktop_rollout',
        errorCode: 'path_not_allowed',
        error: 'blocked path',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(bridge.sent, hasLength(1));

    bridge.connected = false;
    bridge._connections.add(BridgeConnectionState.disconnected);
    await _flush();
    bridge.connected = true;
    bridge._connections.add(BridgeConnectionState.connected);
    await _flush();
    expect(bridge.sent, hasLength(2));
  });
}
