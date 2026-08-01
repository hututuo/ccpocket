import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/notification_approval_coordinator.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('cold-start v2 actions wait for authenticated source revalidation', () {
    const expected = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-a',
      codexSourceId: 'source-a',
    );
    const unscoped = BridgeDataSourceIdentity.unscoped;
    const different = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-b',
      codexSourceId: 'source-b',
    );

    expect(
      shouldQueueNotificationApprovalAction(
        actionPayloadVersion: 2,
        provider: 'codex',
        expected: expected,
        current: unscoped,
        currentIdentityAuthoritative: false,
      ),
      isTrue,
    );
    expect(
      shouldQueueNotificationApprovalAction(
        actionPayloadVersion: 2,
        provider: 'codex',
        expected: expected,
        current: different,
        currentIdentityAuthoritative: true,
      ),
      isFalse,
    );
    expect(
      shouldQueueNotificationApprovalAction(
        actionPayloadVersion: 1,
        provider: 'codex',
        expected: expected,
        current: unscoped,
        currentIdentityAuthoritative: false,
      ),
      isFalse,
    );
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

  test('rejects an unknown persisted approval action payload version', () {
    expect(
      NotificationApprovalRequest.fromJson(<String, Object?>{
        'actionPayloadVersion': 3,
        'sessionId': 'thread-1',
        'provider': 'codex',
        'permissionId': 'opaque-1',
        'decision': 'approve',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      }),
      isNull,
    );
  });

  test(
    'shared Codex notification uses CAB once and waits for canonical resolution',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final legacyBridge = _FakeNotificationApprovalBridge();
      final codexBridge = _FakeCodexActionBridge();
      final coordinator = NotificationApprovalCoordinator(
        preferences: preferences,
        bridge: legacyBridge,
        codexBridge: codexBridge,
        createId: () => 'notification-operation-1',
      );
      await coordinator.initialize();
      addTearDown(codexBridge.dispose);
      addTearDown(coordinator.dispose);

      await coordinator.submit(_brokerApproval());
      codexBridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _brokerHealth(),
          requests: [_brokerRequest()],
        ),
      );
      await _flushEvents();

      final responses = codexBridge.sent
          .where((message) => message['type'] == 'respond_codex_action')
          .toList(growable: false);
      expect(responses, hasLength(1));
      expect(
        responses.single,
        containsPair('operationId', 'notification-operation-1'),
      );
      expect(
        codexBridge.sent.where(
          (message) =>
              message['type'] == 'approve' || message['type'] == 'reject',
        ),
        isEmpty,
      );

      codexBridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.response,
          requestId: responses.single['requestId'] as String,
          opaqueRequestId: 'opaque-1',
          outcome: CodexActionBrokerResponseOutcome.outcomeUnknown,
        ),
      );
      await _flushEvents();
      final queued =
          jsonDecode(preferences.getString('notification_approval_queue_v2')!)
              as List;
      expect((queued.single as Map)['queueState'], 'awaitingCanonical');

      // The same action may also arrive from Flutter's notification callback
      // after the native host delivered it. It must not reset the durable
      // awaiting state or submit a second broker mutation.
      await coordinator.submit(_brokerApproval());
      await _flushEvents();
      expect(
        codexBridge.sent.where(
          (message) => message['type'] == 'respond_codex_action',
        ),
        hasLength(1),
      );
      final deduplicatedQueue =
          jsonDecode(preferences.getString('notification_approval_queue_v2')!)
              as List;
      expect(
        (deduplicatedQueue.single as Map)['operationId'],
        'notification-operation-1',
      );
      expect(
        (deduplicatedQueue.single as Map)['queueState'],
        'awaitingCanonical',
      );

      codexBridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.request,
          request: _brokerRequest(
            state: CodexActionBrokerRequestState.resolved,
            live: false,
          ),
        ),
      );
      await _flushEvents();
      expect(preferences.getString('notification_approval_queue_v2'), isNull);
      expect(
        codexBridge.sent.where(
          (message) => message['type'] == 'respond_codex_action',
        ),
        hasLength(1),
      );
    },
  );

  test('does not replay a persisted CAB action after restart', () async {
    final persistedRequest = _brokerApproval().copyWith(
      operationId: 'notification-operation-restart',
      queueState: NotificationApprovalQueueState.awaitingCanonical,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'notification_approval_queue_v2': jsonEncode(<Object?>[
        persistedRequest.toJson(),
      ]),
    });
    final preferences = await SharedPreferences.getInstance();
    final codexBridge = _FakeCodexActionBridge();
    final coordinator = NotificationApprovalCoordinator(
      preferences: preferences,
      bridge: _FakeNotificationApprovalBridge(),
      codexBridge: codexBridge,
    );
    await coordinator.initialize();
    addTearDown(codexBridge.dispose);
    addTearDown(coordinator.dispose);

    codexBridge.emit(
      CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.snapshot,
        health: _brokerHealth(),
        requests: [_brokerRequest()],
      ),
    );
    await _flushEvents();
    expect(
      codexBridge.sent.where(
        (message) => message['type'] == 'respond_codex_action',
      ),
      isEmpty,
    );
    expect(preferences.getString('notification_approval_queue_v2'), isNotNull);

    codexBridge.emit(
      CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.snapshot,
        health: _brokerHealth(),
        requests: const <CodexActionBrokerRequest>[],
      ),
    );
    await _flushEvents();
    expect(preferences.getString('notification_approval_queue_v2'), isNull);
  });

  test(
    'shared Codex notification fails closed across source and standby',
    () async {
      final codexBridge = _FakeCodexActionBridge()
        ..currentSourceId = 'source-2';
      final coordinator = NotificationApprovalCoordinator(
        preferences: await SharedPreferences.getInstance(),
        bridge: _FakeNotificationApprovalBridge(),
        codexBridge: codexBridge,
        createId: () => 'notification-operation-2',
      );
      await coordinator.initialize();
      addTearDown(codexBridge.dispose);
      addTearDown(coordinator.dispose);
      await coordinator.submit(_brokerApproval());
      codexBridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _brokerHealth(writerLeaseHeld: false),
          requests: [_brokerRequest()],
        ),
      );
      await _flushEvents();
      expect(
        codexBridge.sent.where(
          (message) => message['type'] == 'respond_codex_action',
        ),
        isEmpty,
      );

      codexBridge.currentSourceId = 'source-1';
      codexBridge.emitConnection(BridgeConnectionState.connected);
      codexBridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _brokerHealth(writerLeaseHeld: false),
          requests: [_brokerRequest()],
        ),
      );
      await _flushEvents();
      expect(
        codexBridge.sent.where(
          (message) => message['type'] == 'respond_codex_action',
        ),
        isEmpty,
      );
    },
  );
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

