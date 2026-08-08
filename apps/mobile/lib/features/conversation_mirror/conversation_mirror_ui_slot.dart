import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/messages.dart';
import '../../services/bridge_service.dart';
import '../local_session_features/host/local_session_feature.dart';
import 'conversation_mirror_service.dart';
import 'conversation_mirror_strings.dart';
import 'conversation_mirror_target.dart';

final LocalSessionFeatureSlot conversationMirrorUiSlot =
    _ConversationMirrorUiSlot();

class _ConversationMirrorUiSlot extends LocalSessionFeatureSlot {
  @override
  String get featureId => 'conversation_mirror_resident';

  @override
  List<SessionMenuAction> overflowActions(CodexSessionFeatureContext context) {
    final service = context.context.read<ConversationMirrorService?>();
    final session = _sessionForRuntime(context.bridge, context.sessionId);
    final target = _targetForRuntime(context.bridge, context.sessionId);
    if (service == null ||
        !service.isAvailable ||
        session?.provider != Provider.codex.value ||
        target == null ||
        !service.hasLocalCopyTarget(target)) {
      return const [];
    }
    return [
      SessionMenuAction(
        featureId: featureId,
        label: ConversationMirrorStrings.of(context.context).manageResident,
        icon: service.isResidentTarget(target)
            ? Icons.offline_pin
            : Icons.check_circle_outline,
        order: 28,
      ),
    ];
  }

  @override
  WorkspaceFeaturePaneDescriptor get paneDescriptor =>
      WorkspaceFeaturePaneDescriptor(
        featureId: featureId,
        title: (context) =>
            ConversationMirrorStrings.of(context).manageResident,
        builder: (context) => ConversationMirrorResidentPanel(
          runtimeSessionId: context.sessionId,
          bridge: context.bridge,
        ),
        sheetHeightFactor: 0.62,
        rememberPerSession: false,
      );
}

ConversationMirrorTarget? _targetForRuntime(
  BridgeService bridge,
  String runtimeSessionId,
) {
  final session = _sessionForRuntime(bridge, runtimeSessionId);
  if (session == null || session.provider != Provider.codex.value) return null;
  final durableId = bridge.providerSessionIdForRuntime(
    runtimeSessionId,
    provider: Provider.codex.value,
  );
  return ConversationMirrorTarget.fromRunning(
    session,
    providerSessionId: durableId,
    codexSourceId: bridge.codexSourceId,
  );
}

SessionInfo? _sessionForRuntime(BridgeService bridge, String runtimeSessionId) {
  for (final candidate in bridge.sessions) {
    if (candidate.id == runtimeSessionId) {
      return candidate;
    }
  }
  return null;
}

class ConversationMirrorResidentPanel extends StatefulWidget {
  const ConversationMirrorResidentPanel({
    required this.runtimeSessionId,
    required this.bridge,
    super.key,
  });

  final String runtimeSessionId;
  final BridgeService bridge;

  @override
  State<ConversationMirrorResidentPanel> createState() =>
      _ConversationMirrorResidentPanelState();
}

class _ConversationMirrorResidentPanelState
    extends State<ConversationMirrorResidentPanel> {
  bool _busy = false;
  String? _error;

  Future<void> _stopResident(
    ConversationMirrorService service,
    ConversationMirrorTarget target,
  ) async {
    if (_busy) return;
    final strings = ConversationMirrorStrings.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await service.stopBeingResidentTarget(target);
    } catch (error) {
      if (mounted) setState(() => _error = strings.failed('$error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(
    ConversationMirrorService service,
    ConversationMirrorTarget target,
  ) async {
    final strings = ConversationMirrorStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.removeLocalCopy),
        content: Text(strings.removeLocalCopyWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.removeLocalCopy),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await service.removeLocalCopyTarget(target);
    } catch (error) {
      if (mounted) setState(() => _error = strings.failed('$error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<SessionInfo>>(
      stream: widget.bridge.sessionList,
      initialData: widget.bridge.sessions,
      builder: (context, _) => _buildPanel(context),
    );
  }

  Widget _buildPanel(BuildContext context) {
    final strings = ConversationMirrorStrings.of(context);
    final service = context.watch<ConversationMirrorService?>();
    final target = _targetForRuntime(widget.bridge, widget.runtimeSessionId);
    if (service == null || !service.isAvailable) {
      return Center(child: Text(strings.bridgeUpdateRequired));
    }
    if (target == null) {
      return Center(child: Text(strings.waitingForConversationIdentity));
    }

    final metadata = service.cachedMetadataForTarget(target);
    final isResident = metadata?.autoSync == true;
    final hasLocalCopy = metadata?.hasLocalCopy == true;
    if (!hasLocalCopy) {
      return Center(child: Text(strings.noLocalCopy));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            isResident ? Icons.offline_pin : Icons.check_circle_outline,
          ),
          title: Text(strings.savedCopyTitle),
          subtitle: Text(strings.savedCopyTooltip),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        if (metadata != null) ...[
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.storage_outlined),
            title: Text(strings.residentEntries(metadata.entryCount)),
            subtitle: Text(target.effectiveProjectPath),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        if (isResident)
          FilledButton.tonalIcon(
            key: const ValueKey('conversation_resident_stop'),
            onPressed: _busy ? null : () => _stopResident(service, target),
            icon: const Icon(Icons.pause_circle_outline),
            label: Text(strings.stopResident),
          ),
        if (hasLocalCopy) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            key: const ValueKey('conversation_resident_delete_copy'),
            onPressed: _busy ? null : () => _delete(service, target),
            icon: const Icon(Icons.delete_outline),
            label: Text(strings.removeLocalCopy),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}
