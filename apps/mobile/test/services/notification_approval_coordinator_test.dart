import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/notification_approval_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'sends an approval only for one authoritative pending request',
    () async {
      final bridge = _FakeNotificationApprovalBridge()
        ..connected = true
        ..authoritative = true
        ..currentSessions = <SessionInfo>[
          _session(
            id: 'runtime-1',
            provider: 'codex',
            providerSessionId: 'thread-1',
            permissionId: 'permission-1',
          ),
        ];
      final coordinator = NotificationApprovalCoordinator(
        preferences: await SharedPreferences.getInstance(),
        bridge: bridge,
      );
      await coordinator.initialize();
      addTearDown(coordinator.dispose);

      await coordinator.submit(
        NotificationApprovalRequest(
          sessionId: 'runtime-1',
          provider: 'codex',
          providerSessionId: 'thread-1',
          permissionId: 'permission-1',
          decision: NotificationApprovalDecision.approve,
          createdAt: DateTime.now().toUtc(),
        ),
      );

      expect(bridge.sent, hasLength(1));
      expect(bridge.sent.single.delivery, ClientMessageDelivery.ephemeral);
      expect(jsonDecode(bridge.sent.single.toJson()), <String, dynamic>{
        'type': 'approve',
        'id': 'permission-1',
        'sessionId': 'runtime-1',
      });
      expect(bridge.marked, <String>['runtime-1:permission-1']);
      expect(bridge.cleared, <String>['runtime-1']);
    },
  );

  test(
    'resolves a replaced runtime session through its durable identity',
    () async {
      final bridge = _FakeNotificationApprovalBridge()
        ..connected = true
        ..authoritative = true
        ..currentSessions = <SessionInfo>[
          _session(
            id: 'runtime-new',
            provider: 'claude',
            providerSessionId: 'durable-session',
            permissionId: 'permission-2',
          ),
        ];
      final coordinator = NotificationApprovalCoordinator(
        preferences: await SharedPreferences.getInstance(),
        bridge: bridge,
      );
      await coordinator.initialize();
      addTearDown(coordinator.dispose);

      await coordinator.submit(
        NotificationApprovalRequest(
          sessionId: 'runtime-old',
          provider: 'claude',
          providerSessionId: 'durable-session',
          permissionId: 'permission-2',
          decision: NotificationApprovalDecision.reject,
          createdAt: DateTime.now().toUtc(),
        ),
      );

      expect(jsonDecode(bridge.sent.single.toJson()), <String, dynamic>{
        'type': 'reject',
        'id': 'permission-2',
        'sessionId': 'runtime-new',
      });
    },
  );

  test(
    'waits for a live authoritative snapshot and keeps only the last action',
    () async {
      final bridge = _FakeNotificationApprovalBridge();
      final coordinator = NotificationApprovalCoordinator(
        preferences: await SharedPreferences.getInstance(),
        bridge: bridge,
      );
      await coordinator.initialize();
      addTearDown(coordinator.dispose);
      final occurredAt = DateTime.now().toUtc();

      await coordinator.submit(
        NotificationApprovalRequest(
          sessionId: 'runtime-1',
          provider: 'codex',
          permissionId: 'permission-3',
          decision: NotificationApprovalDecision.approve,
          createdAt: occurredAt,
        ),
      );
      await coordinator.submit(
        NotificationApprovalRequest(
          sessionId: 'runtime-1',
          provider: 'codex',
          permissionId: 'permission-3',
          decision: NotificationApprovalDecision.reject,
          createdAt: occurredAt,
        ),
      );
      expect(bridge.sent, isEmpty);

      bridge
        ..connected = true
        ..authoritative = true
        ..currentSessions = <SessionInfo>[
          _session(
            id: 'runtime-1',
            provider: 'codex',
            permissionId: 'permission-3',
          ),
        ]
        ..emitConnection(BridgeConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(
        (jsonDecode(bridge.sent.single.toJson())
            as Map<String, dynamic>)['type'],
        'reject',
      );
    },
  );

  test('ignores stale, future, and mismatched permission identities', () async {
    final bridge = _FakeNotificationApprovalBridge()
      ..connected = true
      ..authoritative = true
      ..currentSessions = <SessionInfo>[
        _session(
          id: 'runtime-1',
          provider: 'codex',
          permissionId: 'current-permission',
        ),
      ];
    final coordinator = NotificationApprovalCoordinator(
      preferences: await SharedPreferences.getInstance(),
      bridge: bridge,
    );
    await coordinator.initialize();
    addTearDown(coordinator.dispose);

    for (final request in <NotificationApprovalRequest>[
      NotificationApprovalRequest(
        sessionId: 'runtime-1',
        provider: 'codex',
        permissionId: 'current-permission',
        decision: NotificationApprovalDecision.approve,
        createdAt: DateTime.now().toUtc().subtract(const Duration(minutes: 11)),
      ),
      NotificationApprovalRequest(
        sessionId: 'runtime-1',
        provider: 'codex',
        permissionId: 'current-permission',
        decision: NotificationApprovalDecision.approve,
        createdAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
      ),
      NotificationApprovalRequest(
        sessionId: 'runtime-1',
        provider: 'codex',
        permissionId: 'other-permission',
        decision: NotificationApprovalDecision.approve,
        createdAt: DateTime.now().toUtc(),
      ),
    ]) {
      await coordinator.submit(request);
    }

    expect(bridge.sent, isEmpty);
  });

  test('normalizes and bounds a persisted approval action queue', () async {
    final now = DateTime.now().toUtc();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'notification_approval_queue_v1': jsonEncode(<Object?>[
        <String, Object?>{
          'sessionId': 42,
          'provider': 'codex',
          'permissionId': 'malformed',
          'decision': 'approve',
          'createdAt': now.toIso8601String(),
        },
        <String, Object?>{
          'sessionId': 'stale',
          'provider': 'codex',
          'permissionId': 'stale',
          'decision': 'approve',
          'createdAt': now
              .subtract(const Duration(minutes: 11))
              .toIso8601String(),
        },
        for (var index = 0; index < 10; index++)
          <String, Object?>{
            'sessionId': 'runtime-$index',
            'provider': 'codex',
            'permissionId': 'permission-$index',
            'decision': 'approve',
            'createdAt': now.toIso8601String(),
          },
      ]),
    });
    final preferences = await SharedPreferences.getInstance();
    final coordinator = NotificationApprovalCoordinator(
      preferences: preferences,
      bridge: _FakeNotificationApprovalBridge(),
    );
    await coordinator.initialize();
    addTearDown(coordinator.dispose);

    final persisted =
        jsonDecode(preferences.getString('notification_approval_queue_v1')!)
            as List;
    expect(persisted, hasLength(8));
    expect(
      persisted.map((item) => (item as Map)['permissionId']),
      isNot(contains('stale')),
    );
    expect(
      persisted.map((item) => (item as Map)['permissionId']),
      containsAll(<String>['permission-2', 'permission-9']),
    );
  });
}

