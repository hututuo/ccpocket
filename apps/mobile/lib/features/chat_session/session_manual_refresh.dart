import 'dart:async';

import '../../core/logger.dart';
import '../../models/bridge_data_source_identity.dart';
import '../../services/bridge_service.dart';
import '../conversation_content_sync/conversation_content_sync_service.dart';
import 'state/chat_session_cubit.dart';

/// Runs the same authoritative reconciliation used by automatic foreground
/// sync, but at explicit user priority.
///
/// This is deliberately not a local list rebuild. It refreshes the runtime
/// catalog/status, re-sends the focused durable-thread request (which also
/// drives Codex settings hydration), and asks the existing history/mirror
/// pipeline to reconcile its current runtime cursor.
Future<bool> refreshSessionFromBridge({
  required BridgeService bridge,
  required ChatSessionCubit chatSession,
  required ConversationContentSyncService? contentSync,
  required String provider,
  required String pageSessionId,
  required BridgeDataSourceIdentity expectedDataSourceIdentity,
  String? runtimeSessionId,
  bool detachedPreview = false,
  Duration connectionTimeout = const Duration(seconds: 10),
}) async {
  try {
    final authoritative = await bridge.refreshAuthoritativeSessionList(
      timeout: connectionTimeout,
    );
    if (!authoritative ||
        !expectedDataSourceIdentity.isSatisfiedBy(
          bridge.dataSourceIdentity,
          provider: provider,
        )) {
      return false;
    }
    final effectiveRuntimeId = detachedPreview
        ? null
        : (runtimeSessionId ?? pageSessionId);
    final providerSessionId = detachedPreview
        ? pageSessionId
        : bridge.providerSessionIdForRuntime(
                effectiveRuntimeId!,
                provider: provider,
              ) ??
              pageSessionId;

    final focusedRefresh = contentSync?.refreshFocusedConversation(
      provider: provider,
      providerSessionId: providerSessionId,
      expectedDataSourceIdentity: expectedDataSourceIdentity,
    );
    chatSession.refreshHistory();
    if (effectiveRuntimeId != null) {
      bridge.refreshBranch(effectiveRuntimeId);
    }
    if (focusedRefresh != null) await focusedRefresh;
    return true;
  } catch (error, stackTrace) {
    logger.warning(
      '[session:$pageSessionId] Manual authoritative refresh failed',
      error,
      stackTrace,
    );
    return false;
  }
}
