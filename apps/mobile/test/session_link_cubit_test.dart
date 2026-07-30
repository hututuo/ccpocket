import 'dart:async';

import 'package:ccpocket/features/session_link/state/session_link_cubit.dart';
import 'package:ccpocket/features/session_link/state/session_link_state.dart';
import 'package:ccpocket/features/session_list/services/session_resume_coordinator.dart';
import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _SessionLinkBridge extends BridgeService {
  final controller = StreamController<ServerMessage>.broadcast();
  late SessionLinkResolveResult result;
  Object? resolveError;
  BridgeDataSourceIdentity? expectedDataSourceIdentity;
  SessionLinkProgressCallback? onProgress;
  bool progressSupported = false;
  bool identityConnected = true;
  bool identityAuthoritative = true;
  BridgeDataSourceIdentity currentDataSourceIdentity =
      BridgeDataSourceIdentity.unscoped;

  @override
  bool get supportsSessionLinkProgress => progressSupported;

  @override
  bool get isConnected => identityConnected;

  @override
  bool get hasAuthoritativeSessionListForCurrentConnection =>
      identityConnected && identityAuthoritative;

  @override
  BridgeDataSourceIdentity get dataSourceIdentity => currentDataSourceIdentity;

  @override
  Stream<ServerMessage> get messages => controller.stream;

  @override
  Future<SessionLinkResolveResult> resolveSessionLink(
    String sessionId, {
    String provider = 'claude',
    Duration timeout = const Duration(seconds: 10),
    Duration progressIdleTimeout = const Duration(seconds: 15),
    Duration progressHardTimeout = const Duration(minutes: 2),
    SessionLinkProgressCallback? onProgress,
    BridgeDataSourceIdentity expectedDataSourceIdentity =
        BridgeDataSourceIdentity.unscoped,
  }) async {
    this.expectedDataSourceIdentity = expectedDataSourceIdentity;
    this.onProgress = onProgress;
    final error = resolveError;
    if (error != null) throw error;
    return result;
  }

  @override
  void dispose() {
    controller.close();
    super.dispose();
  }
}

class _ResumeCoordinator extends SessionResumeCoordinator {
  _ResumeCoordinator({required super.bridge});

  RecentSession? resumedSession;
  String? resumeRequestId;
  int? sessionLinkGeneration;

  @override
  Future<SessionResumeDispatch> resume(
    RecentSession session, {
    String? resumeRequestId,
    int? sessionLinkGeneration,
  }) async {
    resumedSession = session;
    this.resumeRequestId = resumeRequestId;
    this.sessionLinkGeneration = sessionLinkGeneration;
    return SessionResumeDispatch(
      disposition: SessionResumeDisposition.dispatched,
      projectPath: session.projectPath,
      gitBranch: session.gitBranch,
    );
  }
}

RecentSession _recentSession() => const RecentSession(
  sessionId: 'claude-uuid',
  provider: 'claude',
  firstPrompt: 'Continue',
  created: '2026-07-24T00:00:00Z',
  modified: '2026-07-24T01:00:00Z',
  gitBranch: 'main',
  projectPath: '/workspace/app',
  isSidechain: false,
);

