import 'dart:async';

import 'package:ccpocket/features/conversation_mirror/conversation_mirror_badge.dart';
import 'package:ccpocket/features/conversation_mirror/conversation_mirror_resident_section.dart';
import 'package:ccpocket/features/conversation_mirror/conversation_mirror_service.dart';
import 'package:ccpocket/features/conversation_mirror/conversation_mirror_session_actions.dart';
import 'package:ccpocket/features/conversation_mirror/conversation_mirror_ui_slot.dart';
import 'package:ccpocket/features/conversation_mirror/storage/conversation_mirror_storage.dart';
import 'package:ccpocket/features/local_session_features/host/local_session_feature.dart';
import 'package:ccpocket/features/local_session_features/host/local_session_feature_host.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/adaptive_context_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

class _FakeConversationMirrorService extends ConversationMirrorService {
  _FakeConversationMirrorService({
    required this.unsupported,
    required this.localCopy,
    this.downloadResult,
    this.resident = false,
    this.metadata = const [],
  }) : super(
         bridge: BridgeService(),
         store: ConversationMirrorStore(ConversationMirrorDatabase()),
         database: ConversationMirrorDatabase(),
       );

  final bool unsupported;
  final bool localCopy;
  final ConversationMirrorSyncResult? downloadResult;
  final bool resident;
  final List<ConversationMirrorMetadata> metadata;

  @override
  bool get isAvailable => true;

  @override
  bool get featureUnsupported => unsupported;

  @override
  bool hasLocalCopy(RecentSession session) => localCopy;

  @override
  bool isResident(RecentSession session) => resident;

  @override
  List<ConversationMirrorMetadata> get residentMetadata => metadata;

  @override
  String? get currentBridgeInstanceId => 'bridge-test';

  @override
  bool isSyncing(RecentSession session) => false;

  @override
  Future<ConversationMirrorSyncResult> downloadAndWatch(
    RecentSession session,
  ) async =>
      downloadResult ??
      const ConversationMirrorSyncResult(success: true, changed: false);
}

class _UiBridge extends BridgeService {
  _UiBridge(this.currentSessions);

  final List<SessionInfo> currentSessions;
  final _sessionLists = StreamController<List<SessionInfo>>.broadcast();

  @override
  List<SessionInfo> get sessions => currentSessions;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessionLists.stream;

  @override
  String? providerSessionIdForRuntime(
    String runtimeSessionId, {
    String? provider,
  }) => null;

  @override
  void dispose() {
    _sessionLists.close();
    super.dispose();
  }
}

const _session = RecentSession(
  sessionId: 'thread-1',
  provider: 'codex',
  firstPrompt: 'hello',
  created: '2026-07-18T00:00:00Z',
  modified: '2026-07-18T00:00:00Z',
  gitBranch: 'main',
  projectPath: '/tmp/project',
  isSidechain: false,
);

Widget _wrap(ConversationMirrorService service, Widget child) =>
    ChangeNotifierProvider<ConversationMirrorService>.value(
      value: service,
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(body: child),
      ),
    );

const _runningSession = SessionInfo(
  id: 'runtime-1',
  provider: 'codex',
  projectPath: '/tmp/project',
  claudeSessionId: 'thread-1',
  name: 'Active resident',
  status: 'running',
  createdAt: '2026-07-20T00:00:00Z',
  lastActivityAt: '2026-07-20T00:01:00Z',
  lastMessage: 'latest output',
);

