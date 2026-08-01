import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/logger.dart';
import '../features/codex_action_broker/codex_action_broker_service.dart';
import '../models/bridge_data_source_identity.dart';
import '../models/messages.dart';
import 'bridge_service.dart';

enum NotificationApprovalDecision { approve, reject }

enum NotificationApprovalQueueState { queued, awaitingCanonical }

/// Whether a notification decision may enter the durable revalidation queue.
///
/// A shared-runtime Codex v2 action carries the complete Action Broker fence,
/// so a cold-started app may persist it before Bridge authentication and wait
/// for the coordinator to revalidate the exact source/request/generation. Once
/// Mobile has an authoritative identity, a mismatch is final. Legacy actions
/// do not carry that durable fence and therefore keep the original fail-closed
/// source check even while disconnected.
bool shouldQueueNotificationApprovalAction({
  required int actionPayloadVersion,
  required String provider,
  required BridgeDataSourceIdentity expected,
  required BridgeDataSourceIdentity current,
  required bool currentIdentityAuthoritative,
}) {
  if (expected.isSatisfiedBy(current, provider: provider)) return true;
  return actionPayloadVersion == 2 && !currentIdentityAuthoritative;
}

typedef NotificationApprovalIdFactory = String Function();

abstract interface class NotificationApprovalBridge {
  bool get isConnected;
  bool get hasAuthoritativeSessionListForCurrentConnection;
  List<SessionInfo> get sessions;
  Stream<List<SessionInfo>> get sessionList;
  Stream<BridgeConnectionState> get connectionStatus;

  void send(ClientMessage message);
  void markToolUseResponded(String sessionId, String toolUseId);
  void clearSessionPermission(String sessionId);
}

class BridgeServiceNotificationApprovalBridge
    implements NotificationApprovalBridge {
  const BridgeServiceNotificationApprovalBridge(this.bridge);

  final BridgeService bridge;

  @override
  bool get isConnected => bridge.isConnected;

  @override
  bool get hasAuthoritativeSessionListForCurrentConnection =>
      bridge.hasAuthoritativeSessionListForCurrentConnection;

  @override
  List<SessionInfo> get sessions => bridge.sessions;

  @override
  Stream<List<SessionInfo>> get sessionList => bridge.sessionList;

  @override
  Stream<BridgeConnectionState> get connectionStatus => bridge.connectionStatus;

  @override
  void send(ClientMessage message) => bridge.send(message);

  @override
  void markToolUseResponded(String sessionId, String toolUseId) =>
      bridge.markToolUseResponded(sessionId, toolUseId);

  @override
  void clearSessionPermission(String sessionId) =>
      bridge.clearSessionPermission(sessionId);
}

/// One user decision captured from a local or remote notification.
///
/// Version 1 is the established private-runtime/Claude path and carries an
/// opaque legacy permission ID. Version 2 is exclusively for the shared Codex
/// Action Broker and carries the complete broker fence. A v2 request is never
/// downgraded to an `approve` / `reject` ClientMessage.
class NotificationApprovalRequest {
  const NotificationApprovalRequest({
    required this.sessionId,
    required this.provider,
    required this.permissionId,
    required this.decision,
    required this.createdAt,
    this.providerSessionId,
    this.actionPayloadVersion = 1,
    this.bridgeInstanceId,
    this.codexSourceId,
    this.threadId,
    this.turnId,
    this.authorityGeneration,
    this.allowedActions = const {},
    this.operationId,
    this.queueState = NotificationApprovalQueueState.queued,
  });

  final String sessionId;
  final String provider;
  final String? providerSessionId;
  final String permissionId;
  final NotificationApprovalDecision decision;
  final DateTime createdAt;

  final int actionPayloadVersion;
  final String? bridgeInstanceId;
  final String? codexSourceId;
  final String? threadId;
  final String? turnId;
  final String? authorityGeneration;
  final Set<CodexActionBrokerDecision> allowedActions;
  final String? operationId;
  final NotificationApprovalQueueState queueState;

  bool get usesCodexActionBroker => actionPayloadVersion == 2;
  String get opaqueRequestId => permissionId;

