import 'package:ccpocket/features/codex_action_broker/codex_action_broker_interaction_frame.dart';
import 'package:ccpocket/features/codex_action_broker/codex_action_broker_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('guarded broker surface remains visible but blocks mutations', (
    tester,
  ) async {
    var approvals = 0;
    var refreshes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodexActionBrokerInteractionFrame(
            phase: CodexActionBrokerInteractionPhase.reconnecting,
            onRefresh: () => refreshes += 1,
            child: FilledButton(
              key: const ValueKey('legacy_mutation'),
              onPressed: () => approvals += 1,
              child: const Text('Approve'),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('Need You'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('legacy_mutation')),
      warnIfMissed: false,
    );
    await tester.tap(find.byKey(const ValueKey('codex_action_broker_refresh')));
    expect(approvals, 0);
    expect(refreshes, 1);
  });

  testWidgets('actionable broker surface enables native controls and reject', (
    tester,
  ) async {
    var approvals = 0;
    var rejects = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodexActionBrokerInteractionFrame(
            phase: CodexActionBrokerInteractionPhase.actionable,
            onRefresh: () {},
            onReject: () => rejects += 1,
            child: FilledButton(
              key: const ValueKey('broker_mutation'),
              onPressed: () => approvals += 1,
              child: const Text('Approve'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('broker_mutation')));
    await tester.tap(
      find.byKey(const ValueKey('codex_action_broker_question_reject')),
    );
    expect(approvals, 1);
    expect(rejects, 1);
  });
}
