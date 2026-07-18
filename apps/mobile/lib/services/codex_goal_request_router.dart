import '../models/messages.dart';

/// Correlates Goal-v1 Bridge responses that predate `sessionId` and
/// `goalChangeId` response fields.
///
/// New Bridges remain authoritative and are routed by their explicit fields.
/// This FIFO fallback is deliberately limited to live Goal RPCs and expires
/// quickly, so an unscoped error from one session is never broadcast into all
/// active session cubits.
class CodexGoalRequestRouter {
  CodexGoalRequestRouter({
    this.ttl = const Duration(seconds: 25),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;
  final List<CodexGoalRequestRegistration> _pending = [];

  CodexGoalRequestRegistration? register(ClientMessage message) {
    if (!_goalRequestTypes.contains(message.type)) return null;
    final sessionId = message.sessionId;
    if (sessionId == null || sessionId.isEmpty) return null;
    _prune();
    final registration = CodexGoalRequestRegistration._(
      requestType: message.type,
      sessionId: sessionId,
      goalChangeId: message.goalChangeId,
      expiresAt: _clock().add(ttl),
    );
    _pending.add(registration);
    return registration;
  }

  void rollback(CodexGoalRequestRegistration? registration) {
    if (registration != null) _pending.remove(registration);
  }

  void clear() => _pending.clear();

  /// Returns the response's authoritative wire scope, or the legacy request
  /// scope recovered from the pending FIFO.
  String? route(ServerMessage message, {String? wireSessionId}) {
    _prune();
    if (message case GoalStateMessage(:final goalChangeId, :final goal)) {
      final index = _matchGoalState(
        wireSessionId: wireSessionId,
        goalChangeId: goalChangeId,
        goalIsNull: goal == null,
      );
      return _consume(index, wireSessionId);
    }
    if (message case ErrorMessage()) {
      final requestType = _goalRequestTypeForError(message);
      if (requestType == _notGoalError) return wireSessionId;
      final index = _matchError(
        wireSessionId: wireSessionId,
        goalChangeId: message.goalChangeId,
        requestType: requestType,
      );
      return _consume(index, wireSessionId);
    }
    return wireSessionId;
  }

  int _matchGoalState({
    required String? wireSessionId,
    required String? goalChangeId,
    required bool goalIsNull,
  }) {
    final correlated = _indexForChangeId(goalChangeId, wireSessionId);
    if (correlated >= 0) return correlated;

    // A response without a change id is Goal-v1. Preserve request order, but
    // prefer the response shape when two RPCs for one session overlap.
    final compatibleTypes = goalIsNull
        ? const {'get_goal', 'clear_goal'}
        : const {'get_goal', 'set_goal'};
    var index = _candidateIndexWhere(
      (pending) =>
          _matchesSession(pending, wireSessionId) &&
          compatibleTypes.contains(pending.requestType),
      wireSessionId: wireSessionId,
    );
    index = index >= 0
        ? index
        : _candidateIndexWhere(
            (pending) => _matchesSession(pending, wireSessionId),
            wireSessionId: wireSessionId,
          );
    return index;
  }

  int _matchError({
    required String? wireSessionId,
    required String? goalChangeId,
    required String? requestType,
  }) {
    final correlated = _indexForChangeId(goalChangeId, wireSessionId);
    if (correlated >= 0) return correlated;
    if (requestType != null) {
      return _candidateIndexWhere(
        (pending) =>
            pending.requestType == requestType &&
            _matchesSession(pending, wireSessionId),
        wireSessionId: wireSessionId,
      );
    }
    // Pre-1.23 Bridge used only "Invalid message format". The oldest live
    // Goal request is the strongest correlation information it provides.
    return _candidateIndexWhere(
      (pending) => _matchesSession(pending, wireSessionId),
      wireSessionId: wireSessionId,
    );
  }

  int _indexForChangeId(String? goalChangeId, String? wireSessionId) {
    final normalized = goalChangeId?.trim();
    if (normalized == null || normalized.isEmpty) return -1;
    return _candidateIndexWhere(
      (pending) =>
          pending.goalChangeId == normalized &&
          _matchesSession(pending, wireSessionId),
      wireSessionId: wireSessionId,
    );
  }

  bool _matchesSession(
    CodexGoalRequestRegistration pending,
    String? wireSessionId,
  ) => wireSessionId == null || pending.sessionId == wireSessionId;

  int _indexWhere(bool Function(CodexGoalRequestRegistration) matches) {
    for (var index = 0; index < _pending.length; index++) {
      if (matches(_pending[index])) return index;
    }
    return -1;
  }

  int _candidateIndexWhere(
    bool Function(CodexGoalRequestRegistration) matches, {
    required String? wireSessionId,
  }) {
    if (wireSessionId != null) return _indexWhere(matches);
    var candidate = -1;
    for (var index = 0; index < _pending.length; index++) {
      if (!matches(_pending[index])) continue;
      if (candidate >= 0) return -1;
      candidate = index;
    }
    return candidate;
  }

  String? _consume(int index, String? wireSessionId) {
    if (index < 0) return wireSessionId;
    final pending = _pending.removeAt(index);
    return wireSessionId ?? pending.sessionId;
  }

  void _prune() {
    final now = _clock();
    _pending.removeWhere((pending) => !pending.expiresAt.isAfter(now));
  }
}

class CodexGoalRequestRegistration {
  const CodexGoalRequestRegistration._({
    required this.requestType,
    required this.sessionId,
    required this.goalChangeId,
    required this.expiresAt,
  });

  final String requestType;
  final String sessionId;
  final String? goalChangeId;
  final DateTime expiresAt;
}

const _goalRequestTypes = {'get_goal', 'set_goal', 'clear_goal'};
const _notGoalError = '__not_goal_error__';

String? _goalRequestTypeForError(ErrorMessage error) {
  final code = error.errorCode;
  if (code == 'unsupported_message') {
    return _goalRequestTypes.contains(error.message)
        ? error.message
        : _notGoalError;
  }
  if (code == null && error.message == 'Invalid message format') return null;
  if (code == null || !code.startsWith('goal_')) return _notGoalError;
  if (code.startsWith('goal_get_')) return 'get_goal';
  if (code.startsWith('goal_set_')) return 'set_goal';
  if (code.startsWith('goal_clear_')) return 'clear_goal';
  if (code == 'goal_conflict') return null;
  if (code == 'goal_status_unsupported') return null;
  return null;
}
