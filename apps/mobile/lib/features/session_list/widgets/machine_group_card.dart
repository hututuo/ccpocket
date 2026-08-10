import 'package:flutter/material.dart';

import '../../../constants/app_constants.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/machine.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/network_endpoint.dart';

enum _RouteAction { edit, favorite, stop, delete }

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
    this.onStop,
    this.startingMachineId,
    this.updatingMachineId,
  });

  final BridgeMachineGroup group;
  final ValueChanged<MachineWithStatus> onConnect;
  final ValueChanged<MachineWithStatus> onStart;
  final ValueChanged<MachineWithStatus> onEdit;
  final ValueChanged<MachineWithStatus> onDelete;
  final VoidCallback? onRename;
  final ValueChanged<MachineWithStatus>? onToggleFavorite;
  final ValueChanged<MachineWithStatus>? onStop;
  final String? startingMachineId;
  final String? updatingMachineId;

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
        tilePadding: const EdgeInsetsDirectional.fromSTEB(12, 0, 4, 0),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        visualDensity: VisualDensity.compact,
        minTileHeight: 58,
        leading: _MachineStatusDot(status: group.status),
        title: _MachineGroupHeader(
          group: group,
          preferred: preferred,
          onConnect: () => onConnect(preferred),
          onDelete: () => onDelete(preferred),
        ),
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 2, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l.machineRoutes,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (onRename != null)
                  IconButton(
                    key: ValueKey('machine_group_rename_${group.id}'),
                    onPressed: onRename,
                    icon: const Icon(Icons.drive_file_rename_outline, size: 17),
                    tooltip: l.renameMachineGroup,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 44,
                      height: 44,
                    ),
                  ),
              ],
            ),
          ),
          ...group.routes.map(
            (route) => _MachineRouteTile(
              route: route,
              isPreferred: route.machine.id == preferred.machine.id,
              isStarting: startingMachineId == route.machine.id,
              isUpdating: updatingMachineId == route.machine.id,
              onConnect: () => onConnect(route),
              onStart: () => onStart(route),
              onEdit: () => onEdit(route),
              onDelete: () => onDelete(route),
              onToggleFavorite: onToggleFavorite == null
                  ? null
                  : () => onToggleFavorite!(route),
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
  });

  final BridgeMachineGroup group;
  final MachineWithStatus preferred;
  final VoidCallback onConnect;
  final VoidCallback onDelete;

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
    final metadataStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.15,
    );
    final summaryParts = <String>[status];
    if (preferred.latencyMs case final latency?) {
      summaryParts.add(l.machineLatency(latency));
    }
    final connectButton = IconButton.filledTonal(
      key: ValueKey('machine_group_connect_${group.id}'),
      onPressed: group.hasOnlineRoute ? onConnect : null,
      icon: const Icon(Icons.login, size: 16),
      tooltip: l.connect,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                key: ValueKey('machine_group_delete_gesture_${group.id}'),
                behavior: HitTestBehavior.opaque,
                onLongPress: group.routes.length == 1 ? onDelete : null,
                child: Text(
                  group.displayName,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              l.machineRoutesCount(group.routes.length),
              style: metadataStyle,
            ),
            const SizedBox(width: 4),
            connectButton,
          ],
        ),
        Text(
          summaryParts.join(' · '),
          key: ValueKey('machine_group_route_summary_${group.id}'),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.fade,
          style: metadataStyle,
        ),
      ],
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
    this.onToggleFavorite,
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
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final machine = route.machine;
    final isOnline = route.status == MachineStatus.online;
    final compatibilityWarning = _compatibilityWarning(l);
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
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          )
        else if (machine.canStartRemotely)
          IconButton(
            key: ValueKey('machine_route_start_${machine.id}'),
            onPressed: onStart,
            icon: const Icon(Icons.power_settings_new, size: 19),
            tooltip: l.start,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
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
            if (isOnline && onStop != null)
              PopupMenuItem(
                value: _RouteAction.stop,
                child: Text(l.stopServer),
              ),
            PopupMenuItem(value: _RouteAction.delete, child: Text(l.delete)),
          ],
          iconSize: 19,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        ),
      ],
    );
    final routeDetails = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _MachineStatusDot(status: route.status, size: 8),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      key: ValueKey(
                        'machine_route_delete_gesture_${machine.id}',
                      ),
                      behavior: HitTestBehavior.opaque,
                      onLongPress: onDelete,
                      child: Text(
                        formatHostPort(machine.host, machine.port),
                        key: ValueKey('machine_route_address_${machine.id}'),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                      ),
                    ),
                  ),
                  if (isPreferred) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: l.machinePreferredRoute,
                      child: Icon(
                        Icons.route_outlined,
                        key: ValueKey('machine_route_preferred_${machine.id}'),
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                  if (compatibilityWarning != null) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: compatibilityWarning,
                      child: Icon(
                        Icons.warning_amber_rounded,
                        key: ValueKey(
                          'machine_route_compatibility_warning_${machine.id}',
                        ),
                        size: 17,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 1),
              Text(
                _routeSubtitle(l),
                key: ValueKey('machine_route_metadata_${machine.id}'),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.1,
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
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(10, 5, 2, 5),
            child: Row(
              children: [
                Expanded(child: routeDetails),
                const SizedBox(width: 4),
                routeActions,
              ],
            ),
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
    return parts.join(' · ');
  }

  String? _compatibilityWarning(AppLocalizations l) {
    final version = route.versionInfo;
    if (version == null) return null;
    final compatibility = compareClientBridgeCompatibility(
      bridgeRevision: version.clientBridgeCompatibilityRevision,
      mobileRevision: AppConstants.clientBridgeCompatibilityRevision,
    );
    final warning = switch (compatibility) {
      ClientBridgeCompatibility.bridgeOlder => l.clientBridgeBridgeOlder,
      ClientBridgeCompatibility.mobileOlder => l.clientBridgeMobileOlder,
      ClientBridgeCompatibility.matched => null,
    };
    return warning == null ? null : 'v${version.version} · $warning';
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
