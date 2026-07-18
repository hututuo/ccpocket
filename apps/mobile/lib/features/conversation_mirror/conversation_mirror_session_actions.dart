import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/messages.dart';
import '../../widgets/adaptive_context_menu.dart';
import 'conversation_mirror_service.dart';
import 'conversation_mirror_strings.dart';

const conversationMirrorDownloadAction = 'conversation_mirror_download';
const conversationMirrorSyncAction = 'conversation_mirror_sync';
const conversationMirrorRemoveAction = 'conversation_mirror_remove';

/// Optional action-menu contribution for the removable conversation mirror.
///
/// Returning an empty list leaves the upstream recent-session menu unchanged.
List<AdaptiveActionMenuItem<String>> conversationMirrorActionItems(
  BuildContext context,
  RecentSession session,
) {
  final service = context.read<ConversationMirrorService?>();
  if (service == null ||
      !service.isAvailable ||
      session.provider != Provider.codex.value) {
    return const [];
  }
  final strings = ConversationMirrorStrings.of(context);
  final hasLocalCopy = service.hasLocalCopy(session);
  if (!hasLocalCopy) {
    if (service.featureUnsupported) return const [];
    return [
      AdaptiveActionMenuItem(
        key: const ValueKey('conversation_mirror_download_action'),
        value: conversationMirrorDownloadAction,
        icon: Icons.download_for_offline_outlined,
        label: strings.downloadAndSync,
      ),
    ];
  }
  return [
    if (!service.featureUnsupported)
      AdaptiveActionMenuItem(
        key: const ValueKey('conversation_mirror_sync_action'),
        value: conversationMirrorSyncAction,
        icon: Icons.sync,
        label: strings.syncNow,
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
) async {
  if (!const {
    conversationMirrorDownloadAction,
    conversationMirrorSyncAction,
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
      await service.removeLocalCopy(session);
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(strings.removed)));
      }
      return true;
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          action == conversationMirrorDownloadAction
              ? strings.downloading
              : strings.syncing,
        ),
      ),
    );
    final result = action == conversationMirrorDownloadAction
        ? await service.downloadAndWatch(session)
        : await service.syncNow(session);
    if (!context.mounted) return true;
    messenger.hideCurrentSnackBar();
    final message = result.success
        ? (result.changed
              ? strings.downloaded(result.entryCount)
              : strings.upToDate)
        : result.errorCode == 'unsupported_capability' ||
              result.errorCode == 'unsupported_message' ||
              result.errorCode == 'capability_not_negotiated'
        ? strings.bridgeUpdateRequired
        : strings.failed(result.error ?? result.errorCode ?? 'unknown error');
    messenger.showSnackBar(SnackBar(content: Text(message)));
  } catch (error) {
    if (context.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(strings.failed('$error'))));
    }
  }
  return true;
}
