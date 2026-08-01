import 'dart:async';

import 'package:flutter/widgets.dart';

// Public constructor labels intentionally describe injectable collaborators;
// initializing formals would expose private field names to callers.
// ignore_for_file: prefer_initializing_formals

import '../../models/messages.dart';
import '../../services/bridge_service.dart';
import '../conversation_mirror/conversation_mirror_service.dart';
import 'background_notification_mode_controller.dart';
import 'background_sync_host.dart';

enum BackgroundSyncTrigger { enteringBackground, appRefresh, resumed }

const backgroundSyncMachineIdentityPrefix = 'machine:';

String? machineIdFromLogicalConnectionIdentity(String? logicalIdentity) {
  final value = logicalIdentity?.trim();
  if (value == null || !value.startsWith(backgroundSyncMachineIdentityPrefix)) {
    return null;
  }
  final machineId = value.substring(backgroundSyncMachineIdentityPrefix.length);
  return machineId.isEmpty ? null : machineId;
}

abstract interface class BackgroundSyncBridgeGateway {
  bool get isConnected;
  bool get hasAuthoritativeSessionList;
  int get authoritativeSessionListGeneration;
  bool get hasBackgroundWork;
  List<String> get activeSessionIds;
  Stream<BridgeConnectionState> get connectionStates;
  Stream<void> get sessionListChanges;
  Stream<String> get sessionHistoryReconciliations;

  int sessionHistoryReconciliationGeneration(String sessionId);
  void ensureConnected();
  Future<bool> rebuildConnection();
  void requestSessionList();
  void requestSessionHistory(
    String sessionId, {
    required bool allowFullFallback,
  });
  bool hasCachedSessionHistory(String sessionId);
}

class BridgeServiceBackgroundSyncGateway
    implements BackgroundSyncBridgeGateway {
  const BridgeServiceBackgroundSyncGateway(
    this._bridge, {
    Future<bool> Function()? rebuildConnection,
  }) : _rebuildConnection = rebuildConnection;

  final BridgeService _bridge;
  final Future<bool> Function()? _rebuildConnection;

  @override
  bool get isConnected => _bridge.isTransportHealthy;

  @override
  bool get hasAuthoritativeSessionList =>
      _bridge.hasAuthoritativeSessionListForCurrentConnection;

  @override
  int get authoritativeSessionListGeneration =>
      _bridge.authoritativeSessionListGeneration;

  @override
  List<String> get activeSessionIds =>
      _bridge.sessions.map((session) => session.id).toList(growable: false);

  @override
  bool get hasBackgroundWork =>
      _bridge.backgroundActiveWorkCount > 0 ||
      _bridge.sessions.any((session) {
        return session.externalDesktopTurnActive ||
            session.queuedInput != null ||
            const {
              'starting',
              'running',
              'waiting_approval',
              'compacting',
            }.contains(session.status);
      });

  @override
  Stream<BridgeConnectionState> get connectionStates =>
      _bridge.connectionStatus;

  @override
  Stream<void> get sessionListChanges => _bridge.sessionList.map<void>((_) {});

  @override
  Stream<String> get sessionHistoryReconciliations =>
      _bridge.sessionHistoryReconciliations;

  @override
  int sessionHistoryReconciliationGeneration(String sessionId) =>
      _bridge.sessionHistoryReconciliationGeneration(sessionId);

  @override
  void ensureConnected() => _bridge.ensureConnected();

  @override
  Future<bool> rebuildConnection() async {
    final callback = _rebuildConnection;
    return callback == null ? false : callback();
  }

  @override
  void requestSessionList() => _bridge.requestSessionList();

  @override
  void requestSessionHistory(
    String sessionId, {
    required bool allowFullFallback,
  }) {
    if (allowFullFallback) {
      _bridge.requestSessionHistory(sessionId);
    } else {
      _bridge.requestSessionHistoryDeltaOnly(sessionId);
    }
  }

  @override
  bool hasCachedSessionHistory(String sessionId) =>
      _bridge.cachedSessionHistorySeq(sessionId) > 0;
}

abstract interface class BackgroundSyncMirrorGateway {
  Future<void> setAutomaticWatchRestorationEnabled(bool enabled);

  Future<void> reconcileResidents({
    required int maximumConversations,
    required Duration budget,
    required bool restoreMissingWatches,
    ConversationMirrorCancellation? cancellation,
  });
}

