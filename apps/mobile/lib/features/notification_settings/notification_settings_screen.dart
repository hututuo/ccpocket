import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../l10n/app_localizations.dart';
import '../../models/notification_preferences.dart';
import '../../services/bridge_service.dart';
import '../../services/notification_service.dart';
import '../permission_management/l10n/permission_management_strings.dart';
import '../permission_management/permission_management_screen.dart';
import '../settings/state/settings_cubit.dart';
import '../settings/state/settings_state.dart';
import 'l10n/notification_settings_strings.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  late Future<NotificationPermissionStatus> _permissionStatus;

  @override
  void initState() {
    super.initState();
    _refreshPermissionStatus();
  }

  void _refreshPermissionStatus() {
    _permissionStatus = NotificationService.instance.permissionStatus();
  }

  Future<void> _requestPermission() async {
    await NotificationService.instance.requestPermission();
    if (!mounted) return;
    setState(_refreshPermissionStatus);
  }

  Future<void> _toggleNotifications(bool enabled) async {
    if (enabled) {
      await NotificationService.instance.requestPermission();
      if (mounted) setState(_refreshPermissionStatus);
    }
    if (!mounted) return;
    await context.read<SettingsCubit>().toggleFcm(enabled);
  }

  @override
  Widget build(BuildContext context) {
    final strings = NotificationSettingsStrings.of(context);
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(strings.title)),
      body: BlocBuilder<SettingsCubit, SettingsState>(
        builder: (context, state) {
          final preferences = state.notificationPreferences;
          final bridge = context.read<BridgeService>();

          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _SectionHeader(strings.deliverySection),
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    SwitchListTile(
                      key: const ValueKey('notification_master_toggle'),
                      secondary: state.fcmSyncInProgress
                          ? const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              Icons.notifications_active_outlined,
                              color: cs.primary,
                            ),
                      title: Text(strings.masterTitle),
                      subtitle: Text(
                        state.activeMachineId == null
                            ? strings.masterDisconnectedSubtitle
                            : strings.masterConnectedSubtitle,
                      ),
                      value: state.fcmEnabled,
                      onChanged:
                          state.activeMachineId == null ||
                              state.fcmSyncInProgress
                          ? null
                          : _toggleNotifications,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    FutureBuilder<NotificationPermissionStatus>(
                      future: _permissionStatus,
                      builder: (context, snapshot) {
                        final status =
                            snapshot.data ??
                            NotificationPermissionStatus.unavailable;
                        final (icon, color, subtitle) = switch (status) {
                          NotificationPermissionStatus.enabled => (
                            Icons.check_circle_outline,
                            cs.primary,
                            strings.localEnabled,
                          ),
                          NotificationPermissionStatus.disabled => (
                            Icons.notifications_off_outlined,
                            cs.error,
                            strings.localDisabled,
                          ),
                          NotificationPermissionStatus.unavailable => (
                            Icons.help_outline,
                            cs.onSurfaceVariant,
                            strings.localUnavailable,
                          ),
                        };
                        return ListTile(
                          leading: Icon(icon, color: color),
                          title: Text(strings.localNotifications),
                          subtitle: Text(subtitle),
                          trailing:
                              status == NotificationPermissionStatus.disabled
                              ? TextButton(
                                  onPressed: _requestPermission,
                                  child: Text(strings.requestPermission),
                                )
                              : null,
                        );
                      },
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _RemoteStatusTile(state: state, strings: strings),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 2),
                child: Text(
                  strings.selfSignedExplanation,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
              _SectionHeader(strings.typesSection),
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    _PreferenceSwitch(
                      key: const ValueKey('notification_action_toggle'),
                      icon: Icons.priority_high_rounded,
                      title: strings.actionRequiredTitle,
                      subtitle: strings.actionRequiredSubtitle,
                      value: preferences.actionRequired,
                      enabled: !state.fcmSyncInProgress,
                      onChanged: (value) => _updatePreferences(
                        preferences.copyWith(actionRequired: value),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _PreferenceSwitch(
                      key: const ValueKey('notification_completed_toggle'),
                      icon: Icons.task_alt_rounded,
                      title: strings.taskCompletedTitle,
                      subtitle: strings.taskCompletedSubtitle,
                      value: preferences.taskCompleted,
                      enabled: !state.fcmSyncInProgress,
                      onChanged: (value) => _updatePreferences(
                        preferences.copyWith(taskCompleted: value),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _PreferenceSwitch(
                      key: const ValueKey('notification_failed_toggle'),
                      icon: Icons.error_outline_rounded,
                      title: strings.taskFailedTitle,
                      subtitle: strings.taskFailedSubtitle,
                      value: preferences.taskFailed,
                      enabled: !state.fcmSyncInProgress,
                      onChanged: (value) => _updatePreferences(
                        preferences.copyWith(taskFailed: value),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _PreferenceSwitch(
                      key: const ValueKey('notification_progress_toggle'),
                      icon: Icons.pending_actions_outlined,
                      title: strings.progressTitle,
                      subtitle: strings.progressSubtitle,
                      value: preferences.progress,
                      enabled: !state.fcmSyncInProgress,
                      onChanged: (value) => _updatePreferences(
                        preferences.copyWith(progress: value),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _PreferenceSwitch(
                      key: const ValueKey('notification_foreground_toggle'),
                      icon: Icons.web_asset_outlined,
                      title: strings.foregroundTitle,
                      subtitle: strings.foregroundSubtitle,
                      value: preferences.showWhileAppOpen,
                      enabled: true,
                      onChanged: (value) => _updatePreferences(
                        preferences.copyWith(showWhileAppOpen: value),
                      ),
                    ),
                  ],
                ),
              ),
              _SectionHeader(strings.contentSection),
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.visibility_off_outlined),
                      title: Text(l.pushPrivacyMode),
                      subtitle: Text(l.pushPrivacyModeSubtitle),
                      value: state.fcmPrivacy,
                      onChanged:
                          state.activeMachineId == null ||
                              !state.fcmEnabled ||
                              state.fcmSyncInProgress
                          ? null
                          : (value) => context
                                .read<SettingsCubit>()
                                .toggleFcmPrivacy(value),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.translate_outlined),
                      title: Text(l.updateNotificationLanguage),
                      trailing: state.fcmSyncInProgress
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right, size: 20),
                      onTap: !state.fcmEnabled || state.fcmSyncInProgress
                          ? null
                          : _syncLanguage,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.admin_panel_settings_outlined),
                      title: Text(
                        PermissionManagementStrings.of(context).title,
                      ),
                      subtitle: Text(
                        PermissionManagementStrings.of(context).subtitle,
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => PermissionManagementScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _BridgeCompatibilityNotice(
                bridge: bridge,
                connectedMachine: state.activeMachineId != null,
                strings: strings,
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _updatePreferences(NotificationPreferences preferences) async {
    await context.read<SettingsCubit>().setNotificationPreferences(preferences);
  }

  Future<void> _syncLanguage() async {
    final cubit = context.read<SettingsCubit>();
    final l = AppLocalizations.of(context);
    await cubit.syncPushLocale();
    if (!mounted) return;
    final status = cubit.state.fcmStatusKey;
    final success =
        status == FcmStatusKey.enabled || status == FcmStatusKey.enabledPending;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? l.notificationLanguageUpdated : l.fcmTokenFailed,
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

class _BridgeCompatibilityNotice extends StatelessWidget {
  const _BridgeCompatibilityNotice({
    required this.bridge,
    required this.connectedMachine,
    required this.strings,
  });

  final BridgeService bridge;
  final bool connectedMachine;
  final NotificationSettingsStrings strings;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Object?>(
      stream: bridge.sessionList,
      builder: (context, _) {
        final supported = bridge.bridgeCapabilities.contains(
          NotificationPreferences.bridgeCapability,
        );
        if (!connectedMachine || supported) return const SizedBox.shrink();

        final cs = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Card(
            color: cs.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: cs.onTertiaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      strings.oldBridgeWarning,
                      style: TextStyle(
                        color: cs.onTertiaryContainer,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RemoteStatusTile extends StatelessWidget {
  const _RemoteStatusTile({required this.state, required this.strings});

  final SettingsState state;
  final NotificationSettingsStrings strings;

  @override
  Widget build(BuildContext context) {
    final (icon, color, subtitle) = _status(context);
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(strings.remoteNotifications),
      subtitle: Text(subtitle),
    );
  }

  (IconData, Color, String) _status(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (!state.fcmEnabled) {
      return (
        Icons.cloud_off_outlined,
        cs.onSurfaceVariant,
        strings.remoteDisabled,
      );
    }
    if (state.fcmAvailable &&
        (state.fcmStatusKey == FcmStatusKey.enabled ||
            state.fcmStatusKey == FcmStatusKey.enabledPending)) {
      if (state.fcmStatusKey == FcmStatusKey.enabledPending) {
        return (Icons.cloud_sync_outlined, cs.tertiary, strings.remotePending);
      }
      return (Icons.cloud_done_outlined, cs.primary, strings.remoteEnabled);
    }
    if (state.fcmStatusKey == FcmStatusKey.unavailable ||
        state.fcmStatusKey == FcmStatusKey.tokenFailed) {
      return (Icons.cloud_off_outlined, cs.error, strings.remoteUnavailable);
    }
    return (Icons.cloud_sync_outlined, cs.tertiary, strings.remotePending);
  }
}

class _PreferenceSwitch extends StatelessWidget {
  const _PreferenceSwitch({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
