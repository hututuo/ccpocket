import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/auto_approval/auto_approval_service.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  final _sessionsController = StreamController<List<SessionInfo>>.broadcast();
  final _connectionController =
      StreamController<BridgeConnectionState>.broadcast();
  final sent = <Map<String, dynamic>>[];
  final sentDeliveries = <ClientMessageDelivery>[];
  int sessionListRequests = 0;
  int authoritativeGeneration = 0;

  List<SessionInfo> currentSessions = const [];
  bool connected = true;
  String? url = 'wss://bridge.example.test:8765/ws';
  String? logicalIdentity;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessionsController.stream;

  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      _connectionController.stream;

  @override
  List<SessionInfo> get sessions => currentSessions;

  @override
  bool get isConnected => connected;

  @override
  String? get lastUrl => url;

  @override
  String? get logicalConnectionIdentity => logicalIdentity;

  @override
  int get authoritativeSessionListGeneration => authoritativeGeneration;

  void emitSessions(List<SessionInfo> sessions) {
    authoritativeGeneration += 1;
    currentSessions = sessions;
    _sessionsController.add(sessions);
  }

  void emitConnection(BridgeConnectionState state) {
    connected = state == BridgeConnectionState.connected;
    _connectionController.add(state);
  }

  @override
  void send(ClientMessage message) {
    sent.add(jsonDecode(message.toJson()) as Map<String, dynamic>);
    sentDeliveries.add(message.delivery);
  }

  @override
  void requestSessionList() => sessionListRequests += 1;

  @override
  void dispose() {
    _sessionsController.close();
    _connectionController.close();
    super.dispose();
  }
}

SessionInfo _session({
  String runtimeId = 'runtime-1',
  String? stableId = 'thread-1',
  String provider = 'codex',
  PermissionRequestMessage? pending,
}) => SessionInfo(
  id: runtimeId,
  provider: provider,
  projectPath: '/tmp/project',
  claudeSessionId: stableId,
  status: pending == null ? 'running' : 'waiting_approval',
  createdAt: '2026-07-18T00:00:00Z',
  lastActivityAt: '2026-07-18T00:00:00Z',
  pendingPermission: pending,
);

const _bashRequest = PermissionRequestMessage(
  toolUseId: 'tool-bash',
  toolName: 'Bash',
  input: {'command': 'pwd'},
);

Future<
  ({_Bridge bridge, AutoApprovalService service, SharedPreferences preferences})