class ConversationMirrorBackgroundSyncGateway
    implements BackgroundSyncMirrorGateway {
  const ConversationMirrorBackgroundSyncGateway(this._service);

  final ConversationMirrorService _service;

  @override
  Future<void> setAutomaticWatchRestorationEnabled(bool enabled) =>
      _service.setAutomaticWatchRestorationEnabled(enabled);

  @override
  Future<void> reconcileResidents({
    required int maximumConversations,
    required Duration budget,
    required bool restoreMissingWatches,
    ConversationMirrorCancellation? cancellation,
  }) async {
    await _service.reconcileResidents(
      maximumConversations: maximumConversations,
      budget: budget,
      restoreMissingWatches: restoreMissingWatches,
      cancellation: cancellation,
    );
  }
}

class MobileBackgroundSyncCoordinator {
  MobileBackgroundSyncCoordinator({
    required BackgroundSyncHost host,
    required BackgroundSyncBridgeGateway bridge,
    required BackgroundSyncMirrorGateway mirror,
    BackgroundNotificationModeLifecycle? backgroundNotificationMode,
    Duration connectionTimeout = const Duration(seconds: 4),
    Duration sessionListTimeout = const Duration(seconds: 5),
    Duration historyResponseTimeout = const Duration(seconds: 4),
    Duration continuationTrackingWindow = const Duration(seconds: 22),
    Duration continuationTrackingPoll = const Duration(milliseconds: 500),
  }) : _host = host,
       _bridge = bridge,
       _mirror = mirror,
       _backgroundNotificationMode = backgroundNotificationMode,
       _connectionTimeout = connectionTimeout,
       _sessionListTimeout = sessionListTimeout,
       _historyResponseTimeout = historyResponseTimeout,
       _continuationTrackingWindow = continuationTrackingWindow,
       _continuationTrackingPoll = continuationTrackingPoll;

  final BackgroundSyncHost _host;
  final BackgroundSyncBridgeGateway _bridge;
  final BackgroundSyncMirrorGateway _mirror;
  final BackgroundNotificationModeLifecycle? _backgroundNotificationMode;
  final Duration _connectionTimeout;
  final Duration _sessionListTimeout;
  final Duration _historyResponseTimeout;
  final Duration _continuationTrackingWindow;
  final Duration _continuationTrackingPoll;

  Future<void> _syncTail = Future<void>.value();
  _BackgroundSyncLifecycleMode _lifecycleMode =
      _BackgroundSyncLifecycleMode.unknown;
  int _lifecycleTransitionGeneration = 0;
  _SyncCancellationToken? _lifecycleCancellation;
  bool _foregroundCatchupPending = false;
  int _continuationGeneration = 0;
  int? _activeContinuationGeneration;
  _SyncCancellationToken? _activeContinuationCancellation;
  bool _dartReady = false;
  Future<bool>? _dartReadyAttempt;
  bool _started = false;
  bool _disposed = false;

  void start({AppLifecycleState? initialLifecycleState}) {
    if (_started || _disposed) return;
    _started = true;
    _lifecycleMode = _lifecycleModeFor(initialLifecycleState);
    _foregroundCatchupPending =
        _lifecycleMode == _BackgroundSyncLifecycleMode.background;
    final lifecycleGeneration = ++_lifecycleTransitionGeneration;
    _lifecycleCancellation = _SyncCancellationToken();
    _host.setRefreshHandler(_performAppRefresh);
    _host.setContinuationExpirationHandler(_handleContinuationExpired);
    final initialWatchState = _setAutomaticWatchRestorationEnabled(
      _lifecycleMode == _BackgroundSyncLifecycleMode.foreground,
    );
    if (_lifecycleMode != _BackgroundSyncLifecycleMode.unknown) {
      unawaited(
        _publishDartReadyForLifecycle(lifecycleGeneration, initialWatchState),
      );
    } else {
      // A warm-runtime BGAppRefresh can arrive before Flutter publishes a
      // definite lifecycle state. Attach the Dart handler immediately so the
      // native pending task can complete, but keep scheduling fail-closed until
      // foreground/background is known.
      unawaited(_ensureDartReady());
    }
  }

