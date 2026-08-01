import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../models/messages.dart';
import '../../services/bridge_service.dart';

typedef CodexActionBrokerIdFactory = String Function();
typedef CodexActionBrokerClaimantLoader = Future<String> Function();
typedef CodexActionBrokerRuntimeFenceProvider =
    CodexActionBrokerRuntimeFence Function();

@immutable
class CodexActionBrokerRuntimeFence {
  const CodexActionBrokerRuntimeFence({
    this.turnId,
    this.authorityGeneration,
    this.executionHost,
  });

  final String? turnId;
  final String? authorityGeneration;
  final String? executionHost;
}

enum CodexActionBrokerInteractionPhase {
  inactive,
  loading,
  actionable,
  submitting,
  awaitingCanonical,
  reconnecting,
  writerLeaseUnavailable,
  handledElsewhere,
  unsupportedRequest,
  stale,
  unavailable,
  invalid,
}

@immutable
class CodexActionBrokerPresentation {
  const CodexActionBrokerPresentation({
    required this.request,
    required this.permission,
  });

  final CodexActionBrokerRequest request;
  final PermissionRequestMessage permission;

  bool get usesAskUserUi => permission.usesAskUserUi;
}

class _PendingCodexActionResponse {
  _PendingCodexActionResponse({required this.request});

  final CodexActionBrokerRequest request;
  Timer? timer;
  bool timedOut = false;
}

/// Mobile projection of the shared app-server Action Broker.
///
/// This service is deliberately scoped to one durable Codex thread. It never
/// resumes a provider runtime and never falls back to legacy `approve` /
/// `answer` messages. The current authenticated Bridge/source, provider turn,
/// authority generation, writer lease and live request must all agree before
/// [respond] can write anything.
class CodexActionBrokerService extends ChangeNotifier {
  static const _claimantPreferenceKey = 'codex_action_broker_claimant_id_v1';
  static const _uuid = Uuid();
  static Future<String>? _defaultClaimantFlight;

  CodexActionBrokerService({
    required this.bridge,
    required this.threadId,
    required this.expectedBridgeInstanceId,
    required this.expectedCodexSourceId,
    required this.runtimeFence,
    this.enabled = true,
    this.responseTimeout = const Duration(seconds: 15),
    CodexActionBrokerIdFactory? createId,
    CodexActionBrokerClaimantLoader? loadClaimantId,
  }) : _createId = createId ?? _uuid.v4,
       _loadClaimantId = loadClaimantId ?? _loadDefaultClaimantId;

  final BridgeService bridge;
  final String threadId;
  final String? expectedBridgeInstanceId;
  final String? expectedCodexSourceId;
  final CodexActionBrokerRuntimeFenceProvider runtimeFence;
  final bool enabled;
  final Duration responseTimeout;
  final CodexActionBrokerIdFactory _createId;
  final CodexActionBrokerClaimantLoader _loadClaimantId;

  final Map<String, CodexActionBrokerRequest> _requests = {};
  final Map<String, _PendingCodexActionResponse> _pendingResponses = {};
  final Map<String, String> _operationIds = {};
  final Set<String> _awaitingCanonical = {};

  StreamSubscription<LocalFeatureServerMessage>? _messageSubscription;
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  StreamSubscription<List<SessionInfo>>? _sessionListSubscription;
  CodexActionBrokerHealth? _health;
  CodexActionBrokerResponseOutcome? _lastOutcome;
  String? _lastError;
  String? _submittingOpaqueRequestId;
  String? _observedAuthorityKey;
  bool _snapshotObserved = false;
  int _snapshotEpoch = 0;
  bool _started = false;
  bool _disposed = false;
  int _viewEpoch = 0;

  CodexActionBrokerHealth? get health => _health;
  CodexActionBrokerResponseOutcome? get lastOutcome => _lastOutcome;
  String? get lastError => _lastError;
  int get viewEpoch => _viewEpoch;
  int get snapshotEpoch => _snapshotEpoch;
  bool get snapshotObserved => _snapshotObserved;

