import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'l10n/mobile_update_strings.dart';
import 'mobile_update_models.dart';
import 'mobile_update_service.dart';

class MobileUpdateScreen extends StatefulWidget {
  const MobileUpdateScreen({super.key});

  @override
  State<MobileUpdateScreen> createState() => _MobileUpdateScreenState();
}

class _MobileUpdateScreenState extends State<MobileUpdateScreen> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final l = MobileUpdateStrings.of(context);
    final service = context.watch<MobileUpdateService>();
    final state = service.state;
    return Scaffold(
      appBar: AppBar(title: Text(l.title)),
      body: ListView(
        key: const ValueKey('mobile_update_list'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _UpdateStatusCard(
            state: state,
            packageInfo: _packageInfo,
            onCheck: service.checkManually,
            onDownload: service.downloadAvailableUpdate,
            onRetry: service.retry,
          ),
          const SizedBox(height: 16),
          _UpdateModeCard(
            state: state,
            onChanged: state.isBusy ? null : service.setMode,
          ),
          if (state.developerSettingsUnlocked) ...[
            const SizedBox(height: 16),
            _UpdateChannelCard(
              state: state,
              onChanged: state.isBusy ? null : service.setChannel,
            ),
          ],
        ],
      ),
    );
  }
}

class _UpdateStatusCard extends StatelessWidget {
  const _UpdateStatusCard({
    required this.state,
    required this.packageInfo,
    required this.onCheck,
    required this.onDownload,
    required this.onRetry,
  });

  final MobileUpdateState state;
  final Future<PackageInfo> packageInfo;
  final Future<void> Function() onCheck;
  final Future<void> Function() onDownload;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l = MobileUpdateStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    final status = _statusCopy(l);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_statusIcon, color: _statusColor(cs)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    status,
                    key: const ValueKey('mobile_update_status'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _ChannelBadge(channel: state.checkedChannel ?? state.channel),
              ],
            ),
            if (state.phase == MobileUpdatePhase.downloading) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(
                key: ValueKey('mobile_update_download_progress'),
              ),
            ],
            const SizedBox(height: 16),
            FutureBuilder<PackageInfo>(
              future: packageInfo,
              builder: (context, snapshot) {
                final info = snapshot.data;
                return _UpdateMetadata(
                  baseVersion: info == null
                      ? '—'
                      : '${info.version}+${info.buildNumber}',
                  state: state,
                );
              },
            ),
            if (state.phase == MobileUpdatePhase.restartRequired) ...[
              const SizedBox(height: 12),
              Text(l.restartMessage, style: TextStyle(color: cs.primary)),
            ],
            if (state.phase == MobileUpdatePhase.failed) ...[
              const SizedBox(height: 12),
              Text(
                l.failure(state.failureKind),
                key: const ValueKey('mobile_update_error'),
                style: TextStyle(color: cs.error),
              ),
              if (state.failureDetail case final detail?) ...[
                const SizedBox(height: 4),
                Text(
                  detail,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ],
            const SizedBox(height: 18),
            if (state.phase == MobileUpdatePhase.updateAvailable)
              FilledButton.icon(
                key: const ValueKey('mobile_update_download_button'),
                onPressed: state.isBusy ? null : onDownload,
                icon: const Icon(Icons.download_outlined),
                label: Text(l.downloadUpdate),
              )
            else if (state.phase == MobileUpdatePhase.failed)
              FilledButton.icon(
                key: const ValueKey('mobile_update_retry_button'),
                onPressed: state.isBusy ? null : onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(l.retry),
              )
            else
              FilledButton.icon(
                key: const ValueKey('mobile_update_check_button'),
                onPressed:
                    state.isBusy || state.phase == MobileUpdatePhase.unavailable
                    ? null
                    : onCheck,
                icon: state.phase == MobileUpdatePhase.checking
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.system_update_alt),
                label: Text(
                  state.phase == MobileUpdatePhase.checking
                      ? l.checking
                      : l.checkNow,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _statusCopy(MobileUpdateStrings l) => switch (state.phase) {
    MobileUpdatePhase.checking => l.checking,
    MobileUpdatePhase.upToDate => l.upToDate,
    MobileUpdatePhase.updateAvailable => l.updateAvailable,
    MobileUpdatePhase.downloading => l.downloading,
    MobileUpdatePhase.restartRequired => l.restartRequired,
    MobileUpdatePhase.unavailable => l.unavailable,
    MobileUpdatePhase.failed => l.failure(state.failureKind),
    MobileUpdatePhase.idle => l.neverChecked,
  };

  IconData get _statusIcon => switch (state.phase) {
    MobileUpdatePhase.upToDate => Icons.check_circle_outline,
    MobileUpdatePhase.updateAvailable => Icons.new_releases_outlined,
    MobileUpdatePhase.restartRequired => Icons.restart_alt,
    MobileUpdatePhase.unavailable ||
    MobileUpdatePhase.failed => Icons.error_outline,
    MobileUpdatePhase.downloading => Icons.downloading_outlined,
    MobileUpdatePhase.checking => Icons.sync,
    MobileUpdatePhase.idle => Icons.system_update_outlined,
  };

  Color _statusColor(ColorScheme cs) => switch (state.phase) {
    MobileUpdatePhase.unavailable || MobileUpdatePhase.failed => cs.error,
    MobileUpdatePhase.upToDate => cs.tertiary,
    _ => cs.primary,
  };
}

class _UpdateMetadata extends StatelessWidget {
  const _UpdateMetadata({required this.baseVersion, required this.state});

  final String baseVersion;
  final MobileUpdateState state;

  @override
  Widget build(BuildContext context) {
    final l = MobileUpdateStrings.of(context);
    final checkedAt = state.lastCheckedAt;
    final localCheckedAt = checkedAt?.toLocal();
    final target = state.targetPatchNumber;
    final showTarget =
        state.phase == MobileUpdatePhase.updateAvailable ||
        state.phase == MobileUpdatePhase.restartRequired;
    return Column(
      children: [
        _MetadataRow(label: l.currentVersion, value: baseVersion),
        _MetadataRow(
          label: l.currentPatch,
          value: state.currentPatchNumber?.toString() ?? '—',
        ),
        if (showTarget)
          _MetadataRow(
            label: l.targetPatch,
            value: target?.toString() ?? l.latestPatch,
          ),
        _MetadataRow(
          label: l.lastChecked,
          value: localCheckedAt == null
              ? l.neverChecked
              : '${MaterialLocalizations.of(context).formatFullDate(localCheckedAt)} '
                    '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(localCheckedAt), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}',
        ),
      ],
    );
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: style?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: style)),
        ],
      ),
    );
  }
}

