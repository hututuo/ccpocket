import '../models/messages.dart';

enum SessionPrimaryStatus { working, needsYou, idle, unknown }

enum SessionVisualLabel { working, needsYou, unavailable }

enum SessionVisualDetail {
  reviewPlan,
  approveToolCall,
  answerQuestion,
  answerMcpRequest,
  grantPermissions,
  approveTool,
  cleaningContext,
}

class SessionVisualStatus {
  final SessionPrimaryStatus primary;
  final SessionVisualLabel? label;
  final SessionVisualDetail? detail;
  final String? detailArgument;
  final bool showPlanBadge;
  final bool animate;

  const SessionVisualStatus({
    required this.primary,
    required this.label,
    this.detail,
    this.detailArgument,
    required this.showPlanBadge,
    required this.animate,
  });
}

SessionVisualStatus sessionVisualStatusFor({
  required String rawStatus,
  String? permissionMode,
  bool planMode = false,
  PermissionRequestMessage? pendingPermission,
}) {
  final showPlanBadge = planMode || permissionMode == PermissionMode.plan.value;

  if (pendingPermission != null) {
    final detail = switch (pendingPermission.toolName) {
      'ExitPlanMode' => SessionVisualDetail.reviewPlan,
      'AskUserQuestion' =>
        pendingPermission.isQuestionApproval
            ? SessionVisualDetail.approveToolCall
            : SessionVisualDetail.answerQuestion,
      'McpElicitation' =>
        pendingPermission.isQuestionApproval
            ? SessionVisualDetail.approveToolCall
            : pendingPermission.isQuestionPrompt
            ? SessionVisualDetail.answerQuestion
            : SessionVisualDetail.answerMcpRequest,
      'Permissions' => SessionVisualDetail.grantPermissions,
      _ => SessionVisualDetail.approveTool,
    };
    return SessionVisualStatus(
      primary: SessionPrimaryStatus.needsYou,
      label: SessionVisualLabel.needsYou,
      detail: detail,
      detailArgument: detail == SessionVisualDetail.approveTool
          ? pendingPermission.toolName
          : null,
      showPlanBadge: showPlanBadge,
      animate: true,
    );
  }

  return switch (rawStatus) {
    'starting' || 'running' => SessionVisualStatus(
      primary: SessionPrimaryStatus.working,
      label: SessionVisualLabel.working,
      showPlanBadge: showPlanBadge,
      animate: true,
    ),
    'compacting' => SessionVisualStatus(
      primary: SessionPrimaryStatus.working,
      label: SessionVisualLabel.working,
      detail: SessionVisualDetail.cleaningContext,
      showPlanBadge: showPlanBadge,
      animate: true,
    ),
    'waiting_approval' => SessionVisualStatus(
      primary: SessionPrimaryStatus.needsYou,
      label: SessionVisualLabel.needsYou,
      showPlanBadge: showPlanBadge,
      animate: true,
    ),
    'idle' => SessionVisualStatus(
      primary: SessionPrimaryStatus.idle,
      label: null,
      showPlanBadge: showPlanBadge,
      animate: false,
    ),
    _ => SessionVisualStatus(
      primary: SessionPrimaryStatus.unknown,
      label: SessionVisualLabel.unavailable,
      showPlanBadge: showPlanBadge,
      animate: false,
    ),
  };
}
