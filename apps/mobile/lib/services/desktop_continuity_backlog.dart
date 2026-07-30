import 'dart:collection';

import '../models/messages.dart';

class DesktopContinuityTransientPayload {
  const DesktopContinuityTransientPayload({
    required this.turnId,
    required this.payload,
  });

  final String? turnId;
  final ServerMessage payload;
}

class DesktopContinuityBacklogSnapshot {
  const DesktopContinuityBacklogSnapshot({
    required this.sessionId,
    required this.threadId,
    required this.bridgeInstanceId,
    required this.state,
    required this.turnId,
    required this.turnSteerable,
    required this.handoffQueued,
    required this.itemKeys,
    required this.transientPayloads,
    required this.truncated,
  });

  final String sessionId;
  final String threadId;
  final String bridgeInstanceId;
  final CodexDesktopContinuityState? state;
  final String? turnId;
  final bool turnSteerable;
  final bool handoffQueued;
  final Set<String> itemKeys;
  final List<DesktopContinuityTransientPayload> transientPayloads;
  final bool truncated;
}

/// Bounded handoff storage for Desktop continuity while no conversation UI is
/// mounted. Completed payloads live in SessionRuntimeStore; this class keeps
/// only the current stream deltas plus item keys needed to deduplicate the
/// seed emitted when the conversation takes over the watch.
class DesktopContinuityBacklog {
  DesktopContinuityBacklog({
    this.maxSessions = 6,
    this.maxItemKeysPerSession = 4096,
    this.maxTransientCharactersPerSession = 1024 * 1024,
  });

  final int maxSessions;
  final int maxItemKeysPerSession;
  final int maxTransientCharactersPerSession;

  final LinkedHashMap<String, _PendingSession> _pending = LinkedHashMap();
  final LinkedHashMap<String, _ItemKeyLedger> _ledgers = LinkedHashMap();

  /// Records an event and returns true only for a previously unseen message
  /// payload. State events are always applied but return false.
  bool record(CodexDesktopContinuityEventMessage message) {
    final ledger = _ledgerFor(
      message.sessionId,
      message.threadId,
      message.bridgeInstanceId,
    );
    final pending = _pendingFor(message);
    pending
      ..bridgeInstanceId = message.bridgeInstanceId
      ..turnId = message.turnId ?? pending.turnId
      ..turnSteerable = message.turnSteerable && message.turnId != null
      ..handoffQueued = message.handoffQueued;

    switch (message.event) {
      case CodexDesktopContinuityEventKind.watching:
      case CodexDesktopContinuityEventKind.state:
        pending.state = message.state;
        if (message.state == CodexDesktopContinuityState.idle) {
          pending.clearTransientTurn(null);
        }
        return false;
      case CodexDesktopContinuityEventKind.message:
        final itemKey = message.itemKey;
        final payload = message.payload;
        if (itemKey == null || payload == null || !ledger.add(itemKey)) {
          return false;
        }
        if (payload is ThinkingDeltaMessage) {
          pending.appendTransient(
            message.turnId,
            _TransientKind.thinking,
            payload.text,
            maxCharacters: maxTransientCharactersPerSession,
          );
        } else if (payload is StreamDeltaMessage) {
          pending.appendTransient(
            message.turnId,
            _TransientKind.output,
            payload.text,
            maxCharacters: maxTransientCharactersPerSession,
          );
        } else if (payload is AssistantServerMessage ||
            payload is ResultMessage ||
            payload is ErrorMessage) {
          pending.clearTransientTurn(message.turnId);
        }
        return true;
      case CodexDesktopContinuityEventKind.error:
      case CodexDesktopContinuityEventKind.unwatched:
      case CodexDesktopContinuityEventKind.unknown:
        return false;
    }
  }

  DesktopContinuityBacklogSnapshot? take(
    String sessionId, {
    String? threadId,
    String? bridgeInstanceId,
  }) {
    final pending = _pending[sessionId];
    if (pending == null) return null;
    final expectedThreadId = threadId?.trim();
    if (expectedThreadId != null &&
        expectedThreadId.isNotEmpty &&
        pending.threadId != expectedThreadId) {
      return null;
    }
    final expectedBridgeInstanceId = bridgeInstanceId?.trim();
    if (expectedBridgeInstanceId != null &&
        expectedBridgeInstanceId.isNotEmpty &&
        pending.bridgeInstanceId != expectedBridgeInstanceId) {
      return null;
    }
    _pending.remove(sessionId);
    final ledger = _ledgers[sessionId];
    return pending.snapshot(
      itemKeys: Set.unmodifiable(ledger?.itemKeys ?? const <String>{}),
    );
  }

  void clearSession(String sessionId) {
    _pending.remove(sessionId);
    _ledgers.remove(sessionId);
  }

  void clear() {
    _pending.clear();
    _ledgers.clear();
  }

