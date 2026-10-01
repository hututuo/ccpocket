import 'dart:async';

import 'conversation_turns_page_load_result.dart';

/// Immutable request facts. Only the lifecycle can settle its result.
class OlderTurnsPageRequest {
  const OlderTurnsPageRequest._({
    required this.requestId,
    required this.generation,
    required this.targetFingerprint,
    required this.provider,
    required this.providerSessionId,
    required this.expectedRevision,
    required this.expectedCursor,
    required this.result,
  });

  final String requestId;
  final int generation;
  final String targetFingerprint;
  final String provider;
  final String providerSessionId;
  final String expectedRevision;
  final String? expectedCursor;
  final Future<ConversationTurnsPageLoadResult> result;
}

/// Owns older-turn flights, response deadlines and exactly-once settlement.
///
/// The host retains source/subscription fences, retry policy, shared history
/// serialization, Provider requests, SQLite writes, notifications and ACKs.
class OlderTurnsPagingLifecycle {
  static const responseDeadline = Duration(seconds: 15);

  final Map<String, Future<ConversationTurnsPageLoadResult>> _flights = {};
  final Map<String, _PendingOlderPage> _pending = {};

  int get pendingCount => _pending.length;
  int get flightCount => _flights.length;
  Iterable<Future<ConversationTurnsPageLoadResult>> get flights =>
      _flights.values.toList(growable: false);

  Future<ConversationTurnsPageLoadResult> runFlight(
    String key,
    Future<ConversationTurnsPageLoadResult> Function() operation,
  ) {
    final existing = _flights[key];
    if (existing != null) return existing;
    late final Future<ConversationTurnsPageLoadResult> flight;
    flight = Future.sync(operation).whenComplete(() {
      if (identical(_flights[key], flight)) _flights.remove(key);
    });
    _flights[key] = flight;
    return flight;
  }

  OlderTurnsPageRequest begin({
    required String requestId,
    required int generation,
    required String targetFingerprint,
    required String provider,
    required String providerSessionId,
    required String expectedRevision,
    required String? expectedCursor,
  }) {
    if (_pending.containsKey(requestId)) {
      throw StateError('An older-page request ID is already active.');
    }
    final completer = Completer<ConversationTurnsPageLoadResult>();
    final request = OlderTurnsPageRequest._(
      requestId: requestId,
      generation: generation,
      targetFingerprint: targetFingerprint,
      provider: provider,
      providerSessionId: providerSessionId,
      expectedRevision: expectedRevision,
      expectedCursor: expectedCursor,
      result: completer.future,
    );
    final pending = _PendingOlderPage(request, completer);
    _pending[requestId] = pending;
    pending.deadline = Timer(responseDeadline, () {
      fail(
        request,
        TimeoutException(
          'Conversation history page timed out.',
          responseDeadline,
        ),
      );
    });
    return request;
  }

  OlderTurnsPageRequest? find(String? requestId) =>
      requestId == null ? null : _pending[requestId]?.request;

  bool complete(
    OlderTurnsPageRequest request,
    ConversationTurnsPageLoadResult result,
  ) {
    final pending = _take(request);
    if (pending == null) return false;
    pending.completer.complete(result);
    return true;
  }

  bool fail(OlderTurnsPageRequest request, Object error, [StackTrace? stack]) {
    final pending = _take(request);
    if (pending == null) return false;
    pending.completer.completeError(error, stack);
    return true;
  }

  _PendingOlderPage? _take(OlderTurnsPageRequest request) {
    final pending = _pending[request.requestId];
    if (pending == null || !identical(pending.request, request)) return null;
    _pending.remove(request.requestId);
    pending.deadline?.cancel();
    return pending;
  }

  void failTarget({
    required int generation,
    required String targetFingerprint,
    required String provider,
    required String providerSessionId,
    required Object error,
  }) {
    final requests = _pending.values
        .map((pending) => pending.request)
        .where(
          (request) =>
              request.generation == generation &&
              request.targetFingerprint == targetFingerprint &&
              request.provider == provider &&
              request.providerSessionId == providerSessionId,
        )
        .toList(growable: false);
    for (final request in requests) {
      fail(request, error);
    }
  }

  void failAll(Object error) {
    final requests = _pending.values
        .map((pending) => pending.request)
        .toList(growable: false);
    for (final request in requests) {
      fail(request, error);
    }
    // Flights also include queued/local work. Keep them joinable until their
    // host operation settles; failing wire requests is not closing SQLite.
  }
}

class _PendingOlderPage {
  _PendingOlderPage(this.request, this.completer);

  final OlderTurnsPageRequest request;
  final Completer<ConversationTurnsPageLoadResult> completer;
  Timer? deadline;
}
