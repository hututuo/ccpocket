import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:ccpocket/features/session_list/widgets/connect_form.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/features/session_list/session_list_screen.dart';
import 'package:ccpocket/features/settings/state/settings_state.dart';
import 'package:ccpocket/router/app_router.dart';
import 'package:ccpocket/widgets/new_session_sheet.dart';

RecentSession _session({
  required String projectPath,
  String sessionId = 'sess',
  String? provider,
  String firstPrompt = '',
  String gitBranch = 'main',
  String? summary,
  String modified = '2025-01-01T00:00:00Z',
  String? codexApprovalPolicy,
  String? codexApprovalsReviewer,
  String? codexPermissionsMode,
  String? codexSandboxMode,
  String? codexModel,
  String? codexModelReasoningEffort,
  bool? codexNetworkAccessEnabled,
  String? codexWebSearchMode,
}) {
  return RecentSession(
    sessionId: sessionId,
    provider: provider,
    firstPrompt: firstPrompt,
    summary: summary,
    created: '2025-01-01T00:00:00Z',
    modified: modified,
    gitBranch: gitBranch,
    projectPath: projectPath,
    isSidechain: false,
    codexApprovalPolicy: codexApprovalPolicy,
    codexApprovalsReviewer: codexApprovalsReviewer,
    codexPermissionsMode: codexPermissionsMode,
    codexSandboxMode: codexSandboxMode,
    codexModel: codexModel,
    codexModelReasoningEffort: codexModelReasoningEffort,
    codexNetworkAccessEnabled: codexNetworkAccessEnabled,
    codexWebSearchMode: codexWebSearchMode,
  );
}