  _ItemKeyLedger _ledgerFor(
    String sessionId,
    String threadId,
    String bridgeInstanceId,
  ) {
    final existing = _ledgers.remove(sessionId);
    final sourceChanged =
        existing == null ||
        existing.threadId != threadId ||
        existing.bridgeInstanceId != bridgeInstanceId;
    final ledger = sourceChanged
        ? _ItemKeyLedger(threadId, bridgeInstanceId, maxItemKeysPerSession)
        : existing;
    if (existing != null && sourceChanged) {
      _pending.remove(sessionId);
    }
    _ledgers[sessionId] = ledger;
    _trimSessions();
    return ledger;
  }

  _PendingSession _pendingFor(CodexDesktopContinuityEventMessage message) {
    final existing = _pending.remove(message.sessionId);
    final pending =
        existing == null ||
            existing.threadId != message.threadId ||
            existing.bridgeInstanceId != message.bridgeInstanceId
        ? _PendingSession(
            sessionId: message.sessionId,
            threadId: message.threadId,
            bridgeInstanceId: message.bridgeInstanceId,
          )
        : existing;
    _pending[message.sessionId] = pending;
    _trimSessions();
    return pending;
  }

  void _trimSessions() {
    while (_pending.length > maxSessions) {
      final oldest = _pending.keys.first;
      _pending.remove(oldest);
      _ledgers.remove(oldest);
    }
    while (_ledgers.length > maxSessions) {
      final oldest = _ledgers.keys.first;
      _ledgers.remove(oldest);
      _pending.remove(oldest);
    }
  }
}

class _ItemKeyLedger {
  _ItemKeyLedger(this.threadId, this.bridgeInstanceId, this.maxKeys);

  final String threadId;
  final String bridgeInstanceId;
  final int maxKeys;
  final LinkedHashSet<String> itemKeys = LinkedHashSet();

  bool add(String key) {
    if (!itemKeys.add(key)) return false;
    while (itemKeys.length > maxKeys) {
      itemKeys.remove(itemKeys.first);
    }
    return true;
  }
}

enum _TransientKind { thinking, output }

class _PendingSession {
  _PendingSession({
    required this.sessionId,
    required this.threadId,
    required this.bridgeInstanceId,
  });

  final String sessionId;
  final String threadId;
  String bridgeInstanceId;
  CodexDesktopContinuityState? state;
  String? turnId;
  bool turnSteerable = false;
  bool handoffQueued = false;
  bool truncated = false;
  int transientCharacters = 0;
  final LinkedHashMap<String, _TransientChunks> _transients = LinkedHashMap();

  void appendTransient(
    String? turnId,
    _TransientKind kind,
    String text, {
    required int maxCharacters,
  }) {
    if (text.isEmpty) return;
    final key = '${turnId ?? ''}\u0000${kind.name}';
    final accumulator = _transients.putIfAbsent(
      key,
      () => _TransientChunks(turnId: turnId, kind: kind),
    );
    accumulator.chunks.add(text);
    accumulator.characters += text.length;
    transientCharacters += text.length;
    while (transientCharacters > maxCharacters && _transients.isNotEmpty) {
      truncated = true;
      final oldest = _transients.values.first;
      final chunk = oldest.chunks.removeFirst();
      oldest.characters -= chunk.length;
      transientCharacters -= chunk.length;
      if (oldest.chunks.isEmpty) {
        _transients.remove(_transients.keys.first);
      }
    }
  }

  void clearTransientTurn(String? targetTurnId) {
    if (targetTurnId == null) {
      _transients.clear();
      transientCharacters = 0;
      return;
    }
    final keys = _transients.entries
        .where((entry) => entry.value.turnId == targetTurnId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in keys) {
      final removed = _transients.remove(key);
      transientCharacters -= removed?.characters ?? 0;
    }
  }

  DesktopContinuityBacklogSnapshot snapshot({required Set<String> itemKeys}) {
    final payloads = <DesktopContinuityTransientPayload>[];
    for (final accumulator in _transients.values) {
      final text = accumulator.chunks.join();
      if (text.isEmpty) continue;
      payloads.add(
        DesktopContinuityTransientPayload(
          turnId: accumulator.turnId,
          payload: accumulator.kind == _TransientKind.thinking
              ? ThinkingDeltaMessage(text: text)
              : StreamDeltaMessage(text: text),
        ),
      );
    }
    return DesktopContinuityBacklogSnapshot(
      sessionId: sessionId,
      threadId: threadId,
      bridgeInstanceId: bridgeInstanceId,
      state: state,
      turnId: turnId,
      turnSteerable: turnSteerable,
      handoffQueued: handoffQueued,
      itemKeys: itemKeys,
      transientPayloads: List.unmodifiable(payloads),
      truncated: truncated,
    );
  }
}

class _TransientChunks {
  _TransientChunks({required this.turnId, required this.kind});

  final String? turnId;
  final _TransientKind kind;
  final Queue<String> chunks = Queue();
  int characters = 0;
}
