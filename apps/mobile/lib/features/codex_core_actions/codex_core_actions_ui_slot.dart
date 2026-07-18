import 'package:flutter/material.dart';

import '../local_session_features/host/local_session_feature.dart';
import 'codex_core_actions_panel.dart';
import 'codex_core_actions_strings.dart';

final LocalSessionFeatureSlot codexCoreActionsUiSlot =
    _CodexCoreActionsUiSlot();

class _CodexCoreActionsUiSlot extends LocalSessionFeatureSlot {
  @override
  String get featureId => 'codex_core_actions';

  @override
  List<SessionMenuAction> overflowActions(CodexSessionFeatureContext context) =>
      [
        SessionMenuAction(
          featureId: featureId,
          label: CodexCoreActionsStrings.of(context.context).title,
          icon: Icons.construction_outlined,
          order: 15,
        ),
      ];

  @override
  WorkspaceFeaturePaneDescriptor get paneDescriptor =>
      WorkspaceFeaturePaneDescriptor(
        featureId: featureId,
        title: (context) => CodexCoreActionsStrings.of(context).title,
        builder: (context) => CodexCoreActionsPanel(
          sessionId: context.sessionId,
          bridge: context.bridge,
          initialSection: context.arguments['section'] as String?,
        ),
        rememberPerSession: false,
      );
}
