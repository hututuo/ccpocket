import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/machine.dart';
import '../../../services/server_discovery_service.dart';
import '../../../utils/platform_helper.dart';
import 'discovered_servers_list.dart';
import 'machine_list.dart';

class ConnectForm extends StatelessWidget {
  final List<DiscoveredServer> discoveredServers;
  final VoidCallback onScanQrCode;
  final VoidCallback? onViewSetupGuide;
  final ValueChanged<DiscoveredServer> onConnectToDiscovered;

  // Machine management
  final List<MachineWithStatus> machines;
  final String? startingMachineId;
  final String? updatingMachineId;
  final String? latestBridgeVersion;
  final bool isRefreshingMachines;
  final ValueChanged<MachineWithStatus>? onConnectToMachine;
  final ValueChanged<MachineWithStatus>? onStartMachine;
  final ValueChanged<MachineWithStatus>? onEditMachine;
  final ValueChanged<MachineWithStatus>? onDeleteMachine;
  final ValueChanged<MachineWithStatus>? onToggleFavorite;
  final ValueChanged<MachineWithStatus>? onUpdateMachine;
  final ValueChanged<MachineWithStatus>? onStopMachine;
  final VoidCallback? onAddMachine;
  final VoidCallback? onRefreshMachines;
  final String? connectionProgressLabel;
  final double? connectionProgressValue;
  final String? connectionNoticeLabel;
  final VoidCallback? onCancelConnection;
  final VoidCallback? onRetryConnection;

  const ConnectForm({
    super.key,
    required this.discoveredServers,
    required this.onScanQrCode,
    this.onViewSetupGuide,
    required this.onConnectToDiscovered,
    // Machine management
    this.machines = const [],
    this.startingMachineId,
    this.updatingMachineId,
    this.latestBridgeVersion,
    this.isRefreshingMachines = false,
    this.onConnectToMachine,
    this.onStartMachine,
    this.onEditMachine,
    this.onDeleteMachine,
    this.onToggleFavorite,
    this.onUpdateMachine,
    this.onStopMachine,
    this.onAddMachine,
    this.onRefreshMachines,
    this.connectionProgressLabel,
    this.connectionProgressValue,
    this.connectionNoticeLabel,
    this.onCancelConnection,
    this.onRetryConnection,
  });

  bool get _hasMachineHandlers =>
      onConnectToMachine != null &&
      onStartMachine != null &&
      onEditMachine != null &&
      onDeleteMachine != null &&
      onAddMachine != null;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final normalizedProgress = connectionProgressValue
        ?.clamp(0.0, 1.0)
        .toDouble();
    final progressPercent = normalizedProgress == null
        ? null
        : (normalizedProgress * 100).round();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                ],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.1),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(
              Icons.terminal,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            l.connectToBridgeServer,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          if (connectionProgressLabel != null) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              label: progressPercent == null
                  ? connectionProgressLabel
                  : '$connectionProgressLabel, $progressPercent%',
              child: Container(
                key: const ValueKey('bridge_connection_progress'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.28),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            value: normalizedProgress,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            connectionProgressLabel!,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (progressPercent != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            '$progressPercent%',
                            key: const ValueKey(
                              'bridge_connection_progress_percent',
                            ),
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ],
                        if (onCancelConnection != null &&
                            connectionNoticeLabel == null)
                          TextButton(
                            key: const ValueKey('cancel_bridge_connection'),
                            onPressed: onCancelConnection,
                            child: Text(l.cancel),
                          ),
                      ],
                    ),
                    if (normalizedProgress != null) ...[
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          key: const ValueKey('bridge_connection_progress_bar'),
                          value: normalizedProgress,
                          minHeight: 5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (connectionNoticeLabel != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const ValueKey('bridge_connection_notice'),
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.errorContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.error.withValues(alpha: 0.25),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 20,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(connectionNoticeLabel!)),
                    ],
                  ),
                  if (onRetryConnection != null || onCancelConnection != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 4,
                        children: [
                          if (onCancelConnection != null)
                            TextButton(
                              key: const ValueKey(
                                'cancel_bridge_connection_notice',
                              ),
                              onPressed: onCancelConnection,
                              child: Text(l.cancel),
                            ),
                          if (onRetryConnection != null)
                            FilledButton.tonal(
                              key: const ValueKey('retry_bridge_connection'),
                              onPressed: onRetryConnection,
                              child: Text(l.retry),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),

          // Machines section (favorites + recent)
          if (_hasMachineHandlers) ...[
            MachineList(
              machines: machines,
              startingMachineId: startingMachineId,
              updatingMachineId: updatingMachineId,
              latestBridgeVersion: latestBridgeVersion,
              isRefreshing: isRefreshingMachines,
              onConnect: onConnectToMachine!,
              onStart: onStartMachine!,
              onEdit: onEditMachine!,
              onDelete: onDeleteMachine!,
              onToggleFavorite: onToggleFavorite,
              onUpdate: onUpdateMachine,
              onStop: onStopMachine,
              onAddMachine: onAddMachine!,
              onRefresh: onRefreshMachines,
            ),
          ],

          // Discovered servers via mDNS
          if (discoveredServers.isNotEmpty) ...[
            const SizedBox(height: 16),
            DiscoveredServersList(
              servers: discoveredServers,
              onConnect: onConnectToDiscovered,
            ),
          ],

          const SizedBox(height: 24),

          // Action buttons
          if (!kIsWeb && !isDesktopPlatform) ...[
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                key: const ValueKey('scan_qr_button'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHigh,
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  elevation: 0,
                ),
                onPressed: onScanQrCode,
                icon: Icon(
                  Icons.qr_code_scanner,
                  color: Theme.of(context).colorScheme.primary,
                ),
                label: Text(
                  l.scanQrCode,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (onViewSetupGuide != null) ...[
            TextButton.icon(
              key: const ValueKey('setup_guide_button'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: onViewSetupGuide,
              icon: Icon(
                Icons.lightbulb_outline,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              label: Text(
                l.setupGuide,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
