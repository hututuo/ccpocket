import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/messages.dart';
import '../../services/bridge_service.dart';
import '../../widgets/adaptive_context_menu.dart';
import 'session_archive_cubit.dart';
import 'session_archive_strings.dart';

Future<void> openSessionArchive(BuildContext context) {
  final bridge = context.read<BridgeService>();
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => BlocProvider(
        create: (_) => SessionArchiveCubit(bridge: bridge),
        child: const SessionArchiveScreen(),
      ),
    ),
  );
}

class SessionArchiveScreen extends StatelessWidget {
  const SessionArchiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final strings = SessionArchiveStrings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.title),
        actions: [
          IconButton(
            key: const ValueKey('archived_sessions_refresh'),
            onPressed: () => context.read<SessionArchiveCubit>().refresh(),
            icon: const Icon(Icons.refresh),
            tooltip: MaterialLocalizations.of(
              context,
            ).refreshIndicatorSemanticLabel,
          ),
        ],
      ),
      body: BlocBuilder<SessionArchiveCubit, SessionArchiveState>(
        builder: (context, state) {
          if (!state.supported) {
            return _ArchiveMessage(
              icon: Icons.system_update_alt,
              message: strings.unsupported,
            );
          }
          if (state.isLoading && state.sessions.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.error != null && state.sessions.isEmpty) {
            return _ArchiveMessage(
              icon: Icons.error_outline,
              message: strings.failed(state.error!),
              action: TextButton(
                onPressed: () => context.read<SessionArchiveCubit>().refresh(),
                child: Text(
                  MaterialLocalizations.of(
                    context,
                  ).refreshIndicatorSemanticLabel,
                ),
              ),
            );
          }
          if (state.sessions.isEmpty) {
            return _ArchiveMessage(
              icon: Icons.archive_outlined,
              message: strings.empty,
            );
          }
          return RefreshIndicator(
            onRefresh: () => context.read<SessionArchiveCubit>().refresh(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                if (state.truncated)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
                    child: Text(
                      strings.truncated,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (state.error != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(strings.failed(state.error!)),
                    ),
                  ),
                for (final session in state.sessions)
                  _ArchivedSessionTile(
                    session: session,
                    busy: state.pendingSessionKeys.contains(
                      archivedSessionIdentityKey(session),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ArchivedSessionTile extends StatelessWidget {
  const _ArchivedSessionTile({required this.session, required this.busy});

  final ArchivedSessionRecord session;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey(
        'archived_session_${session.provider}_${session.sessionId}',
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: session.provider == Provider.codex.value
              ? scheme.primaryContainer
              : scheme.secondaryContainer,
          child: Icon(
            session.provider == Provider.codex.value
                ? Icons.code
                : Icons.psychology_outlined,
          ),
        ),
        title: Text(
          session.displayTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${pathBasename(session.projectPath)} · ${_archiveDate(session)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: busy
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : IconButton(
                key: ValueKey(
                  'archived_session_actions_${session.provider}_${session.sessionId}',
                ),
                onPressed: () => _showActions(context),
                icon: const Icon(Icons.more_vert),
              ),
      ),
    );
  }

  String _archiveDate(ArchivedSessionRecord session) {
    final parsed = DateTime.tryParse(session.archivedAt)?.toLocal();
    if (parsed == null) return session.archivedAt;
    final month = parsed.month.toString().padLeft(2, '0');
    final day = parsed.day.toString().padLeft(2, '0');
    final hour = parsed.hour.toString().padLeft(2, '0');
    final minute = parsed.minute.toString().padLeft(2, '0');
    return '${parsed.year}-$month-$day $hour:$minute';
  }

  Future<void> _showActions(BuildContext context) async {
    final strings = SessionArchiveStrings.of(context);
    final action = await showAdaptiveActionMenu<String>(
      context: context,
      items: [
        AdaptiveActionMenuItem(
          value: 'restore',
          icon: Icons.unarchive_outlined,
          label: strings.restore,
        ),
        if (session.provider == Provider.codex.value)
          AdaptiveActionMenuItem(
            value: 'delete',
            icon: Icons.delete_forever_outlined,
            label: strings.deletePermanently,
            destructive: true,
          ),
      ],
    );
    if (action == null || !context.mounted) return;
    final cubit = context.read<SessionArchiveCubit>();
    final messenger = ScaffoldMessenger.of(context);
    if (action == 'restore') {
      final success = await cubit.unarchive(session);
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            success
                ? strings.restored
                : strings.failed(cubit.state.error ?? ''),
          ),
        ),
      );
      return;
    }

    if (!await _confirmPermanentDelete(context, strings) || !context.mounted) {
      return;
    }
    final success = await cubit.deletePermanently(session);
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          success ? strings.deleted : strings.failed(cubit.state.error ?? ''),
        ),
      ),
    );
  }

  Future<bool> _confirmPermanentDelete(
    BuildContext context,
    SessionArchiveStrings strings,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PermanentDeleteDialog(strings: strings),
    );
    return result ?? false;
  }
}

class _PermanentDeleteDialog extends StatefulWidget {
  const _PermanentDeleteDialog({required this.strings});

  final SessionArchiveStrings strings;

  @override
  State<_PermanentDeleteDialog> createState() => _PermanentDeleteDialogState();
}

class _PermanentDeleteDialogState extends State<_PermanentDeleteDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _confirmed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      title: Text(strings.deleteTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(strings.deleteWarning),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('permanent_delete_confirmation_input'),
              controller: _controller,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: strings.typeDelete),
              onChanged: (value) {
                setState(() => _confirmed = value == 'DELETE');
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const ValueKey('confirm_permanent_delete_button'),
          onPressed: _confirmed ? () => Navigator.of(context).pop(true) : null,
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(strings.deletePermanently),
        ),
      ],
    );
  }
}

class _ArchiveMessage extends StatelessWidget {
  const _ArchiveMessage({
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    ),
  );
}
