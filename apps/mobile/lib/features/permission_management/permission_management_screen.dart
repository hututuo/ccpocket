import 'dart:async';

import 'package:flutter/material.dart';

import 'l10n/permission_management_strings.dart';
import 'permission_host_service.dart';

class PermissionManagementScreen extends StatefulWidget {
  PermissionManagementScreen({super.key, PermissionHostService? service})
    : service = service ?? PermissionHostService.instance;

  final PermissionHostService service;

  @override
  State<PermissionManagementScreen> createState() =>
      _PermissionManagementScreenState();
}

class _PermissionManagementScreenState extends State<PermissionManagementScreen>
    with WidgetsBindingObserver {
  PermissionHostSnapshot? _snapshot;
  MobilePermission? _busyPermission;
  bool _loading = true;
  int _operation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh(showLoading: false));
    }
  }

  Future<void> _refresh({bool showLoading = true}) async {
    final operation = ++_operation;
    if (showLoading && mounted) setState(() => _loading = true);
    final snapshot = await widget.service.getSnapshot();
    if (!mounted || operation != _operation) return;
    setState(() {
      _snapshot = snapshot;
      _loading = false;
      _busyPermission = null;
    });
  }

  Future<void> _request(MobilePermission permission) async {
    final operation = ++_operation;
    setState(() => _busyPermission = permission);
    final snapshot = await widget.service.requestFromUserAction(permission);
    if (!mounted || operation != _operation) return;
    setState(() {
      _snapshot = snapshot;
      _loading = false;
      _busyPermission = null;
    });
    if (!snapshot.supported) _showActionFailed();
  }

  Future<void> _openSettings() async {
    final opened = await widget.service.openAppSettings();
    if (!mounted || opened) return;
    _showActionFailed();
  }

  void _showActionFailed() {
    final l = PermissionManagementStrings.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.actionFailed)));
  }

  @override
  Widget build(BuildContext context) {
    final l = PermissionManagementStrings.of(context);
    final snapshot = _snapshot;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.title),
        actions: [
          IconButton(
            key: const ValueKey('permission_refresh_button'),
            tooltip: l.refreshTooltip,
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading && snapshot == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                key: const ValueKey('permission_management_list'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  const _PermissionPolicyCard(),
                  const SizedBox(height: 16),
                  if (snapshot == null || !snapshot.supported)
                    const _PermissionHostUnavailableCard()
                  else
                    _PermissionListCard(
                      snapshot: snapshot,
                      busyPermission: _busyPermission,
                      onRequest: _request,
                      onOpenSettings: _openSettings,
                    ),
                ],
              ),
            ),
    );
  }
}

class _PermissionPolicyCard extends StatelessWidget {
  const _PermissionPolicyCard();

  @override
  Widget build(BuildContext context) {
    final l = PermissionManagementStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: cs.secondaryContainer.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.privacy_tip_outlined, color: cs.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l.intro,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSecondaryContainer,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionHostUnavailableCard extends StatelessWidget {
  const _PermissionHostUnavailableCard();

  @override
  Widget build(BuildContext context) {
    final l = PermissionManagementStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('permission_host_unavailable_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.system_update_alt, color: cs.tertiary, size: 32),
            const SizedBox(height: 12),
            Text(
              l.appUpdateRequired,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionListCard extends StatelessWidget {
  const _PermissionListCard({
    required this.snapshot,
    required this.busyPermission,
    required this.onRequest,
    required this.onOpenSettings,
  });

  final PermissionHostSnapshot snapshot;
  final MobilePermission? busyPermission;
  final ValueChanged<MobilePermission> onRequest;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (
            var index = 0;
            index < MobilePermission.values.length;
            index++
          ) ...[
            _PermissionTile(
              state: snapshot.stateFor(MobilePermission.values[index]),
              busy: busyPermission == MobilePermission.values[index],
              onRequest: onRequest,
              onOpenSettings: onOpenSettings,
            ),
            if (index != MobilePermission.values.length - 1)
              const Divider(height: 1, indent: 56),
          ],
        ],
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.state,
    required this.busy,
    required this.onRequest,
    required this.onOpenSettings,
  });

  final MobilePermissionState state;
  final bool busy;
  final ValueChanged<MobilePermission> onRequest;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final copy = _PermissionCopy.of(context, state.permission);
    final action = _PermissionAction.from(state);
    final l = PermissionManagementStrings.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
      child: ListTile(
        key: ValueKey('permission_${state.permission.id}_tile'),
        leading: Icon(copy.icon),
        title: Text(copy.title),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(copy.description),
              const SizedBox(height: 7),
              _PermissionStatusBadge(status: state.status),
            ],
          ),
        ),
        trailing: busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : switch (action) {
                _PermissionAction.request => TextButton(
                  key: ValueKey(
                    'permission_${state.permission.id}_request_button',
                  ),
                  onPressed: () => onRequest(state.permission),
                  child: Text(l.requestAction),
                ),
                _PermissionAction.openSettings => IconButton(
                  key: ValueKey(
                    'permission_${state.permission.id}_settings_button',
                  ),
                  tooltip: l.openSettingsAction,
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.open_in_new, size: 20),
                ),
                _PermissionAction.none => null,
              },
        isThreeLine: true,
      ),
    );
  }
}

