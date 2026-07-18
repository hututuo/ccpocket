import 'dart:async';

import 'package:ccpocket/features/session_archive/session_archive_pending_requests.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

class _ManualTimer implements Timer {
  _ManualTimer(this._callback);

  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;
}

void main() {
  late List<_ManualTimer> timers;
  late List<
    ({List<PendingArchiveRequest> requests, ArchiveResultUnknownReason reason})
  >
  unknown;

  SessionArchivePendingRequests createTracker() =>
      SessionArchivePendingRequests(
        timeout: const Duration(seconds: 20),
        timerFactory: (duration, callback) {
          expect(duration, const Duration(seconds: 20));
          final timer = _ManualTimer(callback);
          timers.add(timer);
          return timer;
        },
        onResultUnknown: (requests, reason) {
          unknown.add((requests: requests, reason: reason));
        },
      );

  setUp(() {
    timers = [];
    unknown = [];
  });

  test('requires exact request, provider, and session correlation', () {
    final tracker = createTracker();
    addTearDown(tracker.dispose);
    expect(
      tracker.register(
        requestId: 'request-1',
        sessionId: 'thread-1',
        provider: 'codex',
        identityKey: 'codex\u0000thread-1',
      ),
      isTrue,
    );

    expect(
      tracker.resolve(
        const ArchiveResultMessage(
          requestId: 'request-1',
          sessionId: 'thread-1',
          success: true,
        ),
      ),
      isNull,
    );
    expect(
      tracker.resolve(
        const ArchiveResultMessage(
          requestId: 'request-1',
          sessionId: 'thread-1',
          provider: 'claude',
          success: true,
        ),
      ),
      isNull,
    );
    expect(
      tracker.resolve(
        const ArchiveResultMessage(
          requestId: 'request-1',
          sessionId: 'other-thread',
          provider: 'codex',
          success: true,
        ),
      ),
      isNull,
    );

    final resolved = tracker.resolve(
      const ArchiveResultMessage(
        requestId: 'request-1',
        sessionId: 'thread-1',
        provider: 'codex',
        success: true,
      ),
    );
    expect(resolved?.requestId, 'request-1');
    expect(tracker.identityKeys, isEmpty);
    expect(timers.single.isActive, isFalse);
  });

  test('legacy result without request id needs one unique candidate', () {
    final tracker = createTracker();
    addTearDown(tracker.dispose);
    tracker.register(
      requestId: 'codex-request',
      sessionId: 'shared',
      provider: 'codex',
      identityKey: 'codex\u0000shared',
    );
    tracker.register(
      requestId: 'claude-request',
      sessionId: 'shared',
      provider: 'claude',
      identityKey: 'claude\u0000shared',
    );

    expect(
      tracker.resolve(
        const ArchiveResultMessage(sessionId: 'shared', success: true),
      ),
      isNull,
    );
    final resolved = tracker.resolve(
      const ArchiveResultMessage(
        sessionId: 'shared',
        provider: 'codex',
        success: true,
      ),
    );
    expect(resolved?.requestId, 'codex-request');
    expect(tracker.identityKeys, {'claude\u0000shared'});
  });

  test('timeout releases busy state and reports unknown without retrying', () {
    final tracker = createTracker();
    addTearDown(tracker.dispose);
    tracker.register(
      requestId: 'request-timeout',
      sessionId: 'thread-timeout',
      provider: 'codex',
      identityKey: 'codex\u0000thread-timeout',
    );

    timers.single.fire();

    expect(tracker.identityKeys, isEmpty);
    expect(unknown, hasLength(1));
    expect(unknown.single.reason, ArchiveResultUnknownReason.timeout);
    expect(unknown.single.requests.single.requestId, 'request-timeout');
  });

  test('disconnect clears every timer once and permits explicit retry', () {
    final tracker = createTracker();
    addTearDown(tracker.dispose);
    tracker.register(
      requestId: 'request-a',
      sessionId: 'thread-a',
      provider: 'codex',
      identityKey: 'codex\u0000thread-a',
    );
    tracker.register(
      requestId: 'request-b',
      sessionId: 'thread-b',
      provider: 'codex',
      identityKey: 'codex\u0000thread-b',
    );

    tracker.connectionLost();

    expect(tracker.identityKeys, isEmpty);
    expect(timers.every((timer) => !timer.isActive), isTrue);
    expect(unknown, hasLength(1));
    expect(unknown.single.reason, ArchiveResultUnknownReason.disconnected);
    expect(unknown.single.requests, hasLength(2));
    expect(
      tracker.register(
        requestId: 'explicit-retry',
        sessionId: 'thread-a',
        provider: 'codex',
        identityKey: 'codex\u0000thread-a',
      ),
      isTrue,
    );
  });

  test(
    'dispose cancels pending timers without surfacing stale UI callbacks',
    () {
      final tracker = createTracker();
      tracker.register(
        requestId: 'request-dispose',
        sessionId: 'thread-dispose',
        provider: 'codex',
        identityKey: 'codex\u0000thread-dispose',
      );

      tracker.dispose();
      timers.single.fire();

      expect(tracker.identityKeys, isEmpty);
      expect(unknown, isEmpty);
    },
  );
}
