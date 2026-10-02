import 'package:ccpocket/features/chat_session/state/detached_timeline_projection.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

Iterable<String> _aliases(ChatEntry entry) sync* {
  if (entry is UserChatEntry) {
    if (entry.providerItemId case final String providerId) {
      yield 'user:${entry.historyTurnId}:$providerId';
    }
    if (entry.clientMessageId case final String clientId) {
      yield 'client:$clientId';
    }
  }
}

DetachedCanonicalHistoryCandidate _prepare(List<ChatEntry> entries) =>
    prepareDetachedCanonicalHistory(
      canonicalEntries: entries,
      exactAliases: _aliases,
      mergeEquivalent: (overlay, canonical) => overlay,
    );

void main() {
  test('prepared canonical input and receipt evidence remain immutable', () {
    final user = UserChatEntry(
      'Canonical prompt',
      providerItemId: 'provider-user',
      historyTurnId: 'turn-canonical',
      clientMessageId: 'client-canonical',
      status: MessageStatus.sent,
    );
    final input = <ChatEntry>[user];
    final candidate = _prepare(input);
    input.clear();

    expect(candidate.isAccepted, isTrue);
    expect(candidate.canonicalEntries, [user]);
    expect(candidate.acknowledgedClientMessageIds, ['client-canonical']);
    expect(() => candidate.canonicalEntries.clear(), throwsUnsupportedError);
    expect(
      () => candidate.acknowledgedClientMessageIds.clear(),
      throwsUnsupportedError,
    );
    expect(
      candidate
          .compose(outgoingOverlays: const [], runtimeOverlays: const [])
          .entries,
      [user],
    );
  });

  test('a rejected candidate supplies no canonical receipt evidence', () {
    final user = UserChatEntry(
      'Duplicate canonical prompt',
      providerItemId: 'provider-duplicate',
      historyTurnId: 'turn-duplicate',
      clientMessageId: 'client-duplicate',
      status: MessageStatus.sent,
    );
    final candidate = _prepare([user, user]);

    expect(candidate.isAccepted, isFalse);
    expect(candidate.duplicateCanonicalCount, 1);
    expect(candidate.acknowledgedClientMessageIds, isEmpty);
    final projection = candidate.compose(
      outgoingOverlays: const [],
      runtimeOverlays: const [],
    );
    expect(projection.duplicateCanonicalCount, 1);
    expect(candidate.acknowledgedClientMessageIds, isEmpty);
  });

  test('overlay enrichment cannot invent a canonical client receipt', () {
    final canonical = UserChatEntry(
      'Provider prompt',
      providerItemId: 'provider-shared',
      historyTurnId: 'turn-shared',
      status: MessageStatus.sent,
    );
    final overlay = UserChatEntry(
      'Provider prompt',
      providerItemId: 'provider-shared',
      historyTurnId: 'turn-shared',
      clientMessageId: 'client-local-only',
    );
    final candidate = _prepare([canonical]);
    final projection = candidate.compose(
      outgoingOverlays: [overlay],
      runtimeOverlays: const [],
    );

    expect(
      (projection.entries.single as UserChatEntry).clientMessageId,
      'client-local-only',
    );
    expect(candidate.acknowledgedClientMessageIds, isEmpty);
    expect(
      (candidate.canonicalEntries.single as UserChatEntry).clientMessageId,
      isNull,
    );
  });

  test('composing current overlays cannot mutate another projection', () {
    final canonical = UserChatEntry(
      'Canonical prompt',
      clientMessageId: 'client-canonical',
    );
    final firstOverlay = UserChatEntry(
      'First input',
      clientMessageId: 'client-a',
    );
    final secondOverlay = UserChatEntry(
      'Second input',
      clientMessageId: 'client-b',
    );
    final candidate = _prepare([canonical]);
    final first = candidate.compose(
      outgoingOverlays: [firstOverlay],
      runtimeOverlays: const [],
    );
    final second = candidate.compose(
      outgoingOverlays: [secondOverlay],
      runtimeOverlays: const [],
    );

    expect(first.entries, [canonical, firstOverlay]);
    expect(second.entries, [canonical, secondOverlay]);
    expect(candidate.canonicalEntries, [canonical]);
    expect(first.outgoingOverlayCount, 1);
    expect(second.outgoingOverlayCount, 1);
    expect(() => first.entries.clear(), throwsUnsupportedError);
  });
}
