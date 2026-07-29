import '../../models/messages.dart';
import '../../widgets/session_visual_status.dart';
import 'state/session_list_cubit.dart';
import 'state/session_list_state.dart';

enum SessionListUrgency { needsYou, working, unread, ordinary }

/// One durable conversation row assembled from the Bridge runtime list and the
/// provider's recent-session catalog.
///
/// A runtime id is deliberately not treated as durable identity. Once the
/// provider thread id is known, running and recent representations collapse
/// into the same row. A just-created runtime without that binding remains a
/// temporary row until the next authoritative session list supplies it.
class UnifiedSessionListItem {
  const UnifiedSessionListItem({
    required this.identityKey,
    required this.running,
    required this.recent,
    required this.activityAt,
  });

  final String identityKey;
  final SessionInfo? running;
  final RecentSession? recent;
  final DateTime? activityAt;

  bool get isRunning => running != null;

  String get provider =>
      running?.provider ?? recent?.provider ?? Provider.claude.value;

  String get projectPath => running?.projectPath ?? recent?.projectPath ?? '';

  String? get providerSessionId {
    final runningId = running?.claudeSessionId?.trim();
    if (runningId != null && runningId.isNotEmpty) return runningId;
    final recentId = recent?.sessionId.trim();
    return recentId == null || recentId.isEmpty ? null : recentId;
  }

  String? get pinKey {
    final durableId = providerSessionId;
    if (durableId == null) return null;
    return sessionPinKey(
      provider: provider,
      projectPath: projectPath,
      sessionId: durableId,
    );
  }

  UnifiedSessionListItem merge({
    SessionInfo? nextRunning,
    RecentSession? nextRecent,
  }) {
    final mergedRunning = nextRunning ?? running;
    final mergedRecent = nextRecent ?? recent;
    return UnifiedSessionListItem(
      identityKey: identityKey,
      running: mergedRunning,
      recent: mergedRecent,
      activityAt: _latestActivity(mergedRunning, mergedRecent),
    );
  }
}

List<UnifiedSessionListItem> buildUnifiedSessionList({
  required Iterable<SessionInfo> runningSessions,
  required Iterable<RecentSession> recentSessions,
  Set<String> pendingResumeSessionIds = const {},
  Set<String> pinnedSessionKeys = const {},
  Set<String> unseenSessionIds = const {},
}) {
  final byIdentity = <String, UnifiedSessionListItem>{};

  for (final recent in recentSessions) {
    if (pendingResumeSessionIds.contains(recent.sessionId)) continue;
    final identity = _recentIdentity(recent);
    byIdentity[identity] = UnifiedSessionListItem(
      identityKey: identity,
      running: null,
      recent: recent,
      activityAt: _latestActivity(null, recent),
    );
  }

  for (final running in runningSessions) {
    final identity = _runningIdentity(running);
    final existing = byIdentity[identity];
    if (existing == null) {
      byIdentity[identity] = UnifiedSessionListItem(
        identityKey: identity,
        running: running,
        recent: null,
        activityAt: _latestActivity(running, null),
      );
      continue;
    }
    final currentRunning = existing.running;
    final keep = currentRunning == null
        ? running
        : _preferRunning(currentRunning, running);
    byIdentity[identity] = existing.merge(nextRunning: keep);
  }

  final items = byIdentity.values.toList(growable: false);
  final urgencyByIdentity = {
    for (final item in items)
      item.identityKey: sessionListUrgencyFor(
        item,
        unseenSessionIds: unseenSessionIds,
      ),
  };
  items.sort((left, right) {
    final pinCompare = _pinTier(
      left,
      pinnedSessionKeys: pinnedSessionKeys,
    ).compareTo(_pinTier(right, pinnedSessionKeys: pinnedSessionKeys));
    if (pinCompare != 0) return pinCompare;

    final urgencyCompare = urgencyByIdentity[left.identityKey]!.index.compareTo(
      urgencyByIdentity[right.identityKey]!.index,
    );
    if (urgencyCompare != 0) return urgencyCompare;

    final activityCompare = (right.activityAt?.millisecondsSinceEpoch ?? -1)
        .compareTo(left.activityAt?.millisecondsSinceEpoch ?? -1);
    if (activityCompare != 0) return activityCompare;
    return left.identityKey.compareTo(right.identityKey);
  });
  return List.unmodifiable(items);
}

SessionListUrgency sessionListUrgencyFor(
  UnifiedSessionListItem item, {
  required Set<String> unseenSessionIds,
}) {
  final running = item.running;
  if (running == null) return SessionListUrgency.ordinary;
  final visualStatus = sessionVisualStatusFor(
    rawStatus: running.externalDesktopTurnActive ? 'running' : running.status,
    permissionMode: running.effectivePermissionMode,
    planMode: running.resolvedPlanMode,
    pendingPermission: running.pendingPermission,
  );
  if (visualStatus.primary == SessionPrimaryStatus.needsYou) {
    return SessionListUrgency.needsYou;
  }
  if (visualStatus.primary == SessionPrimaryStatus.working) {
    return SessionListUrgency.working;
  }
  if (visualStatus.primary == SessionPrimaryStatus.idle &&
      unseenSessionIds.contains(running.id)) {
    return SessionListUrgency.unread;
  }
  return SessionListUrgency.ordinary;
}

bool sessionListItemBypassesDisplayLimit(
  UnifiedSessionListItem item, {
  required Set<String> unseenSessionIds,
}) =>
    sessionListUrgencyFor(item, unseenSessionIds: unseenSessionIds) !=
    SessionListUrgency.ordinary;