  Future<void> handleLifecycleState(AppLifecycleState state) {
    if (_disposed) return Future<void>.value();
    final nextMode = _lifecycleModeFor(state);
    if (nextMode == _lifecycleMode) return Future<void>.value();

    final previousMode = _lifecycleMode;
    _lifecycleCancellation?.cancel();
    final transitionCancellation = _SyncCancellationToken();
    _lifecycleCancellation = transitionCancellation;
    final transitionGeneration = ++_lifecycleTransitionGeneration;
    _lifecycleMode = nextMode;

    switch (nextMode) {
      case _BackgroundSyncLifecycleMode.background:
        _foregroundCatchupPending = true;
        return _enterBackground(
          transitionGeneration: transitionGeneration,
          cancellation: transitionCancellation,
        );
      case _BackgroundSyncLifecycleMode.foreground:
        final shouldReconcile = _foregroundCatchupPending;
        final continuation = _takeActiveContinuation();
        return _resumeToForeground(
          transitionGeneration: transitionGeneration,
          cancellation: transitionCancellation,
          continuation: continuation,
          shouldReconcile: shouldReconcile,
        );
      case _BackgroundSyncLifecycleMode.unknown:
        final continuation = _takeActiveContinuation();
        final prepareForBackground =
            state == AppLifecycleState.inactive &&
            previousMode == _BackgroundSyncLifecycleMode.foreground;
        return _enterUnknownLifecycle(
          continuation,
          transitionGeneration: transitionGeneration,
          cancellation: transitionCancellation,
          prepareForBackground: prepareForBackground,
        );
    }
  }

  Future<void> _enterBackground({
    required int transitionGeneration,
    required _SyncCancellationToken cancellation,
  }) async {
    await _setAutomaticWatchRestorationEnabled(false);
    if (!_isCurrentLifecycleTransition(
      transitionGeneration,
      _BackgroundSyncLifecycleMode.background,
      cancellation,
    )) {
      return;
    }
    final notificationMode = _backgroundNotificationMode;
    if (notificationMode != null) {
      final handled = await notificationMode.enterBackground(
        hasBackgroundWork: _bridge.hasBackgroundWork,
      );
      if (handled ||
          !_isCurrentLifecycleTransition(
            transitionGeneration,
            _BackgroundSyncLifecycleMode.background,
            cancellation,
          )) {
        return;
      }
    }
    unawaited(
      _publishDartReadyForLifecycle(transitionGeneration, Future<void>.value()),
    );
    if (!_bridge.hasBackgroundWork || !_host.supportsContinuation) return;
    final generation = ++_continuationGeneration;
    _activeContinuationGeneration = generation;
    _activeContinuationCancellation = cancellation;
    final accepted = await _host.beginContinuation(
      generation: generation,
      reason: 'active_conversation_sync',
    );
    final ownsContinuation = _activeContinuationGeneration == generation;
    if (!accepted ||
        !ownsContinuation ||
        !_isCurrentLifecycleTransition(
          transitionGeneration,
          _BackgroundSyncLifecycleMode.background,
          cancellation,
        )) {
      if (ownsContinuation) {
        _activeContinuationGeneration = null;
        _activeContinuationCancellation = null;
        if (accepted) {
          await _host.endContinuation(generation: generation);
        }
      }
      return;
    }
    final trackingDeadline = DateTime.now().add(_continuationTrackingWindow);
    try {
      await _synchronize(
        BackgroundSyncTrigger.enteringBackground,
        cancellation: cancellation,
      );
      await _trackActiveBackgroundTurn(
        deadline: trackingDeadline,
        cancellation: cancellation,
      );
    } finally {
      if (_activeContinuationGeneration == generation) {
        _activeContinuationGeneration = null;
        _activeContinuationCancellation = null;
        await _host.endContinuation(generation: generation);
      }
    }
  }

  Future<void> _resumeToForeground({
    required int transitionGeneration,
    required _SyncCancellationToken cancellation,
    required _ContinuationLease? continuation,
    required bool shouldReconcile,
  }) async {
    await _endContinuation(continuation);
    if (!_isCurrentLifecycleTransition(
      transitionGeneration,
      _BackgroundSyncLifecycleMode.foreground,
      cancellation,
    )) {
      return;
    }
    await _backgroundNotificationMode?.enterForeground();
    if (!_isCurrentLifecycleTransition(
      transitionGeneration,
      _BackgroundSyncLifecycleMode.foreground,
      cancellation,
    )) {
      return;
    }
    await _setAutomaticWatchRestorationEnabled(true);
    if (!_isCurrentLifecycleTransition(
      transitionGeneration,
      _BackgroundSyncLifecycleMode.foreground,
      cancellation,
    )) {
      return;
    }
    await _publishDartReadyForLifecycle(
      transitionGeneration,
      Future<void>.value(),
    );
    if (!_isCurrentLifecycleTransition(
      transitionGeneration,
      _BackgroundSyncLifecycleMode.foreground,
      cancellation,
    )) {
      return;
    }
    if (shouldReconcile) {
      final reconciled = await _synchronize(
        BackgroundSyncTrigger.resumed,
        cancellation: cancellation,
      );
      if (reconciled &&
          _isCurrentLifecycleTransition(
            transitionGeneration,
            _BackgroundSyncLifecycleMode.foreground,
            cancellation,
          )) {
        _foregroundCatchupPending = false;
      }
    }
  }

