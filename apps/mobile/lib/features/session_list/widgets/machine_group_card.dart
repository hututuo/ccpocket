import 'package:flutter/material.dart';

import '../../../constants/app_constants.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/machine.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/network_endpoint.dart';

enum _RouteAction { edit, favorite, update, stop, delete }

/// Compact computer card that keeps transport routes explicit but secondary.
class MachineGroupCard extends StatelessWidget {
  const MachineGroupCard({
    super.key,
    required this.group,
    required this.onConnect,
    required this.onStart,
    required this.onEdit,
    required this.onDelete,
    this.onRename,
    this.onToggleFavorite,
    this.onUpdate,
    this.onStop,
    this.startingMachineId,
    this.updatingMachineId,
    this.latestBridgeVersion,
  });

  final BridgeMachineGroup group;
  final ValueChanged<MachineWithStatus> onConnect;
  final ValueChanged<MachineWithStatus> onStart;
  final ValueChanged<MachineWithStatus> onEdit;
  final ValueChanged<MachineWithStatus> onDelete;
  final VoidCallback? onRename;
  final ValueChanged<MachineWithStatus>? onToggleFavorite;
  final ValueChanged<MachineWithStatus>? onUpdate;
  final ValueChanged<MachineWithStatus>? onStop;
  final String? startingMachineId;
  final String? updatingMachineId;
  final String? latestBridgeVersion;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final preferred = group.preferredRoute;
    return Card(
      key: ValueKey('machine_group_${group.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      color: group.isFavorite
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.15)
          : null,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey<String>('machine_group_routes_${group.id}'),
        tilePadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        leading: _MachineStatusDot(status: group.status),
        title: _MachineGroupHeader(
          group: group,
          preferred: preferred,
          onConnect: () => onConnect(preferred),
          onDelete: () => onDelete(preferred),
          onRename: onRename,
        ),
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
              child: Text(
                l.machineRoutes,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          ...group.routes.map(
            (route) => _MachineRouteTile(
              route: route,
              isPreferred: route.machine.id == preferred.machine.id,
              isStarting: startingMachineId == route.machine.id,
              isUpdating: updatingMachineId == route.machine.id,
              latestBridgeVersion: latestBridgeVersion,
              onConnect: () => onConnect(route),
              onStart: () => onStart(route),
              onEdit: () => onEdit(route),
              onDelete: () => onDelete(route),
              onToggleFavorite: onToggleFavorite == null
                  ? null
                  : () => onToggleFavorite!(route),
              onUpdate: onUpdate == null ? null : () => onUpdate!(route),
              onStop: onStop == null ? null : () => onStop!(route),
            ),
          ),
        ],
      ),
    );
  }
}

class _MachineGroupHeader extends StatelessWidget {
  const _MachineGroupHeader({
    required this.group,
    required this.preferred,
    required this.onConnect,
    required this.onDelete,
    this.onRename,
  });

