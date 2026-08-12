import 'package:ccpocket/features/diagnostics/home_diagnostic_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final registry = HomeDiagnosticProjectionRegistry.instance;

  tearDown(registry.clear);

  test('captures the actual source and preserves target original indexes', () {
    final owner = Object();
    String? requestedTarget;
    registry.attach(
      owner: owner,
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'source-1',
      capture: (targetKey) {
        requestedTarget = targetKey;
        return <String, Object?>{
          'orderedRows': <Object?>[
            <String, Object?>{'identityKey': targetKey, 'originalIndex': 1450},
          ],
          'visibleRowKeys': <String>[targetKey],
          'targetOrderedIndex': 1450,
          'targetVisibleIndex': 7,
        };
      },
    );

    final snapshot = registry.capture(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'source-1',
      provider: 'codex',
      providerSessionId: 'thread-1',
    );

    expect(requestedTarget, 'codex\u0000thread-1');
    expect(snapshot['available'], isTrue);
    expect(snapshot['target'], <String, Object?>{
      'identityKey': 'codex\u0000thread-1',
      'orderedIndex': 1450,
      'visibleIndex': 7,
    });
  });

  test('fails closed for a different Codex source and detaches by owner', () {
    final owner = Object();
    registry.attach(
      owner: owner,
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'source-1',
      capture: (_) => const <String, Object?>{},
    );

    expect(
      registry.capture(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'source-2',
        provider: 'codex',
        providerSessionId: 'thread-1',
      ),
      containsPair('reason', 'sourceMismatch'),
    );
    registry.detach(Object());
    expect(
      registry.capture(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'source-1',
        provider: 'codex',
        providerSessionId: 'thread-1',
      )['available'],
      isTrue,
    );
    registry.detach(owner);
    expect(
      registry.capture(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'source-1',
        provider: 'codex',
        providerSessionId: 'thread-1',
      ),
      containsPair('reason', 'notBuilt'),
    );
  });
}
