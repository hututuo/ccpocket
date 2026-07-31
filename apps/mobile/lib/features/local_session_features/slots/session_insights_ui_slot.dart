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
    final durableSessionId = context.sessionInsightsSessionId?.trim();
    final durableCacheIdentityConfirmed =
        durableSessionId != null && durableSessionId.isNotEmpty;
    final insightsSessionId = durableCacheIdentityConfirmed
        ? durableSessionId
        : context.sessionId;
    return [
      SessionInsightsBar(
        key: ValueKey('session_insights_$insightsSessionId'),
        sessionId: insightsSessionId,
        runtimeSessionId: context.sessionId,
        bridgeService: context.bridge,
        selectedModel: context.codexModel,
        compact: true,
        showLeadingDivider: true,
        durableCacheIdentityConfirmed: durableCacheIdentityConfirmed,
        onCompact: context.requestCompact,
      ),
    ];
  }

  @override
  WorkspaceFeaturePaneDescriptor get paneDescriptor =>
      WorkspaceFeaturePaneDescriptor(
        featureId: featureId,
        title: (context) => SessionInsightsStrings.of(context).title,
        builder: (context) {
          final identity = _sessionInsightsPaneIdentity(context);
          return SessionInsightsPanel(
            sessionId: identity.sessionId,
            runtimeSessionId: context.sessionId,
            bridgeService: context.bridge,
            durableCacheIdentityConfirmed:
                identity.durableCacheIdentityConfirmed,
          );
        },
        rememberPerSession: false,
      );
}

({String sessionId, bool durableCacheIdentityConfirmed})
_sessionInsightsPaneIdentity(WorkspaceFeaturePaneContext context) {
  final value = context.arguments['sessionInsightsSessionId'];
  if (value is String && value.trim().isNotEmpty) {
    return (sessionId: value.trim(), durableCacheIdentityConfirmed: true);
  }
  return (sessionId: context.sessionId, durableCacheIdentityConfirmed: false);
}