  CodexActionBrokerDecision get brokerDecision =>
      decision == NotificationApprovalDecision.approve
      ? CodexActionBrokerDecision.approve
      : CodexActionBrokerDecision.reject;

  String get identity => usesCodexActionBroker
      ? 'cab:${bridgeInstanceId ?? ''}:${codexSourceId ?? ''}:'
            '${threadId ?? ''}:${turnId ?? ''}:$permissionId:'
            '${authorityGeneration ?? ''}'
      : '$provider:${providerSessionId ?? sessionId}:$permissionId';

  NotificationApprovalRequest copyWith({
    String? operationId,
    NotificationApprovalQueueState? queueState,
  }) => NotificationApprovalRequest(
    sessionId: sessionId,
    provider: provider,
    providerSessionId: providerSessionId,
    permissionId: permissionId,
    decision: decision,
    createdAt: createdAt,
    actionPayloadVersion: actionPayloadVersion,
    bridgeInstanceId: bridgeInstanceId,
    codexSourceId: codexSourceId,
    threadId: threadId,
    turnId: turnId,
    authorityGeneration: authorityGeneration,
    allowedActions: allowedActions,
    operationId: operationId ?? this.operationId,
    queueState: queueState ?? this.queueState,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (usesCodexActionBroker) 'actionPayloadVersion': 2,
    'sessionId': sessionId,
    'provider': provider,
    'providerSessionId': ?providerSessionId,
    'permissionId': permissionId,
    'decision': decision.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (usesCodexActionBroker) ...<String, dynamic>{
      'bridgeInstanceId': bridgeInstanceId,
      'codexSourceId': codexSourceId,
      'threadId': threadId,
      'turnId': turnId,
      'authorityGeneration': authorityGeneration,
      'allowedActions':
          allowedActions.map((action) => action.wireValue).toList()..sort(),
      'operationId': operationId,
      'queueState': queueState.name,
    },
  };

  static NotificationApprovalRequest? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<Object?, Object?>.from(value);
    final rawActionPayloadVersion = json['actionPayloadVersion'];
    if (rawActionPayloadVersion != null &&
        rawActionPayloadVersion != 1 &&
        rawActionPayloadVersion != 2) {
      return null;
    }
    final actionPayloadVersion = rawActionPayloadVersion == 2 ? 2 : 1;
    final sessionId = _jsonString(json['sessionId']) ?? '';
    final provider = _jsonString(json['provider']) ?? '';
    final providerSessionId = _jsonString(json['providerSessionId']);
    final permissionId = _jsonString(json['permissionId']) ?? '';
    final createdAt = DateTime.tryParse(_jsonString(json['createdAt']) ?? '');
    final decision = switch (json['decision']) {
      'approve' => NotificationApprovalDecision.approve,
      'reject' => NotificationApprovalDecision.reject,
      _ => null,
    };
    if (createdAt == null || decision == null) return null;

    final allowedActions = <CodexActionBrokerDecision>{};
    final rawAllowedActions = json['allowedActions'];
    if (actionPayloadVersion == 2) {
      if (rawAllowedActions is! List || rawAllowedActions.length > 4) {
        return null;
      }
      for (final rawAction in rawAllowedActions) {
        final action = CodexActionBrokerDecision.tryParse(rawAction);
        if (action == null) return null;
        allowedActions.add(action);
      }
    }

