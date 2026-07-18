import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

enum CodexGoalStatus {
  active,
  paused,
  blocked,
  usageLimited,
  budgetLimited,
  complete,
  unknown,
}

@immutable
class CodexGoalCardData {
  final String objective;
  final CodexGoalStatus status;
  final String? rawStatus;
  final int tokensUsed;
  final int timeUsedSeconds;
  final int? tokenBudget;

  const CodexGoalCardData({
    required this.objective,
    this.status = CodexGoalStatus.active,
    this.rawStatus,
    this.tokensUsed = 0,
    this.timeUsedSeconds = 0,
    this.tokenBudget,
  });
}

class CodexGoalCard extends StatelessWidget {
  final CodexGoalCardData goal;
  final VoidCallback onEdit;
  final VoidCallback onTogglePaused;
  final VoidCallback onClear;
  final VoidCallback? onResolveBudget;
  final bool busy;
  final String? busyLabel;
  final bool controlsEnabled;
  final String? disabledLabel;

  const CodexGoalCard({
    super.key,
    required this.goal,
    required this.onEdit,
    required this.onTogglePaused,
    required this.onClear,
    this.onResolveBudget,
    this.busy = false,
    this.busyLabel,
    this.controlsEnabled = true,
    this.disabledLabel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final statusColor = _statusColor(goal.status, cs);

    return Semantics(
      key: const ValueKey('goal_card'),
      container: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 4, 8, 2),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cs.outlineVariant, width: 0.75),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _GoalHeader(
              status: goal.status,
              rawStatus: goal.rawStatus,
              statusColor: statusColor,
              onEdit: onEdit,
              onTogglePaused: onTogglePaused,
              onClear: onClear,
              onResolveBudget: onResolveBudget,
              busy: busy,
              controlsEnabled: controlsEnabled,
            ),
            const SizedBox(height: 2),
            Text(
              goal.objective,
              key: const ValueKey('goal_objective'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w500,
                height: 1.25,
              ),
            ),
            if (busy) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      busyLabel ?? l.goalUpdating,
                      key: const ValueKey('goal_busy_label'),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (!controlsEnabled && !busy) ...[
              const SizedBox(height: 8),
              Row(
                key: const ValueKey('goal_controls_disabled'),
                children: [
                  Icon(
                    Icons.cloud_off_outlined,
                    size: 16,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      disabledLabel ?? l.goalReconnectToManage,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (_hasGoalUsage(goal)) ...[
              const SizedBox(height: 10),
              _GoalUsage(goal: goal),
            ],
          ],
        ),
      ),
    );
  }
}

class _GoalHeader extends StatelessWidget {
  final CodexGoalStatus status;
  final String? rawStatus;
  final Color statusColor;
  final VoidCallback onEdit;
  final VoidCallback onTogglePaused;
  final VoidCallback onClear;
  final VoidCallback? onResolveBudget;
  final bool busy;
  final bool controlsEnabled;

  const _GoalHeader({
    required this.status,
    required this.rawStatus,
    required this.statusColor,
    required this.onEdit,
    required this.onTogglePaused,
    required this.onClear,
    required this.onResolveBudget,
    required this.busy,
    required this.controlsEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final isPaused = status == CodexGoalStatus.paused;
    final canTogglePaused =
        status == CodexGoalStatus.active ||
        status == CodexGoalStatus.paused ||
        status == CodexGoalStatus.blocked ||
        status == CodexGoalStatus.usageLimited;
    final needsBudget = status == CodexGoalStatus.budgetLimited;
    final actionsEnabled =
        controlsEnabled && !busy && status != CodexGoalStatus.unknown;

    return Row(
      children: [
        Icon(Icons.track_changes, size: 20, color: cs.primary),
        const SizedBox(width: 8),
        Text(
          l.goalTitle,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _GoalStatusChip(
              status: status,
              rawStatus: rawStatus,
              color: statusColor,
            ),
          ),
        ),
        _GoalActionButton(
          key: const ValueKey('goal_edit_button'),
          tooltip: l.goalEditTooltip,
          icon: Icons.edit_outlined,
          onPressed: actionsEnabled ? onEdit : null,
        ),
        _GoalActionButton(
          key: const ValueKey('goal_pause_button'),
          tooltip: needsBudget
              ? l.goalUpdateBudgetResume
              : (isPaused ||
                    status == CodexGoalStatus.blocked ||
                    status == CodexGoalStatus.usageLimited)
              ? l.goalResumeTooltip
              : l.goalPauseTooltip,
          icon: needsBudget
              ? Icons.tune
              : (isPaused ||
                    status == CodexGoalStatus.blocked ||
                    status == CodexGoalStatus.usageLimited)
              ? Icons.play_arrow_rounded
              : Icons.pause_circle_outline,
          onPressed: !actionsEnabled
              ? null
              : needsBudget
              ? onResolveBudget
              : canTogglePaused
              ? onTogglePaused
              : null,
        ),
        _GoalActionButton(
          key: const ValueKey('goal_clear_button'),
          tooltip: l.goalClearTooltip,
          icon: Icons.delete_outline,
          onPressed: actionsEnabled ? onClear : null,
        ),
      ],
    );
  }
}

