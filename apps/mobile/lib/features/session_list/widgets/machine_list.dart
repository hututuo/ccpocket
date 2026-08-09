import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/machine.dart';
import 'machine_group_card.dart';

/// List of saved remote machines with status indicators.
class MachineList extends StatelessWidget {
  final List<MachineWithStatus> machines;
  final String? startingMachineId;
  final String? updatingMachineId;
  final String? latestBridgeVersion;
  final bool isRefreshing;
  final ValueChanged<MachineWithStatus> onConnect;
  final ValueChanged<MachineWithStatus> onStart;
  final ValueChanged<MachineWithStatus> onEdit;
  final ValueChanged<MachineWithStatus> onDelete;
  final ValueChanged<MachineWithStatus>? onToggleFavorite;
  final ValueChanged<MachineWithStatus>? onUpdate;
  final ValueChanged<MachineWithStatus>? onStop;
  final ValueChanged<BridgeMachineGroup>? onRenameGroup;
  final VoidCallback onAddMachine;
  final VoidCallback? onRefresh;

  const MachineList({
    super.key,
    required this.machines,
    this.startingMachineId,
    this.updatingMachineId,
    this.latestBridgeVersion,
    this.isRefreshing = false,
    required this.onConnect,
    required this.onStart,
    required this.onEdit,
    required this.onDelete,
    this.onToggleFavorite,
    this.onUpdate,
    this.onStop,
    this.onRenameGroup,
    required this.onAddMachine,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final groups = groupBridgeMachineRoutes(machines);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(Icons.dns, size: 18, color: colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              l.machines,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
            const Spacer(),
            if (onRefresh != null)
              IconButton(
                key: const ValueKey('machine_status_refresh_button'),
                onPressed: isRefreshing ? null : onRefresh,
                icon: _MachineRefreshIcon(
                  isRefreshing: isRefreshing,
                  color: isRefreshing ? colorScheme.primary : null,
                ),
                tooltip: l.refreshStatus,
                visualDensity: VisualDensity.compact,
              ),
            TextButton.icon(
              onPressed: onAddMachine,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l.add),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),

        if (machines.isEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colorScheme.outlineVariant, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.bubble_chart_outlined,
                        color: colorScheme.outline,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        l.noSavedMachinesDescription,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onAddMachine,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(l.machineEditAddTitle),
                    style: FilledButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          const SizedBox(height: 8),
          ...groups.map(
            (group) => MachineGroupCard(
              group: group,
              startingMachineId: startingMachineId,
              updatingMachineId: updatingMachineId,
              latestBridgeVersion: latestBridgeVersion,
              onConnect: onConnect,
              onStart: onStart,
              onEdit: onEdit,
              onDelete: onDelete,
              onRename: onRenameGroup == null
                  ? null
                  : () => onRenameGroup!(group),
              onToggleFavorite: onToggleFavorite,
              onUpdate: onUpdate,
              onStop: onStop,
            ),
          ),
        ],
      ],
    );
  }
}

class _MachineRefreshIcon extends StatefulWidget {
  final bool isRefreshing;
  final Color? color;

  const _MachineRefreshIcon({required this.isRefreshing, this.color});

  @override
  State<_MachineRefreshIcon> createState() => _MachineRefreshIconState();
}

class _MachineRefreshIconState extends State<_MachineRefreshIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _MachineRefreshIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRefreshing != widget.isRefreshing) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (widget.isRefreshing) {
      _controller.repeat();
    } else {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      key: const ValueKey('machine_status_refresh_arrow'),
      turns: _controller,
      child: Icon(Icons.refresh, size: 20, color: widget.color),
    );
  }
}