class _UpdateModeCard extends StatelessWidget {
  const _UpdateModeCard({required this.state, required this.onChanged});

  final MobileUpdateState state;
  final Future<void> Function(MobileUpdateMode)? onChanged;

  @override
  Widget build(BuildContext context) {
    final l = MobileUpdateStrings.of(context);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Text(
              l.modeTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          RadioGroup<MobileUpdateMode>(
            groupValue: state.mode,
            onChanged: (value) {
              if (value != null && onChanged != null) onChanged!(value);
            },
            child: Column(
              children: [
                RadioListTile<MobileUpdateMode>(
                  key: const ValueKey('mobile_update_mode_automatic'),
                  value: MobileUpdateMode.automatic,
                  enabled: onChanged != null,
                  title: Text(l.automaticMode),
                  subtitle: Text(l.automaticModeDescription),
                ),
                RadioListTile<MobileUpdateMode>(
                  key: const ValueKey('mobile_update_mode_silent'),
                  value: MobileUpdateMode.silent,
                  enabled: onChanged != null,
                  title: Text(l.silentMode),
                  subtitle: Text(l.silentModeDescription),
                ),
                RadioListTile<MobileUpdateMode>(
                  key: const ValueKey('mobile_update_mode_manual'),
                  value: MobileUpdateMode.manual,
                  enabled: onChanged != null,
                  title: Text(l.manualMode),
                  subtitle: Text(l.manualModeDescription),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UpdateChannelCard extends StatelessWidget {
  const _UpdateChannelCard({required this.state, required this.onChanged});

  final MobileUpdateState state;
  final Future<bool> Function(MobileUpdateChannel)? onChanged;

  @override
  Widget build(BuildContext context) {
    final l = MobileUpdateStrings.of(context);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Text(
              l.channel,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          RadioGroup<MobileUpdateChannel>(
            groupValue: state.channel,
            onChanged: (value) {
              if (value != null && onChanged != null) onChanged!(value);
            },
            child: Column(
              children: [
                RadioListTile<MobileUpdateChannel>(
                  key: const ValueKey('mobile_update_channel_stable'),
                  value: MobileUpdateChannel.stable,
                  enabled: onChanged != null,
                  title: Text(l.stableChannel),
                ),
                RadioListTile<MobileUpdateChannel>(
                  key: const ValueKey('mobile_update_channel_owner'),
                  value: MobileUpdateChannel.owner,
                  enabled: onChanged != null,
                  title: Text(l.ownerChannel),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              l.ownerWarning,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelBadge extends StatelessWidget {
  const _ChannelBadge({required this.channel});

  final MobileUpdateChannel channel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(
          channel.name,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: cs.onSecondaryContainer),
        ),
      ),
    );
  }
}
