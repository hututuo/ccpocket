import 'dart:async';
import 'dart:typed_data';

import '../../../models/messages.dart';
import '../../chat_session/state/chat_session_cubit.dart';

enum CodexGoalUiIntent { manage, edit }

/// Codex-specific session cubit.
///
/// Extends [ChatSessionCubit] so that shared widgets
/// (`ChatMessageList`, `ChatInputWithOverlays`, etc.) that read
/// `context.read<ChatSessionCubit>()` continue to work.
///
class CodexSessionCubit extends ChatSessionCubit {
  final _goalUiIntentController =
      StreamController<CodexGoalUiIntent>.broadcast();

  Stream<CodexGoalUiIntent> get goalUiIntents => _goalUiIntentController.stream;

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
  }) {
    if (images == null || images.isEmpty) {
      switch (text.trim()) {
        case '/goal':
          requestGoal(userInitiated: true);
          _goalUiIntentController.add(CodexGoalUiIntent.manage);
          return;
        case '/goal edit':
          requestGoal(userInitiated: true);
          _goalUiIntentController.add(CodexGoalUiIntent.edit);
          return;
      }
    }
    super.sendMessage(text, images: images, mentionablePaths: mentionablePaths);
  }

  @override
  Future<void> close() {
    _goalUiIntentController.close();
    return super.close();
  }
}
