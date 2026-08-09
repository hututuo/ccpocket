import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_state.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _GoalBridge extends BridgeService {
  final _messages = StreamController<(ServerMessage, String?)>.broadcast();
  final _connections = StreamController<BridgeConnectionState>.broadcast();
  final _sessions = StreamController<List<SessionInfo>>.broadcast();
  final sentMessages = <ClientMessage>[];
  bool connected = true;
  List<SessionInfo> sessionSnapshot = const [];
  Set<String> capabilities = const {};
  String? sourceId;

  void emitMessage(ServerMessage message, {String? sessionId}) {
    _messages.add((message, sessionId));
  }

  void emitConnection(BridgeConnectionState state) {
    connected = state == BridgeConnectionState.connected;
    _connections.add(state);
  }

  void emitSessions(List<SessionInfo> sessions) {
    sessionSnapshot = sessions;
    _sessions.add(sessions);
  }

  @override
  Stream<ServerMessage> get messages =>
      _messages.stream.map((message) => message.$1);

  @override
  Stream<ServerMessage> messagesForSession(String sessionId) => _messages.stream
      .where((message) => message.$2 == null || message.$2 == sessionId)
      .map((message) => message.$1);

  @override
  Stream<BridgeConnectionState> get connectionStatus => _connections.stream;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessions.stream;

  @override
  List<SessionInfo> get sessions => sessionSnapshot;

  @override
  bool get isConnected => connected;

  @override
  Set<String> get bridgeCapabilities => capabilities;

  @override
  String? get codexSourceId => sourceId;

  @override
  void requestSessionHistory(String sessionId) {}

  @override
  void send(ClientMessage message) {
    if (!connected && message.delivery == ClientMessageDelivery.ephemeral) {
      throw StateError('Bridge is not connected.');
    }
    sentMessages.add(message);
  }

  @override
  void dispose() {
    _messages.close();
    _connections.close();
    _sessions.close();
    super.dispose();
  }
}

