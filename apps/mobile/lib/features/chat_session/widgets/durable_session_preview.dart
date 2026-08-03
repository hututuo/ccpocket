import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../session_list/state/session_list_cubit.dart';
import '../state/chat_session_cubit.dart';

typedef LiveRuntimeReadyCallback = bool Function(ChatSessionCubit cubit);

/// Applies durable-cache revisions to an existing detached chat cubit.
///
/// Keeping the provider and message widgets mounted preserves scroll position
/// and disclosure state while Bridge-owned incremental sync refreshes content.
class DurableSessionPreviewUpdater extends StatefulWidget {
  final String revision;
  final List<ServerMessage> messages;
  final bool hasEarlier;
  final String? statusProvider;
  final String? statusProviderSessionId;
  final String? expectedSourceFingerprint;
  final String? liveRuntimeSessionId;
  final LiveRuntimeReadyCallback? onLiveRuntimeReady;
  final Widget child;

  const DurableSessionPreviewUpdater({
    super.key,
    required this.revision,
    required this.messages,
    required this.hasEarlier,
    this.statusProvider,
    this.statusProviderSessionId,
    this.expectedSourceFingerprint,
    this.liveRuntimeSessionId,
    this.onLiveRuntimeReady,
    required this.child,
  });

  @override
  State<DurableSessionPreviewUpdater> createState() =>
      _DurableSessionPreviewUpdaterState();
}