  CodexActionBrokerRequest? requestByOpaqueId(String opaqueRequestId) {
    if (!authenticatedSourceMatches) return null;
    final request = _requests[opaqueRequestId];
    return request != null && _matchesStaticTarget(request) && !request.terminal
        ? request
        : null;
  }

  bool isAwaitingCanonical(String opaqueRequestId) =>
      _awaitingCanonical.contains(opaqueRequestId);

  bool get capabilityNegotiated => enabled && bridge.supportsCodexActionBroker;

  bool get authenticatedSourceMatches {
    final expectedBridge = expectedBridgeInstanceId?.trim();
    final expectedSource = expectedCodexSourceId?.trim();
    return capabilityNegotiated &&
        bridge.isConnected &&
        expectedBridge != null &&
        expectedBridge.isNotEmpty &&
        expectedSource != null &&
        expectedSource.isNotEmpty &&
        bridge.bridgeInstanceId == expectedBridge &&
        bridge.codexSourceId == expectedSource;
  }

  CodexActionBrokerRequest? get visibleRequest {
    if (!authenticatedSourceMatches) return null;
    final candidates = _requests.values
        .where(_matchesStaticTarget)
        .where((request) => !request.terminal)
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    candidates.sort((left, right) {
      final priority = _requestPriority(
        left,
      ).compareTo(_requestPriority(right));
      if (priority != 0) return priority;
      final observed = left.observedAt.compareTo(right.observedAt);
      return observed != 0
          ? observed
          : left.opaqueRequestId.compareTo(right.opaqueRequestId);
    });
    final fence = runtimeFence();
    final turnId = _normalized(fence.turnId);
    if (turnId != null) {
      for (final request in candidates) {
        if (request.turnId == turnId) {
          return request;
        }
      }
    }
    return candidates.first;
  }

  static int _requestPriority(CodexActionBrokerRequest request) =>
      switch ((request.state, request.live)) {
        (CodexActionBrokerRequestState.pending, true) => 0,
        (CodexActionBrokerRequestState.pending, false) => 1,
        (CodexActionBrokerRequestState.claimed, true) => 2,
        _ => 3,
      };

  CodexActionBrokerPresentation? get presentation {
    final request = visibleRequest;
    if (request == null) return null;
    final permission = _projectPermission(request);
    return permission == null
        ? null
        : CodexActionBrokerPresentation(
            request: request,
            permission: permission,
          );
  }

  bool ownsDetachedInteraction({required bool waitingApproval}) {
    if (!capabilityNegotiated) return false;
    final fence = runtimeFence();
    final request = visibleRequest;
    final hasExactCurrentRequest =
        authenticatedSourceMatches &&
        request != null &&
        _sameRuntimeFence(request, fence);
    return hasExactCurrentRequest ||
        (waitingApproval && fence.executionHost != 'bridge');
  }

  bool get actionable {
    final request = visibleRequest;
    final health = _health;
    final fence = runtimeFence();
    if (request == null ||
        !_supportsProjectedInteraction(request) ||
        health == null ||
        !authenticatedSourceMatches ||
        !health.ready ||
        !health.controlReady ||
        health.degraded ||
        !health.writerLeaseHeld ||
        request.state != CodexActionBrokerRequestState.pending ||
        !request.live ||
        request.allowedActions.isEmpty ||
        _lastOutcome == CodexActionBrokerResponseOutcome.unavailable ||
        _lastOutcome == CodexActionBrokerResponseOutcome.invalid ||
        _submittingOpaqueRequestId == request.opaqueRequestId ||
        _awaitingCanonical.contains(request.opaqueRequestId)) {
      return false;
    }
    return _sameRuntimeFence(request, fence) &&
        health.authorityGeneration == request.authorityGeneration;
  }

