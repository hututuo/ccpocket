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
      context.durableCacheIdentityConfirmed &&
          context.runtimeMutationSessionId == null
      ? const []
      : [
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
        builder: (context) {
          final durableRoute = context.arguments['durableRoute'] == true;
          final runtimeSessionId =
              context.arguments['runtimeSessionId'] as String?;
          if (durableRoute && runtimeSessionId == null) {
            return Center(
              child: Text(CodexCoreActionsStrings.of(context.context).failed),
            );
          }
          return CodexCoreActionsPanel(
            sessionId: runtimeSessionId ?? context.sessionId,
            bridge: context.bridge,
            initialSection: context.arguments['section'] as String?,
          );
        },
        rememberPerSession: false,
      );
}
