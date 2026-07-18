import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/messages.dart';
import 'conversation_mirror_session_actions.dart';
import 'conversation_mirror_service.dart';
import 'conversation_mirror_strings.dart';

/// A feature-local badge inserted into the upstream recent-session card.
/// Removing this file plus the single call site restores the original card.
class ConversationMirrorBadge extends StatelessWidget {
  const ConversationMirrorBadge({required this.session, super.key});

  final RecentSession session;

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConversationMirrorService?>();
    if (service == null ||
        !service.isAvailable ||
        session.provider != Provider.codex.value) {
      return const SizedBox.shrink();
    }
    final syncing = service.isSyncing(session);
    final hasLocalCopy = service.hasLocalCopy(session);
    if (service.featureUnsupported && !hasLocalCopy) {
      return const SizedBox.shrink();
    }
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: syncing
            ? ConversationMirrorStrings.of(context).syncingTooltip
            : hasLocalCopy
            ? ConversationMirrorStrings.of(context).localCopyTooltip
            : ConversationMirrorStrings.of(context).downloadAndSync,
        child: SizedBox.square(
          dimension: 32,
          child: Center(
            child: syncing
                ? SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      key: const ValueKey('conversation_mirror_syncing_badge'),
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : IconButton(
                    key: ValueKey(
                      hasLocalCopy
                          ? 'conversation_mirror_saved_badge'
                          : 'conversation_mirror_download_badge',
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                    iconSize: 19,
                    color: color,
                    icon: Icon(
                      hasLocalCopy
                          ? Icons.offline_pin_outlined
                          : Icons.download_for_offline_outlined,
                    ),
                    onPressed: service.featureUnsupported
                        ? null
                        : () => handleConversationMirrorAction(
                            context,
                            session,
                            hasLocalCopy
                                ? conversationMirrorSyncAction
                                : conversationMirrorDownloadAction,
                          ),
                  ),
          ),
        ),
      ),
    );
  }
}
