import 'package:flutter/material.dart';

import '../../../theme/app_spacing.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/chat_selection_actions.dart';
import 'chat_process_layout.dart';

class ChatProcessDisclosure extends StatelessWidget {
  const ChatProcessDisclosure({
    super.key,
    required this.turn,
    required this.expanded,
    required this.onToggle,
    this.running = false,
  });

  final ChatProcessTurnLayout turn;
  final bool expanded;
  final VoidCallback onToggle;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    final zh = locale == 'zh';
    final appColors = Theme.of(context).extension<AppColors>()!;
    final color = Theme.of(context).colorScheme.tertiary;
    final title = running
        ? (zh ? '正在思考与执行' : 'Thinking & acting')
        : (zh ? '思考与执行' : 'Thinking & actions');
    final count = turn.detailCount;
    final detail = count > 0 ? (zh ? '$count 项' : '$count items') : null;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.bubbleMarginH,
        vertical: 3,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('chat_process_disclosure_${turn.key}'),
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
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(width: 7),
                  Text(
                    detail,
                    style: TextStyle(fontSize: 11, color: appColors.subtleText),
                  ),
                ],
                const Spacer(),
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
