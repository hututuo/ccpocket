import 'dart:async';

import 'package:ccpocket/features/session_list/state/session_list_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/widgets/session_name_title.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart' as provider;
import 'package:shared_preferences/shared_preferences.dart';

class _NameBridge extends BridgeService {
  final _recentResponses = StreamController<RecentSessionsMessage>.broadcast();
  final _projectHistory = StreamController<List<String>>.broadcast();
  final _sessionList = StreamController<List<SessionInfo>>.broadcast();

  final currentSessions = <SessionInfo>[
    SessionInfo(
      id: 'runtime-1',
      provider: Provider.codex.value,
      projectPath: '/private/worktrees/feature-a',
      claudeSessionId: 'thread-1',
      name: 'Runtime title',
      status: 'idle',
      createdAt: '2026-08-09T00:00:00Z',
      lastActivityAt: '2026-08-09T00:00:00Z',
    ),
  ];

  @override
  Stream<RecentSessionsMessage> get recentSessionResponses =>
      _recentResponses.stream;

  @override
  Stream<List<String>> get projectHistoryStream => _projectHistory.stream;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessionList.stream;

  @override
  List<SessionInfo> get sessions => currentSessions;

  void emitCatalogName(String? name) {
    _recentResponses.add(
      RecentSessionsMessage(
        requestScope: 'catalog',
        sessions: [
          RecentSession(
            sessionId: 'thread-1',
            provider: Provider.codex.value,
            name: name,
            firstPrompt: 'Prompt',
            created: '2026-08-09T00:00:00Z',
            modified: '2026-08-09T00:01:00Z',
            gitBranch: 'main',
            projectPath: '/private/worktrees/feature-a',
            isSidechain: false,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_recentResponses.close());
    unawaited(_projectHistory.close());
    unawaited(_sessionList.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mounted title follows the provider catalog rename', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final bridge = _NameBridge();
    final cubit = SessionListCubit(bridge: bridge);
    addTearDown(() async {
      await cubit.close();
      bridge.dispose();
    });

    await tester.pumpWidget(
      provider.Provider<BridgeService>.value(
        value: bridge,
        child: BlocProvider<SessionListCubit>.value(
          value: cubit,
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(
                title: const SessionNameTitle(
                  sessionId: 'runtime-1',
                  projectPath: '/private/worktrees/feature-a',
                  provider: 'codex',
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Runtime title'), findsOneWidget);

    bridge.emitCatalogName('Desktop renamed');
    await tester.pumpAndSettle();

    expect(find.text('Desktop renamed'), findsOneWidget);
    expect(find.text('Runtime title'), findsNothing);

    bridge.emitCatalogName(null);
    await tester.pumpAndSettle();

    expect(find.text('feature-a'), findsOneWidget);
    expect(find.text('Desktop renamed'), findsNothing);
    expect(find.text('Runtime title'), findsNothing);
  });

  testWidgets('keeps the runtime title when no Home catalog is mounted', (
    tester,
  ) async {
    final bridge = _NameBridge();
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      provider.Provider<BridgeService>.value(
        value: bridge,
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: const SessionNameTitle(
                sessionId: 'runtime-1',
                projectPath: '/private/worktrees/feature-a',
                provider: 'codex',
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Runtime title'), findsOneWidget);
  });
}
