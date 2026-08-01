import 'dart:async';

import 'package:ccpocket/features/session_list/state/session_list_cubit.dart';
import 'package:ccpocket/features/session_list/state/session_list_state.dart';
import 'package:ccpocket/features/session_list/widgets/home_content.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/models/offline_pending_action.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:ccpocket/services/in_app_review_service.dart';
import 'package:ccpocket/services/revenuecat_service.dart';
import 'package:ccpocket/services/support_banner_service.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/session_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skeletonizer/src/widgets/skeletonizer.dart';

typedef _RunningSessionTap =
    void Function(
      String sessionId, {
      String? projectPath,
      String? gitBranch,
      String? worktreePath,
      String? provider,
      String? durableProviderSessionId,
      String? permissionMode,
      String? sandboxMode,
      String? approvalPolicy,
      String? approvalsReviewer,
    });

/// Minimal mock for BridgeService that satisfies SessionListCubit.
class _MockBridgeService extends BridgeService {
  final _recentSessionsController =
      StreamController<List<RecentSession>>.broadcast();
  final _projectHistoryController = StreamController<List<String>>.broadcast();

  @override
  Stream<List<RecentSession>> get recentSessionsStream =>
      _recentSessionsController.stream;

  @override
  Stream<List<String>> get projectHistoryStream =>
      _projectHistoryController.stream;

  @override
  bool get recentSessionsHasMore => false;

  @override
  String? get currentProjectFilter => null;

  @override
  void switchProjectFilter(String? projectPath, {int pageSize = 20}) {}

  @override
  void requestSessionList() {}

  @override
  void requestRecentSessions({int? limit, int? offset, String? projectPath}) {}

  @override
  void requestProjectHistory() {}

  @override
  void send(ClientMessage message) {}

  @override
  void dispose() {
    _recentSessionsController.close();
    _projectHistoryController.close();
  }
}

RecentSession _session({
  required String id,
  String projectPath = '/home/user/project-a',
  String modified = '2025-01-01T00:00:00Z',
}) {
  return RecentSession(
    sessionId: id,
    firstPrompt: 'test prompt for $id',
    created: '2025-01-01T00:00:00Z',
    modified: modified,
    gitBranch: 'main',
    projectPath: projectPath,
    isSidechain: false,
  );
}

SessionInfo _runningSession({
  required String id,
  String? providerSessionId,
  String projectPath = '/home/user/project-a',
  String status = 'running',
  String lastActivityAt = '2025-01-01T12:00:00Z',
}) {
  return SessionInfo.fromJson({
    'id': id,
    'projectPath': projectPath,
    'status': status,
    'createdAt': '2025-01-01T12:00:00Z',
    'lastActivityAt': lastActivityAt,
    'gitBranch': 'main',
    'lastMessage': 'Working on something',
    'messageCount': 1,
    'claudeSessionId': ?providerSessionId,
  });
}

ConversationSyncV2Status _conversationStatus(
  String providerSessionId, {
  String activity = 'idle',
  String attention = 'none',
  String result = 'none',
}) => ConversationSyncV2Status(
  provider: 'claude',
  providerSessionId: providerSessionId,
  activity: activity,
  attention: attention,
  result: result,
  runtimeAttachment: 'notLoaded',
  source: 'appServer',
  confidence: 'authoritative',
  observedAt: '2026-07-31T00:00:00Z',
);

