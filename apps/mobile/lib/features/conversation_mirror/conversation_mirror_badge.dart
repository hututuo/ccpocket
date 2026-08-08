import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/messages.dart';
import 'conversation_mirror_service.dart';
import 'conversation_mirror_strings.dart';
import 'conversation_mirror_target.dart';

/// A feature-local badge inserted into the upstream recent-session card.
/// Removing this file plus the single call site restores the original card.
class ConversationMirrorBadge extends StatelessWidget {
  const ConversationMirrorBadge({required this.session, super.key});

  final RecentSession session;

  @override
  Widget build(BuildContext context) => ConversationMirrorTargetBadge(
    target: ConversationMirrorTarget.fromRecent(session),
  );
}

/// Running-session counterpart. It appears as soon as Codex has announced the
/// durable thread ID; before that, no unstable runtime identity is persisted.
class ConversationMirrorRunningBadge extends StatelessWidget {
  const ConversationMirrorRunningBadge({required this.session, super.key});

  final SessionInfo session;

  @override
  Widget build(BuildContext context) {
    final target = ConversationMirrorTarget.fromRunning(session);
    return target == null
        ? const SizedBox.shrink()
        : ConversationMirrorTargetBadge(target: target);
  }
}

class ConversationMirrorTargetBadge extends StatelessWidget {
  const ConversationMirrorTargetBadge({required this.target, super.key});

  final ConversationMirrorTarget target;

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConversationMirrorService?>();
    if (service == null ||
        !service.isAvailable ||
        target.provider != Provider.codex.value) {
      return const SizedBox.shrink();
    }
    final syncing = service.isSyncingTarget(target);
    final hasLocalCopy = service.hasLocalCopyTarget(target);
    final isResident = service.isResidentTarget(target);
    // Full-conversation download is no longer a user-facing workflow. Keep a
    // passive check for legacy copies so people can still see what is already
    // stored, but never turn an empty cache into a download button.
    if (!hasLocalCopy) {
      return const SizedBox.shrink();
    }
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: syncing
            ? ConversationMirrorStrings.of(context).syncingTooltip
            : isResident
            ? ConversationMirrorStrings.of(context).localCopyTooltip
            : ConversationMirrorStrings.of(context).savedCopyTooltip,
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
                : Icon(
                    key: ValueKey(
                      isResident
                          ? 'conversation_mirror_resident_badge'
                          : 'conversation_mirror_saved_badge',
                    ),
                    size: 19,
                    color: color,
                    isResident
                        ? Icons.offline_pin_outlined
                        : Icons.check_circle_outline,
                  ),
          ),
        ),
      ),
    );
  }
}
