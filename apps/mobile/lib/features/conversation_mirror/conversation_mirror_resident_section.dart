import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/messages.dart';
import '../../theme/app_theme.dart';
import '../../widgets/adaptive_context_menu.dart';
import '../session_list/widgets/section_header.dart';
import 'conversation_mirror_service.dart';
import 'conversation_mirror_session_actions.dart';
import 'conversation_mirror_strings.dart';
import 'conversation_mirror_target.dart';
import 'storage/conversation_mirror_models.dart';

typedef OpenResidentRunningSession = void Function(SessionInfo session);
typedef OpenResidentRecentSession = void Function(RecentSession session);

/// Dedicated Home classification for the bounded set of resident chats.
///
/// It renders metadata only; opening a 3,000-message resident conversation
/// still goes through the mirror service's existing recent-200 paging path.
class ConversationMirrorResidentSection extends StatelessWidget {
  const ConversationMirrorResidentSection({
    required this.runningSessions,
    required this.recentSessions,
    required this.onOpenRunning,
    required this.onOpenRecent,
    super.key,
  });

  final List<SessionInfo> runningSessions;
  final List<RecentSession> recentSessions;
  final OpenResidentRunningSession onOpenRunning;
  final OpenResidentRecentSession onOpenRecent;

  Future<void> _showActions(
    BuildContext context,
    ConversationMirrorTarget target,
  ) async {
    final action = await showAdaptiveActionMenu<String>(
      context: context,
      items: conversationMirrorTargetActionItems(context, target),
    );
    if (action == null || !context.mounted) return;
    await handleConversationMirrorTargetAction(context, target, action);
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConversationMirrorService?>();
    if (service == null || !service.isAvailable) {
      return const SizedBox.shrink();
    }
    final bridgeId = service.currentBridgeInstanceId;
    final metadata = service.residentMetadata
        .where(
          (item) => bridgeId == null || item.key.bridgeInstanceId == bridgeId,
        )
        .toList(growable: false);
    if (metadata.isEmpty) return const SizedBox.shrink();

    final strings = ConversationMirrorStrings.of(context);
    final appColors = Theme.of(context).extension<AppColors>()!;
    return Column(
      key: const ValueKey('resident_conversations_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          icon: Icons.offline_pin,
          label: '${strings.residentTitle} · ${metadata.length}',
          color: Theme.of(context).colorScheme.primary,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
          child: Text(
            strings.residentSubtitle,
            style: TextStyle(fontSize: 11, color: appColors.subtleText),
          ),
        ),
        for (final item in metadata)
          _ResidentConversationTile(
            metadata: item,
            runningSession: _runningFor(item.key.providerSessionId),
            recentSession: _recentFor(
              item.key.provider,
              item.key.providerSessionId,
            ),
            onOpenRunning: onOpenRunning,
            onOpenRecent: onOpenRecent,
            onShowActions: (target) => _showActions(context, target),
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  SessionInfo? _runningFor(String providerSessionId) {
    for (final session in runningSessions) {
      if (session.provider == Provider.codex.value &&
          session.claudeSessionId == providerSessionId) {
        return session;
      }
    }
    return null;
  }

  RecentSession? _recentFor(String provider, String providerSessionId) {
    for (final session in recentSessions) {
      if ((session.provider ?? Provider.claude.value) == provider &&
          session.sessionId == providerSessionId) {
        return session;
      }
    }
    return null;
  }
}

class _ResidentConversationTile extends StatelessWidget {
  const _ResidentConversationTile({
    required this.metadata,
    required this.runningSession,
    required this.recentSession,
    required this.onOpenRunning,
    required this.onOpenRecent,
    required this.onShowActions,
  });

  final ConversationMirrorMetadata metadata;
  final SessionInfo? runningSession;
  final RecentSession? recentSession;
  final OpenResidentRunningSession onOpenRunning;
  final OpenResidentRecentSession onOpenRecent;
  final ValueChanged<ConversationMirrorTarget> onShowActions;

  @override
  Widget build(BuildContext context) {
    final strings = ConversationMirrorStrings.of(context);
    final ConversationMirrorTarget target;
    if (runningSession != null) {
      target = ConversationMirrorTarget.fromRunning(runningSession!)!;
    } else if (recentSession != null) {
      target = ConversationMirrorTarget.fromRecent(recentSession!);
    } else {
      target = ConversationMirrorTarget.fromMetadata(metadata);
    }
    final title = _title(target);
    final running = runningSession != null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: ListTile(
        key: ValueKey(
          'resident_conversation_${metadata.key.providerSessionId}',
        ),
        onTap: () {
          final active = runningSession;
          if (active != null) {
            onOpenRunning(active);
          } else {
            onOpenRecent(target.toRecentSession());
          }
        },
        onLongPress: () => onShowActions(target),
        leading: Icon(
          running ? Icons.play_circle_fill : Icons.offline_pin_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${running ? strings.runningPrefix : ''}${strings.residentEntries(metadata.entryCount)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          key: ValueKey(
            'resident_conversation_more_${metadata.key.providerSessionId}',
          ),
          icon: const Icon(Icons.more_horiz),
          tooltip: strings.manageResident,
          onPressed: () => onShowActions(target),
        ),
      ),
    );
  }

  String _title(ConversationMirrorTarget target) {
    final name = target.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    final prompt = target.firstPrompt.trim();
    if (prompt.isNotEmpty) return prompt;
    final project = pathBasename(target.effectiveProjectPath);
    if (project.isNotEmpty) return project;
    final id = target.providerSessionId;
    return id.length <= 12 ? id : '${id.substring(0, 12)}…';
  }
}
