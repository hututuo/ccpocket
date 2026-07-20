import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/desktop_continuity_backlog.dart';
import 'package:flutter_test/flutter_test.dart';

CodexDesktopContinuityEventMessage _event({
  required CodexDesktopContinuityEventKind event,
  CodexDesktopContinuityState? state,
  String? itemKey,
  ServerMessage? payload,
  String? turnId = 'turn-1',
}) {
  return CodexDesktopContinuityEventMessage(
    event: event,
    requestId: 'list-watch',
    bridgeInstanceId: 'bridge-1',
    sessionId: 'session-1',
    threadId: 'thread-1',
    origin: 'desktop_rollout',
    state: state,
    turnId: turnId,
    itemKey: itemKey,
    payload: payload,
  );
}

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
}
