import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../../utils/diagnostic_token.dart';
import '../../session_list/state/session_list_cubit.dart';
import '../state/chat_session_cubit.dart';

typedef LiveRuntimeReadyCallback = bool Function(ChatSessionCubit cubit);

typedef LatestTurnRepairCallback = Future<bool> Function();

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
  final String durableHistoryLoaderRevision;
  final String? durableHistoryLoaderSourceFingerprint;
  final DetachedHistoryToolDetailLoader? detachedHistoryToolDetailLoader;
  final DetachedUserMessageIndexLoader? detachedUserMessageIndexLoader;
  final DetachedUserTurnLoader? detachedUserTurnLoader;
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
    this.durableHistoryLoaderRevision = '',
    this.durableHistoryLoaderSourceFingerprint,
    this.detachedHistoryToolDetailLoader,
    this.detachedUserMessageIndexLoader,
    this.detachedUserTurnLoader,
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
  bool _liveRuntimeCallbackRetryPending = false;

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
      _liveRuntimeCallbackRetryPending = false;
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
        _consumedLiveRuntimeSessionId == normalized) {
      return;
    }
    if (_liveRuntimeCallbackScheduled) {
      _liveRuntimeCallbackRetryPending = true;
      return;
    }
    _liveRuntimeCallbackScheduled = true;
    // Catalog/runtime authority events can arrive while no Flutter frame is
    // scheduled. A post-frame callback would then remain stranded until the
    // user caused another rebuild (for example by leaving and re-entering the
    // conversation). A microtask runs after the current projection/build stack
    // and therefore retries the explicit send as soon as authority is usable.
    scheduleMicrotask(() {
      _liveRuntimeCallbackScheduled = false;
      if (!mounted ||
          !identical(_boundRuntimeCubit, cubit) ||
          widget.liveRuntimeSessionId?.trim() != normalized ||
          _consumedLiveRuntimeSessionId == normalized) {
        return;
      }
      final consumed = widget.onLiveRuntimeReady?.call(cubit) == true;
      logger.info(
        '[outgoing_recovery] event=live_runtime_callback '
        'thread=${diagnosticToken('thread', widget.statusProviderSessionId ?? 'unknown')} '
        'runtime=${diagnosticToken('runtime', normalized)} consumed=$consumed '
        'writable=${cubit.runtimeSessionIdForMutation() != null}',
      );
      if (consumed) {
        _consumedLiveRuntimeSessionId = normalized;
      }
      final retryPending = _liveRuntimeCallbackRetryPending;
      _liveRuntimeCallbackRetryPending = false;
      // Multiple projection signals in one frame are coalesced. Only retry a
      // failed callback when the authority envelope is now actually usable;
      // this avoids a busy post-frame loop while preserving an explicit send
      // that attached before its source-scoped authority arrived.
      if (!consumed &&
          retryPending &&
          cubit.runtimeSessionIdForMutation() != null) {
        _scheduleLiveRuntimeCallback();
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
    // A runtime can attach before the source-scoped authority projection is
    // committed. The first callback then correctly fails closed; retry it
    // after each authoritative status/settings projection so an explicitly
    // requested send is not stranded waiting for another runtime change.
    _scheduleLiveRuntimeCallback();
  }

  @override
  void didUpdateWidget(covariant DurableSessionPreviewUpdater oldWidget) {
    super.didUpdateWidget(oldWidget);
    final liveRuntimeChanged =
        oldWidget.liveRuntimeSessionId != widget.liveRuntimeSessionId;
    final liveRuntimeCallbackChanged =
        oldWidget.onLiveRuntimeReady != widget.onLiveRuntimeReady;
    final durableHistoryLoaderChanged =
        oldWidget.durableHistoryLoaderRevision !=
            widget.durableHistoryLoaderRevision ||
        oldWidget.durableHistoryLoaderSourceFingerprint !=
            widget.durableHistoryLoaderSourceFingerprint;
    if (liveRuntimeChanged || liveRuntimeCallbackChanged) {
      _bindLiveRuntime();
    }
    if (durableHistoryLoaderChanged) {
      final revision = widget.durableHistoryLoaderRevision;
      final sourceFingerprint = widget.durableHistoryLoaderSourceFingerprint;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            widget.durableHistoryLoaderRevision != revision ||
            widget.durableHistoryLoaderSourceFingerprint != sourceFingerprint) {
          return;
        }
        context.read<ChatSessionCubit>().updateDetachedHistoryLoaders(
          toolDetailLoader: widget.detachedHistoryToolDetailLoader,
          userMessageIndexLoader: widget.detachedUserMessageIndexLoader,
          userTurnLoader: widget.detachedUserTurnLoader,
        );
      });
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

/// Compact, retryable status shown when the cache has no visible entries and
/// the newest turn is known to be incomplete.
class DurableLatestTurnRecoveryBanner extends StatefulWidget {
  final LatestTurnRepairCallback onRetry;

  const DurableLatestTurnRecoveryBanner({super.key, required this.onRetry});

  @override
  State<DurableLatestTurnRecoveryBanner> createState() =>
      _DurableLatestTurnRecoveryBannerState();
}

class _DurableLatestTurnRecoveryBannerState
    extends State<DurableLatestTurnRecoveryBanner> {
  bool _retrying = false;
  bool _failed = false;

  Future<void> _retryLatestTurn() async {
    if (_retrying) return;
    setState(() {
      _retrying = true;
      _failed = false;
    });
    try {
      final recovered = await widget.onRetry().timeout(
        const Duration(seconds: 35),
      );
      if (!mounted) return;
      setState(() {
        _retrying = false;
        _failed = !recovered;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _retrying = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('durable_latest_turn_recovery_banner'),
      color: colors.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_retrying) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                Icon(
                  Icons.sync_problem_outlined,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _failed
                        ? '${l.conversationLatestTurnIncomplete} ${l.turnLoadFailed}'
                        : l.conversationLatestTurnIncomplete,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: const ValueKey('durable_latest_turn_recovery_retry'),
                  onPressed: _retrying ? null : _retryLatestTurn,
                  child: _retrying
                      ? Semantics(
                          label: l.loading,
                          child: const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              key: ValueKey(
                                'durable_latest_turn_recovery_loading',
                              ),
                              strokeWidth: 2,
                            ),
                          ),
                        )
                      : Text(l.retry),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
