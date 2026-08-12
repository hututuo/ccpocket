import 'package:ccpocket/features/diagnostics/session_diagnostic_report.dart';
import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diagnostic identity requires the exact Bridge and source', () {
    const expected = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'source-a',
    );
    expect(
      diagnosticDataSourceIdentityMatchesExact(expected, expected),
      isTrue,
    );
    expect(
      diagnosticDataSourceIdentityMatchesExact(
        expected,
        const BridgeDataSourceIdentity(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'source-b',
        ),
      ),
      isFalse,
    );
    expect(
      diagnosticDataSourceIdentityMatchesExact(
        expected,
        const BridgeDataSourceIdentity(
          bridgeInstanceId: 'bridge-2',
          codexSourceId: 'source-a',
        ),
      ),
      isFalse,
    );
  });

  test(
    'presentation capture is stable only for two available equal revisions',
    () {
      const revision = 'revision-1';
      expect(
        diagnosticPresentationCaptureStable(
          const {'available': true, 'presentationRevision': revision},
          const {'available': true, 'presentationRevision': revision},
        ),
        isTrue,
      );
      expect(
        diagnosticPresentationCaptureStable(
          const {'available': false, 'reason': 'loading'},
          const {'available': false, 'reason': 'loading'},
        ),
        isFalse,
      );
      expect(
        diagnosticPresentationCaptureStable(
          const {'available': true, 'presentationRevision': revision},
          const {'available': true, 'presentationRevision': 'revision-2'},
        ),
        isFalse,
      );
    },
  );
}
