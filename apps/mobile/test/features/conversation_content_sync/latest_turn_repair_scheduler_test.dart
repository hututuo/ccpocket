import 'dart:async';

import 'package:ccpocket/features/conversation_content_sync/latest_turn_repair_scheduler.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

LatestTurnRepairRequest _request({
  String thread = 'thread-a',
  String revision = 'canonical',
}) => LatestTurnRepairRequest(
  generation: 1,
  targetFingerprint: 'source-a',
  provider: 'codex',
  providerSessionId: thread,
  revision: revision,
  observation: 'observed-$revision',
  repair: 'turns_page',
);

void main() {
  test(
    'backs off at 1/2/4 seconds and bounds one operation to four failures',
    () {
      fakeAsync((time) {
        var requests = 0;
        late LatestTurnRepairScheduler scheduler;
        scheduler = LatestTurnRepairScheduler(
          isCurrent: (_) => true,
          repair: (_) {
            requests += 1;
            return Future.error(StateError('provider unavailable'));
          },
          recheck: (schedulerRequest) => scheduler.schedule(schedulerRequest),
        );
        scheduler.schedule(_request());
        time.flushMicrotasks();
        expect(requests, 1);
        for (final delay in [1, 2, 4]) {
          time.elapse(
            Duration(seconds: delay) - const Duration(milliseconds: 1),
          );
          final before = requests;
          // Replayed observations cannot bypass a pending backoff.
          scheduler.schedule(_request());
          time.flushMicrotasks();
          expect(requests, before);
          time.elapse(const Duration(milliseconds: 1));
          time.flushMicrotasks();
          expect(requests, before + 1);
        }
        expect(requests, 4);
        time.elapse(const Duration(minutes: 1));
        scheduler.schedule(_request());
        time.flushMicrotasks();
        expect(requests, 4);
        expect(time.nonPeriodicTimerCount, 0);
        // The retained bound belongs to the original revision/turn/repair key.
        scheduler.schedule(_request(revision: 'next-canonical'));
        time.flushMicrotasks();
        expect(requests, 5);
        scheduler.clearAll();
        expect(time.nonPeriodicTimerCount, 0);
      });
    },
  );

  test('clearing all operations cancels retry timers and queued work', () {
    fakeAsync((time) {
      var requests = 0;
      var rechecks = 0;
      final scheduler = LatestTurnRepairScheduler(
        isCurrent: (_) => true,
        repair: (_) {
          requests += 1;
          return Future.error(StateError('provider unavailable'));
        },
        recheck: (_) => rechecks += 1,
      );
      scheduler.schedule(_request());
      time.flushMicrotasks();
      expect(requests, 1);
      expect(time.nonPeriodicTimerCount, 1);
      scheduler.clearAll();
      time.elapse(const Duration(minutes: 1));
      expect(rechecks, 0);
      expect(scheduler.pendingCount, 0);
      expect(time.nonPeriodicTimerCount, 0);
      scheduler.schedule(_request());
      scheduler.clearAll();
      time.flushMicrotasks();
      expect(requests, 1);
    });
  });

  test(
    'clearing one target leaves other targets live and rejects its late failure',
    () {
      fakeAsync((time) {
        final pending = <String, Completer<LatestTurnRepairOutcome>>{};
        var rechecks = 0;
        final scheduler = LatestTurnRepairScheduler(
          isCurrent: (_) => true,
          repair: (request) {
            final completer = Completer<LatestTurnRepairOutcome>();
            pending[request.providerSessionId] = completer;
            return completer.future;
          },
          recheck: (_) => rechecks += 1,
        );
        scheduler.schedule(_request());
        scheduler.schedule(_request(thread: 'thread-b'));
        time.flushMicrotasks();
        expect(scheduler.pendingCount, 2);
        scheduler.clearTarget(
          targetFingerprint: 'source-a',
          provider: 'codex',
          providerSessionId: 'thread-a',
        );
        pending['thread-a']!.completeError(StateError('late failure'));
        time.flushMicrotasks();
        expect(scheduler.pendingCount, 1);
        expect(time.nonPeriodicTimerCount, 0);
        pending['thread-b']!.complete((
          loaded: true,
          hasMore: false,
          repairObservation: 'observed-canonical',
        ));
        time.flushMicrotasks();
        expect(scheduler.pendingCount, 0);
        expect(rechecks, 0);
        scheduler.clearAll();
      });
    },
  );

  test(
    'an old completion cannot retire the new owner of the same operation',
    () {
      fakeAsync((time) {
        final pending = <Completer<LatestTurnRepairOutcome>>[];
        final scheduler = LatestTurnRepairScheduler(
          isCurrent: (_) => true,
          repair: (_) {
            final completer = Completer<LatestTurnRepairOutcome>();
            pending.add(completer);
            return completer.future;
          },
          recheck: (_) => fail('Unchanged progress must not recheck'),
        );
        scheduler.schedule(_request());
        time.flushMicrotasks();
        scheduler.clearAll();
        scheduler.schedule(_request());
        time.flushMicrotasks();
        expect(pending, hasLength(2));
        pending.first.complete((
          loaded: true,
          hasMore: false,
          repairObservation: 'observed-canonical',
        ));
        time.flushMicrotasks();
        expect(scheduler.pendingCount, 1);
        pending.last.complete((
          loaded: true,
          hasMore: false,
          repairObservation: 'observed-canonical',
        ));
        time.flushMicrotasks();
        expect(scheduler.pendingCount, 0);
        scheduler.schedule(_request());
        time.flushMicrotasks();
        expect(pending, hasLength(2));
        scheduler.clearAll();
      });
    },
  );
}
