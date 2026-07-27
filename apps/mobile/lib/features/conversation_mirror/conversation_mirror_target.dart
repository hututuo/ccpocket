import 'package:flutter/foundation.dart';

import '../../models/messages.dart';
import 'storage/conversation_mirror_models.dart';

/// Stable, feature-local description of a conversation that can be resident.
///
/// Runtime IDs are optional metadata only. Mirror identity always uses the
/// provider thread ID, so a running card, recent card, and resumed chat all
/// address the same durable phone copy.
@immutable
class ConversationMirrorTarget {
  const ConversationMirrorTarget({
    required this.provider,
    required this.providerSessionId,
    this.codexSourceId,
    required this.projectPath,
    this.resumeCwd,
    this.runtimeSessionId,
    this.name,
    this.agentNickname,
    this.agentRole,
    this.summary,
    this.firstPrompt = '',
    this.lastPrompt,
    this.created = '',
    this.modified = '',
    this.gitBranch = '',
    this.rawPermissionMode,
    this.executionMode,
    this.planMode = false,
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
  });

  final String provider;
  final String providerSessionId;
  final String? codexSourceId;
  final String projectPath;
  final String? resumeCwd;
  final String? runtimeSessionId;
  final String? name;
  final String? agentNickname;
  final String? agentRole;
  final String? summary;
  final String firstPrompt;
  final String? lastPrompt;
  final String created;
  final String modified;
  final String gitBranch;
  final String? rawPermissionMode;
  final String? executionMode;
  final bool planMode;
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

  String get effectiveProjectPath =>
      resumeCwd?.isNotEmpty == true ? resumeCwd! : projectPath;

  factory ConversationMirrorTarget.fromRecent(RecentSession session) =>
      ConversationMirrorTarget(
        provider: session.provider ?? Provider.claude.value,
        providerSessionId: session.sessionId,
        codexSourceId: session.codexSourceId,
        projectPath: session.projectPath,
        resumeCwd: session.resumeCwd,
        name: session.name,
        agentNickname: session.agentNickname,
        agentRole: session.agentRole,
        summary: session.summary,
        firstPrompt: session.firstPrompt,
        lastPrompt: session.lastPrompt,
        created: session.created,
        modified: session.modified,
        gitBranch: session.gitBranch,
        rawPermissionMode: session.rawPermissionMode,
        executionMode: session.executionMode,
        planMode: session.planMode,
        codexApprovalPolicy: session.codexApprovalPolicy,
        codexApprovalsReviewer: session.codexApprovalsReviewer,
        codexPermissionsMode: session.codexPermissionsMode,
        codexSandboxMode: session.codexSandboxMode,
        codexModel: session.codexModel,
        codexProfile: session.codexProfile,
        codexModelReasoningEffort: session.codexModelReasoningEffort,
        codexServiceTier: session.codexServiceTier,
        codexNetworkAccessEnabled: session.codexNetworkAccessEnabled,
        codexWebSearchMode: session.codexWebSearchMode,
        codexAdditionalWritableRoots: session.codexAdditionalWritableRoots,
      );

  /// Returns null until a new runtime has announced its durable provider ID.
  static ConversationMirrorTarget? fromRunning(
    SessionInfo session, {
    String? providerSessionId,
    String? codexSourceId,
  }) {
    final provider = session.provider ?? Provider.claude.value;
    final durableId =
        providerSessionId?.trim() ?? session.claudeSessionId?.trim();
    if (durableId == null || durableId.isEmpty) return null;
    return ConversationMirrorTarget(
      provider: provider,
      providerSessionId: durableId,
      codexSourceId: provider == Provider.codex.value ? codexSourceId : null,
      projectPath: session.projectPath,
      resumeCwd: session.worktreePath,
      runtimeSessionId: session.id,
      name: session.name,
      agentNickname: session.agentNickname,
      agentRole: session.agentRole,
      firstPrompt: session.lastMessage,
      lastPrompt: session.lastMessage,
      created: session.createdAt,
      modified: session.lastActivityAt,
      gitBranch: session.worktreeBranch ?? session.gitBranch,
      rawPermissionMode: session.permissionMode,
      executionMode: session.executionMode,
      planMode: session.planMode,
      codexApprovalPolicy: session.codexApprovalPolicy,
      codexApprovalsReviewer: session.codexApprovalsReviewer,
      codexPermissionsMode: session.codexPermissionsMode,
      codexSandboxMode: session.codexSandboxMode,
      codexModel: session.codexModel ?? session.model,
      codexProfile: session.codexProfile,
      codexModelReasoningEffort: session.codexModelReasoningEffort,
      codexServiceTier: session.codexServiceTier,
      codexNetworkAccessEnabled: session.codexNetworkAccessEnabled,
      codexWebSearchMode: session.codexWebSearchMode,
      codexAdditionalWritableRoots: session.codexAdditionalWritableRoots,
    );
  }

  factory ConversationMirrorTarget.fromMetadata(
    ConversationMirrorMetadata metadata,
  ) => ConversationMirrorTarget(
    provider: metadata.key.provider,
    providerSessionId: metadata.key.providerSessionId,
    projectPath: metadata.projectPath,
    created: metadata.lastSyncedAt?.toIso8601String() ?? '',
    modified: metadata.lastSyncedAt?.toIso8601String() ?? '',
  );

  RecentSession toRecentSession() => RecentSession(
    sessionId: providerSessionId,
    provider: provider,
    codexSourceId: codexSourceId,
    rawPermissionMode: rawPermissionMode,
    name: name,
    agentNickname: agentNickname,
    agentRole: agentRole,
    summary: summary,
    firstPrompt: firstPrompt,
    lastPrompt: lastPrompt,
    created: created,
    modified: modified,
    gitBranch: gitBranch,
    projectPath: projectPath,
    resumeCwd: resumeCwd,
    isSidechain: false,
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