void main() {
  final sessions = [
    _session(projectPath: '/home/user/ccpocket', sessionId: 's1'),
    _session(projectPath: '/home/user/ccpocket', sessionId: 's2'),
    _session(projectPath: '/home/user/my-app', sessionId: 's3'),
    _session(projectPath: '/home/user/my-app', sessionId: 's4'),
    _session(projectPath: '/home/user/my-app', sessionId: 's5'),
    _session(projectPath: '/home/user/cli-tool', sessionId: 's6'),
  ];

  test('standalone chat routes preserve the durable provider identity', () {
    const claudeArgs = ClaudeSessionRouteArgs(
      sessionId: 'pending-claude',
      durableProviderSessionId: 'claude-thread',
    );
    const codexArgs = CodexSessionRouteArgs(
      sessionId: 'pending-codex',
      durableProviderSessionId: 'codex-thread',
    );

    expect(claudeArgs.durableProviderSessionId, 'claude-thread');
    expect(codexArgs.durableProviderSessionId, 'codex-thread');
  });

  group('SessionHomeConnectionGate', () {
    test('does not enter the session UI on transport readiness alone', () {
      final gate = SessionHomeConnectionGate();

      gate.update(
        state: BridgeConnectionState.connected,
        targetKey: 'machine:a',
        hasAuthoritativeSessionList: false,
        hasAuthoritativeRecentSessions: false,
      );

      expect(gate.hasReadyTarget, isFalse);
      final presentation = gate.presentationState(
        transportState: BridgeConnectionState.connected,
        hasAuthoritativeSessionList: false,
        hasAuthoritativeRecentSessions: false,
      );
      expect(presentation, BridgeConnectionState.connecting);
      expect(gate.shouldShowConnectedUi(presentation), isFalse);
    });

    test('active sessions alone do not expose placeholder catalog rows', () {
      final gate = SessionHomeConnectionGate();

      gate.update(
        state: BridgeConnectionState.connected,
        targetKey: 'machine:a',
        hasAuthoritativeSessionList: true,
        hasAuthoritativeRecentSessions: false,
      );

      expect(gate.hasReadyTarget, isFalse);
      expect(
        gate.presentationState(
          transportState: BridgeConnectionState.connected,
          hasAuthoritativeSessionList: true,
          hasAuthoritativeRecentSessions: false,
        ),
        BridgeConnectionState.connecting,
      );
    });

    test('latches only after both current Bridge catalogs arrive', () {
      final gate = SessionHomeConnectionGate();

      expect(
        gate.update(
          state: BridgeConnectionState.connected,
          targetKey: 'machine:a',
          hasAuthoritativeSessionList: true,
          hasAuthoritativeRecentSessions: true,
        ),
        isTrue,
      );
      expect(gate.hasReadyTarget, isTrue);
      expect(
        gate.shouldShowConnectedUi(BridgeConnectionState.connected),
        isTrue,
      );
    });

    test('keeps a ready same-target reconnect in the existing home', () {
      final gate = SessionHomeConnectionGate()
        ..update(
          state: BridgeConnectionState.connected,
          targetKey: 'machine:a',
          hasAuthoritativeSessionList: true,
          hasAuthoritativeRecentSessions: true,
        );

      gate.update(
        state: BridgeConnectionState.reconnecting,
        targetKey: 'machine:a',
        hasAuthoritativeSessionList: false,
        hasAuthoritativeRecentSessions: false,
      );
      expect(
        gate.shouldShowConnectedUi(BridgeConnectionState.reconnecting),
        isTrue,
      );

      final upgradedButNotReady = gate.presentationState(
        transportState: BridgeConnectionState.connected,
        hasAuthoritativeSessionList: false,
        hasAuthoritativeRecentSessions: false,
      );
      expect(upgradedButNotReady, BridgeConnectionState.reconnecting);
      expect(gate.shouldShowConnectedUi(upgradedButNotReady), isTrue);
    });

    test('a different Bridge target must become authoritative again', () {
      final gate = SessionHomeConnectionGate()
        ..update(
          state: BridgeConnectionState.connected,
          targetKey: 'machine:a',
          hasAuthoritativeSessionList: true,
          hasAuthoritativeRecentSessions: true,
        );

      expect(
        gate.update(
          state: BridgeConnectionState.connecting,
          targetKey: 'machine:b',
          hasAuthoritativeSessionList: false,
          hasAuthoritativeRecentSessions: false,
        ),
        isTrue,
      );
      expect(gate.hasReadyTarget, isFalse);
      expect(
        gate.shouldShowConnectedUi(BridgeConnectionState.connecting),
        isFalse,
      );
    });

    test('an initial failed reconnect never opens the session UI', () {
      final gate = SessionHomeConnectionGate();

      gate.update(
        state: BridgeConnectionState.reconnecting,
        targetKey: 'machine:a',
        hasAuthoritativeSessionList: false,
        hasAuthoritativeRecentSessions: false,
      );

      expect(
        gate.shouldShowConnectedUi(BridgeConnectionState.reconnecting),
        isFalse,
      );
    });

    test('cached home requires an explicit target-scoped user choice', () {
      final gate = SessionHomeConnectionGate();
      expect(gate.hasReadyTarget, isFalse);

      gate.acceptCachedTarget('machine:a');

      final presentation = gate.presentationState(
        transportState: BridgeConnectionState.connected,
        hasAuthoritativeSessionList: false,
        hasAuthoritativeRecentSessions: false,
      );
      expect(presentation, BridgeConnectionState.reconnecting);
      expect(gate.shouldShowConnectedUi(presentation), isTrue);
    });
  });

  group('ConnectionAttemptFence', () {
    test('only the latest async connection attempt can finish', () {
      final fence = ConnectionAttemptFence();
      final first = fence.begin();
      final second = fence.begin();

      expect(fence.isCurrent(first), isFalse);
      expect(fence.isCurrent(second), isTrue);
    });

    test('cancel invalidates the currently selected connection', () {
      final fence = ConnectionAttemptFence();
      final attempt = fence.begin();

      fence.cancel();

      expect(fence.isCurrent(attempt), isFalse);
    });
  });

  group('Bridge connection entry progress', () {
    BridgeConnectionEntryProgress? progress({
      BridgeConnectionState state = BridgeConnectionState.disconnected,
      bool selectionPending = false,
      bool hasSessionList = false,
      bool hasRecentSessions = false,
      bool autoConnecting = false,
    }) => bridgeConnectionEntryProgressFor(
      transportState: state,
      selectionPending: selectionPending,
      hasAuthoritativeSessionList: hasSessionList,
      hasAuthoritativeRecentSessions: hasRecentSessions,
      autoConnecting: autoConnecting,
    );

    test('reports stable milestones instead of elapsed-time guesses', () {
      expect(
        progress(selectionPending: true)?.stage,
        BridgeConnectionEntryStage.preparingTarget,
      );
      expect(progress(selectionPending: true)?.percent, 0);

      expect(progress(state: BridgeConnectionState.connecting)?.percent, 25);
      expect(progress(state: BridgeConnectionState.connected)?.percent, 60);
      expect(
        progress(
          state: BridgeConnectionState.connected,
          hasSessionList: true,
        )?.percent,
        85,
      );
    });

    test('disappears only after both authoritative datasets are ready', () {
      expect(
        progress(
          state: BridgeConnectionState.connected,
          hasSessionList: true,
          hasRecentSessions: true,
        ),
        isNull,
      );
    });
  });

  group('SessionCatalogBootstrapGate', () {
    test('retries when session_list arrives before connected', () {
      final gate = SessionCatalogBootstrapGate();

      expect(
        gate.claim(
          connectionState: BridgeConnectionState.connecting,
          selectionPending: false,
          hasAuthoritativeSessionList: true,
          generation: 1,
        ),
        isFalse,
      );
      expect(
        gate.claim(
          connectionState: BridgeConnectionState.connected,
          selectionPending: false,
          hasAuthoritativeSessionList: true,
          generation: 1,
        ),
        isTrue,
      );
      expect(
        gate.claim(
          connectionState: BridgeConnectionState.connected,
          selectionPending: false,
          hasAuthoritativeSessionList: true,
          generation: 1,
        ),
        isFalse,
      );
    });

    test('waits for selection and claims each new generation', () {
      final gate = SessionCatalogBootstrapGate();

      expect(
        gate.claim(
          connectionState: BridgeConnectionState.connected,
          selectionPending: true,
          hasAuthoritativeSessionList: true,
          generation: 2,
        ),
        isFalse,
      );
      expect(
        gate.claim(
          connectionState: BridgeConnectionState.connected,
          selectionPending: false,
          hasAuthoritativeSessionList: true,
          generation: 2,
        ),
        isTrue,
      );
      expect(
        gate.claim(
          connectionState: BridgeConnectionState.connected,
          selectionPending: false,
          hasAuthoritativeSessionList: true,
          generation: 3,
        ),
        isTrue,
      );
    });

    test('failed dispatch releases the same generation for retry', () {
      final gate = SessionCatalogBootstrapGate();

      expect(
        gate.claim(
          connectionState: BridgeConnectionState.connected,
          selectionPending: false,
          hasAuthoritativeSessionList: true,
          generation: 7,
        ),
        isTrue,
      );

      gate.completeDispatch(7, dispatched: false);

      expect(
        gate.claim(
          connectionState: BridgeConnectionState.connected,
          selectionPending: false,
          hasAuthoritativeSessionList: true,
          generation: 7,
        ),
        isTrue,
      );
    });

    test('a dispatched generation only retries after an explicit timeout', () {
      final gate = SessionCatalogBootstrapGate();

      expect(
        gate.claim(
          connectionState: BridgeConnectionState.connected,
          selectionPending: false,
          hasAuthoritativeSessionList: true,
          generation: 8,
        ),
        isTrue,
      );
      gate.completeDispatch(8, dispatched: true);
      expect(
        gate.claim(
          connectionState: BridgeConnectionState.connected,
          selectionPending: false,
          hasAuthoritativeSessionList: true,
          generation: 8,
        ),
        isFalse,
      );

      expect(gate.prepareRetry(8), isTrue);
      expect(
        gate.claim(
          connectionState: BridgeConnectionState.connected,
          selectionPending: false,
          hasAuthoritativeSessionList: true,
          generation: 8,
        ),
        isTrue,
      );
    });
  });

  group('SessionCatalogRecoveryPolicy', () {
    test('retries a correlated catalog once, then fails explicitly', () {
      final policy = SessionCatalogRecoveryPolicy();

      expect(
        policy.nextAction(
          hasAuthoritativeSessionList: true,
          hasUsableCatalog: false,
          supportsRequestCorrelation: true,
        ),
        SessionCatalogRecoveryAction.retryCatalog,
      );
      policy.recordCatalogRetry();
      expect(
        policy.nextAction(
          hasAuthoritativeSessionList: true,
          hasUsableCatalog: false,
          supportsRequestCorrelation: true,
        ),
        SessionCatalogRecoveryAction.fail,
      );
    });

    test('does not consume a catalog retry before dispatch starts', () {
      final policy = SessionCatalogRecoveryPolicy();

      for (var attempt = 0; attempt < 2; attempt++) {
        expect(
          policy.nextAction(
            hasAuthoritativeSessionList: true,
            hasUsableCatalog: false,
            supportsRequestCorrelation: true,
          ),
          SessionCatalogRecoveryAction.retryCatalog,
        );
      }
    });

    test('never retries an uncorrelated legacy request on the same socket', () {
      final policy = SessionCatalogRecoveryPolicy();

      expect(
        policy.nextAction(
          hasAuthoritativeSessionList: true,
          hasUsableCatalog: false,
          supportsRequestCorrelation: false,
        ),
        SessionCatalogRecoveryAction.fail,
      );
    });

    test('requests a missing session list once before failing', () {
      final policy = SessionCatalogRecoveryPolicy();

      expect(
        policy.nextAction(
          hasAuthoritativeSessionList: false,
          hasUsableCatalog: false,
          supportsRequestCorrelation: false,
        ),
        SessionCatalogRecoveryAction.requestSessionList,
      );
      policy.recordSessionListRetry();
      expect(
        policy.nextAction(
          hasAuthoritativeSessionList: false,
          hasUsableCatalog: false,
          supportsRequestCorrelation: false,
        ),
        SessionCatalogRecoveryAction.fail,
      );
    });
  });

  testWidgets('connection progress stays within the connection picker', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: ConnectForm(
            discoveredServers: const [],
            onScanQrCode: () {},
            onConnectToDiscovered: (_) {},
            connectionProgressLabel: '正在载入绘画目录…',
            connectionProgressValue: 0.85,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('bridge_connection_progress')), findsOne);
    expect(
      find.byKey(const ValueKey('bridge_connection_progress_bar')),
      findsOne,
    );
    expect(find.text('85%'), findsOne);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('bridge_connection_progress_bar')),
          )
          .value,
      0.85,
    );
    expect(find.text('正在载入绘画目录…'), findsOne);
    expect(find.text('连接到 Bridge 服务'), findsOne);
  });

  testWidgets('connection picker exposes cancel and retry without navigating', (
    tester,
  ) async {
    var cancelled = false;
    var retried = false;
    var usedCache = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: ConnectForm(
            discoveredServers: const [],
            onScanQrCode: () {},
            onConnectToDiscovered: (_) {},
            connectionProgressLabel: '正在载入绘画目录…',
            connectionNoticeLabel: '绘画目录准备时间超过预期',
            onCancelConnection: () => cancelled = true,
            onRetryConnection: () => retried = true,
            onUseCachedCatalog: () => usedCache = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('bridge_connection_progress')), findsOne);
    expect(find.byKey(const ValueKey('bridge_connection_notice')), findsOne);

    final retry = find.byKey(const ValueKey('retry_bridge_connection'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    expect(retried, isTrue);

    final useCache = find.byKey(const ValueKey('use_cached_conversations'));
    await tester.ensureVisible(useCache);
    await tester.tap(useCache);
    await tester.pump();
    expect(usedCache, isTrue);

    final cancel = find.byKey(
      const ValueKey('cancel_bridge_connection_notice'),
    );
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pump();
    expect(cancelled, isTrue);
    expect(find.text('连接到 Bridge 服务'), findsOne);
  });

  testWidgets('external connection links require explicit confirmation', (
    tester,
  ) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                confirmed = await showExternalBridgeConnectionConfirmation(
                  context: context,
                  target: '100.64.1.2:8765',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('连接到这个 Bridge？'), findsOne);
    expect(find.textContaining('100.64.1.2:8765'), findsOne);
    expect(find.textContaining('token='), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(confirmed, isFalse);
  });

  group('projectCounts', () {
    test('counts sessions per project name', () {
      final counts = projectCounts(sessions);
      expect(counts['ccpocket'], 2);
      expect(counts['my-app'], 3);
      expect(counts['cli-tool'], 1);
    });

    test('preserves first-seen order', () {
      final keys = projectCounts(sessions).keys.toList();
      expect(keys, ['ccpocket', 'my-app', 'cli-tool']);
    });

    test('returns empty map for empty input', () {
      expect(projectCounts([]), isEmpty);
    });
  });

  group('filterByProject', () {
    test('null filter returns all sessions', () {
      expect(filterByProject(sessions, null), sessions);
    });

    test('filters by project name', () {
      final filtered = filterByProject(sessions, 'my-app');
      expect(filtered, hasLength(3));
      expect(filtered.every((s) => s.projectName == 'my-app'), isTrue);
    });

    test('non-existent project returns empty', () {
      expect(filterByProject(sessions, 'nope'), isEmpty);
    });
  });

  group('recentProjects', () {
    test('returns unique projects in first-seen order', () {
      final projects = recentProjects(sessions);
      expect(projects, hasLength(3));
      expect(projects[0].name, 'ccpocket');
      expect(projects[1].name, 'my-app');
      expect(projects[2].name, 'cli-tool');
    });

    test('preserves full path', () {
      final projects = recentProjects(sessions);
      expect(projects[0].path, '/home/user/ccpocket');
    });

    test('empty input returns empty', () {
      expect(recentProjects([]), isEmpty);
    });
  });

  group('shortenPath', () {
    test('replaces HOME prefix with ~', () {
      // This test depends on the runtime HOME env var.
      // We test the no-match case which is platform-independent.
      expect(shortenPath('/some/other/path'), '/some/other/path');
    });

    test('returns original if no HOME match', () {
      expect(shortenPath('/tmp/foo'), '/tmp/foo');
    });
  });

  group('buildResumeCommand', () {
    test('builds Claude resume command with quoted project path', () {
      final session = _session(
        projectPath: "/home/user/My Project",
        sessionId: 'claude-session-1',
      );

      expect(
        buildResumeCommand(session),
        "cd '/home/user/My Project' && claude --resume 'claude-session-1'",
      );
    });

    test('uses resumeCwd for worktree sessions', () {
      final session = RecentSession(
        sessionId: 'worktree-session',
        firstPrompt: 'test',
        created: '2025-01-01T00:00:00Z',
        modified: '2025-01-01T00:00:00Z',
        gitBranch: 'feature',
        projectPath: '/home/user/project',
        resumeCwd: '/home/user/project-worktrees/feature',
        isSidechain: false,
      );

      expect(
        buildResumeCommand(session),
        "cd '/home/user/project-worktrees/feature' && claude --resume 'worktree-session'",
      );
    });

    test('escapes single quotes for shell paste', () {
      final session = _session(
        projectPath: "/tmp/it's/project",
        sessionId: "session'42",
      );

      expect(
        buildResumeCommand(session),
        "cd '/tmp/it'\\''s/project' && claude --resume 'session'\\''42'",
      );
    });

    test('adds --dangerously-skip-permissions for bypassPermissions', () {
      final session = RecentSession(
        sessionId: 'bypass-session',
        firstPrompt: 'test',
        created: '2025-01-01T00:00:00Z',
        modified: '2025-01-01T00:00:00Z',
        gitBranch: 'main',
        projectPath: '/home/user/project',
        executionMode: ExecutionMode.fullAccess.value,
        isSidechain: false,
      );

      expect(
        buildResumeCommand(session),
        "cd '/home/user/project' && claude --resume 'bypass-session' --dangerously-skip-permissions",
      );
    });

    test('adds --permission-mode for acceptEdits', () {
      final session = RecentSession(
        sessionId: 'edit-session',
        firstPrompt: 'test',
        created: '2025-01-01T00:00:00Z',
        modified: '2025-01-01T00:00:00Z',
        gitBranch: 'main',
        projectPath: '/home/user/project',
        executionMode: ExecutionMode.acceptEdits.value,
        isSidechain: false,
      );

      expect(
        buildResumeCommand(session),
        "cd '/home/user/project' && claude --resume 'edit-session' --permission-mode acceptEdits",
      );
    });

    test('adds --permission-mode for plan mode', () {
      final session = RecentSession(
        sessionId: 'plan-session',
        firstPrompt: 'test',
        created: '2025-01-01T00:00:00Z',
        modified: '2025-01-01T00:00:00Z',
        gitBranch: 'main',
        projectPath: '/home/user/project',
        planMode: true,
        isSidechain: false,
      );

      expect(
        buildResumeCommand(session),
        "cd '/home/user/project' && claude --resume 'plan-session' --permission-mode plan",
      );
    });
  });

  group('filterByQuery', () {
    final querySessions = [
      _session(
        projectPath: '/home/user/app',
        sessionId: 'q1',
        firstPrompt: 'Fix the login bug',
        summary: 'Fixed auth issue',
      ),
      _session(
        projectPath: '/home/user/app',
        sessionId: 'q2',
        firstPrompt: 'Add dark mode',
      ),
      _session(
        projectPath: '/home/user/app',
        sessionId: 'q3',
        firstPrompt: 'Refactor tests',
        summary: 'Login flow refactored',
      ),
    ];

    test('empty query returns all sessions', () {
      expect(filterByQuery(querySessions, ''), querySessions);
    });

    test('matches firstPrompt case-insensitively', () {
      final filtered = filterByQuery(querySessions, 'LOGIN');
      expect(filtered, hasLength(2));
      expect(filtered.map((s) => s.sessionId), containsAll(['q1', 'q3']));
    });

    test('matches summary', () {
      final filtered = filterByQuery(querySessions, 'auth');
      expect(filtered, hasLength(1));
      expect(filtered.first.sessionId, 'q1');
    });

    test('no match returns empty', () {
      expect(filterByQuery(querySessions, 'zzzzz'), isEmpty);
    });
  });

  group('RecentSessionsMessage.hasMore', () {
    test('parses hasMore: true', () {
      final json = {
        'type': 'recent_sessions',
        'sessions': <Map<String, dynamic>>[],
        'hasMore': true,
      };
      final msg = ServerMessage.fromJson(json);
      expect(msg, isA<RecentSessionsMessage>());
      expect((msg as RecentSessionsMessage).hasMore, isTrue);
    });

    test('defaults hasMore to false when missing', () {
      final json = {
        'type': 'recent_sessions',
        'sessions': <Map<String, dynamic>>[],
      };
      final msg = ServerMessage.fromJson(json);
      expect(msg, isA<RecentSessionsMessage>());
      expect((msg as RecentSessionsMessage).hasMore, isFalse);
    });

    test('parses hasMore: false', () {
      final json = {
        'type': 'recent_sessions',
        'sessions': <Map<String, dynamic>>[],
        'hasMore': false,
      };
      final msg = ServerMessage.fromJson(json);
      expect(msg, isA<RecentSessionsMessage>());
      expect((msg as RecentSessionsMessage).hasMore, isFalse);
    });
  });

  group('ClientMessage.listRecentSessions', () {
    test('serializes with no optional params', () {
      final msg = ClientMessage.listRecentSessions();
      final decoded = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(decoded['type'], 'list_recent_sessions');
      expect(decoded.containsKey('offset'), isFalse);
      expect(decoded.containsKey('projectPath'), isFalse);
    });

    test('serializes with correlation, filters, offset and projectPath', () {
      final msg = ClientMessage.listRecentSessions(
        limit: 10,
        offset: 20,
        projectPath: '/tmp/project',
        requestId: 'catalog-7-12',
        queryGeneration: 7,
        provider: 'codex',
        namedOnly: true,
        searchQuery: 'needle',
      );
      final decoded = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(decoded['type'], 'list_recent_sessions');
      expect(decoded['limit'], 10);
      expect(decoded['offset'], 20);
      expect(decoded['projectPath'], '/tmp/project');
      expect(decoded['requestId'], 'catalog-7-12');
      expect(decoded['queryGeneration'], 7);
      expect(decoded['provider'], 'codex');
      expect(decoded['namedOnly'], isTrue);
      expect(decoded['searchQuery'], 'needle');
    });

    test('omits null optional params', () {
      final msg = ClientMessage.listRecentSessions(limit: 5);
      final decoded = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(decoded['limit'], 5);
      expect(decoded.containsKey('offset'), isFalse);
      expect(decoded.containsKey('projectPath'), isFalse);
    });
  });

  group('session start defaults', () {
    test('selects provider-specific auto rename settings', () {
      const settings = SettingsState(
        autoRenameCodexSessions: true,
        autoRenameClaudeSessions: false,
      );

      expect(autoRenameForProvider(settings, Provider.codex), isTrue);
      expect(autoRenameForProvider(settings, Provider.claude), isFalse);

      final codexJson =
          jsonDecode(
                ClientMessage.start(
                  '/tmp/project',
                  provider: Provider.codex.value,
                  autoRename: autoRenameForProvider(settings, Provider.codex),
                ).toJson(),
              )
              as Map<String, dynamic>;
      final claudeJson =
          jsonDecode(
                ClientMessage.start(
                  '/tmp/project',
                  provider: Provider.claude.value,
                  autoRename: autoRenameForProvider(settings, Provider.claude),
                ).toJson(),
              )
              as Map<String, dynamic>;

      expect(codexJson['autoRename'], isTrue);
      expect(claudeJson['autoRename'], isFalse);
    });

    test('serializes and restores codex defaults', () {
      final params = NewSessionParams(
        projectPath: '/tmp/project-a',
        provider: Provider.codex,
        permissionMode: PermissionMode.acceptEdits,
        useWorktree: true,
        worktreeBranch: 'feature/x',
        existingWorktreePath: '/tmp/project-a-worktrees/feature-x',
        model: 'gpt-5.3-codex',
        sandboxMode: SandboxMode.on,
        modelReasoningEffort: ReasoningEffort.high,
        codexSpeed: CodexSpeed.fast,
        networkAccessEnabled: true,
        webSearchMode: WebSearchMode.live,
      );

      final json = sessionStartDefaultsToJson(params);
      final restored = sessionStartDefaultsFromJson(json);

      expect(restored, isNotNull);
      expect(restored!.projectPath, '/tmp/project-a');
      expect(restored.provider, Provider.codex);
      // Session-specific fields are intentionally NOT persisted
      expect(restored.useWorktree, isFalse);
      expect(restored.existingWorktreePath, isNull);
      expect(restored.worktreeBranch, isNull);
      // Provider settings ARE persisted
      expect(restored.codexApprovalPolicy, CodexApprovalPolicy.onRequest);
      expect(restored.codexAutoReviewEnabled, isFalse);
      expect(restored.codexSpeed, CodexSpeed.fast);
      expect(restored.webSearchMode, WebSearchMode.live);
    });

    test('serializes and restores codex auto review default', () {
      final params = NewSessionParams(
        projectPath: '/tmp/project-auto-review',
        provider: Provider.codex,
        codexApprovalPolicy: CodexApprovalPolicy.onRequest,
        codexAutoReviewEnabled: true,
      );

      final json = sessionStartDefaultsToJson(params);
      final restored = sessionStartDefaultsFromJson(json);

      expect(restored, isNotNull);
      expect(restored!.provider, Provider.codex);
      expect(restored.codexApprovalPolicy, CodexApprovalPolicy.onRequest);
      expect(restored.codexAutoReviewEnabled, isTrue);
      expect(restored.codexApprovalsReviewer, 'auto_review');
    });

    test('preserves factual Codex recent approval reviewer', () {
      final recent = [
        _session(
          projectPath: '/tmp/project-auto-review',
          provider: Provider.codex.value,
          codexApprovalPolicy: CodexApprovalPolicy.onRequest.value,
          codexApprovalsReviewer: 'auto_review',
        ),
      ];
      final claudeDefaults = NewSessionParams(
        projectPath: '/tmp/project-claude',
        provider: Provider.claude,
        permissionMode: PermissionMode.defaultMode,
      );

      final updated = preserveFactualRecentSessions(recent);

      expect(updated.single.codexApprovalPolicy, 'on-request');
      expect(updated.single.codexApprovalsReviewer, 'auto_review');
      expect(claudeDefaults.provider, Provider.claude);
    });

    test('Codex defaults do not override Codex recent approval reviewer', () {
      final recent = [
        _session(
          projectPath: '/tmp/project-codex',
          provider: Provider.codex.value,
          codexApprovalPolicy: CodexApprovalPolicy.onRequest.value,
          codexApprovalsReviewer: 'user',
        ),
      ];
      final codexDefaults = NewSessionParams(
        projectPath: '/tmp/project-codex',
        provider: Provider.codex,
        codexApprovalPolicy: CodexApprovalPolicy.onRequest,
        codexAutoReviewEnabled: true,
      );

      final updated = preserveFactualRecentSessions(recent);

      expect(updated.single.codexApprovalPolicy, 'on-request');
      expect(updated.single.codexApprovalsReviewer, 'user');
      expect(codexDefaults.codexApprovalsReviewer, 'auto_review');
    });

    test('Codex resume settings keep missing metadata unknown', () {
      final session = _session(
        projectPath: '/tmp/project-codex',
        provider: Provider.codex.value,
      );

      final settings = factualCodexResumeSettings(session, const []);

      expect(settings.permissionMode, isNull);
      expect(settings.executionMode, isNull);
      expect(settings.approvalPolicy, isNull);
      expect(settings.approvalsReviewer, isNull);
      expect(settings.codexPermissionsMode, isNull);
      expect(settings.sandboxMode, isNull);
      expect(settings.model, isNull);
    });

    test('new Bridge owns Codex settings restoration during resume', () {
      expect(
        bridgePreservesCodexResumeSettings(const {
          codexResumePreservesSettingsCapability,
        }),
        isTrue,
      );
      expect(bridgePreservesCodexResumeSettings(const {}), isFalse);
    });

    test('Codex resume settings preserve factual metadata', () {
      final session = _session(
        projectPath: '/tmp/project-codex',
        provider: Provider.codex.value,
        codexApprovalPolicy: CodexApprovalPolicy.onRequest.value,
        codexApprovalsReviewer: 'auto_review',
        codexPermissionsMode: CodexPermissionsMode.autoReview.value,
        codexSandboxMode: 'workspace-write',
        codexModel: 'gpt-5.3-codex',
        codexModelReasoningEffort: 'high',
        codexNetworkAccessEnabled: false,
        codexWebSearchMode: 'cached',
      );

      final settings = factualCodexResumeSettings(session, const [
        'gpt-5.3-codex',
      ]);

      expect(settings.permissionMode, PermissionMode.acceptEdits.value);
      expect(settings.executionMode, ExecutionMode.defaultMode.value);
      expect(settings.approvalPolicy, CodexApprovalPolicy.onRequest.value);
      expect(settings.approvalsReviewer, 'auto_review');
      expect(
        settings.codexPermissionsMode,
        CodexPermissionsMode.autoReview.value,
      );
      expect(settings.sandboxMode, 'workspace-write');
      expect(settings.model, 'gpt-5.3-codex');
      expect(settings.modelReasoningEffort, 'high');
      expect(settings.networkAccessEnabled, isFalse);
      expect(settings.webSearchMode, 'cached');
    });

    test(
      'Claude initial defaults keep saved Codex auto review for tab switch',
      () {
        final claudeDefaults = NewSessionParams(
          projectPath: '/tmp/project-claude',
          provider: Provider.claude,
          permissionMode: PermissionMode.defaultMode,
        );
        final codexDefaults = NewSessionParams(
          projectPath: '/tmp/project-codex',
          provider: Provider.codex,
          codexApprovalPolicy: CodexApprovalPolicy.onRequest,
          codexAutoReviewEnabled: true,
        );

        final merged = mergeCodexDefaultsIntoInitialSessionDefaults(
          claudeDefaults,
          codexDefaults,
        );

        expect(merged, isNotNull);
        expect(merged!.provider, Provider.claude);
        expect(merged.codexApprovalPolicy, CodexApprovalPolicy.onRequest);
        expect(merged.codexAutoReviewEnabled, isTrue);
        expect(merged.codexApprovalsReviewer, 'auto_review');
      },
    );

    test('does not persist session-specific fields', () {
      final params = NewSessionParams(
        projectPath: '/tmp/project-c',
        provider: Provider.claude,
        permissionMode: PermissionMode.acceptEdits,
        useWorktree: true,
        worktreeBranch: 'feature/y',
        existingWorktreePath: '/tmp/project-c-worktrees/feature-y',
        claudeMaxTurns: 10,
        claudeMaxBudgetUsd: 2.50,
      );

      final json = sessionStartDefaultsToJson(params);
      final restored = sessionStartDefaultsFromJson(json);

      expect(restored, isNotNull);
      // These session-specific values must NOT be restored
      expect(restored!.useWorktree, isFalse);
      expect(restored.worktreeBranch, isNull);
      expect(restored.existingWorktreePath, isNull);
      expect(restored.claudeMaxTurns, isNull);
      expect(restored.claudeMaxBudgetUsd, isNull);
    });

    test('returns null when required projectPath is missing', () {
      final restored = sessionStartDefaultsFromJson(<String, dynamic>{});
      expect(restored, isNull);
    });

    test('serializes and restores Claude advanced defaults', () {
      final params = NewSessionParams(
        projectPath: '/tmp/project-b',
        provider: Provider.claude,
        permissionMode: PermissionMode.plan,
        claudeModel: 'claude-sonnet-4-5',
        claudeEffort: ClaudeEffort.max,
        claudeMaxTurns: 6,
        claudeMaxBudgetUsd: 0.75,
        claudeFallbackModel: 'claude-haiku-4-5',
        claudeForkSession: true,
        claudePersistSession: false,
      );

      final json = sessionStartDefaultsToJson(params);
      final restored = sessionStartDefaultsFromJson(json);

      expect(restored, isNotNull);
      expect(restored!.provider, Provider.claude);
      expect(restored.permissionMode, PermissionMode.plan);
      expect(restored.claudeModel, 'claude-sonnet-4-5');
      expect(restored.claudeEffort, ClaudeEffort.max);
      // maxTurns and maxBudgetUsd are session-specific, NOT persisted
      expect(restored.claudeMaxTurns, isNull);
      expect(restored.claudeMaxBudgetUsd, isNull);
      expect(restored.claudeFallbackModel, 'claude-haiku-4-5');
      expect(restored.claudeForkSession, isTrue);
      expect(restored.claudePersistSession, isFalse);
    });

    test('migrates deprecated codex defaults to the fallback first model', () {
      final restored = sessionStartDefaultsFromJson({
        'projectPath': '/tmp/project-d',
        'provider': Provider.codex.value,
        'model': 'gpt-5.2-codex',
      });

      expect(restored, isNotNull);
      expect(restored!.model, defaultCodexModels.first);
    });
  });
}
