import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../models/messages.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_theme.dart';
import '../../utils/command_parser.dart';
import '../../utils/image_decode_size.dart';
import '../adaptive_context_menu.dart';
import '../chat_message_timestamp.dart';

class UserBubble extends StatelessWidget {
  final String text;
  final MessageStatus status;
  final ChatMessageTimestampData? timestamp;
  final VoidCallback? onRetry;
  final VoidCallback? onRewind;
  final bool rewindAsEdit;
  final List<String> imageUrls;
  final String? httpBaseUrl;
  final List<Uint8List> imageBytesList;

  /// Number of images attached (from history restoration when actual data is unavailable).
  final int imageCount;

  const UserBubble({
    super.key,
    required this.text,
    this.status = MessageStatus.sent,
    this.timestamp,
    this.onRetry,
    this.onRewind,
    this.rewindAsEdit = false,
    this.imageUrls = const [],
    this.httpBaseUrl,
    this.imageBytesList = const [],
    this.imageCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    // Detect command message with XML tags
    final parsed = parseCommandMessage(text);
    if (parsed != null) {
      return _CommandBubble(
        command: parsed,
        status: status,
        timestamp: timestamp,
        text: text,
        onRetry: onRetry,
        onRewind: onRewind,
        onShowContextMenu: (position) =>
            _showContextMenu(context, position: position),
      );
    }

    return _StandardBubble(
      displayText: text,
      status: status,
      timestamp: timestamp,
      onRetry: onRetry,
      onRewind: onRewind,
      imageBytesList: imageBytesList,
      imageUrls: imageUrls,
      httpBaseUrl: httpBaseUrl,
      onShowContextMenu: (position) =>
          _showContextMenu(context, position: position),
    );
  }

  void _showContextMenu(BuildContext context, {Offset? position}) async {
    final action = await showAdaptiveActionMenu<String>(
      context: context,
      position: position,
      items: [
        AdaptiveActionMenuItem(
          value: 'copy',
          icon: Icons.copy,
          label: AppLocalizations.of(context).copy,
        ),
        if (onRewind != null)
          AdaptiveActionMenuItem(
            value: 'rewind',
            icon: rewindAsEdit ? Icons.edit_outlined : Icons.history,
            label: rewindAsEdit
                ? AppLocalizations.of(context).edit
                : AppLocalizations.of(context).rewindToHere,
          ),
      ],
    );
    if (!context.mounted || action == null) return;
    if (action == 'copy') {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).copied),
          duration: const Duration(seconds: 1),
        ),
      );
      return;
    }
    if (action == 'rewind') {
      onRewind?.call();
    }
  }
}

/// Standard user message bubble.
class _StandardBubble extends StatelessWidget {
  final String displayText;
  final MessageStatus status;
  final ChatMessageTimestampData? timestamp;
  final VoidCallback? onRetry;
  final VoidCallback? onRewind;
  final List<Uint8List> imageBytesList;
  final List<String> imageUrls;
  final String? httpBaseUrl;
  final ValueChanged<Offset?> onShowContextMenu;

