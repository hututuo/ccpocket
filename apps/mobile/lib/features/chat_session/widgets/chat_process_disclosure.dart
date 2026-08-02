import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/tool_categories.dart';
import '../../../widgets/chat_message_timestamp.dart';
import '../../../widgets/chat_selection_actions.dart';
import 'chat_process_layout.dart';

class ChatProcessDisclosure extends StatelessWidget {
  const ChatProcessDisclosure({
    super.key,
    required this.segment,
    required this.expanded,
    required this.onToggle,
    this.running = false,
    this.timestamp,
  });

  final ChatProcessSegmentLayout segment;
  final bool expanded;
  final VoidCallback onToggle;
  final bool running;
  final ChatMessageTimestampData? timestamp;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final appColors = Theme.of(context).extension<AppColors>()!;
    final color = Theme.of(context).colorScheme.tertiary;
    final title = running ? l.chatProcessRunningTitle : l.chatProcessTitle;
    final count = segment.detailCount;
    final detail = count > 0 ? l.chatProcessItemCount(count) : null;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.bubbleMarginH,
        vertical: 3,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('chat_process_disclosure_${segment.key}'),
          borderRadius: BorderRadius.circular(10),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            child: Row(
              children: [
                Icon(
                  running ? Icons.autorenew : Icons.psychology_outlined,
                  size: 15,
                  color: color,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (detail != null) ...[
                        const SizedBox(width: 7),
                        Text(
                          detail,
                          style: TextStyle(
                            fontSize: 11,
                            color: appColors.subtleText,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                if (timestamp case final value?) ...[
                  ChatMessageTimestampText(timestamp: value),
                  const SizedBox(width: 5),
                ],
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 17,
                  color: appColors.subtleText,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChatIntermediateOutputsDisclosure extends StatelessWidget {
  const ChatIntermediateOutputsDisclosure({
    super.key,
    required this.turn,
    required this.expanded,
    required this.onToggle,
    this.timestamp,
  });

  final ChatProcessTurnLayout turn;
  final bool expanded;
  final VoidCallback onToggle;
  final ChatMessageTimestampData? timestamp;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final appColors = Theme.of(context).extension<AppColors>()!;
    final color = Theme.of(context).colorScheme.secondary;
    final count = turn.intermediateOutputCount;
    final detailCount = turn.intermediateDetailCount;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.bubbleMarginH,
        vertical: 3,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('chat_intermediate_disclosure_${turn.key}'),
          borderRadius: BorderRadius.circular(10),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            child: Row(
              children: [
                Icon(Icons.layers_outlined, size: 15, color: color),
                const SizedBox(width: 7),
                Expanded(
                  flex: 3,
                  child: Text(
                    l.chatProcessIntermediateUpdates,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 2,
                  child: Text(
                    detailCount > 0
                        ? l.chatProcessUpdateDetailCount(count, detailCount)
                        : l.chatProcessUpdateCount(count),
                    style: TextStyle(fontSize: 11, color: appColors.subtleText),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                  ),
                ),
                const SizedBox(width: 4),
                if (timestamp case final value?) ...[
                  ChatMessageTimestampText(timestamp: value),
                  const SizedBox(width: 5),
                ],
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 17,
                  color: appColors.subtleText,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Header for the one active, unfinished assistant interval.
///
/// The live text itself intentionally remains outside this card. This makes
/// the current progress readable at a glance while its thought/tool detail is
/// still opt-in.
class ChatCurrentProgressHeader extends StatelessWidget {
  const ChatCurrentProgressHeader({
    super.key,
    required this.turnKey,
    required this.expanded,
    required this.onToggle,
    this.hasDetails = true,
  });

  final String turnKey;
  final bool expanded;
  final VoidCallback onToggle;
  final bool hasDetails;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final appColors = Theme.of(context).extension<AppColors>()!;
    final color = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.bubbleMarginH,
        3,
        AppSpacing.bubbleMarginH,
        1,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('chat_current_progress_$turnKey'),
          borderRadius: BorderRadius.circular(10),
          onTap: hasDetails ? onToggle : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            child: Row(
              children: [
                Icon(Icons.pending_actions_outlined, size: 15, color: color),
                const SizedBox(width: 7),
                Text(
                  l.chatProcessCurrentProgress,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  l.chatProcessLive,
                  style: TextStyle(fontSize: 11, color: appColors.subtleText),
                ),
                const Spacer(),
                if (hasDetails)
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 17,
                    color: appColors.subtleText,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The compact, single-tool line shown below the currently visible text.
///
/// It intentionally displays only the newest invocation/result. Tapping it
/// uses the same expansion action as the current-progress header, revealing
/// the complete interval rather than opening a second, conflicting detail UI.
class ChatCurrentToolActivityLine extends StatelessWidget {
  const ChatCurrentToolActivityLine({
    super.key,
    required this.activity,
    required this.expanded,
    required this.onTap,
    this.timestamp,
  });

  final ChatProcessToolActivity activity;
  final bool expanded;
  final VoidCallback onTap;
  final ChatMessageTimestampData? timestamp;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final appColors = Theme.of(context).extension<AppColors>()!;
    final category = categorizeToolName(activity.name);
    final categoryColor = getToolCategoryColor(category, appColors);
    final summary = _toolActivitySummary(activity, category);
    final displayName = getToolDisplayName(
      activity.name,
      l10n: l,
      input: activity.input,
      phase: activity.completed
          ? ToolDisplayPhase.completed
          : ToolDisplayPhase.action,
    );

    final toolLine = Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.bubbleMarginH + 4,
        1,
        AppSpacing.bubbleMarginH + 4,
        5,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('chat_current_tool_${activity.toolUseId}'),
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(
                  getToolCategoryIcon(category),
                  size: 12,
                  color: categoryColor,
                ),
                const SizedBox(width: 6),
                Text(
                  activity.completed
                      ? l.chatProcessLatestTool
                      : l.chatProcessRunningTool,
                  style: TextStyle(fontSize: 11, color: appColors.subtleText),
                ),
                const SizedBox(width: 6),
                Text(
                  displayName,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      summary,
                      style: TextStyle(
                        fontSize: 11,
                        color: appColors.subtleText,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ] else
                  const Spacer(),
                if (timestamp case final value?) ...[
                  ChatMessageTimestampText(timestamp: value),
                  const SizedBox(width: 5),
                ],
                Icon(
                  expanded ? Icons.expand_less : Icons.chevron_right,
                  key: ValueKey(
                    'chat_current_tool_disclosure_icon_${activity.toolUseId}',
                  ),
                  size: 15,
                  color: appColors.subtleText,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return toolLine;
  }
}

String chatGuardianReviewIdentity(GuardianApprovalMessage message) {
  final reviewId = message.reviewId?.trim();
  if (reviewId?.isNotEmpty == true) return 'review:$reviewId';
  return [
    message.targetItemId ?? '',
    message.status.name,
    message.risk.name,
    message.reason,
    message.authorization ?? '',
    message.action?.toString() ?? '',
  ].join('|');
}

String _toolActivitySummary(
  ChatProcessToolActivity activity,
  ToolCategory category,
) => getToolCollapsedSummary(category, activity.input);

class ChatLiveThinkingDetails extends StatelessWidget {
  const ChatLiveThinkingDetails({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.bubbleMarginH + 4,
        0,
        AppSpacing.bubbleMarginH + 4,
        6,
      ),
      child: SelectableText(
        text,
        key: const ValueKey('live_thinking_details'),
        style: TextStyle(
          fontSize: 12,
          height: 1.45,
          fontFamily: 'monospace',
          color: cs.onSurface.withValues(alpha: 0.76),
        ),
        contextMenuBuilder: chatSelectableTextContextMenuBuilder,
      ),
    );
  }
}
