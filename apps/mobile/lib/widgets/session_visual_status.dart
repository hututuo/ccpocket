import '../models/messages.dart';

enum SessionPrimaryStatus { working, needsYou, error, idle, unknown }

enum SessionExecutionHost { bridge, desktopAppServer, unknown }

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

class SessionCardPresentation {
  final SessionVisualStatus visualStatus;
  final SessionExecutionHost executionHost;
  final bool isUnread;

  const SessionCardPresentation({
    required this.visualStatus,
    required this.executionHost,
    required this.isUnread,
  });

  bool get hasVisibleStatus => visualStatus.label != null || isUnread;
}

/// Resolves the single presentation contract shared by list ordering and cards.
///
/// Conversation Sync v2 is authoritative when present. Runtime fields are a
/// compatibility fallback for older Bridges and may still provide approval
/// detail when they agree with the authoritative v2 attention state.
SessionCardPresentation sessionCardPresentationFor({
  ConversationSyncV2Status? syncStatus,
  SessionInfo? runtimeSession,
  bool isUnseen = false,
}) {
  final runtimeVisual = runtimeSession == null
      ? null
      : sessionVisualStatusFor(
          rawStatus: runtimeSession.externalDesktopTurnActive
              ? 'running'
              : runtimeSession.status,
          permissionMode: runtimeSession.effectivePermissionMode,
          planMode: runtimeSession.resolvedPlanMode,
          pendingPermission: runtimeSession.pendingPermission,
        );
  final visualStatus = syncStatus == null
      ? runtimeVisual ?? _idleVisualStatus()
      : _syncVisualStatus(syncStatus, runtimeVisual: runtimeVisual);
  final executionHost = visualStatus.primary == SessionPrimaryStatus.idle
      ? SessionExecutionHost.unknown
      : syncStatus == null
      ? runtimeSession == null
            ? SessionExecutionHost.unknown
            : runtimeSession.externalDesktopTurnActive
            ? SessionExecutionHost.desktopAppServer
            : SessionExecutionHost.bridge
      : _syncExecutionHost(syncStatus);

  return SessionCardPresentation(
    visualStatus: visualStatus,
    executionHost: executionHost,
    isUnread: visualStatus.primary == SessionPrimaryStatus.idle && isUnseen,
  );
}

SessionExecutionHost _syncExecutionHost(ConversationSyncV2Status status) {
  final explicit = status.executionHost;
  if (explicit != null) {
    return switch (explicit) {
      'bridge' => SessionExecutionHost.bridge,
      'desktopAppServer' => SessionExecutionHost.desktopAppServer,
      _ => SessionExecutionHost.unknown,
    };
  }

  // Compatibility fallback for old Bridges. A modern Bridge must send an
  // explicit `unknown` rather than relying on evidence provenance to guess the
  // turn origin.
  return switch (status.source) {
    'appServer' || 'legacyRollout' => SessionExecutionHost.desktopAppServer,
    'bridgeRuntime' => SessionExecutionHost.bridge,
    _ => SessionExecutionHost.unknown,
  };
}

SessionVisualStatus _syncVisualStatus(
  ConversationSyncV2Status status, {
  required SessionVisualStatus? runtimeVisual,
}) {
  final showPlanBadge = runtimeVisual?.showPlanBadge ?? false;
  if (status.attention != 'none') {
    final detail = runtimeVisual?.primary == SessionPrimaryStatus.needsYou
        ? runtimeVisual?.detail
        : null;
    return SessionVisualStatus(
      primary: SessionPrimaryStatus.needsYou,
      label: SessionVisualLabel.needsYou,
      detail: detail,
      detailArgument: detail == null ? null : runtimeVisual?.detailArgument,
      showPlanBadge: showPlanBadge,
      animate: true,
    );
  }
  if (status.activity == 'working' || status.activity == 'compacting') {
    return SessionVisualStatus(
      primary: SessionPrimaryStatus.working,
      label: SessionVisualLabel.working,
      detail: status.activity == 'compacting'
          ? SessionVisualDetail.cleaningContext
          : null,
      showPlanBadge: showPlanBadge,
      animate: true,
    );
  }
  if (status.activity == 'systemError' ||
      status.runtimeAttachment == 'ownedElsewhere') {
    return SessionVisualStatus(
      primary: SessionPrimaryStatus.error,
      label: SessionVisualLabel.unavailable,
      showPlanBadge: showPlanBadge,
      animate: false,
    );
  }
  if (status.activity == 'unknown') {
    final explicitlyUnavailable =
        status.controlState == 'unavailable' ||
        status.controlState == 'blocked';
    return SessionVisualStatus(
      primary: explicitlyUnavailable
          ? SessionPrimaryStatus.error
          : SessionPrimaryStatus.unknown,
      label: explicitlyUnavailable ? SessionVisualLabel.unavailable : null,
      showPlanBadge: showPlanBadge,
      animate: false,
    );
  }
  return _idleVisualStatus(showPlanBadge: showPlanBadge);
}

SessionVisualStatus _idleVisualStatus({bool showPlanBadge = false}) =>
    SessionVisualStatus(
      primary: SessionPrimaryStatus.idle,
      label: null,
      showPlanBadge: showPlanBadge,
      animate: false,
    );

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
    'idle' => _idleVisualStatus(showPlanBadge: showPlanBadge),
    _ => SessionVisualStatus(
      primary: SessionPrimaryStatus.unknown,
      label: SessionVisualLabel.unavailable,
      showPlanBadge: showPlanBadge,
      animate: false,
    ),
  };
}
