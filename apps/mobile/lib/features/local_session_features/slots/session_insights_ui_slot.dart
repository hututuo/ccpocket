import 'package:flutter/material.dart';

import '../../session_insights/widgets/session_insights_bar.dart';
import '../../session_insights/l10n/session_insights_strings.dart';
import '../host/local_session_feature.dart';

final LocalSessionFeatureSlot sessionInsightsUiSlot = _SessionInsightsUiSlot();

class _SessionInsightsUiSlot extends LocalSessionFeatureSlot {
  @override
  String get featureId => 'session_insights';

  @override
  List<Widget> modeBarWidgets(CodexSessionFeatureContext context) {
    final insightsSessionId =
        context.sessionInsightsSessionId ?? context.sessionId;
    return [
      SessionInsightsBar(
        key: ValueKey('session_insights_$insightsSessionId'),
        sessionId: insightsSessionId,
        runtimeSessionId: context.sessionId,
        bridgeService: context.bridge,
        selectedModel: context.codexModel,
        compact: true,
        showLeadingDivider: true,
        onCompact: context.requestCompact,
      ),
    ];
  }

  @override
  WorkspaceFeaturePaneDescriptor get paneDescriptor =>
      WorkspaceFeaturePaneDescriptor(
        featureId: featureId,
        title: (context) => SessionInsightsStrings.of(context).title,
        builder: (context) => SessionInsightsPanel(
          sessionId: _sessionInsightsPaneSessionId(context),
          runtimeSessionId: context.sessionId,
          bridgeService: context.bridge,
        ),
        rememberPerSession: false,
      );
}

String _sessionInsightsPaneSessionId(WorkspaceFeaturePaneContext context) {
  final value = context.arguments['sessionInsightsSessionId'];
  if (value is String && value.trim().isNotEmpty) return value;
  return context.sessionId;
}