  const _StandardBubble({
    required this.displayText,
    required this.status,
    required this.timestamp,
    required this.onRetry,
    required this.onRewind,
    required this.imageBytesList,
    required this.imageUrls,
    required this.httpBaseUrl,
    required this.onShowContextMenu,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;

    return Align(
      alignment: Alignment.centerRight,
      child: AdaptiveContextMenuRegion(
        onOpen: onShowContextMenu,
        child: GestureDetector(
          onTap: status.canRetry ? onRetry : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(
                  vertical: AppSpacing.bubbleMarginV,
                  horizontal: AppSpacing.bubbleMarginH,
                ),
                padding: const EdgeInsets.symmetric(
                  vertical: AppSpacing.bubblePaddingV,
                  horizontal: AppSpacing.bubblePaddingH,
                ),
                constraints: BoxConstraints(
                  maxWidth:
                      MediaQuery.of(context).size.width *
                      AppSpacing.maxBubbleWidthFraction,
                ),
                decoration: BoxDecoration(
                  color: appColors.userBubble,
                  borderRadius: AppSpacing.userBubbleBorderRadius,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (imageBytesList.isNotEmpty ||
                        (imageUrls.isNotEmpty && httpBaseUrl != null))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            for (final bytes in imageBytesList)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(
                                  bytes,
                                  width: imageBytesList.length == 1 ? 200 : 120,
                                  fit: BoxFit.cover,
                                  cacheWidth: decodeWidthForLogical(
                                    context,
                                    200,
                                  ),
                                  errorBuilder: (context, error, stackTrace) =>
                                      Container(
                                        width: imageBytesList.length == 1
                                            ? 200
                                            : 120,
                                        height: 80,
                                        color: Colors.grey[300],
                                        child: const Icon(Icons.broken_image),
                                      ),
                                ),
                              ),
                            if (imageBytesList.isEmpty)
                              for (final url in imageUrls)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    '$httpBaseUrl$url',
                                    width: imageUrls.length == 1 ? 200 : 120,
                                    fit: BoxFit.cover,
                                    cacheWidth: decodeWidthForLogical(
                                      context,
                                      200,
                                    ),
                                    errorBuilder:
                                        (context, error, stackTrace) =>
                                            Container(
                                              width: imageUrls.length == 1
                                                  ? 200
                                                  : 120,
                                              height: 80,
                                              color: Colors.grey[300],
                                              child: const Icon(
                                                Icons.broken_image,
                                              ),
                                            ),
                                  ),
                                ),
                          ],
                        ),
                      ),
                    if (displayText.isNotEmpty || timestamp != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (displayText.isNotEmpty)
                            Flexible(
                              child: Text(
                                displayText,
                                style: TextStyle(
                                  color: appColors.userBubbleText,
                                ),
                              ),
                            ),
                          if (displayText.isNotEmpty && timestamp != null)
                            const SizedBox(width: 8),
                          if (timestamp case final value?)
                            ChatMessageTimestampText(
                              timestamp: value,
                              color: appColors.userBubbleText.withValues(
                                alpha: 0.66,
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.bubbleMarginH),
                child: _StatusIndicator(status: status),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// CLI-style command bubble: "/command-name args" in a single bubble.
class _CommandBubble extends StatelessWidget {
  final ParsedCommand command;
  final MessageStatus status;
  final ChatMessageTimestampData? timestamp;
  final String text;
  final VoidCallback? onRetry;
  final VoidCallback? onRewind;
  final ValueChanged<Offset?> onShowContextMenu;

  const _CommandBubble({
    required this.command,
    required this.status,
    required this.timestamp,
    required this.text,
    required this.onRetry,
    required this.onRewind,
    required this.onShowContextMenu,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final hasArgs = command.args != null && command.args!.isNotEmpty;

    return Align(
      alignment: Alignment.centerRight,
      child: AdaptiveContextMenuRegion(
        onOpen: onShowContextMenu,
        child: GestureDetector(
          onTap: status.canRetry ? onRetry : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(
                  vertical: AppSpacing.bubbleMarginV,
                  horizontal: AppSpacing.bubbleMarginH,
                ),
                padding: const EdgeInsets.symmetric(
                  vertical: AppSpacing.bubblePaddingV,
                  horizontal: AppSpacing.bubblePaddingH,
                ),
                constraints: BoxConstraints(
                  maxWidth:
                      MediaQuery.of(context).size.width *
                      AppSpacing.maxBubbleWidthFraction,
                ),
                decoration: BoxDecoration(
                  color: appColors.userBubble,
                  borderRadius: AppSpacing.userBubbleBorderRadius,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: command.commandName,
                              style: TextStyle(
                                color: appColors.userBubbleText,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'monospace',
                              ),
                            ),
                            if (hasArgs)
                              TextSpan(
                                text: ' ${command.args}',
                                style: TextStyle(
                                  color: appColors.userBubbleText,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (timestamp case final value?) ...[
                      const SizedBox(width: 8),
                      ChatMessageTimestampText(
                        timestamp: value,
                        color: appColors.userBubbleText.withValues(alpha: 0.66),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.bubbleMarginH),
                child: _StatusIndicator(status: status),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusIndicator extends StatelessWidget {
  final MessageStatus status;

  const _StatusIndicator({required this.status});

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;

    return switch (status) {
      MessageStatus.sending => SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: appColors.subtleText,
        ),
      ),
      MessageStatus.queued => Icon(
        Icons.schedule,
        size: 14,
        color: appColors.subtleText,
      ),
      MessageStatus.sent => Icon(
        Icons.check,
        size: 14,
        color: appColors.subtleText,
      ),
      MessageStatus.bridgeAccepted => Icon(
        Icons.check,
        size: 14,
        color: appColors.subtleText,
      ),
      MessageStatus.providerAccepted => Icon(
        Icons.done_all,
        size: 14,
        color: appColors.subtleText,
      ),
      MessageStatus.providerRejected => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check, size: 14, color: appColors.subtleText),
          const SizedBox(width: 3),
          Icon(
            Icons.error_outline,
            size: 14,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 4),
          Text(
            AppLocalizations.of(context).tapToRetry,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ),
      MessageStatus.failed => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 14,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 4),
          Text(
            AppLocalizations.of(context).tapToRetry,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ),
    };
  }
}