enum _PermissionAction {
  request,
  openSettings,
  none;

  static _PermissionAction from(MobilePermissionState state) {
    return switch (state.requestMode) {
      MobilePermissionRequestMode.direct => request,
      MobilePermissionRequestMode.openSettings ||
      MobilePermissionRequestMode.featureTriggered => openSettings,
      MobilePermissionRequestMode.none ||
      MobilePermissionRequestMode.systemPicker ||
      MobilePermissionRequestMode.unavailable => none,
    };
  }
}

class _PermissionStatusBadge extends StatelessWidget {
  const _PermissionStatusBadge({required this.status});

  final MobilePermissionStatus status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = _statusLabel(PermissionManagementStrings.of(context), status);
    final blocked =
        status == MobilePermissionStatus.denied ||
        status == MobilePermissionStatus.restricted;
    final granted =
        status == MobilePermissionStatus.authorized ||
        status == MobilePermissionStatus.limited ||
        status == MobilePermissionStatus.provisional ||
        status == MobilePermissionStatus.ephemeral;
    final foreground = blocked
        ? cs.error
        : granted
        ? cs.primary
        : cs.onSurfaceVariant;

    return Semantics(
      label: text,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: foreground.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Text(
            text,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

String _statusLabel(
  PermissionManagementStrings l,
  MobilePermissionStatus status,
) => switch (status) {
  MobilePermissionStatus.notDetermined => l.statusNotDetermined,
  MobilePermissionStatus.authorized => l.statusAuthorized,
  MobilePermissionStatus.denied => l.statusDenied,
  MobilePermissionStatus.restricted => l.statusRestricted,
  MobilePermissionStatus.limited => l.statusLimited,
  MobilePermissionStatus.provisional => l.statusProvisional,
  MobilePermissionStatus.ephemeral => l.statusEphemeral,
  MobilePermissionStatus.systemManaged => l.statusSystemManaged,
  MobilePermissionStatus.unavailable => l.statusUnavailable,
  MobilePermissionStatus.unknown => l.statusUnknown,
};

class _PermissionCopy {
  const _PermissionCopy({
    required this.title,
    required this.description,
    required this.icon,
  });

  final String title;
  final String description;
  final IconData icon;

  static _PermissionCopy of(BuildContext context, MobilePermission permission) {
    final l = PermissionManagementStrings.of(context);
    return switch (permission) {
      MobilePermission.notifications => _PermissionCopy(
        title: l.notificationsTitle,
        description: l.notificationsDescription,
        icon: Icons.notifications_outlined,
      ),
      MobilePermission.camera => _PermissionCopy(
        title: l.cameraTitle,
        description: l.cameraDescription,
        icon: Icons.photo_camera_outlined,
      ),
      MobilePermission.microphone => _PermissionCopy(
        title: l.microphoneTitle,
        description: l.microphoneDescription,
        icon: Icons.mic_none_outlined,
      ),
      MobilePermission.speechRecognition => _PermissionCopy(
        title: l.speechRecognitionTitle,
        description: l.speechRecognitionDescription,
        icon: Icons.record_voice_over_outlined,
      ),
      MobilePermission.localNetwork => _PermissionCopy(
        title: l.localNetworkTitle,
        description: l.localNetworkDescription,
        icon: Icons.lan_outlined,
      ),
      MobilePermission.files => _PermissionCopy(
        title: l.filesTitle,
        description: l.filesDescription,
        icon: Icons.folder_open_outlined,
      ),
    };
  }
}