  final BridgeMachineGroup group;
  final MachineWithStatus preferred;
  final VoidCallback onConnect;
  final VoidCallback onDelete;
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = switch (group.status) {
      MachineStatus.online => l.machineOnline,
      MachineStatus.offline => l.offline,
      MachineStatus.unreachable => l.unreachable,
      MachineStatus.identityChanged => l.machineIdentityChanged,
      MachineStatus.unknown => l.machineChecking,
    };
    final metadataStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.3,
    );
    final routeAddress = formatHostPort(
      preferred.machine.host,
      preferred.machine.port,
    );
    final routeSummary = group.routes.length > 1
        ? '${l.machinePreferredRoute}: $routeAddress'
        : routeAddress;
    final facts = Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        Text(status, style: metadataStyle),
        Text(l.machineRoutesCount(group.routes.length), style: metadataStyle),
        if (preferred.latencyMs case final latency?)
          Text(l.machineLatency(latency), style: metadataStyle),
      ],
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        facts,
        const SizedBox(height: 4),
        Text(
          routeSummary,
          key: ValueKey('machine_group_route_summary_${group.id}'),
          softWrap: true,
          style: metadataStyle,
        ),
      ],
    );
    final connectButton = FilledButton.tonalIcon(
      key: ValueKey('machine_group_connect_${group.id}'),
      onPressed: group.hasOnlineRoute ? onConnect : null,
      icon: const Icon(Icons.login, size: 16),
      label: Text(l.connect),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: GestureDetector(
                  key: ValueKey('machine_group_delete_gesture_${group.id}'),
                  behavior: HitTestBehavior.opaque,
                  onLongPress: group.routes.length == 1 ? onDelete : null,
                  child: Text(
                    group.displayName,
                    softWrap: true,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
              if (onRename != null)
                IconButton(
                  key: ValueKey('machine_group_rename_${group.id}'),
                  onPressed: onRename,
                  icon: const Icon(Icons.drive_file_rename_outline, size: 18),
                  tooltip: l.renameMachineGroup,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 280) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    details,
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: connectButton,
                    ),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: details),
                  const SizedBox(width: 12),
                  connectButton,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MachineRouteTile extends StatelessWidget {
  const _MachineRouteTile({
    required this.route,
    required this.isPreferred,
    required this.isStarting,
    required this.isUpdating,
    required this.onConnect,
    required this.onStart,
    required this.onEdit,
    required this.onDelete,
    required this.latestBridgeVersion,
    this.onToggleFavorite,
    this.onUpdate,
    this.onStop,
  });

  final MachineWithStatus route;
  final bool isPreferred;
  final bool isStarting;
  final bool isUpdating;
  final VoidCallback onConnect;
  final VoidCallback onStart;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onUpdate;
  final VoidCallback? onStop;
  final String? latestBridgeVersion;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final machine = route.machine;
    final updateTargetVersion =
        latestBridgeVersion != null &&
            compareSemanticVersions(
                  latestBridgeVersion!,
                  AppConstants.expectedBridgeVersion,
                ) >
                0
        ? latestBridgeVersion!
        : AppConstants.expectedBridgeVersion;
    final needsUpdate = route.needsUpdate(updateTargetVersion);
    final isOnline = route.status == MachineStatus.online;
    final routeActions = Row(
      key: ValueKey('machine_route_actions_${machine.id}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isStarting || isUpdating)
          const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (isOnline)
          IconButton(
            key: ValueKey('machine_route_connect_${machine.id}'),
            onPressed: onConnect,
            icon: const Icon(Icons.login, size: 19),
            tooltip: l.connect,
          )
        else if (machine.canStartRemotely)
          IconButton(
            key: ValueKey('machine_route_start_${machine.id}'),
            onPressed: onStart,
            icon: const Icon(Icons.power_settings_new, size: 19),
            tooltip: l.start,
          ),
        PopupMenuButton<_RouteAction>(
          key: ValueKey('machine_route_menu_${machine.id}'),
          onSelected: (action) {
            switch (action) {
              case _RouteAction.edit:
                onEdit();
                return;
              case _RouteAction.favorite:
                onToggleFavorite?.call();
                return;
              case _RouteAction.update:
                onUpdate?.call();
                return;
              case _RouteAction.stop:
                onStop?.call();
                return;
              case _RouteAction.delete:
                onDelete();
                return;
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: _RouteAction.edit, child: Text(l.edit)),
            if (onToggleFavorite != null)
              PopupMenuItem(
                value: _RouteAction.favorite,
                child: Text(machine.isFavorite ? l.unfavorite : l.favorite),
              ),
            if (isOnline &&
                needsUpdate &&
                machine.canStartRemotely &&
                onUpdate != null)
              PopupMenuItem(
                value: _RouteAction.update,
                child: Text(l.updateBridge),
              ),
            if (isOnline && onStop != null)
              PopupMenuItem(
                value: _RouteAction.stop,
                child: Text(l.stopServer),
              ),
            PopupMenuItem(value: _RouteAction.delete, child: Text(l.delete)),
          ],
        ),
      ],
    );
    final routeDetails = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: _MachineStatusDot(status: route.status, size: 9),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                key: ValueKey('machine_route_delete_gesture_${machine.id}'),
                behavior: HitTestBehavior.opaque,
                onLongPress: onDelete,
                child: Text(
                  formatHostPort(machine.host, machine.port),
                  key: ValueKey('machine_route_address_${machine.id}'),
                  softWrap: true,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    height: 1.25,
                  ),
                ),
              ),
              if (isPreferred) ...[
                const SizedBox(height: 4),
                _RouteBadge(label: l.machinePreferredRoute),
              ],
              const SizedBox(height: 4),
              Text(
                _routeSubtitle(l),
                key: ValueKey('machine_route_metadata_${machine.id}'),
                softWrap: true,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return Padding(
      key: ValueKey('machine_route_${machine.id}'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isOnline ? onConnect : null,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final usesLargeText =
                  MediaQuery.textScalerOf(context).scale(14) > 17;
              final stackActions = constraints.maxWidth < 360 || usesLargeText;
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: stackActions
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          routeDetails,
                          const SizedBox(height: 4),
                          Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: routeActions,
                          ),
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(child: routeDetails),
                          const SizedBox(width: 8),
                          routeActions,
                        ],
                      ),
              );
            },
          ),
        ),
      ),
    );
  }

  String _routeSubtitle(AppLocalizations l) {
    final parts = <String>[
      switch (route.status) {
        MachineStatus.online => l.machineOnline,
        MachineStatus.offline => l.offline,
        MachineStatus.unreachable => l.unreachable,
        MachineStatus.identityChanged => l.machineIdentityChanged,
        MachineStatus.unknown => l.machineChecking,
      },
    ];
    if (route.latencyMs case final latency?) {
      parts.add(l.machineLatency(latency));
    }
    if (route.versionInfo case final version?) {
      parts.add('v${version.version}');
    }
    return parts.join(' · ');
  }
}

class _MachineStatusDot extends StatelessWidget {
  const _MachineStatusDot({required this.status, this.size = 12});

  final MachineStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>();
    final scheme = theme.colorScheme;
    final color = switch (status) {
      MachineStatus.online => colors?.statusOnline ?? Colors.green,
      MachineStatus.offline => scheme.error,
      MachineStatus.unreachable => colors?.statusApproval ?? Colors.orange,
      MachineStatus.identityChanged => scheme.error,
      MachineStatus.unknown => colors?.statusIdle ?? scheme.outline,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _RouteBadge extends StatelessWidget {
  const _RouteBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer),
        ),
      ),
    );
  }
}
