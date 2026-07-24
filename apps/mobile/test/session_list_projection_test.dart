import 'package:ccpocket/features/session_list/session_list_projection.dart';
import 'package:ccpocket/features/session_list/state/session_list_cubit.dart';
import 'package:ccpocket/features/session_list/state/session_list_state.dart';
import 'package:ccpocket/models/messages.dart';
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
      expect(items.single.activityAt, DateTime.utc(2026, 7, 25, 2));
    });

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

    test('hides recent representation while the same resume is queued', () {
      final items = buildUnifiedSessionList(
        runningSessions: const [],
        recentSessions: [
          _recent(id: 'queued', modified: '2026-07-25T01:00:00Z'),
          _recent(id: 'visible', modified: '2026-07-25T02:00:00Z'),
        ],
        pendingResumeSessionIds: const {'queued'},
      );

      expect(items.map((item) => item.providerSessionId), ['visible']);
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
}) => RecentSession(
  sessionId: id,
  provider: Provider.codex.value,
  firstPrompt: id,
  created: '2026-07-25T00:00:00Z',
  modified: modified,
  gitBranch: 'main',
  projectPath: projectPath,
  isSidechain: false,
);

SessionInfo _running({
  required String runtimeId,
  required String? threadId,
  required String lastActivityAt,
  String? name,
  String lastMessage = '',
}) => SessionInfo(
  id: runtimeId,
  provider: Provider.codex.value,
  projectPath: '/repo',
  claudeSessionId: threadId,
  name: name,
  status: 'idle',
  createdAt: '2026-07-25T00:00:00Z',
  lastActivityAt: lastActivityAt,
  lastMessage: lastMessage,
);
