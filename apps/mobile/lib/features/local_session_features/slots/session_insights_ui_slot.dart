import 'package:flutter/material.dart';

import '../../session_insights/widgets/session_insights_bar.dart';
import '../../session_insights/l10n/session_insights_strings.dart';
import '../host/local_session_feature.dart';

final LocalSessionFeatureSlot sessionInsightsUiSlot = _SessionInsightsUiSlot();

class _SessionInsightsUiSlot extends LocalSessionFeatureSlot {
  @override
  String get featureId => 'session_insights';

  @override
  List<Widget> statusWidgets(CodexSessionFeatureContext context) => [
    Align(
      alignment: Alignment.centerRight,
      child: SessionInsightsBar(
        sessionId: context.sessionId,
        bridgeService: context.bridge,
        onCompact: () => context.openPane(
          'codex_core_actions',
          arguments: const {'section': 'compact'},
        ),
      ),
    ),
  ];

  @override
  WorkspaceFeaturePaneDescriptor get paneDescriptor =>
      WorkspaceFeaturePaneDescriptor(
        featureId: featureId,
        title: (context) => SessionInsightsStrings.of(context).title,
        builder: (context) => SessionInsightsPanel(
          sessionId: context.sessionId,
          bridgeService: context.bridge,
        ),
        rememberPerSession: false,
      );
}