    final request = NotificationApprovalRequest(
      sessionId: sessionId,
      provider: provider,
      providerSessionId: providerSessionId?.isNotEmpty == true
          ? providerSessionId
          : null,
      permissionId: permissionId,
      decision: decision,
      createdAt: createdAt.toUtc(),
      actionPayloadVersion: actionPayloadVersion,
      bridgeInstanceId: _jsonString(json['bridgeInstanceId']),
      codexSourceId: _jsonString(json['codexSourceId']),
      threadId: _jsonString(json['threadId']),
      turnId: _jsonString(json['turnId']),
      authorityGeneration: _jsonString(json['authorityGeneration']),
      allowedActions: Set.unmodifiable(allowedActions),
      operationId: _jsonString(json['operationId']),
      queueState: json['queueState'] == 'awaitingCanonical'
          ? NotificationApprovalQueueState.awaitingCanonical
          : NotificationApprovalQueueState.queued,
    );
    return request.isValid ? request : null;
  }

  bool get isValid {
    final commonValid =
        sessionId.isNotEmpty &&
        sessionId.length <= 256 &&
        (provider == 'claude' || provider == 'codex') &&
        permissionId.isNotEmpty &&
        permissionId.length <= 256 &&
        (providerSessionId == null || providerSessionId!.length <= 256) &&
        createdAt.isUtc;
    if (!commonValid) return false;
    if (!usesCodexActionBroker) return actionPayloadVersion == 1;
    return provider == 'codex' &&
        _boundedIdentity(bridgeInstanceId, 256) &&
        _boundedIdentity(codexSourceId, 128) &&
        _boundedIdentity(threadId, 256) &&
        _boundedIdentity(turnId, 256) &&
        _boundedIdentity(authorityGeneration, 64) &&
        _boundedIdentity(operationId, 256) &&
        allowedActions.isNotEmpty &&
        allowedActions.contains(brokerDecision);
  }

  static bool _boundedIdentity(String? value, int maximumLength) =>
      value != null && value.isNotEmpty && value.length <= maximumLength;
}

String? _jsonString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

/// Revalidates notification actions against the authoritative pending ledger.
///
/// Legacy Claude/private-Codex actions retain their session snapshot path.
/// Shared-runtime Codex actions are processed only through the existing Action
/// Broker service and its source/live/turn/generation/writer-lease fences.
class NotificationApprovalCoordinator {
  factory NotificationApprovalCoordinator({
    required SharedPreferences preferences,
    required NotificationApprovalBridge bridge,
    BridgeService? codexBridge,
    NotificationApprovalIdFactory? createId,
  }) => NotificationApprovalCoordinator._(
    preferences,
    bridge,
    codexBridge ??
        (bridge is BridgeServiceNotificationApprovalBridge
            ? bridge.bridge
            : null),
    createId ?? const Uuid().v4,
  );

  NotificationApprovalCoordinator._(
    this._preferences,
    this._bridge,
    this._codexBridge,
    this._createId,
  );

  static const _legacyPreferenceKey = 'notification_approval_queue_v1';
  static const _preferenceKey = 'notification_approval_queue_v2';
  static const _maxPending = 8;
  static const _maxAge = Duration(minutes: 10);

