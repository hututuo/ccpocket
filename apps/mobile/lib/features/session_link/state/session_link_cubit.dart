import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../models/bridge_data_source_identity.dart';
import '../../../models/messages.dart';
import '../../../services/bridge_service.dart';
import '../../session_list/services/session_resume_coordinator.dart';
import 'session_link_state.dart';

// Public constructor labels intentionally describe injected values; using
// private initializing formals would make them inaccessible to callers.
// ignore_for_file: prefer_initializing_formals

class SessionLinkCubit extends Cubit<SessionLinkState> {
  SessionLinkCubit({
    required BridgeService bridge,
    required String sourceSessionId,
    required String provider,
    BridgeDataSourceIdentity expectedDataSourceIdentity =
        BridgeDataSourceIdentity.unscoped,
    SessionResumeCoordinator? resumeCoordinator,
    String? resumeRequestId,
    Duration progressIdleTimeout = const Duration(seconds: 15),
    Duration progressHardTimeout = const Duration(minutes: 5),
    Duration legacyResumeTimeout = const Duration(minutes: 1),
  }) : _bridge = bridge,
       _sourceSessionId = sourceSessionId,
       _provider = provider,
       _expectedDataSourceIdentity = expectedDataSourceIdentity,
       _resumeRequestId =
           resumeRequestId ??
           'session-link-${DateTime.now().microsecondsSinceEpoch}',
       _resumeCoordinator =
           resumeCoordinator ?? SessionResumeCoordinator(bridge: bridge),
       _progressIdleTimeout = progressIdleTimeout,
       _progressHardTimeout = progressHardTimeout,
       _legacyResumeTimeout = legacyResumeTimeout,
       super(const SessionLinkState.resolving());

  final BridgeService _bridge;
  final String _sourceSessionId;
  final String _provider;
  final BridgeDataSourceIdentity _expectedDataSourceIdentity;
  final String _resumeRequestId;
  final SessionResumeCoordinator _resumeCoordinator;
  final Duration _progressIdleTimeout;
  final Duration _progressHardTimeout;
  final Duration _legacyResumeTimeout;
  final StreamController<SessionLinkProgressMessage> _progressController =
      StreamController<SessionLinkProgressMessage>.broadcast();
  StreamSubscription<ServerMessage>? _resumeSubscription;
  Timer? _resumeIdleTimer;
  Timer? _resumeHardTimer;
  bool _started = false;
  String? _resumeGitBranch;
  String? _resumeSourceSessionId;
  int? _linkGeneration;
  SessionLinkProgressMessage? _currentProgress;
  SessionLinkProgressMessage? _lastResumeProgress;

  Stream<SessionLinkProgressMessage> get progress => _progressController.stream;
  SessionLinkProgressMessage? get currentProgress => _currentProgress;

  Future<void> resolve() async {
    if (_started) return;
    _started = true;
    try {
      await _resolveOnce();
    } catch (_) {
      await _cancelResumeSubscription();
      if (!isClosed) {
        emit(const SessionLinkState.unavailable());
      }
    }
  }

  Future<void> _resolveOnce() async {
    final result = await _bridge.resolveSessionLink(
      _sourceSessionId,
      provider: _provider,
      progressIdleTimeout: _progressIdleTimeout,
      progressHardTimeout: _progressHardTimeout,
      onProgress: _publishProgress,
      expectedDataSourceIdentity: _expectedDataSourceIdentity,
    );
    if (isClosed) return;
    if (result.support == SessionLinkResolveSupport.unsupported) {
      emit(const SessionLinkState.openLegacy());
      return;
    }
    if (result.support == SessionLinkResolveSupport.unavailable) {
      emit(const SessionLinkState.unavailable());
      return;
    }

    final resolution = result.resolution;
    if (resolution == null) {
      emit(const SessionLinkState.unavailable());
      return;
    }
    _linkGeneration = result.generation;
    switch (resolution.status) {
      case SessionLinkResolutionStatus.live:
        final bridgeSessionId = resolution.bridgeSessionId;
        if (bridgeSessionId == null || bridgeSessionId.isEmpty) {
          emit(const SessionLinkState.unavailable());
          return;
        }
        emit(
          SessionLinkState.openLive(
            bridgeSessionId: bridgeSessionId,
            provider: resolution.provider ?? _provider,
          ),
        );
      case SessionLinkResolutionStatus.recent:
        final recentSession = resolution.recentSession;
        if (recentSession == null) {
          emit(const SessionLinkState.unavailable());
          return;
        }
        await _resume(recentSession);
      case SessionLinkResolutionStatus.unavailable:
        emit(const SessionLinkState.unavailable());
    }
  }