void main() {
  late _SessionLinkBridge bridge;

  setUp(() {
    bridge = _SessionLinkBridge();
  });

  tearDown(() {
    bridge.dispose();
  });

  test('opens an exact live Bridge session', () async {
    bridge.result = const SessionLinkResolveResult.resolved(
      SessionLinkResolutionMessage(
        requestId: 'request-1',
        sourceSessionId: 'claude-uuid',
        status: SessionLinkResolutionStatus.live,
        bridgeSessionId: 'bridge-1',
        provider: 'claude',
      ),
    );
    final cubit = SessionLinkCubit(
      bridge: bridge,
      sourceSessionId: 'claude-uuid',
      provider: 'claude',
    );
    addTearDown(cubit.close);

    await cubit.resolve();

    expect(
      cubit.state,
      const SessionLinkState.openLive(
        bridgeSessionId: 'bridge-1',
        provider: 'claude',
      ),
    );
  });

  test('forwards the expected Bridge data source to the resolver', () async {
    bridge.result = const SessionLinkResolveResult.unavailable();
    const expected = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-source-a',
    );
    final cubit = SessionLinkCubit(
      bridge: bridge,
      sourceSessionId: 'codex-thread',
      provider: 'codex',
      expectedDataSourceIdentity: expected,
    );
    addTearDown(cubit.close);

    await cubit.resolve();

    expect(bridge.expectedDataSourceIdentity, expected);
    expect(cubit.state, const SessionLinkState.unavailable());
  });

  test('falls back to the legacy route for an older Bridge', () async {
    bridge.result = const SessionLinkResolveResult.unsupported();
    final cubit = SessionLinkCubit(
      bridge: bridge,
      sourceSessionId: 'claude-uuid',
      provider: 'claude',
    );
    addTearDown(cubit.close);

    await cubit.resolve();

    expect(cubit.state, const SessionLinkState.openLegacy());
  });

  test('resumes an exact recent session and opens its new runtime', () async {
    final recentSession = _recentSession();
    bridge.result = SessionLinkResolveResult.resolved(
      SessionLinkResolutionMessage(
        requestId: 'request-1',
        sourceSessionId: recentSession.sessionId,
        status: SessionLinkResolutionStatus.recent,
        provider: 'claude',
        recentSession: recentSession,
      ),
    );
    final coordinator = _ResumeCoordinator(bridge: bridge);
    final cubit = SessionLinkCubit(
      bridge: bridge,
      sourceSessionId: recentSession.sessionId,
      provider: 'claude',
      resumeCoordinator: coordinator,
      resumeRequestId: 'link-request-1',
    );
    addTearDown(cubit.close);

    await cubit.resolve();
    expect(cubit.state, const SessionLinkState.resuming());
    expect(coordinator.resumedSession?.sessionId, recentSession.sessionId);
    expect(coordinator.resumeRequestId, 'link-request-1');

    bridge.controller.add(
      const SystemMessage(
        subtype: 'session_created',
        sessionId: 'bridge-2',
        resumeRequestId: 'link-request-1',
        provider: 'claude',
      ),
    );
    await Future.microtask(() {});

    expect(cubit.state, isA<SessionLinkOpenResumed>());
    expect(
      (cubit.state as SessionLinkOpenResumed).session.sessionId,
      'bridge-2',
    );
    expect((cubit.state as SessionLinkOpenResumed).gitBranch, 'main');
  });

  test('rejects resume when the authenticated Codex source changed', () async {
    const sourceA = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'source-a',
    );
    const sourceB = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'source-b',
    );
    const recentSession = RecentSession(
      sessionId: 'codex-thread',
      provider: 'codex',
      codexSourceId: 'source-a',
      firstPrompt: 'Continue Codex work',
      created: '2026-07-24T00:00:00Z',
      modified: '2026-07-24T01:00:00Z',
      gitBranch: 'main',
      projectPath: '/workspace/app',
      isSidechain: false,
    );
    bridge.currentDataSourceIdentity = sourceB;
    bridge.result = const SessionLinkResolveResult.resolved(
      SessionLinkResolutionMessage(
        requestId: 'request-source-a',
        sourceSessionId: 'codex-thread',
        status: SessionLinkResolutionStatus.recent,
        provider: 'codex',
        recentSession: recentSession,
      ),
      dataSourceIdentity: sourceA,
    );
    final coordinator = _ResumeCoordinator(bridge: bridge);
    final cubit = SessionLinkCubit(
      bridge: bridge,
      sourceSessionId: recentSession.sessionId,
      provider: 'codex',
      expectedDataSourceIdentity: sourceA,
      resumeCoordinator: coordinator,
    );
    addTearDown(cubit.close);

    await cubit.resolve();

    expect(cubit.state, const SessionLinkState.unavailable());
    expect(cubit.lastFailureCode, 'data_source_changed');
    expect(coordinator.resumedSession, isNull);
  });

  test(
    'resume progress is generation fenced and duplicate heartbeats are ignored',
    () async {
      final recentSession = _recentSession();
      bridge.progressSupported = true;
      bridge.result = SessionLinkResolveResult.resolved(
        SessionLinkResolutionMessage(
          requestId: 'request-1',
          sourceSessionId: recentSession.sessionId,
          status: SessionLinkResolutionStatus.recent,
          provider: 'claude',
          recentSession: recentSession,
          generation: 9,
        ),
        generation: 9,
      );
      final coordinator = _ResumeCoordinator(bridge: bridge);
      final cubit = SessionLinkCubit(
        bridge: bridge,
        sourceSessionId: recentSession.sessionId,
        provider: 'claude',
        resumeCoordinator: coordinator,
        resumeRequestId: 'link-request-progress',
        progressIdleTimeout: const Duration(seconds: 1),
      );
      addTearDown(cubit.close);
      final observed = <SessionLinkProgressMessage>[];
      final subscription = cubit.progress.listen(observed.add);
      addTearDown(subscription.cancel);

      await cubit.resolve();
      expect(coordinator.sessionLinkGeneration, 9);
      expect(cubit.state, const SessionLinkState.resuming());

      SessionLinkProgressMessage progress({
        required int generation,
        required int sequence,
        int? completedUnits,
      }) => SessionLinkProgressMessage(
        requestId: 'link-request-progress',
        sourceSessionId: recentSession.sessionId,
        generation: generation,
        operation: SessionLinkProgressOperation.resume,
        stage: SessionLinkProgressStage.requestAccepted,
        sequence: sequence,
        observedAt: '2026-07-31T00:00:00Z',
        completedUnits: completedUnits,
      );

      bridge.controller.add(progress(generation: 8, sequence: 1));
      bridge.controller.add(progress(generation: 9, sequence: 1));
      bridge.controller.add(progress(generation: 9, sequence: 2));
      bridge.controller.add(
        progress(generation: 9, sequence: 3, completedUnits: 1),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        observed.map((message) => message.sequence),
        containsAllInOrder([0, 1, 3]),
      );
      expect(observed.where((message) => message.sequence == 2), isEmpty);

      bridge.controller.add(
        const SystemMessage(
          subtype: 'session_created',
          sessionId: 'bridge-stale-progress',
          resumeRequestId: 'link-request-progress',
          sessionLinkGeneration: 8,
          provider: 'claude',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state, const SessionLinkState.resuming());

      bridge.controller.add(
        const SystemMessage(
          subtype: 'session_created',
          sessionId: 'bridge-progress',
          resumeRequestId: 'link-request-progress',
          sessionLinkGeneration: 9,
          provider: 'claude',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state, isA<SessionLinkOpenResumed>());
    },
  );

  test(
    'effective resume progress can continue beyond the old hard cap',
    () async {
      final recentSession = _recentSession();
      bridge.progressSupported = true;
      bridge.result = SessionLinkResolveResult.resolved(
        SessionLinkResolutionMessage(
          requestId: 'request-long-running',
          sourceSessionId: recentSession.sessionId,
          status: SessionLinkResolutionStatus.recent,
          provider: 'claude',
          recentSession: recentSession,
          generation: 12,
        ),
        generation: 12,
      );
      final cubit = SessionLinkCubit(
        bridge: bridge,
        sourceSessionId: recentSession.sessionId,
        provider: 'claude',
        resumeCoordinator: _ResumeCoordinator(bridge: bridge),
        resumeRequestId: 'link-request-long-running',
        progressIdleTimeout: const Duration(milliseconds: 500),
        progressHardTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(cubit.close);

      await cubit.resolve();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(cubit.state, const SessionLinkState.resuming());
      bridge.controller.add(
        SessionLinkProgressMessage(
          requestId: 'link-request-long-running',
          sourceSessionId: recentSession.sessionId,
          generation: 12,
          operation: SessionLinkProgressOperation.resume,
          stage: SessionLinkProgressStage.historyReading,
          sequence: 1,
          observedAt: '2026-07-31T00:00:01Z',
          completedUnits: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      bridge.controller.add(
        const SystemMessage(
          subtype: 'session_created',
          sessionId: 'bridge-long-running',
          resumeRequestId: 'link-request-long-running',
          sessionLinkGeneration: 12,
          provider: 'claude',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state, isA<SessionLinkOpenResumed>());
      expect(cubit.lastFailureCode, isNull);
    },
  );

  test('resume fails only after effective progress becomes idle', () async {
    final recentSession = _recentSession();
    bridge.progressSupported = true;
    bridge.result = SessionLinkResolveResult.resolved(
      SessionLinkResolutionMessage(
        requestId: 'request-stalled',
        sourceSessionId: recentSession.sessionId,
        status: SessionLinkResolutionStatus.recent,
        provider: 'claude',
        recentSession: recentSession,
        generation: 13,
      ),
      generation: 13,
    );
    final cubit = SessionLinkCubit(
      bridge: bridge,
      sourceSessionId: recentSession.sessionId,
      provider: 'claude',
      resumeCoordinator: _ResumeCoordinator(bridge: bridge),
      resumeRequestId: 'link-request-stalled',
      progressIdleTimeout: const Duration(milliseconds: 60),
      progressHardTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(cubit.close);

    await cubit.resolve();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(cubit.state, const SessionLinkState.unavailable());
    expect(cubit.lastFailureCode, 'progress_idle_timeout');
  });

  test('ignores resume completions owned by another caller', () async {
    final recentSession = _recentSession();
    bridge.result = SessionLinkResolveResult.resolved(
      SessionLinkResolutionMessage(
        requestId: 'request-1',
        sourceSessionId: recentSession.sessionId,
        status: SessionLinkResolutionStatus.recent,
        provider: 'claude',
        recentSession: recentSession,
      ),
    );
    final coordinator = _ResumeCoordinator(bridge: bridge);
    final cubit = SessionLinkCubit(
      bridge: bridge,
      sourceSessionId: recentSession.sessionId,
      provider: 'claude',
      resumeCoordinator: coordinator,
      resumeRequestId: 'link-request-1',
    );
    addTearDown(cubit.close);

    await cubit.resolve();
    bridge.controller.add(
      const SystemMessage(
        subtype: 'session_created',
        sessionId: 'bridge-other',
        resumeRequestId: 'other-request',
        provider: 'claude',
      ),
    );
    await Future.microtask(() {});

    expect(cubit.state, const SessionLinkState.resuming());
  });

  test('shows unavailable when the resolver has no exact match', () async {
    bridge.result = const SessionLinkResolveResult.resolved(
      SessionLinkResolutionMessage(
        requestId: 'request-1',
        sourceSessionId: 'missing',
        status: SessionLinkResolutionStatus.unavailable,
      ),
    );
    final cubit = SessionLinkCubit(
      bridge: bridge,
      sourceSessionId: 'missing',
      provider: 'claude',
    );
    addTearDown(cubit.close);

    await cubit.resolve();

    expect(cubit.state, const SessionLinkState.unavailable());
  });

  test(
    'shows unavailable instead of staying resolving after an error',
    () async {
      bridge.resolveError = StateError('connection stream closed');
      final cubit = SessionLinkCubit(
        bridge: bridge,
        sourceSessionId: 'missing',
        provider: 'claude',
      );
      addTearDown(cubit.close);

      await cubit.resolve();

      expect(cubit.state, const SessionLinkState.unavailable());
      expect(cubit.lastFailureCode, 'resolve_error');
    },
  );

  test('retry uses a fresh correlation and can recover in place', () async {
    bridge.resolveError = StateError('connection stream closed');
    final cubit = SessionLinkCubit(
      bridge: bridge,
      sourceSessionId: 'recoverable',
      provider: 'codex',
      resumeRequestId: 'first-attempt',
    );
    addTearDown(cubit.close);

    await cubit.resolve();
    expect(cubit.state, const SessionLinkState.unavailable());
    expect(cubit.attempt, 0);

    bridge.resolveError = null;
    bridge.result = const SessionLinkResolveResult.resolved(
      SessionLinkResolutionMessage(
        requestId: 'request-2',
        sourceSessionId: 'recoverable',
        status: SessionLinkResolutionStatus.live,
        bridgeSessionId: 'bridge-recovered',
        provider: 'codex',
      ),
    );
    await cubit.retry();

    expect(cubit.attempt, 1);
    expect(cubit.lastFailureCode, isNull);
    expect(
      cubit.state,
      const SessionLinkState.openLive(
        bridgeSessionId: 'bridge-recovered',
        provider: 'codex',
      ),
    );
  });
}
