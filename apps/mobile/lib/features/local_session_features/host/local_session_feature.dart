import 'package:flutter/material.dart';

import '../../../services/bridge_service.dart';
import '../../../services/draft_service.dart';
import '../../../widgets/chat_selection_actions.dart';

typedef OpenLocalFeaturePane =
    Future<void> Function(String featureId, {Map<String, Object?> arguments});

class CodexSessionFeatureContext {
  final BuildContext context;
  final String sessionId;
  final String? sessionInsightsSessionId;
  final String? runtimeMutationSessionId;
  final bool durableCacheIdentityConfirmed;
  final BridgeService bridge;
  final TextEditingController inputController;
  final DraftService draftService;
  final String? codexModel;
  final VoidCallback requestCompact;
  final OpenLocalFeaturePane openPane;

  const CodexSessionFeatureContext({
    required this.context,
    required this.sessionId,
    this.sessionInsightsSessionId,
    this.runtimeMutationSessionId,
    this.durableCacheIdentityConfirmed = false,
    required this.bridge,
    required this.inputController,
    required this.draftService,
    this.codexModel,
    required this.requestCompact,
    required this.openPane,
  });
}

class SessionMenuAction {
  final String featureId;
  final String label;
  final IconData icon;
  final int order;

  const SessionMenuAction({
    required this.featureId,
    required this.label,
    required this.icon,
    this.order = 0,
  });
}

class WorkspaceFeaturePaneContext {
  final BuildContext context;
  final String sessionId;
  final BridgeService bridge;
  final Map<String, Object?> arguments;
  final VoidCallback onClose;

  const WorkspaceFeaturePaneContext({
    required this.context,
    required this.sessionId,
    required this.bridge,
    this.arguments = const {},
    required this.onClose,
  });
}

class WorkspaceFeaturePaneDescriptor {
  final String featureId;
  final String Function(BuildContext context) title;
  final Widget Function(WorkspaceFeaturePaneContext context) builder;
  final double sheetHeightFactor;
  final bool rememberPerSession;

  const WorkspaceFeaturePaneDescriptor({
    required this.featureId,
    required this.title,
    required this.builder,
    this.sheetHeightFactor = 0.92,
    this.rememberPerSession = true,
  });
}

abstract class LocalSessionFeatureSlot {
  String get featureId;

  List<SessionMenuAction> overflowActions(CodexSessionFeatureContext context) =>
      const [];

  List<Widget> statusWidgets(CodexSessionFeatureContext context) => const [];

  List<Widget> modeBarWidgets(CodexSessionFeatureContext context) => const [];

  List<ChatSelectionAction> selectionActions(
    CodexSessionFeatureContext context,
  ) => const [];

  WorkspaceFeaturePaneDescriptor? get paneDescriptor => null;
}

class DisabledLocalSessionFeatureSlot extends LocalSessionFeatureSlot {
  @override
  final String featureId;

  DisabledLocalSessionFeatureSlot(this.featureId);
}