  CodexActionBrokerInteractionPhase get phase {
    if (!capabilityNegotiated) {
      return CodexActionBrokerInteractionPhase.inactive;
    }
    if (!authenticatedSourceMatches) {
      return bridge.isConnected
          ? CodexActionBrokerInteractionPhase.stale
          : CodexActionBrokerInteractionPhase.reconnecting;
    }
    final request = visibleRequest;
    if (request == null) {
      switch (_lastOutcome) {
        case CodexActionBrokerResponseOutcome.contended:
        case CodexActionBrokerResponseOutcome.alreadyResolved:
          return CodexActionBrokerInteractionPhase.handledElsewhere;
        case CodexActionBrokerResponseOutcome.expired:
        case CodexActionBrokerResponseOutcome.staleGeneration:
          return CodexActionBrokerInteractionPhase.stale;
        case CodexActionBrokerResponseOutcome.unavailable:
          return CodexActionBrokerInteractionPhase.unavailable;
        case CodexActionBrokerResponseOutcome.invalid:
          return CodexActionBrokerInteractionPhase.invalid;
        case CodexActionBrokerResponseOutcome.submitted:
        case CodexActionBrokerResponseOutcome.outcomeUnknown:
        case null:
          break;
      }
      final health = _health;
      if (health?.degradedReason == 'unsupported_server_request') {
        return CodexActionBrokerInteractionPhase.unsupportedRequest;
      }
      if (health == null) {
        return CodexActionBrokerInteractionPhase.loading;
      }
      if (!health.controlReady) {
        return CodexActionBrokerInteractionPhase.reconnecting;
      }
      if (!health.writerLeaseHeld) {
        return CodexActionBrokerInteractionPhase.writerLeaseUnavailable;
      }
      if (!health.ready || health.degraded) {
        return CodexActionBrokerInteractionPhase.unavailable;
      }
      return _snapshotObserved
          ? CodexActionBrokerInteractionPhase.stale
          : CodexActionBrokerInteractionPhase.loading;
    }
    if (_submittingOpaqueRequestId == request.opaqueRequestId) {
      return CodexActionBrokerInteractionPhase.submitting;
    }
    if (_awaitingCanonical.contains(request.opaqueRequestId)) {
      return CodexActionBrokerInteractionPhase.awaitingCanonical;
    }
    if (!_supportsProjectedInteraction(request)) {
      return CodexActionBrokerInteractionPhase.unsupportedRequest;
    }
    if (_health?.degradedReason == 'unsupported_server_request') {
      return CodexActionBrokerInteractionPhase.unsupportedRequest;
    }
    if (!_sameRuntimeFence(request, runtimeFence()) ||
        _health?.authorityGeneration != request.authorityGeneration) {
      return CodexActionBrokerInteractionPhase.stale;
    }
    if (request.state == CodexActionBrokerRequestState.claimed) {
      return CodexActionBrokerInteractionPhase.handledElsewhere;
    }
    final health = _health;
    if (health == null || !health.controlReady) {
      return CodexActionBrokerInteractionPhase.reconnecting;
    }
    if (!health.writerLeaseHeld) {
      return CodexActionBrokerInteractionPhase.writerLeaseUnavailable;
    }
    if (!health.ready || health.degraded || !request.live) {
      return CodexActionBrokerInteractionPhase.unavailable;
    }
    if (_lastOutcome == CodexActionBrokerResponseOutcome.unavailable) {
      return CodexActionBrokerInteractionPhase.unavailable;
    }
    if (_lastOutcome == CodexActionBrokerResponseOutcome.invalid) {
      return CodexActionBrokerInteractionPhase.invalid;
    }
    return CodexActionBrokerInteractionPhase.actionable;
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _messageSubscription = bridge.localFeatureMessages.listen(_onMessage);
    _connectionSubscription = bridge.connectionStatus.listen(
      _onConnectionState,
    );
    // Bridge identity/capabilities currently become authoritative with the
    // session-list envelope. Reconcile that authority here, but do not turn
    // every catalog/status emission into another broker snapshot request.
    _sessionListSubscription = bridge.sessionList.listen(
      (_) => _reconcileAuthority(),
    );
    _reconcileAuthority();
  }

  bool refresh() {
    if (_disposed || !authenticatedSourceMatches) return false;
    try {
      bridge.send(
        requestCodexActions(
          requestId: _createId(),
          codexSourceId: expectedCodexSourceId!.trim(),
          threadId: threadId,
        ),
      );
      return true;
    } catch (_) {
      _lastError = 'disconnected';
      _notify();
      return false;
    }
  }

