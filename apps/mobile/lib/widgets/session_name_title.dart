import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/messages.dart';
import '../services/bridge_service.dart';
import '../features/session_list/state/session_list_cubit.dart';
import 'rename_session_dialog.dart';

/// Tappable session name in the AppBar. Shows session name or project name.
/// Tap to rename via dialog.
class SessionNameTitle extends StatelessWidget {
  final String sessionId;
  final String? projectPath;
  final String? provider;

  const SessionNameTitle({
    super.key,
    required this.sessionId,
    this.projectPath,
    this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final bridge = context.read<BridgeService>();
    final catalog = context.read<SessionListCubit?>();

    Widget buildRuntimeTitle() => StreamBuilder<List<SessionInfo>>(
      stream: bridge.sessionList,
      initialData: bridge.sessions,
      builder: (context, snapshot) {
        final sessions = snapshot.data ?? [];
        final session = sessions.where((s) => s.id == sessionId).firstOrNull;
        final durableId = session?.claudeSessionId?.trim();
        final recent = catalog?.catalogSessionFor(
          durableId?.isNotEmpty == true ? durableId! : sessionId,
          provider: session?.provider ?? provider,
        );
        // A committed provider row may intentionally clear a stale runtime
        // title, so its nullable value is authoritative when the row exists.
        final name = recent != null ? recent.name : session?.name;
        final fallback = recent?.projectName.isNotEmpty == true
            ? recent!.projectName
            : projectPath?.split('/').last ?? '';

        return GestureDetector(
          onTap: () async {
            final newName = await showRenameSessionDialog(
              context,
              currentName: name,
            );
            if (newName == null || !context.mounted) return;
            final effectiveName = newName.isEmpty ? null : newName;
            if (session != null || recent == null) {
              bridge.renameSession(sessionId: sessionId, name: effectiveName);
            } else {
              bridge.renameSession(
                sessionId: recent.sessionId,
                name: effectiveName,
                provider: recent.provider,
                providerSessionId: recent.sessionId,
                projectPath: recent.projectPath,
                codexSourceId: recent.codexSourceId,
              );
            }
          },
          child: Text(
            name != null && name.isNotEmpty ? name : fallback,
            style: TextStyle(
              fontSize: 14,
              color: name != null && name.isNotEmpty
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );

    // SessionNameTitle is also used by focused widget tests and embedders that
    // intentionally mount a chat without the Home catalog. Keep the original
    // runtime-title path valid there; the catalog is an additive live-update
    // source, not a hard page dependency.
    if (catalog == null) return buildRuntimeTitle();
    return StreamBuilder<void>(
      stream: catalog.catalogSnapshotChanges,
      builder: (context, _) => buildRuntimeTitle(),
    );
  }
}
