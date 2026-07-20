import 'dart:async';
import 'dart:typed_data';

import '../../../models/messages.dart';
import '../../chat_session/state/chat_session_cubit.dart';
import '../../chat_session/state/chat_session_state.dart';

enum CodexSessionUiIntent {
  manage,
  edit,
  permissions,
  plan,
  planUnavailable,
  skills,
  compact,
  review,
  mcp,
  model,
  context,
}

typedef CodexGoalUiIntent = CodexSessionUiIntent;

/// Codex-specific session cubit.
///
/// Extends [ChatSessionCubit] so that shared widgets
/// (`ChatMessageList`, `ChatInputWithOverlays`, etc.) that read
/// `context.read<ChatSessionCubit>()` continue to work.
///
class CodexSessionCubit extends ChatSessionCubit {
  final _uiIntentController =
      StreamController<CodexSessionUiIntent>.broadcast();

  Stream<CodexSessionUiIntent> get uiIntents => _uiIntentController.stream;
  Stream<CodexGoalUiIntent> get goalUiIntents => _uiIntentController.stream;

  CodexSessionCubit({
    required super.sessionId,
    required super.bridge,
    required super.streamingCubit,
    super.initialExplorerCurrentPath,
    super.initialRecentPeekedFiles,
    super.initialSandboxMode,
    super.initialPermissionMode,
    super.initialCodexApprovalPolicy,
    super.initialCodexApprovalsReviewer,
    super.initialCodexPermissionsMode,
    super.initialProjectPath,
  }) : super(provider: Provider.codex);

  @override
  void sendMessage(
    String text, {
    List<({Uint8List bytes, String mimeType})>? images,
    Iterable<String>? mentionablePaths,
    Iterable<Map<String, String>>? additionalMentions,
  }) {
    if ((images == null || images.isEmpty) &&
        (additionalMentions == null || additionalMentions.isEmpty)) {
      switch (text.trim()) {
        case '/goal':
          requestGoal(userInitiated: true);
          _uiIntentController.add(CodexSessionUiIntent.manage);
          return;
        case '/goal edit':
          requestGoal(userInitiated: true);
          _uiIntentController.add(CodexSessionUiIntent.edit);
          return;
        case '/permissions':
          _uiIntentController.add(CodexSessionUiIntent.permissions);
          return;
        case '/plan':
          _uiIntentController.add(
            state.codexNativePlanModeSupport ==
                        CodexNativePlanModeSupport.unsupported &&
                    !state.planMode
                ? CodexSessionUiIntent.planUnavailable
                : CodexSessionUiIntent.plan,
          );
          return;
        case '/skills':
          _uiIntentController.add(CodexSessionUiIntent.skills);
          return;
        case '/compact':
          _uiIntentController.add(CodexSessionUiIntent.compact);
          return;
        case '/review':
          _uiIntentController.add(CodexSessionUiIntent.review);
          return;
        case '/mcp':
          _uiIntentController.add(CodexSessionUiIntent.mcp);
          return;
        case '/model':
          _uiIntentController.add(CodexSessionUiIntent.model);
          return;
        case '/context':
          _uiIntentController.add(CodexSessionUiIntent.context);
          return;
      }
    }
    super.sendMessage(
      text,
      images: images,
      mentionablePaths: mentionablePaths,
      additionalMentions: additionalMentions,
    );
  }

  @override
  Future<void> close() {
    _uiIntentController.close();
    return super.close();
  }
}