NotificationApprovalRequest _brokerApproval() => NotificationApprovalRequest(
  sessionId: 'thread-1',
  provider: 'codex',
  providerSessionId: 'thread-1',
  permissionId: 'opaque-1',
  decision: NotificationApprovalDecision.approve,
  createdAt: DateTime.now().toUtc(),
  actionPayloadVersion: 2,
  bridgeInstanceId: 'bridge-1',
  codexSourceId: 'source-1',
  threadId: 'thread-1',
  turnId: 'turn-1',
  authorityGeneration: 'cab:1:1',
  allowedActions: const {
    CodexActionBrokerDecision.approve,
    CodexActionBrokerDecision.reject,
  },
);

CodexActionBrokerHealth _brokerHealth({bool writerLeaseHeld = true}) =>
    CodexActionBrokerHealth(
      ready: writerLeaseHeld,
      controlReady: true,
      degraded: false,
      writerLeaseHeld: writerLeaseHeld,
      degradedReason: writerLeaseHeld ? null : 'writer_lease_unavailable',
      authorityGeneration: 'cab:1:1',
    );

CodexActionBrokerRequest _brokerRequest({
  CodexActionBrokerRequestState state = CodexActionBrokerRequestState.pending,
  bool live = true,
}) => CodexActionBrokerRequest(
  opaqueRequestId: 'opaque-1',
  codexSourceId: 'source-1',
  threadId: 'thread-1',
  turnId: 'turn-1',
  kind: CodexActionBrokerRequestKind.commandApproval,
  state: state,
  observedAt: DateTime.utc(2026, 8, 1),
  expiresAt: DateTime.utc(2026, 8, 1, 0, 10),
  updatedAt: DateTime.utc(2026, 8, 1, 0, 0, 1),
  authorityGeneration: 'cab:1:1',
  live: live,
  toolName: 'Bash',
  input: const {'command': 'hidden'},
  allowedActions: const {
    CodexActionBrokerDecision.approve,
    CodexActionBrokerDecision.reject,
  },
);

class _FakeCodexActionBridge extends BridgeService {
  final featureMessages =
      StreamController<LocalFeatureServerMessage>.broadcast();
  final connections = StreamController<BridgeConnectionState>.broadcast();
  final sessionEvents = StreamController<List<SessionInfo>>.broadcast();
  final List<Map<String, dynamic>> sent = [];
  String? currentBridgeId = 'bridge-1';
  String? currentSourceId = 'source-1';

  @override
  bool get isConnected => true;

  @override
  bool get supportsCodexActionBroker => true;

  @override
  String? get bridgeInstanceId => currentBridgeId;

  @override
  String? get codexSourceId => currentSourceId;

  @override
  Stream<LocalFeatureServerMessage> get localFeatureMessages =>
      featureMessages.stream;

  @override
  Stream<BridgeConnectionState> get connectionStatus => connections.stream;

  @override
  Stream<List<SessionInfo>> get sessionList => sessionEvents.stream;

  @override
  void send(ClientMessage message) {
    sent.add(jsonDecode(message.toJson()) as Map<String, dynamic>);
  }

  void emit(LocalFeatureServerMessage message) => featureMessages.add(message);
  void emitConnection(BridgeConnectionState state) => connections.add(state);

  @override
  void dispose() {
    featureMessages.close();
    connections.close();
    sessionEvents.close();
    super.dispose();
  }
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
