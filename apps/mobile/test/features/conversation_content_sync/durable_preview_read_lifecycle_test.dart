import 'package:ccpocket/features/conversation_content_sync/durable_preview_read_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DurablePreviewReadTicket begin(
    DurablePreviewReadLifecycle reads, {
    String target = 'source-a',
    String thread = 'thread',
    int epoch = 1,
  }) => reads.begin(
    targetFingerprint: target,
    providerSessionId: thread,
    cacheCommitEpoch: epoch,
  )!;

  test('notifications merge into one follow-up and then become idle', () {
    final reads = DurablePreviewReadLifecycle();
    final read = begin(reads);
    for (var i = 0; i < 10; i++) {
      expect(
        reads.begin(
          targetFingerprint: 'source-a',
          providerSessionId: 'thread',
          cacheCommitEpoch: 1,
        ),
        isNull,
      );
    }
    expect(
      reads.shouldAccept(
        read,
        targetIsCurrent: true,
        currentCacheCommitEpoch: 1,
      ),
      isFalse,
    );
    expect(reads.finish(read), isTrue);
    final followUp = begin(reads);
    expect(
      reads.shouldAccept(
        followUp,
        targetIsCurrent: true,
        currentCacheCommitEpoch: 1,
      ),
      isTrue,
    );
    expect(reads.finish(followUp), isFalse);
    expect(reads.isLoading, isFalse);
    expect(reads.loadingTargetFingerprint, isNull);
  });

  test(
    'an epoch change without a delivered notification still needs a reread',
    () {
      final reads = DurablePreviewReadLifecycle();
      final read = begin(reads);
      expect(
        reads.shouldAccept(
          read,
          targetIsCurrent: true,
          currentCacheCommitEpoch: 2,
        ),
        isFalse,
      );
      expect(reads.finish(read), isTrue);
      final current = begin(reads, epoch: 2);
      expect(
        reads.shouldAccept(
          current,
          targetIsCurrent: true,
          currentCacheCommitEpoch: 2,
        ),
        isTrue,
      );
      expect(reads.finish(current), isFalse);
    },
  );

  test('a source or route conflict rejects the active result and error', () {
    final reads = DurablePreviewReadLifecycle();
    final read = begin(reads);
    expect(
      reads.shouldAccept(
        read,
        targetIsCurrent: false,
        currentCacheCommitEpoch: 1,
      ),
      isFalse,
    );
    expect(reads.finish(read), isTrue);
    expect(reads.isLoading, isFalse);
  });

  test(
    'late finally cannot release a newer owner or consume its notification',
    () {
      final reads = DurablePreviewReadLifecycle();
      final old = begin(reads);
      reads.invalidate();
      final current = begin(reads, target: 'source-b', thread: 'new-thread');
      reads.markDirty();
      expect(
        reads.shouldAccept(
          old,
          targetIsCurrent: true,
          currentCacheCommitEpoch: 1,
        ),
        isFalse,
      );
      expect(reads.finish(old), isFalse);
      expect(reads.isLoading, isTrue);
      expect(reads.loadingTargetFingerprint, 'source-b');
      expect(reads.finish(current), isTrue);
    },
  );

  test('returning to the same target cannot revive an old ticket', () {
    final reads = DurablePreviewReadLifecycle();
    final old = begin(reads);
    reads.invalidate();
    begin(reads, target: 'source-b');
    reads.invalidate();
    final current = begin(reads);
    expect(
      reads.shouldAccept(
        old,
        targetIsCurrent: true,
        currentCacheCommitEpoch: 1,
      ),
      isFalse,
    );
    expect(reads.finish(old), isFalse);
    expect(
      reads.shouldAccept(
        current,
        targetIsCurrent: true,
        currentCacheCommitEpoch: 1,
      ),
      isTrue,
    );
    expect(reads.finish(current), isFalse);
  });

  test('invalidation discards old dirty work when the route attaches', () {
    final reads = DurablePreviewReadLifecycle();
    final old = begin(reads);
    reads.markDirty();
    reads.invalidate();
    expect(reads.finish(old), isFalse);
    final current = begin(reads);
    expect(
      reads.shouldAccept(
        current,
        targetIsCurrent: true,
        currentCacheCommitEpoch: 1,
      ),
      isTrue,
    );
    expect(reads.finish(current), isFalse);
  });

  test('dispose rejects late work and prevents any restart', () {
    final reads = DurablePreviewReadLifecycle();
    final old = begin(reads);
    reads.markDirty();
    reads.dispose();
    expect(
      reads.shouldAccept(
        old,
        targetIsCurrent: true,
        currentCacheCommitEpoch: 1,
      ),
      isFalse,
    );
    expect(reads.finish(old), isFalse);
    expect(reads.isLoading, isFalse);
    expect(
      reads.begin(
        targetFingerprint: 'source-a',
        providerSessionId: 'thread',
        cacheCommitEpoch: 1,
      ),
      isNull,
    );
  });
}
