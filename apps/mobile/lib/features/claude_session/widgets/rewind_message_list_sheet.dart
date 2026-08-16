import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../../theme/app_theme.dart';

class UserMessageHistoryLoaderSheet extends StatefulWidget {
  final Future<List<UserChatEntry>> Function() loadMessages;
  final bool Function() isUserMessageIndexComplete;
  final ValueListenable<int>? refreshListenable;
  final Future<bool> Function(UserChatEntry message) onScrollToMessage;
  final void Function(UserChatEntry message)? onRewindMessage;
  final bool rewindAsEdit;

  const UserMessageHistoryLoaderSheet({
    super.key,
    required this.loadMessages,
    required this.isUserMessageIndexComplete,
    this.refreshListenable,
    required this.onScrollToMessage,
    this.onRewindMessage,
    this.rewindAsEdit = false,
  });

  @override
  State<UserMessageHistoryLoaderSheet> createState() =>
      _UserMessageHistoryLoaderSheetState();
}

class _UserMessageHistoryLoaderSheetState
    extends State<UserMessageHistoryLoaderSheet> {
  List<UserChatEntry>? _messages;
  Object? _loadError;
  bool _userMessageIndexComplete = false;
  bool _loading = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.refreshListenable?.addListener(_handleRefresh);
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(UserMessageHistoryLoaderSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshListenable != widget.refreshListenable) {
      oldWidget.refreshListenable?.removeListener(_handleRefresh);
      widget.refreshListenable?.addListener(_handleRefresh);
    }
  }

  @override
  void dispose() {
    widget.refreshListenable?.removeListener(_handleRefresh);
    super.dispose();
  }

  void _handleRefresh() {
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final generation = ++_loadGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final messages = await widget.loadMessages();
      final complete = widget.isUserMessageIndexComplete();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _messages = messages;
        _userMessageIndexComplete = complete;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadError = error;
        _userMessageIndexComplete = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = _messages;
    if (messages != null) {
      return UserMessageHistorySheet(
        messages: messages,
        userMessageIndexComplete: _userMessageIndexComplete,
        userMessageIndexRefreshing: _loading,
        userMessageIndexLoadError: _loadError,
        onRetryUserMessageIndex: _reload,
        onScrollToMessage: widget.onScrollToMessage,
        onRewindMessage: widget.onRewindMessage,
        rewindAsEdit: widget.rewindAsEdit,
      );
    }
    if (_loadError != null && !_loading) {
      final l = AppLocalizations.of(context);
      return SizedBox(
        height: 280,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.turnHistoryLoadFailed),
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: _reload, child: Text(l.retry)),
            ],
          ),
        ),
      );
    }
    return const SizedBox(
      height: 280,
      child: Center(child: CircularProgressIndicator.adaptive()),
    );
  }
}

/// Bottom sheet that lists all user messages as a message history.
///
/// Provides two actions per message:
/// - Tap message → [onScrollToMessage] (scroll chat to that position)
/// - Tap the provider action → [onRewindMessage] (only with a stable UUID).
///   Claude presents rewind; Codex presents its pencil/edit-as-branch action.
class UserMessageHistorySheet extends StatefulWidget {
  final List<UserChatEntry> messages;
  final bool userMessageIndexComplete;
  final bool userMessageIndexRefreshing;
  final Object? userMessageIndexLoadError;
  final VoidCallback? onRetryUserMessageIndex;
  final Future<bool> Function(UserChatEntry message) onScrollToMessage;
  final void Function(UserChatEntry message)? onRewindMessage;
  final bool rewindAsEdit;

  const UserMessageHistorySheet({
    super.key,
    required this.messages,
    this.userMessageIndexComplete = true,
    this.userMessageIndexRefreshing = false,
    this.userMessageIndexLoadError,
    this.onRetryUserMessageIndex,
    required this.onScrollToMessage,
    this.onRewindMessage,
    this.rewindAsEdit = false,
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
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.turnLoadFailed)));
  }

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final colorScheme = Theme.of(context).colorScheme;
    final loading = _loadingTarget != null;
    final l = AppLocalizations.of(context);

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
                        l.turnHistoryTitle,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      Text(
                        l.turnCount(widget.messages.length),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: appColors.subtleText,
                        ),
                      ),
                    ],
                  ),
                ),

                const Divider(height: 1),

                if (!widget.userMessageIndexComplete)
                  _PartialHistoryBanner(
                    visibleTurns: widget.messages.length,
                    refreshing: widget.userMessageIndexRefreshing,
                    loadError: widget.userMessageIndexLoadError,
                    onRetry: widget.onRetryUserMessageIndex,
                  ),

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
                            l.noTurnsYet,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: appColors.subtleText),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l.turnHistoryHint,
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
                          rewindAsEdit: widget.rewindAsEdit,
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
                    Text(l.locatingTurn),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PartialHistoryBanner extends StatelessWidget {
  const _PartialHistoryBanner({
    required this.visibleTurns,
    required this.refreshing,
    required this.loadError,
    required this.onRetry,
  });

  final int visibleTurns;
  final bool refreshing;
  final Object? loadError;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final busy = refreshing;
    final status = loadError != null
        ? l.userMessageIndexUnavailable(visibleTurns)
        : refreshing
        ? l.userMessageIndexLoading(visibleTurns)
        : l.userMessageIndexNotReady(visibleTurns);

    return Container(
      key: const ValueKey('partial_history_banner'),
      width: double.infinity,
      color: colorScheme.secondaryContainer.withValues(alpha: 0.45),
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          if (busy)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator.adaptive(strokeWidth: 2),
            )
          else
            Icon(
              Icons.info_outline,
              size: 18,
              color: colorScheme.onSecondaryContainer,
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              status,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey('retry_user_message_index_button'),
              onPressed: busy ? null : onRetry,
              child: Text(l.retry),
            ),
          ],
        ],
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  final UserChatEntry message;
  final int index;
  final bool canRewind;
  final bool rewindAsEdit;
  final VoidCallback? onTap;
  final VoidCallback? onRewind;

  const _MessageTile({
    required this.message,
    required this.index,
    this.canRewind = true,
    this.rewindAsEdit = false,
    required this.onTap,
    this.onRewind,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final colorScheme = Theme.of(context).colorScheme;

    final timeStr = _formatDateTime(message.timestamp);

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
              key: ValueKey(
                rewindAsEdit ? 'edit_turn_$index' : 'rewind_turn_$index',
              ),
              icon: Icon(
                rewindAsEdit ? Icons.edit_outlined : Icons.history,
                size: 18,
                color: colorScheme.primary,
              ),
              tooltip: rewindAsEdit
                  ? AppLocalizations.of(context).edit
                  : AppLocalizations.of(context).rewindToHere,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: onRewind,
            )
          : null,
      onTap: onTap,
    );
  }

  String _formatDateTime(DateTime timestamp) {
    final dt = timestamp.toLocal();
    final now = DateTime.now();
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    if (dt.year == now.year) return '$month-$day $h:$m:$s';
    final year = dt.year.toString().padLeft(4, '0');
    return '$year-$month-$day $h:$m:$s';
  }
}