  /// Submit one broker decision through the same UI-agnostic seam that a
  /// future authenticated notification action may call. Native notification
  /// categories are intentionally not wired in this batch.
  Future<bool> respond(
    CodexActionBrokerDecision decision, {
    required String opaqueRequestId,
    String? answer,
    String? operationId,
  }) async {
    final request = visibleRequest;
    if (!actionable ||
        request == null ||
        request.opaqueRequestId != opaqueRequestId ||
        !request.allowedActions.contains(decision)) {
      return false;
    }
    final intentKey = [
      request.opaqueRequestId,
      request.authorityGeneration,
      decision.wireValue,
      answer ?? '',
    ].join('\u0000');
    final suppliedOperationId = _normalized(operationId);
    if (suppliedOperationId != null && suppliedOperationId.length > 256) {
      return false;
    }
    final stableOperationId = _operationIds.putIfAbsent(
      intentKey,
      () => suppliedOperationId ?? _createId(),
    );
    while (_operationIds.length > 128) {
      _operationIds.remove(_operationIds.keys.first);
    }
    final requestId = _createId();
    _submittingOpaqueRequestId = request.opaqueRequestId;
    _lastOutcome = null;
    _lastError = null;
    _notify();

    try {
      final claimantId = await _loadClaimantId();
      if (_disposed ||
          visibleRequest?.opaqueRequestId != request.opaqueRequestId ||
          _submittingOpaqueRequestId != request.opaqueRequestId ||
          !_requestCanStillSubmit(request, decision)) {
        _submittingOpaqueRequestId = null;
        _notify();
        return false;
      }
      final pending = _PendingCodexActionResponse(request: request);
      _pendingResponses[requestId] = pending;
      pending.timer = Timer(
        responseTimeout,
        () => _handleResponseTimeout(requestId),
      );
      bridge.send(
        respondCodexAction(
          requestId: requestId,
          request: request,
          claimantId: claimantId,
          operationId: stableOperationId,
          action: decision,
          answer: answer,
        ),
      );
      return true;
    } catch (error) {
      _takePendingResponse(requestId);
      if (_submittingOpaqueRequestId == request.opaqueRequestId) {
        _submittingOpaqueRequestId = null;
      }
      _lastError = error.toString();
      _viewEpoch += 1;
      _notify();
      return false;
    }
  }

  void _onMessage(LocalFeatureServerMessage message) {
    if (_disposed) return;
    if (message is LocalFeatureRequestErrorMessage) {
      _handleRequestError(message);
      return;
    }
    if (message is! CodexActionBrokerEventMessage) return;
    switch (message.event) {
      case CodexActionBrokerEventKind.snapshot:
        final scope = message.scope;
        if (scope != null &&
            (scope.codexSourceId != expectedCodexSourceId?.trim() ||
                scope.threadId != threadId)) {
          return;
        }
        _applyHealth(message.health);
        _snapshotObserved = true;
        _snapshotEpoch += 1;
        _lastOutcome = null;
        _lastError = null;
        _requests.clear();
        for (final request in message.requests) {
          if (_matchesStaticTarget(request) && !request.terminal) {
            _requests[request.opaqueRequestId] = request;
          }
        }
        _removePendingResponsesWhere(
          (pending) => !_requests.containsKey(pending.request.opaqueRequestId),
        );
        _awaitingCanonical.removeWhere(
          (opaqueRequestId) => !_requests.containsKey(opaqueRequestId),
        );
        final submitting = _submittingOpaqueRequestId;
        if (submitting != null && !_requests.containsKey(submitting)) {
          _submittingOpaqueRequestId = null;
        }
        _notify();
      case CodexActionBrokerEventKind.request:
        final request = message.request;
        if (request == null || !_matchesStaticTarget(request)) return;
        if (request.terminal) {
          _removeRequest(request.opaqueRequestId);
        } else {
          _requests[request.opaqueRequestId] = request;
        }
        _notify();
      case CodexActionBrokerEventKind.health:
        _applyHealth(message.health);
        _notify();
      case CodexActionBrokerEventKind.response:
        _handleResponse(message);
      case CodexActionBrokerEventKind.unknown:
        return;
    }
  }