/// Orders project sections independently from per-conversation urgency.
///
/// The flat "recent chats" list is allowed to lift unread conversations
/// across projects. The grouped view must not let that unread bit reorder
/// entire project sections, so its order is derived from explicit pins and
/// the latest activity in each project instead.
List<String> orderProjectPathsForGroupedView({
  required Iterable<String> knownProjectPaths,
  required List<UnifiedSessionListItem> sessions,
  Set<String> pinnedSessionKeys = const {},
  Set<String> pinnedProjectPaths = const {},
}) {
  final paths = <String>[];
  final firstSeenIndex = <String, int>{};
  final latestActivityByProject = <String, DateTime?>{};
  final projectsWithPinnedSessions = <String>{};

  void includePath(String path) {
    if (path.isEmpty || firstSeenIndex.containsKey(path)) return;
    firstSeenIndex[path] = paths.length;
    paths.add(path);
  }

  for (final item in sessions) {
    final path = item.projectPath;
    includePath(path);
    final pinKey = item.pinKey;
    if (pinKey != null && pinnedSessionKeys.contains(pinKey)) {
      projectsWithPinnedSessions.add(path);
    }
    final activityAt = item.activityAt;
    final currentLatest = latestActivityByProject[path];
    if (activityAt != null &&
        (currentLatest == null || activityAt.isAfter(currentLatest))) {
      latestActivityByProject[path] = activityAt;
    }
  }
  for (final path in knownProjectPaths) {
    includePath(path);
  }

  int projectTier(String path) {
    if (projectsWithPinnedSessions.contains(path)) return 0;
    if (pinnedProjectPaths.contains(path)) return 1;
    return 2;
  }

  paths.sort((left, right) {
    final tierCompare = projectTier(left).compareTo(projectTier(right));
    if (tierCompare != 0) return tierCompare;

    final leftActivity = latestActivityByProject[left];
    final rightActivity = latestActivityByProject[right];
    if (leftActivity != null || rightActivity != null) {
      if (leftActivity == null) return 1;
      if (rightActivity == null) return -1;
      final activityCompare = rightActivity.compareTo(leftActivity);
      if (activityCompare != 0) return activityCompare;
    }
    return firstSeenIndex[left]!.compareTo(firstSeenIndex[right]!);
  });
  return List.unmodifiable(paths);
}

bool runningSessionMatchesListFilters(
  SessionInfo session, {
  required ProviderFilter providerFilter,
  required String? projectPath,
  required bool namedOnly,
  required String searchQuery,
}) {
  if (projectPath != null && session.projectPath != projectPath) return false;
  final provider = session.provider ?? Provider.claude.value;
  if (providerFilter != ProviderFilter.all && provider != providerFilter.name) {
    return false;
  }
  if (namedOnly && (session.name?.trim().isNotEmpty != true)) return false;

  final query = searchQuery.trim().toLowerCase();
  if (query.isEmpty) return true;
  return [
    session.name,
    session.agentNickname,
    session.agentRole,
    session.lastMessage,
    session.projectPath,
    session.worktreePath,
    session.gitBranch,
  ].whereType<String>().any((value) => value.toLowerCase().contains(query));
}

bool recentSessionMatchesListFilters(
  RecentSession session, {
  required ProviderFilter providerFilter,
  required String? projectPath,
  required bool namedOnly,
  required String searchQuery,
}) {
  if (projectPath != null && session.projectPath != projectPath) return false;
  final provider = session.provider ?? Provider.claude.value;
  if (providerFilter != ProviderFilter.all && provider != providerFilter.name) {
    return false;
  }
  if (namedOnly && (session.name?.trim().isNotEmpty != true)) return false;

  final query = searchQuery.trim().toLowerCase();
  if (query.isEmpty) return true;
  return [
    session.name,
    session.agentNickname,
    session.agentRole,
    session.summary,
    session.firstPrompt,
    session.lastPrompt,
    session.projectPath,
    session.resumeCwd,
    session.gitBranch,
  ].whereType<String>().any((value) => value.toLowerCase().contains(query));
}

int _pinTier(
  UnifiedSessionListItem item, {
  required Set<String> pinnedSessionKeys,
}) {
  final pinKey = item.pinKey;
  if (pinKey != null && pinnedSessionKeys.contains(pinKey)) return 0;
  return 1;
}

String _recentIdentity(RecentSession session) => providerSessionIdentityKey(
  session.provider ?? Provider.claude.value,
  session.sessionId,
);

String _runningIdentity(SessionInfo session) {
  final durableId = session.claudeSessionId?.trim();
  if (durableId != null && durableId.isNotEmpty) {
    return providerSessionIdentityKey(
      session.provider ?? Provider.claude.value,
      durableId,
    );
  }
  return 'runtime\u0000${session.provider ?? Provider.claude.value}'
      '\u0000${session.id}';
}

SessionInfo _preferRunning(SessionInfo left, SessionInfo right) {
  final leftActivity = _parseDate(left.lastActivityAt);
  final rightActivity = _parseDate(right.lastActivityAt);
  if (leftActivity == null) return right;
  if (rightActivity == null) return left;
  return rightActivity.isAfter(leftActivity) ? right : left;
}

DateTime? _latestActivity(SessionInfo? running, RecentSession? recent) {
  final candidates = <DateTime>[
    ?_parseDate(running?.lastActivityAt),
    ?_parseDate(recent?.modified),
    ?_parseDate(running?.createdAt),
    ?_parseDate(recent?.created),
  ];
  if (candidates.isEmpty) return null;
  return candidates.reduce(
    (latest, candidate) => candidate.isAfter(latest) ? candidate : latest,
  );
}

DateTime? _parseDate(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}