Widget _buildHomeContent({
  List<SessionInfo> sessions = const [],
  List<OfflinePendingAction> offlinePendingActions = const [],
  List<RecentSession> recentSessions = const [],
  Set<String> exhaustedProjectPaths = const {},
  Map<String, int> projectSessionDisplayLimits = const {},
  Set<String> unseenSessionIds = const {},
  Map<String, ConversationSyncV2Status> conversationStatuses = const {},
  Set<String> unreadConversationKeys = const {},
  String? currentProjectFilter,
  bool hasMoreSessions = false,
  bool isInitialLoading = false,
  bool showMacOSNativeAppBanner = false,
  VoidCallback? onDismissMacOSNativeAppBanner,
  ValueChanged<String>? onCancelOfflinePendingAction,
  _RunningSessionTap? onTapRunning,
  required SessionListCubit cubit,
  required DraftService draftService,
  required RevenueCatService revenueCatService,
  required SupportBannerService supportBannerService,
}) {
  return MultiRepositoryProvider(
    providers: [
      RepositoryProvider<DraftService>.value(value: draftService),
      RepositoryProvider<RevenueCatService>.value(value: revenueCatService),
      ChangeNotifierProvider<SupportBannerService>.value(
        value: supportBannerService,
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: MultiBlocProvider(
          providers: [BlocProvider<SessionListCubit>.value(value: cubit)],
          child: HomeContent(
            connectionState: BridgeConnectionState.connected,
            sessions: sessions,
            offlinePendingActions: offlinePendingActions,
            recentSessions: recentSessions,
            accumulatedProjectPaths: const {},
            exhaustedProjectPaths: exhaustedProjectPaths,
            projectSessionDisplayLimits: projectSessionDisplayLimits,
            unseenSessionIds: unseenSessionIds,
            conversationStatuses: conversationStatuses,
            unreadConversationKeys: unreadConversationKeys,
            searchQuery: '',
            isLoadingMore: false,
            isInitialLoading: isInitialLoading,
            hasMoreSessions: hasMoreSessions,
            currentProjectFilter: currentProjectFilter,
            onNewSession: () {},
            onTapRunning:
                onTapRunning ??
                (
                  id, {
                  projectPath,
                  gitBranch,
                  worktreePath,
                  provider,
                  durableProviderSessionId,
                  permissionMode,
                  sandboxMode,
                  approvalPolicy,
                  approvalsReviewer,
                }) {},
            onStopSession: (_) {},
            onCancelOfflinePendingAction: onCancelOfflinePendingAction,
            onResumeSession: (_) {},
            onLongPressRecentSession: (_, _) {},
            onArchiveSession: (_) {},
            onLongPressRunningSession: (_, _) {},
            onSelectProject: (_) {},
            onLoadMore: () {},
            onLoadMoreProject: (_) {},
            providerFilter: ProviderFilter.all,
            namedOnly: false,
            onToggleProvider: () {},
            onToggleNamed: () {},
            showMacOSNativeAppBanner: showMacOSNativeAppBanner,
            onDismissMacOSNativeAppBanner: onDismissMacOSNativeAppBanner,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('conversationDestructiveActionBlocked', () {
    ConversationSyncV2Status status({
      required String activity,
      String confidence = 'authoritative',
      String? controlState,
    }) => ConversationSyncV2Status(
      provider: 'codex',
      providerSessionId: 'thread-1',
      activity: activity,
      attention: 'none',
      result: 'none',
      runtimeAttachment: 'notLoaded',
      source: 'appServer',
      confidence: confidence,
      observedAt: '2026-08-01T00:00:00.000Z',
      controlState: controlState,
    );

    test('blocks Desktop-active and unresolved shared states', () {
      expect(
        conversationDestructiveActionBlocked(status(activity: 'working')),
        isTrue,
      );
      expect(
        conversationDestructiveActionBlocked(status(activity: 'compacting')),
        isTrue,
      );
      expect(
        conversationDestructiveActionBlocked(status(activity: 'unknown')),
        isTrue,
      );
      expect(
        conversationDestructiveActionBlocked(
          status(activity: 'idle', confidence: 'unknown'),
        ),
        isTrue,
      );
      expect(
        conversationDestructiveActionBlocked(
          status(activity: 'idle', controlState: 'reconciling'),
        ),
        isTrue,
      );
    });

    test('keeps legacy and authoritative idle archive behavior', () {
      expect(conversationDestructiveActionBlocked(null), isFalse);
      expect(
        conversationDestructiveActionBlocked(status(activity: 'idle')),
        isFalse,
      );
    });
  });

  late _MockBridgeService mockBridge;
  late SessionListCubit cubit;
  late DraftService draftService;
  late RevenueCatService revenueCatService;
  late SupportBannerService supportBannerService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    draftService = DraftService(prefs);
    revenueCatService = RevenueCatService(
      publicApiKey: '',
      platform: TargetPlatform.macOS,
    );
    supportBannerService = SupportBannerService(
      prefs: prefs,
      reviewService: InAppReviewService(
        prefs: prefs,
        appVersionLoader: () async => '1.0.0',
      ),
    );
    mockBridge = _MockBridgeService();
    cubit = SessionListCubit(bridge: mockBridge);
  });

  tearDown(() async {
    cubit.close();
    mockBridge.dispose();
    await revenueCatService.dispose();
  });

  group('HomeContent skeleton', () {
    testWidgets(
      'merged unread conversation opens with runtime and durable identities',
      (tester) async {
        String? openedRuntimeId;
        String? openedDurableId;
        await tester.pumpWidget(
          _buildHomeContent(
            sessions: [
              _runningSession(id: 'runtime-1', providerSessionId: 'thread-1'),
            ],
            recentSessions: [_session(id: 'thread-1')],
            conversationStatuses: {
              providerSessionIdentityKey('claude', 'thread-1'):
                  _conversationStatus('thread-1', result: 'completed'),
            },
            unreadConversationKeys: {
              providerSessionIdentityKey('claude', 'thread-1'),
            },
            onTapRunning:
                (
                  sessionId, {
                  projectPath,
                  gitBranch,
                  worktreePath,
                  provider,
                  durableProviderSessionId,
                  permissionMode,
                  sandboxMode,
                  approvalPolicy,
                  approvalsReviewer,
                }) {
                  openedRuntimeId = sessionId;
                  openedDurableId = durableProviderSessionId;
                },
            cubit: cubit,
            draftService: draftService,
            revenueCatService: revenueCatService,
            supportBannerService: supportBannerService,
          ),
        );
        await tester.pump();

        await tester.tap(
          find.byKey(const ValueKey('conversation_card_claude\u0000thread-1')),
        );
        await tester.pump();

        expect(openedRuntimeId, 'runtime-1');
        expect(openedDurableId, 'thread-1');
      },
    );

    testWidgets('shows Skeletonizer when isInitialLoading is true and '
        'no sessions exist', (tester) async {
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: const [],
          isInitialLoading: true,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      // Skeletonizer internally renders as _Skeletonizer + SkeletonizerScope.
      // Use SkeletonizerScope to detect presence.
      expect(find.byType(SkeletonizerScope), findsOneWidget);
      // Section header should say "Recent Sessions"
      expect(find.text('Recent Sessions'), findsOneWidget);
    });

    testWidgets('shows empty state when isInitialLoading is false and '
        'no sessions exist', (tester) async {
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: const [],
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      // Skeletonizer should NOT be present
      expect(find.byType(SkeletonizerScope), findsNothing);
      // Empty state should show the "New Session" button
      expect(find.text('New Session'), findsOneWidget);
    });

    testWidgets('shows real session cards (not skeleton) when sessions exist '
        'and isInitialLoading is false', (tester) async {
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: [
            _session(id: 's1'),
            _session(id: 's2'),
          ],
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      // No skeleton
      expect(find.byType(SkeletonizerScope), findsNothing);
      // Real session cards should be visible
      expect(find.text('test prompt for s1'), findsOneWidget);
      expect(find.text('test prompt for s2'), findsOneWidget);
    });

    testWidgets('shows only five sessions per project by default', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: [for (var i = 1; i <= 6; i++) _session(id: 's$i')],
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      expect(find.text('test prompt for s1'), findsOneWidget);
      expect(find.text('test prompt for s5'), findsOneWidget);
      expect(find.text('test prompt for s6'), findsNothing);
      expect(
        find.byKey(const ValueKey('project_show_more_/home/user/project-a')),
        findsOneWidget,
      );
    });

    testWidgets(
      'keeps every actionable, working, and unread session above Show more',
      (tester) async {
        await tester.pumpWidget(
          _buildHomeContent(
            sessions: [
              _runningSession(
                id: 'needs-you',
                status: 'waiting_approval',
                lastActivityAt: '2025-01-01T18:00:00Z',
              ),
              _runningSession(
                id: 'running-1',
                lastActivityAt: '2025-01-01T17:00:00Z',
              ),
              _runningSession(
                id: 'running-2',
                status: 'starting',
                lastActivityAt: '2025-01-01T16:00:00Z',
              ),
              _runningSession(
                id: 'running-3',
                status: 'compacting',
                lastActivityAt: '2025-01-01T15:00:00Z',
              ),
              _runningSession(
                id: 'running-4',
                lastActivityAt: '2025-01-01T14:00:00Z',
              ),
              _runningSession(
                id: 'unread',
                status: 'idle',
                lastActivityAt: '2025-01-01T13:00:00Z',
              ),
            ],
            recentSessions: [_session(id: 'ordinary')],
            unseenSessionIds: const {'unread'},
            exhaustedProjectPaths: const {'/home/user/project-a'},
            isInitialLoading: false,
            cubit: cubit,
            draftService: draftService,
            revenueCatService: revenueCatService,
            supportBannerService: supportBannerService,
          ),
        );
        await tester.pump();

        for (final id in const [
          'needs-you',
          'running-1',
          'running-2',
          'running-3',
          'running-4',
          'unread',
        ]) {
          expect(
            find.byKey(
              ValueKey('conversation_card_runtime\u0000claude\u0000$id'),
            ),
            findsOneWidget,
          );
        }
        expect(find.text('test prompt for ordinary'), findsNothing);
        expect(
          find.byKey(const ValueKey('project_show_more_/home/user/project-a')),
          findsOneWidget,
        );
      },
    );
    testWidgets(
      'shows expanded project sessions after display limit increases',
      (tester) async {
        await tester.pumpWidget(
          _buildHomeContent(
            recentSessions: [for (var i = 1; i <= 6; i++) _session(id: 's$i')],
            exhaustedProjectPaths: const {'/home/user/project-a'},
            projectSessionDisplayLimits: const {'/home/user/project-a': 25},
            isInitialLoading: false,
            cubit: cubit,
            draftService: draftService,
            revenueCatService: revenueCatService,
            supportBannerService: supportBannerService,
          ),
        );
        await tester.pump();

        expect(find.text('test prompt for s6'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('project_show_more_/home/user/project-a')),
          findsNothing,
        );
      },
    );

    testWidgets('recent chats mode reveals loaded sessions and persists', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: [for (var i = 1; i <= 6; i++) _session(id: 's$i')],
          exhaustedProjectPaths: const {'/home/user/project-a'},
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      expect(find.text('By project'), findsOneWidget);
      expect(find.text('test prompt for s6'), findsNothing);
      expect(
        find.byKey(const ValueKey('project_show_more_/home/user/project-a')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('recent_grouping_toggle')));
      await tester.pumpAndSettle();

      expect(
        find.text('test prompt for s6', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('project_show_more_/home/user/project-a')),
        findsNothing,
      );
      expect(find.text('Recent chats'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('session_list_group_recent_sessions'), isFalse);
    });

    testWidgets('recent chats mode mounts long session lists lazily', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: [
            for (var i = 1; i <= 80; i++) _session(id: 'lazy-$i'),
          ],
          exhaustedProjectPaths: const {'/home/user/project-a'},
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('recent_grouping_toggle')));
      await tester.pump();

      expect(find.text('test prompt for lazy-1'), findsOneWidget);
      expect(find.text('test prompt for lazy-80'), findsNothing);

      await tester.scrollUntilVisible(
        find.text('test prompt for lazy-80'),
        500,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('session_list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('test prompt for lazy-80'), findsOneWidget);
    });

    testWidgets(
      'preserves row state while Need You, Working, and unread reorder',
      (tester) async {
        final recentSessions = [
          _session(id: 's1', modified: '2026-07-31T01:00:00Z'),
          _session(id: 's2', modified: '2026-07-31T02:00:00Z'),
          _session(id: 's3', modified: '2026-07-31T03:00:00Z'),
        ];
        Finder rowFor(String id) => find.byKey(
          ValueKey('conversation_${providerSessionIdentityKey('claude', id)}'),
        );
        Finder slidableFor(String id) => find.byKey(
          ValueKey(
            'conversation_slidable_'
            '${providerSessionIdentityKey('claude', id)}',
          ),
        );
        Finder cardFor(String id) => find.byKey(
          ValueKey(
            'conversation_card_${providerSessionIdentityKey('claude', id)}',
          ),
        );
        Object cardStateFor(String id) => tester.state(
          find.descendant(
            of: cardFor(id),
            matching: find.byType(RunningSessionCard),
          ),
        );
        double rowTop(String id) => tester.getTopLeft(rowFor(id)).dy;

        await tester.pumpWidget(
          _buildHomeContent(
            recentSessions: recentSessions,
            exhaustedProjectPaths: const {'/home/user/project-a'},
            isInitialLoading: false,
            cubit: cubit,
            draftService: draftService,
            revenueCatService: revenueCatService,
            supportBannerService: supportBannerService,
          ),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('recent_grouping_toggle')));
        await tester.pumpAndSettle();

        expect(rowTop('s3'), lessThan(rowTop('s2')));
        expect(rowTop('s2'), lessThan(rowTop('s1')));
        final rowElementsBefore = {
          for (final id in const ['s1', 's2', 's3'])
            id: tester.element(rowFor(id)),
        };
        final slidableStatesBefore = {
          for (final id in const ['s1', 's2', 's3'])
            id: tester.state(slidableFor(id)),
        };
        final cardStatesBefore = {
          for (final id in const ['s1', 's2', 's3']) id: cardStateFor(id),
        };

        await tester.pumpWidget(
          _buildHomeContent(
            recentSessions: recentSessions,
            exhaustedProjectPaths: const {'/home/user/project-a'},
            conversationStatuses: {
              providerSessionIdentityKey('claude', 's1'): _conversationStatus(
                's1',
                attention: 'approval',
              ),
              providerSessionIdentityKey('claude', 's2'): _conversationStatus(
                's2',
                activity: 'working',
              ),
            },
            unreadConversationKeys: {
              providerSessionIdentityKey('claude', 's3'),
            },
            isInitialLoading: false,
            cubit: cubit,
            draftService: draftService,
            revenueCatService: revenueCatService,
            supportBannerService: supportBannerService,
          ),
        );
        await tester.pump();

        expect(rowTop('s3'), lessThan(rowTop('s1')));
        expect(rowTop('s1'), lessThan(rowTop('s2')));
        for (final id in const ['s1', 's2', 's3']) {
          expect(tester.element(rowFor(id)), same(rowElementsBefore[id]));
          expect(tester.state(slidableFor(id)), same(slidableStatesBefore[id]));
          expect(cardStateFor(id), same(cardStatesBefore[id]));
        }
      },
    );

    testWidgets('recent chats mode mixes projects and keeps project tags', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: [
            _session(id: 'project-a-session'),
            _session(
              id: 'project-b-session',
              projectPath: '/home/user/project-b',
            ),
          ],
          exhaustedProjectPaths: const {
            '/home/user/project-a',
            '/home/user/project-b',
          },
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('project_header_/home/user/project-a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('project_header_/home/user/project-b')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('recent_grouping_toggle')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('project_header_/home/user/project-a')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('project_header_/home/user/project-b')),
        findsNothing,
      );
      expect(find.text('project-a'), findsOneWidget);
      expect(find.text('project-b'), findsOneWidget);
    });

    testWidgets('recent chats mode uses global load more pagination', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: [_session(id: 's1')],
          hasMoreSessions: true,
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('recent_grouping_toggle')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('project_show_more_/home/user/project-a')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('load_more_button')), findsOneWidget);
    });

    testWidgets('hides project Show more when project is exhausted', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: [_session(id: 's1')],
          exhaustedProjectPaths: const {'/home/user/project-a'},
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('project_show_more_/home/user/project-a')),
        findsNothing,
      );
    });

    testWidgets(
      'uses global load more instead of project Show more in filter',
      (tester) async {
        await tester.pumpWidget(
          _buildHomeContent(
            recentSessions: [_session(id: 's1')],
            currentProjectFilter: '/home/user/project-a',
            hasMoreSessions: true,
            isInitialLoading: false,
            cubit: cubit,
            draftService: draftService,
            revenueCatService: revenueCatService,
            supportBannerService: supportBannerService,
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('project_show_more_/home/user/project-a')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('load_more_button')), findsOneWidget);
      },
    );

    testWidgets('keeps running rows visible above the catalog skeleton when '
        'isInitialLoading is true', (tester) async {
      await tester.pumpWidget(
        _buildHomeContent(
          sessions: [_runningSession(id: 'r1')],
          recentSessions: const [],
          isInitialLoading: true,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      expect(find.byType(RunningSessionCard), findsOneWidget);
      expect(find.byType(SkeletonizerScope), findsOneWidget);
      expect(find.text('Recent Sessions'), findsOneWidget);
    });

    testWidgets('shows running and recent rows in one conversation list when '
        'loaded', (tester) async {
      await tester.pumpWidget(
        _buildHomeContent(
          sessions: [_runningSession(id: 'r1')],
          recentSessions: [_session(id: 's1')],
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      expect(find.byType(RunningSessionCard), findsNWidgets(2));
      expect(find.byType(SkeletonizerScope), findsNothing);
      expect(find.text('test prompt for s1'), findsOneWidget);
      expect(find.text('Recent Sessions'), findsOneWidget);
    });

    testWidgets('deduplicates a running row from its durable catalog entry', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHomeContent(
          sessions: [_runningSession(id: 'r1', providerSessionId: 's1')],
          recentSessions: [
            _session(id: 's1'),
            _session(id: 's2'),
          ],
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('conversation_card_claude\u0000s1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('conversation_card_claude\u0000s2')),
        findsOneWidget,
      );
      expect(find.byType(RunningSessionCard), findsNWidgets(2));
    });

    testWidgets(
      'keeps one row element when a durable conversation gains a runtime',
      (tester) async {
        final identity = providerSessionIdentityKey('claude', 's1');
        final stableKey = ValueKey('conversation_$identity');
        final slidableKey = ValueKey('conversation_slidable_$identity');
        final cardKey = ValueKey('conversation_card_$identity');
        await tester.pumpWidget(
          _buildHomeContent(
            recentSessions: [_session(id: 's1')],
            isInitialLoading: false,
            cubit: cubit,
            draftService: draftService,
            revenueCatService: revenueCatService,
            supportBannerService: supportBannerService,
          ),
        );
        await tester.pump();
        final before = tester.element(find.byKey(stableKey));
        final slidableBefore = tester.element(find.byKey(slidableKey));
        final cardBefore = tester.element(find.byKey(cardKey));

        await tester.pumpWidget(
          _buildHomeContent(
            sessions: [
              _runningSession(id: 'runtime-1', providerSessionId: 's1'),
            ],
            recentSessions: [_session(id: 's1')],
            isInitialLoading: false,
            cubit: cubit,
            draftService: draftService,
            revenueCatService: revenueCatService,
            supportBannerService: supportBannerService,
          ),
        );
        await tester.pump();

        expect(tester.element(find.byKey(stableKey)), same(before));
        expect(tester.element(find.byKey(slidableKey)), same(slidableBefore));
        expect(tester.element(find.byKey(cardKey)), same(cardBefore));
        expect(find.byType(RunningSessionCard), findsOneWidget);
      },
    );

    testWidgets('keeps a durable pending resume in its original card', (
      tester,
    ) async {
      final identity = providerSessionIdentityKey('claude', 's1');
      final stableKey = ValueKey('conversation_$identity');
      final cardKey = ValueKey('conversation_card_$identity');
      String? cancelledActionId;

      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: [
            _session(id: 's1'),
            _session(id: 's2'),
          ],
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();
      final rowBefore = tester.element(find.byKey(stableKey));
      final cardBefore = tester.element(find.byKey(cardKey));
      final stateBefore = tester.state(
        find.descendant(
          of: find.byKey(cardKey),
          matching: find.byType(RunningSessionCard),
        ),
      );

      await tester.pumpWidget(
        _buildHomeContent(
          offlinePendingActions: [
            OfflinePendingAction(
              id: 'pending-resume-s1',
              kind: OfflinePendingActionKind.resume,
              projectPath: '/home/user/project-a',
              provider: 'claude',
              sessionId: 's1',
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          ],
          onCancelOfflinePendingAction: (id) => cancelledActionId = id,
          recentSessions: [
            _session(id: 's1'),
            _session(id: 's2'),
          ],
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      expect(tester.element(find.byKey(stableKey)), same(rowBefore));
      expect(tester.element(find.byKey(cardKey)), same(cardBefore));
      expect(
        tester.state(
          find.descendant(
            of: find.byKey(cardKey),
            matching: find.byType(RunningSessionCard),
          ),
        ),
        same(stateBefore),
      );
      expect(find.byType(OfflinePendingSessionCard), findsNothing);
      expect(find.text('test prompt for s1'), findsOneWidget);
      expect(find.text('test prompt for s2'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('session_card_pending_resume_pending-resume-s1'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('session_card_pending_resume_cancel_button')),
      );
      expect(cancelledActionId, 'pending-resume-s1');
    });

    testWidgets('keeps a placeholder for a genuinely new pending session', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHomeContent(
          offlinePendingActions: [
            OfflinePendingAction(
              id: 'pending-start',
              kind: OfflinePendingActionKind.start,
              projectPath: '/home/user/project-a',
              provider: 'claude',
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          ],
          recentSessions: [_session(id: 's1')],
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      expect(find.byType(OfflinePendingSessionCard), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pending_session_pending-start')),
        findsOneWidget,
      );
      expect(find.text('test prompt for s1'), findsOneWidget);
    });

    testWidgets('labels an in-flight resume as being sent to Bridge', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHomeContent(
          offlinePendingActions: [
            OfflinePendingAction(
              id: 'processing-resume-s1',
              kind: OfflinePendingActionKind.resume,
              state: OfflinePendingActionState.processing,
              canCancel: false,
              projectPath: '/home/user/project-a',
              provider: 'claude',
              sessionId: 's1',
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          ],
          recentSessions: [_session(id: 's1')],
          isInitialLoading: false,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      expect(find.byType(OfflinePendingSessionCard), findsNothing);
      expect(find.text('test prompt for s1'), findsOneWidget);
      expect(find.text('Sending session request...'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('session_card_pending_resume_processing-resume-s1'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session_card_pending_resume_cancel_button')),
        findsNothing,
      );
    });

    testWidgets('shows skeleton while loading even if recent sessions exist', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: [_session(id: 's1')],
          isInitialLoading: true,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      // While loading, skeleton should be preferred over stale cards.
      expect(find.byType(SkeletonizerScope), findsOneWidget);
      expect(find.text('test prompt for s1'), findsNothing);
    });

    testWidgets('shows macOS native app banner when requested', (tester) async {
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: [_session(id: 's1')],
          showMacOSNativeAppBanner: true,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('macos_native_app_banner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('macos_native_app_banner_open_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('macos_native_app_banner_dismiss_button')),
        findsOneWidget,
      );
    });

    testWidgets('calls dismiss callback from macOS native app banner', (
      tester,
    ) async {
      var dismissed = false;
      await tester.pumpWidget(
        _buildHomeContent(
          recentSessions: [_session(id: 's1')],
          showMacOSNativeAppBanner: true,
          onDismissMacOSNativeAppBanner: () => dismissed = true,
          cubit: cubit,
          draftService: draftService,
          revenueCatService: revenueCatService,
          supportBannerService: supportBannerService,
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('macos_native_app_banner_dismiss_button')),
      );

      expect(dismissed, isTrue);
    });
  });
}
