import 'package:flutter/material.dart';

import '../../session_insights/widgets/session_insights_bar.dart';
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
      ),
    ),
  ];
}
