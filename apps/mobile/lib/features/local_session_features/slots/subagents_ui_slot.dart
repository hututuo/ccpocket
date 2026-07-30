import 'package:flutter/material.dart';

import '../../subagents/l10n/subagents_strings.dart';
import '../../subagents/widgets/subagents_panel.dart';
import '../host/local_session_feature.dart';

final LocalSessionFeatureSlot subagentsUiSlot = _SubagentsUiSlot();

class _SubagentsUiSlot extends LocalSessionFeatureSlot {
  @override
  String get featureId => 'subagents';

  @override
  List<SessionMenuAction> overflowActions(CodexSessionFeatureContext context) =>
      [
        SessionMenuAction(
          featureId: featureId,
          label: SubagentsStrings.of(context.context).title,
          icon: Icons.account_tree_outlined,
          order: 20,
        ),
      ];

  @override
  WorkspaceFeaturePaneDescriptor get paneDescriptor =>
      WorkspaceFeaturePaneDescriptor(
        featureId: featureId,
        title: (context) => SubagentsStrings.of(context).title,
        builder: (context) {
          final providerThreadId = context.arguments['providerThreadId'];
          final codexSourceId = context.arguments['codexSourceId'];
          return SubagentsPanel(
            sessionId: context.sessionId,
            bridgeService: context.bridge,
            detachedProviderThreadId: providerThreadId is String
                ? providerThreadId
                : null,
            detachedCodexSourceId: codexSourceId is String
                ? codexSourceId
                : null,
            onClose: context.onClose,
          );
        },
      );
}