  Future<void> _enterUnknownLifecycle(
    _ContinuationLease? continuation, {
    required int transitionGeneration,
    required _SyncCancellationToken cancellation,
    required bool prepareForBackground,
  }) async {
    final disabled = _setAutomaticWatchRestorationEnabled(false);
    await _endContinuation(continuation);
    await disabled;
    if (!_isCurrentLifecycleTransition(
      transitionGeneration,
      _BackgroundSyncLifecycleMode.unknown,
      cancellation,
    )) {
      return;
    }
    final notificationMode = _backgroundNotificationMode;
    if (notificationMode == null) return;
    if (prepareForBackground) {
      await notificationMode.prepareForBackground(
        hasBackgroundWork: _bridge.hasBackgroundWork,
      );
    } else {
      await notificationMode.leaveLifecycle();
    }
  }

  Future<void> _publishDartReadyForLifecycle(
    int transitionGeneration,
    Future<void> lifecycleStatePublication,
  ) async {
    await lifecycleStatePublication;
    if (!_isCurrentLifecycleGeneration(transitionGeneration) ||
        _lifecycleMode == _BackgroundSyncLifecycleMode.unknown) {
      return;
    }
    final ready = await _ensureDartReady();
    if (!ready ||
        !_isCurrentLifecycleGeneration(transitionGeneration) ||
        _lifecycleMode == _BackgroundSyncLifecycleMode.unknown) {
      return;
    }
    unawaited(_host.scheduleRefresh());
  }

  Future<bool> _ensureDartReady() async {
    if (_disposed || !_host.supportsAppRefresh) return false;
    if (_dartReady) return true;
    final existing = _dartReadyAttempt;
    if (existing != null) return existing;

    late final Future<bool> attempt;
    attempt = () async {
      final ready = await _host.markDartReady();
      if (ready && !_disposed) {
        _dartReady = true;
        return true;
      }
      return false;
    }();
    _dartReadyAttempt = attempt;
    try {
      return await attempt;
    } finally {
      if (identical(_dartReadyAttempt, attempt)) {
        _dartReadyAttempt = null;
      }
    }
  }

  bool _isCurrentLifecycleGeneration(int generation) =>
      !_disposed && _lifecycleTransitionGeneration == generation;

  bool _isCurrentLifecycleTransition(
    int generation,
    _BackgroundSyncLifecycleMode expectedMode,
    _SyncCancellationToken cancellation,
  ) {
    return _isCurrentLifecycleGeneration(generation) &&
        _lifecycleMode == expectedMode &&
        !cancellation.isCancelled;
  }

  _ContinuationLease? _takeActiveContinuation() {
    final generation = _activeContinuationGeneration;
    if (generation == null) return null;
    final cancellation = _activeContinuationCancellation;
    _activeContinuationGeneration = null;
    _activeContinuationCancellation = null;
    cancellation?.cancel();
    return _ContinuationLease(generation);
  }

  Future<void> _endContinuation(_ContinuationLease? continuation) async {
    if (continuation == null) return;
    await _host.endContinuation(generation: continuation.generation);
  }

  static _BackgroundSyncLifecycleMode _lifecycleModeFor(
    AppLifecycleState? state,
  ) {
    return switch (state) {
      AppLifecycleState.resumed => _BackgroundSyncLifecycleMode.foreground,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused => _BackgroundSyncLifecycleMode.background,
      AppLifecycleState.inactive ||
      AppLifecycleState.detached ||
      null => _BackgroundSyncLifecycleMode.unknown,
    };
  }

