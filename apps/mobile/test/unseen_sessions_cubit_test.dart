import 'dart:convert';

import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/providers/unseen_sessions_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

SessionInfo _session({
  required String id,
  String? provider,
  String? providerSessionId,
  String status = 'idle',
  String lastActivityAt = '2026-03-11T10:00:00Z',
}) {
  return SessionInfo(
    id: id,
    provider: provider,
    projectPath: '/test',
    claudeSessionId: providerSessionId,
    status: status,
    createdAt: '2026-03-11T09:00:00Z',
    lastActivityAt: lastActivityAt,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('UnseenSessionsCubit', () {
    test('idle session with no seen-at record is unseen', () async {
      final cubit = UnseenSessionsCubit();
      await cubit.ready;

      cubit.updateSessions([_session(id: 'a')]);
      expect(cubit.state, contains('a'));
      expect(cubit.isUnseen('a'), isTrue);

      await cubit.close();
    });

    test('non-idle sessions are never unseen', () async {
      final cubit = UnseenSessionsCubit();
      await cubit.ready;

      cubit.updateSessions([
        _session(id: 'a', status: 'running'),
        _session(id: 'b', status: 'waiting_approval'),
        _session(id: 'c', status: 'starting'),
      ]);
      expect(cubit.state, isEmpty);

      await cubit.close();
    });

    test('markSeen removes session from unseen set', () async {
      final cubit = UnseenSessionsCubit();
      await cubit.ready;

      cubit.updateSessions([_session(id: 'a')]);
      expect(cubit.isUnseen('a'), isTrue);

      cubit.markSeen('a');
      expect(cubit.isUnseen('a'), isFalse);

      await cubit.close();
    });

    test('markSeen persists and subsequent updates respect seen-at', () async {
      final cubit = UnseenSessionsCubit();
      await cubit.ready;

      cubit.updateSessions([
        _session(id: 'a', lastActivityAt: '2026-03-11T10:00:00Z'),
      ]);
      expect(cubit.isUnseen('a'), isTrue);

      cubit.markSeen('a');
      expect(cubit.isUnseen('a'), isFalse);

      // Same lastActivityAt → still seen
      cubit.updateSessions([
        _session(id: 'a', lastActivityAt: '2026-03-11T10:00:00Z'),
      ]);
      expect(cubit.isUnseen('a'), isFalse);

      // Newer lastActivityAt → unseen again
      cubit.updateSessions([
        _session(id: 'a', lastActivityAt: '2099-01-01T00:00:00Z'),
      ]);
      expect(cubit.isUnseen('a'), isTrue);

      await cubit.close();
    });

    test('empty lastActivityAt is never unseen', () async {
      final cubit = UnseenSessionsCubit();
      await cubit.ready;

      cubit.updateSessions([_session(id: 'a', lastActivityAt: '')]);
      expect(cubit.state, isEmpty);

      await cubit.close();
    });

    test('multiple sessions tracked independently', () async {
      final cubit = UnseenSessionsCubit();
      await cubit.ready;

      cubit.updateSessions([
        _session(id: 'a'),
        _session(id: 'b', status: 'running'),
        _session(id: 'c'),
      ]);
      expect(cubit.state, {'a', 'c'});

      cubit.markSeen('a');
      expect(cubit.state, {'c'});

      await cubit.close();
    });

    test('stale entries are cleaned up', () async {
      final cubit = UnseenSessionsCubit();
      await cubit.ready;

      cubit.updateSessions([_session(id: 'a'), _session(id: 'b')]);
      cubit.markSeen('a');
      cubit.markSeen('b');

      // Session 'a' removed from running list
      cubit.updateSessions([_session(id: 'b')]);
      // No assertion on internal state, just ensure no error and 'b' is still seen
      expect(cubit.isUnseen('b'), isFalse);

      await cubit.close();
    });

    // ---------------------------------------------------------------
    // False-positive prevention tests
    // ---------------------------------------------------------------

    group('false-positive prevention', () {
      test(
        'visible session activity stays seen without a future-time buffer',
        () async {
          final cubit = UnseenSessionsCubit();
          await cubit.ready;

          cubit.updateSessions([
            _session(id: 's1', lastActivityAt: '2026-03-11T10:00:00Z'),
          ]);
          cubit.markSeen('s1');
          expect(cubit.isUnseen('s1'), isFalse);

          cubit.updateSessions(
            [_session(id: 's1', lastActivityAt: '2026-03-11T10:00:05Z')],
            visibleSessionId: 's1',
            visibleProvider: 'claude',
          );
          expect(
            cubit.isUnseen('s1'),
            isFalse,
            reason: 'authoritative activity is consumed while still visible',
          );

          cubit.updateSessions([
            _session(id: 's1', lastActivityAt: '2026-03-11T10:00:06Z'),
          ]);
          expect(cubit.isUnseen('s1'), isTrue);

          await cubit.close();
        },
      );

      test(
        'newly created session marked seen before it appears in list',
        () async {
          // Simulates: session_created event fires → markSeen called with
          // real session ID → session later appears in active list as idle.
          final cubit = UnseenSessionsCubit();
          await cubit.ready;

          // markSeen called when session_created arrives (before the session
          // appears in the active session list).
          cubit.markSeen('new-session-123');

          // An older session-list snapshot may arrive before the newly created
          // session is included. It must not consume the one-shot suppression.
          cubit.updateSessions(const <SessionInfo>[]);

          // Session now appears in the list as idle.
          cubit.updateSessions([
            _session(
              id: 'new-session-123',
              lastActivityAt: '2026-03-11T10:00:00Z',
            ),
          ]);
          expect(
            cubit.isUnseen('new-session-123'),
            isFalse,
            reason: 'Session created by the user should not appear as unseen',
          );

          await cubit.close();
        },
      );

      test('session completion after the user leaves becomes unread', () async {
        final cubit = UnseenSessionsCubit();
        await cubit.ready;

        cubit.updateSessions(
          [_session(id: 's1', lastActivityAt: '2026-03-11T10:00:00Z')],
          visibleSessionId: 's1',
          visibleProvider: 'claude',
        );
        cubit.markSeen('s1');

        cubit.updateSessions([
          _session(
            id: 's1',
            status: 'running',
            lastActivityAt: '2026-03-11T10:01:00Z',
          ),
        ]);
        expect(cubit.state, isEmpty);

        cubit.updateSessions([
          _session(id: 's1', lastActivityAt: '2026-03-11T10:02:00Z'),
        ]);
        expect(
          cubit.isUnseen('s1'),
          isTrue,
          reason: 'completion after leaving must create the blue unread dot',
        );

        await cubit.close();
      });

      test('completion while the session remains visible stays seen', () async {
        final cubit = UnseenSessionsCubit();
        await cubit.ready;

        cubit.updateSessions(
          [_session(id: 's1', lastActivityAt: '2026-03-11T10:02:00Z')],
          visibleSessionId: 's1',
          visibleProvider: 'claude',
        );
        expect(
          cubit.isUnseen('s1'),
          isFalse,
          reason: 'visible completion is consumed immediately',
        );

        await cubit.close();
      });

      test(
        'durable session identity survives a runtime ID replacement',
        () async {
          final cubit = UnseenSessionsCubit();
          await cubit.ready;

          cubit.updateSessions([
            _session(
              id: 'runtime-old',
              provider: 'codex',
              providerSessionId: 'thread-1',
            ),
          ]);
          cubit.markSeen('runtime-old');
          cubit.updateSessions([
            _session(
              id: 'runtime-new',
              provider: 'codex',
              providerSessionId: 'thread-1',
            ),
          ]);

          expect(cubit.isUnseen('runtime-new'), isFalse);
          await cubit.close();
        },
      );

      test('durable resume can be marked seen before runtime attach', () async {
        final cubit = UnseenSessionsCubit();
        await cubit.ready;

        cubit.markSeen(
          'thread-1',
          scopeKey: 'bridge-a',
          provider: 'codex',
          durableProviderSessionId: 'thread-1',
        );
        cubit.updateSessions([
          _session(
            id: 'runtime-after-attach',
            provider: 'codex',
            providerSessionId: 'thread-1',
          ),
        ], scopeKey: 'bridge-a');

        expect(cubit.isUnseen('runtime-after-attach'), isFalse);
        await cubit.close();
      });

      test('seen state is isolated between Bridge scopes', () async {
        final cubit = UnseenSessionsCubit();
        await cubit.ready;

        cubit.updateSessions([
          _session(
            id: 'runtime-a',
            provider: 'codex',
            providerSessionId: 'thread-shared',
          ),
        ], scopeKey: 'bridge-a');
        cubit.markSeen('runtime-a', scopeKey: 'bridge-a');

        cubit.updateSessions([
          _session(
            id: 'runtime-b',
            provider: 'codex',
            providerSessionId: 'thread-shared',
          ),
        ], scopeKey: 'bridge-b');

        expect(
          cubit.isUnseen('runtime-b'),
          isTrue,
          reason: 'A different Bridge must not inherit another Bridge seen-at',
        );
        await cubit.close();
      });

      test(
        'stable Bridge source preserves seen state across endpoint routes',
        () async {
          const source = BridgeDataSourceIdentity(
            bridgeInstanceId: 'bridge-1',
            codexSourceId: 'codex-source-a',
          );
          final cubit = UnseenSessionsCubit();
          await cubit.ready;

          cubit.updateSessions(
            [
              _session(
                id: 'runtime-a',
                provider: 'codex',
                providerSessionId: 'thread-shared',
              ),
            ],
            scopeKey: 'url:wss://first.example:443/ws',
            dataSourceIdentity: source,
          );
          cubit.markSeen(
            'runtime-a',
            scopeKey: 'url:wss://first.example:443/ws',
            dataSourceIdentity: source,
          );
          cubit.updateSessions(
            [
              _session(
                id: 'runtime-b',
                provider: 'codex',
                providerSessionId: 'thread-shared',
              ),
            ],
            scopeKey: 'url:wss://second.example:443/ws',
            dataSourceIdentity: source,
          );

          expect(cubit.isUnseen('runtime-b'), isFalse);
          await cubit.close();
        },
      );

      test('same Bridge keeps different Codex sources isolated', () async {
        const firstSource = BridgeDataSourceIdentity(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-source-a',
        );
        const secondSource = BridgeDataSourceIdentity(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-source-b',
        );
        final cubit = UnseenSessionsCubit();
        await cubit.ready;

        cubit.updateSessions([
          _session(
            id: 'runtime-a',
            provider: 'codex',
            providerSessionId: 'thread-shared',
          ),
        ], dataSourceIdentity: firstSource);
        cubit.markSeen(
          'runtime-a',
          provider: 'codex',
          dataSourceIdentity: firstSource,
        );
        cubit.updateSessions([
          _session(
            id: 'runtime-b',
            provider: 'codex',
            providerSessionId: 'thread-shared',
          ),
        ], dataSourceIdentity: secondSource);

        expect(cubit.isUnseen('runtime-b'), isTrue);
        await cubit.close();
      });

      test(
        'scope switch clears runtime mappings from the previous Bridge',
        () async {
          final cubit = UnseenSessionsCubit();
          await cubit.ready;

          cubit.updateSessions([
            _session(id: 'same-runtime-id'),
          ], scopeKey: 'bridge-a');
          cubit.markSeen('same-runtime-id', scopeKey: 'bridge-a');
          cubit.updateSessions([
            _session(id: 'same-runtime-id'),
          ], scopeKey: 'bridge-b');

          expect(cubit.isUnseen('same-runtime-id'), isTrue);
          await cubit.close();
        },
      );
    });

    // ---------------------------------------------------------------
    // Persistence across cubit instances
    // ---------------------------------------------------------------

    group('persistence', () {
      test('seen-at survives cubit recreation', () async {
        final cubit1 = UnseenSessionsCubit();
        await cubit1.ready;

        cubit1.updateSessions([
          _session(id: 'a', lastActivityAt: '2026-03-11T10:00:00Z'),
        ]);
        cubit1.markSeen('a');
        // Wait for SharedPreferences write.
        await Future<void>.delayed(Duration.zero);
        await cubit1.close();

        // New cubit instance loads persisted data.
        final cubit2 = UnseenSessionsCubit();
        await cubit2.ready;

        cubit2.updateSessions([
          _session(id: 'a', lastActivityAt: '2026-03-11T10:00:00Z'),
        ]);
        expect(
          cubit2.isUnseen('a'),
          isFalse,
          reason: 'Persisted seen-at should carry over to new instance',
        );

        await cubit2.close();
      });

      test(
        'legacy durable key migrates only into the current Bridge',
        () async {
          SharedPreferences.setMockInitialValues({
            'unseen_sessions_seen_at': jsonEncode({
              'codex:thread-1': '2026-03-11T10:00:00Z',
            }),
          });
          final cubit = UnseenSessionsCubit();
          await cubit.ready;

          cubit.updateSessions([
            _session(
              id: 'runtime-a',
              provider: 'codex',
              providerSessionId: 'thread-1',
            ),
          ], scopeKey: 'bridge-a');
          expect(cubit.isUnseen('runtime-a'), isFalse);
          await cubit.close();

          final prefs = await SharedPreferences.getInstance();
          final stored =
              jsonDecode(prefs.getString('unseen_sessions_seen_at')!)
                  as Map<String, dynamic>;
          expect(stored, isNot(contains('codex:thread-1')));
          expect(stored, contains('v2|bridge-a|codex|thread-1'));

          final nextBridge = UnseenSessionsCubit();
          await nextBridge.ready;
          nextBridge.updateSessions([
            _session(
              id: 'runtime-b',
              provider: 'codex',
              providerSessionId: 'thread-1',
            ),
          ], scopeKey: 'bridge-b');
          expect(nextBridge.isUnseen('runtime-b'), isTrue);
          await nextBridge.close();
        },
      );

      test('legacy route-scoped seen state migrates once', () async {
        SharedPreferences.setMockInitialValues({
          'unseen_sessions_seen_at': jsonEncode({
            'v2|logical%3Amachine-a|codex|thread-1': '2026-03-11T10:00:00Z',
          }),
        });
        const source = BridgeDataSourceIdentity(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-source-a',
        );
        final cubit = UnseenSessionsCubit();
        await cubit.ready;

        cubit.updateSessions(
          [
            _session(
              id: 'runtime-a',
              provider: 'codex',
              providerSessionId: 'thread-1',
            ),
          ],
          scopeKey: 'logical:machine-a',
          dataSourceIdentity: source,
          legacyScopeKeys: const ['logical:machine-a'],
        );
        expect(cubit.isUnseen('runtime-a'), isFalse);
        await cubit.close();

        final prefs = await SharedPreferences.getInstance();
        final stored =
            jsonDecode(prefs.getString('unseen_sessions_seen_at')!)
                as Map<String, dynamic>;
        expect(
          stored,
          isNot(contains('v2|logical%3Amachine-a|codex|thread-1')),
        );
        expect(stored.values, contains('2026-03-11T10:00:00Z'));
      });

      test('pruning compares mixed ISO formats by their instant', () async {
        final stored = <String, String>{
          'v2|bridge-a|codex|older': '2026-01-01T00:00:00Z',
          'v2|bridge-a|codex|newer': '2026-01-01T00:00:00.500+00:00',
          for (var index = 0; index < 999; index++)
            'v2|bridge-a|codex|future-$index':
                '2030-01-01T00:00:${(index % 60).toString().padLeft(2, '0')}Z',
        };
        SharedPreferences.setMockInitialValues({
          'unseen_sessions_seen_at': jsonEncode(stored),
        });
        final cubit = UnseenSessionsCubit();
        await cubit.ready;

        cubit.updateSessions(const [], scopeKey: 'bridge-a');
        await cubit.close();

        final prefs = await SharedPreferences.getInstance();
        final persisted =
            jsonDecode(prefs.getString('unseen_sessions_seen_at')!)
                as Map<String, dynamic>;
        expect(persisted, isNot(contains('v2|bridge-a|codex|older')));
        expect(persisted, contains('v2|bridge-a|codex|newer'));
        expect(persisted, hasLength(1000));
      });
    });
  });
}
