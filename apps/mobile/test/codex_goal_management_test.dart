import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_state.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/codex_session/state/codex_session_cubit.dart';
import 'package:ccpocket/features/codex_session/widgets/codex_goal_management.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final _messages = StreamController<ServerMessage>.broadcast();
  final _connections = StreamController<BridgeConnectionState>.broadcast();
  final _sessions = StreamController<List<SessionInfo>>.broadcast();
  final sentMessages = <ClientMessage>[];
  bool connected = true;
  List<SessionInfo> sessionSnapshot = const [];

  @override
  bool get isConnected => connected;

  @override
  Stream<ServerMessage> get messages => _messages.stream;

  @override
  Stream<ServerMessage> messagesForSession(String sessionId) =>
      _messages.stream;

  @override
  Stream<BridgeConnectionState> get connectionStatus => _connections.stream;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessions.stream;

  @override
  List<SessionInfo> get sessions => sessionSnapshot;

  void emitSessions(List<SessionInfo> sessions) {
    sessionSnapshot = sessions;
    _sessions.add(sessions);
  }

  @override
  void requestSessionHistory(String sessionId) {}

  @override
  void send(ClientMessage message) => sentMessages.add(message);

  void emitGoal(
    CodexGoal? goal, {
    required int sequence,
    String? goalChangeId,
  }) {
    _messages.add(
      GoalStateMessage(
        sessionId: 's1',
        goal: goal,
        goalChangeId: goalChangeId,
        goalOperationSequence: sequence,
      ),
    );
  }

  void emit(ServerMessage message) => _messages.add(message);

  @override
  void disconnect() {
    connected = false;
    _connections.add(BridgeConnectionState.disconnected);
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
  const original = CodexGoal(
    threadId: 'thread-1',
    objective: 'Original objective',
    status: CodexThreadGoalStatus.active,
    tokenBudget: null,
    tokensUsed: 10,
    timeUsedSeconds: 5,
    createdAt: 1,
    updatedAt: 1,
  );
  const desktopEdit = CodexGoal(
    threadId: 'thread-1',
    objective: 'Desktop objective',
    status: CodexThreadGoalStatus.active,
    tokenBudget: null,
    tokensUsed: 11,
    timeUsedSeconds: 6,
    createdAt: 1,
    updatedAt: 2,
  );

  late _Bridge bridge;
  late StreamingStateCubit streamingCubit;
  late ChatSessionCubit cubit;

  setUp(() async {
    bridge = _Bridge();
    streamingCubit = StreamingStateCubit();
    cubit = ChatSessionCubit(
      sessionId: 's1',
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streamingCubit,
    );
    bridge.emitGoal(original, sequence: 1);
    await pumpEventQueue();
    bridge.sentMessages.clear();
  });

  tearDown(() async {
    await cubit.close();
    await streamingCubit.close();
    bridge.dispose();
  });

  testWidgets('editor refuses to overwrite a Goal changed on desktop', (
    tester,
  ) async {
    late BuildContext appContext;
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                appContext = context;
                return FilledButton(
                  onPressed: () => unawaited(
                    CodexGoalManagement.showEditor(context, original),
                  ),
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byKey(const ValueKey('goal_objective_field')),
      'Phone objective',
    );
    bridge.emitGoal(desktopEdit, sequence: 2);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('goal_save_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('goal_save_button')));
    await tester.pump();

    expect(
      bridge.sentMessages.where((message) => message.type == 'set_goal'),
      isEmpty,
    );
    expect(
      find.text('这个目标已在其他客户端发生变化。草稿仍会保留；请取消并查看最新目标，然后重新打开编辑器。'),
      findsOneWidget,
    );
    expect(find.text('Phone objective'), findsOneWidget);
    expect(find.byKey(const ValueKey('goal_objective_field')), findsOneWidget);
    expect(appContext.mounted, isTrue);
  });

  testWidgets('clear confirmation cannot delete a replacement desktop Goal', (
    tester,
  ) async {
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => unawaited(
                  CodexGoalManagement.confirmClear(context, original),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    bridge.emitGoal(
      const CodexGoal(
        threadId: 'thread-1',
        objective: 'Replacement objective',
        status: CodexThreadGoalStatus.paused,
        tokenBudget: 1000,
        tokensUsed: 0,
        timeUsedSeconds: 0,
        createdAt: 3,
        updatedAt: 3,
      ),
      sequence: 2,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('goal_clear_confirm_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('goal_clear_confirm_button')));
    await tester.pump();

    expect(
      bridge.sentMessages.where((message) => message.type == 'clear_goal'),
      isEmpty,
    );
    expect(
      find.text('这个目标已在其他客户端发生变化。草稿仍会保留；请取消并查看最新目标，然后重新打开编辑器。'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('goal_clear_confirm_button')),
      findsOneWidget,
    );
  });

  testWidgets('start dialog cannot replace a Goal created on desktop', (
    tester,
  ) async {
    bridge.emitGoal(null, sequence: 2);
    await tester.pump();
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () =>
                    unawaited(CodexGoalManagement.showEditor(context, null)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byKey(const ValueKey('goal_objective_field')),
      'Phone objective',
    );
    bridge.emitGoal(desktopEdit, sequence: 3);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('goal_save_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('goal_save_button')));
    await tester.pump();

    expect(
      bridge.sentMessages.where((message) => message.type == 'set_goal'),
      isEmpty,
    );
    expect(
      find.text('这个目标已在其他客户端发生变化。草稿仍会保留；请取消并查看最新目标，然后重新打开编辑器。'),
      findsOneWidget,
    );
    expect(find.text('Phone objective'), findsOneWidget);
  });

  testWidgets('start stays visible until Bridge confirms the Goal', (
    tester,
  ) async {
    bridge.emitGoal(null, sequence: 2);
    await tester.pump();
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () =>
                    unawaited(CodexGoalManagement.showEditor(context, null)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('goal_objective_field')),
      'Phone objective',
    );
    await tester.tap(find.byKey(const ValueKey('goal_save_button')));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Phone objective'), findsOneWidget);
    final setMessage = bridge.sentMessages.lastWhere(
      (message) => message.type == 'set_goal',
    );

    bridge.emitGoal(
      const CodexGoal(
        threadId: 'thread-1',
        objective: 'Phone objective',
        status: CodexThreadGoalStatus.active,
        tokenBudget: null,
        tokensUsed: 0,
        timeUsedSeconds: 0,
        createdAt: 3,
        updatedAt: 3,
      ),
      sequence: 3,
      goalChangeId: setMessage.goalChangeId,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('goal_objective_field')), findsNothing);
  });

  testWidgets('server conflict preserves the editor draft', (tester) async {
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => unawaited(
                  CodexGoalManagement.showEditor(context, original),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('goal_objective_field')),
      'Unsent phone draft',
    );
    await tester.tap(find.byKey(const ValueKey('goal_save_button')));
    await tester.pump();
    final setMessage = bridge.sentMessages.lastWhere(
      (message) => message.type == 'set_goal',
    );
    bridge.emit(
      ErrorMessage(
        message: 'conflict',
        errorCode: 'goal_conflict',
        sessionId: 's1',
        goalChangeId: setMessage.goalChangeId,
      ),
    );
    await tester.pumpAndSettle();

    expect(cubit.state.goalMutationErrorKind, CodexGoalErrorKind.conflict);
    expect(find.text('Unsent phone draft'), findsOneWidget);
    expect(
      find.text('这个目标已在其他客户端发生变化。草稿仍会保留；请取消并查看最新目标，然后重新打开编辑器。'),
      findsOneWidget,
    );
  });

  testWidgets('disconnect before save keeps the editor and draft', (
    tester,
  ) async {
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => unawaited(
                  CodexGoalManagement.showEditor(context, original),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('goal_objective_field')),
      'Offline phone draft',
    );
    bridge.disconnect();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('goal_save_button')));
    await tester.pump();

    expect(find.text('Offline phone draft'), findsOneWidget);
    expect(find.text('重新连接并刷新后才能管理这个目标。'), findsOneWidget);
    expect(
      bridge.sentMessages.where((message) => message.type == 'set_goal'),
      isEmpty,
    );
  });

  testWidgets('runtime usage growth does not conflict with a writable edit', (
    tester,
  ) async {
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => unawaited(
                  CodexGoalManagement.showEditor(context, original),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('goal_objective_field')),
      'Edited after progress',
    );
    bridge.emitGoal(
      const CodexGoal(
        threadId: 'thread-1',
        objective: 'Original objective',
        status: CodexThreadGoalStatus.active,
        tokenBudget: null,
        tokensUsed: 99,
        timeUsedSeconds: 60,
        createdAt: 1,
        updatedAt: 2,
      ),
      sequence: 2,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('goal_save_button')));
    await tester.pump();

    final setMessage = bridge.sentMessages.lastWhere(
      (message) => message.type == 'set_goal',
    );
    expect(setMessage.goalChangeId, isNotEmpty);
    bridge.emitGoal(
      const CodexGoal(
        threadId: 'thread-1',
        objective: 'Edited after progress',
        status: CodexThreadGoalStatus.active,
        tokenBudget: null,
        tokensUsed: 99,
        timeUsedSeconds: 60,
        createdAt: 1,
        updatedAt: 3,
      ),
      sequence: 3,
      goalChangeId: setMessage.goalChangeId,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goal_objective_field')), findsNothing);
  });

  testWidgets('Goal load failure shows a localized retry state', (
    tester,
  ) async {
    bridge.emitGoal(null, sequence: 2);
    await tester.pump();
    await tester.pump();
    cubit.requestGoal(userInitiated: true);
    bridge.emit(
      const ErrorMessage(
        message: 'lookup failed',
        errorCode: 'goal_get_failed',
        sessionId: 's1',
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(cubit.state.goalLoadErrorKind, CodexGoalErrorKind.readFailed);

    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () =>
                    unawaited(CodexGoalManagement.showManager(context)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('目标加载失败'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('goal_load_retry_button')),
      findsOneWidget,
    );
  });

  test('native Codex commands emit UI intents without chat turns', () async {
    final uiCubit = CodexSessionCubit(
      sessionId: 's-ui',
      bridge: bridge,
      streamingCubit: streamingCubit,
    );
    final intents = <CodexGoalUiIntent>[];
    final subscription = uiCubit.goalUiIntents.listen(intents.add);
    try {
      uiCubit.sendMessage('/goal');
      uiCubit.sendMessage('/goal edit');
      uiCubit.sendMessage('/permissions');
      uiCubit.sendMessage('/plan');
      uiCubit.sendMessage('/skills');
      uiCubit.sendMessage('/compact');
      uiCubit.sendMessage('/review');
      uiCubit.sendMessage('/mcp');
      uiCubit.sendMessage('/model');
      uiCubit.sendMessage('/context');
      await pumpEventQueue();

      expect(intents, const [
        CodexSessionUiIntent.manage,
        CodexSessionUiIntent.edit,
        CodexSessionUiIntent.permissions,
        CodexSessionUiIntent.plan,
        CodexSessionUiIntent.skills,
        CodexSessionUiIntent.compact,
        CodexSessionUiIntent.review,
        CodexSessionUiIntent.mcp,
        CodexSessionUiIntent.model,
        CodexSessionUiIntent.context,
      ]);
      expect(uiCubit.state.entries, isEmpty);
      expect(bridge.sentMessages.map((message) => message.type), ['get_goal']);
    } finally {
      await subscription.cancel();
      await uiCubit.close();
    }
  });

  test(
    'unsupported native Codex /plan emits guidance intent without a chat turn',
    () async {
      bridge.emitSessions([
        const SessionInfo(
          id: 's-ui',
          provider: 'codex',
          projectPath: '/project',
          status: 'idle',
          createdAt: '',
          lastActivityAt: '',
          codexNativePlanModeSupported: false,
        ),
      ]);
      final uiCubit = CodexSessionCubit(
        sessionId: 's-ui',
        bridge: bridge,
        streamingCubit: streamingCubit,
      );
      final intents = <CodexSessionUiIntent>[];
      final subscription = uiCubit.uiIntents.listen(intents.add);
      try {
        uiCubit.sendMessage('/plan');
        await pumpEventQueue();

        expect(intents, [CodexSessionUiIntent.planUnavailable]);
        expect(uiCubit.state.planMode, isFalse);
        expect(uiCubit.state.entries, isEmpty);
        expect(
          bridge.sentMessages.where(
            (message) => message.type == 'set_permission_mode',
          ),
          isEmpty,
        );
      } finally {
        await subscription.cancel();
        await uiCubit.close();
      }
    },
  );
}