  Future<bool> _performAppRefresh(BackgroundRefreshRequest request) async {
    if (_disposed || request.isExpired) return false;
    if (_backgroundNotificationMode?.ownsBackgroundTransport == true) {
      // Location-backed notification mode deliberately owns the background
      // transport. Do not parse, reconcile, or render conversation data until
      // foreground restoration switches the Bridge back to interactive mode.
      return true;
    }
    await _setAutomaticWatchRestorationEnabled(false);
    try {
      if (_host.supportsAppRefresh) {
        unawaited(_host.scheduleRefresh());
      }
      return await synchronize(
        BackgroundSyncTrigger.appRefresh,
        refreshRequest: request,
      );
    } finally {
      // A warm-runtime refresh can be delivered while already foregrounded,
      // without a matching lifecycle transition. Never leave resident-watch
      // restoration disabled after such a delivery.
      if (!_disposed &&
          _lifecycleMode == _BackgroundSyncLifecycleMode.foreground) {
        await _setAutomaticWatchRestorationEnabled(true);
      }
    }
  }

  Future<bool> synchronize(
    BackgroundSyncTrigger trigger, {
    BackgroundRefreshRequest? refreshRequest,
  }) {
    return _synchronize(trigger, refreshRequest: refreshRequest);
  }

  Future<bool> _synchronize(
    BackgroundSyncTrigger trigger, {
    BackgroundRefreshRequest? refreshRequest,
    _SyncCancellationToken? cancellation,
  }) {
    if (_disposed) return Future.value(false);
    final completer = Completer<bool>();
    _syncTail = _syncTail.catchError((Object _, StackTrace _) {}).then((
      _,
    ) async {
      try {
        if (_isCancelled(refreshRequest, cancellation)) {
          if (!completer.isCompleted) completer.complete(false);
          return;
        }
        final result = await _runSynchronization(
          trigger,
          refreshRequest: refreshRequest,
          cancellation: cancellation,
        );
        if (!completer.isCompleted) completer.complete(result);
      } catch (_) {
        if (!completer.isCompleted) completer.complete(false);
      }
    });
    return completer.future;
  }

  Future<bool> _runSynchronization(
    BackgroundSyncTrigger trigger, {
    BackgroundRefreshRequest? refreshRequest,
    _SyncCancellationToken? cancellation,
  }) async {
    final allowConnectionRebuild = trigger == BackgroundSyncTrigger.resumed;
    if (!await _connectAndRefreshSessionList(
      allowConnectionRebuild: allowConnectionRebuild,
      refreshRequest: refreshRequest,
      cancellation: cancellation,
    )) {
      return false;
    }
    if (_isCancelled(refreshRequest, cancellation)) return false;

    final foreground = trigger == BackgroundSyncTrigger.resumed;
    final sessionIds = _bridge.activeSessionIds.toSet();
    final historyReconciliation = _requestSessionHistories(
      sessionIds,
      foreground: foreground,
      refreshRequest: refreshRequest,
      cancellation: cancellation,
    );

    final mirrorBudget = _boundedMirrorBudget(
      foreground: foreground,
      request: refreshRequest,
    );
    if (mirrorBudget > Duration.zero) {
      final mirrorCancellation = _CombinedMirrorCancellation(
        refreshRequest: refreshRequest,
        continuationCancellation: cancellation,
        isCoordinatorDisposed: () => _disposed,
      );
      await _mirror.reconcileResidents(
        maximumConversations: foreground ? 8 : 2,
        budget: mirrorBudget,
        restoreMissingWatches: foreground,
        cancellation: mirrorCancellation,
      );
    }
    if (_isCancelled(refreshRequest, cancellation)) return false;
    final historiesComplete = await historyReconciliation;
    return historiesComplete && !_isCancelled(refreshRequest, cancellation);
  }

