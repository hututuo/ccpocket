import 'package:ccpocket/features/session_list/pending_session_binding.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local dispatch failures use the binding failure channel', () {
    final binding = PendingSessionBinding(
      kind: PendingSessionRequestKind.resume,
      requestId: 'resume-local',
      provider: 'codex',
      projectPath: '/repo',
      providerSessionId: 'thread-local',
      allowLegacyFallback: false,
    );
    addTearDown(binding.dispose);

    binding.rejectLocal('Could not prepare resume');

    expect(binding.failure.value?.errorMessage, 'Could not prepare resume');
    expect(binding.value, isNull);
  });

  group('PendingSessionBinding', () {
    test('accepts only the exact start request id on a capable Bridge', () {
      final binding = PendingSessionBinding(
        kind: PendingSessionRequestKind.start,
        requestId: 'start-1',
        provider: 'codex',
        projectPath: '/repo',
        allowLegacyFallback: false,
      );
      addTearDown(binding.dispose);

      expect(
        binding.match(
          const SystemMessage(
            subtype: 'session_created',
            sessionId: 'wrong',
            provider: 'codex',
            projectPath: '/repo',
            startRequestId: 'start-2',
          ),
        ),
        PendingSessionMatchQuality.none,
      );

      final message = const SystemMessage(
        subtype: 'session_created',
        sessionId: 'right',
        provider: 'codex',
        projectPath: '/repo',
        startRequestId: 'start-1',
      );
      expect(binding.match(message), PendingSessionMatchQuality.exact);
      expect(dispatchPendingSessionMessage([binding], message), same(binding));
      expect(binding.value?.sessionId, 'right');
    });

    test('same-project resume cannot bind to another request', () {
      final binding = PendingSessionBinding(
        kind: PendingSessionRequestKind.resume,
        requestId: 'resume-1',
        provider: 'codex',
        projectPath: '/repo',
        providerSessionId: 'thread-1',
        allowLegacyFallback: false,
      );
      addTearDown(binding.dispose);

      final wrong = const SystemMessage(
        subtype: 'session_created',
        sessionId: 'runtime-2',
        provider: 'codex',
        projectPath: '/repo',
        sourceSessionId: 'thread-1',
        resumeRequestId: 'resume-2',
      );
      expect(dispatchPendingSessionMessage([binding], wrong), isNull);
      expect(binding.value, isNull);
    });

    test('legacy start fallback requires one unique owner', () {
      PendingSessionBinding create(String requestId) => PendingSessionBinding(
        kind: PendingSessionRequestKind.start,
        requestId: requestId,
        provider: 'claude',
        projectPath: '/repo',
        allowLegacyFallback: true,
      );

      final first = create('start-1');
      final second = create('start-2');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      const message = SystemMessage(
        subtype: 'session_created',
        sessionId: 'runtime-1',
        provider: 'claude',
        projectPath: '/repo',
      );

      expect(dispatchPendingSessionMessage([first, second], message), isNull);
      expect(first.value, isNull);
      expect(second.value, isNull);

      expect(dispatchPendingSessionMessage([first], message), same(first));
      expect(first.value?.sessionId, 'runtime-1');
    });

    test('legacy resume fallback requires the durable provider identity', () {
      final binding = PendingSessionBinding(
        kind: PendingSessionRequestKind.resume,
        requestId: 'resume-1',
        provider: 'claude',
        projectPath: '/repo',
        providerSessionId: 'claude-session-1',
        allowLegacyFallback: true,
      );
      addTearDown(binding.dispose);

      const unrelated = SystemMessage(
        subtype: 'session_created',
        sessionId: 'runtime-2',
        provider: 'claude',
        projectPath: '/repo',
        sourceSessionId: 'claude-session-2',
      );
      expect(dispatchPendingSessionMessage([binding], unrelated), isNull);

      const related = SystemMessage(
        subtype: 'session_created',
        sessionId: 'runtime-1',
        provider: 'claude',
        projectPath: '/repo',
        sourceSessionId: 'claude-session-1',
      );
      expect(dispatchPendingSessionMessage([binding], related), same(binding));
    });

    test('routes an exact failure without consuming another request', () {
      final first = PendingSessionBinding(
        kind: PendingSessionRequestKind.start,
        requestId: 'start-1',
        provider: 'codex',
        projectPath: '/repo',
        allowLegacyFallback: false,
      );
      final second = PendingSessionBinding(
        kind: PendingSessionRequestKind.start,
        requestId: 'start-2',
        provider: 'codex',
        projectPath: '/repo',
        allowLegacyFallback: false,
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      const failure = SystemMessage(
        subtype: 'session_start_failed',
        provider: 'codex',
        projectPath: '/repo',
        startRequestId: 'start-2',
        errorMessage: 'profile missing',
      );
      expect(
        dispatchPendingSessionMessage([first, second], failure),
        same(second),
      );
      expect(first.failure.value, isNull);
      expect(second.failure.value?.errorMessage, 'profile missing');
    });
  });
}
