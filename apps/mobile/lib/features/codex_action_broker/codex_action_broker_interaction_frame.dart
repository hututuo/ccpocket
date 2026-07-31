import 'package:flutter/material.dart';

import 'codex_action_broker_service.dart';
import 'codex_action_broker_strings.dart';

/// Non-modal status frame around the existing approval/question controls.
///
/// The child remains the established CC Pocket UI. This wrapper only disables
/// unsafe interaction and explains the broker state; it is not a second
/// approval dialog.
class CodexActionBrokerInteractionFrame extends StatelessWidget {
  const CodexActionBrokerInteractionFrame({
    super.key,
    required this.phase,
    required this.onRefresh,
    this.child,
    this.onReject,
  });

  final CodexActionBrokerInteractionPhase phase;
  final VoidCallback onRefresh;
  final Widget? child;
  final VoidCallback? onReject;

  bool get _interactive =>
      phase == CodexActionBrokerInteractionPhase.actionable;

  @override
  Widget build(BuildContext context) {
    final strings = CodexActionBrokerStrings.of(context);
    final colors = Theme.of(context).colorScheme;
    final status = strings.messageFor(phase);
    return Material(
      color: colors.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
              child: Row(
                children: [
                  Icon(
                    phase == CodexActionBrokerInteractionPhase.actionable
                        ? Icons.shield_outlined
                        : Icons.sync_problem_outlined,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${strings.needYou} · $status',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('codex_action_broker_refresh'),
                    onPressed: onRefresh,
                    child: Text(strings.refresh),
                  ),
                ],
              ),
            ),
          if (child != null)
            IgnorePointer(
              key: const ValueKey('codex_action_broker_interaction_guard'),
              ignoring: !_interactive,
              child: Opacity(opacity: _interactive ? 1 : 0.68, child: child),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.person_outline, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      strings.needYou,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          if (_interactive && onReject != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  key: const ValueKey('codex_action_broker_question_reject'),
                  onPressed: onReject,
                  child: Text(strings.reject),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
