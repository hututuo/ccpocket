import 'package:ccpocket/features/session_list/session_list_projection.dart';
import 'package:ccpocket/features/session_list/state/session_list_cubit.dart';
import 'package:ccpocket/features/session_list/state/session_list_state.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/widgets/session_visual_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildUnifiedSessionList', () {
    test('merges running and recent forms by durable provider identity', () {
      final recent = _recent(id: 'thread-1', modified: '2026-07-25T01:00:00Z');
      final running = _running(
        runtimeId: 'runtime-a',
        threadId: 'thread-1',
        lastActivityAt: '2026-07-25T02:00:00Z',
      );

      final items = buildUnifiedSessionList(
        runningSessions: [running],
        recentSessions: [recent],
      );

      expect(items, hasLength(1));
      expect(items.single.running, same(running));
      expect(items.single.recent, same(recent));
      expect(items.single.activityAt, DateTime.utc(2026, 7, 25, 1));
    });

    test(
      'runtime attachment does not change durable conversation ordering',
      () {
        final recent = _recent(
          id: 'thread-1',
          modified: '2026-07-25T01:00:00Z',
        );

        final detached = buildUnifiedSessionList(
          runningSessions: const [],
          recentSessions: [recent],
        ).single;
        final attached = buildUnifiedSessionList(
          runningSessions: [
            _running(
              runtimeId: 'runtime-a',
              threadId: 'thread-1',
              lastActivityAt: '2026-07-25T09:00:00Z',
            ),
          ],
          recentSessions: [recent],
        ).single;

        expect(attached.identityKey, detached.identityKey);
        expect(attached.activityAt, detached.activityAt);
      },
    );

    test('sorts newest activity first inside each pin tier', () {
      final olderPinned = _recent(
        id: 'pinned',
        modified: '2026-07-25T01:00:00Z',
      );
      final newerPinned = _recent(
        id: 'pinned-newer',
        modified: '2026-07-25T02:00:00Z',
      );
      final newestUnpinned = _recent(
        id: 'latest',
        modified: '2026-07-25T03:00:00Z',
      );
      final pinned = {
        recentSessionPinKey(olderPinned),
        recentSessionPinKey(newerPinned),
      };

      final items = buildUnifiedSessionList(
        runningSessions: const [],
        recentSessions: [olderPinned, newestUnpinned, newerPinned],
        pinnedSessionKeys: pinned,
      );

      expect(items.map((item) => item.providerSessionId), [
        'pinned-newer',
        'pinned',
        'latest',
      ]);
    });

    test('does not preserve runtime insertion order', () {
      final items = buildUnifiedSessionList(
        runningSessions: [
          _running(
            runtimeId: 'older',
            threadId: 'older-thread',
            lastActivityAt: '2026-07-25T01:00:00Z',
          ),
          _running(
            runtimeId: 'newer',
            threadId: 'newer-thread',
            lastActivityAt: '2026-07-25T03:00:00Z',
          ),
          _running(
            runtimeId: 'middle',
            threadId: 'middle-thread',
            lastActivityAt: '2026-07-25T02:00:00Z',
          ),
        ],
        recentSessions: const [],
      );

      expect(items.map((item) => item.running!.id), [
        'newer',
        'middle',
        'older',
      ]);
    });

    test('puts unread sessions ahead of ordinary sessions', () {
      final items = buildUnifiedSessionList(
        runningSessions: [
          _running(
            runtimeId: 'newer-read',
            threadId: 'newer-read-thread',
            lastActivityAt: '2026-07-25T03:00:00Z',
            projectPath: '/project-a',
          ),
          _running(
            runtimeId: 'older-unread',
            threadId: 'older-unread-thread',
            lastActivityAt: '2026-07-25T01:00:00Z',
            projectPath: '/project-b',
          ),
          _running(
            runtimeId: 'middle-read',
            threadId: 'middle-read-thread',
            lastActivityAt: '2026-07-25T02:00:00Z',
            projectPath: '/project-c',
          ),
        ],
        recentSessions: const [],
        unseenSessionIds: const {'older-unread'},
      );

      expect(items.map((item) => item.running!.id), [
        'older-unread',
        'newer-read',
        'middle-read',
      ]);
    });

    test('grouped project order ignores unread conversation priority', () {
      final items = buildUnifiedSessionList(
        runningSessions: [
          _running(
            runtimeId: 'newer-read',
            threadId: 'newer-read-thread',
            lastActivityAt: '2026-07-25T03:00:00Z',
            projectPath: '/project-a',
          ),
          _running(
            runtimeId: 'older-unread',
            threadId: 'older-unread-thread',
            lastActivityAt: '2026-07-25T01:00:00Z',
            projectPath: '/project-b',
          ),
        ],
        recentSessions: const [],
        unseenSessionIds: const {'older-unread'},
      );

      expect(items.map((item) => item.running!.id), [
        'older-unread',
        'newer-read',
      ]);
      expect(
        orderProjectPathsForGroupedView(
          knownProjectPaths: const [],
          sessions: items,
        ),
        ['/project-a', '/project-b'],
      );
    });

    test('unread does not break equal-activity project ordering ties', () {
      List<UnifiedSessionListItem> build(Set<String> unread) =>
          buildUnifiedSessionList(
            runningSessions: [
              _running(
                runtimeId: 'runtime-a',
                threadId: 'thread-a',
                lastActivityAt: '2026-07-25T01:00:00Z',
                projectPath: '/project-a',
              ),
              _running(
                runtimeId: 'runtime-b',
                threadId: 'thread-b',
                lastActivityAt: '2026-07-25T01:00:00Z',
                projectPath: '/project-b',
              ),
            ],
            recentSessions: const [],
            unseenSessionIds: unread,
          );

      final before = build(const {});
      final after = build(const {'runtime-b'});
      expect(after.first.running!.id, 'runtime-b');
      expect(
        orderProjectPathsForGroupedView(
          knownProjectPaths: const [],
          sessions: before,
        ),
        ['/project-a', '/project-b'],
      );
      expect(
        orderProjectPathsForGroupedView(
          knownProjectPaths: const [],
          sessions: after,
          unseenSessionIds: const {'runtime-b'},
        ),
        ['/project-a', '/project-b'],
      );
    });

    test('grouped project order preserves explicit pin tiers', () {
      final pinnedSession = _recent(
        id: 'pinned-session',
        modified: '2026-07-25T01:00:00Z',
        projectPath: '/session-pinned-project',
      );
      final ordinary = _recent(
        id: 'ordinary',
        modified: '2026-07-25T03:00:00Z',
        projectPath: '/ordinary-project',
      );
      final pinnedSessionKey = recentSessionPinKey(pinnedSession);
      final items = buildUnifiedSessionList(
        runningSessions: const [],
        recentSessions: [ordinary, pinnedSession],
        pinnedSessionKeys: {pinnedSessionKey},
      );

      expect(
        orderProjectPathsForGroupedView(
          knownProjectPaths: const ['/project-pinned-project'],
          sessions: items,
          pinnedSessionKeys: {pinnedSessionKey},
          pinnedProjectPaths: const {'/project-pinned-project'},
        ),
        [
          '/session-pinned-project',
          '/project-pinned-project',
          '/ordinary-project',
        ],
      );
    });

    test('groups worktrees by Desktop project identity and synced name', () {
      final items = buildUnifiedSessionList(
        runningSessions: const [],
        recentSessions: [
          _recent(
            id: 'thread-main',
            modified: '2026-07-25T03:00:00Z',
            projectPath: '/workspace/ccpocket',
            projectGroupId: 'project-ccpocket',
            projectGroupName: 'CC Pocket Mobile',
          ),
          _recent(
            id: 'thread-worktree',
            modified: '2026-07-25T02:00:00Z',
            projectPath: '/private/worktrees/feature-a',
            projectGroupId: 'project-ccpocket',
            projectGroupName: 'CC Pocket Mobile',
          ),
          _recent(
            id: 'thread-projectless',
            modified: '2026-07-25T01:00:00Z',
            projectPath: '/private/tmp/scratch',
            projectless: true,
          ),
        ],
      );

      expect(items[0].projectGroupingKey, 'desktop-project:project-ccpocket');
      expect(items[0].projectGroupingName, 'CC Pocket Mobile');
      expect(items[1].projectGroupingKey, items[0].projectGroupingKey);
      expect(items[2].projectGroupingKey, desktopProjectlessGroupingKey);
      expect(
        orderProjectPathsForGroupedView(
          knownProjectPaths: const [],
          sessions: items,
        ),
        ['desktop-project:project-ccpocket', desktopProjectlessGroupingKey],
      );
    });

    test('keeps an explicit pin ahead of unread sessions', () {
      final pinned = _running(
        runtimeId: 'pinned-read',
        threadId: 'pinned-read-thread',
        lastActivityAt: '2026-07-25T01:00:00Z',
      );
      final unread = _running(
        runtimeId: 'unread',
        threadId: 'unread-thread',
        lastActivityAt: '2026-07-25T03:00:00Z',
      );

      final items = buildUnifiedSessionList(
        runningSessions: [unread, pinned],
        recentSessions: const [],
        pinnedSessionKeys: {runningSessionPinKey(pinned)!},
        unseenSessionIds: const {'unread'},
      );

      expect(items.map((item) => item.running!.id), ['pinned-read', 'unread']);
    });

    test('orders unread before actionable and working sessions', () {
      final pinned = _running(
        runtimeId: 'pinned-ordinary',
        threadId: 'pinned-ordinary-thread',
        lastActivityAt: '2026-07-25T00:00:00Z',
      );
      final items = buildUnifiedSessionList(
        runningSessions: [
          _running(
            runtimeId: 'ordinary',
            threadId: 'ordinary-thread',
            lastActivityAt: '2026-07-25T05:00:00Z',
          ),
          _running(
            runtimeId: 'unread',
            threadId: 'unread-thread',
            lastActivityAt: '2026-07-25T04:00:00Z',
          ),
          _running(
            runtimeId: 'working',
            threadId: 'working-thread',
            lastActivityAt: '2026-07-25T03:00:00Z',
            status: 'running',
          ),
          _running(
            runtimeId: 'desktop-working',
            threadId: 'desktop-working-thread',
            lastActivityAt: '2026-07-25T02:30:00Z',
            externalDesktopTurnActive: true,
          ),
          _running(
            runtimeId: 'needs-you',
            threadId: 'needs-you-thread',
            lastActivityAt: '2026-07-25T02:00:00Z',
            status: 'waiting_approval',
          ),
          pinned,
        ],
        recentSessions: const [],
        pinnedSessionKeys: {runningSessionPinKey(pinned)!},
        unseenSessionIds: const {'unread'},
      );

      expect(items.map((item) => item.running!.id), [
        'pinned-ordinary',
        'unread',
        'needs-you',
        'working',
        'desktop-working',
        'ordinary',
      ]);
      expect(
        sessionListUrgencyFor(items[2], unseenSessionIds: const {'unread'}),
        SessionListUrgency.needsYou,
      );
      expect(
        sessionListItemBypassesDisplayLimit(
          items[3],
          unseenSessionIds: const {'unread'},
        ),
        isTrue,
      );
      expect(
        sessionListItemBypassesDisplayLimit(
          items.last,
          unseenSessionIds: const {'unread'},
        ),
        isFalse,
      );
    });

    test('orders durable v2 status without inventing Ready for idle', () {
      final recent = [
        _recent(id: 'ordinary', modified: '2026-07-25T05:00:00Z'),
        _recent(id: 'unread', modified: '2026-07-25T04:00:00Z'),
        _recent(id: 'error', modified: '2026-07-25T03:00:00Z'),
        _recent(id: 'working', modified: '2026-07-25T02:00:00Z'),
        _recent(id: 'needs-you', modified: '2026-07-25T01:00:00Z'),
      ];
      final statuses = {
        for (final status in [
          _status('ordinary'),
          _status('unread', result: 'completed'),
          _status('error', activity: 'systemError'),
          _status('working', activity: 'working'),
          _status('needs-you', attention: 'approval'),
        ])
          status.key: status,
      };

      final items = buildUnifiedSessionList(
        runningSessions: const [],
        recentSessions: recent,
        conversationStatuses: statuses,
        unreadConversationKeys: const {'codex\u0000unread'},
      );

      expect(items.map((item) => item.providerSessionId), [
        'unread',
        'needs-you',
        'working',
        'error',
        'ordinary',
      ]);
      expect(
        sessionListUrgencyFor(items.last, unseenSessionIds: const {}),
        SessionListUrgency.ordinary,
      );
      expect(items.last.syncStatus?.activity, 'idle');
    });

    test(
      'working order advances only for discrete assistant text checkpoints',
      () {
        final statuses = {
          for (final id in ['thread-a', 'thread-b'])
            _status(id, activity: 'working').key: _status(
              id,
              activity: 'working',
            ),
        };
        final beforeAssistantUpdate = buildUnifiedSessionList(
          runningSessions: const [],
          recentSessions: [
            _recent(
              id: 'thread-a',
              modified: '2026-07-25T06:00:00Z',
              lastAssistantOutputAt: '2026-07-25T02:00:00Z',
            ),
            _recent(
              id: 'thread-b',
              modified: '2026-07-25T05:00:00Z',
              lastAssistantOutputAt: '2026-07-25T03:00:00Z',
            ),
          ],
          conversationStatuses: statuses,
        );

        expect(beforeAssistantUpdate.map((item) => item.providerSessionId), [
          'thread-b',
          'thread-a',
        ]);

        final afterAssistantUpdate = buildUnifiedSessionList(
          runningSessions: const [],
          recentSessions: [
            _recent(
              id: 'thread-a',
              modified: '2026-07-25T07:00:00Z',
              lastAssistantOutputAt: '2026-07-25T04:00:00Z',
            ),
            beforeAssistantUpdate.first.recent!,
          ],
          conversationStatuses: statuses,
        );

        expect(afterAssistantUpdate.map((item) => item.providerSessionId), [
          'thread-a',
          'thread-b',
        ]);
      },
    );

    test('grouped project order ignores tool-only working activity', () {
      final statuses = {
        for (final id in ['thread-a', 'thread-b'])
          _status(id, activity: 'working').key: _status(
            id,
            activity: 'working',
          ),
      };
      final items = buildUnifiedSessionList(
        runningSessions: const [],
        recentSessions: [
          _recent(
            id: 'thread-a',
            modified: '2026-07-25T07:00:00Z',
            lastAssistantOutputAt: '2026-07-25T02:00:00Z',
            projectPath: '/project-a',
          ),
          _recent(
            id: 'thread-b',
            modified: '2026-07-25T05:00:00Z',
            lastAssistantOutputAt: '2026-07-25T03:00:00Z',
            projectPath: '/project-b',
          ),
        ],
        conversationStatuses: statuses,
      );

      expect(
        orderProjectPathsForGroupedView(
          knownProjectPaths: const [],
          sessions: items,
        ),
        ['/project-b', '/project-a'],
      );
    });

    test(
      'uses the same v2-first presentation for urgency and visible status',
      () {
        final items = buildUnifiedSessionList(
          runningSessions: [
            _running(
              runtimeId: 'runtime-working',
              threadId: 'thread-working',
              lastActivityAt: '2026-07-25T01:00:00Z',
            ),
            _running(
              runtimeId: 'runtime-stale-attention',
              threadId: 'thread-idle',
              lastActivityAt: '2026-07-25T02:00:00Z',
              status: 'waiting_approval',
              externalDesktopTurnActive: true,
            ),
          ],
          recentSessions: [
            _recent(id: 'thread-working', modified: '2026-07-25T01:00:00Z'),
            _recent(id: 'thread-idle', modified: '2026-07-25T02:00:00Z'),
          ],
          conversationStatuses: {
            'codex\u0000thread-working': _status(
              'thread-working',
              activity: 'working',
              source: 'appServer',
            ),
            'codex\u0000thread-idle': _status(
              'thread-idle',
              source: 'bridgeRuntime',
            ),
          },
        );

        expect(items.map((item) => item.providerSessionId), [
          'thread-working',
          'thread-idle',
        ]);
        expect(
          sessionListUrgencyFor(items.first, unseenSessionIds: const {}),
          SessionListUrgency.working,
        );
        expect(
          sessionListUrgencyFor(items.last, unseenSessionIds: const {}),
          SessionListUrgency.ordinary,
        );
        expect(
          sessionCardPresentationFor(
            syncStatus: items.last.syncStatus,
            runtimeSession: items.last.running,
          ).visualStatus.primary,
          SessionPrimaryStatus.idle,
        );
      },
    );

    test('does not turn an unknown runtime status into unread', () {
      final items = buildUnifiedSessionList(
        runningSessions: [
          _running(
            runtimeId: 'unknown',
            threadId: 'unknown-thread',
            lastActivityAt: '2026-07-25T01:00:00Z',
            status: 'future_status',
          ),
        ],
        recentSessions: const [],
        unseenSessionIds: const {'unknown'},
      );

      expect(
        sessionListUrgencyFor(
          items.single,
          unseenSessionIds: const {'unknown'},
        ),
        SessionListUrgency.ordinary,
      );
      expect(
        sessionListItemBypassesDisplayLimit(
          items.single,
          unseenSessionIds: const {'unknown'},
        ),
        isFalse,
      );
    });

    test('keeps an unbound new runtime as a temporary distinct row', () {
      final items = buildUnifiedSessionList(
        runningSessions: [
          _running(
            runtimeId: 'runtime-a',
            threadId: null,
            lastActivityAt: '2026-07-25T02:00:00Z',
          ),
        ],
        recentSessions: [
          _recent(id: 'thread-1', modified: '2026-07-25T01:00:00Z'),
        ],
      );

      expect(items, hasLength(2));
      expect(items.where((item) => item.running != null), hasLength(1));
      expect(items.where((item) => item.recent != null), hasLength(1));
    });

    test('uses a deterministic durable identity tie break', () {
      final items = buildUnifiedSessionList(
        runningSessions: const [],
        recentSessions: [
          _recent(id: 'b', modified: '2026-07-25T01:00:00Z'),
          _recent(id: 'a', modified: '2026-07-25T01:00:00Z'),
        ],
      );

      expect(items.map((item) => item.providerSessionId), ['a', 'b']);
    });
  });

  group('runningSessionMatchesListFilters', () {
    final session = _running(
      runtimeId: 'runtime-a',
      threadId: 'thread-a',
      lastActivityAt: '2026-07-25T01:00:00Z',
      name: 'Performance audit',
      lastMessage: 'Finished benchmark',
    );

    test('applies provider, project, named and search filters', () {
      expect(
        runningSessionMatchesListFilters(
          session,
          providerFilter: ProviderFilter.codex,
          projectPath: '/repo',
          namedOnly: true,
          searchQuery: 'benchmark',
        ),
        isTrue,
      );
      expect(
        runningSessionMatchesListFilters(
          session,
          providerFilter: ProviderFilter.claude,
          projectPath: '/repo',
          namedOnly: true,
          searchQuery: '',
        ),
        isFalse,
      );
      expect(
        runningSessionMatchesListFilters(
          session,
          providerFilter: ProviderFilter.codex,
          projectPath: '/other',
          namedOnly: false,
          searchQuery: '',
        ),
        isFalse,
      );
    });
  });

  test(
    'recentSessionMatchesListFilters also gates offline mirror fallbacks',
    () {
      final session = _recent(
        id: 'offline',
        modified: '2026-07-25T01:00:00Z',
        projectPath: '/saved',
      );

      expect(
        recentSessionMatchesListFilters(
          session,
          providerFilter: ProviderFilter.codex,
          projectPath: '/saved',
          namedOnly: false,
          searchQuery: 'offline',
        ),
        isTrue,
      );
      expect(
        recentSessionMatchesListFilters(
          session,
          providerFilter: ProviderFilter.claude,
          projectPath: '/saved',
          namedOnly: false,
          searchQuery: '',
        ),
        isFalse,
      );
    },
  );
}

