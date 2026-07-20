import 'package:ccpocket/features/local_session_features/host/local_session_feature.dart';
import 'package:ccpocket/features/local_session_features/host/local_session_feature_host.dart';
import 'package:ccpocket/features/session_insights/widgets/session_insights_bar.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  @override
  bool get isConnected => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'session insights belongs to the mode toolbar and keeps compact routing',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final bridge = _Bridge();
      final drafts = DraftService(await SharedPreferences.getInstance());
      final input = TextEditingController();
      final opened = <({String featureId, Map<String, Object?> arguments})>[];
      late CodexSessionFeatureContext featureContext;
      addTearDown(bridge.dispose);
      addTearDown(input.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              featureContext = CodexSessionFeatureContext(
                context: context,
                sessionId: 'session-1',
                bridge: bridge,
                inputController: input,
                draftService: drafts,
                openPane: (featureId, {arguments = const {}}) async {
                  opened.add((
                    featureId: featureId,
                    arguments: Map.unmodifiable(arguments),
                  ));
                },
              );
              return const SizedBox();
            },
          ),
        ),
      );

      expect(
        LocalSessionFeatureHost.statusWidgets(
          featureContext,
        ).whereType<SessionInsightsBar>(),
        isEmpty,
      );
      final modeBars = LocalSessionFeatureHost.modeBarWidgets(
        featureContext,
      ).whereType<SessionInsightsBar>().toList(growable: false);
      expect(modeBars, hasLength(1));
      expect(modeBars.single.compact, isTrue);
      expect(modeBars.single.showLeadingDivider, isTrue);
      expect(modeBars.single.onCompact, isNotNull);

      modeBars.single.onCompact!();
      expect(opened, hasLength(1));
      expect(opened.single.featureId, 'codex_core_actions');
      expect(opened.single.arguments, containsPair('section', 'compact'));
    },
  );
}