>
_harness({
  Map<String, Object> initialPreferences = const {},
  Duration reconcileDelay = const Duration(seconds: 2),
  int maxTrackedRequests = 512,
  AutoApprovalPersistence? persistEnabledKeys,
}) async {
  SharedPreferences.setMockInitialValues(initialPreferences);
  final preferences = await SharedPreferences.getInstance();
  final bridge = _Bridge()..currentSessions = [_session()];
  final service = AutoApprovalService(
    bridge: bridge,
    preferences: preferences,
    reconcileDelay: reconcileDelay,
    maxTrackedRequests: maxTrackedRequests,
    persistEnabledKeys: persistEnabledKeys,
  )..initialize();
  return (bridge: bridge, service: service, preferences: preferences);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('live-only approval preserves the existing wire payload', () {
    final message = ClientMessage.approveLiveOnly(
      'tool-1',
      sessionId: 'runtime-1',
    );

    expect(jsonDecode(message.toJson()), {
      'type': 'approve',
      'id': 'tool-1',
      'sessionId': 'runtime-1',
    });
    expect(message.delivery, ClientMessageDelivery.ephemeral);
  });

  test('uses a strict v1 request allowlist', () {
    const mcpApproval = PermissionRequestMessage(
      toolUseId: 'mcp',
      toolName: 'McpElicitation',
      input: {
        'mode': 'form',
        'availableDecisions': ['accept', 'decline'],
        'questions': [
          {
            'header': 'Approve app tool call?',
            'question': 'Allow this app tool call?',
            'options': [
              {'label': 'Allow'},
              {'label': 'Cancel'},
            ],
          },
        ],
      },
    );
    const allowedToolNames = [
      'Bash',
      'FileChange',
      'Permissions',
      'ExitPlanMode',
    ];
    for (final toolName in allowedToolNames) {
      expect(
        AutoApprovalService.isEligibleRequest(
          PermissionRequestMessage(
            toolUseId: toolName,
            toolName: toolName,
            input: const {},
          ),
        ),
        isTrue,
      );
    }
    expect(AutoApprovalService.isEligibleRequest(mcpApproval), isTrue);

    const manualRequests = [
      PermissionRequestMessage(
        toolUseId: 'question',
        toolName: 'AskUserQuestion',
        input: {
          'questions': [
            {'question': 'Choose one'},
          ],
        },
      ),
      PermissionRequestMessage(
        toolUseId: 'plugin',
        toolName: 'ToolSuggestion',
        input: {'toolName': 'some-plugin'},
      ),
      PermissionRequestMessage(
        toolUseId: 'form',
        toolName: 'McpElicitation',
        input: {
          'questions': [
            {'header': 'Account', 'question': 'Enter your account'},
          ],
        },
      ),
      PermissionRequestMessage(
        toolUseId: 'spoofed-approval-form',
        toolName: 'McpElicitation',
        input: {
          'mode': 'form',
          'requestedSchema': {'type': 'object', 'properties': {}},
          'questions': [
            {
              'header': 'Approve app tool call?',
              'question': 'Choose an account action',
              'options': [
                {'label': 'Allow'},
                {'label': 'Cancel'},
              ],
            },
          ],
        },
      ),
      PermissionRequestMessage(
        toolUseId: 'future',
        toolName: 'FutureDangerousTool',
        input: {},
      ),
    ];
    for (final request in manualRequests) {
      expect(AutoApprovalService.isEligibleRequest(request), isFalse);
    }
  });

  test(
    'defaults off and leaves ordinary permission delivery untouched',
    () async {
      final harness = await _harness();
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);

      expect(harness.service.isEnabledForSession('runtime-1'), isFalse);
      expect(
        harness.service.handlePermissionRequestForTest(
          'runtime-1',
          _bashRequest,
        ),
        isFalse,
      );
      expect(harness.bridge.sent, isEmpty);
    },
  );

  test(
    'approves an eligible request exactly once without hiding manual UI',
    () async {
      final harness = await _harness();
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);

      expect(
        await harness.service.setEnabledForSession('runtime-1', true),
        isTrue,
      );
      expect(
        harness.service.handlePermissionRequestForTest(
          'runtime-1',
          _bashRequest,
        ),
        isTrue,
      );
      expect(
        harness.service.handlePermissionRequestForTest(
          'runtime-1',
          _bashRequest,
        ),
        isFalse,
      );

      expect(harness.bridge.sent, [
        {'type': 'approve', 'id': 'tool-bash', 'sessionId': 'runtime-1'},
      ]);
      expect(harness.service.approvedCountForSession('runtime-1'), 1);
      expect(harness.bridge.sentDeliveries, [ClientMessageDelivery.ephemeral]);
    },
  );

  test(
    'enabling catches a permission already pending without an open screen',
    () async {
      final harness = await _harness();
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);
      harness.bridge.currentSessions = [_session(pending: _bashRequest)];

      await harness.service.setEnabledForSession('runtime-1', true);

      expect(harness.bridge.sent.single['type'], 'approve');
      expect(harness.bridge.sent.single['sessionId'], 'runtime-1');
    },
  );

  test(
    'session-list replay catches pending approval and remains idempotent',
    () async {
      final harness = await _harness();
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);
      await harness.service.setEnabledForSession('runtime-1', true);

      final pending = _session(pending: _bashRequest);
      harness.bridge.emitSessions([pending]);
      harness.bridge.emitSessions([pending]);
      await pumpEventQueue();

      expect(harness.bridge.sent, hasLength(1));
    },
  );

  test('bounds reconciliation retries for an unresolved request', () async {
    final harness = await _harness(
      reconcileDelay: const Duration(milliseconds: 5),
    );
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    await harness.service.setEnabledForSession('runtime-1', true);
    final pending = _session(pending: _bashRequest);

    harness.bridge.emitSessions([pending]);
    await pumpEventQueue();
    for (var expectedAttempts = 2; expectedAttempts <= 3; expectedAttempts++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      harness.bridge.emitSessions([pending]);
      await pumpEventQueue();
      expect(harness.bridge.sent, hasLength(expectedAttempts));
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    harness.bridge.emitSessions([pending]);
    await pumpEventQueue();

    expect(harness.bridge.sent, hasLength(3));
    expect(harness.bridge.sessionListRequests, 3);
  });

  test('tracking capacity fails closed without resetting old limits', () async {
    final harness = await _harness(
      reconcileDelay: const Duration(days: 1),
      maxTrackedRequests: 4,
    );
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    await harness.service.setEnabledForSession('runtime-1', true);

    for (var index = 0; index < 5; index++) {
      final approved = harness.service.handlePermissionRequestForTest(
        'runtime-1',
        PermissionRequestMessage(
          toolUseId: 'capacity-$index',
          toolName: 'Bash',
          input: const {'command': 'pwd'},
        ),
      );
      expect(approved, index < 4);
    }

    expect(harness.bridge.sent, hasLength(4));
    expect(
      harness.service.handlePermissionRequestForTest(
        'runtime-1',
        const PermissionRequestMessage(
          toolUseId: 'capacity-4',
          toolName: 'Bash',
          input: {'command': 'pwd'},
        ),
      ),
      isFalse,
    );
    expect(harness.bridge.sent, hasLength(4));
  });

  test(
    'alternating pending snapshots cannot reset per-request limits',
    () async {
      final harness = await _harness(
        reconcileDelay: const Duration(milliseconds: 2),
      );
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);
      await harness.service.setEnabledForSession('runtime-1', true);
      const secondRequest = PermissionRequestMessage(
        toolUseId: 'tool-file',
        toolName: 'FileChange',
        input: {'changes': []},
      );

      for (var cycle = 0; cycle < 5; cycle++) {
        harness.bridge.emitSessions([_session(pending: _bashRequest)]);
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 4));
        harness.bridge.emitSessions([_session(pending: secondRequest)]);
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }

      expect(
        harness.bridge.sent.where((message) => message['id'] == 'tool-bash'),
        hasLength(3),
      );
      expect(
        harness.bridge.sent.where((message) => message['id'] == 'tool-file'),
        hasLength(3),
      );
    },
  );

  test('disabling supervision cancels pending reconciliation', () async {
    final harness = await _harness(
      reconcileDelay: const Duration(milliseconds: 5),
    );
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    harness.bridge.currentSessions = [_session(pending: _bashRequest)];

    await harness.service.setEnabledForSession('runtime-1', true);
    expect(harness.bridge.sent, hasLength(1));
    await harness.service.setEnabledForSession('runtime-1', false);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(harness.bridge.sessionListRequests, 0);
    expect(harness.service.isEnabledForSession('runtime-1'), isFalse);
  });

  test('resolved pending state allows the next request to proceed', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    await harness.service.setEnabledForSession('runtime-1', true);

    harness.bridge.emitSessions([_session(pending: _bashRequest)]);
    await pumpEventQueue();
    harness.bridge.emitSessions([_session()]);
    await pumpEventQueue();
    const nextRequest = PermissionRequestMessage(
      toolUseId: 'tool-file',
      toolName: 'FileChange',
      input: {'changes': []},
    );
    harness.bridge.emitSessions([_session(pending: nextRequest)]);
    await pumpEventQueue();

    expect(harness.bridge.sent.map((message) => message['id']), [
      'tool-bash',
      'tool-file',
    ]);
  });

  test('request without a one-shot accept decision remains manual', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    await harness.service.setEnabledForSession('runtime-1', true);
    const request = PermissionRequestMessage(
      toolUseId: 'tool-session',
      toolName: 'Permissions',
      input: {
        'availableDecisions': ['acceptForSession', 'decline'],
      },
    );

    expect(
      harness.service.handlePermissionRequestForTest('runtime-1', request),
      isFalse,
    );
    expect(harness.bridge.sent, isEmpty);
  });

  test(
    'questions, malformed questions, and tool suggestions stay manual',
    () async {
      final harness = await _harness();
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);
      await harness.service.setEnabledForSession('runtime-1', true);
      const requests = [
        PermissionRequestMessage(
          toolUseId: 'question',
          toolName: 'AskUserQuestion',
          input: {
            'questions': [
              {'question': 'Choose one'},
            ],
          },
        ),
        PermissionRequestMessage(
          toolUseId: 'malformed',
          toolName: 'AskUserQuestion',
          input: {'questions': []},
        ),
        PermissionRequestMessage(
          toolUseId: 'plugin',
          toolName: 'ToolSuggestion',
          input: {'toolName': 'some-plugin'},
        ),
        PermissionRequestMessage(
          toolUseId: 'decline-only',
          toolName: 'Bash',
          input: {
            'availableDecisions': ['decline'],
          },
        ),
      ];

      for (final request in requests) {
        expect(
          harness.service.handlePermissionRequestForTest('runtime-1', request),
          isFalse,
        );
      }
      expect(harness.bridge.sent, isEmpty);
    },
  );

  test(
    'persists stable conversation identity across runtime rebinding',
    () async {
      final first = await _harness();
      await first.service.setEnabledForSession('runtime-1', true);
      first.service.dispose();
      first.bridge.dispose();

      final stored = first.preferences.getStringList(
        AutoApprovalService.preferencesKey,
      );
      final second = await _harness(
        initialPreferences: {AutoApprovalService.preferencesKey: stored!},
      );
      addTearDown(second.service.dispose);
      addTearDown(second.bridge.dispose);
      second.bridge.currentSessions = [
        _session(runtimeId: 'runtime-2', stableId: 'thread-1'),
      ];

      expect(second.service.isEnabledForSession('runtime-2'), isTrue);
      expect(
        second.service.handlePermissionRequestForTest(
          'runtime-2',
          _bashRequest,
        ),
        isTrue,
      );
      expect(second.bridge.sent.single['sessionId'], 'runtime-2');
    },
  );

  test(
    'failed disable persistence leaves the switch visibly enabled',
    () async {
      final first = await _harness();
      await first.service.setEnabledForSession('runtime-1', true);
      final stored = first.preferences.getStringList(
        AutoApprovalService.preferencesKey,
      );
      first.service.dispose();
      first.bridge.dispose();

      final second = await _harness(
        initialPreferences: {AutoApprovalService.preferencesKey: stored!},
        persistEnabledKeys: (_) async => false,
      );
      addTearDown(second.service.dispose);
      addTearDown(second.bridge.dispose);

      expect(second.service.isEnabledForSession('runtime-1'), isTrue);
      expect(
        await second.service.setEnabledForSession('runtime-1', false),
        isFalse,
      );
      expect(second.service.isEnabledForSession('runtime-1'), isTrue);
    },
  );

  test('disable suppresses approvals before persistence completes', () async {
    final seed = await _harness();
    await seed.service.setEnabledForSession('runtime-1', true);
    final stored = seed.preferences.getStringList(
      AutoApprovalService.preferencesKey,
    );
    seed.service.dispose();
    seed.bridge.dispose();

    final write = Completer<bool>();
    final harness = await _harness(
      initialPreferences: {AutoApprovalService.preferencesKey: stored!},
      persistEnabledKeys: (_) => write.future,
    );
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);

    final disabling = harness.service.setEnabledForSession('runtime-1', false);
    expect(harness.service.isEnabledForSession('runtime-1'), isFalse);
    expect(
      harness.service.handlePermissionRequestForTest('runtime-1', _bashRequest),
      isFalse,
    );
    expect(harness.bridge.sent, isEmpty);

    write.complete(true);
    expect(await disabling, isTrue);
  });

  test('serializes cross-session disable and enable mutations', () async {
    final seed = await _harness();
    await seed.service.setEnabledForSession('runtime-1', true);
    final stored = seed.preferences.getStringList(
      AutoApprovalService.preferencesKey,
    );
    seed.service.dispose();
    seed.bridge.dispose();

    final firstWrite = Completer<bool>();
    final writes = <List<String>>[];
    var writeCount = 0;
    final harness = await _harness(
      initialPreferences: {AutoApprovalService.preferencesKey: stored!},
      persistEnabledKeys: (values) {
        writes.add(List<String>.of(values));
        writeCount += 1;
        if (writeCount == 1) return firstWrite.future;
        return Future<bool>.value(true);
      },
    );
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    harness.bridge.currentSessions = [
      _session(),
      _session(runtimeId: 'runtime-2', stableId: 'thread-2'),
    ];

    final disableFirst = harness.service.setEnabledForSession(
      'runtime-1',
      false,
    );
    await pumpEventQueue();
    final enableSecond = harness.service.setEnabledForSession(
      'runtime-2',
      true,
    );
    await pumpEventQueue();
    expect(writes, hasLength(1));

    firstWrite.complete(true);
    expect(await disableFirst, isTrue);
    expect(await enableSecond, isTrue);

    expect(writes, hasLength(2));
    expect(writes.first, isEmpty);
    expect(writes.last, hasLength(1));
    expect(jsonDecode(writes.last.single), [
      1,
      'endpoint:wss://bridge.example.test:8765/ws',
      'codex',
      'thread-2',
    ]);
    expect(harness.service.isEnabledForSession('runtime-1'), isFalse);
    expect(harness.service.isEnabledForSession('runtime-2'), isTrue);
  });

  test('rapid enable then disable preserves the latest intent', () async {
    final firstWrite = Completer<bool>();
    final writes = <List<String>>[];
    var writeCount = 0;
    final harness = await _harness(
      persistEnabledKeys: (values) {
        writes.add(List<String>.of(values));
        writeCount += 1;
        if (writeCount == 1) return firstWrite.future;
        return Future<bool>.value(true);
      },
    );
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);

    final enable = harness.service.setEnabledForSession('runtime-1', true);
    await pumpEventQueue();
    final disable = harness.service.setEnabledForSession('runtime-1', false);
    await pumpEventQueue();
    expect(writes, hasLength(1));

    firstWrite.complete(true);
    expect(await enable, isTrue);
    expect(await disable, isTrue);

    expect(writes, hasLength(2));
    expect(writes.first, hasLength(1));
    expect(writes.last, isEmpty);
    expect(harness.service.isEnabledForSession('runtime-1'), isFalse);
  });

  test(
    'queued mutations retain the machine identity captured on tap',
    () async {
      final firstWrite = Completer<bool>();
      final writes = <List<String>>[];
      var writeCount = 0;
      final harness = await _harness(
        persistEnabledKeys: (values) {
          writes.add(List<String>.of(values));
          writeCount += 1;
          if (writeCount == 1) return firstWrite.future;
          return Future<bool>.value(true);
        },
      );
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);

      harness.bridge.logicalIdentity = 'machine:machine-a';
      final enableA = harness.service.setEnabledForSession('runtime-1', true);
      await pumpEventQueue();
      harness.bridge.logicalIdentity = 'machine:machine-b';
      final enableB = harness.service.setEnabledForSession('runtime-1', true);
      harness.bridge.logicalIdentity = 'machine:machine-a';

      firstWrite.complete(true);
      expect(await enableA, isTrue);
      expect(await enableB, isTrue);

      final identities = writes.last
          .map((value) => jsonDecode(value) as List<dynamic>)
          .map((parts) => parts[1])
          .toSet();
      expect(identities, {'machine:machine-a', 'machine:machine-b'});
    },
  );

  test(
    'different Bridge endpoint does not inherit approval authority',
    () async {
      final harness = await _harness();
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);
      await harness.service.setEnabledForSession('runtime-1', true);

      harness.bridge.url = 'wss://other.example.test:8765/ws';

      expect(harness.service.isEnabledForSession('runtime-1'), isFalse);
      expect(
        harness.service.handlePermissionRequestForTest(
          'runtime-1',
          _bashRequest,
        ),
        isFalse,
      );
    },
  );

  test('stable machine identity survives a new SSH tunnel port', () async {
    final first = await _harness();
    first.bridge.logicalIdentity = 'machine:machine-1';
    first.bridge.url = 'ws://127.0.0.1:41001';
    await first.service.setEnabledForSession('runtime-1', true);
    final stored = first.preferences.getStringList(
      AutoApprovalService.preferencesKey,
    );
    first.service.dispose();
    first.bridge.dispose();

    final second = await _harness(
      initialPreferences: {AutoApprovalService.preferencesKey: stored!},
    );
    addTearDown(second.service.dispose);
    addTearDown(second.bridge.dispose);
    second.bridge.logicalIdentity = 'machine:machine-1';
    second.bridge.url = 'ws://127.0.0.1:52002';

    expect(second.service.isEnabledForSession('runtime-1'), isTrue);
  });

  test('a different machine cannot inherit a reused tunnel endpoint', () async {
    final first = await _harness();
    first.bridge.logicalIdentity = 'machine:machine-1';
    first.bridge.url = 'ws://127.0.0.1:41001';
    await first.service.setEnabledForSession('runtime-1', true);
    final stored = first.preferences.getStringList(
      AutoApprovalService.preferencesKey,
    );
    first.service.dispose();
    first.bridge.dispose();

    final second = await _harness(
      initialPreferences: {AutoApprovalService.preferencesKey: stored!},
    );
    addTearDown(second.service.dispose);
    addTearDown(second.bridge.dispose);
    second.bridge.logicalIdentity = 'machine:machine-2';
    second.bridge.url = 'ws://127.0.0.1:41001';

    expect(second.service.isEnabledForSession('runtime-1'), isFalse);
  });

  test('missing stable provider identity fails closed', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    harness.bridge.currentSessions = [_session(stableId: null)];

    expect(harness.service.canConfigureSession('runtime-1'), isFalse);
    expect(
      await harness.service.setEnabledForSession('runtime-1', true),
      isFalse,
    );
    expect(
      harness.service.handlePermissionRequestForTest('runtime-1', _bashRequest),
      isFalse,
    );
  });

  test('session identity arrival and removal notify open feature UI', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    var notifications = 0;
    harness.service.addListener(() => notifications += 1);

    harness.bridge.emitSessions([_session(stableId: null)]);
    await pumpEventQueue();
    expect(harness.service.canConfigureSession('runtime-1'), isFalse);
    final afterMissingIdentity = notifications;

    harness.bridge.emitSessions([_session(stableId: 'thread-1')]);
    await pumpEventQueue();
    expect(harness.service.canConfigureSession('runtime-1'), isTrue);
    expect(notifications, greaterThan(afterMissingIdentity));

    final afterIdentity = notifications;
    harness.bridge.emitSessions(const []);
    await pumpEventQueue();
    expect(harness.service.canConfigureSession('runtime-1'), isFalse);
    expect(notifications, greaterThan(afterIdentity));
  });

  test('offline disable all prevents approval on the next reconnect', () async {
    final seed = await _harness();
    await seed.service.setEnabledForSession('runtime-1', true);
    final stored = seed.preferences.getStringList(
      AutoApprovalService.preferencesKey,
    );
    seed.service.dispose();
    seed.bridge.dispose();

    final harness = await _harness(
      initialPreferences: {AutoApprovalService.preferencesKey: stored!},
    );
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    harness.bridge.connected = false;
    harness.bridge.currentSessions = const [];

    expect(harness.service.hasEnabledConversations, isTrue);
    expect(await harness.service.disableAll(), isTrue);
    expect(harness.service.hasEnabledConversations, isFalse);
    expect(
      harness.preferences.getStringList(AutoApprovalService.preferencesKey),
      isEmpty,
    );

    harness.bridge.currentSessions = [_session(pending: _bashRequest)];
    harness.bridge.emitConnection(BridgeConnectionState.connected);
    await pumpEventQueue();
    expect(harness.bridge.sent, isEmpty);
  });

  test('disable all still writes empty after a queued disable fails', () async {
    final seed = await _harness();
    await seed.service.setEnabledForSession('runtime-1', true);
    final stored = seed.preferences.getStringList(
      AutoApprovalService.preferencesKey,
    );
    seed.service.dispose();
    seed.bridge.dispose();

    final firstWrite = Completer<bool>();
    final writes = <List<String>>[];
    var writeCount = 0;
    final harness = await _harness(
      initialPreferences: {AutoApprovalService.preferencesKey: stored!},
      persistEnabledKeys: (values) {
        writes.add(List<String>.of(values));
        writeCount += 1;
        if (writeCount == 1) return firstWrite.future;
        return Future<bool>.value(true);
      },
    );
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);

    final singleDisable = harness.service.setEnabledForSession(
      'runtime-1',
      false,
    );
    await pumpEventQueue();
    expect(harness.service.hasEnabledConversations, isFalse);
    final globalDisable = harness.service.disableAll();
    await pumpEventQueue();

    firstWrite.complete(false);
    expect(await singleDisable, isFalse);
    expect(await globalDisable, isTrue);
    expect(writes, hasLength(2));
    expect(writes.last, isEmpty);
    expect(harness.service.hasEnabledConversations, isFalse);
  });

  test(
    'disconnect pauses approval and reconnect reconsiders pending state',
    () async {
      final harness = await _harness();
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);
      await harness.service.setEnabledForSession('runtime-1', true);
      final pending = _session(pending: _bashRequest);
      harness.bridge.currentSessions = [pending];

      harness.bridge.emitConnection(BridgeConnectionState.disconnected);
      await pumpEventQueue();
      expect(
        harness.service.handlePermissionRequestForTest(
          'runtime-1',
          _bashRequest,
        ),
        isFalse,
      );
      expect(harness.bridge.sent, isEmpty);

      harness.bridge.emitConnection(BridgeConnectionState.connected);
      await pumpEventQueue();
      expect(harness.bridge.sent, isEmpty);
      expect(harness.bridge.sessionListRequests, 1);

      harness.bridge.emitSessions([pending]);
      await pumpEventQueue();
      expect(harness.bridge.sent, hasLength(1));
    },
  );

  test(
    'enabling during reconnect waits for an authoritative session list',
    () async {
      final harness = await _harness();
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);
      final pending = _session(pending: _bashRequest);

      harness.bridge.emitConnection(BridgeConnectionState.disconnected);
      harness.bridge.currentSessions = [pending];
      harness.bridge.emitConnection(BridgeConnectionState.connected);
      await pumpEventQueue();

      expect(
        await harness.service.setEnabledForSession('runtime-1', true),
        isTrue,
      );
      expect(harness.bridge.sent, isEmpty);

      harness.bridge.emitSessions([pending]);
      await pumpEventQueue();
      expect(harness.bridge.sent, hasLength(1));
    },
  );

  test('sanitizes endpoint credentials before persistence identity', () {
    expect(
      AutoApprovalService.sanitizeBridgeEndpoint(
        'wss://user:secret@EXAMPLE.test:8765/socket?token=hidden#fragment',
      ),
      'wss://example.test:8765/socket',
    );
    expect(
      AutoApprovalService.sanitizeBridgeEndpoint('https://example.test'),
      isNull,
    );
  });

  test('non-Codex sessions cannot enable the local supervisor', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    harness.bridge.currentSessions = [_session(provider: 'claude')];

    expect(harness.service.canConfigureSession('runtime-1'), isFalse);
    expect(
      await harness.service.setEnabledForSession('runtime-1', true),
      isFalse,
    );
  });
}