void main() {
  testWidgets('old Bridge hides download when there is no local copy', (
    tester,
  ) async {
    final service = _FakeConversationMirrorService(
      unsupported: true,
      localCopy: false,
    );

    await tester.pumpWidget(
      _wrap(service, const ConversationMirrorBadge(session: _session)),
    );

    expect(
      find.byKey(const ValueKey('conversation_mirror_download_badge')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('conversation_mirror_saved_badge')),
      findsNothing,
    );
  });

  testWidgets('old Bridge keeps a removable local copy visible', (
    tester,
  ) async {
    final service = _FakeConversationMirrorService(
      unsupported: true,
      localCopy: true,
    );
    late List<AdaptiveActionMenuItem<String>> actions;

    await tester.pumpWidget(
      _wrap(
        service,
        Column(
          children: [
            const ConversationMirrorBadge(session: _session),
            Builder(
              builder: (context) {
                actions = conversationMirrorActionItems(context, _session);
                return const SizedBox.shrink();
              },
            ),
          ],
        ),
      ),
    );

    final savedButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('conversation_mirror_saved_badge')),
    );
    expect(savedButton.onPressed, isNull);
    expect(actions.map((action) => action.value), [
      conversationMirrorRemoveAction,
    ]);
  });

  testWidgets('pre-feature Bridge timeout uses the friendly fallback message', (
    tester,
  ) async {
    final service = _FakeConversationMirrorService(
      unsupported: false,
      localCopy: false,
      downloadResult: const ConversationMirrorSyncResult(
        success: false,
        changed: false,
        errorCode: 'capability_not_negotiated',
        error: 'technical handshake detail',
      ),
    );

    await tester.pumpWidget(
      _wrap(
        service,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => handleConversationMirrorAction(
              context,
              _session,
              conversationMirrorDownloadAction,
            ),
            child: const Text('download'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('download'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This Bridge does not support conversation mirrors; existing loading remains active',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('technical handshake detail'), findsNothing);
  });

  testWidgets('running card actions can make an active Codex chat resident', (
    tester,
  ) async {
    final service = _FakeConversationMirrorService(
      unsupported: false,
      localCopy: false,
    );
    late List<AdaptiveActionMenuItem<String>> actions;

    await tester.pumpWidget(
      _wrap(
        service,
        Builder(
          builder: (context) {
            actions = conversationMirrorRunningActionItems(
              context,
              _runningSession,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(actions.map((action) => action.value), [
      conversationMirrorDownloadAction,
    ]);
  });

  testWidgets('session More keeps residency entry before durable id arrives', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final draftService = DraftService(await SharedPreferences.getInstance());
    final service = _FakeConversationMirrorService(
      unsupported: false,
      localCopy: false,
    );
    final bridge = _UiBridge([
      const SessionInfo(
        id: 'runtime-new',
        provider: 'codex',
        projectPath: '/tmp/project',
        status: 'starting',
        createdAt: '2026-07-20T00:00:00Z',
        lastActivityAt: '2026-07-20T00:00:00Z',
      ),
    ]);
    final input = TextEditingController();
    late List<SessionMenuAction> actions;
    addTearDown(input.dispose);
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _wrap(
        service,
        Builder(
          builder: (context) {
            actions = conversationMirrorUiSlot.overflowActions(
              CodexSessionFeatureContext(
                context: context,
                sessionId: 'runtime-new',
                bridge: bridge,
                inputController: input,
                draftService: draftService,
                requestCompact: () {},
                openPane: (_, {arguments = const {}}) async {},
              ),
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(actions.single.featureId, 'conversation_mirror_resident');
    expect(actions.single.label, 'Residency and full sync');
    expect(
      LocalSessionFeatureHost.paneDescriptor('conversation_mirror_resident'),
      isNotNull,
    );
  });

  testWidgets('Home resident section renders metadata and opens running chat', (
    tester,
  ) async {
    final metadata = ConversationMirrorMetadata(
      key: const ConversationMirrorKey(
        bridgeInstanceId: 'bridge-test',
        provider: 'codex',
        providerSessionId: 'thread-1',
      ),
      activeGeneration: 'generation-1',
      revision: 'revision-1',
      entryCount: 3000,
      bytes: 1024,
      autoSync: true,
      projectPath: '/tmp/project',
      lastSyncedAt: DateTime.utc(2026, 7, 20),
      error: null,
    );
    final service = _FakeConversationMirrorService(
      unsupported: false,
      localCopy: true,
      resident: true,
      metadata: [metadata],
    );
    var openedRunning = false;
    var openedRecent = false;

    await tester.pumpWidget(
      _wrap(
        service,
        ConversationMirrorResidentSection(
          runningSessions: const [_runningSession],
          recentSessions: const [_session],
          onOpenRunning: (_) => openedRunning = true,
          onOpenRecent: (_) => openedRecent = true,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('resident_conversations_section')),
      findsOneWidget,
    );
    expect(find.text('Resident conversations · 1'), findsOneWidget);
    expect(
      find.text('Running · 3000 records stored on the phone'),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('resident_conversation_thread-1')),
    );
    expect(openedRunning, isTrue);
    expect(openedRecent, isFalse);
  });
}
