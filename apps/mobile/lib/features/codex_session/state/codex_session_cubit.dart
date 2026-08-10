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
  compactImmediately,
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
    super.detachedPreview,
    super.initialHistoryMessages,
    super.detachedHistoryPageLoader,
    super.detachedHistoryToolDetailLoader,
    super.detachedUserMessageIndexLoader,
    super.detachedUserTurnLoader,
    super.detachedRuntimeOverlayStream,
    super.initialHistoryHasEarlier,
    super.initialLiveRuntimeSessionId,
  }) : super(provider: Provider.codex);

  @override
  bool sendMessage(
    String text, {
    String? clientMessageId,
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
          return true;
        case '/goal edit':
          requestGoal(userInitiated: true);
          _uiIntentController.add(CodexSessionUiIntent.edit);
          return true;
        case '/permissions':
          _uiIntentController.add(CodexSessionUiIntent.permissions);
          return true;
        case '/plan':
          _uiIntentController.add(
            state.codexNativePlanModeSupport ==
                        CodexNativePlanModeSupport.unsupported &&
                    !state.planMode
                ? CodexSessionUiIntent.planUnavailable
                : CodexSessionUiIntent.plan,
          );
          return true;
        case '/skills':
          _uiIntentController.add(CodexSessionUiIntent.skills);
          return true;
        case '/compact':
          _uiIntentController.add(CodexSessionUiIntent.compactImmediately);
          return true;
        case '/review':
          _uiIntentController.add(CodexSessionUiIntent.review);
          return true;
        case '/mcp':
          _uiIntentController.add(CodexSessionUiIntent.mcp);
          return true;
        case '/model':
          _uiIntentController.add(CodexSessionUiIntent.model);
          return true;
        case '/context':
          _uiIntentController.add(CodexSessionUiIntent.context);
          return true;
      }
    }
    return super.sendMessage(
      text,
      clientMessageId: clientMessageId,
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