  void _handleResponse(CodexActionBrokerEventMessage message) {
    final requestId = message.requestId;
    final opaqueRequestId = message.opaqueRequestId;
    if (requestId == null || opaqueRequestId == null) return;
    final pending = _pendingResponses[requestId];
    if (pending == null ||
        pending.request.opaqueRequestId != opaqueRequestId ||
        !_matchesResponseFence(pending.request, message.request)) {
      return;
    }
    _takePendingResponse(requestId);
    if (_submittingOpaqueRequestId == opaqueRequestId) {
      _submittingOpaqueRequestId = null;
    }
    final responseRequest = message.request;
    if (responseRequest != null && !responseRequest.terminal) {
      _requests[opaqueRequestId] = responseRequest;
    }
    _lastOutcome = message.outcome;
    _lastError = message.error;
    switch (message.outcome) {
      case CodexActionBrokerResponseOutcome.submitted:
      case CodexActionBrokerResponseOutcome.outcomeUnknown:
        // Both outcomes may already have written to app-server. Never retry;
        // wait for the canonical serverRequest/resolved lifecycle instead.
        _awaitingCanonical.add(opaqueRequestId);
      case CodexActionBrokerResponseOutcome.alreadyResolved:
      case CodexActionBrokerResponseOutcome.contended:
      case CodexActionBrokerResponseOutcome.expired:
      case CodexActionBrokerResponseOutcome.staleGeneration:
        _removeRequest(opaqueRequestId);
      case CodexActionBrokerResponseOutcome.unavailable:
      case CodexActionBrokerResponseOutcome.invalid:
        _awaitingCanonical.remove(opaqueRequestId);
        _viewEpoch += 1;
      case null:
        return;
    }
    _notify();
  }

  void _handleRequestError(LocalFeatureRequestErrorMessage message) {
    if (message.featureId != 'codex_action_broker' ||
        message.requestType != 'respond_codex_action' ||
        message.ownerSessionId != threadId) {
      return;
    }
    final requestId = message.requestId;
    if (requestId == null) return;
    final pending = _takePendingResponse(requestId);
    if (pending == null) return;
    if (_submittingOpaqueRequestId == pending.request.opaqueRequestId) {
      _submittingOpaqueRequestId = null;
    }
    _awaitingCanonical.remove(pending.request.opaqueRequestId);
    // A correlated protocol error means the Bridge rejected this RPC rather
    // than accepting the app-server mutation. Keep the request visible but
    // require a fresh canonical snapshot before another explicit user tap.
    _lastOutcome = CodexActionBrokerResponseOutcome.unavailable;
    _lastError = message.errorCode ?? message.message;
    _viewEpoch += 1;
    _notify();
    refresh();
  }

  void _handleResponseTimeout(String requestId) {
    if (_disposed) return;
    final pending = _pendingResponses[requestId];
    if (pending == null || pending.timedOut) return;
    pending.timer?.cancel();
    pending.timer = null;
    pending.timedOut = true;
    final opaqueRequestId = pending.request.opaqueRequestId;
    if (_submittingOpaqueRequestId == opaqueRequestId) {
      _submittingOpaqueRequestId = null;
    }
    if (_requestStillAuthoritative(pending.request)) {
      // The write may already have reached app-server. Never retry this
      // intent; wait for the canonical resolved lifecycle and only refresh
      // visibility.
      _awaitingCanonical.add(opaqueRequestId);
      _lastOutcome = CodexActionBrokerResponseOutcome.outcomeUnknown;
      _lastError = 'request_timeout';
      _viewEpoch += 1;
    }
    _notify();
    refresh();
  }

  _PendingCodexActionResponse? _takePendingResponse(String requestId) {
    final pending = _pendingResponses.remove(requestId);
    pending?.timer?.cancel();
    return pending;
  }