  final SharedPreferences _preferences;
  final NotificationApprovalBridge _bridge;
  final BridgeService? _codexBridge;
  final NotificationApprovalIdFactory _createId;
  final List<NotificationApprovalRequest> _pending = [];
  final Map<String, _CodexNotificationActionAttempt> _brokerAttempts = {};
  StreamSubscription<List<SessionInfo>>? _sessionSub;
  StreamSubscription<BridgeConnectionState>? _connectionSub;
  Future<void> _persistChain = Future<void>.value();
  Future<void>? _disposeFuture;
  Timer? _retryTimer;
  bool _initialized = false;
  bool _disposed = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    for (final key in const [_legacyPreferenceKey, _preferenceKey]) {
      final raw = _preferences.getString(key);
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            final request = NotificationApprovalRequest.fromJson(item);
            if (request != null &&
                !_isExpired(request) &&
                !_isTooFarInFuture(request)) {
              _pending.removeWhere(
                (existing) => existing.identity == request.identity,
              );
              _pending.add(request);
            }
          }
        }
      } catch (error, stackTrace) {
        logger.warning(
          '[notifications] invalid persisted approval action',
          error,
          stackTrace,
        );
      }
    }
    if (_pending.length > _maxPending) {
      _pending.removeRange(0, _pending.length - _maxPending);
    }
    await _persist();
    _sessionSub = _bridge.sessionList.listen((_) => _drain());
    _connectionSub = _bridge.connectionStatus.listen((_) => _drain());
    _drain();
  }

  Future<void> submit(NotificationApprovalRequest request) async {
    if (!_initialized) await initialize();
    final existing = request.usesCodexActionBroker
        ? _pending
              .where((item) => item.identity == request.identity)
              .firstOrNull
        : null;
    if (existing != null &&
        (existing.queueState ==
                NotificationApprovalQueueState.awaitingCanonical ||
            existing.decision == request.decision)) {
      // A notification action can arrive through both the native host and the
      // Flutter callback, or be replayed when Dart becomes ready. Preserve the
      // original operation ID and never turn an uncertain/submitted CAB write
      // back into a replayable queued action.
      return;
    }
    var normalized = request;
    if (request.usesCodexActionBroker && request.operationId == null) {
      normalized = request.copyWith(operationId: _createId());
    }
    if (!normalized.isValid ||
        _isExpired(normalized) ||
        _isTooFarInFuture(normalized)) {
      return;
    }
    _removeByIdentity(normalized.identity);
    _pending.add(normalized);
    if (_pending.length > _maxPending) {
      final removed = _pending.sublist(0, _pending.length - _maxPending);
      _pending.removeRange(0, _pending.length - _maxPending);
      for (final item in removed) {
        _disposeBrokerAttempt(item.identity);
      }
    }
    await _persist();
    _drain();
  }

  void _drain() {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    final expired = _pending
        .where((request) => _isExpired(request) || _isTooFarInFuture(request))
        .map((request) => request.identity)
        .toList(growable: false);
    for (final identity in expired) {
      _removeByIdentity(identity);
    }
    var changed = expired.isNotEmpty;

    for (final request in List<NotificationApprovalRequest>.of(_pending)) {
      if (request.usesCodexActionBroker) {
        _ensureBrokerAttempt(request);
      }
    }

    final legacy = _pending
        .where((request) => !request.usesCodexActionBroker)
        .toList(growable: false);
    if (!_bridge.isConnected ||
        !_bridge.hasAuthoritativeSessionListForCurrentConnection) {
      if (changed) unawaited(_persist());
      if (legacy.isNotEmpty && _bridge.isConnected) {
        _retryTimer = Timer(const Duration(seconds: 1), _drain);
      }
      return;
    }

    var retryAfterSendFailure = false;
    for (final request in legacy) {
      final session = _matchingSession(request);
      if (session == null) continue;
      try {
        final message = request.decision == NotificationApprovalDecision.approve
            ? ClientMessage.approveLiveOnly(
                request.permissionId,
                sessionId: session.id,
              )
            : ClientMessage.rejectLiveOnly(
                request.permissionId,
                sessionId: session.id,
              );
        _bridge.send(message);
        _bridge.markToolUseResponded(session.id, request.permissionId);
        _bridge.clearSessionPermission(session.id);
        _removeByIdentity(request.identity);
        changed = true;
      } catch (error, stackTrace) {
        logger.warning(
          '[notifications] approval action send failed',
          error,
          stackTrace,
        );
        retryAfterSendFailure = true;
      }
    }
    if (changed) unawaited(_persist());
    if (legacy.isNotEmpty && retryAfterSendFailure) {
      _retryTimer = Timer(const Duration(seconds: 1), _drain);
    }
  }

  void _ensureBrokerAttempt(NotificationApprovalRequest request) {
    final bridge = _codexBridge;
    if (bridge == null || _brokerAttempts.containsKey(request.identity)) return;
    final service = CodexActionBrokerService(
      bridge: bridge,
      threadId: request.threadId!,
      expectedBridgeInstanceId: request.bridgeInstanceId,
      expectedCodexSourceId: request.codexSourceId,
      runtimeFence: () => CodexActionBrokerRuntimeFence(
        turnId: request.turnId,
        authorityGeneration: request.authorityGeneration,
        executionHost: 'desktopAppServer',
      ),
    );
    late final _CodexNotificationActionAttempt attempt;
    void listener() => _scheduleBrokerEvaluation(attempt);
    attempt = _CodexNotificationActionAttempt(
      requestIdentity: request.identity,
      service: service,
      listener: listener,
    );
    _brokerAttempts[request.identity] = attempt;
    service.addListener(listener);
    service.start();
    _scheduleBrokerEvaluation(attempt);
  }

  void _scheduleBrokerEvaluation(_CodexNotificationActionAttempt attempt) {
    if (_disposed || attempt.scheduled || attempt.disposed) return;
    attempt.scheduled = true;
    scheduleMicrotask(() async {
      attempt.scheduled = false;
      await _evaluateBrokerAttempt(attempt);
    });
  }

  Future<void> _evaluateBrokerAttempt(
    _CodexNotificationActionAttempt attempt,
  ) async {
    if (_disposed || attempt.disposed || attempt.inFlight) return;
    NotificationApprovalRequest? request;
    for (final item in _pending) {
      if (item.identity == attempt.requestIdentity) {
        request = item;
        break;
      }
    }
    if (request == null || !request.usesCodexActionBroker) {
      _disposeBrokerAttempt(attempt.requestIdentity);
      return;
    }
    final service = attempt.service;
    if (!service.authenticatedSourceMatches) return;
    final exact = service.requestByOpaqueId(request.opaqueRequestId);

    if (request.queueState ==
        NotificationApprovalQueueState.awaitingCanonical) {
      if (service.snapshotObserved && exact == null) {
        _removeAndPersist(request.identity);
      }
      return;
    }

    switch (service.lastOutcome) {
      case CodexActionBrokerResponseOutcome.submitted:
      case CodexActionBrokerResponseOutcome.outcomeUnknown:
        _replaceAndPersist(
          request.copyWith(
            queueState: NotificationApprovalQueueState.awaitingCanonical,
          ),
        );
        return;
      case CodexActionBrokerResponseOutcome.alreadyResolved:
      case CodexActionBrokerResponseOutcome.contended:
      case CodexActionBrokerResponseOutcome.expired:
      case CodexActionBrokerResponseOutcome.staleGeneration:
      case CodexActionBrokerResponseOutcome.invalid:
        _removeAndPersist(request.identity);
        return;
      case CodexActionBrokerResponseOutcome.unavailable:
        if (attempt.lastRefreshViewEpoch != service.viewEpoch) {
          attempt.lastRefreshViewEpoch = service.viewEpoch;
          service.refresh();
        }
        return;
      case null:
        break;
    }

    if (exact == null) {
      if (service.snapshotObserved) _removeAndPersist(request.identity);
      return;
    }
    if (!_matchesExactBrokerFence(request, exact)) {
      _removeAndPersist(request.identity);
      return;
    }

    switch (service.phase) {
      case CodexActionBrokerInteractionPhase.actionable:
        break;
      case CodexActionBrokerInteractionPhase.handledElsewhere:
        _replaceAndPersist(
          request.copyWith(
            queueState: NotificationApprovalQueueState.awaitingCanonical,
          ),
        );
        return;
      case CodexActionBrokerInteractionPhase.stale:
      case CodexActionBrokerInteractionPhase.invalid:
        _removeAndPersist(request.identity);
        return;
      case CodexActionBrokerInteractionPhase.unavailable:
        if (attempt.lastRefreshViewEpoch != service.viewEpoch) {
          attempt.lastRefreshViewEpoch = service.viewEpoch;
          service.refresh();
        }
        return;
      case CodexActionBrokerInteractionPhase.inactive:
      case CodexActionBrokerInteractionPhase.loading:
      case CodexActionBrokerInteractionPhase.submitting:
      case CodexActionBrokerInteractionPhase.awaitingCanonical:
      case CodexActionBrokerInteractionPhase.reconnecting:
      case CodexActionBrokerInteractionPhase.writerLeaseUnavailable:
      case CodexActionBrokerInteractionPhase.unsupportedRequest:
        return;
    }

    if (attempt.lastAttemptSnapshotEpoch == service.snapshotEpoch) return;
    attempt.lastAttemptSnapshotEpoch = service.snapshotEpoch;
    attempt.inFlight = true;
    try {
      await service.respond(
        request.brokerDecision,
        opaqueRequestId: request.opaqueRequestId,
        operationId: request.operationId,
      );
    } catch (error, stackTrace) {
      logger.warning(
        '[notifications] Codex action broker submission failed',
        error,
        stackTrace,
      );
    } finally {
      attempt.inFlight = false;
      _scheduleBrokerEvaluation(attempt);
    }
  }

  bool _matchesExactBrokerFence(
    NotificationApprovalRequest queued,
    CodexActionBrokerRequest live,
  ) =>
      live.opaqueRequestId == queued.opaqueRequestId &&
      live.codexSourceId == queued.codexSourceId &&
      live.threadId == queued.threadId &&
      live.turnId == queued.turnId &&
      live.authorityGeneration == queued.authorityGeneration &&
      live.live &&
      live.state == CodexActionBrokerRequestState.pending &&
      _sameActions(live.allowedActions, queued.allowedActions) &&
      live.allowedActions.contains(queued.brokerDecision);

  static bool _sameActions(
    Set<CodexActionBrokerDecision> left,
    Set<CodexActionBrokerDecision> right,
  ) => left.length == right.length && left.containsAll(right);

  SessionInfo? _matchingSession(NotificationApprovalRequest request) {
    final matches = _bridge.sessions
        .where((session) {
          final pending = session.pendingPermission;
          if (pending?.toolUseId != request.permissionId) return false;
          if ((session.provider ?? 'claude') != request.provider) return false;
          if (session.id == request.sessionId) return true;
          final providerSessionId = request.providerSessionId;
          return providerSessionId != null &&
              providerSessionId.isNotEmpty &&
              session.claudeSessionId == providerSessionId;
        })
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  void _replaceAndPersist(NotificationApprovalRequest request) {
    final index = _pending.indexWhere(
      (existing) => existing.identity == request.identity,
    );
    if (index < 0) return;
    _pending[index] = request;
    unawaited(_persist());
  }

  void _removeAndPersist(String identity) {
    if (_removeByIdentity(identity)) unawaited(_persist());
  }

  bool _removeByIdentity(String identity) {
    final before = _pending.length;
    _pending.removeWhere((request) => request.identity == identity);
    if (_pending.length == before) return false;
    _disposeBrokerAttempt(identity);
    return true;
  }

  void _disposeBrokerAttempt(String identity) {
    final attempt = _brokerAttempts.remove(identity);
    if (attempt == null || attempt.disposed) return;
    attempt.disposed = true;
    attempt.service.removeListener(attempt.listener);
    attempt.service.dispose();
  }

  bool _isExpired(NotificationApprovalRequest request) {
    return DateTime.now().toUtc().difference(request.createdAt.toUtc()) >
        _maxAge;
  }

  bool _isTooFarInFuture(NotificationApprovalRequest request) {
    return request.createdAt.toUtc().difference(DateTime.now().toUtc()) >
        const Duration(minutes: 1);
  }

  Future<void> _persist() async {
    final allEncoded = _pending.isEmpty
        ? null
        : jsonEncode(_pending.map((request) => request.toJson()).toList());
    final legacy = _pending
        .where((request) => !request.usesCodexActionBroker)
        .toList(growable: false);
    final legacyEncoded = legacy.isEmpty
        ? null
        : jsonEncode(legacy.map((request) => request.toJson()).toList());
    _persistChain = _persistChain
        .then((_) async {
          if (allEncoded == null) {
            await _preferences.remove(_preferenceKey);
          } else {
            await _preferences.setString(_preferenceKey, allEncoded);
          }
          if (legacyEncoded == null) {
            await _preferences.remove(_legacyPreferenceKey);
          } else {
            await _preferences.setString(_legacyPreferenceKey, legacyEncoded);
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          logger.warning(
            '[notifications] approval queue persistence failed',
            error,
            stackTrace,
          );
        });
    await _persistChain;
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    await _sessionSub?.cancel();
    await _connectionSub?.cancel();
    for (final identity in _brokerAttempts.keys.toList(growable: false)) {
      _disposeBrokerAttempt(identity);
    }
    await _persistChain;
  }
}

class _CodexNotificationActionAttempt {
  _CodexNotificationActionAttempt({
    required this.requestIdentity,
    required this.service,
    required this.listener,
  });

  final String requestIdentity;
  final CodexActionBrokerService service;
  final void Function() listener;
  int lastAttemptSnapshotEpoch = -1;
  int lastRefreshViewEpoch = -1;
  bool scheduled = false;
  bool inFlight = false;
  bool disposed = false;
}
