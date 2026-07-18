import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../local_session_features/host/local_session_feature.dart';
import 'auto_approval_panel.dart';
import 'auto_approval_service.dart';
import 'auto_approval_strings.dart';

final LocalSessionFeatureSlot autoApprovalUiSlot = _AutoApprovalUiSlot();

class _AutoApprovalUiSlot extends LocalSessionFeatureSlot {
  @override
  String get featureId => 'auto_approval';

  @override
  List<SessionMenuAction> overflowActions(CodexSessionFeatureContext context) {
    if (!_isInstalled(context.context)) return const [];
    return [
      SessionMenuAction(
        featureId: featureId,
        label: AutoApprovalStrings.of(context.context).menuLabel,
        icon: Icons.approval_outlined,
        order: 35,
      ),
    ];
  }

  @override
  List<Widget> statusWidgets(CodexSessionFeatureContext context) {
    if (!_isInstalled(context.context)) return const [];
    return [
      Align(
        key: const ValueKey('auto_approval_status_slot'),
        alignment: Alignment.centerRight,
        child: AutoApprovalStatusChip(
          sessionId: context.sessionId,
          onPressed: () => context.openPane(featureId),
        ),
      ),
    ];
  }

  bool _isInstalled(BuildContext context) =>
      Provider.of<AutoApprovalService?>(context, listen: false) != null;

  @override
  WorkspaceFeaturePaneDescriptor get paneDescriptor =>
      WorkspaceFeaturePaneDescriptor(
        featureId: featureId,
        title: (context) => AutoApprovalStrings.of(context).title,
        builder: (context) => AutoApprovalPanel(sessionId: context.sessionId),
        sheetHeightFactor: 0.56,
        rememberPerSession: false,
      );
}