class _FakeNotificationApprovalBridge implements NotificationApprovalBridge {
  bool connected = false;
  bool authoritative = false;
  List<SessionInfo> currentSessions = const <SessionInfo>[];
  final List<ClientMessage> sent = <ClientMessage>[];
  final List<String> marked = <String>[];
  final List<String> cleared = <String>[];
  final StreamController<List<SessionInfo>> _sessions =
      StreamController<List<SessionInfo>>.broadcast();
  final StreamController<BridgeConnectionState> _connections =
      StreamController<BridgeConnectionState>.broadcast();

  @override
  bool get isConnected => connected;

  @override
  bool get hasAuthoritativeSessionListForCurrentConnection =>
      connected && authoritative;

  @override
  List<SessionInfo> get sessions => currentSessions;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessions.stream;

  @override
  Stream<BridgeConnectionState> get connectionStatus => _connections.stream;

  void emitConnection(BridgeConnectionState state) => _connections.add(state);

  @override
  void send(ClientMessage message) => sent.add(message);

  @override
  void markToolUseResponded(String sessionId, String toolUseId) {
    marked.add('$sessionId:$toolUseId');
  }

  @override
  void clearSessionPermission(String sessionId) => cleared.add(sessionId);
}

SessionInfo _session({
  required String id,
  required String provider,
  String? providerSessionId,
  required String permissionId,
}) {
  return SessionInfo(
    id: id,
    provider: provider,
    projectPath: '/project',
    claudeSessionId: providerSessionId,
    status: 'waiting_approval',
    createdAt: '2026-07-25T00:00:00Z',
    lastActivityAt: '2026-07-25T00:00:00Z',
    pendingPermission: PermissionRequestMessage(
      toolUseId: permissionId,
      toolName: 'Bash',
      input: const <String, dynamic>{},
    ),
  );
}
