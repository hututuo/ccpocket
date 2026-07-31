import 'dart:convert';
import 'dart:typed_data';

import '../utils/request_user_input.dart';

part 'local_features/protocol_host.dart';
part 'local_features/slots/auto_approval_protocol_slot.dart';
part 'local_features/slots/session_insights_models_slot.dart';
part 'local_features/slots/session_insights_protocol_slot.dart';
part 'local_features/slots/subagents_models_slot.dart';
part 'local_features/slots/subagents_protocol_slot.dart';
part 'local_features/slots/add_to_conversation_protocol_slot.dart';
part 'local_features/slots/side_chat_models_slot.dart';
part 'local_features/slots/side_chat_protocol_slot.dart';
part 'local_features/slots/persisted_side_chat_protocol_slot.dart';
part 'local_features/slots/ephemeral_side_chat_protocol_slot.dart';
part 'local_features/slots/conversation_mirror_protocol_slot.dart';
part 'local_features/slots/codex_core_actions_protocol_slot.dart';
part 'local_features/slots/codex_desktop_continuity_protocol_slot.dart';
part 'local_features/slots/file_transfer_protocol_slot.dart';
part 'local_features/slots/file_browser_protocol_slot.dart';
part 'local_features/slots/conversation_content_protocol_slot.dart';
part 'local_features/slots/conversation_sync_v2_protocol_slot.dart';

bool isCodexAutoReviewApprovalsReviewer(String? value) {
  return value == 'auto_review' || value == 'guardian_subagent';
}

// ---- Assistant content types ----

sealed class AssistantContent {
  factory AssistantContent.fromJson(Map<String, dynamic> json) {
    return switch (json['type'] as String) {
      'text' => TextContent(text: json['text'] as String),
      'tool_use' => ToolUseContent(
        id: json['id'] as String,
        name: json['name'] as String,
        input: Map<String, dynamic>.from(json['input'] as Map),
      ),
      'thinking' => ThinkingContent(
        thinking: json['thinking'] as String? ?? '',
      ),
      _ => UnknownAssistantContent(rawType: '${json['type']}'),
    };
  }
}

class TextContent implements AssistantContent {
  final String text;
  const TextContent({required this.text});
}

/// Display-compatible fallback for additive content types unknown to this app.
///
/// It remains a [TextContent] subtype so existing renderers keep showing the
/// diagnostic placeholder, but ordering logic can exclude synthetic text.
class UnknownAssistantContent extends TextContent {
  final String rawType;

  UnknownAssistantContent({required this.rawType})
    : super(text: '[Unknown content type: $rawType]');
}

bool isVisibleAssistantTextContent(AssistantContent content) =>
    content is TextContent &&
    content is! UnknownAssistantContent &&
    content.text.trim().isNotEmpty;

class ToolUseContent implements AssistantContent {
  final String id;
  final String name;
  final Map<String, dynamic> input;
  const ToolUseContent({
    required this.id,
    required this.name,
    required this.input,
  });
}

class ThinkingContent implements AssistantContent {
  final String thinking;
  const ThinkingContent({required this.thinking});
}

// ---- Assistant message ----

class AssistantMessage {
  final String id;
  final String role;
  final List<AssistantContent> content;
  final String model;

  const AssistantMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.model,
  });

  factory AssistantMessage.fromJson(Map<String, dynamic> json) {
    final contentList = (json['content'] as List)
        .map((c) => AssistantContent.fromJson(c as Map<String, dynamic>))
        .toList();
    return AssistantMessage(
      id: json['id'] as String? ?? '',
      role: json['role'] as String? ?? 'assistant',
      content: contentList,
      model: sanitizeCodexModelName(json['model'] as String?) ?? '',
    );
  }
}

// ---- Bridge connection state ----

enum BridgeConnectionState { disconnected, connecting, connected, reconnecting }

// ---- Message status (for user messages) ----

enum MessageStatus {
  sending,
  sent,
  queued,
  bridgeAccepted,
  providerAccepted,
  providerRejected,
  failed;

  bool get canRetry =>
      this == MessageStatus.failed || this == MessageStatus.providerRejected;
}

// ---- Process status ----

enum ProcessStatus {
  starting,
  idle,
  running,
  waitingApproval,
  compacting,
  unknown;

  static ProcessStatus fromString(String value) {
    return switch (value.trim()) {
      'starting' => ProcessStatus.starting,
      'idle' => ProcessStatus.idle,
      'running' => ProcessStatus.running,
      'waiting_approval' => ProcessStatus.waitingApproval,
      'compacting' => ProcessStatus.compacting,
      _ => ProcessStatus.unknown,
    };
  }

  String get wireValue => switch (this) {
    ProcessStatus.starting => 'starting',
    ProcessStatus.idle => 'idle',
    ProcessStatus.running => 'running',
    ProcessStatus.waitingApproval => 'waiting_approval',
    ProcessStatus.compacting => 'compacting',
    ProcessStatus.unknown => 'unknown',
  };
}

ProcessStatus _processStatusFromJson(dynamic value) {
  final rawStatus = _nonEmptyString(value);
  return rawStatus == null
      ? ProcessStatus.unknown
      : ProcessStatus.fromString(rawStatus);
}

ProcessStatus? _optionalProcessStatusFromJson(dynamic value) {
  final rawStatus = _nonEmptyString(value);
  return rawStatus == null ? null : ProcessStatus.fromString(rawStatus);
}

enum CodexThreadGoalStatus {
  active('active'),
  paused('paused'),
  blocked('blocked'),
  usageLimited('usageLimited'),
  budgetLimited('budgetLimited'),
  complete('complete');

  final String value;
  const CodexThreadGoalStatus(this.value);

  static CodexThreadGoalStatus fromString(String value) => switch (value) {
    'paused' => CodexThreadGoalStatus.paused,
    'blocked' => CodexThreadGoalStatus.blocked,
    'usageLimited' => CodexThreadGoalStatus.usageLimited,
    'budgetLimited' => CodexThreadGoalStatus.budgetLimited,
    'complete' => CodexThreadGoalStatus.complete,
    'active' => CodexThreadGoalStatus.active,
    _ => CodexThreadGoalStatus.active,
  };
}

class CodexGoal {
  final String threadId;
  final String objective;
  final CodexThreadGoalStatus status;
  final String? rawStatus;
  final int? tokenBudget;
  final int tokensUsed;
  final int timeUsedSeconds;
  final int createdAt;
  final int updatedAt;

  const CodexGoal({
    required this.threadId,
    required this.objective,
    required this.status,
    this.rawStatus,
    required this.tokenBudget,
    required this.tokensUsed,
    required this.timeUsedSeconds,
    required this.createdAt,
    required this.updatedAt,
  });

  factory CodexGoal.fromJson(Map<String, dynamic> json) {
    final rawStatus = json['status'] as String;
    return CodexGoal(
      threadId: json['threadId'] as String,
      objective: json['objective'] as String,
      status: CodexThreadGoalStatus.fromString(rawStatus),
      rawStatus: rawStatus,
      tokenBudget: json['tokenBudget'] as int?,
      tokensUsed: json['tokensUsed'] as int? ?? 0,
      timeUsedSeconds: json['timeUsedSeconds'] as int? ?? 0,
      createdAt: json['createdAt'] as int? ?? 0,
      updatedAt: json['updatedAt'] as int? ?? 0,
    );
  }

  String get effectiveStatus => rawStatus ?? status.value;

  /// Future app-server statuses retain their raw value without widening the
  /// legacy enum and breaking exhaustive switches in older presentation code.
  bool get hasUnknownStatus => !CodexThreadGoalStatus.values.any(
    (knownStatus) => knownStatus.value == effectiveStatus,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CodexGoal &&
          threadId == other.threadId &&
          objective == other.objective &&
          effectiveStatus == other.effectiveStatus &&
          tokenBudget == other.tokenBudget &&
          tokensUsed == other.tokensUsed &&
          timeUsedSeconds == other.timeUsedSeconds &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
    threadId,
    objective,
    effectiveStatus,
    tokenBudget,
    tokensUsed,
    timeUsedSeconds,
    createdAt,
    updatedAt,
  );
}

// ---- Provider ----

enum Provider {
  claude('claude', 'Claude'),
  codex('codex', 'Codex');

  final String value;
  final String label;
  const Provider(this.value, this.label);
}

String providerSessionIdentityKey(String provider, String sessionId) =>
    '$provider\u0000$sessionId';

String? sanitizeCodexModelName(String? model) {
  final normalized = model?.trim();
  if (normalized == null || normalized.isEmpty || normalized == 'codex') {
    return null;
  }
  return normalized;
}

const defaultCodexModels = <String>[
  'gpt-5.5',
  'gpt-5.4',
  'gpt-5.4-mini',
  'gpt-5.3-codex',
  'gpt-5.3-codex-spark',
];

const _deprecatedCodexModels = <String>{'gpt-5.2-codex'};

bool isDeprecatedCodexModel(String? model) {
  final normalized = sanitizeCodexModelName(model);
  return normalized != null && _deprecatedCodexModels.contains(normalized);
}

String? normalizeCodexModelForAvailableList(
  String? model,
  Iterable<String> availableModels,
) {
  final normalized = sanitizeCodexModelName(model);
  if (normalized == null) return null;
  if (!isDeprecatedCodexModel(normalized)) return normalized;

  final candidates = availableModels.toList();
  final effectiveModels = candidates.isNotEmpty
      ? candidates
      : defaultCodexModels;
  for (final candidate in effectiveModels) {
    final sanitizedCandidate = sanitizeCodexModelName(candidate);
    if (sanitizedCandidate == null ||
        isDeprecatedCodexModel(sanitizedCandidate)) {
      continue;
    }
    return sanitizedCandidate;
  }
  return null;
}

// ---- Permission mode ----

enum PermissionMode {
  defaultMode('default', 'Default'),
  acceptEdits('acceptEdits', 'Accept Edits'),
  plan('plan', 'Plan'),
  auto('auto', 'Auto'),
  bypassPermissions('bypassPermissions', 'Bypass All');

  final String value;
  final String label;
  const PermissionMode(this.value, this.label);
}

enum ExecutionMode {
  defaultMode('default', 'Default'),
  acceptEdits('acceptEdits', 'Accept Edits'),
  fullAccess('fullAccess', 'Full Access');

  final String value;
  final String label;
  const ExecutionMode(this.value, this.label);
}

ExecutionMode? executionModeFromRaw(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  for (final value in ExecutionMode.values) {
    if (value.value == raw) return value;
  }
  return null;
}

enum CodexApprovalPolicy {
  untrusted('untrusted'),
  onRequest('on-request'),
  onFailure('on-failure'),
  never('never');

  final String value;
  const CodexApprovalPolicy(this.value);
}

enum CodexPermissionsMode {
  defaultPermissions('default', 'On Request'),
  autoReview('autoReview', 'Auto-review'),
  fullAccess('fullAccess', 'Full access'),
  custom('custom', 'Custom (config.toml)');

  final String value;
  final String label;
  const CodexPermissionsMode(this.value, this.label);
}

enum CodexPermissionApplyStrategy {
  nextTurn('next_turn'),
  restartNow('restart_now');

  final String value;
  const CodexPermissionApplyStrategy(this.value);
}

CodexPermissionsMode? codexPermissionsModeFromRaw(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  for (final value in CodexPermissionsMode.values) {
    if (value.value == raw) return value;
  }
  return null;
}

CodexPermissionsMode codexPermissionsModeFromSettings({
  String? codexPermissionsMode,
  String? approvalPolicy,
  String? approvalsReviewer,
  String? sandboxMode,
}) {
  final explicit = codexPermissionsModeFromRaw(codexPermissionsMode);
  if (explicit != null) return explicit;
  if (codexPermissionsMode != null && codexPermissionsMode.isNotEmpty) {
    return CodexPermissionsMode.custom;
  }
  final normalizedSandbox = switch (sandboxMode) {
    'danger-full-access' || 'off' => 'danger-full-access',
    'workspace-write' || 'on' => 'workspace-write',
    'read-only' => 'read-only',
    _ => null,
  };
  if (approvalPolicy == CodexApprovalPolicy.never.value &&
      normalizedSandbox == 'danger-full-access') {
    return CodexPermissionsMode.fullAccess;
  }
  if (approvalPolicy == CodexApprovalPolicy.onRequest.value &&
      normalizedSandbox == 'workspace-write') {
    if (isCodexAutoReviewApprovalsReviewer(approvalsReviewer)) {
      return CodexPermissionsMode.autoReview;
    }
    if (approvalsReviewer == null || approvalsReviewer == 'user') {
      return CodexPermissionsMode.defaultPermissions;
    }
  }
  return CodexPermissionsMode.custom;
}

String? _resolveCodexPermissionsMode(Map<String, dynamic>? codexSettings) {
  if (codexSettings == null) return null;
  final explicit = codexPermissionsModeFromRaw(
    codexSettings['codexPermissionsMode'] as String?,
  );
  if (explicit != null) return explicit.value;
  if (codexSettings['codexPermissionsMode'] != null) {
    return CodexPermissionsMode.custom.value;
  }
  if (codexSettings['approvalPolicy'] == null ||
      codexSettings['sandboxMode'] == null) {
    return null;
  }
  return codexPermissionsModeFromSettings(
    approvalPolicy: codexSettings['approvalPolicy'] as String?,
    approvalsReviewer: codexSettings['approvalsReviewer'] as String?,
    sandboxMode: codexSettings['sandboxMode'] as String?,
  ).value;
}

CodexApprovalPolicy? approvalPolicyForCodexPermissionsMode(
  CodexPermissionsMode mode,
) => switch (mode) {
  CodexPermissionsMode.defaultPermissions ||
  CodexPermissionsMode.autoReview => CodexApprovalPolicy.onRequest,
  CodexPermissionsMode.fullAccess => CodexApprovalPolicy.never,
  CodexPermissionsMode.custom => null,
};

String? approvalsReviewerForCodexPermissionsMode(CodexPermissionsMode mode) =>
    switch (mode) {
      CodexPermissionsMode.autoReview => 'auto_review',
      CodexPermissionsMode.defaultPermissions ||
      CodexPermissionsMode.fullAccess => 'user',
      CodexPermissionsMode.custom => null,
    };

SandboxMode? sandboxModeForCodexPermissionsMode(CodexPermissionsMode mode) =>
    switch (mode) {
      CodexPermissionsMode.defaultPermissions ||
      CodexPermissionsMode.autoReview => SandboxMode.on,
      CodexPermissionsMode.fullAccess => SandboxMode.off,
      CodexPermissionsMode.custom => null,
    };

CodexApprovalPolicy? codexApprovalPolicyFromRaw(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  if (raw == CodexApprovalPolicy.onFailure.value) {
    return CodexApprovalPolicy.onRequest;
  }
  for (final value in CodexApprovalPolicy.values) {
    if (value.value == raw) return value;
  }
  return null;
}

CodexApprovalPolicy codexApprovalPolicyFromLegacyExecutionMode(String? raw) {
  return executionModeFromRaw(raw) == ExecutionMode.fullAccess
      ? CodexApprovalPolicy.never
      : CodexApprovalPolicy.onRequest;
}

String codexApprovalPolicyFromLegacyExecutionModeValue(String? raw) =>
    codexApprovalPolicyFromLegacyExecutionMode(raw).value;

bool derivePlanMode({bool? planMode, String? permissionMode}) {
  return planMode ?? (permissionMode == PermissionMode.plan.value);
}

ExecutionMode deriveExecutionMode({
  String? provider,
  String? executionMode,
  String? permissionMode,
  String? approvalPolicy,
}) {
  final explicit = executionModeFromRaw(executionMode);
  if (explicit != null) return explicit;

  if (permissionMode == PermissionMode.bypassPermissions.value) {
    return ExecutionMode.fullAccess;
  }
  if (permissionMode == PermissionMode.acceptEdits.value) {
    return provider == Provider.codex.value
        ? ExecutionMode.defaultMode
        : ExecutionMode.acceptEdits;
  }
  if (approvalPolicy == 'never') return ExecutionMode.fullAccess;
  return ExecutionMode.defaultMode;
}

String? resolveCodexApprovalPolicy({
  String? approvalPolicy,
  String? executionMode,
}) {
  return approvalPolicy?.isNotEmpty == true
      ? approvalPolicy
      : (executionMode?.isNotEmpty == true
            ? codexApprovalPolicyFromLegacyExecutionModeValue(executionMode)
            : null);
}

PermissionMode legacyPermissionModeFromModes(
  Provider provider, {
  required ExecutionMode executionMode,
  required bool planMode,
}) {
  if (planMode) return PermissionMode.plan;
  switch (executionMode) {
    case ExecutionMode.defaultMode:
      return provider == Provider.codex
          ? PermissionMode.acceptEdits
          : PermissionMode.defaultMode;
    case ExecutionMode.acceptEdits:
      return PermissionMode.acceptEdits;
    case ExecutionMode.fullAccess:
      return PermissionMode.bypassPermissions;
  }
}

enum ClaudeEffort {
  low('low', 'Low'),
  medium('medium', 'Medium'),
  high('high', 'High'),
  xhigh('xhigh', 'X High'),
  max('max', 'Max');

  final String value;
  final String label;
  const ClaudeEffort(this.value, this.label);
}

// ---- Sandbox mode (Claude & Codex) ----

enum SandboxMode {
  on('on', 'Sandbox On'),
  off('off', 'Sandbox Off');

  final String value;
  final String label;
  const SandboxMode(this.value, this.label);
}

final class ReasoningEffort {
  static const none = ReasoningEffort._('none', 'none');
  static const minimal = ReasoningEffort._('minimal', 'minimal');
  static const low = ReasoningEffort._('low', 'light');
  static const medium = ReasoningEffort._('medium', 'medium');
  static const high = ReasoningEffort._('high', 'high');
  static const xhigh = ReasoningEffort._('xhigh', 'x-high');
  static const max = ReasoningEffort._('max', 'max');
  static const ultra = ReasoningEffort._('ultra', 'ultra');

  static const values = [none, minimal, low, medium, high, xhigh, max, ultra];

  final String value;
  final String label;
  const ReasoningEffort._(this.value, this.label);

