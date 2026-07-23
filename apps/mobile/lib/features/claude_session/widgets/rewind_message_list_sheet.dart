import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../../theme/app_theme.dart';

class UserMessageHistoryLoaderSheet extends StatelessWidget {
  final Future<List<UserChatEntry>> messages;
  final Future<bool> Function(UserChatEntry message) onScrollToMessage;
  final void Function(UserChatEntry message)? onRewindMessage;

  const UserMessageHistoryLoaderSheet({
    super.key,
    required this.messages,
    required this.onScrollToMessage,
    this.onRewindMessage,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<UserChatEntry>>(
      future: messages,
      builder: (context, snapshot) {
        final loaded = snapshot.data;
        if (loaded != null) {
          return UserMessageHistorySheet(
            messages: loaded,
            onScrollToMessage: onScrollToMessage,
            onRewindMessage: onRewindMessage,
          );
        }
        return const SizedBox(
          height: 280,
          child: Center(child: CircularProgressIndicator.adaptive()),
        );
      },
    );
  }
}

/// Bottom sheet that lists all user messages as a message history.
///
/// Provides two actions per message:
/// - Tap message → [onScrollToMessage] (scroll chat to that position)
/// - Tap rewind icon → [onRewindMessage] (only for messages with UUID)
class UserMessageHistorySheet extends StatefulWidget {
  final List<UserChatEntry> messages;
  final Future<bool> Function(UserChatEntry message) onScrollToMessage;
  final void Function(UserChatEntry message)? onRewindMessage;

  const UserMessageHistorySheet({
    super.key,
    required this.messages,
    required this.onScrollToMessage,
    this.onRewindMessage,
  });

  @override
  State<UserMessageHistorySheet> createState() =>
      _UserMessageHistorySheetState();
}

class _UserMessageHistorySheetState extends State<UserMessageHistorySheet> {
  UserChatEntry? _loadingTarget;

  Future<void> _scrollTo(UserChatEntry message) async {
    if (_loadingTarget != null) return;
    setState(() => _loadingTarget = message);
    var found = false;
    try {
      found = await widget.onScrollToMessage(message);
    } catch (_) {
      found = false;
    }
    if (!mounted) return;
    if (found) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _loadingTarget = null);
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(zh ? '未能加载这轮会话，请重试' : 'Could not load this turn')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final colorScheme = Theme.of(context).colorScheme;
    final loading = _loadingTarget != null;
    final zh = Localizations.localeOf(context).languageCode == 'zh';

    return Stack(
      children: [
        DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                // Drag handle
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),

                // Title
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      Icon(Icons.history, size: 20, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        zh ? '会话轮次' : 'Turn history',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      Text(
                        zh
                            ? '${widget.messages.length} 轮'
                            : '${widget.messages.length} turn${widget.messages.length == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: appColors.subtleText,
                        ),
                      ),
                    ],
                  ),
                ),

                const Divider(height: 1),

                // Message list
                if (widget.messages.isEmpty)
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 48,
                            color: appColors.subtleText,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            zh ? '暂无会话轮次' : 'No turns yet',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: appColors.subtleText),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            zh
                                ? '发送消息后，每一轮的开头都会显示在这里'
                                : 'Each turn start appears here after you send a message',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: appColors.subtleText),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: widget.messages.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 56),
                      itemBuilder: (context, index) {
                        // Show newest first
                        final msg =
                            widget.messages[widget.messages.length - 1 - index];
                        final canRewind =
                            widget.onRewindMessage != null &&
                            msg.messageUuid != null;
                        return _MessageTile(
                          message: msg,
                          index: widget.messages.length - index,
                          canRewind: canRewind,
                          onTap: loading ? null : () => _scrollTo(msg),
                          onRewind: canRewind
                              ? () {
                                  Navigator.of(context).pop();
                                  widget.onRewindMessage!(msg);
                                }
                              : null,
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
        if (loading)
          Positioned.fill(
            child: ModalBarrier(
              key: const ValueKey('history_target_loading'),
              dismissible: false,
              color: colorScheme.scrim.withValues(alpha: 0.24),
            ),
          ),
        if (loading)
          Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 18,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator.adaptive(
                        strokeWidth: 2.4,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      zh ? '正在加载并定位这轮会话…' : 'Loading and locating this turn…',
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MessageTile extends StatelessWidget {
  final UserChatEntry message;
  final int index;
  final bool canRewind;
  final VoidCallback? onTap;
  final VoidCallback? onRewind;

  const _MessageTile({
    required this.message,
    required this.index,
    this.canRewind = true,
    required this.onTap,
    this.onRewind,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final colorScheme = Theme.of(context).colorScheme;

    final timeStr = _formatTime(message.timestamp);

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: colorScheme.surfaceContainerHigh,
        child: Text(
          '#$index',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: appColors.subtleText,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      title: Text(
        message.text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      subtitle: Text(
        timeStr,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: appColors.subtleText),
      ),
      trailing: canRewind
          ? IconButton(
              icon: Icon(Icons.history, size: 18, color: colorScheme.primary),
              tooltip: AppLocalizations.of(context).rewindToHere,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: onRewind,
            )
          : null,
      onTap: onTap,
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
