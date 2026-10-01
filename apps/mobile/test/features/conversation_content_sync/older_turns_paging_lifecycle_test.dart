import 'dart:async';

import 'package:ccpocket/features/conversation_content_sync/conversation_turns_page_load_result.dart';
import 'package:ccpocket/features/conversation_content_sync/older_turns_paging_lifecycle.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _loaded = ConversationTurnsPageLoadResult(loaded: true, hasMore: false);

OlderTurnsPageRequest _begin(
  OlderTurnsPagingLifecycle lifecycle, {
  String id = 'request-a',
  int generation = 1,
  String source = 'source-a',
  String provider = 'codex',
  String thread = 'thread-a',
}) => lifecycle.begin(
  requestId: id,
  generation: generation,
  targetFingerprint: source,
  provider: provider,
  providerSessionId: thread,
  expectedRevision: 'canonical',
  expectedCursor: 'older-page-1',
);

void main() {
  test('expires at 15 seconds and rejects a reply after the deadline', () {
    fakeAsync((time) {
      final lifecycle = OlderTurnsPagingLifecycle();
      final request = _begin(lifecycle);
      Object? failure;
      request.result.then<void>(
        (_) => fail('An expired page must not succeed'),
        onError: (Object error) => failure = error,
      );
      time.elapse(
        const Duration(seconds: 15) - const Duration(milliseconds: 1),
      );
      time.flushMicrotasks();
      expect(failure, isNull);
      expect(lifecycle.find(request.requestId), same(request));
      time.elapse(const Duration(milliseconds: 1));
      time.flushMicrotasks();
      expect(failure, isA<TimeoutException>());
      expect(
        (failure as TimeoutException).duration,
        const Duration(seconds: 15),
      );
      expect(lifecycle.pendingCount, 0);
      expect(time.nonPeriodicTimerCount, 0);
      expect(lifecycle.complete(request, _loaded), isFalse);
    });
  });

  test('success retires the request and cancels its response deadline', () {
    fakeAsync((time) {
      final lifecycle = OlderTurnsPagingLifecycle();
      final request = _begin(lifecycle);
      ConversationTurnsPageLoadResult? received;
      request.result.then((result) => received = result);
      expect(lifecycle.complete(request, _loaded), isTrue);
      expect(lifecycle.find(request.requestId), isNull);
      expect(lifecycle.pendingCount, 0);
      expect(time.nonPeriodicTimerCount, 0);
      time.elapse(const Duration(minutes: 1));
      expect(received, same(_loaded));
      expect(lifecycle.fail(request, StateError('late error')), isFalse);
      expect(lifecycle.complete(request, _loaded), isFalse);
    });
  });

  test(
    'failure retains the original error and stack and cancels its timer',
    () {
      fakeAsync((time) {
        final lifecycle = OlderTurnsPagingLifecycle();
        final request = _begin(lifecycle);
        final error = StateError('send failed');
        final stack = StackTrace.fromString('original send stack');
        Object? receivedError;
        StackTrace? receivedStack;
        request.result.then<void>(
          (_) => fail('The failed request must not succeed'),
          onError: (Object error, StackTrace stack) {
            receivedError = error;
            receivedStack = stack;
          },
        );
        expect(lifecycle.fail(request, error, stack), isTrue);
        time.flushMicrotasks();
        expect(receivedError, same(error));
        expect(receivedStack, same(stack));
        expect(lifecycle.pendingCount, 0);
        expect(time.nonPeriodicTimerCount, 0);
        expect(lifecycle.complete(request, _loaded), isFalse);
      });
    },
  );

  test(
    'an old handle cannot settle a replacement with the same request ID',
    () {
      fakeAsync((time) {
        final lifecycle = OlderTurnsPagingLifecycle();
        final old = _begin(lifecycle);
        old.result.then<void>((_) {}, onError: (Object _) {});
        expect(() => _begin(lifecycle), throwsStateError);
        lifecycle.fail(old, StateError('subscription replaced'));
        final current = _begin(lifecycle);
        ConversationTurnsPageLoadResult? received;
        current.result.then((result) => received = result);
        expect(lifecycle.complete(old, _loaded), isFalse);
        expect(lifecycle.find(current.requestId), same(current));
        expect(lifecycle.pendingCount, 1);
        expect(time.nonPeriodicTimerCount, 1);
        lifecycle.complete(current, _loaded);
        time.flushMicrotasks();
        expect(received, same(_loaded));
        expect(time.nonPeriodicTimerCount, 0);
      });
    },
  );

  test(
    'target cancellation preserves other threads, sources and generations',
    () {
      fakeAsync((time) {
        final lifecycle = OlderTurnsPagingLifecycle();
        final requests = [
          _begin(lifecycle),
          _begin(lifecycle, id: 'other-thread', thread: 'thread-b'),
          _begin(lifecycle, id: 'other-source', source: 'source-b'),
          _begin(lifecycle, id: 'other-generation', generation: 2),
          _begin(lifecycle, id: 'other-provider', provider: 'claude'),
        ];
        final failures = <Object>[];
        for (final request in requests) {
          request.result.then<void>(
            (_) {},
            onError: (Object error) => failures.add(error),
          );
        }
        final reset = StateError('thread reset');
        lifecycle.failTarget(
          generation: 1,
          targetFingerprint: 'source-a',
          provider: 'codex',
          providerSessionId: 'thread-a',
          error: reset,
        );
        time.flushMicrotasks();
        expect(failures, [same(reset)]);
        expect(lifecycle.find(requests.first.requestId), isNull);
        expect(lifecycle.pendingCount, 4);
        expect(time.nonPeriodicTimerCount, 4);
        for (final request in requests.skip(1)) {
          expect(lifecycle.find(request.requestId), same(request));
          lifecycle.complete(request, _loaded);
        }
        time.flushMicrotasks();
        expect(lifecycle.pendingCount, 0);
        expect(time.nonPeriodicTimerCount, 0);
      });
    },
  );

  test(
    'duplicate callers share a flight and a failed flight can be retried',
    () {
      fakeAsync((time) {
        final lifecycle = OlderTurnsPagingLifecycle();
        final provider = Completer<ConversationTurnsPageLoadResult>();
        var starts = 0;
        final first = lifecycle.runFlight('thread-a', () {
          starts += 1;
          return provider.future;
        });
        final duplicate = lifecycle.runFlight('thread-a', () {
          starts += 1;
          return Future.value(_loaded);
        });
        expect(duplicate, same(first));
        expect(starts, 1);
        Object? receivedError;
        first.then<void>(
          (_) {},
          onError: (Object error) => receivedError = error,
        );
        final error = StateError('provider failed');
        provider.completeError(error);
        time.flushMicrotasks();
        expect(receivedError, same(error));
        expect(lifecycle.flightCount, 0);
        final retry = lifecycle.runFlight('thread-a', () {
          starts += 1;
          return Future.value(_loaded);
        });
        retry.then<void>((_) {});
        time.flushMicrotasks();
        expect(starts, 2);
        expect(lifecycle.flightCount, 0);
      });
    },
  );

  test('synchronous host errors retire the flight and retain the error', () {
    fakeAsync((time) {
      final lifecycle = OlderTurnsPagingLifecycle();
      final error = StateError('host failed before returning a future');
      Object? receivedError;
      lifecycle
          .runFlight('thread-a', () => throw error)
          .then<void>(
            (_) => fail('The failed host operation must not succeed'),
            onError: (Object error) => receivedError = error,
          );
      time.flushMicrotasks();
      expect(receivedError, same(error));
      expect(lifecycle.flightCount, 0);
    });
  });

  test(
    'global cancellation keeps local host work joinable until it finishes',
    () {
      fakeAsync((time) {
        final lifecycle = OlderTurnsPagingLifecycle();
        final localWork = Completer<void>();
        final otherRequest = _begin(
          lifecycle,
          id: 'other-thread',
          thread: 'thread-b',
        );
        otherRequest.result.then<void>((_) {}, onError: (Object _) {});
        Object? requestFailure;
        final flight = lifecycle.runFlight('thread-a', () async {
          final request = _begin(lifecycle);
          try {
            await request.result;
          } catch (error) {
            requestFailure = error;
          }
          await localWork.future;
          return _loaded;
        });
        var hostFinished = false;
        flight.then<void>((_) => hostFinished = true);
        time.flushMicrotasks();
        final stopped = StateError('source stopped');
        lifecycle.failAll(stopped);
        time.flushMicrotasks();
        expect(requestFailure, same(stopped));
        expect(lifecycle.pendingCount, 0);
        expect(time.nonPeriodicTimerCount, 0);
        expect(lifecycle.flights.single, same(flight));
        expect(hostFinished, isFalse);
        localWork.complete();
        time.flushMicrotasks();
        expect(hostFinished, isTrue);
        expect(lifecycle.flightCount, 0);
      });
    },
  );
}