  factory ReasoningEffort.fromValue(String value) {
    for (final effort in values) {
      if (effort.value == value) return effort;
    }
    final words = value.split(RegExp(r'[-_\s]+'));
    final label = words
        .where((word) => word.isNotEmpty)
        .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
    return ReasoningEffort._(value, label.isEmpty ? value : label);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReasoningEffort && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

ReasoningEffort? reasoningEffortByValue(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  return ReasoningEffort.fromValue(value);
}

enum CodexSpeed {
  standard('standard', 'Standard'),
  fast('fast', 'Fast'),

  /// A service tier advertised by a newer Codex runtime that this client does
  /// not know how to mutate yet. The exact wire value stays on the session
  /// snapshot and is rendered read-only instead of being mislabeled Standard.
  unknown('unknown', 'Custom');

  final String value;
  final String label;
  const CodexSpeed(this.value, this.label);
}

CodexSpeed codexSpeedFromRaw(String? raw) => switch (raw?.trim()) {
  'fast' || 'priority' => CodexSpeed.fast,
  null || '' || 'standard' || 'default' => CodexSpeed.standard,
  _ => CodexSpeed.unknown,
};

/// Parses persisted input for controls that can only select Standard or Fast.
/// Unknown runtime tiers stay untouched unless the user explicitly chooses a
/// supported value in an active-session control.
CodexSpeed codexSelectableSpeedFromRaw(String? raw) {
  final parsed = codexSpeedFromRaw(raw);
  return parsed == CodexSpeed.unknown ? CodexSpeed.standard : parsed;
}

/// Parses the service tier of an already-running Codex session.
///
/// A null result means the runtime did not advertise the setting. Unknown
/// non-empty values are preserved as [CodexSpeed.unknown]; callers keep the
/// original wire value alongside the enum and present it read-only.
CodexSpeed? codexRuntimeSpeedFromRaw(String? raw) {
  final normalized = raw?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  return codexSpeedFromRaw(normalized);
}

enum WebSearchMode {
  disabled('disabled', 'Disabled'),
  cached('cached', 'Cached'),
  live('live', 'Live');

  final String value;
  final String label;
  const WebSearchMode(this.value, this.label);
}

// ---- Image reference ----

class ImageRef {
  final String id;
  final String url;
  final String mimeType;
  final String? thumbnailUrl;

  const ImageRef({
    required this.id,
    required this.url,
    required this.mimeType,
    this.thumbnailUrl,
  });

  factory ImageRef.fromJson(Map<String, dynamic> json) {
    return ImageRef(
      id: json['id'] as String,
      url: json['url'] as String,
      mimeType: json['mimeType'] as String,
      thumbnailUrl: json['thumbnailUrl'] as String?,
    );
  }
}

// ---- Worktree info ----

class WorktreeInfo {
  final String worktreePath;
  final String branch;
  final String projectPath;
  final String? head;

  const WorktreeInfo({
    required this.worktreePath,
    required this.branch,
    required this.projectPath,
    this.head,
  });

  factory WorktreeInfo.fromJson(Map<String, dynamic> json) {
    return WorktreeInfo(
      worktreePath: json['worktreePath'] as String,
      branch: json['branch'] as String,
      projectPath: json['projectPath'] as String,
      head: json['head'] as String?,
    );
  }
}

// ---- Gallery image ----

class GalleryImage {
  final String id;
  final String url;
  final String mimeType;
  final String projectPath;
  final String projectName;
  final String? sessionId;
  final String addedAt;
  final int sizeBytes;

  const GalleryImage({
    required this.id,
    required this.url,
    required this.mimeType,
    required this.projectPath,
    required this.projectName,
    this.sessionId,
    required this.addedAt,
    required this.sizeBytes,
  });

  factory GalleryImage.fromJson(Map<String, dynamic> json) {
    return GalleryImage(
      id: json['id'] as String,
      url: json['url'] as String,
      mimeType: json['mimeType'] as String,
      projectPath: json['projectPath'] as String,
      projectName: json['projectName'] as String,
      sessionId: json['sessionId'] as String?,
      addedAt: json['addedAt'] as String,
      sizeBytes: json['sizeBytes'] as int? ?? 0,
    );
  }
}

enum QueuedInputDeliveryStage {
  bridgeAccepted('bridge_accepted', 1),
  providerAccepted('provider_accepted', 2),
  providerRejected('provider_rejected', 2);

  const QueuedInputDeliveryStage(this.wireValue, this.rank);

  final String wireValue;
  final int rank;

  static QueuedInputDeliveryStage? fromWireValue(Object? value) =>
      switch (value) {
        'bridge_accepted' => QueuedInputDeliveryStage.bridgeAccepted,
        'provider_accepted' => QueuedInputDeliveryStage.providerAccepted,
        'provider_rejected' => QueuedInputDeliveryStage.providerRejected,
        _ => null,
      };
}

class QueuedInputItem {
  final String itemId;
  final String text;
  final String createdAt;
  final String? updatedAt;
  final String? clientMessageId;
  final QueuedInputDeliveryStage? deliveryStage;
  final String? deliveryError;
  final int imageCount;
  final List<Map<String, String>> skills;
  final List<Map<String, String>> mentions;

  const QueuedInputItem({
    required this.itemId,
    required this.text,
    required this.createdAt,
    this.updatedAt,
    this.clientMessageId,
    this.deliveryStage,
    this.deliveryError,
    this.imageCount = 0,
    this.skills = const [],
    this.mentions = const [],
  });

  factory QueuedInputItem.fromJson(Map<String, dynamic> json) {
    return QueuedInputItem(
      itemId: json['itemId'] as String? ?? '',
      text: json['text'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String?,
      clientMessageId: json['clientMessageId'] as String?,
      deliveryStage: QueuedInputDeliveryStage.fromWireValue(
        json['deliveryStage'],
      ),
      deliveryError: json['deliveryError'] as String?,
      imageCount: json['imageCount'] as int? ?? 0,
      skills: _stringMapList(json['skills']),
      mentions: _stringMapList(json['mentions']),
    );
  }

  QueuedInputItem withDeliveryStage(
    QueuedInputDeliveryStage incoming, {
    String? error,
  }) {
    final current = deliveryStage;
    if (current != null && current.rank >= incoming.rank) return this;
    return QueuedInputItem(
      itemId: itemId,
      text: text,
      createdAt: createdAt,
      updatedAt: updatedAt,
      clientMessageId: clientMessageId,
      deliveryStage: incoming,
      deliveryError: error,
      imageCount: imageCount,
      skills: skills,
      mentions: mentions,
    );
  }

  QueuedInputItem mergeDeliveryStateFrom(QueuedInputItem previous) {
    final previousStage = previous.deliveryStage;
    final currentStage = deliveryStage;
    final keepPrevious =
        previousStage != null &&
        (currentStage == null || previousStage.rank >= currentStage.rank);
    return QueuedInputItem(
      itemId: itemId,
      text: text,
      createdAt: createdAt,
      updatedAt: updatedAt,
      clientMessageId: clientMessageId ?? previous.clientMessageId,
      deliveryStage: keepPrevious ? previousStage : currentStage,
      deliveryError: keepPrevious ? previous.deliveryError : deliveryError,
      imageCount: imageCount,
      skills: skills,
      mentions: mentions,
    );
  }
}

bool queuedInputItemsShareIdentity(
  QueuedInputItem left,
  QueuedInputItem right,
) {
  if (left.itemId == right.itemId) return true;
  final leftClientId = left.clientMessageId?.trim();
  final rightClientId = right.clientMessageId?.trim();
  return leftClientId != null &&
      leftClientId.isNotEmpty &&
      leftClientId == rightClientId;
}

// ---- Usage info ----

class UsageWindow {
  final double utilization;
  final String resetsAt;

  const UsageWindow({required this.utilization, required this.resetsAt});

  factory UsageWindow.fromJson(Map<String, dynamic> json) {
    return UsageWindow(
      utilization: (json['utilization'] as num).toDouble(),
      resetsAt: json['resetsAt'] as String,
    );
  }

  /// Parse resetsAt as DateTime (ISO 8601).
  DateTime? get resetsAtDateTime => DateTime.tryParse(resetsAt);
}

class UsageInfo {
  final String provider;
  final UsageWindow? fiveHour;
  final UsageWindow? sevenDay;
  final String? error;

  const UsageInfo({
    required this.provider,
    this.fiveHour,
    this.sevenDay,
    this.error,
  });

  factory UsageInfo.fromJson(Map<String, dynamic> json) {
    return UsageInfo(
      provider: json['provider'] as String,
      fiveHour: json['fiveHour'] != null
          ? UsageWindow.fromJson(json['fiveHour'] as Map<String, dynamic>)
          : null,
      sevenDay: json['sevenDay'] != null
          ? UsageWindow.fromJson(json['sevenDay'] as Map<String, dynamic>)
          : null,
      error: json['error'] as String?,
    );
  }

  bool get hasData => fiveHour != null || sevenDay != null;
  bool get hasError => error != null && !hasData;
}

// ---- Helpers ----

/// Normalize tool_result content: Claude CLI may send String or List of content blocks.
String _normalizeToolResultContent(dynamic content) {
  if (content is String) return content;
  if (content is List) {
    return content
        .whereType<Map<String, dynamic>>()
        .where((c) => c['type'] == 'text')
        .map((c) => c['text']?.toString() ?? '')
        .join('\n');
  }
  return content?.toString() ?? '';
}

List<ArtifactRef> _parseArtifactRefs(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => ArtifactRef.fromJson(Map<String, dynamic>.from(item)))
      .where((artifact) => artifact.id.isNotEmpty)
      .toList(growable: false);
}

/// Parse session_list tolerantly: one malformed session entry must not
/// blank the whole home screen, so bad entries are skipped and counted.
/// A frame without a `sessions` list is rejected outright — treating it as
/// an empty authoritative list would wipe the known sessions from the UI.
SessionListMessage _sessionListFromJson(Map<String, dynamic> json) {
  final sessions = <SessionInfo>[];
  var dropped = 0;
  final rawSessions = json['sessions'];
  if (rawSessions is! List) {
    throw const FormatException('session_list has no sessions list');
  }
  for (final entry in rawSessions) {
    try {
      sessions.add(
        SessionInfo.fromJson(Map<String, dynamic>.from(entry as Map)),
      );
    } catch (_) {
      dropped++;
    }
  }
  return SessionListMessage(
    sessions: sessions,
    droppedSessionCount: dropped,
    bridgeInstanceId: json['bridgeInstanceId'] as String?,
    codexSourceId: json['codexSourceId'] as String?,
    allowedDirs:
        (json['allowedDirs'] as List?)?.whereType<String>().toList() ??
        const [],
    claudeModels:
        (json['claudeModels'] as List?)?.whereType<String>().toList() ??
        const [],
    claudeModelEfforts:
        (json['claudeModelEfforts'] as Map?)?.map(
          (key, value) => MapEntry(
            key as String,
            (value as List?)?.whereType<String>().toList() ?? const [],
          ),
        ) ??
        const {},
    codexModels:
        (json['codexModels'] as List?)?.whereType<String>().toList() ??
        const [],
    codexModelReasoningEfforts:
        (json['codexModelReasoningEfforts'] as Map?)?.map(
          (key, value) => MapEntry(
            key as String,
            (value as List?)?.whereType<String>().toList() ?? const [],
          ),
        ) ??
        const {},
    codexModelServiceTiers:
        (json['codexModelServiceTiers'] as Map?)?.map(
          (key, value) => MapEntry(
            key as String,
            (value as List?)?.whereType<String>().toList() ?? const [],
          ),
        ) ??
        const {},
    codexProfiles:
        (json['codexProfiles'] as List?)?.whereType<String>().toList() ??
        const [],
    defaultCodexProfile: json['defaultCodexProfile'] as String?,
    codexAutoReviewDisabled: json['codexAutoReviewDisabled'] as bool? ?? false,
    bridgeVersion: json['bridgeVersion'] as String?,
    bridgeCapabilities:
        (json['bridgeCapabilities'] as List?)?.whereType<String>().toList() ??
        const [],
  );
}

/// Reads a JSON scalar as an int, tolerating doubles (JSON numbers may
/// arrive as floating point) and yielding null for any other shape.
int? _intFromJson(dynamic value) =>
    value is num && value.isFinite ? value.toInt() : null;

/// Parses the `messages` list of a history frame, dropping malformed
/// entries: one bad entry must not wipe the whole list. A frame without a
/// list at all is fundamentally broken and is rejected instead.
List<HistoryEntry> _historyEntriesFromJson(dynamic raw) {
  if (raw is! List) {
    throw const FormatException('history frame has no messages list');
  }
  final entries = <HistoryEntry>[];
  for (final entry in raw) {
    try {
      entries.add(
        HistoryEntry.fromJson(Map<String, dynamic>.from(entry as Map)),
      );
    } catch (_) {
      // Drop the malformed entry.
    }
  }
  return entries;
}

List<ServerMessage> _historyMessagesFromJson(dynamic raw) {
  if (raw is! List) {
    throw const FormatException('history frame has no messages list');
  }
  final messages = <ServerMessage>[];
  for (final entry in raw) {
    try {
      messages.add(
        ServerMessage.fromJson(Map<String, dynamic>.from(entry as Map)),
      );
    } catch (_) {
      // Drop the malformed message.
    }
  }
  return messages;
}

HistoryPageMessage _historyPageFromJson(Map<String, dynamic> json) {
  final nextBeforeSeq = _intFromJson(json['nextBeforeSeq']);
  final rawCursor = json['nextBeforeCursor'];
  final nextBeforeCursor = rawCursor is String && rawCursor.isNotEmpty
      ? rawCursor
      : null;
  return HistoryPageMessage(
    requestId: json['requestId'] as String,
    sessionId: json['sessionId'] as String,
    beforeSeq: _intFromJson(json['beforeSeq']) ?? 0,
    nextBeforeSeq: nextBeforeSeq ?? 0,
    nextBeforeCursor: nextBeforeCursor,
    // Without a usable continuation cursor the page cannot be paged past;
    // report the stream as exhausted instead of fabricating a cursor.
    hasMore:
        (nextBeforeSeq != null || nextBeforeCursor != null) &&
        (json['hasMore'] as bool? ?? false),
    error: json['error'] as String?,
    entries: _historyEntriesFromJson(json['messages']),
  );
}

/// A Bridge-owned reference to a local file mentioned by an assistant or tool
/// result. [originalHref] preserves the assistant's text for exact UI matching;
/// the client can resolve only the opaque [id], never an arbitrary path.
class ArtifactRef {
  final String id;
  final String filename;
  final String mimeType;
  final int sizeBytes;

  /// `source` opens in File Peek; `preview` is resolved to a short-lived URL.
  final String kind;

  /// Origin of the reference, such as `assistant_markdown`.
  final String source;
  final int? textContentIndex;
  final String? originalHref;
  final String? projectRelativePath;
  final int? line;
  final int? column;

  const ArtifactRef({
    required this.id,
    required this.filename,
    required this.mimeType,
    required this.sizeBytes,
    required this.kind,
    required this.source,
    this.textContentIndex,
    this.originalHref,
    this.projectRelativePath,
    this.line,
    this.column,
  });

  factory ArtifactRef.fromJson(Map<String, dynamic> json) {
    return ArtifactRef(
      id: json['id'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      kind: json['kind'] as String? ?? '',
      source: json['source'] as String? ?? '',
      textContentIndex: (json['textContentIndex'] as num?)?.toInt(),
      originalHref: json['originalHref'] as String?,
      projectRelativePath: json['projectRelativePath'] as String?,
      line: (json['line'] as num?)?.toInt(),
      column: (json['column'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'filename': filename,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
    'kind': kind,
    'source': source,
    if (textContentIndex != null) 'textContentIndex': textContentIndex,
    if (originalHref != null) 'originalHref': originalHref,
    if (projectRelativePath != null) 'projectRelativePath': projectRelativePath,
    if (line != null) 'line': line,
    if (column != null) 'column': column,
  };

  bool get isSource => kind == 'source';
  bool get isPreview => kind == 'preview';

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArtifactRef &&
          id == other.id &&
          filename == other.filename &&
          mimeType == other.mimeType &&
          sizeBytes == other.sizeBytes &&
          kind == other.kind &&
          source == other.source &&
          textContentIndex == other.textContentIndex &&
          originalHref == other.originalHref &&
          projectRelativePath == other.projectRelativePath &&
          line == other.line &&
          column == other.column;

  @override
  int get hashCode => Object.hash(
    id,
    filename,
    mimeType,
    sizeBytes,
    kind,
    source,
    textContentIndex,
    originalHref,
    projectRelativePath,
    line,
    column,
  );
}

// ---- Server messages ----

class ServerMessageTimestamp {
  final DateTime value;
  final bool isAuthoritative;

  const ServerMessageTimestamp({
    required this.value,
    required this.isAuthoritative,
  });
}

final Expando<ServerMessageTimestamp> _serverMessageTimestamps =
    Expando<ServerMessageTimestamp>('ccpocket.server_message_timestamp');

ServerMessageTimestamp? serverMessageTimestamp(ServerMessage message) =>
    _serverMessageTimestamps[message];

void attachServerMessageTimestamp(
  ServerMessage message, {
  required DateTime value,
  required bool isAuthoritative,
}) {
  _serverMessageTimestamps[message] = ServerMessageTimestamp(
    value: value,
    isAuthoritative: isAuthoritative,
  );
}

void _attachServerMessageTimestamp(
  ServerMessage message,
  Map<String, dynamic> json,
) {
  final receivedAt = DateTime.tryParse(json['receivedAt'] as String? ?? '');
  if (receivedAt != null) {
    _serverMessageTimestamps[message] = ServerMessageTimestamp(
      value: receivedAt,
      isAuthoritative: true,
    );
    return;
  }
  final sourceTimestamp = DateTime.tryParse(
    json['sourceTimestamp'] as String? ?? '',
  );
  final legacyUserTimestamp = json['type'] == 'user_input'
      ? DateTime.tryParse(json['timestamp'] as String? ?? '')
      : null;
  final fallback = sourceTimestamp ?? legacyUserTimestamp;
  if (fallback != null) {
    _serverMessageTimestamps[message] = ServerMessageTimestamp(
      value: fallback,
      isAuthoritative:
          sourceTimestamp != null &&
          json['sourceTimestampIsAuthoritative'] == true,
    );
  }
}

sealed class ServerMessage {
  factory ServerMessage.fromJson(Map<String, dynamic> json) {
    final localFeatureMessage = LocalFeatureProtocolHost.tryDecode(json);
    if (localFeatureMessage != null) {
      _attachServerMessageTimestamp(localFeatureMessage, json);
      return localFeatureMessage;
    }
    final message = switch (json['type'] as String) {
      'client_delivery_mode_state_v1' => ClientDeliveryModeStateMessage(
        mode: BridgeClientDeliveryMode.fromWire(json['mode'] as String?),
        requestId: json['requestId'] as String? ?? '',
        activeWorkCount: json['activeWorkCount'] as int? ?? 0,
      ),
      'background_notification_v1' => BackgroundNotificationMessage(
        deliveryId: json['deliveryId'] as String? ?? '',
        eventType: json['eventType'] as String? ?? '',
        sessionId: json['sessionId'] as String? ?? '',
        provider: json['provider'] as String? ?? 'claude',
        title: json['title'] as String? ?? 'CC Pocket',
        body: json['body'] as String? ?? '',
        occurredAt: DateTime.tryParse(json['occurredAt'] as String? ?? ''),
        data:
            (json['data'] as Map?)?.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ) ??
            const <String, String>{},
      ),
      'background_activity_state_v1' => BackgroundActivityStateMessage(
        activeWorkCount: json['activeWorkCount'] as int? ?? 0,
        occurredAt: DateTime.tryParse(json['occurredAt'] as String? ?? ''),
      ),
      'push_registration_state_v1' => PushRegistrationStateMessage(
        operation: json['operation'] as String? ?? 'register',
        requestId: json['requestId'] as String? ?? '',
        success: json['success'] as bool? ?? false,
        errorCode: json['errorCode'] as String?,
      ),
      'system' => SystemMessage(
        subtype: json['subtype'] as String? ?? '',
        sessionId: json['sessionId'] as String?,
        claudeSessionId: json['claudeSessionId'] as String?,
        model: json['model'] as String?,
        approvalPolicy: json['approvalPolicy'] as String?,
        approvalsReviewer: json['approvalsReviewer'] as String?,
        codexPermissionsMode: json['codexPermissionsMode'] as String?,
        provider: json['provider'] as String?,
        projectPath: json['projectPath'] as String?,
        permissionMode: json['permissionMode'] as String?,
        executionMode: json['executionMode'] as String?,
        planMode: json['planMode'] as bool?,
        sandboxMode: json['sandboxMode'] as String?,
        modelReasoningEffort: json['modelReasoningEffort'] as String?,
        serviceTier: json['serviceTier'] as String?,
        networkAccessEnabled: json['networkAccessEnabled'] as bool?,
        webSearchMode: json['webSearchMode'] as String?,
        slashCommands:
            (json['slashCommands'] as List?)
                ?.map((e) => e as String)
                .toList() ??
            const [],
        skills:
            (json['skills'] as List?)?.map((e) => e as String).toList() ??
            const [],
        skillMetadata:
            (json['skillMetadata'] as List?)
                ?.map(
                  (e) => CodexSkillMetadata.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
        apps:
            (json['apps'] as List?)?.map((e) => e as String).toList() ??
            const [],
        appMetadata:
            (json['appMetadata'] as List?)
                ?.map(
                  (e) => CodexAppMetadata.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
        plugins:
            (json['plugins'] as List?)?.whereType<String>().toList() ??
            const [],
        pluginMetadata:
            (json['pluginMetadata'] as List?)
                ?.map(
                  (e) =>
                      CodexPluginMetadata.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
        worktreePath: json['worktreePath'] as String?,
        worktreeBranch: json['worktreeBranch'] as String?,
        clearContext: json['clearContext'] as bool? ?? false,
        sourceSessionId: json['sourceSessionId'] as String?,
        forkedFromSessionId: json['forkedFromSessionId'] as String?,
        forkedFromThreadId: json['forkedFromThreadId'] as String?,
        startRequestId: json['startRequestId'] as String?,
        resumeRequestId: json['resumeRequestId'] as String?,
        sessionLinkGeneration: (json['sessionLinkGeneration'] as num?)?.toInt(),
        errorMessage: json['errorMessage'] as String?,
        tipCode: json['tipCode'] as String?,
        permissionChangeId: json['permissionChangeId'] as String?,
        codexCliJoin: json['codexCliJoin'] is Map<String, dynamic>
            ? CodexCliJoinTarget.fromJson(
                json['codexCliJoin'] as Map<String, dynamic>,
              )
            : null,
      ),
      'assistant' => AssistantServerMessage(
        message: AssistantMessage.fromJson(
          json['message'] as Map<String, dynamic>,
        ),
        messageUuid: json['messageUuid'] as String?,
        artifacts: _parseArtifactRefs(json['artifacts']),
        historyToolDetailGaps:
            (json['historyToolDetailGaps'] as List?)
                ?.whereType<Map>()
                .map(
                  (value) => HistoryToolDetailGap.fromJson(
                    Map<String, dynamic>.from(value),
                  ),
                )
                .where((gap) => gap.isValid)
                .toList() ??
            const [],
      ),
      'tool_result' => ToolResultMessage(
        toolUseId: json['toolUseId'] as String,
        content: _normalizeToolResultContent(json['content']),
        toolName: json['toolName'] as String?,
        images:
            (json['images'] as List?)
                ?.map((i) => ImageRef.fromJson(i as Map<String, dynamic>))
                .toList() ??
            const [],
        userMessageUuid: json['userMessageUuid'] as String?,
        artifacts: _parseArtifactRefs(json['artifacts']),
      ),
      'artifact_resolved' => ArtifactResolvedMessage(
        requestId: json['requestId'] as String? ?? '',
        artifactId: json['artifactId'] as String? ?? '',
        relativeUrl: json['relativeUrl'] as String?,
        expiresAt: json['expiresAt'] as String?,
        error: json['error'] as String?,
        errorCode: json['errorCode'] as String?,
      ),
      'result' => ResultMessage(
        subtype: json['subtype'] as String? ?? '',
        result: json['result'] as String?,
        error: json['error'] as String?,
        cost: (json['cost'] as num?)?.toDouble(),
        duration: (json['duration'] as num?)?.toDouble(),
        sessionId: json['sessionId'] as String?,
        stopReason: json['stopReason'] as String?,
        inputTokens: json['inputTokens'] as int?,
        cachedInputTokens: json['cachedInputTokens'] as int?,
        outputTokens: json['outputTokens'] as int?,
        toolCalls: json['toolCalls'] as int?,
        fileEdits: json['fileEdits'] as int?,
      ),
      'guardian_approval' => GuardianApprovalMessage.fromJson(json),
      'error' =>
        _guardianReviewFromErrorJson(json) ??
            ErrorMessage(
              message: json['message'] as String,
              errorCode: json['errorCode'] as String?,
              sessionId: json['sessionId'] as String?,
              permissionChangeId: json['permissionChangeId'] as String?,
              goalChangeId: json['goalChangeId'] as String?,
            ),
      sessionLinkProgressCapability => SessionLinkProgressMessage.fromJson(
        json,
      ),
      'session_link_resolution' => SessionLinkResolutionMessage(
        requestId: json['requestId'] as String,
        sourceSessionId: json['sourceSessionId'] as String,
        status: SessionLinkResolutionStatus.fromString(
          json['status'] as String?,
        ),
        bridgeSessionId: json['bridgeSessionId'] as String?,
        provider: json['provider'] as String?,
        generation: (json['sessionLinkGeneration'] as num?)?.toInt(),
        recentSession: switch (json['recentSession']) {
          final Map<String, dynamic> value => RecentSession.fromJson(value),
          _ => null,
        },
      ),
      'status' => StatusMessage(
        status: _processStatusFromJson(json['status']),
        rawStatus: _nonEmptyString(json['status']),
        activityAt: json['activityAt'] as String?,
      ),
      'history' => HistoryMessage(
        messages: _historyMessagesFromJson(json['messages']),
        historyWindow: switch (json['historyWindow']) {
          final Map<String, dynamic> value => HistoryWindowInfo.fromJson(value),
          _ => null,
        },
      ),
      'history_page' => _historyPageFromJson(json),
      'history_tool_details' => HistoryToolDetailsMessage(
        requestId: json['requestId'] as String? ?? '',
        sessionId: json['sessionId'] as String? ?? '',
        error: json['error'] as String?,
        details: ((json['details'] as List?) ?? const [])
            .whereType<Map>()
            .take(8)
            .map(
              (value) =>
                  HistoryToolDetail.fromJson(Map<String, dynamic>.from(value)),
            )
            .where((detail) => detail.isValid)
            .toList(),
      ),
      'history_delta' => HistoryDeltaMessage(
        sessionId: json['sessionId'] as String?,
        fromSeq: _intFromJson(json['fromSeq']) ?? 0,
        toSeq: _intFromJson(json['toSeq']) ?? 0,
        entries: _historyEntriesFromJson(json['messages']),
        status: _optionalProcessStatusFromJson(json['status']),
        rawStatus: _nonEmptyString(json['status']),
      ),
      'history_snapshot' => HistorySnapshotMessage(
        sessionId: json['sessionId'] as String?,
        fromSeq: _intFromJson(json['fromSeq']) ?? 0,
        toSeq: _intFromJson(json['toSeq']) ?? 0,
        entries: _historyEntriesFromJson(json['messages']),
        status: _optionalProcessStatusFromJson(json['status']),
        rawStatus: _nonEmptyString(json['status']),
        reason: json['reason'] as String? ?? 'compacted',
        historyWindow: switch (json['historyWindow']) {
          final Map<String, dynamic> value => HistoryWindowInfo.fromJson(value),
          _ => null,
        },
      ),
      'conversation_queue' => ConversationQueueMessage(
        sessionId: json['sessionId'] as String?,
        limit: json['limit'] as int? ?? 1,
        items:
            (json['items'] as List?)
                ?.map(
                  (item) =>
                      QueuedInputItem.fromJson(item as Map<String, dynamic>),
                )
                .toList() ??
            const [],
      ),
      'goal_state' => GoalStateMessage(
        sessionId: json['sessionId'] as String?,
        goalChangeId: json['goalChangeId'] as String?,
        goalOperationSequence: (json['goalOperationSequence'] as num?)?.toInt(),
        goal: json['goal'] is Map<String, dynamic>
            ? CodexGoal.fromJson(json['goal'] as Map<String, dynamic>)
            : null,
      ),
      'permission_request' => PermissionRequestMessage(
        toolUseId: json['toolUseId'] as String,
        toolName: json['toolName'] as String,
        input: Map<String, dynamic>.from(json['input'] as Map),
      ),
      'permission_resolved' => PermissionResolvedMessage(
        toolUseId: json['toolUseId'] as String,
      ),
      'stream_delta' => StreamDeltaMessage(text: json['text'] as String),
      'thinking_delta' => ThinkingDeltaMessage(text: json['text'] as String),
      'session_list' => _sessionListFromJson(json),
      'recent_sessions' => RecentSessionsMessage(
        sessions: (json['sessions'] as List)
            .map((s) => RecentSession.fromJson(s as Map<String, dynamic>))
            .toList(),
        hasMore: json['hasMore'] as bool? ?? false,
        limit: json['limit'] as int?,
        offset: json['offset'] as int?,
        projectPath: json['projectPath'] as String?,
        requestScope: json['requestScope'] as String?,
        requestId: json['requestId'] as String?,
        queryGeneration: (json['queryGeneration'] as num?)?.toInt(),
        catalogRevision: (json['catalogRevision'] as num?)?.toInt(),
        provider: json['provider'] as String?,
        namedOnly: json['namedOnly'] as bool?,
        searchQuery: json['searchQuery'] as String?,
      ),
      sessionCatalogChangedMessageType => SessionCatalogChangedMessage(
        revision: (json['revision'] as num?)?.toInt() ?? 0,
        occurredAt: json['occurredAt'] as String?,
      ),
      'past_history' => PastHistoryMessage(
        claudeSessionId: json['claudeSessionId'] as String? ?? '',
        messages: (json['messages'] as List)
            .map((m) => PastMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
      ),
      'gallery_list' => GalleryListMessage(
        images: (json['images'] as List)
            .map((i) => GalleryImage.fromJson(i as Map<String, dynamic>))
            .toList(),
      ),
      'gallery_new_image' => GalleryNewImageMessage(
        image: GalleryImage.fromJson(json['image'] as Map<String, dynamic>),
      ),
      'window_list' => WindowListMessage(
        windows: (json['windows'] as List)
            .map((w) => WindowInfo.fromJson(w as Map<String, dynamic>))
            .toList(),
      ),
      'screenshot_result' => ScreenshotResultMessage(
        success: json['success'] as bool? ?? false,
        image: json['image'] != null
            ? GalleryImage.fromJson(json['image'] as Map<String, dynamic>)
            : null,
        error: json['error'] as String?,
      ),
      'debug_bundle' => DebugBundleMessage(
        sessionId: json['sessionId'] as String? ?? '',
        generatedAt: json['generatedAt'] as String? ?? '',
        session: DebugBundleSession.fromJson(
          json['session'] as Map<String, dynamic>? ?? const {},
        ),
        pastMessageCount: json['pastMessageCount'] as int? ?? 0,
        historySummary:
            (json['historySummary'] as List?)?.whereType<String>().toList() ??
            const [],
        debugTrace:
            (json['debugTrace'] as List?)
                ?.map(
                  (e) => DebugTraceEvent.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
        traceFilePath: json['traceFilePath'] as String?,
        savedBundlePath: json['savedBundlePath'] as String?,
        reproRecipe: DebugReproRecipe.fromJson(
          json['reproRecipe'] as Map<String, dynamic>? ??
              const <String, dynamic>{},
        ),
        agentPrompt: json['agentPrompt'] as String? ?? '',
        diff: json['diff'] as String? ?? '',
        diffError: json['diffError'] as String?,
      ),
      'file_content' => FileContentMessage(
        requestId: json['requestId'] as String?,
        filePath: json['filePath'] as String,
        kind: json['kind'] as String? ?? 'text',
        content: json['content'] as String? ?? '',
        language: json['language'] as String?,
        error: json['error'] as String?,
        errorCode: json['errorCode'] as String?,
        totalLines: json['totalLines'] as int?,
        truncated: json['truncated'] as bool? ?? false,
        base64: json['base64'] as String?,
        mimeType: json['mimeType'] as String?,
        sizeBytes: json['sizeBytes'] as int?,
      ),
      'file_list' => FileListMessage(
        files: (json['files'] as List).whereType<String>().toList(),
        requestId: json['requestId'] as String?,
        projectPath: json['projectPath'] as String?,
        totalFiles: json['totalFiles'] as int?,
        truncated: json['truncated'] as bool? ?? false,
        error: json['error'] as String?,
        errorCode: json['errorCode'] as String?,
      ),
      'project_history' => ProjectHistoryMessage(
        projects: (json['projects'] as List).whereType<String>().toList(),
      ),
      'diff_result' => DiffResultMessage(
        diff: json['diff'] as String? ?? '',
        error: json['error'] as String?,
        errorCode: json['errorCode'] as String?,
        imageChanges:
            (json['imageChanges'] as List?)
                ?.map(
                  (e) => DiffImageChange.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
        requestId: json['requestId'] as String?,
      ),
      'diff_image_result' => DiffImageResultMessage(
        projectPath: json['projectPath'] as String?,
        filePath: json['filePath'] as String,
        version: json['version'] as String,
        base64: json['base64'] as String?,
        mimeType: json['mimeType'] as String?,
        error: json['error'] as String?,
        oldBase64: json['oldBase64'] as String?,
        newBase64: json['newBase64'] as String?,
        requestId: json['requestId'] as String?,
      ),
      'worktree_list' => WorktreeListMessage(
        worktrees: (json['worktrees'] as List)
            .map((w) => WorktreeInfo.fromJson(w as Map<String, dynamic>))
            .toList(),
        mainBranch: json['mainBranch'] as String?,
      ),
      'worktree_removed' => WorktreeRemovedMessage(
        worktreePath: json['worktreePath'] as String,
      ),
      'tool_use_summary' => ToolUseSummaryMessage(
        summary: json['summary'] as String,
        precedingToolUseIds:
            (json['precedingToolUseIds'] as List?)
                ?.whereType<String>()
                .toList() ??
            const [],
      ),
      'user_input' => UserInputMessage(
        text: json['text'] as String? ?? '',
        clientMessageId: json['clientMessageId'] as String?,
        userMessageUuid: json['userMessageUuid'] as String?,
        isSynthetic: json['isSynthetic'] as bool? ?? false,
        isMeta: json['isMeta'] as bool? ?? false,
        imageCount: json['imageCount'] as int? ?? 0,
        timestamp: json['timestamp'] as String?,
        imageUrls:
            (json['images'] as List?)
                ?.map((e) => (e as Map<String, dynamic>)['url'] as String?)
                .whereType<String>()
                .toList() ??
            const [],
      ),
      'rewind_preview' => RewindPreviewMessage(
        canRewind: json['canRewind'] as bool? ?? false,
        filesChanged: (json['filesChanged'] as List?)
            ?.whereType<String>()
            .toList(),
        insertions: json['insertions'] as int?,
        deletions: json['deletions'] as int?,
        error: json['error'] as String?,
      ),
      'rewind_result' => RewindResultMessage(
        success: json['success'] as bool? ?? false,
        mode: json['mode'] as String? ?? 'both',
        error: json['error'] as String?,
      ),
      'input_ack' => InputAckMessage(
        sessionId: json['sessionId'] as String?,
        clientMessageId: json['clientMessageId'] as String?,
        acceptedSeq: json['acceptedSeq'] as int?,
        queued: json['queued'] as bool? ?? false,
        stage: InputAckStage.fromWireValue(json['stage']),
      ),
      inputDeliveryStatusMessageType => InputDeliveryStatusMessage.fromJson(
        json,
      ),
      'input_rejected' => InputRejectedMessage(
        sessionId: json['sessionId'] as String?,
        clientMessageId: json['clientMessageId'] as String?,
        reason: json['reason'] as String?,
      ),
      'usage_result' => UsageResultMessage(
        providers: (json['providers'] as List)
            .map((p) => UsageInfo.fromJson(p as Map<String, dynamic>))
            .toList(),
      ),
      'recording_list' => RecordingListMessage(
        recordings: (json['recordings'] as List)
            .map((r) => RecordingInfo.fromJson(r as Map<String, dynamic>))
            .toList(),
      ),
      'recording_content' => RecordingContentMessage(
        sessionId: json['sessionId'] as String? ?? '',
        content: json['content'] as String? ?? '',
      ),
      'message_images_result' => MessageImagesResultMessage(
        messageUuid: json['messageUuid'] as String? ?? '',
        images:
            (json['images'] as List?)
                ?.map((i) => ImageRef.fromJson(i as Map<String, dynamic>))
                .toList() ??
            const [],
      ),
      'prompt_history_backup_result' => PromptHistoryBackupResultMessage(
        success: json['success'] as bool? ?? false,
        backedUpAt: json['backedUpAt'] as String?,
        error: json['error'] as String?,
      ),
      'prompt_history_restore_result' => PromptHistoryRestoreResultMessage(
        success: json['success'] as bool? ?? false,
        data: json['data'] as String?,
        appVersion: json['appVersion'] as String?,
        dbVersion: json['dbVersion'] as int?,
        backedUpAt: json['backedUpAt'] as String?,
        error: json['error'] as String?,
      ),
      'prompt_history_backup_info' => PromptHistoryBackupInfoMessage(
        exists: json['exists'] as bool? ?? false,
        appVersion: json['appVersion'] as String?,
        dbVersion: json['dbVersion'] as int?,
        backedUpAt: json['backedUpAt'] as String?,
        sizeBytes: json['sizeBytes'] as int?,
      ),
      'prompt_history_sync_result' => PromptHistorySyncResultMessage(
        success: json['success'] as bool? ?? false,
        requestId: json['requestId'] as String?,
        bridgeInstanceId: json['bridgeInstanceId'] as String?,
        revision: json['revision'] as int?,
        syncedAt: json['syncedAt'] as String?,
        fullSnapshot: json['fullSnapshot'] as bool? ?? false,
        entries:
            (json['entries'] as List?)
                ?.map(
                  (e) => PromptHistoryServerEntry.fromJson(
                    e as Map<String, dynamic>,
                  ),
                )
                .toList() ??
            const [],
        error: json['error'] as String?,
      ),
      'prompt_history_mutation_result' => PromptHistoryMutationResultMessage(
        success: json['success'] as bool? ?? false,
        bridgeInstanceId: json['bridgeInstanceId'] as String?,
        revision: json['revision'] as int?,
        entry: json['entry'] is Map<String, dynamic>
            ? PromptHistoryServerEntry.fromJson(
                json['entry'] as Map<String, dynamic>,
              )
            : null,
        error: json['error'] as String?,
      ),
      'prompt_history_status' => PromptHistoryStatusMessage(
        bridgeInstanceId: json['bridgeInstanceId'] as String? ?? '',
        revision: json['revision'] as int? ?? 0,
        entryCount: json['entryCount'] as int? ?? 0,
        updatedAt: json['updatedAt'] as String?,
      ),
      'rename_result' => RenameResultMessage(
        sessionId: json['sessionId'] as String? ?? '',
        name: json['name'] as String?,
        success: json['success'] as bool? ?? false,
        error: json['error'] as String?,
      ),
      'archive_result' => ArchiveResultMessage(
        requestId: json['requestId'] as String?,
        sessionId: json['sessionId'] as String? ?? '',
        provider: json['provider'] as String?,
        success: json['success'] as bool? ?? false,
        error: json['error'] as String?,
        errorCode: json['errorCode'] as String?,
      ),
      'archived_sessions_result' => ArchivedSessionsResultMessage(
        requestId: json['requestId'] as String? ?? '',
        success: json['success'] as bool? ?? false,
        sessions:
            (json['sessions'] as List?)
                ?.whereType<Map>()
                .map(
                  (session) => ArchivedSessionRecord.fromJson(
                    Map<String, dynamic>.from(session),
                  ),
                )
                .toList() ??
            const [],
        truncated: json['truncated'] as bool? ?? false,
        error: json['error'] as String?,
        errorCode: json['errorCode'] as String?,
      ),
      'unarchive_result' => SessionLifecycleResultMessage(
        type: 'unarchive_result',
        requestId: json['requestId'] as String? ?? '',
        sessionId: json['sessionId'] as String? ?? '',
        success: json['success'] as bool? ?? false,
        error: json['error'] as String?,
        errorCode: json['errorCode'] as String?,
      ),
      'delete_session_result' => SessionLifecycleResultMessage(
        type: 'delete_session_result',
        requestId: json['requestId'] as String? ?? '',
        sessionId: json['sessionId'] as String? ?? '',
        success: json['success'] as bool? ?? false,
        error: json['error'] as String?,
        errorCode: json['errorCode'] as String?,
      ),
      'branch_update' => BranchUpdateMessage(
        sessionId: json['sessionId'] as String? ?? '',
        branch: json['branch'] as String? ?? '',
      ),
      // ---- Git Operations (Phase 1-3) ----
      'git_stage_result' => GitStageResultMessage(
        success: json['success'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        error: json['error'] as String?,
      ),
      'git_unstage_result' => GitUnstageResultMessage(
        success: json['success'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        error: json['error'] as String?,
      ),
      'git_unstage_hunks_result' => GitUnstageHunksResultMessage(
        success: json['success'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        error: json['error'] as String?,
      ),
      'git_commit_result' => GitCommitResultMessage(
        success: json['success'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        commitHash: json['commitHash'] as String?,
        message: json['message'] as String?,
        error: json['error'] as String?,
      ),
      'git_push_result' => GitPushResultMessage(
        success: json['success'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        error: json['error'] as String?,
      ),
      'git_branches_result' => GitBranchesResultMessage(
        current: json['current'] as String? ?? '',
        projectPath: _nonEmptyString(json['projectPath']),
        branches:
            (json['branches'] as List?)?.whereType<String>().toList() ??
            const [],
        checkedOutBranches:
            (json['checkedOutBranches'] as List?)
                ?.whereType<String>()
                .toList() ??
            const [],
        remoteStatusByBranch:
            (json['remoteStatusByBranch'] as Map?)?.map(
              (key, value) => MapEntry(
                key as String,
                GitBranchRemoteStatus.fromJson(
                  Map<String, dynamic>.from(value as Map),
                ),
              ),
            ) ??
            const {},
        error: json['error'] as String?,
      ),
      'git_create_branch_result' => GitCreateBranchResultMessage(
        success: json['success'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        error: json['error'] as String?,
      ),
      'git_checkout_branch_result' => GitCheckoutBranchResultMessage(
        success: json['success'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        error: json['error'] as String?,
      ),
      'git_revert_file_result' => GitRevertFileResultMessage(
        success: json['success'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        error: json['error'] as String?,
      ),
      'git_revert_hunks_result' => GitRevertHunksResultMessage(
        success: json['success'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        error: json['error'] as String?,
      ),
      'git_fetch_result' => GitFetchResultMessage(
        success: json['success'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        error: json['error'] as String?,
      ),
      'git_pull_result' => GitPullResultMessage(
        success: json['success'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        message: json['message'] as String?,
        error: json['error'] as String?,
      ),
      'git_status_result' => GitStatusResultMessage(
        sessionId: json['sessionId'] as String?,
        projectPath: json['projectPath'] as String? ?? '',
        hasUncommittedChanges: json['hasUncommittedChanges'] as bool? ?? false,
        stagedCount: json['stagedCount'] as int? ?? 0,
        unstagedCount: json['unstagedCount'] as int? ?? 0,
        untrackedCount: json['untrackedCount'] as int? ?? 0,
        remoteStatusIncluded: json['remoteStatusIncluded'] as bool? ?? false,
        hasRemoteChanges: json['hasRemoteChanges'] as bool? ?? false,
        commitsAhead: json['commitsAhead'] as int? ?? 0,
        commitsBehind: json['commitsBehind'] as int? ?? 0,
        hasUpstream: json['hasUpstream'] as bool? ?? false,
        branch: json['branch'] as String?,
        remoteError: json['remoteError'] as String?,
        error: json['error'] as String?,
      ),
      'git_remote_status_result' => GitRemoteStatusResultMessage(
        ahead: json['ahead'] as int? ?? 0,
        behind: json['behind'] as int? ?? 0,
        branch: json['branch'] as String? ?? '',
        hasUpstream: json['hasUpstream'] as bool? ?? false,
        projectPath: _nonEmptyString(json['projectPath']),
        error: json['error'] as String?,
        errorCode: json['errorCode'] as String?,
      ),
      _ => ErrorMessage(message: 'Unknown message type: ${json['type']}'),
    };
    _attachServerMessageTimestamp(message, json);
    return message;
  }
}

/// Metadata for a Codex skill, returned by the `skills/list` RPC.
class CodexSkillMetadata {
  final String name;
  final String path;
  final String description;
  final String? shortDescription;
  final bool enabled;
  final String scope;
  final String? displayName;
  final String? defaultPrompt;
  final String? brandColor;

  const CodexSkillMetadata({
    required this.name,
    required this.path,
    required this.description,
    this.shortDescription,
    this.enabled = true,
    this.scope = 'user',
    this.displayName,
    this.defaultPrompt,
    this.brandColor,
  });

  factory CodexSkillMetadata.fromJson(Map<String, dynamic> json) {
    return CodexSkillMetadata(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      description: json['description'] as String? ?? '',
      shortDescription: json['shortDescription'] as String?,
      enabled: json['enabled'] as bool? ?? true,
      scope: json['scope'] as String? ?? 'user',
      displayName: json['displayName'] as String?,
      defaultPrompt: json['defaultPrompt'] as String?,
      brandColor: json['brandColor'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {'name': name, 'path': path};

  /// Best human-readable label for UI display.
  String get label => displayName ?? name;

  /// Best short description for UI display.
  String get summary => shortDescription ?? description;
}

/// Metadata for a Codex app / connector, returned by the `app/list` RPC.
class CodexAppMetadata {
  final String id;
  final String name;
  final String description;
  final String? installUrl;
  final bool isAccessible;
  final bool isEnabled;

  const CodexAppMetadata({
    required this.id,
    required this.name,
    required this.description,
    this.installUrl,
    this.isAccessible = true,
    this.isEnabled = true,
  });

  factory CodexAppMetadata.fromJson(Map<String, dynamic> json) {
    return CodexAppMetadata(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      installUrl: json['installUrl'] as String?,
      isAccessible: json['isAccessible'] as bool? ?? true,
      isEnabled: json['isEnabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'path': 'app://$id',
  };

  String get label => name.isNotEmpty ? name : id;
}

/// Metadata for a Codex plugin, returned by the `plugin/list` RPC.
class CodexPluginMetadata {
  final String id;
  final String name;
  final String path;
  final String marketplaceName;
  final String? marketplacePath;
  final bool installed;
  final bool enabled;
  final String? displayName;
  final String? shortDescription;
  final String? longDescription;
  final String? defaultPrompt;
  final String? brandColor;
  final String? composerIcon;
  final String? composerIconUrl;

  const CodexPluginMetadata({
    required this.id,
    required this.name,
    required this.path,
    required this.marketplaceName,
    this.marketplacePath,
    this.installed = true,
    this.enabled = true,
    this.displayName,
    this.shortDescription,
    this.longDescription,
    this.defaultPrompt,
    this.brandColor,
    this.composerIcon,
    this.composerIconUrl,
  });

  factory CodexPluginMetadata.fromJson(Map<String, dynamic> json) {
    final id = _nonEmptyString(json['id']) ?? '';
    return CodexPluginMetadata(
      id: id,
      name: _nonEmptyString(json['name']) ?? '',
      path: _nonEmptyString(json['path']) ?? 'plugin://$id',
      marketplaceName: _nonEmptyString(json['marketplaceName']) ?? '',
      marketplacePath: _nonEmptyString(json['marketplacePath']),
      installed: json['installed'] as bool? ?? true,
      enabled: json['enabled'] as bool? ?? true,
      displayName: _nonEmptyString(json['displayName']),
      shortDescription: _nonEmptyString(json['shortDescription']),
      longDescription: _nonEmptyString(json['longDescription']),
      defaultPrompt: _firstString(json['defaultPrompt']),
      brandColor: _nonEmptyString(json['brandColor']),
      composerIcon: _nonEmptyString(json['composerIcon']),
      composerIconUrl: _nonEmptyString(json['composerIconUrl']),
    );
  }

  Map<String, dynamic> toJson() => {'name': label, 'path': path};

  String get label => displayName ?? name;

  String get summary =>
      shortDescription ?? longDescription ?? (name.isNotEmpty ? name : id);
}

String? _firstString(dynamic value) {
  final text = _nonEmptyString(value);
  if (text != null) return text;
  if (value is! List) return null;
  for (final entry in value) {
    final text = _nonEmptyString(entry);
    if (text != null) return text;
  }
  return null;
}

enum BridgeClientDeliveryMode {
  interactive('interactive'),
  notificationsOnly('notifications_only');

  const BridgeClientDeliveryMode(this.wireValue);

  final String wireValue;

  static BridgeClientDeliveryMode fromWire(String? value) {
    return value == notificationsOnly.wireValue
        ? notificationsOnly
        : interactive;
  }
}

class ClientDeliveryModeStateMessage implements ServerMessage {
  const ClientDeliveryModeStateMessage({
    required this.mode,
    required this.requestId,
    required this.activeWorkCount,
  });

  final BridgeClientDeliveryMode mode;
  final String requestId;
  final int activeWorkCount;
}

class BackgroundNotificationMessage implements ServerMessage {
  const BackgroundNotificationMessage({
    this.deliveryId = '',
    required this.eventType,
    required this.sessionId,
    required this.provider,
    required this.title,
    required this.body,
    required this.occurredAt,
    required this.data,
  });

  final String deliveryId;
  final String eventType;
  final String sessionId;
  final String provider;
  final String title;
  final String body;
  final DateTime? occurredAt;
  final Map<String, String> data;
}

class BackgroundActivityStateMessage implements ServerMessage {
  const BackgroundActivityStateMessage({
    required this.activeWorkCount,
    required this.occurredAt,
  });

  final int activeWorkCount;
  final DateTime? occurredAt;

  bool get hasActiveWork => activeWorkCount > 0;
}

class PushRegistrationStateMessage implements ServerMessage {
  const PushRegistrationStateMessage({
    required this.operation,
    required this.requestId,
    required this.success,
    this.errorCode,
  });

  final String operation;
  final String requestId;
  final bool success;
  final String? errorCode;
}

class SystemMessage implements ServerMessage {
  final String subtype;
  final String? sessionId;

  /// The full Claude CLI session UUID (for JSONL lookups).
  /// Falls back to [sessionId] when not provided.
  final String? claudeSessionId;
  final String? model;
  final String? approvalPolicy;
  final String? approvalsReviewer;
  final String? codexPermissionsMode;
  final String? provider;
  final String? projectPath;
  final String? permissionMode;
  final String? executionMode;
  final bool? planMode;
  final String? sandboxMode;
  final String? modelReasoningEffort;
  final String? serviceTier;
  final bool? networkAccessEnabled;
  final String? webSearchMode;
  final List<String> slashCommands;
  final List<String> skills;
  final List<CodexSkillMetadata> skillMetadata;
  final List<String> apps;
  final List<CodexAppMetadata> appMetadata;
  final List<String> plugins;
  final List<CodexPluginMetadata> pluginMetadata;
  final String? worktreePath;
  final String? worktreeBranch;
  final bool clearContext;
  final String? sourceSessionId;
  final String? forkedFromSessionId;
  final String? forkedFromThreadId;
  final String? startRequestId;
  final String? resumeRequestId;
  final int? sessionLinkGeneration;
  final String? errorMessage;
  final String? tipCode;
  final String? permissionChangeId;
  final CodexCliJoinTarget? codexCliJoin;
  const SystemMessage({
    required this.subtype,
    this.sessionId,
    this.claudeSessionId,
    this.model,
    this.approvalPolicy,
    this.approvalsReviewer,
    this.codexPermissionsMode,
    this.provider,
    this.projectPath,
    this.permissionMode,
    this.executionMode,
    this.planMode,
    this.sandboxMode,
    this.modelReasoningEffort,
    this.serviceTier,
    this.networkAccessEnabled,
    this.webSearchMode,
    this.slashCommands = const [],
    this.skills = const [],
    this.skillMetadata = const [],
    this.apps = const [],
    this.appMetadata = const [],
    this.plugins = const [],
    this.pluginMetadata = const [],
    this.worktreePath,
    this.worktreeBranch,
    this.clearContext = false,
    this.sourceSessionId,
    this.forkedFromSessionId,
    this.forkedFromThreadId,
    this.startRequestId,
    this.resumeRequestId,
    this.sessionLinkGeneration,
    this.errorMessage,
    this.tipCode,
    this.permissionChangeId,
    this.codexCliJoin,
  });
}

class CodexCliJoinTarget {
  final String url;
  final String command;

  const CodexCliJoinTarget({required this.url, required this.command});

  factory CodexCliJoinTarget.fromJson(Map<String, dynamic> json) {
    return CodexCliJoinTarget(
      url: json['url'] as String? ?? '',
      command: json['command'] as String? ?? '',
    );
  }

  bool get isValid => url.trim().isNotEmpty && command.trim().isNotEmpty;
}

class AssistantServerMessage implements ServerMessage {
  final AssistantMessage message;
  final String? messageUuid;
  final List<ArtifactRef> artifacts;
  final List<HistoryToolDetailGap> historyToolDetailGaps;

  /// Number of UI-only content blocks prepended after the Bridge assigned
  /// [ArtifactRef.textContentIndex]. Never serialized on the wire.
  final int artifactContentIndexOffset;
  const AssistantServerMessage({
    required this.message,
    this.messageUuid,
    this.artifacts = const [],
    this.historyToolDetailGaps = const [],
    this.artifactContentIndexOffset = 0,
  });

  String get artifactMessageId =>
      message.id.isNotEmpty ? message.id : messageUuid?.trim() ?? '';
}

class HistoryToolDetailGap {
  static const maxToolUseIds = 200;

  final String gapId;
  final List<String> toolUseIds;
  final List<String> toolNames;
  final int toolCallCount;
  final String? turnId;

  const HistoryToolDetailGap({
    required this.gapId,
    required this.toolUseIds,
    required this.toolNames,
    required this.toolCallCount,
    this.turnId,
  });

  bool get isValid => gapId.isNotEmpty && toolUseIds.isNotEmpty;

  factory HistoryToolDetailGap.fromJson(Map<String, dynamic> json) {
    final rawNames = json['toolNames'] is List
        ? json['toolNames'] as List
        : const [];
    final rawIds = json['toolUseIds'] is List
        ? json['toolUseIds'] as List
        : const [];
    final seen = <String>{};
    final toolUseIds = <String>[];
    final toolNames = <String>[];
    for (var rawIndex = 0; rawIndex < rawIds.length; rawIndex++) {
      final rawId = rawIds[rawIndex];
      if (rawId is! String) continue;
      final id = rawId.trim();
      final rawName = rawIndex < rawNames.length && rawNames[rawIndex] is String
          ? (rawNames[rawIndex] as String).trim()
          : '';
      if (id.isEmpty || id.length > 256 || !seen.add(id)) continue;
      toolUseIds.add(id);
      toolNames.add(rawName.isEmpty || rawName.length > 256 ? 'Tool' : rawName);
      if (toolUseIds.length >= maxToolUseIds) break;
    }
    final rawGapId = (json['gapId'] as String? ?? '').trim();
    final rawTurnId = (json['turnId'] as String? ?? '').trim();
    return HistoryToolDetailGap(
      gapId: rawGapId.length <= 128 ? rawGapId : '',
      toolUseIds: List.unmodifiable(toolUseIds),
      toolNames: List.unmodifiable(toolNames),
      // Count only validated IDs. The client must never allocate or display
      // work based on an untrusted wire count.
      toolCallCount: toolUseIds.length,
      turnId: rawTurnId.isNotEmpty && rawTurnId.length <= 256
          ? rawTurnId
          : null,
    );
  }
}

class ToolResultMessage implements ServerMessage {
  final String toolUseId;
  final String content;
  final String? toolName;
  final List<ImageRef> images;
  final String? userMessageUuid;
  final List<ArtifactRef> artifacts;
  const ToolResultMessage({
    required this.toolUseId,
    required this.content,
    this.toolName,
    this.images = const [],
    this.userMessageUuid,
    this.artifacts = const [],
  });
}

class ArtifactResolvedMessage implements ServerMessage {
  final String requestId;
  final String artifactId;
  final String? relativeUrl;
  final String? expiresAt;
  final String? error;
  final String? errorCode;

  const ArtifactResolvedMessage({
    required this.requestId,
    required this.artifactId,
    this.relativeUrl,
    this.expiresAt,
    this.error,
    this.errorCode,
  });

  bool get isSuccess =>
      error == null && relativeUrl != null && relativeUrl!.isNotEmpty;
}

class ResultMessage implements ServerMessage {
  final String subtype;
  final String? result;
  final String? error;
  final double? cost;
  final double? duration;
  final String? sessionId;
  final String? stopReason;
  final int? inputTokens;
  final int? cachedInputTokens;
  final int? outputTokens;
  final int? toolCalls;
  final int? fileEdits;
  const ResultMessage({
    required this.subtype,
    this.result,
    this.error,
    this.cost,
    this.duration,
    this.sessionId,
    this.stopReason,
    this.inputTokens,
    this.cachedInputTokens,
    this.outputTokens,
    this.toolCalls,
    this.fileEdits,
  });
}

class ErrorMessage implements ServerMessage {
  final String message;
  final String? errorCode;
  final String? sessionId;
  final String? permissionChangeId;
  final String? goalChangeId;

  const ErrorMessage({
    required this.message,
    this.errorCode,
    this.sessionId,
    this.permissionChangeId,
    this.goalChangeId,
  });
}

enum SessionLinkResolutionStatus {
  live,
  recent,
  unavailable;

  static SessionLinkResolutionStatus fromString(String? value) {
    return switch (value) {
      'live' => live,
      'recent' => recent,
      _ => unavailable,
    };
  }
}

enum SessionLinkProgressOperation {
  resolve('resolve'),
  resume('resume'),
  unknown('__unknown__');

  final String wireValue;
  const SessionLinkProgressOperation(this.wireValue);

  static SessionLinkProgressOperation fromWire(Object? value) {
    return values.firstWhere(
      (operation) => operation.wireValue == value,
      orElse: () => unknown,
    );
  }
}

enum SessionLinkProgressStage {
  waitingForConnection('waiting_for_connection', 0),
  waitingForIdentity('waiting_for_identity', 1),
  requestSent('request_sent', 2),
  requestAccepted('request_accepted', 3),
  runtimeChecked('runtime_checked', 4),
  catalogScanning('catalog_scanning', 5),
  catalogScanned('catalog_scanned', 6),
  resolutionReady('resolution_ready', 7),
  resumeLockWaiting('resume_lock_waiting', 8),
  resumeLockAcquired('resume_lock_acquired', 9),
  historyReading('history_reading', 10),
  historyRead('history_read', 11),
  runtimeStarting('runtime_starting', 12),
  metadataLoading('metadata_loading', 13),
  ready('ready', 14),
  unknown('__unknown__', -1);

  final String wireValue;
  final int rank;
  const SessionLinkProgressStage(this.wireValue, this.rank);

  static SessionLinkProgressStage fromWire(Object? value) {
    return values.firstWhere(
      (stage) => stage.wireValue == value,
      orElse: () => unknown,
    );
  }
}

class SessionLinkProgressMessage implements ServerMessage {
  final String requestId;
  final String sourceSessionId;
  final int generation;
  final SessionLinkProgressOperation operation;
  final SessionLinkProgressStage stage;
  final int sequence;
  final String observedAt;
  final int? completedUnits;
  final int? totalUnits;

  const SessionLinkProgressMessage({
    required this.requestId,
    required this.sourceSessionId,
    required this.generation,
    required this.operation,
    required this.stage,
    required this.sequence,
    required this.observedAt,
    this.completedUnits,
    this.totalUnits,
  });

  factory SessionLinkProgressMessage.fromJson(Map<String, dynamic> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Session link progress $key is invalid.');
      }
      return value;
    }

    int requiredInt(String key, {required int minimum}) {
      final value = json[key];
      if (value is! num || value.toInt() != value || value < minimum) {
        throw FormatException('Session link progress $key is invalid.');
      }
      return value.toInt();
    }

    int? optionalInt(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! num || value.toInt() != value || value < 0) {
        throw FormatException('Session link progress $key is invalid.');
      }
      return value.toInt();
    }

    return SessionLinkProgressMessage(
      requestId: requiredString('requestId'),
      sourceSessionId: requiredString('sourceSessionId'),
      generation: requiredInt('generation', minimum: 1),
      operation: SessionLinkProgressOperation.fromWire(json['operation']),
      stage: SessionLinkProgressStage.fromWire(json['stage']),
      sequence: requiredInt('sequence', minimum: 1),
      observedAt: requiredString('observedAt'),
      completedUnits: optionalInt('completedUnits'),
      totalUnits: optionalInt('totalUnits'),
    );
  }

  bool isEffectiveAfter(SessionLinkProgressMessage? previous) {
    if (operation == SessionLinkProgressOperation.unknown ||
        stage == SessionLinkProgressStage.unknown) {
      return false;
    }
    if (previous == null) return true;
    if (requestId != previous.requestId ||
        sourceSessionId != previous.sourceSessionId ||
        generation != previous.generation ||
        operation != previous.operation ||
        sequence <= previous.sequence) {
      return false;
    }
    if (stage.rank > previous.stage.rank) return true;
    if (stage != previous.stage) return false;
    final completed = completedUnits;
    return completed != null && completed > (previous.completedUnits ?? 0);
  }
}

class SessionLinkResolutionMessage implements ServerMessage {
  final String requestId;
  final String sourceSessionId;
  final SessionLinkResolutionStatus status;
  final String? bridgeSessionId;
  final String? provider;
  final int? generation;
  final RecentSession? recentSession;

  const SessionLinkResolutionMessage({
    required this.requestId,
    required this.sourceSessionId,
    required this.status,
    this.bridgeSessionId,
    this.provider,
    this.generation,
    this.recentSession,
  });
}

enum GuardianApprovalRisk {
  unknown,
  low,
  medium,
  high,
  critical;

  static GuardianApprovalRisk fromString(String? value) => switch (value) {
    'low' => GuardianApprovalRisk.low,
    'medium' => GuardianApprovalRisk.medium,
    'high' => GuardianApprovalRisk.high,
    'critical' => GuardianApprovalRisk.critical,
    _ => GuardianApprovalRisk.unknown,
  };
}

enum GuardianApprovalStatus {
  approved,
  denied,
  timedOut,
  aborted;

  static GuardianApprovalStatus fromString(String? value) => switch (value) {
    'approved' => GuardianApprovalStatus.approved,
    'denied' => GuardianApprovalStatus.denied,
    'timedOut' => GuardianApprovalStatus.timedOut,
    'aborted' => GuardianApprovalStatus.aborted,
    // Old Bridges omit the status field and emit guardian_approval only for
    // approved reviews, so a missing status still means approved.
    null => GuardianApprovalStatus.approved,
    // Fail closed on unrecognized literals: a future status value must not
    // render as an approval the user would trust.
    _ => GuardianApprovalStatus.denied,
  };
}

class GuardianApprovalMessage implements ServerMessage {
  final GuardianApprovalRisk risk;
  final GuardianApprovalStatus status;
  final String reason;
  final String? authorization;
  final String? reviewId;
  final String? targetItemId;
  final Map<String, dynamic>? action;
  const GuardianApprovalMessage({
    required this.risk,
    this.status = GuardianApprovalStatus.approved,
    required this.reason,
    this.authorization,
    this.reviewId,
    this.targetItemId,
    this.action,
  });

  factory GuardianApprovalMessage.fromJson(Map<String, dynamic> json) {
    final rawAction = json['action'];
    return GuardianApprovalMessage(
      risk: GuardianApprovalRisk.fromString(json['risk'] as String?),
      status: GuardianApprovalStatus.fromString(json['status'] as String?),
      reason: json['reason'] as String? ?? '',
      authorization: json['authorization'] as String?,
      reviewId: json['reviewId'] as String?,
      targetItemId: json['targetItemId'] as String?,
      action: rawAction is Map ? Map<String, dynamic>.from(rawAction) : null,
    );
  }
}

GuardianApprovalMessage? _guardianReviewFromErrorJson(
  Map<String, dynamic> json,
) {
  final rawReview = json['guardianReview'];
  if (rawReview is Map) {
    return GuardianApprovalMessage.fromJson(
      Map<String, dynamic>.from(rawReview),
    );
  }
  if (json['errorCode'] != 'codex_warning') return null;
  final rawMessage = json['message'];
  if (rawMessage is! String) return null;
  return _guardianReviewFromLegacyWarning(rawMessage);
}

GuardianApprovalMessage? _guardianReviewFromLegacyWarning(String message) {
  final normalized = message.trim();
  final match = RegExp(
    r'^automatic approval review (approved|denied)\s*\(([^)]*)\)\s*:\s*([\s\S]+)$',
    caseSensitive: false,
  ).firstMatch(normalized);
  if (match == null) {
    if (RegExp(
      r'^automatic approval review timed out while evaluating the requested approval\.?$',
      caseSensitive: false,
    ).hasMatch(normalized)) {
      return GuardianApprovalMessage(
        risk: GuardianApprovalRisk.unknown,
        status: GuardianApprovalStatus.timedOut,
        reason: normalized,
      );
    }
    return null;
  }

  final metadata = <String, String>{};
  for (final field in match.group(2)!.split(',')) {
    final separator = field.indexOf(':');
    if (separator == -1) continue;
    metadata[field.substring(0, separator).trim().toLowerCase()] = field
        .substring(separator + 1)
        .trim();
  }
  final risk = GuardianApprovalRisk.fromString(metadata['risk']?.toLowerCase());
  final reason = match.group(3)!.trim();
  if (risk == GuardianApprovalRisk.unknown || reason.isEmpty) return null;
  return GuardianApprovalMessage(
    risk: risk,
    status: match.group(1)!.toLowerCase() == 'denied'
        ? GuardianApprovalStatus.denied
        : GuardianApprovalStatus.approved,
    reason: reason,
    authorization: metadata['authorization'],
  );
}

class StatusMessage implements ServerMessage {
  final ProcessStatus status;
  final String? rawStatus;
  final String? activityAt;

  const StatusMessage({required this.status, this.rawStatus, this.activityAt});

  String get effectiveStatus => rawStatus ?? status.wireValue;
  bool get hasUnknownStatus => status == ProcessStatus.unknown;
}

class HistoryMessage implements ServerMessage {
  final List<ServerMessage> messages;
  final HistoryWindowInfo? historyWindow;
  const HistoryMessage({required this.messages, this.historyWindow});
}

class HistoryWindowInfo {
  final String capability;
  final int fromSeq;
  final bool hasMore;
  final String? cursor;

  const HistoryWindowInfo({
    required this.capability,
    required this.fromSeq,
    required this.hasMore,
    this.cursor,
  });

  factory HistoryWindowInfo.fromJson(Map<String, dynamic> json) =>
      HistoryWindowInfo(
        capability: json['capability'] as String? ?? '',
        fromSeq: _intFromJson(json['fromSeq']) ?? 0,
        hasMore: json['hasMore'] as bool? ?? false,
        cursor: json['cursor'] as String?,
      );
}

class HistoryEntry {
  final int seq;
  final ServerMessage message;
  const HistoryEntry({required this.seq, required this.message});

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      seq: _intFromJson(json['seq']) ?? 0,
      message: ServerMessage.fromJson(
        Map<String, dynamic>.from(json['message'] as Map),
      ),
    );
  }
}

class HistoryDeltaMessage implements ServerMessage {
  final String? sessionId;
  final int fromSeq;
  final int toSeq;
  final List<HistoryEntry> entries;
  final ProcessStatus? status;
  final String? rawStatus;

  const HistoryDeltaMessage({
    this.sessionId,
    required this.fromSeq,
    required this.toSeq,
    required this.entries,
    this.status,
    this.rawStatus,
  });
}

class HistoryPageMessage implements ServerMessage {
  final String requestId;
  final String sessionId;
  final int beforeSeq;
  final int nextBeforeSeq;
  final String? nextBeforeCursor;
  final bool hasMore;
  final List<HistoryEntry> entries;
  final String? error;

  const HistoryPageMessage({
    required this.requestId,
    required this.sessionId,
    required this.beforeSeq,
    required this.nextBeforeSeq,
    this.nextBeforeCursor,
    required this.hasMore,
    required this.entries,
    this.error,
  });
}

class HistoryToolDetail {
  final String toolUseId;
  final String toolName;
  final Map<String, dynamic> input;
  final ToolResultMessage? result;

  const HistoryToolDetail({
    required this.toolUseId,
    required this.toolName,
    required this.input,
    this.result,
  });

  bool get isValid => toolUseId.isNotEmpty;

  factory HistoryToolDetail.fromJson(Map<String, dynamic> json) {
    final rawToolUseId = (json['toolUseId'] as String? ?? '').trim();
    final toolUseId = rawToolUseId.length <= 256 ? rawToolUseId : '';
    final rawToolName = (json['toolName'] as String? ?? 'Tool').trim();
    final rawResult = json['result'];
    final rawImages = rawResult is Map ? rawResult['images'] : null;
    final rawArtifacts = rawResult is Map ? rawResult['artifacts'] : null;
    return HistoryToolDetail(
      toolUseId: toolUseId,
      toolName: rawToolName.isEmpty || rawToolName.length > 256
          ? 'Tool'
          : rawToolName,
      input: Map<String, dynamic>.from(json['input'] as Map? ?? const {}),
      result: rawResult is Map
          ? ToolResultMessage(
              toolUseId: toolUseId,
              content: _normalizeToolResultContent(rawResult['content']),
              toolName: rawResult['toolName'] as String?,
              images:
                  (rawImages is List
                          ? rawImages.whereType<Map>().take(32)
                          : const <Map>[])
                      .map(
                        (value) =>
                            ImageRef.fromJson(Map<String, dynamic>.from(value)),
                      )
                      .toList(growable: false),
              artifacts: rawArtifacts is List
                  ? _parseArtifactRefs(rawArtifacts.take(32).toList())
                  : const [],
            )
          : null,
    );
  }
}

class HistoryToolDetailsMessage implements ServerMessage {
  final String requestId;
  final String sessionId;
  final List<HistoryToolDetail> details;
  final String? error;

  const HistoryToolDetailsMessage({
    required this.requestId,
    required this.sessionId,
    required this.details,
    this.error,
  });
}

class HistorySnapshotMessage implements ServerMessage {
  final String? sessionId;
  final int fromSeq;
  final int toSeq;
  final List<HistoryEntry> entries;
  final ProcessStatus? status;
  final String? rawStatus;
  final String reason;
  final HistoryWindowInfo? historyWindow;

  const HistorySnapshotMessage({
    this.sessionId,
    required this.fromSeq,
    required this.toSeq,
    required this.entries,
    this.status,
    this.rawStatus,
    required this.reason,
    this.historyWindow,
  });
}

class ToolSuggestionApp {
  final String id;
  final String name;
  final String? description;
  final String? installUrl;
  final String? category;

  const ToolSuggestionApp({
    required this.id,
    required this.name,
    this.description,
    this.installUrl,
    this.category,
  });

  factory ToolSuggestionApp.fromJson(Map<String, dynamic> json) {
    return ToolSuggestionApp(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      installUrl: json['installUrl'] as String?,
      category: json['category'] as String?,
    );
  }
}

class PermissionRequestMessage implements ServerMessage {
  final String toolUseId;
  final String toolName;
  final Map<String, dynamic> input;
  const PermissionRequestMessage({
    required this.toolUseId,
    required this.toolName,
    required this.input,
  });

  bool get isRequestUserInputApproval =>
      toolName == 'AskUserQuestion' && isMcpApprovalRequestUserInput(input);

  bool get isMcpElicitation => toolName == 'McpElicitation';

  bool get isToolSuggestion => toolName == 'ToolSuggestion';

  String get suggestedToolName =>
      _nonEmptyString(input['toolName']) ?? displayToolName;

  String get toolSuggestionReason =>
      _nonEmptyString(input['suggestReason']) ??
      _nonEmptyString(input['message']) ??
      suggestedToolName;

  String get toolSuggestionInstallState =>
      _nonEmptyString(input['installState']) ?? 'idle';

  String? get toolSuggestionInstallError =>
      _nonEmptyString(input['installError']);

  String? get toolSuggestionInstallUrl => _nonEmptyString(input['installUrl']);

  String? get toolSuggestionType => _nonEmptyString(input['toolType']);

  List<ToolSuggestionApp> get appsNeedingAuthentication {
    final raw = input['appsNeedingAuth'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((app) => ToolSuggestionApp.fromJson(app.cast<String, dynamic>()))
        .where((app) => app.id.isNotEmpty && app.name.isNotEmpty)
        .toList(growable: false);
  }

  bool get hasQuestions => hasRequestUserInputQuestions(input);

  bool get isQuestionPrompt =>
      (toolName == 'AskUserQuestion' || isMcpElicitation) && hasQuestions;

  bool get isQuestionApproval =>
      isQuestionPrompt && isMcpApprovalRequestUserInput(input);

  bool get usesAskUserUi =>
      isQuestionPrompt && !(isMcpElicitation && isQuestionApproval);

  bool get isPermissionGrantRequest => toolName == 'Permissions';

  bool get isMalformedAskUserQuestion =>
      toolName == 'AskUserQuestion' && !hasQuestions;

  List<String> get availableDecisions =>
      _stringList(input['availableDecisions']);

  bool get canApprove =>
      !isMalformedAskUserQuestion &&
      (availableDecisions.isEmpty || availableDecisions.contains('accept'));

  bool get canApproveForSession =>
      !isMalformedAskUserQuestion &&
      (availableDecisions.isEmpty ||
          availableDecisions.contains('acceptForSession'));

  bool get canDecline =>
      isMalformedAskUserQuestion ||
      availableDecisions.isEmpty ||
      availableDecisions.contains('decline') ||
      availableDecisions.contains('cancel');

  bool get showsCancelAction =>
      availableDecisions.contains('cancel') &&
      !availableDecisions.contains('decline');

  PermissionPresentation get presentation => PermissionPresentation.from(this);

  String get displayToolName {
    if (isToolSuggestion) {
      return _nonEmptyString(input['toolName']) ?? 'Plugin suggestion';
    }
    if (isQuestionApproval) {
      return requestUserInputHeader(input) ?? 'App Tool Approval';
    }
    if (isMcpElicitation) {
      final serverName = _nonEmptyString(input['serverName']);
      return serverName == null ? 'MCP Elicitation' : 'MCP: $serverName';
    }
    if (isPermissionGrantRequest) {
      return 'Additional Permissions';
    }
    return toolName;
  }

  /// Human-readable summary of the permission request input.
  String get summary => presentation.summary;

  List<String> get detailLines => presentation.secondaryDetails;
}

class PermissionPresentation {
  final String title;
  final String summary;
  final String? riskBadge;
  final String? scopeLabel;
  final String? primaryTargetLabel;
  final String? primaryTarget;
  final List<String> secondaryDetails;
  final String rawDetails;

  const PermissionPresentation({
    required this.title,
    required this.summary,
    required this.rawDetails,
    this.riskBadge,
    this.scopeLabel,
    this.primaryTargetLabel,
    this.primaryTarget,
    this.secondaryDetails = const [],
  });

  factory PermissionPresentation.from(PermissionRequestMessage message) {
    final input = message.input;
    final rawDetails = const JsonEncoder.withIndent('  ').convert(input);

    if (message.isToolSuggestion) {
      return PermissionPresentation(
        title: message.suggestedToolName,
        summary: message.toolSuggestionReason,
        rawDetails: rawDetails,
        riskBadge: message.toolSuggestionType == 'plugin'
            ? 'Plugin'
            : 'Connector',
      );
    }

    if (message.isQuestionApproval && !message.isMcpElicitation) {
      return PermissionPresentation(
        title: message.displayToolName,
        summary: requestUserInputQuestionText(input) ?? message.displayToolName,
        rawDetails: rawDetails,
        riskBadge: 'App Tool',
        secondaryDetails: _buildCommonSecondaryDetails(
          input,
          includePermissions: false,
        ),
      );
    }

    if (message.isQuestionPrompt && !message.isMcpElicitation) {
      return PermissionPresentation(
        title: requestUserInputHeader(input) ?? message.displayToolName,
        summary:
            requestUserInputQuestionText(input) ??
            _mcpSummary(input) ??
            message.displayToolName,
        rawDetails: rawDetails,
        riskBadge: message.isMcpElicitation ? 'MCP' : 'Question',
        secondaryDetails: _buildCommonSecondaryDetails(
          input,
          includePermissions: false,
        ),
      );
    }

    if (message.isMcpElicitation) {
      final toolDescription = _mcpToolDescription(input);
      final summary =
          toolDescription ??
          _mcpSummary(input) ??
          requestUserInputQuestionText(input) ??
          message.displayToolName;
      final url = _nonEmptyString(input['url']);
      return PermissionPresentation(
        title: message.displayToolName,
        summary: summary,
        rawDetails: rawDetails,
        riskBadge: 'MCP',
        primaryTargetLabel: url != null ? 'URL' : null,
        primaryTarget: url,
        secondaryDetails: _dedupeDetailLines(
          summary: summary,
          primaryTarget: url,
          lines: [
            if (_nonEmptyString(input['serverName']) case final serverName?)
              'Server: $serverName',
            ..._mcpToolParamLines(input),
            if (_nonEmptyString(input['message']) case final reason?)
              'Reason: $reason',
            ..._buildCommonSecondaryDetails(input, includePermissions: false),
          ],
        ),
      );
    }

    if (message.isPermissionGrantRequest) {
      final permissions = _flattenPermissionValues(input['permissions']);
      return PermissionPresentation(
        title: 'Additional Permissions',
        summary:
            _nonEmptyString(input['reason']) ??
            (permissions.isNotEmpty
                ? 'Grant additional access for this task'
                : message.displayToolName),
        rawDetails: rawDetails,
        riskBadge: 'Permissions',
        primaryTargetLabel: permissions.isNotEmpty ? 'Requested' : null,
        primaryTarget: permissions.isNotEmpty ? permissions.join(', ') : null,
        secondaryDetails: _buildCommonSecondaryDetails(
          input,
          includePermissions: true,
        ),
      );
    }

    switch (message.toolName) {
      case 'Bash':
        final command = _nonEmptyString(input['command']);
        final visibleReason = _visibleReason(
          input['reason'],
          primaryTarget: command,
        );
        return PermissionPresentation(
          title: 'Command Approval',
          summary: visibleReason ?? 'Allow command execution',
          rawDetails: rawDetails,
          riskBadge: 'Command',
          primaryTargetLabel: command != null ? 'Command' : null,
          primaryTarget: command,
          secondaryDetails: _dedupeDetailLines(
            summary: visibleReason ?? 'Allow command execution',
            primaryTarget: command,
            lines: _buildCommonSecondaryDetails(
              input,
              includePermissions: false,
              primaryTarget: command,
            ),
          ),
        );
      case 'FileChange':
        final changes = _changePaths(input['changes']);
        return PermissionPresentation(
          title: 'File Change Approval',
          summary:
              _nonEmptyString(input['reason']) ??
              _fileChangeSummary(changes) ??
              'Allow file changes',
          rawDetails: rawDetails,
          riskBadge: 'File Changes',
          primaryTargetLabel: changes.isNotEmpty ? 'Files' : null,
          primaryTarget: changes.isNotEmpty
              ? _compactFileTargets(changes)
              : null,
          secondaryDetails: [
            if (_nonEmptyString(input['grantRoot']) case final grantRoot?)
              'Grant root: $grantRoot',
            ..._buildCommonSecondaryDetails(
              input,
              includePermissions: false,
              includeReason: false,
            ),
          ],
        );
      default:
        final fallbackPrimary = _firstInputValue(input, const [
          'command',
          'file_path',
          'path',
          'pattern',
          'url',
        ]);
        return PermissionPresentation(
          title: message.displayToolName,
          summary:
              _visibleReason(input['reason'], primaryTarget: fallbackPrimary) ??
              fallbackPrimary ??
              message.displayToolName,
          rawDetails: rawDetails,
          riskBadge: message.displayToolName,
          primaryTargetLabel: fallbackPrimary != null ? 'Target' : null,
          primaryTarget: fallbackPrimary,
          secondaryDetails: _dedupeDetailLines(
            summary:
                _visibleReason(
                  input['reason'],
                  primaryTarget: fallbackPrimary,
                ) ??
                fallbackPrimary ??
                message.displayToolName,
            primaryTarget: fallbackPrimary,
            lines: _buildCommonSecondaryDetails(
              input,
              includePermissions: false,
              primaryTarget: fallbackPrimary,
            ),
          ),
        );
    }
  }
}

List<String> _flattenPermissionValues(dynamic value, [String prefix = '']) {
  if (value is Map) {
    final out = <String>[];
    for (final entry in value.entries) {
      final key = entry.key.toString();
      final nextPrefix = prefix.isEmpty ? key : '$prefix.$key';
      out.addAll(_flattenPermissionValues(entry.value, nextPrefix));
    }
    return out;
  }
  if (value is List) {
    return value
        .map((entry) => entry.toString())
        .where((entry) => entry.isNotEmpty)
        .map((entry) => prefix.isEmpty ? entry : '$prefix=$entry')
        .toList();
  }
  if (value is bool || value is num || value is String) {
    final text = value.toString();
    if (text.isEmpty) return const [];
    return [prefix.isEmpty ? text : '$prefix=$text'];
  }
  return const [];
}

String? _stringMapSummary(dynamic value) {
  if (value is! Map) return null;
  final parts = value.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .where((entry) => entry.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  return parts.join(', ');
}

String? _networkPolicySummary(dynamic value) {
  if (value is! List) return null;
  final parts = value
      .map((entry) => _stringMapSummary(entry))
      .whereType<String>()
      .toList();
  if (parts.isEmpty) return null;
  return parts.join(' | ');
}

String? _mcpSummary(Map<String, dynamic> input) {
  final message = _nonEmptyString(input['message']);
  final url = _nonEmptyString(input['url']);
  if (message != null && url != null) {
    return '$message | $url';
  }
  return message ?? url;
}

String? _nonEmptyString(dynamic value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _visibleReason(dynamic value, {String? primaryTarget}) {
  final reason = _nonEmptyString(value);
  final target = _nonEmptyString(primaryTarget);
  if (reason == null || target == null) return reason;

  final normalizedReason = reason.replaceAll('`', '');
  final normalizedTarget = target.replaceAll('`', '');
  final approvalBoilerplates = <String>[
    '$normalizedTarget requires approval:',
    '$normalizedTarget requires permission:',
  ];
  if (normalizedReason == normalizedTarget ||
      approvalBoilerplates.any(normalizedReason.startsWith)) {
    return null;
  }
  return reason;
}

String? _firstInputValue(Map<String, dynamic> input, List<String> keys) {
  for (final key in keys) {
    final value = _nonEmptyString(input[key]);
    if (value != null) return value;
  }
  return null;
}

List<String> _changePaths(dynamic value) {
  if (value is! List) return const [];
  return value
      .map((entry) {
        if (entry is! Map) return null;
        return _nonEmptyString(entry['file']) ??
            _nonEmptyString(entry['path']) ??
            _nonEmptyString(entry['target']);
      })
      .whereType<String>()
      .toList();
}

String? _fileChangeSummary(List<String> changes) {
  if (changes.isEmpty) return null;
  if (changes.length == 1) return 'Allow changes to ${changes.first}';
  return 'Allow changes to ${changes.length} files';
}

String _compactFileTargets(List<String> changes) {
  if (changes.isEmpty) return '';
  if (changes.length == 1) return changes.first;
  return '${changes.first} +${changes.length - 1} more';
}

List<String> _buildCommonSecondaryDetails(
  Map<String, dynamic> input, {
  required bool includePermissions,
  bool includeReason = true,
  String reasonLabel = 'Why',
  String? primaryTarget,
}) {
  final lines = <String>[];

  if (includeReason) {
    final reason = _visibleReason(
      input['reason'],
      primaryTarget: primaryTarget,
    );
    if (reason != null) {
      lines.add('$reasonLabel: $reason');
    }
  }

  if (includePermissions) {
    final permissions = _flattenPermissionValues(input['permissions']);
    if (permissions.isNotEmpty) {
      lines.add('Permissions: ${permissions.join(', ')}');
    }
  }

  final additionalPermissions = _flattenPermissionValues(
    input['additionalPermissions'],
  );
  if (additionalPermissions.isNotEmpty) {
    lines.add('Additional permissions: ${additionalPermissions.join(', ')}');
  }

  final execAmendment = _stringMapSummary(input['proposedExecpolicyAmendment']);
  if (execAmendment != null) {
    lines.add('Exec policy: $execAmendment');
  }

  final networkAmendments = _networkPolicySummary(
    input['proposedNetworkPolicyAmendments'],
  );
  if (networkAmendments != null) {
    lines.add('Network policy: $networkAmendments');
  }

  return lines;
}

String? _mcpToolDescription(Map<String, dynamic> input) {
  final meta = _stringKeyedMap(input['_meta']);
  return _nonEmptyString(meta?['tool_description']);
}

List<String> _mcpToolParamLines(Map<String, dynamic> input) {
  final meta = _stringKeyedMap(input['_meta']);
  final paramsDisplay = meta?['tool_params_display'];
  if (paramsDisplay is List) {
    final lines = paramsDisplay
        .map((entry) {
          final item = _stringKeyedMap(entry);
          if (item == null) return null;
          final label =
              _nonEmptyString(item['display_name']) ??
              _nonEmptyString(item['name']);
          final value = _nonEmptyString(item['value']);
          if (label == null || value == null) return null;
          return '${_titleCaseLabel(label)}: $value';
        })
        .whereType<String>()
        .toList();
    if (lines.isNotEmpty) return lines;
  }

  final params = _stringKeyedMap(meta?['tool_params']);
  if (params == null || params.isEmpty) return const [];
  return params.entries
      .map((entry) {
        final value = _stringifyDetailValue(entry.value);
        if (value == null) return null;
        return '${_titleCaseLabel(entry.key)}: $value';
      })
      .whereType<String>()
      .toList();
}

List<String> _dedupeDetailLines({
  required String summary,
  String? primaryTarget,
  required List<String> lines,
}) {
  final normalizedSummary = _normalizeDetailValue(summary);
  final normalizedPrimary = _normalizeDetailValue(primaryTarget);
  final seen = <String>{};
  final deduped = <String>[];

  for (final line in lines) {
    final normalizedLine = _normalizeDetailValue(_detailLineValue(line));
    if (normalizedLine == null || normalizedLine.isEmpty) {
      if (seen.add(line)) deduped.add(line);
      continue;
    }
    if (normalizedLine == normalizedSummary ||
        normalizedLine == normalizedPrimary) {
      continue;
    }
    if (!seen.add(normalizedLine)) continue;
    deduped.add(line);
  }

  return deduped;
}

Map<String, dynamic>? _stringKeyedMap(dynamic value) {
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String? _stringifyDetailValue(dynamic value) {
  if (value == null) return null;
  if (value is String) return _nonEmptyString(value);
  if (value is num || value is bool) return value.toString();
  if (value is List) {
    final parts = value.map(_stringifyDetailValue).whereType<String>().toList();
    return parts.isEmpty ? null : parts.join(', ');
  }
  if (value is Map) {
    final parts = value.entries
        .map((entry) {
          final rendered = _stringifyDetailValue(entry.value);
          if (rendered == null) return null;
          return '${entry.key}=$rendered';
        })
        .whereType<String>()
        .toList();
    return parts.isEmpty ? null : parts.join(', ');
  }
  return value.toString();
}

String _titleCaseLabel(String label) {
  final normalized = label.replaceAll('_', ' ').trim();
  if (normalized.isEmpty) return label;
  return normalized
      .split(RegExp(r'\s+'))
      .map((part) {
        if (part.isEmpty) return part;
        return '${part[0].toUpperCase()}${part.substring(1)}';
      })
      .join(' ');
}

String? _detailLineValue(String line) {
  final idx = line.indexOf(':');
  if (idx == -1) return line;
  return line.substring(idx + 1).trim();
}

String? _normalizeDetailValue(String? value) {
  final text = _nonEmptyString(value);
  if (text == null) return null;
  return text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
}

List<String> _stringList(dynamic value) {
  if (value is! List) return const [];
  return value
      .map((entry) => entry.toString())
      .where((entry) => entry.isNotEmpty)
      .toList();
}

List<Map<String, String>> _stringMapList(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map(
        (entry) => {
          'name': entry['name']?.toString() ?? '',
          'path': entry['path']?.toString() ?? '',
        },
      )
      .where((entry) => entry['name']!.isNotEmpty && entry['path']!.isNotEmpty)
      .toList();
}

class PermissionResolvedMessage implements ServerMessage {
  final String toolUseId;
  const PermissionResolvedMessage({required this.toolUseId});
}

class StreamDeltaMessage implements ServerMessage {
  final String text;
  const StreamDeltaMessage({required this.text});
}

class ThinkingDeltaMessage implements ServerMessage {
  final String text;
  const ThinkingDeltaMessage({required this.text});
}

class SessionListMessage implements ServerMessage {
  final List<SessionInfo> sessions;

  /// Malformed session entries skipped during parsing (logged by the
  /// receiver); one bad entry must not blank the whole session list.
  final int droppedSessionCount;
  final String? bridgeInstanceId;
  final String? codexSourceId;
  final List<String> allowedDirs;
  final List<String> claudeModels;
  final Map<String, List<String>> claudeModelEfforts;
  final List<String> codexModels;
  final Map<String, List<String>> codexModelReasoningEfforts;
  final Map<String, List<String>> codexModelServiceTiers;
  final List<String> codexProfiles;
  final String? defaultCodexProfile;
  final bool codexAutoReviewDisabled;
  final String? bridgeVersion;
  final List<String> bridgeCapabilities;
  const SessionListMessage({
    required this.sessions,
    this.droppedSessionCount = 0,
    this.bridgeInstanceId,
    this.codexSourceId,
    this.allowedDirs = const [],
    this.claudeModels = const [],
    this.claudeModelEfforts = const {},
    this.codexModels = const [],
    this.codexModelReasoningEfforts = const {},
    this.codexModelServiceTiers = const {},
    this.codexProfiles = const [],
    this.defaultCodexProfile,
    this.codexAutoReviewDisabled = false,
    this.bridgeVersion,
    this.bridgeCapabilities = const [],
  });
}

class RecentSessionsMessage implements ServerMessage {
  final List<RecentSession> sessions;
  final bool hasMore;
  final int? limit;
  final int? offset;
  final String? projectPath;
  final String? requestScope;
  final String? requestId;
  final int? queryGeneration;
  final int? catalogRevision;
  final String? provider;
  final bool? namedOnly;
  final String? searchQuery;
  const RecentSessionsMessage({
    required this.sessions,
    this.hasMore = false,
    this.limit,
    this.offset,
    this.projectPath,
    this.requestScope,
    this.requestId,
    this.queryGeneration,
    this.catalogRevision,
    this.provider,
    this.namedOnly,
    this.searchQuery,
  });
}

class SessionCatalogChangedMessage implements ServerMessage {
  final int revision;
  final String? occurredAt;

  const SessionCatalogChangedMessage({required this.revision, this.occurredAt});
}

class PastHistoryMessage implements ServerMessage {
  final String claudeSessionId;
  final List<PastMessage> messages;
  const PastHistoryMessage({
    required this.claudeSessionId,
    required this.messages,
  });
}

class GalleryListMessage implements ServerMessage {
  final List<GalleryImage> images;
  const GalleryListMessage({required this.images});
}

class GalleryNewImageMessage implements ServerMessage {
  final GalleryImage image;
  const GalleryNewImageMessage({required this.image});
}

// ---- Screenshot / Window ----

class WindowInfo {
  final int windowId;
  final String ownerName;
  final String windowTitle;

  const WindowInfo({
    required this.windowId,
    required this.ownerName,
    required this.windowTitle,
  });

  factory WindowInfo.fromJson(Map<String, dynamic> json) {
    return WindowInfo(
      windowId: json['windowId'] as int,
      ownerName: json['ownerName'] as String? ?? '',
      windowTitle: json['windowTitle'] as String? ?? '',
    );
  }
}

class WindowListMessage implements ServerMessage {
  final List<WindowInfo> windows;
  const WindowListMessage({required this.windows});
}

class ScreenshotResultMessage implements ServerMessage {
  final bool success;
  final GalleryImage? image;
  final String? error;
  const ScreenshotResultMessage({
    required this.success,
    this.image,
    this.error,
  });
}

class DebugTraceEvent {
  final String ts;
  final String sessionId;
  final String direction;
  final String channel;
  final String type;
  final String? detail;

  const DebugTraceEvent({
    required this.ts,
    required this.sessionId,
    required this.direction,
    required this.channel,
    required this.type,
    this.detail,
  });

  factory DebugTraceEvent.fromJson(Map<String, dynamic> json) {
    return DebugTraceEvent(
      ts: json['ts'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      direction: json['direction'] as String? ?? '',
      channel: json['channel'] as String? ?? '',
      type: json['type'] as String? ?? '',
      detail: json['detail'] as String?,
    );
  }
}

class DebugBundleSession {
  final String id;
  final String provider;
  final String status;
  final String projectPath;
  final String? worktreePath;
  final String? worktreeBranch;
  final String? claudeSessionId;
  final String createdAt;
  final String lastActivityAt;

  const DebugBundleSession({
    required this.id,
    required this.provider,
    required this.status,
    required this.projectPath,
    this.worktreePath,
    this.worktreeBranch,
    this.claudeSessionId,
    required this.createdAt,
    required this.lastActivityAt,
  });

  factory DebugBundleSession.fromJson(Map<String, dynamic> json) {
    return DebugBundleSession(
      id: json['id'] as String? ?? '',
      provider: json['provider'] as String? ?? '',
      status: json['status'] as String? ?? '',
      projectPath: json['projectPath'] as String? ?? '',
      worktreePath: json['worktreePath'] as String?,
      worktreeBranch: json['worktreeBranch'] as String?,
      claudeSessionId: json['claudeSessionId'] as String?,
      createdAt: json['createdAt'] as String? ?? '',
      lastActivityAt: json['lastActivityAt'] as String? ?? '',
    );
  }
}

class DebugReproRecipe {
  final String wsUrlHint;
  final String startBridgeCommand;
  final Map<String, dynamic> resumeSessionMessage;
  final Map<String, dynamic> getHistoryMessage;
  final Map<String, dynamic> getDebugBundleMessage;
  final List<String> notes;

  const DebugReproRecipe({
    this.wsUrlHint = '',
    this.startBridgeCommand = '',
    this.resumeSessionMessage = const <String, dynamic>{},
    this.getHistoryMessage = const <String, dynamic>{},
    this.getDebugBundleMessage = const <String, dynamic>{},
    this.notes = const [],
  });

  factory DebugReproRecipe.fromJson(Map<String, dynamic> json) {
    return DebugReproRecipe(
      wsUrlHint: json['wsUrlHint'] as String? ?? '',
      startBridgeCommand: json['startBridgeCommand'] as String? ?? '',
      resumeSessionMessage:
          (json['resumeSessionMessage'] as Map<String, dynamic>?) ??
          const <String, dynamic>{},
      getHistoryMessage:
          (json['getHistoryMessage'] as Map<String, dynamic>?) ??
          const <String, dynamic>{},
      getDebugBundleMessage:
          (json['getDebugBundleMessage'] as Map<String, dynamic>?) ??
          const <String, dynamic>{},
      notes: (json['notes'] as List?)?.whereType<String>().toList() ?? const [],
    );
  }
}

class DebugBundleMessage implements ServerMessage {
  final String sessionId;
  final String generatedAt;
  final DebugBundleSession session;
  final int pastMessageCount;
  final List<String> historySummary;
  final List<DebugTraceEvent> debugTrace;
  final String? traceFilePath;
  final String? savedBundlePath;
  final DebugReproRecipe reproRecipe;
  final String agentPrompt;
  final String diff;
  final String? diffError;

  const DebugBundleMessage({
    required this.sessionId,
    required this.generatedAt,
    required this.session,
    required this.pastMessageCount,
    this.historySummary = const [],
    this.debugTrace = const [],
    this.traceFilePath,
    this.savedBundlePath,
    this.reproRecipe = const DebugReproRecipe(),
    this.agentPrompt = '',
    required this.diff,
    this.diffError,
  });
}

class FileListMessage implements ServerMessage {
  final List<String> files;
  final String? requestId;
  final String? projectPath;
  final int? totalFiles;
  final bool truncated;
  final String? error;
  final String? errorCode;

  /// Local-only marker emitted when BridgeService clears bridge-scoped state.
  /// It is never parsed from the wire and must not satisfy an Explorer request.
  final bool reset;

  const FileListMessage({
    required this.files,
    this.requestId,
    this.projectPath,
    this.totalFiles,
    this.truncated = false,
    this.error,
    this.errorCode,
    this.reset = false,
  });
}

class FileContentMessage implements ServerMessage {
  final String? requestId;
  final String filePath;
  final String kind;
  final String content;
  final String? language;
  final String? error;
  final String? errorCode;
  final int? totalLines;
  final bool truncated;
  final String? base64;
  final String? mimeType;
  final int? sizeBytes;
  const FileContentMessage({
    this.requestId,
    required this.filePath,
    this.kind = 'text',
    required this.content,
    this.language,
    this.error,
    this.errorCode,
    this.totalLines,
    this.truncated = false,
    this.base64,
    this.mimeType,
    this.sizeBytes,
  });
}

class ProjectHistoryMessage implements ServerMessage {
  final List<String> projects;
  const ProjectHistoryMessage({required this.projects});
}

/// Image change detected in a git diff.
class DiffImageChange {
  final String filePath;
  final bool isNew;
  final bool isDeleted;
  final bool isSvg;
  final int? oldSize;
  final int? newSize;
  final String? oldBase64;
  final String? newBase64;
  final String mimeType;
  final bool loadable;
  final bool autoDisplay;

  const DiffImageChange({
    required this.filePath,
    this.isNew = false,
    this.isDeleted = false,
    this.isSvg = false,
    this.oldSize,
    this.newSize,
    this.oldBase64,
    this.newBase64,
    required this.mimeType,
    this.loadable = false,
    this.autoDisplay = false,
  });

  factory DiffImageChange.fromJson(Map<String, dynamic> json) =>
      DiffImageChange(
        filePath: json['filePath'] as String,
        isNew: json['isNew'] as bool? ?? false,
        isDeleted: json['isDeleted'] as bool? ?? false,
        isSvg: json['isSvg'] as bool? ?? false,
        oldSize: json['oldSize'] as int?,
        newSize: json['newSize'] as int?,
        oldBase64: json['oldBase64'] as String?,
        newBase64: json['newBase64'] as String?,
        mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
        loadable: json['loadable'] as bool? ?? false,
        autoDisplay: json['autoDisplay'] as bool? ?? false,
      );
}

class DiffResultMessage implements ServerMessage {
  final String diff;
  final String? error;
  final String? errorCode;
  final List<DiffImageChange> imageChanges;

  /// Echo of the get_diff requestId; null when talking to an old Bridge.
  final String? requestId;

  const DiffResultMessage({
    required this.diff,
    this.error,
    this.errorCode,
    this.imageChanges = const [],
    this.requestId,
  });
}

class DiffImageResultMessage implements ServerMessage {
  /// Echoed by current Bridges; absent when talking to an old Bridge.
  final String? projectPath;
  final String filePath;
  final String version;
  final String? base64;
  final String? mimeType;
  final String? error;

  /// For version="both": old/new base64 in a single response.
  final String? oldBase64;
  final String? newBase64;
  final String? requestId;

  const DiffImageResultMessage({
    this.projectPath,
    required this.filePath,
    required this.version,
    this.base64,
    this.mimeType,
    this.error,
    this.oldBase64,
    this.newBase64,
    this.requestId,
  });
}

class WorktreeListMessage implements ServerMessage {
  final List<WorktreeInfo> worktrees;
  final String? mainBranch;
  const WorktreeListMessage({required this.worktrees, this.mainBranch});
}

class WorktreeRemovedMessage implements ServerMessage {
  final String worktreePath;
  const WorktreeRemovedMessage({required this.worktreePath});
}

/// Summary of tool uses within a subagent (Task tool).
/// This message replaces multiple tool_result messages with a compressed summary.
class ToolUseSummaryMessage implements ServerMessage {
  /// Human-readable summary of the tools used (e.g., "Read 3 files and analyzed code")
  final String summary;

  /// IDs of the tool_use calls that this summary replaces
  final List<String> precedingToolUseIds;

  const ToolUseSummaryMessage({
    required this.summary,
    this.precedingToolUseIds = const [],
  });
}

/// User text input message (emitted from history replay).
///
/// Bridge sends this when restoring in-memory history so that Flutter can
/// reconstruct [UserChatEntry] with the original text and UUID.
class UserInputMessage implements ServerMessage {
  final String text;
  final String? clientMessageId;
  final String? userMessageUuid;

  /// Whether this message was synthetically generated by Claude CLI
  /// (e.g. plan approval, Task agent prompts) rather than typed by the user.
  final bool isSynthetic;

  /// Whether this is a meta message (e.g. skill loading prompt).
  final bool isMeta;

  /// Number of images attached to this user message.
  final int imageCount;

  /// ISO 8601 timestamp from the bridge server (may be null for older history).
  final String? timestamp;

  /// Image URLs (relative, e.g. "/images/{id}") from the bridge image store.
  final List<String> imageUrls;
  const UserInputMessage({
    required this.text,
    this.clientMessageId,
    this.userMessageUuid,
    this.isSynthetic = false,
    this.isMeta = false,
    this.imageCount = 0,
    this.timestamp,
    this.imageUrls = const [],
  });
}

class RewindPreviewMessage implements ServerMessage {
  final bool canRewind;
  final List<String>? filesChanged;
  final int? insertions;
  final int? deletions;
  final String? error;
  const RewindPreviewMessage({
    required this.canRewind,
    this.filesChanged,
    this.insertions,
    this.deletions,
    this.error,
  });
}

class RewindResultMessage implements ServerMessage {
  final bool success;
  final String mode;
  final String? error;
  const RewindResultMessage({
    required this.success,
    required this.mode,
    this.error,
  });
}

class InputAckMessage implements ServerMessage {
  final String? sessionId;
  final String? clientMessageId;
  final int? acceptedSeq;

  /// When true the agent was busy and the message was queued for the next turn.
  /// An automatic interrupt is triggered server-side so the agent picks it up
  /// promptly, but the client can show a brief "queued" indicator.
  final bool queued;
  final InputAckStage? stage;
  const InputAckMessage({
    this.sessionId,
    this.clientMessageId,
    this.acceptedSeq,
    this.queued = false,
    this.stage,
  });
}

enum InputAckStage {
  bridgeAccepted('bridge_accepted');

  const InputAckStage(this.wireValue);
  final String wireValue;

  static InputAckStage? fromWireValue(Object? value) => switch (value) {
    'bridge_accepted' => InputAckStage.bridgeAccepted,
    _ => null,
  };
}

enum InputDeliveryStage {
  providerAccepted('provider_accepted'),
  providerRejected('provider_rejected');

  const InputDeliveryStage(this.wireValue);
  final String wireValue;

  static InputDeliveryStage? fromWireValue(Object? value) => switch (value) {
    'provider_accepted' => InputDeliveryStage.providerAccepted,
    'provider_rejected' => InputDeliveryStage.providerRejected,
    _ => null,
  };
}

class InputDeliveryStatusMessage implements ServerMessage {
  final String sessionId;
  final String clientMessageId;
  final InputDeliveryStage stage;
  final String provider;
  final String method;
  final String occurredAt;
  final int? acceptedSeq;
  final bool queued;
  final bool? clientUserMessageIdAccepted;
  final String? error;

  const InputDeliveryStatusMessage({
    required this.sessionId,
    required this.clientMessageId,
    required this.stage,
    required this.provider,
    required this.method,
    required this.occurredAt,
    this.acceptedSeq,
    this.queued = false,
    this.clientUserMessageIdAccepted,
    this.error,
  });

  factory InputDeliveryStatusMessage.fromJson(Map<String, dynamic> json) {
    final sessionId = json['sessionId'];
    final clientMessageId = json['clientMessageId'];
    final stage = InputDeliveryStage.fromWireValue(json['stage']);
    final provider = json['provider'];
    final method = json['method'];
    final occurredAt = json['occurredAt'];
    final acceptedSeq = json['acceptedSeq'];
    final queued = json['queued'];
    final clientUserMessageIdAccepted = json['clientUserMessageIdAccepted'];
    final error = json['error'];
    if (sessionId is! String ||
        sessionId.isEmpty ||
        clientMessageId is! String ||
        clientMessageId.isEmpty ||
        stage == null ||
        provider != Provider.codex.value ||
        (method != 'turn/start' && method != 'turn/steer') ||
        occurredAt is! String ||
        DateTime.tryParse(occurredAt) == null ||
        (acceptedSeq != null && acceptedSeq is! int) ||
        (queued != null && queued is! bool) ||
        (clientUserMessageIdAccepted != null &&
            clientUserMessageIdAccepted is! bool) ||
        (error != null && error is! String)) {
      throw const FormatException('Invalid input delivery status payload.');
    }
    return InputDeliveryStatusMessage(
      sessionId: sessionId,
      clientMessageId: clientMessageId,
      stage: stage,
      provider: provider as String,
      method: method as String,
      occurredAt: occurredAt,
      acceptedSeq: acceptedSeq as int?,
      queued: queued as bool? ?? false,
      clientUserMessageIdAccepted: clientUserMessageIdAccepted as bool?,
      error: error as String?,
    );
  }
}

class ConversationQueueMessage implements ServerMessage {
  final String? sessionId;
  final int limit;
  final List<QueuedInputItem> items;
  const ConversationQueueMessage({
    this.sessionId,
    required this.limit,
    required this.items,
  });
}

class GoalStateMessage implements ServerMessage {
  final String? sessionId;
  final CodexGoal? goal;
  final String? goalChangeId;
  final int? goalOperationSequence;
  const GoalStateMessage({
    this.sessionId,
    required this.goal,
    this.goalChangeId,
    this.goalOperationSequence,
  });
}

class InputRejectedMessage implements ServerMessage {
  final String? sessionId;
  final String? clientMessageId;
  final String? reason;
  const InputRejectedMessage({
    this.sessionId,
    this.clientMessageId,
    this.reason,
  });
}

class UsageResultMessage implements ServerMessage {
  final List<UsageInfo> providers;
  const UsageResultMessage({required this.providers});
}

class RecordingListMessage implements ServerMessage {
  final List<RecordingInfo> recordings;
  const RecordingListMessage({required this.recordings});
}

class RecordingContentMessage implements ServerMessage {
  final String sessionId;
  final String content;
  const RecordingContentMessage({
    required this.sessionId,
    required this.content,
  });
}

class RenameResultMessage implements ServerMessage {
  final String sessionId;
  final String? name;
  final bool success;
  final String? error;
  const RenameResultMessage({
    required this.sessionId,
    this.name,
    required this.success,
    this.error,
  });
}

class ArchiveResultMessage implements ServerMessage {
  final String? requestId;
  final String sessionId;
  final String? provider;
  final bool success;
  final String? error;
  final String? errorCode;
  const ArchiveResultMessage({
    this.requestId,
    required this.sessionId,
    this.provider,
    required this.success,
    this.error,
    this.errorCode,
  });
}

class ArchivedSessionRecord {
  final String sessionId;
  final String provider;
  final String? codexSourceId;
  final String projectPath;
  final String archivedAt;
  final String? name;
  final String? summary;
  final String? firstPrompt;
  final String? modified;

  const ArchivedSessionRecord({
    required this.sessionId,
    required this.provider,
    this.codexSourceId,
    required this.projectPath,
    required this.archivedAt,
    this.name,
    this.summary,
    this.firstPrompt,
    this.modified,
  });

  factory ArchivedSessionRecord.fromJson(Map<String, dynamic> json) =>
      ArchivedSessionRecord(
        sessionId: json['sessionId'] as String? ?? '',
        provider: json['provider'] as String? ?? '',
        codexSourceId: json['codexSourceId'] as String?,
        projectPath: json['projectPath'] as String? ?? '',
        archivedAt: json['archivedAt'] as String? ?? '',
        name: json['name'] as String?,
        summary: json['summary'] as String?,
        firstPrompt: json['firstPrompt'] as String?,
        modified: json['modified'] as String?,
      );

  String get displayTitle {
    final named = name?.trim();
    if (named != null && named.isNotEmpty) return named;
    final prompt = firstPrompt?.trim();
    if (prompt != null && prompt.isNotEmpty) return prompt;
    final summarized = summary?.trim();
    if (summarized != null && summarized.isNotEmpty) return summarized;
    return sessionId;
  }
}

class ArchivedSessionsResultMessage implements ServerMessage {
  final String requestId;
  final bool success;
  final List<ArchivedSessionRecord> sessions;
  final bool truncated;
  final String? error;
  final String? errorCode;

  const ArchivedSessionsResultMessage({
    required this.requestId,
    required this.success,
    required this.sessions,
    this.truncated = false,
    this.error,
    this.errorCode,
  });
}

class SessionLifecycleResultMessage implements ServerMessage {
  final String type;
  final String requestId;
  final String sessionId;
  final bool success;
  final String? error;
  final String? errorCode;

  const SessionLifecycleResultMessage({
    required this.type,
    required this.requestId,
    required this.sessionId,
    required this.success,
    this.error,
    this.errorCode,
  });
}

/// Response to a `refresh_branch` request with the current git branch.
class BranchUpdateMessage implements ServerMessage {
  final String sessionId;
  final String branch;
  const BranchUpdateMessage({required this.sessionId, required this.branch});
}

class PromptHistoryBackupResultMessage implements ServerMessage {
  final bool success;
  final String? backedUpAt;
  final String? error;
  const PromptHistoryBackupResultMessage({
    required this.success,
    this.backedUpAt,
    this.error,
  });
}

class PromptHistoryRestoreResultMessage implements ServerMessage {
  final bool success;
  final String? data;
  final String? appVersion;
  final int? dbVersion;
  final String? backedUpAt;
  final String? error;
  const PromptHistoryRestoreResultMessage({
    required this.success,
    this.data,
    this.appVersion,
    this.dbVersion,
    this.backedUpAt,
    this.error,
  });
}

class PromptHistoryBackupInfoMessage implements ServerMessage {
  final bool exists;
  final String? appVersion;
  final int? dbVersion;
  final String? backedUpAt;
  final int? sizeBytes;
  const PromptHistoryBackupInfoMessage({
    required this.exists,
    this.appVersion,
    this.dbVersion,
    this.backedUpAt,
    this.sizeBytes,
  });
}

class PromptHistoryServerEntry {
  final String id;
  final String text;
  final String projectPath;
  final int totalUseCount;
  final bool isFavorite;
  final String createdAt;
  final String lastUsedAt;
  final String updatedAt;
  final String? favoriteUpdatedAt;
  final String? deletedAt;
  final String commandKind;
  final Map<String, PromptHistoryClientStat> clientStats;
  final Map<String, PromptHistorySessionStat> sessionStats;

  const PromptHistoryServerEntry({
    required this.id,
    required this.text,
    required this.projectPath,
    required this.totalUseCount,
    required this.isFavorite,
    required this.createdAt,
    required this.lastUsedAt,
    required this.updatedAt,
    this.favoriteUpdatedAt,
    this.deletedAt,
    required this.commandKind,
    required this.clientStats,
    required this.sessionStats,
  });

  factory PromptHistoryServerEntry.fromJson(Map<String, dynamic> json) {
    return PromptHistoryServerEntry(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      projectPath: json['projectPath'] as String? ?? '',
      totalUseCount: json['totalUseCount'] as int? ?? 0,
      isFavorite: json['isFavorite'] as bool? ?? false,
      createdAt: json['createdAt'] as String? ?? '',
      lastUsedAt: json['lastUsedAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
      favoriteUpdatedAt: json['favoriteUpdatedAt'] as String?,
      deletedAt: json['deletedAt'] as String?,
      commandKind: json['commandKind'] as String? ?? 'none',
      clientStats:
          (json['clientStats'] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(
              key,
              PromptHistoryClientStat.fromJson(value as Map<String, dynamic>),
            ),
          ) ??
          const {},
      sessionStats:
          (json['sessionStats'] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(
              key,
              PromptHistorySessionStat.fromJson(value as Map<String, dynamic>),
            ),
          ) ??
          const {},
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'projectPath': projectPath,
    'totalUseCount': totalUseCount,
    'isFavorite': isFavorite,
    'createdAt': createdAt,
    'lastUsedAt': lastUsedAt,
    'updatedAt': updatedAt,
    'favoriteUpdatedAt': ?favoriteUpdatedAt,
    'deletedAt': ?deletedAt,
    'commandKind': commandKind,
    'clientStats': clientStats.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'sessionStats': sessionStats.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
  };
}

class PromptHistoryClientStat {
  final int useCount;
  final String lastUsedAt;
  final String? clientName;

  const PromptHistoryClientStat({
    required this.useCount,
    required this.lastUsedAt,
    this.clientName,
  });

  factory PromptHistoryClientStat.fromJson(Map<String, dynamic> json) {
    return PromptHistoryClientStat(
      useCount: json['useCount'] as int? ?? 0,
      lastUsedAt: json['lastUsedAt'] as String? ?? '',
      clientName: json['clientName'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'useCount': useCount,
    'lastUsedAt': lastUsedAt,
    'clientName': ?clientName,
  };
}

class PromptHistorySessionStat {
  final int useCount;
  final String lastUsedAt;

  const PromptHistorySessionStat({
    required this.useCount,
    required this.lastUsedAt,
  });

  factory PromptHistorySessionStat.fromJson(Map<String, dynamic> json) {
    return PromptHistorySessionStat(
      useCount: json['useCount'] as int? ?? 0,
      lastUsedAt: json['lastUsedAt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'useCount': useCount,
    'lastUsedAt': lastUsedAt,
  };
}

class PromptHistorySyncResultMessage implements ServerMessage {
  final bool success;
  final String? requestId;
  final String? bridgeInstanceId;
  final int? revision;
  final String? syncedAt;
  final bool fullSnapshot;
  final List<PromptHistoryServerEntry> entries;
  final String? error;

  const PromptHistorySyncResultMessage({
    required this.success,
    this.requestId,
    this.bridgeInstanceId,
    this.revision,
    this.syncedAt,
    this.fullSnapshot = false,
    this.entries = const [],
    this.error,
  });
}

class PromptHistoryMutationResultMessage implements ServerMessage {
  final bool success;
  final String? bridgeInstanceId;
  final int? revision;
  final PromptHistoryServerEntry? entry;
  final String? error;

  const PromptHistoryMutationResultMessage({
    required this.success,
    this.bridgeInstanceId,
    this.revision,
    this.entry,
    this.error,
  });
}

class PromptHistoryStatusMessage implements ServerMessage {
  final String bridgeInstanceId;
  final int revision;
  final int entryCount;
  final String? updatedAt;

  const PromptHistoryStatusMessage({
    required this.bridgeInstanceId,
    required this.revision,
    required this.entryCount,
    this.updatedAt,
  });
}

class MessageImagesResultMessage implements ServerMessage {
  final String messageUuid;
  final List<ImageRef> images;
  const MessageImagesResultMessage({
    required this.messageUuid,
    required this.images,
  });
}

// ---- Git Operations (Phase 1-3) ----
// Git results are broadcast to every listener; [projectPath] (echoed by the
// Bridge since the crosstalk fix) lets views bound to different projects
// discard each other's results. Old Bridges omit it → accept everything.

class GitStageResultMessage implements ServerMessage {
  final bool success;
  final String? projectPath;
  final String? error;
  const GitStageResultMessage({
    required this.success,
    this.projectPath,
    this.error,
  });
}

class GitUnstageResultMessage implements ServerMessage {
  final bool success;
  final String? projectPath;
  final String? error;
  const GitUnstageResultMessage({
    required this.success,
    this.projectPath,
    this.error,
  });
}

class GitUnstageHunksResultMessage implements ServerMessage {
  final bool success;
  final String? projectPath;
  final String? error;
  const GitUnstageHunksResultMessage({
    required this.success,
    this.projectPath,
    this.error,
  });
}

class GitCommitResultMessage implements ServerMessage {
  final bool success;
  final String? projectPath;
  final String? commitHash;
  final String? message;
  final String? error;
  const GitCommitResultMessage({
    required this.success,
    this.projectPath,
    this.commitHash,
    this.message,
    this.error,
  });
}

class GitPushResultMessage implements ServerMessage {
  final bool success;
  final String? projectPath;
  final String? error;
  const GitPushResultMessage({
    required this.success,
    this.projectPath,
    this.error,
  });
}

class GitBranchRemoteStatus {
  final int ahead;
  final int behind;
  final bool hasUpstream;

  const GitBranchRemoteStatus({
    required this.ahead,
    required this.behind,
    required this.hasUpstream,
  });

  factory GitBranchRemoteStatus.fromJson(Map<String, dynamic> json) {
    return GitBranchRemoteStatus(
      ahead: json['ahead'] as int? ?? 0,
      behind: json['behind'] as int? ?? 0,
      hasUpstream: json['hasUpstream'] as bool? ?? false,
    );
  }
}

class GitBranchesResultMessage implements ServerMessage {
  final String current;
  final List<String> branches;
  final String? projectPath;
  final List<String> checkedOutBranches;
  final Map<String, GitBranchRemoteStatus> remoteStatusByBranch;
  final String? error;
  const GitBranchesResultMessage({
    required this.current,
    required this.branches,
    this.projectPath,
    this.checkedOutBranches = const [],
    this.remoteStatusByBranch = const {},
    this.error,
  });
}

class GitCreateBranchResultMessage implements ServerMessage {
  final bool success;
  final String? projectPath;
  final String? error;
  const GitCreateBranchResultMessage({
    required this.success,
    this.projectPath,
    this.error,
  });
}

class GitCheckoutBranchResultMessage implements ServerMessage {
  final bool success;
  final String? projectPath;
  final String? error;
  const GitCheckoutBranchResultMessage({
    required this.success,
    this.projectPath,
    this.error,
  });
}

class GitRevertFileResultMessage implements ServerMessage {
  final bool success;
  final String? projectPath;
  final String? error;
  const GitRevertFileResultMessage({
    required this.success,
    this.projectPath,
    this.error,
  });
}

class GitRevertHunksResultMessage implements ServerMessage {
  final bool success;
  final String? projectPath;
  final String? error;
  const GitRevertHunksResultMessage({
    required this.success,
    this.projectPath,
    this.error,
  });
}

class GitFetchResultMessage implements ServerMessage {
  final bool success;
  final String? projectPath;
  final String? error;
  const GitFetchResultMessage({
    required this.success,
    this.projectPath,
    this.error,
  });
}

class GitPullResultMessage implements ServerMessage {
  final bool success;
  final String? projectPath;
  final String? message;
  final String? error;
  const GitPullResultMessage({
    required this.success,
    this.projectPath,
    this.message,
    this.error,
  });
}

class GitStatusResultMessage implements ServerMessage {
  final String? sessionId;
  final String projectPath;
  final bool hasUncommittedChanges;
  final int stagedCount;
  final int unstagedCount;
  final int untrackedCount;
  final bool remoteStatusIncluded;
  final bool hasRemoteChanges;
  final int commitsAhead;
  final int commitsBehind;
  final bool hasUpstream;
  final String? branch;
  final String? remoteError;
  final String? error;
  const GitStatusResultMessage({
    this.sessionId,
    required this.projectPath,
    required this.hasUncommittedChanges,
    required this.stagedCount,
    required this.unstagedCount,
    required this.untrackedCount,
    this.remoteStatusIncluded = false,
    this.hasRemoteChanges = false,
    this.commitsAhead = 0,
    this.commitsBehind = 0,
    this.hasUpstream = false,
    this.branch,
    this.remoteError,
    this.error,
  });
}

class GitRemoteStatusResultMessage implements ServerMessage {
  final int ahead;
  final int behind;
  final String branch;
  final bool hasUpstream;
  final String? projectPath;
  final String? error;
  final String? errorCode;
  const GitRemoteStatusResultMessage({
    required this.ahead,
    required this.behind,
    required this.branch,
    required this.hasUpstream,
    this.projectPath,
    this.error,
    this.errorCode,
  });
}

class RecordingInfo {
  final String name;
  final String modified;
  final int sizeBytes;
  final String? projectPath;
  final String? summary;
  final String? firstPrompt;
  final String? lastPrompt;

  const RecordingInfo({
    required this.name,
    required this.modified,
    required this.sizeBytes,
    this.projectPath,
    this.summary,
    this.firstPrompt,
    this.lastPrompt,
  });

  factory RecordingInfo.fromJson(Map<String, dynamic> json) {
    final meta = json['meta'] as Map<String, dynamic>?;
    return RecordingInfo(
      name: json['name'] as String? ?? '',
      modified: json['modified'] as String? ?? '',
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      projectPath: meta?['projectPath'] as String?,
      summary: json['summary'] as String?,
      firstPrompt: json['firstPrompt'] as String?,
      lastPrompt: json['lastPrompt'] as String?,
    );
  }

  /// Display text prioritizing summary > firstPrompt > name fallback.
  String get displayText {
    if (summary != null && summary!.isNotEmpty) return summary!;
    if (firstPrompt != null && firstPrompt!.isNotEmpty) return firstPrompt!;
    return name;
  }

  /// Short project name (last path component).
  String? get projectName {
    if (projectPath == null || projectPath!.isEmpty) return null;
    return pathBasename(projectPath!);
  }

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  DateTime? get modifiedDate => DateTime.tryParse(modified);
}

class PastMessage {
  final String role;
  final String? uuid;
  final String? timestamp;

  /// Whether this is a meta message (e.g. skill loading prompt).
  final bool isMeta;

  /// Number of images attached to this user message.
  final int imageCount;
  final String? toolUseId;
  final String? toolName;
  final List<ImageRef> images;
  final String? toolResultContent;
  final List<AssistantContent> content;
  final List<ArtifactRef> artifacts;
  const PastMessage({
    required this.role,
    this.uuid,
    this.timestamp,
    this.isMeta = false,
    this.imageCount = 0,
    this.toolUseId,
    this.toolName,
    this.images = const [],
    this.toolResultContent,
    required this.content,
    this.artifacts = const [],
  });

  factory PastMessage.fromJson(Map<String, dynamic> json) {
    final rawContent = json['content'];
    final List<AssistantContent> contentList;
    if (rawContent is String) {
      // Handle string content (e.g. user message after interrupt)
      contentList = rawContent.isNotEmpty
          ? [TextContent(text: rawContent)]
          : [];
    } else {
      contentList = (rawContent as List? ?? [])
          .map((c) => AssistantContent.fromJson(c as Map<String, dynamic>))
          .toList();
    }
    return PastMessage(
      role: json['role'] as String? ?? '',
      uuid: json['uuid'] as String?,
      timestamp: json['timestamp'] as String?,
      isMeta: json['isMeta'] as bool? ?? false,
      imageCount: json['imageCount'] as int? ?? 0,
      toolUseId: json['toolUseId'] as String?,
      toolName: json['toolName'] as String?,
      images:
          (json['images'] as List?)
              ?.map((i) => ImageRef.fromJson(i as Map<String, dynamic>))
              .toList() ??
          const [],
      toolResultContent: rawContent is String ? rawContent : null,
      content: contentList,
      artifacts: _parseArtifactRefs(json['artifacts']),
    );
  }
}

// ---- Recent session (from sessions-index.json) ----

/// Display mode for session list cards.
enum SessionDisplayMode {
  first('First'),
  last('Last'),
  summary('Summary');

  final String label;
  const SessionDisplayMode(this.label);
}

String pathBasename(String path) {
  if (path.isEmpty) return path;
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty);
  final last = parts.isEmpty ? '' : parts.last;
  return last.isNotEmpty ? last : path;
}

class RecentSession {
  final String sessionId;
  final String? provider;
  final String? codexSourceId;
  final String? rawPermissionMode;
  final String? forkedFromThreadId;

  /// User-assigned session name (customTitle for Claude, thread_name for Codex).
  final String? name;
  final String? agentNickname;
  final String? agentRole;
  final String? summary;
  final String firstPrompt;
  final String? lastPrompt;
  final String created;
  final String modified;

  /// Mobile-local checkpoint for the newest discrete assistant text output.
  ///
  /// This is derived from the committed bounded timeline and deliberately
  /// stays separate from [modified], which may advance for tool traffic.
  final String? lastAssistantOutputAt;
  final String gitBranch;
  final String projectPath;
  final String? resumeCwd;
  final bool isSidechain;
  final String? codexApprovalPolicy;
  final String? codexApprovalsReviewer;
  final String? codexPermissionsMode;
  final String? executionMode;
  final bool planMode;
  final String? codexSandboxMode;
  final String? codexModel;
  final String? codexProfile;
  final String? codexModelReasoningEffort;
  final String? codexServiceTier;
  final bool? codexNetworkAccessEnabled;
  final String? codexWebSearchMode;
  final List<String> codexAdditionalWritableRoots;

  const RecentSession({
    required this.sessionId,
    this.provider,
    this.codexSourceId,
    this.rawPermissionMode,
    this.forkedFromThreadId,
    this.name,
    this.agentNickname,
    this.agentRole,
    this.summary,
    required this.firstPrompt,
    this.lastPrompt,
    required this.created,
    required this.modified,
    this.lastAssistantOutputAt,
    required this.gitBranch,
    required this.projectPath,
    this.resumeCwd,
    required this.isSidechain,
    this.codexApprovalPolicy,
    this.codexApprovalsReviewer,
    this.codexPermissionsMode,
    this.executionMode,
    this.planMode = false,
    this.codexSandboxMode,
    this.codexModel,
    this.codexProfile,
    this.codexModelReasoningEffort,
    this.codexServiceTier,
    this.codexNetworkAccessEnabled,
    this.codexWebSearchMode,
    this.codexAdditionalWritableRoots = const [],
  });

  ExecutionMode get resolvedExecutionMode => deriveExecutionMode(
    provider: provider,
    executionMode: executionMode,
    permissionMode: rawPermissionMode,
    approvalPolicy: codexApprovalPolicy,
  );

  bool get resolvedPlanMode => planMode;

  String get permissionMode => legacyPermissionModeFromModes(
    provider == Provider.codex.value ? Provider.codex : Provider.claude,
    executionMode: resolvedExecutionMode,
    planMode: resolvedPlanMode,
  ).value;

  String get effectivePermissionMode => rawPermissionMode?.isNotEmpty == true
      ? rawPermissionMode!
      : permissionMode;

  factory RecentSession.fromJson(Map<String, dynamic> json) {
    final codexSettings = json['codexSettings'] as Map<String, dynamic>?;
    return RecentSession(
      sessionId: json['sessionId'] as String,
      provider: json['provider'] as String?,
      codexSourceId: json['codexSourceId'] as String?,
      rawPermissionMode: json['permissionMode'] as String?,
      forkedFromThreadId: json['forkedFromThreadId'] as String?,
      name: json['name'] as String?,
      agentNickname: json['agentNickname'] as String?,
      agentRole: json['agentRole'] as String?,
      summary: json['summary'] as String?,
      firstPrompt: json['firstPrompt'] as String? ?? '',
      lastPrompt: json['lastPrompt'] as String?,
      created: json['created'] as String? ?? '',
      modified: json['modified'] as String? ?? '',
      lastAssistantOutputAt: json['lastAssistantOutputAt'] as String?,
      gitBranch: json['gitBranch'] as String? ?? '',
      projectPath: json['projectPath'] as String? ?? '',
      resumeCwd: json['resumeCwd'] as String?,
      isSidechain: json['isSidechain'] as bool? ?? false,
      codexApprovalPolicy: resolveCodexApprovalPolicy(
        approvalPolicy: codexSettings?['approvalPolicy'] as String?,
        executionMode: json['executionMode'] as String?,
      ),
      codexApprovalsReviewer: codexSettings?['approvalsReviewer'] as String?,
      codexPermissionsMode: _resolveCodexPermissionsMode(codexSettings),
      executionMode:
          json['executionMode'] as String? ??
          deriveExecutionMode(
            provider: json['provider'] as String?,
            permissionMode: json['permissionMode'] as String?,
            approvalPolicy: codexSettings?['approvalPolicy'] as String?,
          ).value,
      planMode: derivePlanMode(
        planMode: json['planMode'] as bool?,
        permissionMode: json['permissionMode'] as String?,
      ),
      codexSandboxMode: codexSettings?['sandboxMode'] as String?,
      codexModel: sanitizeCodexModelName(codexSettings?['model'] as String?),
      codexProfile: codexSettings?['profile'] as String?,
      codexModelReasoningEffort:
          codexSettings?['modelReasoningEffort'] as String?,
      codexServiceTier: codexSettings?['serviceTier'] as String?,
      codexNetworkAccessEnabled:
          codexSettings?['networkAccessEnabled'] as bool?,
      codexWebSearchMode: codexSettings?['webSearchMode'] as String?,
      codexAdditionalWritableRoots: _stringList(
        codexSettings?['additionalWritableRoots'],
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'provider': provider,
    'codexSourceId': codexSourceId,
    'permissionMode': rawPermissionMode,
    'forkedFromThreadId': forkedFromThreadId,
    'name': name,
    'agentNickname': agentNickname,
    'agentRole': agentRole,
    'summary': summary,
    'firstPrompt': firstPrompt,
    'lastPrompt': lastPrompt,
    'created': created,
    'modified': modified,
    'lastAssistantOutputAt': lastAssistantOutputAt,
    'gitBranch': gitBranch,
    'projectPath': projectPath,
    'resumeCwd': resumeCwd,
    'isSidechain': isSidechain,
    'executionMode': executionMode,
    'planMode': planMode,
    'codexSettings': {
      'approvalPolicy': codexApprovalPolicy,
      'approvalsReviewer': codexApprovalsReviewer,
      'codexPermissionsMode': codexPermissionsMode,
      'sandboxMode': codexSandboxMode,
      'model': codexModel,
      'profile': codexProfile,
      'modelReasoningEffort': codexModelReasoningEffort,
      'serviceTier': codexServiceTier,
      'networkAccessEnabled': codexNetworkAccessEnabled,
      'webSearchMode': codexWebSearchMode,
      'additionalWritableRoots': codexAdditionalWritableRoots,
    },
  };

  /// Extract project name from path (last segment)
  String get projectName {
    return pathBasename(projectPath);
  }

  /// Display text: summary if available, otherwise firstPrompt
  String get displayText {
    if (summary != null && summary!.isNotEmpty) return summary!;
    if (firstPrompt.isNotEmpty) return firstPrompt;
    if (name != null && name!.isNotEmpty) return name!;
    return projectName;
  }

  RecentSession copyWithLastAssistantOutputAt(String value) {
    return RecentSession(
      sessionId: sessionId,
      provider: provider,
      codexSourceId: codexSourceId,
      rawPermissionMode: rawPermissionMode,
      forkedFromThreadId: forkedFromThreadId,
      name: name,
      agentNickname: agentNickname,
      agentRole: agentRole,
      summary: summary,
      firstPrompt: firstPrompt,
      lastPrompt: lastPrompt,
      created: created,
      modified: modified,
      lastAssistantOutputAt: value,
      gitBranch: gitBranch,
      projectPath: projectPath,
      resumeCwd: resumeCwd,
      isSidechain: isSidechain,
      codexApprovalPolicy: codexApprovalPolicy,
      codexApprovalsReviewer: codexApprovalsReviewer,
      codexPermissionsMode: codexPermissionsMode,
      executionMode: executionMode,
      planMode: planMode,
      codexSandboxMode: codexSandboxMode,
      codexModel: codexModel,
      codexProfile: codexProfile,
      codexModelReasoningEffort: codexModelReasoningEffort,
      codexServiceTier: codexServiceTier,
      codexNetworkAccessEnabled: codexNetworkAccessEnabled,
      codexWebSearchMode: codexWebSearchMode,
      codexAdditionalWritableRoots: codexAdditionalWritableRoots,
    );
  }

  /// Create a copy with an updated name. Use [clearName] to set name to null.
  RecentSession copyWithName({String? name, bool clearName = false}) {
    return RecentSession(
      sessionId: sessionId,
      provider: provider,
      codexSourceId: codexSourceId,
      rawPermissionMode: rawPermissionMode,
      forkedFromThreadId: forkedFromThreadId,
      name: clearName ? null : (name ?? this.name),
      agentNickname: agentNickname,
      agentRole: agentRole,
      summary: summary,
      firstPrompt: firstPrompt,
      lastPrompt: lastPrompt,
      created: created,
      modified: modified,
      lastAssistantOutputAt: lastAssistantOutputAt,
      gitBranch: gitBranch,
      projectPath: projectPath,
      resumeCwd: resumeCwd,
      isSidechain: isSidechain,
      codexApprovalPolicy: codexApprovalPolicy,
      codexApprovalsReviewer: codexApprovalsReviewer,
      codexPermissionsMode: codexPermissionsMode,
      executionMode: executionMode,
      planMode: planMode,
      codexSandboxMode: codexSandboxMode,
      codexModel: codexModel,
      codexProfile: codexProfile,
      codexModelReasoningEffort: codexModelReasoningEffort,
      codexServiceTier: codexServiceTier,
      codexNetworkAccessEnabled: codexNetworkAccessEnabled,
      codexWebSearchMode: codexWebSearchMode,
      codexAdditionalWritableRoots: codexAdditionalWritableRoots,
    );
  }

  RecentSession copyWithCodexApprovalDefaults({
    required String approvalPolicy,
    required String approvalsReviewer,
    String? codexPermissionsMode,
  }) {
    return RecentSession(
      sessionId: sessionId,
      provider: provider,
      codexSourceId: codexSourceId,
      rawPermissionMode: rawPermissionMode,
      forkedFromThreadId: forkedFromThreadId,
      name: name,
      agentNickname: agentNickname,
      agentRole: agentRole,
      summary: summary,
      firstPrompt: firstPrompt,
      lastPrompt: lastPrompt,
      created: created,
      modified: modified,
      lastAssistantOutputAt: lastAssistantOutputAt,
      gitBranch: gitBranch,
      projectPath: projectPath,
      resumeCwd: resumeCwd,
      isSidechain: isSidechain,
      codexApprovalPolicy: approvalPolicy,
      codexApprovalsReviewer: approvalsReviewer,
      codexPermissionsMode: codexPermissionsMode ?? this.codexPermissionsMode,
      executionMode: executionMode,
      planMode: planMode,
      codexSandboxMode: codexSandboxMode,
      codexModel: codexModel,
      codexProfile: codexProfile,
      codexModelReasoningEffort: codexModelReasoningEffort,
      codexServiceTier: codexServiceTier,
      codexNetworkAccessEnabled: codexNetworkAccessEnabled,
      codexWebSearchMode: codexWebSearchMode,
      codexAdditionalWritableRoots: codexAdditionalWritableRoots,
    );
  }
}

// ---- Session info (for multi-session) ----

class SessionInfo {
  final String id;
  final String? provider;
  final String projectPath;
  final String? claudeSessionId;
  final String? forkedFromSessionId;
  final String? forkedFromThreadId;

  /// User-assigned session name.
  final String? name;
  final String? agentNickname;
  final String? agentRole;
  final String status;
  final String createdAt;
  final String lastActivityAt;
  final String? lastAssistantOutputAt;
  final String gitBranch;
  final String lastMessage;
  final String? worktreePath;
  final String? worktreeBranch;
  final String? permissionMode;
  final String? executionMode;
  final bool planMode;
  final String? model;
  final String? codexApprovalPolicy;
  final String? codexApprovalsReviewer;
  final String? codexPermissionsMode;
  final String? codexSandboxMode;
  final String? codexModel;
  final String? codexProfile;
  final String? codexModelReasoningEffort;
  final String? codexServiceTier;
  final bool? codexNetworkAccessEnabled;
  final String? codexWebSearchMode;
  final List<String> codexAdditionalWritableRoots;
  final bool codexPermissionApplyStrategySupported;

  /// True while an official Desktop rollout watcher owns the active turn.
  final bool externalDesktopTurnActive;
  final bool? codexNativePlanModeSupported;
  final bool? codexGoalControlSupported;
  final PermissionRequestMessage? pendingPermission;
  final QueuedInputItem? queuedInput;

  const SessionInfo({
    required this.id,
    this.provider,
    required this.projectPath,
    this.claudeSessionId,
    this.forkedFromSessionId,
    this.forkedFromThreadId,
    this.name,
    this.agentNickname,
    this.agentRole,
    required this.status,
    required this.createdAt,
    required this.lastActivityAt,
    this.lastAssistantOutputAt,
    this.gitBranch = '',
    this.lastMessage = '',
    this.worktreePath,
    this.worktreeBranch,
    this.permissionMode,
    this.executionMode,
    this.planMode = false,
    this.model,
    this.codexApprovalPolicy,
    this.codexApprovalsReviewer,
    this.codexPermissionsMode,
    this.codexSandboxMode,
    this.codexModel,
    this.codexProfile,
    this.codexModelReasoningEffort,
    this.codexServiceTier,
    this.codexNetworkAccessEnabled,
    this.codexWebSearchMode,
    this.codexAdditionalWritableRoots = const [],
    this.codexPermissionApplyStrategySupported = false,
    this.externalDesktopTurnActive = false,
    this.codexNativePlanModeSupported,
    this.codexGoalControlSupported,
    this.pendingPermission,
    this.queuedInput,
  });

  ExecutionMode get resolvedExecutionMode => deriveExecutionMode(
    provider: provider,
    executionMode: executionMode,
    permissionMode: permissionMode,
    approvalPolicy: codexApprovalPolicy,
  );

  bool get resolvedPlanMode =>
      planMode || permissionMode == PermissionMode.plan.value;

  String get effectivePermissionMode =>
      permissionMode ??
      legacyPermissionModeFromModes(
        provider == Provider.codex.value ? Provider.codex : Provider.claude,
        executionMode: resolvedExecutionMode,
        planMode: resolvedPlanMode,
      ).value;

  SessionInfo copyWith({
    String? status,
    String? name,
    bool clearName = false,
    String? lastMessage,
    String? lastActivityAt,
    String? lastAssistantOutputAt,
    String? permissionMode,
    String? executionMode,
    bool? planMode,
    String? model,
    String? codexApprovalPolicy,
    String? codexApprovalsReviewer,
    String? codexPermissionsMode,
    String? codexSandboxMode,
    String? codexModel,
    String? codexProfile,
    String? codexModelReasoningEffort,
    String? codexServiceTier,
    bool? codexNetworkAccessEnabled,
    String? codexWebSearchMode,
    List<String>? codexAdditionalWritableRoots,
    bool? codexPermissionApplyStrategySupported,
    bool? externalDesktopTurnActive,
    bool? codexNativePlanModeSupported,
    bool clearCodexNativePlanModeSupported = false,
    bool? codexGoalControlSupported,
    bool clearCodexGoalControlSupported = false,
    PermissionRequestMessage? pendingPermission,
    bool clearPermission = false,
    QueuedInputItem? queuedInput,
    bool clearQueuedInput = false,
  }) {
    return SessionInfo(
      id: id,
      provider: provider,
      projectPath: projectPath,
      claudeSessionId: claudeSessionId,
      forkedFromSessionId: forkedFromSessionId,
      forkedFromThreadId: forkedFromThreadId,
      name: clearName ? null : (name ?? this.name),
      agentNickname: agentNickname,
      agentRole: agentRole,
      status: status ?? this.status,
      createdAt: createdAt,
      lastActivityAt: lastActivityAt ?? this.lastActivityAt,
      lastAssistantOutputAt:
          lastAssistantOutputAt ?? this.lastAssistantOutputAt,
      gitBranch: gitBranch,
      lastMessage: lastMessage ?? this.lastMessage,
      worktreePath: worktreePath,
      worktreeBranch: worktreeBranch,
      permissionMode: permissionMode ?? this.permissionMode,
      executionMode: executionMode ?? this.executionMode,
      planMode: planMode ?? this.planMode,
      model: model ?? this.model,
      codexApprovalPolicy: codexApprovalPolicy ?? this.codexApprovalPolicy,
      codexApprovalsReviewer:
          codexApprovalsReviewer ?? this.codexApprovalsReviewer,
      codexPermissionsMode: codexPermissionsMode ?? this.codexPermissionsMode,
      codexSandboxMode: codexSandboxMode ?? this.codexSandboxMode,
      codexModel: codexModel ?? this.codexModel,
      codexProfile: codexProfile ?? this.codexProfile,
      codexModelReasoningEffort:
          codexModelReasoningEffort ?? this.codexModelReasoningEffort,
      codexServiceTier: codexServiceTier ?? this.codexServiceTier,
      codexNetworkAccessEnabled:
          codexNetworkAccessEnabled ?? this.codexNetworkAccessEnabled,
      codexWebSearchMode: codexWebSearchMode ?? this.codexWebSearchMode,
      codexAdditionalWritableRoots:
          codexAdditionalWritableRoots ?? this.codexAdditionalWritableRoots,
      codexPermissionApplyStrategySupported:
          codexPermissionApplyStrategySupported ??
          this.codexPermissionApplyStrategySupported,
      externalDesktopTurnActive:
          externalDesktopTurnActive ?? this.externalDesktopTurnActive,
      codexNativePlanModeSupported: clearCodexNativePlanModeSupported
          ? null
          : (codexNativePlanModeSupported ?? this.codexNativePlanModeSupported),
      codexGoalControlSupported: clearCodexGoalControlSupported
          ? null
          : (codexGoalControlSupported ?? this.codexGoalControlSupported),
      pendingPermission: clearPermission
          ? null
          : (pendingPermission ?? this.pendingPermission),
      queuedInput: clearQueuedInput ? null : (queuedInput ?? this.queuedInput),
    );
  }

  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    final codexSettings = json['codexSettings'] as Map<String, dynamic>?;
    final permJson = json['pendingPermission'] as Map<String, dynamic>?;
    final queueJson = json['queuedInput'] as Map<String, dynamic>?;
    return SessionInfo(
      id: json['id'] as String,
      provider: json['provider'] as String?,
      projectPath: json['projectPath'] as String,
      claudeSessionId: json['claudeSessionId'] as String?,
      forkedFromSessionId: json['forkedFromSessionId'] as String?,
      forkedFromThreadId: json['forkedFromThreadId'] as String?,
      name: json['name'] as String?,
      agentNickname: json['agentNickname'] as String?,
      agentRole: json['agentRole'] as String?,
      status: json['status'] as String? ?? 'idle',
      createdAt: json['createdAt'] as String? ?? '',
      lastActivityAt: json['lastActivityAt'] as String? ?? '',
      lastAssistantOutputAt: json['lastAssistantOutputAt'] as String?,
      gitBranch: json['gitBranch'] as String? ?? '',
      lastMessage: json['lastMessage'] as String? ?? '',
      worktreePath: json['worktreePath'] as String?,
      worktreeBranch: json['worktreeBranch'] as String?,
      permissionMode: json['permissionMode'] as String?,
      executionMode:
          json['executionMode'] as String? ??
          deriveExecutionMode(
            provider: json['provider'] as String?,
            permissionMode: json['permissionMode'] as String?,
            approvalPolicy: codexSettings?['approvalPolicy'] as String?,
          ).value,
      planMode: derivePlanMode(
        planMode: json['planMode'] as bool?,
        permissionMode: json['permissionMode'] as String?,
      ),
      model: json['model'] as String?,
      codexApprovalPolicy: resolveCodexApprovalPolicy(
        approvalPolicy: codexSettings?['approvalPolicy'] as String?,
        executionMode: json['executionMode'] as String?,
      ),
      codexApprovalsReviewer: codexSettings?['approvalsReviewer'] as String?,
      codexPermissionsMode: _resolveCodexPermissionsMode(codexSettings),
      codexSandboxMode: codexSettings?['sandboxMode'] as String?,
      codexModel: sanitizeCodexModelName(codexSettings?['model'] as String?),
      codexProfile: codexSettings?['profile'] as String?,
      codexModelReasoningEffort:
          codexSettings?['modelReasoningEffort'] as String?,
      codexServiceTier: codexSettings?['serviceTier'] as String?,
      codexNetworkAccessEnabled:
          codexSettings?['networkAccessEnabled'] as bool?,
      codexWebSearchMode: codexSettings?['webSearchMode'] as String?,
      codexAdditionalWritableRoots: _stringList(
        codexSettings?['additionalWritableRoots'],
      ),
      codexPermissionApplyStrategySupported:
          json['codexPermissionApplyStrategySupported'] as bool? ?? false,
      externalDesktopTurnActive:
          json['externalDesktopTurnActive'] as bool? ?? false,
      codexNativePlanModeSupported:
          json['codexNativePlanModeSupported'] as bool?,
      codexGoalControlSupported: json['codexGoalControlSupported'] as bool?,
      pendingPermission: _pendingPermissionFromJson(permJson),
      queuedInput: queueJson != null
          ? QueuedInputItem.fromJson(queueJson)
          : null,
    );
  }

  /// A malformed pendingPermission blob degrades to "no pending permission"
  /// instead of discarding the whole session entry.
  static PermissionRequestMessage? _pendingPermissionFromJson(
    Map<String, dynamic>? permJson,
  ) {
    if (permJson == null) return null;
    try {
      return PermissionRequestMessage(
        toolUseId: permJson['toolUseId'] as String,
        toolName: permJson['toolName'] as String,
        input: Map<String, dynamic>.from(permJson['input'] as Map),
      );
    } catch (_) {
      return null;
    }
  }
}

// ---- Client messages ----

enum ClientMessageDelivery { queued, ephemeral }

const turnAwareHistoryWindowCapability = 'turn_aware_history_window_v1';
const historyPageCapability = 'history_page_v1';
const historyToolDetailCapability = 'history_tool_detail_v1';
const sessionActivityAtCapability = 'session_activity_at_v1';
const sessionRequestCorrelationCapability = 'session_request_correlation_v1';
const sessionCatalogWatchCapability = 'session_catalog_watch_v1';
const promptHistoryRequestCorrelationCapability =
    'prompt_history_request_correlation_v1';
const sessionCatalogRequestCorrelationCapability =
    'session_catalog_request_correlation_v1';
const sessionCatalogChangedMessageType = 'session_catalog_changed_v1';
const sessionLinkProgressCapability = 'session_link_progress_v1';
const fileListRequestCorrelationCapability = 'file_list_request_correlation_v1';
const gitDiffRequestCorrelationCapability = 'git_diff_request_correlation_v1';
const gitProjectResultCorrelationCapability =
    'git_project_result_correlation_v1';
const inputDeliveryAckBridgeCapability = 'input_delivery_ack_v1';
const inputDeliveryStatusMessageType = 'input_delivery_status_v1';

class ClientMessage {
  final Map<String, dynamic> _json;
  final ClientMessageDelivery delivery;

  ClientMessage._(this._json, {this.delivery = ClientMessageDelivery.queued});
  factory ClientMessage.raw(Map<String, dynamic> json) =>
      ClientMessage._(Map<String, dynamic>.from(json));

  String get type => _json['type'] as String;
  String? get sessionId => _json['sessionId'] as String?;
  String? get permissionChangeId => _json['permissionChangeId'] as String?;
  String? get goalChangeId => _json['goalChangeId'] as String?;

  factory ClientMessage.clientCapabilities({
    String? appVersion,
    int protocolVersion = 1,
    bool fileTransferSupported = false,
    List<String>? supportedServerMessages,
    Map<String, dynamic>? mobileRuntime,
  }) {
    final advertisedMessages =
        supportedServerMessages ??
        <String>[
          'conversation_queue',
          inputDeliveryStatusMessageType,
          'goal_state',
          'goal_state_raw_status',
          'guardian_approval',
          'history_delta',
          'history_snapshot',
          'bounded_history_window_v1',
          turnAwareHistoryWindowCapability,
          historyPageCapability,
          historyToolDetailCapability,
          sessionActivityAtCapability,
          sessionRequestCorrelationCapability,
          sessionCatalogChangedMessageType,
          sessionLinkProgressCapability,
          'git_status_result',
          'prompt_history_status',
          'artifact_resolved',
          'client_delivery_mode_state_v1',
          'background_notification_v1',
          'background_activity_state_v1',
          'push_registration_state_v1',
          'archived_sessions_result',
          'unarchive_result',
          'delete_session_result',
          autoApprovalSupervisionCapability,
          ...LocalFeatureProtocolHost.supportedServerMessageTypes.where(
            (type) =>
                !fileTransferProtocolSlot.supportedServerMessageTypes.contains(
                  type,
                ) ||
                fileTransferSupported,
          ),
        ];
    return ClientMessage._(<String, dynamic>{
      'type': 'client_capabilities',
      'protocolVersion': protocolVersion,
      'appVersion': ?appVersion,
      if (advertisedMessages.isNotEmpty)
        'supportedServerMessages': advertisedMessages,
      'mobileRuntime': ?mobileRuntime,
    });
  }

  factory ClientMessage.setClientDeliveryMode({
    required BridgeClientDeliveryMode mode,
    required String requestId,
    String? locale,
    bool? privacyMode,
    List<String>? enabledEventTypes,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'set_client_delivery_mode',
    'mode': mode.wireValue,
    'requestId': requestId,
    'locale': ?locale,
    'privacyMode': ?privacyMode,
    'enabledEventTypes': ?enabledEventTypes,
  }, delivery: ClientMessageDelivery.ephemeral);

  factory ClientMessage.backgroundNotificationAck(String deliveryId) =>
      ClientMessage._(<String, dynamic>{
        'type': 'background_notification_ack_v1',
        'deliveryId': deliveryId,
      }, delivery: ClientMessageDelivery.ephemeral);

  factory ClientMessage.resolveArtifact({
    required String requestId,
    required String sessionId,
    required String messageId,
    required String artifactId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'resolve_artifact',
      'requestId': requestId,
      'sessionId': sessionId,
      'messageId': messageId,
      'artifactId': artifactId,
    });
  }

  factory ClientMessage.start(
    String projectPath, {
    String? sessionId,
    bool? continueMode,
    String? permissionMode,
    String? executionMode,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? codexPermissionsMode,
    bool? planMode,
    String? effort,
    int? maxTurns,
    double? maxBudgetUsd,
    String? fallbackModel,
    bool? forkSession,
    bool? persistSession,
    String? profile,
    bool? useWorktree,
    String? worktreeBranch,
    String? existingWorktreePath,
    String? provider,
    String? model,
    String? sandboxMode,
    String? modelReasoningEffort,
    String? serviceTier,
    bool? networkAccessEnabled,
    String? webSearchMode,
    List<String>? additionalWritableRoots,
    bool? autoRename,
    String? startRequestId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'start',
      'projectPath': projectPath,
      'sessionId': ?sessionId,
      if (continueMode == true) 'continue': true,
      'permissionMode': ?permissionMode,
      'executionMode': ?executionMode,
      'approvalPolicy': ?approvalPolicy,
      'approvalsReviewer': ?approvalsReviewer,
      'codexPermissionsMode': ?codexPermissionsMode,
      'planMode': ?planMode,
      'effort': ?effort,
      'maxTurns': ?maxTurns,
      'maxBudgetUsd': ?maxBudgetUsd,
      'fallbackModel': ?fallbackModel,
      'forkSession': ?forkSession,
      'persistSession': ?persistSession,
      'profile': ?profile,
      if (useWorktree == true) 'useWorktree': true,
      if (worktreeBranch != null && worktreeBranch.isNotEmpty)
        'worktreeBranch': worktreeBranch,
      'existingWorktreePath': ?existingWorktreePath,
      'provider': ?provider,
      'model': ?model,
      'sandboxMode': ?sandboxMode,
      'modelReasoningEffort': ?modelReasoningEffort,
      'serviceTier': ?serviceTier,
      'networkAccessEnabled': ?networkAccessEnabled,
      'webSearchMode': ?webSearchMode,
      if (additionalWritableRoots != null && additionalWritableRoots.isNotEmpty)
        'additionalWritableRoots': additionalWritableRoots,
      'autoRename': ?autoRename,
      'startRequestId': ?startRequestId,
    });
  }

  factory ClientMessage.input(
    String text, {
    String? sessionId,
    String? clientMessageId,
    int? baseSeq,
    List<Map<String, String>>? images,
    Map<String, String>? skill,
    List<Map<String, String>>? skills,
    List<Map<String, String>>? mentions,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'input',
      'text': text,
      'sessionId': ?sessionId,
      'clientMessageId': ?clientMessageId,
      'baseSeq': ?baseSeq,
      if (images != null && images.isNotEmpty) 'images': images,
      'skill': ?skill,
      if (skills != null && skills.isNotEmpty) 'skills': skills,
      if (mentions != null && mentions.isNotEmpty) 'mentions': mentions,
    });
  }

  factory ClientMessage.updateQueuedInput({
    required String sessionId,
    required String itemId,
    required String text,
    List<Map<String, String>>? skills,
    List<Map<String, String>>? mentions,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'update_queued_input',
      'sessionId': sessionId,
      'itemId': itemId,
      'text': text,
      if (skills != null && skills.isNotEmpty) 'skills': skills,
      if (mentions != null && mentions.isNotEmpty) 'mentions': mentions,
    });
  }

  factory ClientMessage.steerQueuedInput({
    required String sessionId,
    required String itemId,
    String? expectedTurnId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'steer_queued_input',
      'sessionId': sessionId,
      'itemId': itemId,
      'expectedTurnId': ?expectedTurnId,
    }, delivery: ClientMessageDelivery.ephemeral);
  }

  factory ClientMessage.cancelQueuedInput({
    required String sessionId,
    required String itemId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'cancel_queued_input',
      'sessionId': sessionId,
      'itemId': itemId,
    });
  }

  factory ClientMessage.pushRegister({
    required String token,
    required String platform,
    String? requestId,
    String? locale,
    bool? privacyMode,
    List<String>? enabledEventTypes,
    bool? approvalActionsSupported,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'push_register',
    'token': token,
    'platform': platform,
    'requestId': ?requestId,
    'locale': ?locale,
    'privacyMode': ?privacyMode,
    'enabledEventTypes': ?enabledEventTypes,
    'approvalActionsSupported': ?approvalActionsSupported,
  });

  factory ClientMessage.pushUnregister(String token, {String? requestId}) =>
      ClientMessage._(<String, dynamic>{
        'type': 'push_unregister',
        'token': token,
        'requestId': ?requestId,
      });

  factory ClientMessage.setPermissionMode(String mode, {String? sessionId}) {
    return ClientMessage._(<String, dynamic>{
      'type': 'set_permission_mode',
      'mode': mode,
      'sessionId': ?sessionId,
    });
  }

  factory ClientMessage.setSessionMode({
    required String legacyMode,
    String? executionMode,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? codexPermissionsMode,
    bool? planMode,
    CodexPermissionApplyStrategy? applyStrategy,
    String? permissionChangeId,
    String? sessionId,
  }) {
    return ClientMessage._(
      <String, dynamic>{
        'type': 'set_permission_mode',
        'mode': legacyMode,
        'executionMode': ?executionMode,
        'approvalPolicy': ?approvalPolicy,
        'approvalsReviewer': ?approvalsReviewer,
        'codexPermissionsMode': ?codexPermissionsMode,
        'planMode': ?planMode,
        'applyStrategy': ?applyStrategy?.value,
        'permissionChangeId': ?permissionChangeId,
        'sessionId': ?sessionId,
      },
      delivery: applyStrategy == null
          ? ClientMessageDelivery.queued
          : ClientMessageDelivery.ephemeral,
    );
  }

  factory ClientMessage.setCodexModel(
    String model, {
    String? modelReasoningEffort,
    String? sessionId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'set_codex_model',
      'model': model,
      'modelReasoningEffort': ?modelReasoningEffort,
      'sessionId': ?sessionId,
    });
  }

  factory ClientMessage.setCodexSpeed(String serviceTier, {String? sessionId}) {
    return ClientMessage._(<String, dynamic>{
      'type': 'set_codex_speed',
      'serviceTier': serviceTier,
      'sessionId': ?sessionId,
    });
  }

  factory ClientMessage.getGoal(String sessionId) => ClientMessage._({
    'type': 'get_goal',
    'sessionId': sessionId,
  }, delivery: ClientMessageDelivery.ephemeral);

  factory ClientMessage.setGoal({
    required String sessionId,
    String? objective,
    CodexThreadGoalStatus? status,
    int? tokenBudget,
    bool includeTokenBudget = false,
    String? goalChangeId,
    int? expectedGoalOperationSequence,
  }) => ClientMessage._({
    'type': 'set_goal',
    'sessionId': sessionId,
    'objective': ?objective,
    if (status != null) 'status': status.value,
    if (includeTokenBudget) 'tokenBudget': tokenBudget,
    'goalChangeId': ?goalChangeId,
    'expectedGoalOperationSequence': ?expectedGoalOperationSequence,
  }, delivery: ClientMessageDelivery.ephemeral);

  factory ClientMessage.clearGoal(
    String sessionId, {
    String? goalChangeId,
    int? expectedGoalOperationSequence,
  }) => ClientMessage._({
    'type': 'clear_goal',
    'sessionId': sessionId,
    'goalChangeId': ?goalChangeId,
    'expectedGoalOperationSequence': ?expectedGoalOperationSequence,
  }, delivery: ClientMessageDelivery.ephemeral);

  factory ClientMessage.setSandboxMode(
    String sandboxMode, {
    String? sessionId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'set_sandbox_mode',
      'sandboxMode': sandboxMode,
      'sessionId': ?sessionId,
    });
  }

  factory ClientMessage.approve(
    String id, {
    bool clearContext = false,
    String? sessionId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'approve',
      'id': id,
      if (clearContext) 'clearContext': true,
      'sessionId': ?sessionId,
    }, delivery: ClientMessageDelivery.ephemeral);
  }

  /// Sends the existing approve wire message only on the current live socket.
  ///
  /// Mobile automation must never replay an approval from the offline queue
  /// after its original request may have expired or changed.
  factory ClientMessage.approveLiveOnly(
    String id, {
    required String sessionId,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'approve',
    'id': id,
    'sessionId': sessionId,
  }, delivery: ClientMessageDelivery.ephemeral);

  factory ClientMessage.approveAlways(String id, {String? sessionId}) =>
      ClientMessage._(<String, dynamic>{
        'type': 'approve_always',
        'id': id,
        'sessionId': ?sessionId,
      }, delivery: ClientMessageDelivery.ephemeral);

  factory ClientMessage.reject(
    String id, {
    String? message,
    String? sessionId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'reject',
      'id': id,
      'message': ?message,
      'sessionId': ?sessionId,
    }, delivery: ClientMessageDelivery.ephemeral);
  }

  factory ClientMessage.rejectLiveOnly(
    String id, {
    required String sessionId,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'reject',
    'id': id,
    'sessionId': sessionId,
  }, delivery: ClientMessageDelivery.ephemeral);

  factory ClientMessage.answer(
    String toolUseId,
    String result, {
    String? sessionId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'answer',
      'toolUseId': toolUseId,
      'result': result,
      'sessionId': ?sessionId,
    }, delivery: ClientMessageDelivery.ephemeral);
  }

  factory ClientMessage.installToolSuggestion(
    String toolUseId, {
    String? sessionId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'install_tool_suggestion',
      'toolUseId': toolUseId,
      'sessionId': ?sessionId,
    }, delivery: ClientMessageDelivery.ephemeral);
  }

  factory ClientMessage.getHistory(String sessionId) =>
      ClientMessage._({'type': 'get_history', 'sessionId': sessionId});

  factory ClientMessage.getHistoryDelta(
    String sessionId, {
    required int sinceSeq,
  }) => ClientMessage._({
    'type': 'get_history_delta',
    'sessionId': sessionId,
    'sinceSeq': sinceSeq,
  });

  factory ClientMessage.getHistoryPage({
    required String requestId,
    required String sessionId,
    required int beforeSeq,
    String? beforeCursor,
  }) => ClientMessage._({
    'type': 'get_history_page',
    'requestId': requestId,
    'sessionId': sessionId,
    'beforeSeq': beforeSeq,
    'beforeCursor': ?beforeCursor,
  });

  factory ClientMessage.getHistoryToolDetails({
    required String requestId,
    required String sessionId,
    required List<String> toolUseIds,
  }) => ClientMessage._({
    'type': 'get_history_tool_details',
    'requestId': requestId,
    'sessionId': sessionId,
    'toolUseIds': toolUseIds,
  });

  factory ClientMessage.resolveSessionLink({
    required String requestId,
    required String sessionId,
    String? provider,
    int? sessionLinkGeneration,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'resolve_session_link',
    'requestId': requestId,
    'sessionId': sessionId,
    'provider': ?provider,
    'sessionLinkGeneration': ?sessionLinkGeneration,
  });

  factory ClientMessage.refreshBranch(String sessionId) =>
      ClientMessage._({'type': 'refresh_branch', 'sessionId': sessionId});

  factory ClientMessage.getDebugBundle(
    String sessionId, {
    int? traceLimit,
    bool? includeDiff,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'get_debug_bundle',
    'sessionId': sessionId,
    'traceLimit': ?traceLimit,
    'includeDiff': ?includeDiff,
  });

  factory ClientMessage.listSessions() =>
      ClientMessage._({'type': 'list_sessions'});

  factory ClientMessage.stopSession(String sessionId) =>
      ClientMessage._({'type': 'stop_session', 'sessionId': sessionId});

  /// Rename a session. For running sessions, sessionId is the bridge session id.
  /// For recent sessions, include provider, providerSessionId, and projectPath.
  factory ClientMessage.renameSession({
    required String sessionId,
    String? name,
    String? provider,
    String? providerSessionId,
    String? projectPath,
    String? codexSourceId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'rename_session',
      'sessionId': sessionId,
      'name': ?name,
      'provider': ?provider,
      'providerSessionId': ?providerSessionId,
      'projectPath': ?projectPath,
      'codexSourceId': ?codexSourceId,
    });
  }

  factory ClientMessage.listRecentSessions({
    int? limit,
    int? offset,
    String? projectPath,
    String? requestScope,
    String? requestId,
    int? queryGeneration,
    String? provider,
    bool? namedOnly,
    String? searchQuery,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'list_recent_sessions',
      'limit': ?limit,
      'offset': ?offset,
      'projectPath': ?projectPath,
      'requestScope': ?requestScope,
      'requestId': ?requestId,
      'queryGeneration': ?queryGeneration,
      'provider': ?provider,
      'namedOnly': ?namedOnly,
      'searchQuery': ?searchQuery,
    });
  }

  factory ClientMessage.resumeSession(
    String sessionId,
    String projectPath, {
    String? permissionMode,
    String? executionMode,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? codexPermissionsMode,
    bool? planMode,
    String? effort,
    int? maxTurns,
    double? maxBudgetUsd,
    String? fallbackModel,
    bool? forkSession,
    bool? persistSession,
    String? profile,
    String? provider,
    String? sandboxMode,
    String? model,
    String? modelReasoningEffort,
    String? serviceTier,
    bool? networkAccessEnabled,
    String? webSearchMode,
    List<String>? additionalWritableRoots,
    String? resumeRequestId,
    String? codexSourceId,
    int? sessionLinkGeneration,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'resume_session',
      'sessionId': sessionId,
      'projectPath': projectPath,
      'permissionMode': ?permissionMode,
      'executionMode': ?executionMode,
      'approvalPolicy': ?approvalPolicy,
      'approvalsReviewer': ?approvalsReviewer,
      'codexPermissionsMode': ?codexPermissionsMode,
      'planMode': ?planMode,
      'effort': ?effort,
      'maxTurns': ?maxTurns,
      'maxBudgetUsd': ?maxBudgetUsd,
      'fallbackModel': ?fallbackModel,
      'forkSession': ?forkSession,
      'persistSession': ?persistSession,
      'profile': ?profile,
      'provider': ?provider,
      'sandboxMode': ?sandboxMode,
      'model': ?model,
      'modelReasoningEffort': ?modelReasoningEffort,
      'serviceTier': ?serviceTier,
      'networkAccessEnabled': ?networkAccessEnabled,
      'webSearchMode': ?webSearchMode,
      'resumeRequestId': ?resumeRequestId,
      'codexSourceId': ?codexSourceId,
      'sessionLinkGeneration': ?sessionLinkGeneration,
      if (additionalWritableRoots != null && additionalWritableRoots.isNotEmpty)
        'additionalWritableRoots': additionalWritableRoots,
    });
  }

  factory ClientMessage.listGallery({String? project, String? sessionId}) =>
      ClientMessage._(<String, dynamic>{
        'type': 'list_gallery',
        'project': ?project,
        'sessionId': ?sessionId,
      });

  factory ClientMessage.readFile(
    String projectPath,
    String filePath, {
    String? requestId,
    int? maxLines,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'read_file',
    'requestId': ?requestId,
    'projectPath': projectPath,
    'filePath': filePath,
    'maxLines': ?maxLines,
  });

  factory ClientMessage.readArtifactSource({
    required String requestId,
    required String sessionId,
    required String messageId,
    required String artifactId,
    required String filePath,
    int? maxLines,
  }) {
    if ([
      requestId,
      sessionId,
      messageId,
      artifactId,
      filePath,
    ].any((value) => value.trim().isEmpty)) {
      throw ArgumentError('Artifact source request is incomplete.');
    }
    return ClientMessage._(<String, dynamic>{
      'type': 'read_artifact_source',
      'requestId': requestId,
      'sessionId': sessionId,
      'messageId': messageId,
      'artifactId': artifactId,
      'filePath': filePath,
      'maxLines': ?maxLines,
    });
  }

  factory ClientMessage.listFiles(String projectPath, {String? requestId}) =>
      ClientMessage._(<String, dynamic>{
        'type': 'list_files',
        'projectPath': projectPath,
        'requestId': ?requestId,
      });

  factory ClientMessage.getDiff(
    String projectPath, {
    bool? staged,
    String? requestId,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'get_diff',
    'projectPath': projectPath,
    'staged': ?staged,
    'requestId': ?requestId,
  });

  factory ClientMessage.getDiffImage(
    String projectPath,
    String filePath,
    String version, {
    String? requestId,
  }) => ClientMessage._({
    'type': 'get_diff_image',
    'projectPath': projectPath,
    'filePath': filePath,
    'version': version,
    'requestId': ?requestId,
  });

  factory ClientMessage.interrupt({String? sessionId}) => ClientMessage._(
    <String, dynamic>{'type': 'interrupt', 'sessionId': ?sessionId},
  );

  factory ClientMessage.listProjectHistory() =>
      ClientMessage._({'type': 'list_project_history'});

  factory ClientMessage.removeProjectHistory(String projectPath) =>
      ClientMessage._({
        'type': 'remove_project_history',
        'projectPath': projectPath,
      });

  factory ClientMessage.listWorktrees(String projectPath) =>
      ClientMessage._({'type': 'list_worktrees', 'projectPath': projectPath});

  factory ClientMessage.removeWorktree(
    String projectPath,
    String worktreePath,
  ) => ClientMessage._({
    'type': 'remove_worktree',
    'projectPath': projectPath,
    'worktreePath': worktreePath,
  });

  factory ClientMessage.rewind(
    String sessionId,
    String targetUuid,
    String mode,
  ) => ClientMessage._({
    'type': 'rewind',
    'sessionId': sessionId,
    'targetUuid': targetUuid,
    'mode': mode,
  });

  factory ClientMessage.rewindDryRun(String sessionId, String targetUuid) =>
      ClientMessage._({
        'type': 'rewind_dry_run',
        'sessionId': sessionId,
        'targetUuid': targetUuid,
      });

  factory ClientMessage.forkSession(String sessionId, String targetUuid) =>
      ClientMessage._({
        'type': 'fork',
        'sessionId': sessionId,
        'targetUuid': targetUuid,
      });

  /// Fork a persisted Codex thread that is not currently a Bridge runtime.
  /// Older apps keep using [forkSession]; a newer Bridge recognizes the
  /// additional projectPath and creates an ordinary persisted Codex session.
  factory ClientMessage.forkRecentSession({
    required String threadId,
    required String projectPath,
    String? codexSourceId,
  }) => ClientMessage._({
    'type': 'fork',
    'sessionId': threadId,
    'targetUuid': 'codex:user-turn:latest',
    'projectPath': projectPath,
    'codexSourceId': ?codexSourceId,
  });

  factory ClientMessage.listWindows() =>
      ClientMessage._({'type': 'list_windows'});

  factory ClientMessage.getUsage() => ClientMessage._({'type': 'get_usage'});

  factory ClientMessage.listRecordings() =>
      ClientMessage._({'type': 'list_recordings'});

  factory ClientMessage.getRecording(String sessionId) =>
      ClientMessage._({'type': 'get_recording', 'sessionId': sessionId});

  factory ClientMessage.getMessageImages({
    required String claudeSessionId,
    required String messageUuid,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'get_message_images',
    'claudeSessionId': claudeSessionId,
    'messageUuid': messageUuid,
  });

  factory ClientMessage.takeScreenshot({
    required String mode,
    int? windowId,
    required String projectPath,
    String? sessionId,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'take_screenshot',
    'mode': mode,
    'projectPath': projectPath,
    'windowId': ?windowId,
    'sessionId': ?sessionId,
  });

  factory ClientMessage.backupPromptHistory({
    required String data,
    required String appVersion,
    required int dbVersion,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'backup_prompt_history',
    'data': data,
    'appVersion': appVersion,
    'dbVersion': dbVersion,
  });

  factory ClientMessage.restorePromptHistory() =>
      ClientMessage._({'type': 'restore_prompt_history'});

  factory ClientMessage.getPromptHistoryBackupInfo() =>
      ClientMessage._({'type': 'get_prompt_history_backup_info'});

  factory ClientMessage.recordPromptHistory({
    required String text,
    required String clientId,
    String? projectPath,
    String? clientName,
    String? sessionId,
    String? usedAt,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'record_prompt_history',
    'text': text,
    'projectPath': ?projectPath,
    'clientId': clientId,
    'clientName': ?clientName,
    'sessionId': ?sessionId,
    'usedAt': ?usedAt,
  });

  factory ClientMessage.syncPromptHistory({
    required String clientId,
    String? requestId,
    String? clientName,
    int? sinceRevision,
    bool includeDeleted = true,
    List<PromptHistoryServerEntry> entries = const [],
  }) => ClientMessage._(
    <String, dynamic>{
      'type': 'sync_prompt_history',
      'requestId': ?requestId,
      'clientId': clientId,
      'clientName': ?clientName,
      'sinceRevision': ?sinceRevision,
      'includeDeleted': includeDeleted,
      if (entries.isNotEmpty)
        'entries': entries.map((entry) => entry.toJson()).toList(),
    },
    // A read-only snapshot is meaningful only to the live listener that
    // requested it. Never replay it after a reconnect with no waiter.
    delivery: ClientMessageDelivery.ephemeral,
  );

  factory ClientMessage.mutatePromptHistory({
    String? id,
    String? text,
    String? projectPath,
    required String action,
    bool? isFavorite,
    String? updatedAt,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'mutate_prompt_history',
    'id': ?id,
    'text': ?text,
    'projectPath': ?projectPath,
    'action': action,
    'isFavorite': ?isFavorite,
    'updatedAt': ?updatedAt,
  });

  factory ClientMessage.importPromptHistoryV1({
    required String clientId,
    String? requestId,
    String? clientName,
    required List<PromptHistoryServerEntry> entries,
  }) => ClientMessage._(
    <String, dynamic>{
      'type': 'import_prompt_history_v1',
      'requestId': ?requestId,
      'clientId': clientId,
      'clientName': ?clientName,
      'entries': entries.map((entry) => entry.toJson()).toList(),
    },
    // The operation is correlated by its live response lane. Replaying it on
    // another socket could make a later snapshot consume the stale response.
    delivery: ClientMessageDelivery.ephemeral,
  );

  factory ClientMessage.archiveSession({
    required String sessionId,
    required String provider,
    required String projectPath,
    String? requestId,
    String? name,
    String? summary,
    String? firstPrompt,
    String? modified,
    String? codexSourceId,
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': 'archive_session',
      'requestId': ?requestId,
      'sessionId': sessionId,
      'provider': provider,
      'projectPath': projectPath,
      'name': ?name,
      'summary': ?summary,
      'firstPrompt': ?firstPrompt,
      'modified': ?modified,
      'codexSourceId': ?codexSourceId,
    }, delivery: ClientMessageDelivery.ephemeral);
  }

  factory ClientMessage.listArchivedSessions({required String requestId}) =>
      ClientMessage._({
        'type': 'list_archived_sessions',
        'requestId': requestId,
      }, delivery: ClientMessageDelivery.ephemeral);

  factory ClientMessage.unarchiveSession({
    required String requestId,
    required String sessionId,
    required String provider,
    required String projectPath,
    String? codexSourceId,
  }) => ClientMessage._({
    'type': 'unarchive_session',
    'requestId': requestId,
    'sessionId': sessionId,
    'provider': provider,
    'projectPath': projectPath,
    'codexSourceId': ?codexSourceId,
  }, delivery: ClientMessageDelivery.ephemeral);

  factory ClientMessage.deleteSession({
    required String requestId,
    required String sessionId,
    required String projectPath,
    String? codexSourceId,
  }) => ClientMessage._({
    'type': 'delete_session',
    'requestId': requestId,
    'sessionId': sessionId,
    'provider': 'codex',
    'projectPath': projectPath,
    'confirmDescendantDeletion': true,
    'codexSourceId': ?codexSourceId,
  }, delivery: ClientMessageDelivery.ephemeral);

  // ---- Git Operations (Phase 1-3) ----

  factory ClientMessage.gitStage(
    String projectPath, {
    List<String>? files,
    List<Map<String, dynamic>>? hunks,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'git_stage',
    'projectPath': projectPath,
    'files': ?files,
    'hunks': ?hunks,
  });

  factory ClientMessage.gitUnstage(String projectPath, {List<String>? files}) =>
      ClientMessage._(<String, dynamic>{
        'type': 'git_unstage',
        'projectPath': projectPath,
        'files': ?files,
      });

  factory ClientMessage.gitUnstageHunks(
    String projectPath,
    List<Map<String, dynamic>> hunks,
  ) => ClientMessage._(<String, dynamic>{
    'type': 'git_unstage_hunks',
    'projectPath': projectPath,
    'hunks': hunks,
  });

  factory ClientMessage.gitCommit(
    String projectPath, {
    String? sessionId,
    String? message,
    bool? autoGenerate,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'git_commit',
    'projectPath': projectPath,
    'sessionId': ?sessionId,
    'message': ?message,
    'autoGenerate': ?autoGenerate,
  });

  factory ClientMessage.gitPush(String projectPath) => ClientMessage._(
    <String, dynamic>{'type': 'git_push', 'projectPath': projectPath},
  );

  factory ClientMessage.gitBranches(String projectPath) => ClientMessage._(
    <String, dynamic>{'type': 'git_branches', 'projectPath': projectPath},
  );

  factory ClientMessage.gitCreateBranch(
    String projectPath,
    String name, {
    bool? checkout,
  }) => ClientMessage._(<String, dynamic>{
    'type': 'git_create_branch',
    'projectPath': projectPath,
    'name': name,
    'checkout': ?checkout,
  });

  factory ClientMessage.gitCheckoutBranch(String projectPath, String branch) =>
      ClientMessage._({
        'type': 'git_checkout_branch',
        'projectPath': projectPath,
        'branch': branch,
      });

  factory ClientMessage.gitRevertFile(String projectPath, List<String> files) =>
      ClientMessage._({
        'type': 'git_revert_file',
        'projectPath': projectPath,
        'files': files,
      });

  factory ClientMessage.gitRevertHunks(
    String projectPath,
    List<Map<String, dynamic>> hunks,
  ) => ClientMessage._({
    'type': 'git_revert_hunks',
    'projectPath': projectPath,
    'hunks': hunks,
  });

  factory ClientMessage.gitFetch(String projectPath) =>
      ClientMessage._({'type': 'git_fetch', 'projectPath': projectPath});

  factory ClientMessage.gitPull(String projectPath) =>
      ClientMessage._({'type': 'git_pull', 'projectPath': projectPath});

  factory ClientMessage.gitStatus(
    String projectPath, {
    String? sessionId,
    bool includeRemote = false,
  }) => ClientMessage._({
    'type': 'git_status',
    'projectPath': projectPath,
    'sessionId': ?sessionId,
    if (includeRemote) 'includeRemote': true,
  });

  factory ClientMessage.gitRemoteStatus(String projectPath) => ClientMessage._({
    'type': 'git_remote_status',
    'projectPath': projectPath,
  });

  String toJson() => jsonEncode(_json);
}

// ---- Chat entry (for UI display) ----

sealed class ChatEntry {
  DateTime get timestamp;
  bool get timestampIsAuthoritative;
}

class ServerChatEntry implements ChatEntry {
  final ServerMessage message;
  @override
  final DateTime timestamp;
  @override
  final bool timestampIsAuthoritative;
  ServerChatEntry(
    this.message, {
    DateTime? timestamp,
    bool? timestampIsAuthoritative,
  }) : timestamp =
           timestamp ??
           serverMessageTimestamp(message)?.value.toLocal() ??
           DateTime.now(),
       timestampIsAuthoritative =
           timestampIsAuthoritative ??
           (timestamp == null &&
               (serverMessageTimestamp(message)?.isAuthoritative ?? false));
}

class UserChatEntry implements ChatEntry {
  final String text;
  final String? sessionId;
  final String? clientMessageId;
  final List<Uint8List> imageBytesList;
  final List<String> imageUrls;
  MessageStatus status;

  /// Number of images attached to this user message (from history restoration).
  final int imageCount;

  /// UUID assigned by the SDK for this user message (set when tool_result arrives).
  String? messageUuid;
  @override
  final DateTime timestamp;
  @override
  final bool timestampIsAuthoritative;
  UserChatEntry(
    this.text, {
    DateTime? timestamp,
    this.timestampIsAuthoritative = false,
    this.sessionId,
    this.clientMessageId,
    List<Uint8List>? imageBytesList,
    List<String>? imageUrls,
    this.imageCount = 0,
    this.status = MessageStatus.sending,
    this.messageUuid,
  }) : imageBytesList = imageBytesList ?? const [],
       imageUrls = imageUrls ?? const [],
       timestamp = timestamp ?? DateTime.now();
}

class StreamingChatEntry implements ChatEntry {
  String text;
  @override
  final DateTime timestamp;
  @override
  final bool timestampIsAuthoritative;
  StreamingChatEntry({
    this.text = '',
    DateTime? timestamp,
    this.timestampIsAuthoritative = false,
  }) : timestamp = timestamp ?? DateTime.now();
}
