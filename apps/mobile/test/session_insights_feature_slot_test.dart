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
    'session insights invokes the direct compact action without opening a pane',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final bridge = _Bridge();
      final drafts = DraftService(await SharedPreferences.getInstance());
      final input = TextEditingController();
      final opened = <({String featureId, Map<String, Object?> arguments})>[];
      var compactRequests = 0;
      late CodexSessionFeatureContext featureContext;
      addTearDown(bridge.dispose);
      addTearDown(input.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              featureContext = CodexSessionFeatureContext(
                context: context,
                sessionId: 'runtime-before-attach',
                sessionInsightsSessionId: 'durable-thread',
                bridge: bridge,
                inputController: input,
                draftService: drafts,
                requestCompact: () => compactRequests += 1,
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
      expect(modeBars.single.sessionId, 'durable-thread');
      expect(modeBars.single.runtimeSessionId, 'runtime-before-attach');
      expect(modeBars.single.durableCacheIdentityConfirmed, isTrue);

      final runtimeOnlyContext = CodexSessionFeatureContext(
        context: featureContext.context,
        sessionId: 'runtime-only',
        bridge: bridge,
        inputController: input,
        draftService: drafts,
        requestCompact: () {},
        openPane: (featureId, {arguments = const {}}) async {},
      );
      final runtimeOnlyBar = LocalSessionFeatureHost.modeBarWidgets(
        runtimeOnlyContext,
      ).whereType<SessionInsightsBar>().single;
      expect(runtimeOnlyBar.sessionId, 'runtime-only');
      expect(runtimeOnlyBar.durableCacheIdentityConfirmed, isFalse);

      final attachedContext = CodexSessionFeatureContext(
        context: featureContext.context,
        sessionId: 'runtime-after-attach',
        sessionInsightsSessionId: 'durable-thread',
        bridge: bridge,
        inputController: input,
        draftService: drafts,
        requestCompact: () => compactRequests += 1,
        openPane: (featureId, {arguments = const {}}) async {},
      );
      final attachedBar = LocalSessionFeatureHost.modeBarWidgets(
        attachedContext,
      ).whereType<SessionInsightsBar>().single;
      expect(attachedBar.sessionId, 'durable-thread');
      expect(attachedBar.runtimeSessionId, 'runtime-after-attach');
      expect(attachedBar.key, modeBars.single.key);

      final pane = LocalSessionFeatureHost.paneDescriptor('session_insights')!;
      final runtimeOnlyPanel =
          pane.builder(
                WorkspaceFeaturePaneContext(
                  context: featureContext.context,
                  sessionId: 'runtime-only',
                  bridge: bridge,
                  onClose: () {},
                ),
              )
              as SessionInsightsPanel;
      expect(runtimeOnlyPanel.sessionId, 'runtime-only');
      expect(runtimeOnlyPanel.durableCacheIdentityConfirmed, isFalse);
      final durablePanel =
          pane.builder(
                WorkspaceFeaturePaneContext(
                  context: featureContext.context,
                  sessionId: 'runtime-only',
                  bridge: bridge,
                  arguments: const {
                    'sessionInsightsSessionId': 'durable-thread',
                  },
                  onClose: () {},
                ),
              )
              as SessionInsightsPanel;
      expect(durablePanel.sessionId, 'durable-thread');
      expect(durablePanel.durableCacheIdentityConfirmed, isTrue);

      modeBars.single.onCompact!();
      expect(compactRequests, 1);
      expect(opened, isEmpty);
    },
  );
}
