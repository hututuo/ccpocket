import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../state/chat_session_cubit.dart';

/// Applies durable-cache revisions to an existing detached chat cubit.
///
/// Keeping the provider and message widgets mounted preserves scroll position
/// and disclosure state while Bridge-owned incremental sync refreshes content.
class DurableSessionPreviewUpdater extends StatefulWidget {
  final String revision;
  final List<ServerMessage> messages;
  final Widget child;

  const DurableSessionPreviewUpdater({
    super.key,
    required this.revision,
    required this.messages,
    required this.child,
  });

  @override
  State<DurableSessionPreviewUpdater> createState() =>
      _DurableSessionPreviewUpdaterState();
}

class _DurableSessionPreviewUpdaterState
    extends State<DurableSessionPreviewUpdater> {
  @override
  void didUpdateWidget(covariant DurableSessionPreviewUpdater oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision == widget.revision) return;
    final revision = widget.revision;
    final messages = widget.messages;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.revision != revision) return;
      context.read<ChatSessionCubit>().updateDetachedPreviewHistory(messages);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Compact non-blocking status shown while a durable conversation is already
/// readable/composable but its live runtime is still attaching.
class DurableSessionBindingBanner extends StatelessWidget {
  final bool messageQueued;

  const DurableSessionBindingBanner({super.key, required this.messageQueued});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                Icon(
                  messageQueued ? Icons.schedule_send_outlined : Icons.sync,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    messageQueued
                        ? '${l.queuedLocally} · ${l.loadingSessionStatus}'
                        : l.loadingSessionStatus,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
