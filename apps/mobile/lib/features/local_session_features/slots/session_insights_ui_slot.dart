import 'package:flutter/material.dart';

import '../../session_insights/widgets/session_insights_bar.dart';
import '../../session_insights/l10n/session_insights_strings.dart';
import '../host/local_session_feature.dart';

final LocalSessionFeatureSlot sessionInsightsUiSlot = _SessionInsightsUiSlot();

class _SessionInsightsUiSlot extends LocalSessionFeatureSlot {
  @override
  String get featureId => 'session_insights';

  @override
  List<Widget> modeBarWidgets(CodexSessionFeatureContext context) => [
    SessionInsightsBar(
      key: ValueKey('session_insights_${context.sessionId}'),
      sessionId: context.sessionId,
      bridgeService: context.bridge,
      selectedModel: context.codexModel,
      compact: true,
      showLeadingDivider: true,
      onCompact: context.requestCompact,
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
