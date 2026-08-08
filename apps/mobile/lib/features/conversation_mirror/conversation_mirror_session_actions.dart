import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/messages.dart';
import '../../widgets/adaptive_context_menu.dart';
import 'conversation_mirror_service.dart';
import 'conversation_mirror_strings.dart';
import 'conversation_mirror_target.dart';

const conversationMirrorStopResidentAction =
    'conversation_mirror_stop_resident';
const conversationMirrorRemoveAction = 'conversation_mirror_remove';

/// Optional action-menu contribution for the removable conversation mirror.
///
/// Returning an empty list leaves the upstream recent-session menu unchanged.
List<AdaptiveActionMenuItem<String>> conversationMirrorActionItems(
  BuildContext context,
  RecentSession session,
) => conversationMirrorTargetActionItems(
  context,
  ConversationMirrorTarget.fromRecent(session),
);

List<AdaptiveActionMenuItem<String>> conversationMirrorRunningActionItems(
  BuildContext context,
  SessionInfo session,
) {
  final target = ConversationMirrorTarget.fromRunning(session);
  return target == null
      ? const []
      : conversationMirrorTargetActionItems(context, target);
}

List<AdaptiveActionMenuItem<String>> conversationMirrorTargetActionItems(
  BuildContext context,
  ConversationMirrorTarget target,
) {
  final service = context.read<ConversationMirrorService?>();
  if (service == null ||
      !service.isAvailable ||
      target.provider != Provider.codex.value) {
    return const [];
  }
  final strings = ConversationMirrorStrings.of(context);
  final hasLocalCopy = service.hasLocalCopyTarget(target);
  final isResident = service.isResidentTarget(target);
  // Existing legacy copies remain removable, but the former opt-in full
  // download/sync workflow is retired. Recent history is now obtained through
  // bounded paging and the ordinary rebuildable cache.
  if (!isResident) {
    return [
      if (hasLocalCopy)
        AdaptiveActionMenuItem(
          key: const ValueKey('conversation_mirror_remove_action'),
          value: conversationMirrorRemoveAction,
          icon: Icons.phonelink_erase_outlined,
          label: strings.removeLocalCopy,
          destructive: true,
        ),
    ];
  }
  return [
    AdaptiveActionMenuItem(
      key: const ValueKey('conversation_mirror_stop_resident_action'),
      value: conversationMirrorStopResidentAction,
      icon: Icons.pause_circle_outline,
      label: strings.stopResident,
    ),
    AdaptiveActionMenuItem(
      key: const ValueKey('conversation_mirror_remove_action'),
      value: conversationMirrorRemoveAction,
      icon: Icons.phonelink_erase_outlined,
      label: strings.removeLocalCopy,
      destructive: true,
    ),
  ];
}

/// Handles only mirror-owned action values. Returns false for upstream items.
Future<bool> handleConversationMirrorAction(
  BuildContext context,
  RecentSession session,
  String action,
) => handleConversationMirrorTargetAction(
  context,
  ConversationMirrorTarget.fromRecent(session),
  action,
);

Future<bool> handleConversationMirrorRunningAction(
  BuildContext context,
  SessionInfo session,
  String action,
) async {
  final target = ConversationMirrorTarget.fromRunning(session);
  if (target == null) return false;
  return handleConversationMirrorTargetAction(context, target, action);
}

Future<bool> handleConversationMirrorTargetAction(
  BuildContext context,
  ConversationMirrorTarget target,
  String action,
) async {
  if (!const {
    conversationMirrorStopResidentAction,
    conversationMirrorRemoveAction,
  }.contains(action)) {
    return false;
  }
  final service = context.read<ConversationMirrorService?>();
  if (service == null) return true;
  final strings = ConversationMirrorStrings.of(context);
  final messenger = ScaffoldMessenger.of(context);

  try {
    if (action == conversationMirrorRemoveAction) {
      await service.removeLocalCopyTarget(target);
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(strings.removed)));
      }
      return true;
    }

    await service.stopBeingResidentTarget(target);
    if (context.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(strings.residencyStopped)));
    }
  } catch (error) {
    if (context.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(strings.failed('$error'))));
    }
  }
  return true;
}
