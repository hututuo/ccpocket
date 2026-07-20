import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../services/draft_service.dart';
import '../../../widgets/chat_selection_actions.dart';
import '../../side_chat/l10n/side_chat_strings.dart';
import '../../side_chat/side_chat_selection_action.dart';
import '../../side_chat/widgets/persisted_side_chat_pane.dart';
import '../host/local_session_feature.dart';

final LocalSessionFeatureSlot sideChatUiSlot = _SideChatUiSlot();

class _SideChatUiSlot extends LocalSessionFeatureSlot {
  @override
  String get featureId => 'side_chat';

  @override
  List<SessionMenuAction> overflowActions(CodexSessionFeatureContext context) =>
      [
        SessionMenuAction(
          featureId: featureId,
          label: SideChatStrings.of(context.context).title,
          icon: Icons.chat_bubble_outline,
          order: 30,
        ),
      ];

  @override
  List<ChatSelectionAction> selectionActions(
    CodexSessionFeatureContext context,
  ) {
    return [
      createSideChatSelectionAction(
        context: context.context,
        onOpen: (selectedText) {
          unawaited(
            context.openPane(
              featureId,
              arguments: {
                'initialSelection': selectedText,
                'selectionRevision': DateTime.now().microsecondsSinceEpoch,
              },
            ),
          );
        },
      ),
    ];
  }

  @override
  WorkspaceFeaturePaneDescriptor get paneDescriptor =>
      WorkspaceFeaturePaneDescriptor(
        featureId: featureId,
        title: (context) => SideChatStrings.of(context).title,
        rememberPerSession: false,
        builder: (context) => PersistedSideChatPane(
          parentSessionId: context.sessionId,
          bridgeService: context.bridge,
          draftService: context.context.read<DraftService>(),
          initialSelection: context.arguments['initialSelection'] as String?,
          selectionRevision:
              context.arguments['selectionRevision'] as int? ?? 0,
          onClose: context.onClose,
        ),
      );
}