class _GoalStatusChip extends StatelessWidget {
  final CodexGoalStatus status;
  final String? rawStatus;
  final Color color;

  const _GoalStatusChip({
    required this.status,
    required this.rawStatus,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Container(
      key: const ValueKey('goal_status_chip'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status == CodexGoalStatus.unknown &&
                rawStatus != null &&
                rawStatus != 'unknown'
            ? '${_statusLabel(status, l)} · $rawStatus'
            : _statusLabel(status, l),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _GoalActionButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  const _GoalActionButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 19),
      color: cs.onSurfaceVariant,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    );
  }
}

Color _statusColor(CodexGoalStatus status, ColorScheme cs) => switch (status) {
  CodexGoalStatus.active => cs.secondary,
  CodexGoalStatus.paused => cs.primary,
  CodexGoalStatus.blocked => cs.tertiary,
  CodexGoalStatus.usageLimited || CodexGoalStatus.budgetLimited => cs.error,
  CodexGoalStatus.complete => cs.secondary,
  CodexGoalStatus.unknown => cs.outline,
};

String _statusLabel(CodexGoalStatus status, AppLocalizations l) =>
    switch (status) {
      CodexGoalStatus.active => l.goalStatusActive,
      CodexGoalStatus.paused => l.goalStatusPaused,
      CodexGoalStatus.blocked => l.goalStatusBlocked,
      CodexGoalStatus.usageLimited => l.goalStatusUsageLimited,
      CodexGoalStatus.budgetLimited => l.goalStatusBudgetLimited,
      CodexGoalStatus.complete => l.goalStatusComplete,
      CodexGoalStatus.unknown => l.goalStatusUnknown,
    };

bool _hasGoalUsage(CodexGoalCardData goal) =>
    goal.tokensUsed > 0 || goal.timeUsedSeconds > 0 || goal.tokenBudget != null;

class _GoalUsage extends StatelessWidget {
  final CodexGoalCardData goal;

  const _GoalUsage({required this.goal});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final budget = goal.tokenBudget;
    final progress = budget == null || budget <= 0
        ? null
        : (goal.tokensUsed / budget).clamp(0.0, 1.0);
    return Column(
      key: const ValueKey('goal_usage'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _GoalMetric(
              icon: Icons.data_usage_outlined,
              label: budget == null
                  ? '${_compactNumber(goal.tokensUsed)} ${l.goalTokensUnit}'
                  : '${_compactNumber(goal.tokensUsed)} / ${_compactNumber(budget)} ${l.goalTokensUnit}',
            ),
            _GoalMetric(
              icon: Icons.schedule_outlined,
              label: _formatGoalDuration(goal.timeUsedSeconds),
            ),
          ],
        ),
        if (progress != null) ...[
          const SizedBox(height: 7),
          LinearProgressIndicator(
            key: const ValueKey('goal_budget_progress'),
            value: progress,
            minHeight: 3,
            borderRadius: BorderRadius.circular(999),
            backgroundColor: cs.surfaceContainerHighest,
          ),
        ],
      ],
    );
  }
}

class _GoalMetric extends StatelessWidget {
  final IconData icon;
  final String label;

  const _GoalMetric({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

String _compactNumber(int value) {
  if (value >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(value % 1000000 == 0 ? 0 : 1)}m';
  }
  if (value >= 1000) {
    return '${(value / 1000).toStringAsFixed(value % 1000 == 0 ? 0 : 1)}k';
  }
  return '$value';
}

String _formatGoalDuration(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  if (minutes < 60) {
    return remainingSeconds == 0
        ? '${minutes}m'
        : '${minutes}m ${remainingSeconds}s';
  }
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return remainingMinutes == 0 ? '${hours}h' : '${hours}h ${remainingMinutes}m';
}