  Future<bool> _requestSessionHistories(
    Set<String> sessionIds, {
    required bool foreground,
    BackgroundRefreshRequest? refreshRequest,
    _SyncCancellationToken? cancellation,
  }) async {
    final pending = sessionIds
        .where(
          (sessionId) =>
              foreground || _bridge.hasCachedSessionHistory(sessionId),
        )
        .toSet();
    if (pending.isEmpty) return true;
    final previousGenerations = <String, int>{
      for (final sessionId in pending)
        sessionId: _bridge.sessionHistoryReconciliationGeneration(sessionId),
    };
    return _waitForStreamCondition<String>(
      stream: _bridge.sessionHistoryReconciliations,
      timeout: _boundedTimeout(_historyResponseTimeout, refreshRequest),
      refreshRequest: refreshRequest,
      cancellation: cancellation,
      condition: (sessionId) {
        final previous = previousGenerations[sessionId];
        if (previous == null ||
            _bridge.sessionHistoryReconciliationGeneration(sessionId) <=
                previous) {
          return false;
        }
        pending.remove(sessionId);
        return pending.isEmpty;
      },
      onReady: () {
        for (final sessionId in List<String>.from(pending)) {
          if (_isCancelled(refreshRequest, cancellation)) return;
          _bridge.requestSessionHistory(
            sessionId,
            allowFullFallback: foreground,
          );
        }
      },
    );
  }

  Future<void> _trackActiveBackgroundTurn({
    required DateTime deadline,
    required _SyncCancellationToken cancellation,
  }) async {
    if (_continuationTrackingWindow <= Duration.zero ||
        _continuationTrackingPoll <= Duration.zero) {
      return;
    }
    while (_lifecycleMode == _BackgroundSyncLifecycleMode.background &&
        _bridge.hasBackgroundWork &&
        !_isCancelled(null, cancellation)) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return;
      final delay = remaining < _continuationTrackingPoll
          ? remaining
          : _continuationTrackingPoll;
      if (!await _waitForCancellationAwareDelay(delay, cancellation)) return;
    }
  }

  Future<bool> _waitForCancellationAwareDelay(
    Duration duration,
    _SyncCancellationToken cancellation,
  ) async {
    if (_isCancelled(null, cancellation)) return false;
    final completed = Completer<bool>();
    Timer? timer;

    void complete(bool value) {
      if (!completed.isCompleted) completed.complete(value);
    }

    void cancelWait() => complete(false);
    cancellation.addListener(cancelWait);
    try {
      if (completed.isCompleted) return false;
      timer = Timer(duration, () => complete(true));
      return await completed.future;
    } finally {
      timer?.cancel();
      cancellation.removeListener(cancelWait);
    }
  }

  Duration _boundedMirrorBudget({
    required bool foreground,
    BackgroundRefreshRequest? request,
  }) {
    final defaultBudget = foreground
        ? const Duration(seconds: 12)
        : const Duration(seconds: 8);
    if (request == null) return defaultBudget;
    final remaining = request.remaining - const Duration(seconds: 2);
    if (remaining <= Duration.zero) return Duration.zero;
    return remaining < defaultBudget ? remaining : defaultBudget;
  }

  Future<bool> _connectAndRefreshSessionList({
    required bool allowConnectionRebuild,
    BackgroundRefreshRequest? refreshRequest,
    _SyncCancellationToken? cancellation,
  }) async {
    if (!await _ensureConnected(refreshRequest, cancellation)) return false;
    if (await _requestFreshSessionList(refreshRequest, cancellation)) {
      return true;
    }
    if (!allowConnectionRebuild || _isCancelled(refreshRequest, cancellation)) {
      return false;
    }
    final rebuilt = await _bridge.rebuildConnection();
    if (!rebuilt || !await _ensureConnected(refreshRequest, cancellation)) {
      return false;
    }
    return _requestFreshSessionList(refreshRequest, cancellation);
  }

  Future<bool> _ensureConnected(
    BackgroundRefreshRequest? request,
    _SyncCancellationToken? cancellation,
  ) async {
    if (_bridge.isConnected) {
      _bridge.ensureConnected();
      if (_bridge.isConnected) return true;
    }
    return _waitForStreamCondition<BridgeConnectionState>(
      stream: _bridge.connectionStates,
      condition: (state) =>
          state == BridgeConnectionState.connected && _bridge.isConnected,
      timeout: _boundedTimeout(_connectionTimeout, request),
      refreshRequest: request,
      cancellation: cancellation,
      onReady: _bridge.ensureConnected,
    );
  }

  Future<bool> _requestFreshSessionList(
    BackgroundRefreshRequest? request,
    _SyncCancellationToken? cancellation,
  ) {
    final previousGeneration = _bridge.authoritativeSessionListGeneration;
    return _waitForStreamCondition<void>(
      stream: _bridge.sessionListChanges,
      condition: (_) =>
          _bridge.hasAuthoritativeSessionList &&
          _bridge.authoritativeSessionListGeneration > previousGeneration,
      timeout: _boundedTimeout(_sessionListTimeout, request),
      refreshRequest: request,
      cancellation: cancellation,
      onReady: _bridge.requestSessionList,
    );
  }

  Future<bool> _waitForStreamCondition<T>({
    required Stream<T> stream,
    required bool Function(T event) condition,
    required Duration timeout,
    required void Function() onReady,
    BackgroundRefreshRequest? refreshRequest,
    _SyncCancellationToken? cancellation,
  }) async {
    if (_isCancelled(null, cancellation)) return false;
    final completed = Completer<bool>();
    Timer? timer;
    StreamSubscription<T>? subscription;

    void complete(bool value) {
      if (!completed.isCompleted) completed.complete(value);
    }

    void cancelWait() => complete(false);
    cancellation?.addListener(cancelWait);
    refreshRequest?.addExpirationListener(cancelWait);
    try {
      if (completed.isCompleted) return false;
      subscription = stream.listen(
        (event) {
          if (condition(event)) complete(true);
        },
        onError: (Object _, StackTrace _) => complete(false),
        onDone: () => complete(false),
      );
      timer = Timer(timeout, () => complete(false));
      if (completed.isCompleted) return false;
      onReady();
      if (_isCancelled(null, cancellation)) complete(false);
      return await completed.future;
    } catch (_) {
      return false;
    } finally {
      timer?.cancel();
      cancellation?.removeListener(cancelWait);
      refreshRequest?.removeExpirationListener(cancelWait);
      await subscription?.cancel();
    }
  }

  bool _isCancelled(
    BackgroundRefreshRequest? refreshRequest,
    _SyncCancellationToken? cancellation,
  ) {
    return _disposed ||
        refreshRequest?.isExpired == true ||
        cancellation?.isCancelled == true;
  }

  Future<void> _setAutomaticWatchRestorationEnabled(bool enabled) async {
    try {
      await _mirror.setAutomaticWatchRestorationEnabled(enabled);
    } catch (_) {
      // The canonical Bridge history path remains usable if the optional
      // resident mirror store is unavailable.
    }
  }

  void _handleContinuationExpired(int generation) {
    if (_activeContinuationGeneration != generation) return;
    _activeContinuationCancellation?.cancel();
  }

  Duration _boundedTimeout(
    Duration preferred,
    BackgroundRefreshRequest? request,
  ) {
    if (request == null) return preferred;
    final remaining = request.remaining - const Duration(milliseconds: 500);
    if (remaining <= Duration.zero) return const Duration(milliseconds: 1);
    return remaining < preferred ? remaining : preferred;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _host.setRefreshHandler(null);
    _host.setContinuationExpirationHandler(null);
    _lifecycleCancellation?.cancel();
    _lifecycleCancellation = null;
    final continuation = _takeActiveContinuation();
    await _endContinuation(continuation);
    await _host.dispose();
  }

  @visibleForTesting
  int? get activeContinuationGeneration => _activeContinuationGeneration;
}