class _DurableSessionPreviewUpdaterState
    extends State<DurableSessionPreviewUpdater> {
  StreamSubscription<void>? _statusSub;
  SessionListCubit? _boundSessionList;
  String? _boundProvider;
  String? _boundProviderSessionId;
  ChatSessionCubit? _boundRuntimeCubit;
  String? _consumedLiveRuntimeSessionId;
  bool _liveRuntimeCallbackScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindLiveRuntime();
    _bindStatusProjection();
  }

  void _bindLiveRuntime() {
    final runtimeSessionId = widget.liveRuntimeSessionId?.trim();
    final normalized = runtimeSessionId == null || runtimeSessionId.isEmpty
        ? null
        : runtimeSessionId;
    final cubit = context.read<ChatSessionCubit>();
    if (!identical(_boundRuntimeCubit, cubit)) {
      _boundRuntimeCubit?.detachedLiveRuntimeRevision.removeListener(
        _handleLiveRuntimeRevision,
      );
      _boundRuntimeCubit = cubit;
      cubit.detachedLiveRuntimeRevision.addListener(_handleLiveRuntimeRevision);
      _consumedLiveRuntimeSessionId = null;
    }
    cubit.updateDetachedLiveRuntime(normalized);
    if (normalized == null) {
      _consumedLiveRuntimeSessionId = null;
      return;
    }
    _scheduleLiveRuntimeCallback();
  }

  void _handleLiveRuntimeRevision() {
    if (!mounted) return;
    _scheduleLiveRuntimeCallback();
  }

  void _scheduleLiveRuntimeCallback() {
    final callback = widget.onLiveRuntimeReady;
    final cubit = _boundRuntimeCubit;
    final normalized = widget.liveRuntimeSessionId?.trim();
    if (callback == null ||
        cubit == null ||
        normalized == null ||
        normalized.isEmpty ||
        _consumedLiveRuntimeSessionId == normalized ||
        _liveRuntimeCallbackScheduled) {
      return;
    }
    _liveRuntimeCallbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _liveRuntimeCallbackScheduled = false;
      if (!mounted ||
          !identical(_boundRuntimeCubit, cubit) ||
          widget.liveRuntimeSessionId?.trim() != normalized ||
          _consumedLiveRuntimeSessionId == normalized) {
        return;
      }
      if (widget.onLiveRuntimeReady?.call(cubit) == true) {
        _consumedLiveRuntimeSessionId = normalized;
      }
    });
  }

  void _bindStatusProjection() {
    final provider = widget.statusProvider;
    final providerSessionId = widget.statusProviderSessionId;
    SessionListCubit? sessionList;
    try {
      sessionList = context.read<SessionListCubit>();
    } catch (_) {
      // Isolated official/widget hosts may omit the optional catalog service.
    }
    if (provider == null || providerSessionId == null || sessionList == null) {
      _statusSub?.cancel();
      _statusSub = null;
      _boundSessionList = null;
      _boundProvider = null;
      _boundProviderSessionId = null;
      return;
    }
    final boundSessionList = sessionList;
    if (identical(_boundSessionList, boundSessionList) &&
        _boundProvider == provider &&
        _boundProviderSessionId == providerSessionId) {
      _applyStatusProjection(boundSessionList, provider, providerSessionId);
      return;
    }
    _statusSub?.cancel();
    _boundSessionList = boundSessionList;
    _boundProvider = provider;
    _boundProviderSessionId = providerSessionId;
    _applyStatusProjection(boundSessionList, provider, providerSessionId);
    _statusSub = boundSessionList.catalogSnapshotChanges.listen((_) {
      if (!mounted ||
          !identical(_boundSessionList, boundSessionList) ||
          widget.statusProvider != provider ||
          widget.statusProviderSessionId != providerSessionId) {
        return;
      }
      _applyStatusProjection(boundSessionList, provider, providerSessionId);
    });
  }

  void _applyStatusProjection(
    SessionListCubit sessionList,
    String provider,
    String providerSessionId,
  ) {
    final status =
        sessionList.conversationStatuses['$provider\u0000$providerSessionId'];
    final cubit = context.read<ChatSessionCubit>();
    final sourceFingerprint = sessionList.conversationSourceFingerprint;
    final expectedSourceFingerprint = widget.expectedSourceFingerprint?.trim();
    if (expectedSourceFingerprint != null &&
        expectedSourceFingerprint.isNotEmpty &&
        sourceFingerprint != expectedSourceFingerprint) {
      cubit.suspendDetachedProviderProjection(
        reason: 'source_fingerprint_mismatch',
        observedSourceFingerprint: sourceFingerprint,
        expectedSourceFingerprint: expectedSourceFingerprint,
        catalogUsable: sessionList.hasUsableCatalogForCurrentTarget,
      );
      if (!sessionList.hasUsableCatalogForCurrentTarget) {
        // Authentication, route canonicalization, and the first priority
        // commit can temporarily expose different fingerprints for the same
        // Bridge/source. Keep the last committed durable facts visible while
        // denying mutations until the current target is authoritative.
        return;
      }
      cubit.updateDetachedProviderStatus(
        null,
        sourceFingerprint: expectedSourceFingerprint,
      );
      cubit.updateDetachedProviderSettings(
        null,
        sourceFingerprint: expectedSourceFingerprint,
      );
      return;
    }
    cubit.updateDetachedProviderStatus(
      status,
      sourceFingerprint: sourceFingerprint,
    );
    cubit.updateDetachedProviderSettings(
      sessionList.conversationMetadataFor(provider, providerSessionId),
      sourceFingerprint: sourceFingerprint,
    );
  }

  @override
  void didUpdateWidget(covariant DurableSessionPreviewUpdater oldWidget) {
    super.didUpdateWidget(oldWidget);
    final liveRuntimeChanged =
        oldWidget.liveRuntimeSessionId != widget.liveRuntimeSessionId;
    if (liveRuntimeChanged) {
      _bindLiveRuntime();
    }
    if (liveRuntimeChanged ||
        oldWidget.statusProvider != widget.statusProvider ||
        oldWidget.statusProviderSessionId != widget.statusProviderSessionId ||
        oldWidget.expectedSourceFingerprint !=
            widget.expectedSourceFingerprint) {
      // A replacement runtime clears the previous handle's authority. Reapply
      // only the current source-scoped catalog status after the new handle is
      // bound; never carry writable/steerable across runtime generations.
      _bindStatusProjection();
    }
    if (oldWidget.revision == widget.revision &&
        oldWidget.hasEarlier == widget.hasEarlier) {
      return;
    }
    final revision = widget.revision;
    final messages = widget.messages;
    final hasEarlier = widget.hasEarlier;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.revision != revision) return;
      context.read<ChatSessionCubit>().updateDetachedPreviewHistory(
        messages,
        hasEarlier: hasEarlier,
      );
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _boundRuntimeCubit?.detachedLiveRuntimeRevision.removeListener(
      _handleLiveRuntimeRevision,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Compact non-blocking status shown while a durable conversation is already
/// readable/composable but its live runtime is still attaching.
class DurableSessionBindingBanner extends StatelessWidget {
  final bool queuedLocally;

  const DurableSessionBindingBanner({super.key, required this.queuedLocally});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                Icon(
                  queuedLocally ? Icons.schedule_send_outlined : Icons.sync,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    queuedLocally
                        ? '${l.queuedLocally} · ${l.loadingSessionStatus}'
                        : l.loadingSessionStatus,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
