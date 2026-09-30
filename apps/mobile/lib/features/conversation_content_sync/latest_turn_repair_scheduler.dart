import 'dart:async';

import 'conversation_sync_trace.dart';

/// Facts observed by the host. The scheduler never reads or writes history.
class LatestTurnRepairRequest {
  const LatestTurnRepairRequest({
    required this.generation,
    required this.targetFingerprint,
    required this.provider,
    required this.providerSessionId,
    required this.revision,
    required this.observation,
    required this.repair,
    this.turnId,
  });

  final int generation;
  final String targetFingerprint;
  final String provider;
  final String providerSessionId;
  final String revision;
  final String observation;
  final String repair;
  final String? turnId;

  String get _targetKey =>
      '$targetFingerprint\u0000$provider\u0000$providerSessionId';
  String get _operationKey =>
      '$_targetKey\u0000$revision\u0000${turnId ?? ''}\u0000$repair';
}

typedef LatestTurnRepairOutcome = ({
  bool loaded,
  bool hasMore,
  String? repairObservation,
});

/// Owns only automatic repair scheduling, including every retry and cancel.
///
/// The host owns focus/source/generation, observes the committed cache, and
/// executes repairs through its existing serialized request/write path.
class LatestTurnRepairScheduler {
  LatestTurnRepairScheduler({
    required this.isCurrent,
    required this.repair,
    required this.recheck,
  });

  static const _maximumFailures = 4;
  static const _maximumRememberedObservations = 128;
  final bool Function(LatestTurnRepairRequest request) isCurrent;
  final Future<LatestTurnRepairOutcome> Function(
    LatestTurnRepairRequest request,
  )
  repair;
  final void Function(LatestTurnRepairRequest request) recheck;
  final Map<String, _RepairState> _states = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, String> _completedSummaryObservations = {};

  /// Includes exhausted/backing-off operations, matching the host diagnostic.
  int get pendingCount => _states.length;

  void schedule(LatestTurnRepairRequest request) {
    if (!isCurrent(request)) return;
    final key = request._operationKey;
    if (request.repair == 'turns_page' &&
        _completedSummaryObservations[request._targetKey] ==
            request.observation) {
      return;
    }
    final previous = _states[key];
    if (previous?.running == true) {
      if (previous!.observation != request.observation) {
        _states[key] = previous.copyWith(
          dirty: true,
          observation: request.observation,
        );
      }
      return;
    }
    if ((previous?.failureCount ?? 0) >= _maximumFailures) return;
    if (previous?.nextRetryAt case final nextRetryAt?
        when DateTime.now().isBefore(nextRetryAt)) {
      return;
    }
    final operationToken = Object();
    _states[key] = _RepairState(
      running: true,
      dirty: false,
      observation: request.observation,
      operationToken: operationToken,
      failureCount: previous?.failureCount ?? 0,
    );
    bool ownsOperation() =>
        identical(_states[key]?.operationToken, operationToken) &&
        isCurrent(request);
    conversationSyncTrace(
      '[conversation_sync_v2] event=latest_turn_auto_repair_scheduled '
      'target=${conversationSyncTargetTrace(request.provider, request.providerSessionId)} '
      'content=${shortConversationSyncToken(request.revision)} repair=${request.repair}',
    );
    scheduleMicrotask(() {
      if (!ownsOperation()) return;
      unawaited(
        repair(request)
            .then((result) {
              if (!ownsOperation()) return;
              conversationSyncTrace(
                '[conversation_sync_v2] event=latest_turn_auto_repair_complete '
                'target=${conversationSyncTargetTrace(request.provider, request.providerSessionId)} '
                'loaded=${result.loaded} hasMore=${result.hasMore}',
              );
              final state = _states.remove(key);
              _retryTimers.remove(key)?.cancel();
              if (request.repair == 'turns_page' &&
                  result.loaded &&
                  state?.dirty != true &&
                  result.repairObservation != null) {
                _rememberSummaryObservation(
                  request._targetKey,
                  result.repairObservation!,
                );
              }
              if (state?.dirty == true) recheck(request);
            })
            .catchError((Object error) {
              if (!ownsOperation()) return;
              conversationSyncTrace(
                '[conversation_sync_v2] event=latest_turn_auto_repair_failed '
                'target=${conversationSyncTargetTrace(request.provider, request.providerSessionId)} '
                'error=${error.runtimeType}',
                warning: true,
              );
              final state = _states[key];
              if (state == null) return;
              final failureCount = (state.failureCount + 1).clamp(
                1,
                _maximumFailures,
              );
              final retryDelay = Duration(seconds: 1 << (failureCount - 1));
              _states[key] = _RepairState(
                running: false,
                dirty: state.dirty,
                observation: state.observation,
                operationToken: operationToken,
                failureCount: failureCount,
                nextRetryAt: DateTime.now().add(retryDelay),
              );
              _retryTimers.remove(key)?.cancel();
              if (failureCount < _maximumFailures) {
                _retryTimers[key] = Timer(retryDelay, () {
                  if (!ownsOperation()) return;
                  _retryTimers.remove(key);
                  final retryState = _states[key];
                  if (retryState == null || retryState.running) return;
                  _states[key] = _RepairState(
                    running: false,
                    dirty: retryState.dirty,
                    observation: retryState.observation,
                    operationToken: operationToken,
                    failureCount: retryState.failureCount,
                  );
                  recheck(request);
                });
              }
            }),
      );
    });
  }

  void _rememberSummaryObservation(String targetKey, String observation) {
    _completedSummaryObservations
      ..remove(targetKey)
      ..[targetKey] = observation;
    while (_completedSummaryObservations.length >
        _maximumRememberedObservations) {
      _completedSummaryObservations.remove(
        _completedSummaryObservations.keys.first,
      );
    }
  }

  void clearTarget({
    required String targetFingerprint,
    required String provider,
    required String providerSessionId,
  }) {
    final targetKey =
        '$targetFingerprint\u0000$provider\u0000$providerSessionId';
    final prefix = '$targetKey\u0000';
    final keys = _states.keys
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
    for (final key in keys) {
      _retryTimers.remove(key)?.cancel();
      _states.remove(key);
    }
    _completedSummaryObservations.remove(targetKey);
  }

  void clearAll() {
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _states.clear();
    _completedSummaryObservations.clear();
  }
}

class _RepairState {
  const _RepairState({
    required this.running,
    required this.dirty,
    required this.observation,
    required this.operationToken,
    required this.failureCount,
    this.nextRetryAt,
  });

  final bool running;
  final bool dirty;
  final String observation;
  final Object operationToken;
  final int failureCount;
  final DateTime? nextRetryAt;

  _RepairState copyWith({bool? dirty, String? observation}) => _RepairState(
    running: running,
    dirty: dirty ?? this.dirty,
    observation: observation ?? this.observation,
    operationToken: operationToken,
    failureCount: failureCount,
    nextRetryAt: nextRetryAt,
  );
}
