import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/desktop_continuity_backlog.dart';
import 'package:flutter_test/flutter_test.dart';

CodexDesktopContinuityEventMessage _event({
  required CodexDesktopContinuityEventKind event,
  CodexDesktopContinuityState? state,
  String? itemKey,
  ServerMessage? payload,
  String? turnId = 'turn-1',
  String bridgeInstanceId = 'bridge-1',
  bool turnSteerable = false,
  String? timestamp,
}) {
  return CodexDesktopContinuityEventMessage(
    event: event,
    requestId: 'list-watch',
    bridgeInstanceId: bridgeInstanceId,
    sessionId: 'session-1',
    threadId: 'thread-1',
    origin: 'desktop_rollout',
    state: state,
    turnId: turnId,
    turnSteerable: turnSteerable,
    timestamp: timestamp,
    itemKey: itemKey,
    payload: payload,
  );
}

ServerMessage _timestampedPayload(
  Map<String, dynamic> json,
  String sourceTimestamp,
) => ServerMessage.fromJson({
  ...json,
  'sourceTimestamp': sourceTimestamp,
  'sourceTimestampIsAuthoritative': true,
});

void main() {
  test('aggregates live deltas and deduplicates continuity item keys', () {
    final backlog = DesktopContinuityBacklog();

    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.watching,
        state: CodexDesktopContinuityState.running,
      ),
    );
    expect(
      backlog.record(
        _event(
          event: CodexDesktopContinuityEventKind.message,
          itemKey: 'thinking-1',
          payload: const ThinkingDeltaMessage(text: 'Inspecting '),
        ),
      ),
      isTrue,
    );
    expect(
      backlog.record(
        _event(
          event: CodexDesktopContinuityEventKind.message,
          itemKey: 'thinking-1',
          payload: const ThinkingDeltaMessage(text: 'duplicate'),
        ),
      ),
      isFalse,
    );
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        itemKey: 'thinking-2',
        payload: const ThinkingDeltaMessage(text: 'files'),
      ),
    );
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        itemKey: 'output-1',
        payload: const StreamDeltaMessage(text: 'Partial answer'),
      ),
    );

    final snapshot = backlog.take('session-1', threadId: 'thread-1');

    expect(snapshot, isNotNull);
    expect(snapshot!.state, CodexDesktopContinuityState.running);
    expect(snapshot.itemKeys, {'thinking-1', 'thinking-2', 'output-1'});
    expect(snapshot.transientPayloads, hasLength(2));
    expect(
      (snapshot.transientPayloads.first.payload as ThinkingDeltaMessage).text,
      'Inspecting files',
    );
    expect(
      (snapshot.transientPayloads.last.payload as StreamDeltaMessage).text,
      'Partial answer',
    );
    expect(backlog.take('session-1'), isNull);
  });

  test('retains authoritative time when backlog deltas are aggregated', () {
    final backlog = DesktopContinuityBacklog();
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        itemKey: 'thinking-1',
        payload: _timestampedPayload({
          'type': 'thinking_delta',
          'text': 'first ',
        }, '2026-07-31T01:00:00.000Z'),
      ),
    );
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        itemKey: 'thinking-2',
        payload: _timestampedPayload({
          'type': 'thinking_delta',
          'text': 'second',
        }, '2026-07-31T01:00:01.000Z'),
      ),
    );
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        itemKey: 'output-1',
        payload: _timestampedPayload({
          'type': 'stream_delta',
          'text': 'answer',
        }, '2026-07-31T01:00:02.000Z'),
      ),
    );

    final snapshot = backlog.take('session-1')!;
    final thinking = snapshot.transientPayloads.first.payload;
    final output = snapshot.transientPayloads.last.payload;

    expect(
      serverMessageTimestamp(thinking),
      isA<ServerMessageTimestamp>()
          .having(
            (value) => value.value,
            'value',
            DateTime.parse('2026-07-31T01:00:01.000Z'),
          )
          .having((value) => value.isAuthoritative, 'isAuthoritative', isTrue),
    );
    expect(
      serverMessageTimestamp(output),
      isA<ServerMessageTimestamp>()
          .having(
            (value) => value.value,
            'value',
            DateTime.parse('2026-07-31T01:00:02.000Z'),
          )
          .having((value) => value.isAuthoritative, 'isAuthoritative', isTrue),
    );
  });

  test('terminal state clears stale live deltas before handoff', () {
    final backlog = DesktopContinuityBacklog();
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        itemKey: 'thinking-1',
        payload: const ThinkingDeltaMessage(text: 'done soon'),
      ),
    );
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.state,
        state: CodexDesktopContinuityState.idle,
      ),
    );

    final snapshot = backlog.take('session-1');

    expect(snapshot!.state, CodexDesktopContinuityState.idle);
    expect(snapshot.transientPayloads, isEmpty);
  });

  test('preserves exact turn steerability and clears it fail closed', () {
    final backlog = DesktopContinuityBacklog();
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.watching,
        state: CodexDesktopContinuityState.running,
        turnSteerable: true,
      ),
    );

    expect(backlog.take('session-1')!.turnSteerable, isTrue);

    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.watching,
        state: CodexDesktopContinuityState.running,
      ),
    );
    expect(backlog.take('session-1')!.turnSteerable, isFalse);
  });

  test('transient storage and item-key ledgers stay bounded', () {
    final backlog = DesktopContinuityBacklog(
      maxItemKeysPerSession: 2,
      maxTransientCharactersPerSession: 5,
    );
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        itemKey: 'one',
        payload: const ThinkingDeltaMessage(text: '1234'),
      ),
    );
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        itemKey: 'two',
        payload: const ThinkingDeltaMessage(text: '5678'),
      ),
    );
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        itemKey: 'three',
        payload: const StreamDeltaMessage(text: 'ok'),
      ),
    );

    final snapshot = backlog.take('session-1');

    expect(snapshot!.truncated, isTrue);
    expect(snapshot.itemKeys, {'two', 'three'});
    expect(snapshot.transientPayloads, hasLength(1));
    expect(
      (snapshot.transientPayloads.single.payload as StreamDeltaMessage).text,
      'ok',
    );
  });

  test('take rejects a backlog owned by another Bridge instance', () {
    final backlog = DesktopContinuityBacklog();
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        itemKey: 'thinking-1',
        payload: const ThinkingDeltaMessage(text: 'from bridge one'),
      ),
    );

    expect(
      backlog.take(
        'session-1',
        threadId: 'thread-1',
        bridgeInstanceId: 'bridge-2',
      ),
      isNull,
    );
    expect(
      backlog.take(
        'session-1',
        threadId: 'thread-1',
        bridgeInstanceId: 'bridge-1',
      ),
      isNotNull,
    );
  });

  test('new Bridge instance replaces same-id pending source atomically', () {
    final backlog = DesktopContinuityBacklog();
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        itemKey: 'same-key',
        payload: const ThinkingDeltaMessage(text: 'old source'),
      ),
    );
    backlog.record(
      _event(
        event: CodexDesktopContinuityEventKind.message,
        bridgeInstanceId: 'bridge-2',
        itemKey: 'same-key',
        payload: const ThinkingDeltaMessage(text: 'new source'),
      ),
    );

    final snapshot = backlog.take(
      'session-1',
      threadId: 'thread-1',
      bridgeInstanceId: 'bridge-2',
    );
    expect(snapshot, isNotNull);
    expect(snapshot!.bridgeInstanceId, 'bridge-2');
    expect(snapshot.itemKeys, {'same-key'});
    expect(
      (snapshot.transientPayloads.single.payload as ThinkingDeltaMessage).text,
      'new source',
    );
  });
}
