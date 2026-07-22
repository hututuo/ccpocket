import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderBox, ScrollDirection;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../../providers/bridge_cubits.dart';
import '../../../services/bridge_service.dart';
import '../../../utils/artifact_link_matcher.dart';
import '../../../widgets/chat_selection_actions.dart';
import '../../../widgets/message_bubble.dart';
import '../../artifact_preview/artifact_preview_entry.dart';
import '../../file_peek/file_peek_sheet.dart';
import '../../message_images/message_images_screen.dart';
import '../state/chat_session_cubit.dart';
import '../state/streaming_state.dart';
import '../state/streaming_state_cubit.dart';
import 'maintain_reading_position_physics.dart';
import 'chat_process_disclosure.dart';
import 'chat_process_layout.dart';

String? resolveChatFileRoot({String? worktreePath, String? projectPath}) {
  final worktree = worktreePath?.trim();
  if (worktree != null && worktree.isNotEmpty) return worktree;
  final project = projectPath?.trim();
  return project == null || project.isEmpty ? null : project;
}

@visibleForTesting
bool shouldShowForkForAssistant(
  List<ChatEntry> entries,
  int entryIndex, {
  bool transcriptTailComplete = false,
}) {
  if (entryIndex < 0 || entryIndex >= entries.length) return false;
  final entry = entries[entryIndex];
  if (entry is! ServerChatEntry || entry.message is! AssistantServerMessage) {
    return false;
  }
  final assistant = entry.message as AssistantServerMessage;
  final hasVisibleReply = assistant.message.content.any(
    (content) => content is TextContent && content.text.trim().isNotEmpty,
  );
  if (!hasVisibleReply) return false;

  var hasTerminalResult = false;
  for (var i = entryIndex + 1; i < entries.length; i++) {
    final next = entries[i];
    // Desktop/app-server history may omit the synthetic ResultMessage that the
    // live Bridge stream emits. A following user turn still proves that this
    // was the final assistant reply for the preceding completed turn.
    if (next is UserChatEntry) return true;
    if (next is ServerChatEntry) {
      final message = next.message;
      // Fork is turn-granular: a later visible assistant update means this
      // block was progress inside the same turn, not an item-level branch
      // point. Tool-only assistant envelopes do not replace the visible reply.
      if (message is AssistantServerMessage &&
          message.message.content.any(
            (content) =>
                content is TextContent && content.text.trim().isNotEmpty,
          )) {
        return false;
      }
      if (message is ResultMessage) hasTerminalResult = true;
    }
  }
  return hasTerminalResult || transcriptTailComplete;
}

@visibleForTesting
bool shouldLoadOlderLocalHistory(
  ScrollMetrics metrics, {
  double threshold = 480,
}) =>
    metrics.maxScrollExtent > 0 &&
    metrics.pixels >= metrics.maxScrollExtent - threshold;

/// Displays the chat message list with [ListView.builder] (reverse: true).
///
/// Reads entries directly from [ChatSessionCubit] state (SSOT).
/// With reverse list, offset 0 = bottom of chat, so new messages appear
/// immediately without scroll adjustment, and history prepend does not
/// shift the viewport.
class ChatMessageList extends StatefulWidget {
  final String sessionId;
  final AutoScrollController scrollController;
  final String? httpBaseUrl;
  final void Function(UserChatEntry)? onRetryMessage;
  final void Function(UserChatEntry)? onRewindMessage;
  final void Function(AssistantServerMessage)? onForkMessage;
  final ValueNotifier<int>? collapseToolResults;
  final double bottomPadding;
  final bool isCodex;
  final ValueChanged<String>? onFilePeekOpened;
  final List<ChatSelectionAction> selectionActions;

  /// Project path for file peek (reading files from Bridge).
  final String? projectPath;

  /// When set (non-null), the list scrolls to the given [UserChatEntry].
  /// The notifier is reset to null after scrolling.
  final ValueNotifier<UserChatEntry?>? scrollToUserEntry;