enum _BackgroundSyncLifecycleMode { unknown, foreground, background }

class _ContinuationLease {
  const _ContinuationLease(this.generation);

  final int generation;
}

class _SyncCancellationToken {
  final Set<VoidCallback> _listeners = {};
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void addListener(VoidCallback listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<VoidCallback>.from(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

class _CombinedMirrorCancellation implements ConversationMirrorCancellation {
  _CombinedMirrorCancellation({
    required BackgroundRefreshRequest? refreshRequest,
    required _SyncCancellationToken? continuationCancellation,
    required bool Function() isCoordinatorDisposed,
  }) : _refreshRequest = refreshRequest,
       _continuationCancellation = continuationCancellation,
       _isCoordinatorDisposed = isCoordinatorDisposed;

  final BackgroundRefreshRequest? _refreshRequest;
  final _SyncCancellationToken? _continuationCancellation;
  final bool Function() _isCoordinatorDisposed;

  @override
  bool get isCancelled =>
      _isCoordinatorDisposed() ||
      _refreshRequest?.isExpired == true ||
      _continuationCancellation?.isCancelled == true;

  @override
  void addListener(VoidCallback listener) {
    _refreshRequest?.addExpirationListener(listener);
    _continuationCancellation?.addListener(listener);
    if (isCancelled) listener();
  }

  @override
  void removeListener(VoidCallback listener) {
    _refreshRequest?.removeExpirationListener(listener);
    _continuationCancellation?.removeListener(listener);
  }
}