void main() {
  late _GoalBridge mockBridge;
  late StreamingStateCubit streamingCubit;

  setUp(() {
    mockBridge = _GoalBridge();
    streamingCubit = StreamingStateCubit();
  });

  tearDown(() {
    streamingCubit.close();
    mockBridge.dispose();
  });

  ChatSessionCubit createCubit(
    String sessionId, {
    Provider? provider,
    bool threadReady = true,
  }) {
    if (provider == Provider.codex &&
        threadReady &&
        !mockBridge.sessionSnapshot.any((session) => session.id == sessionId)) {
      mockBridge.sessionSnapshot = [
        ...mockBridge.sessionSnapshot,
        SessionInfo(
          id: sessionId,
          provider: 'codex',
          projectPath: '/tmp/project',
          claudeSessionId: 'thread-$sessionId',
          status: 'idle',
          createdAt: '',
          lastActivityAt: '',
        ),
      ];
    }
    return ChatSessionCubit(
      sessionId: sessionId,
      provider: provider,
      bridge: mockBridge,
      streamingCubit: streamingCubit,
    );
  }

  group('Codex Goal mobile control', () {
    test(
      'new session defers Goal lookup until app-server binds its thread',
      () async {
        final cubit = createCubit(
          's-new',
          provider: Provider.codex,
          threadReady: false,
        );
        addTearDown(cubit.close);

        cubit.requestGoal(userInitiated: true);
        mockBridge.emitConnection(BridgeConnectionState.connected);
        await pumpEventQueue();
        expect(
          mockBridge.sentMessages.where(
            (message) => message.type == 'get_goal',
          ),
          isEmpty,
        );

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            sessionId: 'thread-new',
            provider: 'codex',
          ),
          sessionId: 's-new',
        );
        await pumpEventQueue();

        final requests = mockBridge.sentMessages.where(
          (message) => message.type == 'get_goal',
        );
        expect(requests, hasLength(1));
        expect(jsonDecode(requests.single.toJson()), {
          'type': 'get_goal',
          'sessionId': 's-new',
        });
      },
    );

    test(
      'prebound resume id waits for a non-starting runtime snapshot',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's-resume',
            provider: 'codex',
            projectPath: '/tmp/project',
            claudeSessionId: 'thread-resume',
            status: 'starting',
            createdAt: '',
            lastActivityAt: '',
          ),
        ];
        final cubit = createCubit(
          's-resume',
          provider: Provider.codex,
          threadReady: false,
        );
        addTearDown(cubit.close);

        cubit.requestGoal();
        expect(mockBridge.sentMessages, isEmpty);

        mockBridge.emitSessions(const [
          SessionInfo(
            id: 's-resume',
            provider: 'codex',
            projectPath: '/tmp/project',
            claudeSessionId: 'thread-resume',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
          ),
        ]);
        await pumpEventQueue();

        expect(
          mockBridge.sentMessages.where(
            (message) => message.type == 'get_goal',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'Codex /goal command sets goal without creating a chat turn',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        mockBridge.emitMessage(
          const GoalStateMessage(sessionId: 's1', goal: null),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.sendMessage('/goal Goal機能をCC Pocketに追加する');

        expect(cubit.state.entries, isEmpty);
        expect(mockBridge.sentMessages, hasLength(1));
        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(payload['type'], 'set_goal');
        expect(payload['sessionId'], 's1');
        expect(payload['objective'], 'Goal機能をCC Pocketに追加する');
        expect(payload['status'], 'active');
        expect(payload['goalChangeId'], isNotEmpty);
        expect(
          mockBridge.sentMessages.single.delivery,
          ClientMessageDelivery.ephemeral,
        );
      },
    );

    test(
      'detached durable Goal loads and /goal objective uses the native Goal target',
      () async {
        mockBridge.capabilities = const {codexDurableThreadGoalsCapability};
        mockBridge.sourceId = 'source-1';
        final cubit = ChatSessionCubit(
          sessionId: 'thread-durable',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
        );
        addTearDown(cubit.close);

        final initialRequest =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(initialRequest, {
          'type': 'get_goal',
          'sessionId': 'thread-durable',
          'goalTarget': 'durable_thread',
          'codexSourceId': 'source-1',
          'threadId': 'thread-durable',
        });

        mockBridge.emitMessage(
          const GoalStateMessage(sessionId: 'thread-durable', goal: null),
          sessionId: 'thread-durable',
        );
        await pumpEventQueue();
        expect(cubit.state.goalStateLoaded, isTrue);
        expect(cubit.state.goalSupport, CodexGoalSupport.supported);

        mockBridge.sentMessages.clear();
        expect(cubit.sendMessage('/goal Ship durable Goal support'), isTrue);
        expect(cubit.state.entries, isEmpty);
        final mutation =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(mutation, containsPair('type', 'set_goal'));
        expect(mutation, containsPair('sessionId', 'thread-durable'));
        expect(mutation, containsPair('goalTarget', 'durable_thread'));
        expect(
          mutation,
          containsPair('objective', 'Ship durable Goal support'),
        );
        expect(mutation, containsPair('expectedGoalPresent', false));
        expect(mutation['operationId'], isNotEmpty);
      },
    );

    test(
      'detached legacy Goal request fails visibly instead of loading forever',
      () {
        final cubit = ChatSessionCubit(
          sessionId: 'thread-legacy',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
        );
        addTearDown(cubit.close);

        cubit.requestGoal(userInitiated: true);

        expect(cubit.state.goalStateLoaded, isFalse);
        expect(cubit.state.goalLoadErrorKind, CodexGoalErrorKind.readFailed);
        expect(cubit.state.goalMutationError, isNotNull);
        expect(mockBridge.sentMessages, isEmpty);
      },
    );

    test(
      'future Goal status is read-only even through typed commands',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const futureGoal = CodexGoal(
          threadId: 'thread-1',
          objective: 'Future lifecycle',
          status: CodexThreadGoalStatus.active,
          rawStatus: 'awaitingReview',
          tokenBudget: null,
          tokensUsed: 1,
          timeUsedSeconds: 1,
          createdAt: 1,
          updatedAt: 2,
        );
        mockBridge.emitMessage(
          const GoalStateMessage(sessionId: 's1', goal: futureGoal),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        for (final command in const [
          '/goal pause',
          '/goal resume',
          '/goal clear',
          '/goal overwrite it',
        ]) {
          cubit.sendMessage(command);
        }
        expect(cubit.editGoal('Direct overwrite'), isFalse);
        expect(cubit.toggleGoalPaused(), isFalse);
        expect(cubit.resumeGoal(), isFalse);
        expect(cubit.clearGoal(), isFalse);

        expect(mockBridge.sentMessages, isEmpty);
        expect(
          cubit.state.goalMutationErrorKind,
          CodexGoalErrorKind.unknownStatus,
        );
        expect(cubit.state.goal, futureGoal);
      },
    );

    test(
      'Codex /goal subcommands serialize confirmed goal mutations',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        const active = CodexGoal(
          threadId: 'thread-1',
          objective: 'Goal objective',
          status: CodexThreadGoalStatus.active,
          tokenBudget: null,
          tokensUsed: 10,
          timeUsedSeconds: 5,
          createdAt: 1,
          updatedAt: 2,
        );
        mockBridge.emitMessage(
          const GoalStateMessage(sessionId: 's1', goal: active),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.sendMessage('/goal pause');
        var payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(payload['status'], 'paused');
        final pauseId = payload['goalChangeId'] as String;
        mockBridge.emitMessage(
          GoalStateMessage(
            sessionId: 's1',
            goalChangeId: pauseId,
            goal: const CodexGoal(
              threadId: 'thread-1',
              objective: 'Goal objective',
              status: CodexThreadGoalStatus.paused,
              tokenBudget: null,
              tokensUsed: 10,
              timeUsedSeconds: 5,
              createdAt: 1,
              updatedAt: 3,
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.sendMessage('/goal resume');
        payload =
            jsonDecode(mockBridge.sentMessages.last.toJson())
                as Map<String, dynamic>;
        expect(payload['status'], 'active');
        final resumeId = payload['goalChangeId'] as String;
        mockBridge.emitMessage(
          GoalStateMessage(
            sessionId: 's1',
            goalChangeId: resumeId,
            goal: const CodexGoal(
              threadId: 'thread-1',
              objective: 'Goal objective',
              status: CodexThreadGoalStatus.active,
              tokenBudget: null,
              tokensUsed: 10,
              timeUsedSeconds: 5,
              createdAt: 1,
              updatedAt: 4,
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.sendMessage('/goal clear');
        expect(cubit.state.entries, isEmpty);
        payload =
            jsonDecode(mockBridge.sentMessages.last.toJson())
                as Map<String, dynamic>;
        expect(payload['type'], 'clear_goal');
        expect(payload['goalChangeId'], isNotEmpty);
      },
    );

    test('Codex requests persisted goal after app-server init', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);

      mockBridge.emitMessage(
        const SystemMessage(subtype: 'init', sessionId: 'thread-1'),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(jsonDecode(mockBridge.sentMessages.single.toJson()), {
        'type': 'get_goal',
        'sessionId': 's1',
      });
    });

    test(
      'Codex goal state supports refresh, pause, resume, and clear',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        cubit.sendMessage('/goal');
        expect(jsonDecode(mockBridge.sentMessages.single.toJson()), {
          'type': 'get_goal',
          'sessionId': 's1',
        });

        const goal = CodexGoal(
          threadId: 'thread-1',
          objective: 'Persisted goal',
          status: CodexThreadGoalStatus.active,
          tokenBudget: null,
          tokensUsed: 10,
          timeUsedSeconds: 5,
          createdAt: 1,
          updatedAt: 2,
        );
        mockBridge.emitMessage(
          const GoalStateMessage(sessionId: 's1', goal: goal),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.goal, goal);

        mockBridge.sentMessages.clear();
        cubit.toggleGoalPaused();
        var payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(payload['type'], 'set_goal');
        expect(payload['sessionId'], 's1');
        expect(payload['status'], 'paused');

        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 's1',
            goal: CodexGoal(
              threadId: 'thread-1',
              objective: 'Persisted goal',
              status: CodexThreadGoalStatus.paused,
              tokenBudget: null,
              tokensUsed: 10,
              timeUsedSeconds: 5,
              createdAt: 1,
              updatedAt: 3,
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        mockBridge.sentMessages.clear();
        cubit.toggleGoalPaused();
        payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(payload['status'], 'active');

        mockBridge.emitMessage(
          GoalStateMessage(
            sessionId: 's1',
            goalChangeId: payload['goalChangeId'] as String,
            goal: const CodexGoal(
              threadId: 'thread-1',
              objective: 'Persisted goal',
              status: CodexThreadGoalStatus.active,
              tokenBudget: null,
              tokensUsed: 10,
              timeUsedSeconds: 5,
              createdAt: 1,
              updatedAt: 4,
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        mockBridge.sentMessages.clear();
        cubit.clearGoal();
        payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(payload['type'], 'clear_goal');
        expect(payload['sessionId'], 's1');
        expect(payload['goalChangeId'], isNotEmpty);
      },
    );

    test('Codex Goal mutations are live-only and never queued offline', () {
      mockBridge.connected = false;
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);

      expect(cubit.startGoal('Offline goal'), isFalse);
      expect(mockBridge.sentMessages, isEmpty);
      expect(cubit.state.goalMutation, isNull);
      expect(cubit.state.goalMutationError, contains('never queued offline'));
      expect(
        cubit.state.goalMutationErrorKind,
        CodexGoalErrorKind.connectRequired,
      );
    });

    test(
      'Codex Goal distinguishes not loaded from a loaded empty state',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        expect(cubit.state.goalStateLoaded, isFalse);
        mockBridge.emitMessage(
          const GoalStateMessage(sessionId: 's1', goal: null),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.goalStateLoaded, isTrue);
        expect(cubit.state.goal, isNull);
        expect(cubit.state.goalSupport, CodexGoalSupport.supported);
      },
    );

    test(
      'user Goal refresh failures are visible without background spam',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        cubit.requestGoal(userInitiated: true);
        mockBridge.emitMessage(
          const ErrorMessage(
            message: 'Temporary Goal lookup failure',
            errorCode: 'goal_get_failed',
            sessionId: 's1',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.goalMutationError, 'Temporary Goal lookup failure');

        cubit.clearGoalMutationError();
        cubit.requestGoal();
        mockBridge.emitMessage(
          const ErrorMessage(
            message: 'Background Goal lookup failure',
            errorCode: 'goal_get_failed',
            sessionId: 's1',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.goalMutationError, isNull);
      },
    );

    test(
      'stale and foreign Goal acknowledgements cannot finish a newer edit',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const original = CodexGoal(
          threadId: 'thread-1',
          objective: 'Original',
          status: CodexThreadGoalStatus.active,
          tokenBudget: null,
          tokensUsed: 20,
          timeUsedSeconds: 10,
          createdAt: 1,
          updatedAt: 10,
        );
        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 's1',
            goalOperationSequence: 6,
            goal: original,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.editGoal('Updated'), isTrue);
        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        final changeId = payload['goalChangeId'] as String;
        expect(payload['expectedGoalOperationSequence'], 6);

        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 's1',
            goalOperationSequence: 7,
            goal: CodexGoal(
              threadId: 'thread-1',
              objective: 'Updated',
              status: CodexThreadGoalStatus.active,
              tokenBudget: null,
              tokensUsed: 20,
              timeUsedSeconds: 10,
              createdAt: 1,
              updatedAt: 11,
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.goalMutation?.id, changeId);

        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 's1',
            goalOperationSequence: 8,
            goal: CodexGoal(
              threadId: 'thread-1',
              objective: 'Desktop edit',
              status: CodexThreadGoalStatus.active,
              tokenBudget: null,
              tokensUsed: 20,
              timeUsedSeconds: 10,
              createdAt: 1,
              updatedAt: 11,
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.goalMutation?.id, changeId);
        expect(cubit.state.goal?.objective, 'Desktop edit');

        mockBridge.emitMessage(
          GoalStateMessage(
            sessionId: 's1',
            goalChangeId: changeId,
            goalOperationSequence: 7,
            goal: const CodexGoal(
              threadId: 'thread-1',
              objective: 'Updated',
              status: CodexThreadGoalStatus.active,
              tokenBudget: null,
              tokensUsed: 20,
              timeUsedSeconds: 10,
              createdAt: 1,
              updatedAt: 9,
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.goalMutation, isNull);
        expect(cubit.state.goal?.objective, 'Desktop edit');
      },
    );

    test(
      'sequence-less clear acknowledgement cannot erase a newer desktop Goal',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const original = CodexGoal(
          threadId: 'thread-1',
          objective: 'Original',
          status: CodexThreadGoalStatus.active,
          tokenBudget: null,
          tokensUsed: 0,
          timeUsedSeconds: 0,
          createdAt: 1,
          updatedAt: 10,
        );
        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 's1',
            goalOperationSequence: 10,
            goal: original,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.clearGoal(), isTrue);
        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        final changeId = payload['goalChangeId'] as String;
        expect(payload['expectedGoalOperationSequence'], 10);

        const desktopGoal = CodexGoal(
          threadId: 'thread-1',
          objective: 'Created on desktop',
          status: CodexThreadGoalStatus.active,
          tokenBudget: null,
          tokensUsed: 0,
          timeUsedSeconds: 0,
          createdAt: 2,
          updatedAt: 11,
        );
        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 's1',
            goalOperationSequence: 11,
            goal: desktopGoal,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.goal, desktopGoal);
        expect(cubit.state.goalMutation?.id, changeId);

        mockBridge.emitMessage(
          GoalStateMessage(sessionId: 's1', goalChangeId: changeId, goal: null),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.goalMutation, isNull);
        expect(cubit.state.goal, desktopGoal);
        expect(cubit.state.goalOperationSequence, 11);
      },
    );

    test(
      'in-flight Goal refresh cannot acknowledge a same-value edit',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const goal = CodexGoal(
          threadId: 'thread-1',
          objective: 'Same objective',
          status: CodexThreadGoalStatus.active,
          tokenBudget: null,
          tokensUsed: 1,
          timeUsedSeconds: 1,
          createdAt: 1,
          updatedAt: 5,
        );
        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 's1',
            goalOperationSequence: 5,
            goal: goal,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.requestGoal();
        expect(cubit.editGoal('Same objective'), isTrue);
        final setPayload =
            jsonDecode(mockBridge.sentMessages.last.toJson())
                as Map<String, dynamic>;
        final changeId = setPayload['goalChangeId'] as String;

        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 's1',
            goalOperationSequence: 5,
            goal: goal,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.goalMutation?.id, changeId);

        mockBridge.emitMessage(
          ErrorMessage(
            message: 'Goal update failed',
            errorCode: 'goal_set_failed',
            sessionId: 's1',
            goalChangeId: changeId,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.goalMutation, isNull);
        expect(cubit.state.goalMutationError, 'Goal update failed');
      },
    );

    test(
      'budget-limited Goal resumes with budget removal in one RPC',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 's1',
            goal: CodexGoal(
              threadId: 'thread-1',
              objective: 'Finish migration',
              status: CodexThreadGoalStatus.budgetLimited,
              tokenBudget: 100,
              tokensUsed: 100,
              timeUsedSeconds: 60,
              createdAt: 1,
              updatedAt: 2,
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(
          cubit.resumeGoal(includeTokenBudget: true, tokenBudget: null),
          isTrue,
        );
        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(payload['status'], 'active');
        expect(payload.containsKey('tokenBudget'), isTrue);
        expect(payload['tokenBudget'], isNull);
        expect(payload['goalChangeId'], isNotEmpty);
      },
    );

    test(
      'runtime Goal capability disables mutations without hiding chat',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        mockBridge.emitSessions(const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/tmp/project',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            codexGoalControlSupported: false,
          ),
        ]);
        await Future.microtask(() {});

        expect(cubit.state.goalSupport, CodexGoalSupport.unsupported);
        expect(cubit.state.advancedGoalControlSupported, isFalse);
        expect(cubit.startGoal('Unsupported goal'), isFalse);
        expect(mockBridge.sentMessages, isEmpty);
        cubit.requestGoal();
        expect(mockBridge.sentMessages, isEmpty);
        cubit.requestGoal(userInitiated: true);
        expect(mockBridge.sentMessages.single.type, 'get_goal');
      },
    );

    test('pre-Goal Bridge rejection disables polling cleanly', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);

      cubit.requestGoal(userInitiated: true);
      expect(mockBridge.sentMessages.single.type, 'get_goal');
      mockBridge.emitMessage(
        const ErrorMessage(
          message: 'get_goal',
          errorCode: 'unsupported_message',
          sessionId: 's1',
        ),
        sessionId: 's1',
      );
      await pumpEventQueue();

      expect(cubit.state.goalSupport, CodexGoalSupport.unsupported);
      expect(cubit.state.goalStateLoaded, isTrue);
      mockBridge.sentMessages.clear();
      cubit.requestGoal();
      expect(mockBridge.sentMessages, isEmpty);
    });

    test(
      'pre-Goal Bridge mutation rejection fails immediately as unsupported',
      () async {
        for (final requestType in const ['set_goal', 'clear_goal']) {
          final sessionId = 's-$requestType';
          final cubit = createCubit(sessionId, provider: Provider.codex);
          final existingGoal = requestType == 'clear_goal'
              ? CodexGoal(
                  threadId: 'thread-$requestType',
                  objective: 'Existing',
                  status: CodexThreadGoalStatus.active,
                  tokenBudget: null,
                  tokensUsed: 0,
                  timeUsedSeconds: 0,
                  createdAt: 1,
                  updatedAt: 1,
                )
              : null;
          mockBridge.emitMessage(
            GoalStateMessage(sessionId: sessionId, goal: existingGoal),
            sessionId: sessionId,
          );
          await Future.microtask(() {});
          expect(
            requestType == 'set_goal'
                ? cubit.startGoal('New Goal')
                : cubit.clearGoal(),
            isTrue,
          );
          expect(cubit.state.goalMutation, isNotNull);

          mockBridge.emitMessage(
            ErrorMessage(
              message: requestType,
              errorCode: 'unsupported_message',
              sessionId: sessionId,
            ),
            sessionId: sessionId,
          );
          await Future.microtask(() {});

          expect(cubit.state.goalMutation, isNull);
          expect(cubit.state.goalSupport, CodexGoalSupport.unsupported);
          expect(
            cubit.state.goalMutationErrorKind,
            CodexGoalErrorKind.unsupported,
          );
          await cubit.close();
          mockBridge.sentMessages.clear();
        }
      },
    );

    test(
      'legacy Goal state enables core controls but not advanced budgets',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        mockBridge.emitMessage(
          const GoalStateMessage(sessionId: 's1', goal: null),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.goalSupport, CodexGoalSupport.supported);
        expect(cubit.supportsAdvancedGoalControl, isFalse);

        mockBridge.emitSessions(const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/tmp/project',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            codexGoalControlSupported: true,
          ),
        ]);
        await Future.microtask(() {});
        expect(cubit.supportsAdvancedGoalControl, isTrue);
        expect(cubit.state.advancedGoalControlSupported, isTrue);
      },
    );

    test(
      'Goal conflict refreshes authority and preserves a localized code',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 's1',
            goalOperationSequence: 4,
            goal: CodexGoal(
              threadId: 'thread-1',
              objective: 'Original',
              status: CodexThreadGoalStatus.active,
              tokenBudget: null,
              tokensUsed: 0,
              timeUsedSeconds: 0,
              createdAt: 1,
              updatedAt: 1,
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.editGoal('Phone edit'), isTrue);
        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;

        mockBridge.emitMessage(
          ErrorMessage(
            message: 'Goal changed since this operation started',
            errorCode: 'goal_conflict',
            sessionId: 's1',
            goalChangeId: payload['goalChangeId'] as String,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.goalMutation, isNull);
        expect(cubit.state.goalMutationErrorKind, CodexGoalErrorKind.conflict);
        expect(mockBridge.sentMessages.last.type, 'get_goal');
      },
    );

    test('Goal errors only fail the matching mobile mutation', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      mockBridge.emitMessage(
        const GoalStateMessage(
          sessionId: 's1',
          goal: CodexGoal(
            threadId: 'thread-1',
            objective: 'Original',
            status: CodexThreadGoalStatus.active,
            tokenBudget: null,
            tokensUsed: 0,
            timeUsedSeconds: 0,
            createdAt: 1,
            updatedAt: 1,
          ),
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      expect(cubit.editGoal('Edited'), isTrue);
      final pendingId = cubit.state.goalMutation!.id;

      mockBridge.emitMessage(
        const ErrorMessage(
          message: 'Another client was blocked',
          errorCode: 'permission_restart_in_progress',
          sessionId: 's1',
          goalChangeId: 'foreign-change',
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      expect(cubit.state.goalMutation?.id, pendingId);

      mockBridge.emitMessage(
        ErrorMessage(
          message: 'Permission restart is in progress',
          errorCode: 'permission_restart_in_progress',
          sessionId: 's1',
          goalChangeId: pendingId,
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      expect(cubit.state.goalMutation, isNull);
      expect(cubit.state.goalMutationError, contains('Permission restart'));
    });

    test(
      'disconnect fails pending Goal changes and invalidates empty state',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 's1',
            goal: CodexGoal(
              threadId: 'thread-1',
              objective: 'Original',
              status: CodexThreadGoalStatus.active,
              tokenBudget: null,
              tokensUsed: 0,
              timeUsedSeconds: 0,
              createdAt: 1,
              updatedAt: 1,
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.editGoal('Edited'), isTrue);

        mockBridge.emitConnection(BridgeConnectionState.disconnected);
        await Future.microtask(() {});
        expect(cubit.state.goalMutation, isNull);
        expect(cubit.state.goalStateLoaded, isFalse);
        expect(cubit.state.goalSupport, CodexGoalSupport.unknown);
        expect(cubit.state.goalMutationError, contains('disconnected'));
        expect(
          cubit.state.goalMutationErrorKind,
          CodexGoalErrorKind.disconnected,
        );
      },
    );
  });
}