RecentSession _recent({
  required String id,
  required String modified,
  String projectPath = '/repo',
  String? lastAssistantOutputAt,
  String? projectGroupId,
  String? projectGroupName,
  bool projectless = false,
}) => RecentSession(
  sessionId: id,
  provider: Provider.codex.value,
  firstPrompt: id,
  created: '2026-07-25T00:00:00Z',
  modified: modified,
  lastAssistantOutputAt: lastAssistantOutputAt,
  gitBranch: 'main',
  projectPath: projectPath,
  projectGroupKind: projectless
      ? 'projectless'
      : projectGroupId == null
      ? null
      : 'desktopProject',
  projectGroupId: projectGroupId,
  projectGroupName: projectGroupName,
  projectGroupPath: projectGroupId == null ? null : '/workspace/ccpocket',
  projectGroupingSnapshotComplete: projectless || projectGroupId != null,
  isSidechain: false,
);

SessionInfo _running({
  required String runtimeId,
  required String? threadId,
  required String lastActivityAt,
  String projectPath = '/repo',
  String? name,
  String lastMessage = '',
  String status = 'idle',
  bool externalDesktopTurnActive = false,
  String? lastAssistantOutputAt,
}) => SessionInfo(
  id: runtimeId,
  provider: Provider.codex.value,
  projectPath: projectPath,
  claudeSessionId: threadId,
  name: name,
  status: status,
  createdAt: '2026-07-25T00:00:00Z',
  lastActivityAt: lastActivityAt,
  lastAssistantOutputAt: lastAssistantOutputAt,
  lastMessage: lastMessage,
  externalDesktopTurnActive: externalDesktopTurnActive,
);

ConversationSyncV2Status _status(
  String id, {
  String activity = 'idle',
  String attention = 'none',
  String result = 'none',
  String source = 'appServer',
}) => ConversationSyncV2Status(
  provider: Provider.codex.value,
  providerSessionId: id,
  activity: activity,
  attention: attention,
  result: result,
  runtimeAttachment: 'notLoaded',
  source: source,
  confidence: 'authoritative',
  observedAt: '2026-07-25T05:00:00Z',
);
