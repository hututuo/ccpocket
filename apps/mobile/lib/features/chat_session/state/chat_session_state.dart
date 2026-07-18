import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../models/messages.dart';
import '../../../widgets/slash_command_sheet.dart' show SlashCommand;

part 'chat_session_state.freezed.dart';

enum CodexGoalSupport { unknown, supported, unsupported }

enum CodexNativePlanModeSupport { unknown, supported, unsupported }

enum CodexGoalMutationKind { create, edit, pause, resume, updateBudget, clear }

enum CodexGoalErrorKind {
  disconnected,
  connectRequired,
  unsupported,
  unknownStatus,
  invalidBudget,
  timeout,
  objectiveRequired,
  objectiveTooLong,
  budgetResumeRequired,
  conflict,
  readFailed,
  updateFailed,
  clearFailed,
}

class CodexGoalMutation {
  final String id;
  final CodexGoalMutationKind kind;
  final String? objective;
  final CodexThreadGoalStatus? status;
  final bool includesTokenBudget;
  final int? tokenBudget;
  final int? expectedOperationSequence;

  const CodexGoalMutation({
    required this.id,
    required this.kind,
    this.objective,
    this.status,
    this.includesTokenBudget = false,
    this.tokenBudget,
    this.expectedOperationSequence,
  });
}

/// Core state for a single chat session, managed by [ChatSessionNotifier].
@freezed
abstract class ChatSessionState with _$ChatSessionState {
  const factory ChatSessionState({
    // Process status
    @Default(ProcessStatus.starting) ProcessStatus status,

    // Messages
    @Default([]) List<ChatEntry> entries,

    // Approval / AskUserQuestion
    @Default(ApprovalState.none()) ApprovalState approval,

    // Session metadata
    String? claudeSessionId,
    String? projectPath,
    String? gitBranch,
    @Default('') String explorerCurrentPath,
    @Default([]) List<String> recentPeekedFiles,

    // Flags
    @Default(false) bool pastHistoryLoaded,
    @Default(false) bool bulkLoading,
    @Default(false) bool inPlanMode,
    @Default(false) bool collapseToolResults,

    // Legacy permission mode kept for compatibility with older bridge/app flows.
    @Default(PermissionMode.defaultMode) PermissionMode permissionMode,

    // Canonical session modes
    @Default(ExecutionMode.defaultMode) ExecutionMode executionMode,
    @Default(CodexApprovalPolicy.onRequest)
    CodexApprovalPolicy codexApprovalPolicy,
    @Default('user') String codexApprovalsReviewer,
    @Default(CodexPermissionsMode.defaultPermissions)
    CodexPermissionsMode codexPermissionsMode,
    String? codexModel,
    ReasoningEffort? codexModelReasoningEffort,
    @Default(CodexSpeed.standard) CodexSpeed codexSpeed,
    @Default(false) bool planMode,
    @Default(CodexNativePlanModeSupport.unknown)
    CodexNativePlanModeSupport codexNativePlanModeSupport,

    // Sandbox mode - Freezed default is .on but Cubit constructor overrides
    // based on provider (Claude=off, Codex=on).
    @Default(SandboxMode.on) SandboxMode sandboxMode,

    // Tool use IDs hidden by tool_use_summary (subagent compression)
    @Default({}) Set<String> hiddenToolUseIds,

    // Rewind preview (dry-run result)
    RewindPreviewMessage? rewindPreview,

    // Cost tracking
    @Default(0.0) double totalCost,
    Duration? totalDuration,

    // Slash commands available in this session
    @Default([]) List<SlashCommand> slashCommands,

    // Codex conversation queue (Bridge is the source of truth).
    QueuedInputItem? queuedInput,

    // Persisted Codex thread goal (Bridge/app-server is the source of truth).
    CodexGoal? goal,

    // Goal control is live-only. Bridge/app-server remains authoritative.
    @Default(false) bool goalStateLoaded,
    @Default(CodexGoalSupport.unknown) CodexGoalSupport goalSupport,
    @Default(false) bool advancedGoalControlSupported,
    int? goalOperationSequence,
    CodexGoalMutation? goalMutation,
    String? goalMutationError,
    CodexGoalErrorKind? goalMutationErrorKind,
    CodexGoalErrorKind? goalLoadErrorKind,
  }) = _ChatSessionState;
}

/// Represents the current approval/question state.
///
/// Uses sealed union so the UI can pattern-match exhaustively.
@freezed
abstract class ApprovalState with _$ApprovalState {
  /// No pending approval.
  const factory ApprovalState.none() = ApprovalNone;

  /// A tool is requesting permission to execute.
  const factory ApprovalState.permission({
    required String toolUseId,
    required PermissionRequestMessage request,
  }) = ApprovalPermission;

  /// Claude is asking the user a question (AskUserQuestion tool).
  const factory ApprovalState.askUser({
    required String toolUseId,
    required Map<String, dynamic> input,
  }) = ApprovalAskUser;
}