  void _removePendingResponsesWhere(
    bool Function(_PendingCodexActionResponse pending) test,
  ) {
    final requestIds = _pendingResponses.entries
        .where((entry) => test(entry.value))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final requestId in requestIds) {
      _takePendingResponse(requestId);
    }
  }

  void _applyHealth(CodexActionBrokerHealth? health) {
    if (health == null) return;
    final previousGeneration = _health?.authorityGeneration;
    _health = health;
    final nextGeneration = health.authorityGeneration;
    if (previousGeneration != null && previousGeneration != nextGeneration) {
      _requests.removeWhere(
        (_, request) => request.authorityGeneration != nextGeneration,
      );
      _removePendingResponsesWhere(
        (pending) => pending.request.authorityGeneration != nextGeneration,
      );
      _awaitingCanonical.removeWhere(
        (opaqueRequestId) => !_requests.containsKey(opaqueRequestId),
      );
      _submittingOpaqueRequestId = null;
      _snapshotObserved = false;
      _lastOutcome = null;
      _lastError = null;
      _viewEpoch += 1;
    }
  }

  void _onConnectionState(BridgeConnectionState state) {
    if (_disposed) return;
    if (state != BridgeConnectionState.connected) {
      _observedAuthorityKey = null;
      _clearForAuthorityChange();
      return;
    }
    _reconcileAuthority();
  }

  void _reconcileAuthority() {
    if (_disposed) return;
    final nextKey = authenticatedSourceMatches
        ? '${bridge.bridgeInstanceId}\u0000${bridge.codexSourceId}'
        : null;
    if (nextKey == null) {
      _observedAuthorityKey = null;
      _clearForAuthorityChange();
      return;
    }
    if (_observedAuthorityKey == nextKey) return;
    _observedAuthorityKey = nextKey;
    refresh();
  }

  void _clearForAuthorityChange() {
    final changed =
        _health != null ||
        _requests.isNotEmpty ||
        _pendingResponses.isNotEmpty ||
        _awaitingCanonical.isNotEmpty ||
        _submittingOpaqueRequestId != null ||
        _snapshotObserved ||
        _lastOutcome != null ||
        _lastError != null;
    _health = null;
    _requests.clear();
    _removePendingResponsesWhere((_) => true);
    _awaitingCanonical.clear();
    _submittingOpaqueRequestId = null;
    _snapshotObserved = false;
    _lastOutcome = null;
    _lastError = null;
    if (changed) {
      _viewEpoch += 1;
      _notify();
    }
  }

  void _removeRequest(String opaqueRequestId) {
    _requests.remove(opaqueRequestId);
    _removePendingResponsesWhere(
      (pending) => pending.request.opaqueRequestId == opaqueRequestId,
    );
    _awaitingCanonical.remove(opaqueRequestId);
    if (_submittingOpaqueRequestId == opaqueRequestId) {
      _submittingOpaqueRequestId = null;
    }
  }

  bool _matchesStaticTarget(CodexActionBrokerRequest request) {
    final expectedSource = expectedCodexSourceId?.trim();
    return expectedSource != null &&
        expectedSource.isNotEmpty &&
        request.codexSourceId == expectedSource &&
        request.threadId == threadId;
  }

  bool _sameRuntimeFence(
    CodexActionBrokerRequest request,
    CodexActionBrokerRuntimeFence fence,
  ) {
    final turnId = _normalized(fence.turnId);
    // conversation_sync authority generations (daemon/runtime namespace) and
    // Action Broker generations (`cab:*`) are intentionally different. The
    // cross-feature fence is the exact active turn; the broker generation is
    // checked only against broker health below.
    return turnId != null && request.turnId == turnId;
  }

  bool _requestStillAuthoritative(CodexActionBrokerRequest request) {
    final current = _requests[request.opaqueRequestId];
    return current != null &&
        _sameRequestFence(current, request) &&
        _sameRuntimeFence(request, runtimeFence()) &&
        _health?.authorityGeneration == request.authorityGeneration &&
        authenticatedSourceMatches;
  }

  bool _requestCanStillSubmit(
    CodexActionBrokerRequest expected,
    CodexActionBrokerDecision decision,
  ) {
    final current = _requests[expected.opaqueRequestId];
    final health = _health;
    return current != null &&
        _sameRequestFence(current, expected) &&
        current.state == CodexActionBrokerRequestState.pending &&
        current.live &&
        current.allowedActions.contains(decision) &&
        _supportsProjectedInteraction(current) &&
        health != null &&
        health.ready &&
        health.controlReady &&
        !health.degraded &&
        health.writerLeaseHeld &&
        health.authorityGeneration == current.authorityGeneration &&
        _sameRuntimeFence(current, runtimeFence()) &&
        authenticatedSourceMatches;
  }

  bool _matchesResponseFence(
    CodexActionBrokerRequest expected,
    CodexActionBrokerRequest? response,
  ) {
    if (!_requestStillAuthoritative(expected)) return false;
    return response == null || _sameRequestFence(expected, response);
  }

  bool _sameRequestFence(
    CodexActionBrokerRequest left,
    CodexActionBrokerRequest right,
  ) =>
      left.opaqueRequestId == right.opaqueRequestId &&
      left.codexSourceId == right.codexSourceId &&
      left.threadId == right.threadId &&
      left.turnId == right.turnId &&
      left.authorityGeneration == right.authorityGeneration;

  PermissionRequestMessage? _projectPermission(
    CodexActionBrokerRequest request,
  ) {
    final toolName = switch (request.kind) {
      CodexActionBrokerRequestKind.commandApproval =>
        _normalized(request.toolName) ?? 'Bash',
      CodexActionBrokerRequestKind.fileApproval =>
        _normalized(request.toolName) ?? 'FileChange',
      CodexActionBrokerRequestKind.permissionsApproval =>
        _normalized(request.toolName) ?? 'Permissions',
      CodexActionBrokerRequestKind.userInput => 'AskUserQuestion',
      // Broker MCP elicitations already carry normalized native question
      // options, including session/always approval choices. Route them through
      // the established AskUserQuestion surface so `answer` remains expressible
      // instead of silently collapsing the request to approve/reject.
      CodexActionBrokerRequestKind.mcpElicitation => 'AskUserQuestion',
      CodexActionBrokerRequestKind.toolSuggestion => 'ToolSuggestion',
      CodexActionBrokerRequestKind.currentTime ||
      CodexActionBrokerRequestKind.unknown => null,
    };
    if (toolName == null) return null;
    final availableDecisions = <String>[
      if (request.allowedActions.contains(CodexActionBrokerDecision.approve))
        'accept',
      if (request.allowedActions.contains(
        CodexActionBrokerDecision.approveAlways,
      ))
        'acceptForSession',
      if (request.allowedActions.contains(CodexActionBrokerDecision.reject))
        'decline',
    ];
    return PermissionRequestMessage(
      toolUseId: request.opaqueRequestId,
      toolName: toolName,
      input: Map<String, dynamic>.unmodifiable({
        ...request.input,
        'availableDecisions': availableDecisions,
      }),
    );
  }

  bool _supportsProjectedInteraction(CodexActionBrokerRequest request) {
    final permission = _projectPermission(request);
    if (permission == null) return false;
    if (permission.usesAskUserUi) {
      return request.allowedActions.contains(CodexActionBrokerDecision.answer);
    }
    return request.allowedActions.any(
      const {
        CodexActionBrokerDecision.approve,
        CodexActionBrokerDecision.approveAlways,
        CodexActionBrokerDecision.reject,
      }.contains,
    );
  }

  static String? _normalized(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static Future<String> _loadDefaultClaimantId() {
    return _defaultClaimantFlight ??= () async {
      final preferences = await SharedPreferences.getInstance();
      final existing = preferences.getString(_claimantPreferenceKey)?.trim();
      if (existing != null && existing.isNotEmpty && existing.length <= 256) {
        return existing;
      }
      final value = 'mobile-${_uuid.v4()}';
      await preferences.setString(_claimantPreferenceKey, value);
      return value;
    }();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _messageSubscription?.cancel();
    _connectionSubscription?.cancel();
    _sessionListSubscription?.cancel();
    _requests.clear();
    _removePendingResponsesWhere((_) => true);
    _awaitingCanonical.clear();
    super.dispose();
  }
}