  Future<void> _resume(RecentSession session) async {
    await _resumeSubscription?.cancel();
    _resumeSubscription = _bridge.messages.listen(_handleResumeMessage);
    _resumeSourceSessionId = session.sessionId;
    _lastResumeProgress = null;
    emit(const SessionLinkState.resuming());
    _publishProgress(
      SessionLinkProgressMessage(
        requestId: _resumeRequestId,
        sourceSessionId: session.sessionId,
        generation: _linkGeneration ?? 1,
        operation: SessionLinkProgressOperation.resume,
        stage: SessionLinkProgressStage.requestSent,
        sequence: 0,
        observedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
    _armResumeHardTimer();
    final dispatch = await _resumeCoordinator.resume(
      session,
      resumeRequestId: _resumeRequestId,
      sessionLinkGeneration: _bridge.supportsSessionLinkProgress
          ? _linkGeneration
          : null,
    );
    if (isClosed) return;
    _resumeGitBranch = dispatch.gitBranch;
    if (dispatch.disposition == SessionResumeDisposition.alreadyQueued) {
      await _cancelResumeSubscription();
      emit(const SessionLinkState.unavailable());
      return;
    }
    if (_bridge.supportsSessionLinkProgress && _linkGeneration != null) {
      _armResumeIdleTimer();
    } else {
      _resumeHardTimer?.cancel();
      _resumeHardTimer = Timer(_legacyResumeTimeout, _onResumeTimeout);
    }
  }

  void _handleResumeMessage(ServerMessage message) {
    if (isClosed) return;
    if (message is SessionLinkProgressMessage) {
      if (message.requestId != _resumeRequestId ||
          message.sourceSessionId != _resumeSourceSessionId ||
          message.generation != _linkGeneration ||
          message.operation != SessionLinkProgressOperation.resume ||
          !message.isEffectiveAfter(_lastResumeProgress)) {
        return;
      }
      _lastResumeProgress = message;
      _publishProgress(message);
      _armResumeIdleTimer();
      return;
    }
    if (message is! SystemMessage) return;
    if (message.resumeRequestId != _resumeRequestId) return;
    if (message.subtype == 'session_created' && message.sessionId != null) {
      unawaited(_cancelResumeSubscription());
      emit(
        SessionLinkState.openResumed(
          session: message,
          gitBranch: _resumeGitBranch,
        ),
      );
      return;
    }
    if (message.subtype == 'session_resume_failed') {
      unawaited(_cancelResumeSubscription());
      emit(const SessionLinkState.unavailable());
    }
  }

  void _publishProgress(SessionLinkProgressMessage progress) {
    if (isClosed) return;
    final current = _currentProgress;
    if (current != null &&
        current.requestId == progress.requestId &&
        current.sourceSessionId == progress.sourceSessionId &&
        current.generation == progress.generation &&
        current.operation == progress.operation &&
        current.stage == progress.stage &&
        current.sequence == progress.sequence &&
        current.completedUnits == progress.completedUnits &&
        current.totalUnits == progress.totalUnits) {
      return;
    }
    _currentProgress = progress;
    _progressController.add(progress);
  }

  void _armResumeIdleTimer() {
    _resumeIdleTimer?.cancel();
    _resumeIdleTimer = Timer(_progressIdleTimeout, _onResumeTimeout);
  }

  void _armResumeHardTimer() {
    _resumeHardTimer?.cancel();
    _resumeHardTimer = Timer(_progressHardTimeout, _onResumeTimeout);
  }

  void _onResumeTimeout() {
    if (isClosed || state is! SessionLinkResuming) return;
    unawaited(_cancelResumeSubscription());
    emit(const SessionLinkState.unavailable());
  }

  Future<void> _cancelResumeSubscription() async {
    _resumeIdleTimer?.cancel();
    _resumeIdleTimer = null;
    _resumeHardTimer?.cancel();
    _resumeHardTimer = null;
    await _resumeSubscription?.cancel();
    _resumeSubscription = null;
  }

  @override
  Future<void> close() async {
    await _cancelResumeSubscription();
    await _progressController.close();
    return super.close();
  }
}