  const ChatMessageList({
    super.key,
    required this.sessionId,
    required this.scrollController,
    required this.httpBaseUrl,
    required this.onRetryMessage,
    this.onRewindMessage,
    this.onForkMessage,
    required this.collapseToolResults,
    this.scrollToUserEntry,
    this.bottomPadding = 8,
    this.projectPath,
    this.isCodex = false,
    this.onFilePeekOpened,
    this.selectionActions = const [],
  });

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  ChatSessionCubit? _pagingCubit;
  final Set<String> _expandedProcessSegments = {};
  final Set<String> _expandedIntermediateTurns = {};
  final Set<String> _expandedCurrentProgress = {};
  final Map<String, GlobalKey> _disclosureAnchorKeys = {};
  bool _userScrollInProgress = false;

  @override
  void initState() {
    super.initState();
    widget.scrollToUserEntry?.addListener(_onScrollToUserEntry);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextCubit = context.read<ChatSessionCubit>();
    if (identical(nextCubit, _pagingCubit)) return;
    _pagingCubit?.localHistoryPaging.removeListener(_onPagingChanged);
    _pagingCubit = nextCubit;
    nextCubit.localHistoryPaging.addListener(_onPagingChanged);
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollToUserEntry != widget.scrollToUserEntry) {
      oldWidget.scrollToUserEntry?.removeListener(_onScrollToUserEntry);
      widget.scrollToUserEntry?.addListener(_onScrollToUserEntry);
    }
  }

  @override
  void dispose() {
    widget.scrollToUserEntry?.removeListener(_onScrollToUserEntry);
    _pagingCubit?.localHistoryPaging.removeListener(_onPagingChanged);
    super.dispose();
  }

  void _onPagingChanged() {
    if (mounted) setState(() {});
  }

  void _onScrollToUserEntry() {
    final entry = widget.scrollToUserEntry?.value;
    if (entry == null) return;
    // Reset the notifier
    widget.scrollToUserEntry?.value = null;
    _scrollToUserEntry(entry);
  }

  GlobalKey _anchorKey(String id) =>
      _disclosureAnchorKeys.putIfAbsent(id, () => GlobalKey());

  Widget _anchoredDisclosure(String id, Widget child) =>
      KeyedSubtree(key: _anchorKey(id), child: child);

  /// Expanding a reverse, variable-height list can otherwise move the tapped
  /// disclosure away from the user's finger. Measure that row before and after
  /// the layout change, then compensate the scroll offset by the observed
  /// movement so the row remains in the same viewport position.
  void _toggleWithStableAnchor(String anchorId, VoidCallback mutate) {
    final anchorContext = _anchorKey(anchorId).currentContext;
    final beforeBox = anchorContext?.findRenderObject();
    final beforeY = beforeBox is RenderBox
        ? beforeBox.localToGlobal(Offset.zero).dy
        : null;

    setState(mutate);
    if (beforeY == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _userScrollInProgress ||
          !widget.scrollController.hasClients) {
        return;
      }
      final afterBox = _anchorKey(anchorId).currentContext?.findRenderObject();
      if (afterBox is! RenderBox) return;
      final delta = afterBox.localToGlobal(Offset.zero).dy - beforeY;
      if (delta.abs() < 0.5) return;
      final position = widget.scrollController.position;
      // This chat is a reverse ListView: increasing its offset moves content
      // down on screen, unlike a conventional downwards viewport. Read the
      // actual axis direction so the compensation also remains correct if the
      // list becomes non-reversed later.
      final reverseAxis =
          position.axisDirection == AxisDirection.up ||
          position.axisDirection == AxisDirection.left;
      final scrollDelta = reverseAxis ? -delta : delta;
      final target = (position.pixels + scrollDelta)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((target - position.pixels).abs() >= 0.5) {
        widget.scrollController.jumpTo(target);
      }
    });
  }

  Future<void> _openArtifact(String messageId, ArtifactRef artifact) async {
    final requestSessionId = widget.sessionId;
    final requestProjectPath = widget.projectPath;
    final sourcePath = artifact.projectRelativePath;
    if (artifact.isSource &&
        (requestProjectPath == null ||
            requestProjectPath.isEmpty ||
            !isSafeProjectRelativePath(sourcePath))) {
      _showArtifactError(AppLocalizations.of(context).artifactUnavailable);
      return;
    }
    final bridge = context.read<BridgeService>();
    if (artifact.isSource) {
      final safeSourcePath = sourcePath!;
      try {
        // Source refs are opened atomically by identity. Resolving a download
        // URL first creates a TOCTOU window and is unnecessary for File Peek.
        final sourceContent = await bridge.readArtifactSource(
          sessionId: requestSessionId,
          messageId: messageId,
          artifactId: artifact.id,
          filePath: safeSourcePath,
          maxLines: filePeekMaxLinesForInitialLine(artifact.line),
        );
        if (!mounted || widget.sessionId != requestSessionId) return;
        if (widget.projectPath != requestProjectPath) {
          _showArtifactError(AppLocalizations.of(context).artifactUnavailable);
          return;
        }
        if (sourceContent.error != null) {
          _showArtifactError(
            _artifactErrorMessage(sourceContent.errorCode, sourceRead: true),
          );
          return;
        }
        return showFilePeekSheet(
          context,
          bridge: bridge,
          projectPath: requestProjectPath!,
          filePath: safeSourcePath,
          initialLine: artifact.line,
          artifactSessionId: requestSessionId,
          artifactMessageId: messageId,
          artifactId: artifact.id,
          initialContent: sourceContent,
          onOpened: () => widget.onFilePeekOpened?.call(safeSourcePath),
        );
      } on ArtifactSourceReadException catch (error) {
        if (!mounted || widget.sessionId != requestSessionId) return;
        if (widget.projectPath != requestProjectPath) return;
        _showArtifactError(_artifactErrorMessage(error.code, sourceRead: true));
      } catch (_) {
        if (mounted &&
            widget.sessionId == requestSessionId &&
            widget.projectPath == requestProjectPath) {
          _showArtifactError(AppLocalizations.of(context).artifactOpenFailed);
        }
      }
      return;
    }
    try {
      final resolved = await bridge.resolveArtifact(
        sessionId: requestSessionId,
        messageId: messageId,
        artifactId: artifact.id,
      );
      if (!mounted || widget.sessionId != requestSessionId) return;
      if (supportsEmbeddedArtifactPreview()) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ArtifactPreviewScreen(
              previewUrl: resolved.url,
              filename: artifact.filename,
              mimeType: artifact.mimeType,
              sizeBytes: artifact.sizeBytes,
              expiresAt: resolved.expiresAt,
            ),
          ),
        );
        return;
      }
      final launched = await launchUrl(
        resolved.url,
        mode: LaunchMode.externalApplication,
      );
      if (!mounted || widget.sessionId != requestSessionId) return;
      if (!launched) {
        _showArtifactError(AppLocalizations.of(context).artifactOpenFailed);
      }
    } on ArtifactResolveException catch (error) {
      if (!mounted || widget.sessionId != requestSessionId) return;
      _showArtifactError(_artifactErrorMessage(error.code));
    } catch (_) {
      if (mounted && widget.sessionId == requestSessionId) {
        _showArtifactError(AppLocalizations.of(context).artifactOpenFailed);
      }
    }
  }

  String _artifactErrorMessage(String? code, {bool sourceRead = false}) {
    final localizations = AppLocalizations.of(context);
    return switch (code) {
      'artifact_expired' ||
      'artifact_gone' ||
      'artifact_changed' ||
      'artifact_not_found' ||
      'artifact_unavailable' ||
      'file_gone' ||
      'file_changed' ||
      'file_unreadable' ||
      'path_not_allowed' ||
      'source_path_mismatch' ||
      'session_not_found' => localizations.artifactUnavailable,
      'bridge_disconnected' ||
      'bridge_changed' ||
      'bridge_reconnecting' => localizations.artifactReconnect,
      'artifact_resolve_unsupported' ||
      'artifact_source_read_unsupported' ||
      'unsupported_message' => localizations.artifactBridgeUpdateRequired,
      'artifact_resolve_timeout' ||
      'artifact_source_read_timeout' => localizations.artifactTimeout,
      _ =>
        sourceRead
            ? localizations.artifactOpenFailed
            : localizations.artifactPrepareFailed,
    };
  }

  void _showArtifactError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ---------------------------------------------------------------------------
  // Scroll to user entry
  // ---------------------------------------------------------------------------

  /// Scrolls the chat list to make the given [UserChatEntry] visible.
  ///
  /// Uses [AutoScrollController.scrollToIndex] which handles both on-screen
  /// and off-screen items correctly with variable-height widgets.
  void _scrollToUserEntry(UserChatEntry entry) {
    final entries = context.read<ChatSessionCubit>().state.entries;
    final idx = entries.indexOf(entry);
    if (idx < 0) return;
    widget.scrollController.scrollToIndex(
      idx,
      preferPosition: AutoScrollPosition.middle,
      duration: const Duration(milliseconds: 300),
    );
  }

  // ---------------------------------------------------------------------------
  // Plan text resolution
  // ---------------------------------------------------------------------------

  /// For entries with ExitPlanMode, search all entries for a Write tool
  /// targeting `.claude/plans/` to resolve the plan text.
  String? _resolvePlanText(ChatEntry entry) {
    if (entry is! ServerChatEntry) return null;
    final msg = entry.message;
    if (msg is! AssistantServerMessage) return null;
    final hasExitPlan = msg.message.content.any(
      (c) => c is ToolUseContent && c.name == 'ExitPlanMode',
    );
    if (!hasExitPlan) return null;
    return _findPlanFromWriteTool();
  }

  /// Search all entries in reverse for a Write tool targeting `.claude/plans/`.
  String? _findPlanFromWriteTool() {
    final entries = context.read<ChatSessionCubit>().state.entries;
    for (var i = entries.length - 1; i >= 0; i--) {
      final entry = entries[i];
      if (entry is! ServerChatEntry) continue;
      final msg = entry.message;
      if (msg is! AssistantServerMessage) continue;
      for (final c in msg.message.content) {
        if (c is! ToolUseContent || c.name != 'Write') continue;
        final filePath = c.input['file_path']?.toString() ?? '';
        if (!filePath.contains('.claude/plans/')) continue;
        final content = c.input['content']?.toString();
        if (content != null && content.isNotEmpty) return content;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final chatCubit = context.watch<ChatSessionCubit>();
    final chatState = chatCubit.state;
    final hiddenToolUseIds = chatState.hiddenToolUseIds;
    final allEntries = chatState.entries;

    // Watch only the isStreaming flag (not the full streaming text) so the
    // list rebuilds when streaming starts/stops (to adjust itemCount) but NOT
    // on every text delta. The actual streaming text is rendered inside a
    // scoped BlocBuilder on the streaming item only.
    final hasStreaming = context.select<StreamingStateCubit, bool>(
      (cubit) => cubit.state.isStreaming,
    );
    final latestTurnIsActive =
        chatState.status == ProcessStatus.running ||
        chatState.status == ProcessStatus.waitingApproval ||
        chatState.status == ProcessStatus.compacting ||
        chatState.externalDesktopTurnActive ||
        hasStreaming;
    final processLayout = buildChatProcessLayout(
      allEntries,
      latestTurnIsActive: latestTurnIsActive,
      hasTransientCurrentOutput: hasStreaming,
    );
    final messageCount = allEntries.length + (hasStreaming ? 1 : 0);
    final streamingCubit = context.read<StreamingStateCubit>();

    final paging = chatCubit.localHistoryPaging.value;
    final content = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // Only unfocus when user drags the list (not programmatic scroll).
        // This prevents the keyboard from being dismissed during automatic
        // scroll-to-bottom triggered by streaming updates.
        if (notification is UserScrollNotification) {
          _userScrollInProgress =
              notification.direction != ScrollDirection.idle;
          if (_userScrollInProgress) {
            FocusScope.of(context).unfocus();
          }
        }
        if (paging.enabled &&
            paging.hasMore &&
            shouldLoadOlderLocalHistory(notification.metrics)) {
          unawaited(chatCubit.loadOlderLocalHistory());
        }
        return false;
      },
      child: ListView.builder(
        controller: widget.scrollController,
        reverse: true,
        physics: MaintainReadingPositionPhysics(
          shouldMaintain: () => streamingCubit.state.isStreaming,
        ),
        padding: EdgeInsets.only(top: 36, bottom: widget.bottomPadding),
        itemCount:
            messageCount +
            ((paging.enabled &&
                    (paging.hasMore || paging.loading || paging.error != null))
                ? 1
                : 0),
        itemBuilder: (context, index) {
          if (index == messageCount) {
            if (paging.hasMore && !paging.loading && paging.error == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) unawaited(chatCubit.loadOlderLocalHistory());
              });
            }
            return _LocalHistoryPageIndicator(
              paging: paging,
              onRetry: () async {
                await chatCubit.loadOlderLocalHistory();
              },
            );
          }
          // index 0 = newest entry (bottom of chat)
          // Map to actual entry index:
          final entryIndex = messageCount - 1 - index;

          // Streaming entry is at messageCount - 1 (index 0 in reverse)
          if (hasStreaming && entryIndex == allEntries.length) {
            // Scoped BlocBuilder: only this widget rebuilds on streaming deltas
            final turn = processLayout.latestTurn;
            final turnKey =
                turn?.key ??
                processLayout.latestTurnKey ??
                'session:${widget.sessionId}';
            final progressKey = 'live:$turnKey';
            return _anchoredDisclosure(
              'current:$progressKey',
              BlocBuilder<StreamingStateCubit, StreamingState>(
                builder: (context, streamingState) {
                  if (!streamingState.isStreaming) {
                    return const SizedBox.shrink();
                  }
                  final thinking = streamingState.thinking.trim();
                  final currentTool = turn?.currentTool;
                  final expanded = _expandedCurrentProgress.contains(
                    progressKey,
                  );
                  final hasDetails = thinking.isNotEmpty || currentTool != null;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ChatCurrentProgressHeader(
                        turnKey: progressKey,
                        expanded: expanded,
                        hasDetails: hasDetails,
                        onToggle: () => _toggleCurrentProgress(progressKey),
                      ),
                      if (streamingState.text.isNotEmpty)
                        ChatEntryWidget(
                          entry: StreamingChatEntry(text: streamingState.text),
                          previous: null,
                          httpBaseUrl: widget.httpBaseUrl,
                          sessionId: widget.sessionId,
                          projectPath: widget.projectPath,
                          onRetryMessage: null,
                          collapseToolResults: null,
                          hiddenToolUseIds: const {},
                          isCodex: widget.isCodex,
                        ),
                      if (currentTool != null)
                        ChatCurrentToolActivityLine(
                          activity: currentTool,
                          onTap: () => _toggleCurrentProgress(progressKey),
                        ),
                      if (thinking.isNotEmpty && expanded)
                        ChatLiveThinkingDetails(text: thinking),
                    ],
                  );
                },
              ),
            );
          }

          final entry = allEntries[entryIndex];
          final previous = entryIndex > 0 ? allEntries[entryIndex - 1] : null;
          final processSegment = processLayout.segmentForEntry(entryIndex);
          final intermediateTurn = processLayout.turnForEntry(entryIndex);
          final isIntermediateEntry =
              intermediateTurn?.isIntermediateEntry(entryIndex) == true;
          final intermediateExpanded =
              intermediateTurn != null &&
              _expandedIntermediateTurns.contains(intermediateTurn.key);
          final showIntermediateHeader =
              intermediateTurn?.showsIntermediateSummaryAt(entryIndex) == true;
          if (isIntermediateEntry && !intermediateExpanded) {
            final collapsedTurn = intermediateTurn;
            if (!showIntermediateHeader || collapsedTurn == null) {
              return const SizedBox.shrink();
            }
            return AutoScrollTag(
              key: ValueKey('intermediate:${collapsedTurn.key}'),
              controller: widget.scrollController,
              index: entryIndex,
              child: _anchoredDisclosure(
                'intermediate:${collapsedTurn.key}',
                ChatIntermediateOutputsDisclosure(
                  turn: collapsedTurn,
                  expanded: false,
                  onToggle: () => _toggleIntermediateTurn(collapsedTurn.key),
                ),
              ),
            );
          }

          final isCurrentAssistant =
              !hasStreaming &&
              intermediateTurn?.isCurrentAssistantEntry(entryIndex) == true;
          final isCurrentProcess =
              !hasStreaming &&
              intermediateTurn?.isCurrentProcessEntry(entryIndex) == true;
          final currentProgressKey = intermediateTurn == null
              ? null
              : 'entry:${intermediateTurn.key}';
          final currentExpanded =
              currentProgressKey != null &&
              _expandedCurrentProgress.contains(currentProgressKey);
          final isCurrentSummary =
              isCurrentProcess &&
              intermediateTurn?.currentSegment?.showsSummaryAt(entryIndex) ==
                  true;
          if (isCurrentProcess && !currentExpanded) {
            if (!isCurrentSummary || currentProgressKey == null) {
              return const SizedBox.shrink();
            }
            final currentTool = intermediateTurn?.currentTool;
            return AutoScrollTag(
              key: ValueKey('current:$currentProgressKey'),
              controller: widget.scrollController,
              index: entryIndex,
              child: _anchoredDisclosure(
                'current:$currentProgressKey',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ChatCurrentProgressHeader(
                      turnKey: currentProgressKey,
                      expanded: false,
                      hasDetails: true,
                      onToggle: () =>
                          _toggleCurrentProgress(currentProgressKey),
                    ),
                    if (currentTool != null)
                      ChatCurrentToolActivityLine(
                        activity: currentTool,
                        onTap: () => _toggleCurrentProgress(currentProgressKey),
                      ),
                  ],
                ),
              ),
            );
          }

          final processExpanded =
              processSegment != null &&
              _expandedProcessSegments.contains(processSegment.key);
          if (!isIntermediateEntry &&
              !isCurrentProcess &&
              processSegment != null &&
              processSegment.detailCount > 0 &&
              processSegment.isProcessEntry(entryIndex) &&
              !processExpanded) {
            if (!processSegment.showsSummaryAt(entryIndex)) {
              return const SizedBox.shrink();
            }
            return AutoScrollTag(
              key: ValueKey('process:${processSegment.key}'),
              controller: widget.scrollController,
              index: entryIndex,
              child: _anchoredDisclosure(
                'process:${processSegment.key}',
                ChatProcessDisclosure(
                  segment: processSegment,
                  expanded: false,
                  onToggle: () => _toggleProcessSegment(processSegment.key),
                ),
              ),
            );
          }
          final transcriptTailComplete =
              chatState.status == ProcessStatus.idle &&
              chatState.queuedInput == null &&
              !hasStreaming;
          final onForkMessage =
              widget.isCodex &&
                  shouldShowForkForAssistant(
                    allEntries,
                    entryIndex,
                    transcriptTailComplete: transcriptTailComplete,
                  )
              ? widget.onForkMessage
              : null;
          final fileRoot = widget.projectPath;
          final showAssistantProcessDetails = isIntermediateEntry
              ? true
              : isCurrentAssistant
              ? currentExpanded
              : processSegment?.hasInlineProcessAt(entryIndex) != true ||
                    processExpanded;

          Widget child = ChatEntryWidget(
            entry: entry,
            previous: previous,
            httpBaseUrl: widget.httpBaseUrl,
            sessionId: widget.sessionId,
            projectPath: widget.projectPath,
            onRetryMessage: widget.onRetryMessage,
            onRewindMessage: widget.onRewindMessage,
            onForkMessage: onForkMessage,
            onDismissCodexWarning: chatCubit.dismissCodexWarning,
            collapseToolResults: widget.collapseToolResults,
            showAssistantProcessDetails: showAssistantProcessDetails,
            resolvedPlanText: _resolvePlanText(entry),
            hiddenToolUseIds: hiddenToolUseIds,
            onArtifactOpen: _openArtifact,
            onFileTap: fileRoot?.isNotEmpty == true
                ? (filePath) {
                    openFilePeek(
                      context,
                      bridge: context.read<BridgeService>(),
                      projectPath: fileRoot!,
                      filePath: filePath,
                      projectFiles: context.read<FileListCubit>().state,
                      onResolvedFilePath: widget.onFilePeekOpened,
                    );
                  }
                : null,
            onImageTap: (user) {
              final claudeSessionId = context
                  .read<ChatSessionCubit>()
                  .state
                  .claudeSessionId;
              final httpBaseUrl = widget.httpBaseUrl;
              if (claudeSessionId == null ||
                  claudeSessionId.isEmpty ||
                  httpBaseUrl == null) {
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MessageImagesScreen(
                    bridge: context.read<BridgeService>(),
                    httpBaseUrl: httpBaseUrl,
                    claudeSessionId: claudeSessionId,
                    messageUuid: user.messageUuid!,
                    imageCount: user.imageCount,
                  ),
                ),
              );
            },
            isCodex: widget.isCodex,
          );
          if (isIntermediateEntry &&
              showIntermediateHeader &&
              intermediateTurn != null) {
            child = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _anchoredDisclosure(
                  'intermediate:${intermediateTurn.key}',
                  ChatIntermediateOutputsDisclosure(
                    turn: intermediateTurn,
                    expanded: true,
                    onToggle: () =>
                        _toggleIntermediateTurn(intermediateTurn.key),
                  ),
                ),
                child,
              ],
            );
          } else if (isCurrentAssistant && currentProgressKey != null) {
            final currentTool = intermediateTurn?.currentTool;
            final hasDetails =
                (intermediateTurn?.currentSegment?.detailCount ?? 0) > 0 ||
                currentTool != null;
            child = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _anchoredDisclosure(
                  'current:$currentProgressKey',
                  ChatCurrentProgressHeader(
                    turnKey: currentProgressKey,
                    expanded: currentExpanded,
                    hasDetails: hasDetails,
                    onToggle: () => _toggleCurrentProgress(currentProgressKey),
                  ),
                ),
                child,
                if (currentTool != null)
                  ChatCurrentToolActivityLine(
                    activity: currentTool,
                    onTap: () => _toggleCurrentProgress(currentProgressKey),
                  ),
              ],
            );
          } else if (isCurrentSummary && currentProgressKey != null) {
            final currentTool = intermediateTurn?.currentTool;
            child = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _anchoredDisclosure(
                  'current:$currentProgressKey',
                  ChatCurrentProgressHeader(
                    turnKey: currentProgressKey,
                    expanded: currentExpanded,
                    hasDetails: true,
                    onToggle: () => _toggleCurrentProgress(currentProgressKey),
                  ),
                ),
                if (currentTool != null)
                  ChatCurrentToolActivityLine(
                    activity: currentTool,
                    onTap: () => _toggleCurrentProgress(currentProgressKey),
                  ),
                child,
              ],
            );
          } else if (!isIntermediateEntry &&
              !isCurrentAssistant &&
              !isCurrentProcess &&
              processSegment != null &&
              processSegment.detailCount > 0 &&
              processSegment.showsSummaryAt(entryIndex)) {
            child = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _anchoredDisclosure(
                  'process:${processSegment.key}',
                  ChatProcessDisclosure(
                    segment: processSegment,
                    expanded: processExpanded,
                    onToggle: () => _toggleProcessSegment(processSegment.key),
                  ),
                ),
                child,
              ],
            );
          }
          // Wrap with AutoScrollTag for scroll-to-index support.
          // Use entryIndex (not reverse index) as the AutoScrollTag index.
          child = AutoScrollTag(
            key: ValueKey(_entryKey(entry, entryIndex)),
            controller: widget.scrollController,
            index: entryIndex,
            child: child,
          );
          return child;
        },
      ),
    );
    if (widget.selectionActions.isEmpty) return content;
    return ChatSelectionActionsScope(
      actions: widget.selectionActions,
      child: content,
    );
  }

  void _toggleProcessSegment(String segmentKey) {
    _toggleWithStableAnchor('process:$segmentKey', () {
      if (!_expandedProcessSegments.add(segmentKey)) {
        _expandedProcessSegments.remove(segmentKey);
      }
    });
  }

  void _toggleIntermediateTurn(String turnKey) {
    _toggleWithStableAnchor('intermediate:$turnKey', () {
      if (!_expandedIntermediateTurns.add(turnKey)) {
        _expandedIntermediateTurns.remove(turnKey);
      }
    });
  }

  void _toggleCurrentProgress(String progressKey) {
    _toggleWithStableAnchor('current:$progressKey', () {
      if (!_expandedCurrentProgress.add(progressKey)) {
        _expandedCurrentProgress.remove(progressKey);
      }
    });
  }

  String _entryKey(ChatEntry entry, int index) {
    return switch (entry) {
      ServerChatEntry(:final message) => switch (message) {
        ToolResultMessage(:final toolUseId) => 'tool_result:$toolUseId',
        AssistantServerMessage(:final messageUuid, :final message) =>
          messageUuid != null && messageUuid.isNotEmpty
              ? 'assistant_uuid:$messageUuid'
              : message.id.isNotEmpty
              ? 'assistant_id:${message.id}'
              : 'assistant_ts:${entry.timestamp.microsecondsSinceEpoch}:$index',
        PermissionRequestMessage(:final toolUseId) => 'permission:$toolUseId',
        ToolUseSummaryMessage() =>
          'tool_summary:${entry.timestamp.microsecondsSinceEpoch}:$index',
        _ =>
          '${message.runtimeType}:${entry.timestamp.microsecondsSinceEpoch}:$index',
      },
      UserChatEntry(:final messageUuid, :final clientMessageId, :final text) =>
        messageUuid != null && messageUuid.isNotEmpty
            ? 'user_uuid:$messageUuid'
            : clientMessageId != null && clientMessageId.isNotEmpty
            ? 'user_client:$clientMessageId'
            : 'user_ts:${entry.timestamp.microsecondsSinceEpoch}:${text.hashCode}:$index',
      StreamingChatEntry() => 'streaming',
    };
  }
}

class _LocalHistoryPageIndicator extends StatelessWidget {
  const _LocalHistoryPageIndicator({
    required this.paging,
    required this.onRetry,
  });

  final LocalHistoryPagingState paging;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (paging.error != null) {
      return Center(
        child: TextButton.icon(
          key: const ValueKey('local_history_retry'),
          onPressed: () => unawaited(onRetry()),
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(AppLocalizations.of(context).retry),
        ),
      );
    }
    return const Padding(
      key: ValueKey('local_history_loading'),
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
