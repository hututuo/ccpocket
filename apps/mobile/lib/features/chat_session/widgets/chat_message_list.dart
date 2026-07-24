import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../../providers/bridge_cubits.dart';
import '../../../services/bridge_service.dart';
import '../../../utils/artifact_link_matcher.dart';
import '../../../widgets/bubbles/assistant_bubble.dart';
import '../../../widgets/bubbles/todo_write_widget.dart';
import '../../../widgets/chat_selection_actions.dart';
import '../../../widgets/message_bubble.dart';
import '../../artifact_preview/artifact_preview_entry.dart';
import '../../generated_image_preview/generated_image_preview_mapper.dart';
import '../../generated_image_preview/generated_image_preview_item.dart';
import '../../generated_image_preview/generated_image_response_grouping.dart';
import '../../generated_image_preview/widgets/generated_image_chat_group.dart';
import '../../file_peek/file_peek_sheet.dart';
import '../../message_images/message_images_screen.dart';
import '../state/chat_session_cubit.dart';
import '../state/streaming_state.dart';
import '../state/streaming_state_cubit.dart';
import 'chat_intermediate_process_group.dart';
import 'maintain_reading_position_physics.dart';
import 'chat_process_disclosure.dart';
import 'chat_process_layout.dart';
import 'reading_position_auto_scroll_controller.dart';

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

class _ChatMessageListState extends State<ChatMessageList>
    with WidgetsBindingObserver {
  ChatSessionCubit? _pagingCubit;
  List<ChatEntry>? _processLayoutEntries;
  bool? _processLayoutLatestTurnIsActive;
  bool? _processLayoutHasTransientCurrentOutput;
  ChatProcessLayout? _cachedProcessLayout;
  final Set<String> _expandedProcessSegments = {};
  final Set<String> _expandedIntermediateTurns = {};
  final Set<String> _expandedCurrentProgress = {};
  final Map<String, GlobalKey> _disclosureAnchorKeys = {};
  bool? _tickerEnabled;
  final _generatedImageItemCache =
      <GeneratedImageItemCacheKey, GeneratedImagePreviewItem>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.scrollToUserEntry?.addListener(_onScrollToUserEntry);
    widget.collapseToolResults?.addListener(_onCollapseSignal);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    if (_tickerEnabled == true && !tickerEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _requestCollapseAll();
      });
    }
    _tickerEnabled = tickerEnabled;
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
    if (oldWidget.collapseToolResults != widget.collapseToolResults) {
      oldWidget.collapseToolResults?.removeListener(_onCollapseSignal);
      widget.collapseToolResults?.addListener(_onCollapseSignal);
      _collapseAllState();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.scrollToUserEntry?.removeListener(_onScrollToUserEntry);
    widget.collapseToolResults?.removeListener(_onCollapseSignal);
    _pagingCubit?.localHistoryPaging.removeListener(_onPagingChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _requestCollapseAll();
  }

  void _requestCollapseAll() {
    final notifier = widget.collapseToolResults;
    if (notifier != null) {
      notifier.value++;
    } else {
      _collapseAllState();
    }
  }

  void _onCollapseSignal() => _collapseAllState();

  void _collapseAllState() {
    if (_expandedProcessSegments.isEmpty &&
        _expandedIntermediateTurns.isEmpty &&
        _expandedCurrentProgress.isEmpty) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _expandedProcessSegments.clear();
      _expandedIntermediateTurns.clear();
      _expandedCurrentProgress.clear();
    });
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
      _disclosureAnchorKeys.putIfAbsent(id, GlobalKey.new);

  Widget _anchoredDisclosure(String id, Widget child) =>
      KeyedSubtree(key: _anchorKey(id), child: child);

  ChatProcessLayout _processLayoutFor(
    List<ChatEntry> entries, {
    required bool latestTurnIsActive,
    required bool hasTransientCurrentOutput,
  }) {
    final cached = _cachedProcessLayout;
    if (cached != null &&
        identical(entries, _processLayoutEntries) &&
        latestTurnIsActive == _processLayoutLatestTurnIsActive &&
        hasTransientCurrentOutput == _processLayoutHasTransientCurrentOutput) {
      return cached;
    }
    final layout = buildChatProcessLayout(
      entries,
      latestTurnIsActive: latestTurnIsActive,
      hasTransientCurrentOutput: hasTransientCurrentOutput,
    );
    _processLayoutEntries = entries;
    _processLayoutLatestTurnIsActive = latestTurnIsActive;
    _processLayoutHasTransientCurrentOutput = hasTransientCurrentOutput;
    _cachedProcessLayout = layout;
    return layout;
  }

  /// Keeps a user-triggered height change inside the viewport's layout pass.
  /// The custom scroll position corrects the anchor before paint; the callback
  /// below only releases the request and never moves the viewport.
  void _toggleWithStableReadingPosition(String anchorId, VoidCallback mutate) {
    final controller = widget.scrollController;
    final generation = controller is ReadingPositionAutoScrollController
        ? controller.beginAnchorMutation(_anchorKey(anchorId))
        : null;
    setState(mutate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller is ReadingPositionAutoScrollController) {
        controller.endAnchorMutation(generation);
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

  Widget _timelineItem({
    required String key,
    required int entryIndex,
    required Widget child,
  }) => ReadingPositionItem(
    child: AutoScrollTag(
      key: ValueKey(key),
      controller: widget.scrollController,
      index: entryIndex,
      child: child,
    ),
  );

  Widget _buildTranscriptEntry({
    required List<ChatEntry> entries,
    required int entryIndex,
    required Set<String> hiddenToolUseIds,
    required bool transcriptTailComplete,
    required bool showAssistantProcessDetails,
  }) {
    final entry = entries[entryIndex];
    final previous = entryIndex > 0 ? entries[entryIndex - 1] : null;
    final onForkMessage =
        widget.isCodex &&
            shouldShowForkForAssistant(
              entries,
              entryIndex,
              transcriptTailComplete: transcriptTailComplete,
            )
        ? widget.onForkMessage
        : null;
    final fileRoot = widget.projectPath;
    final chatCubit = context.read<ChatSessionCubit>();
    return ChatEntryWidget(
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
        final claudeSessionId = chatCubit.state.claudeSessionId;
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
  }

  Widget _buildAssistantProcessDetails(
    List<ChatEntry> entries,
    int entryIndex,
    Set<String> hiddenToolUseIds,
  ) {
    final entry = entries[entryIndex];
    if (entry case ServerChatEntry(
      message: final AssistantServerMessage message,
    )) {
      return AssistantProcessDetails(
        message: message,
        collapseNotifier: widget.collapseToolResults,
        hiddenToolUseIds: hiddenToolUseIds,
      );
    }
    return const SizedBox.shrink();
  }

  List<Widget> _buildProcessSegmentDetails({
    required ChatProcessSegmentLayout segment,
    required List<ChatEntry> entries,
    required Set<String> hiddenToolUseIds,
    required bool transcriptTailComplete,
    required Map<int, List<GeneratedImagePreviewItem>> imageItemsByAnchor,
    required Set<int> imageGroupMemberIndices,
  }) {
    final details = <Widget>[];
    if (segment.assistantEntryIndex case final assistantIndex?
        when segment.hasInlineAssistantProcess) {
      details.add(
        KeyedSubtree(
          key: ValueKey('chat_process_inline_${segment.key}'),
          child: _buildAssistantProcessDetails(
            entries,
            assistantIndex,
            hiddenToolUseIds,
          ),
        ),
      );
    }
    final processIndices = segment.processEntryIndices.toList()..sort();
    for (final processIndex in processIndices) {
      details.add(
        KeyedSubtree(
          key: ValueKey('chat_process_entry_${segment.key}_$processIndex'),
          child: switch (imageItemsByAnchor[processIndex]) {
            final items? => GeneratedImageChatGroup(items: items),
            _ when imageGroupMemberIndices.contains(processIndex) =>
              const SizedBox.shrink(),
            _ => _buildTranscriptEntry(
              entries: entries,
              entryIndex: processIndex,
              hiddenToolUseIds: hiddenToolUseIds,
              transcriptTailComplete: transcriptTailComplete,
              showAssistantProcessDetails: true,
            ),
          },
        ),
      );
    }
    return details;
  }

  Widget _buildHistoricalProcessGroup({
    required ChatProcessSegmentLayout segment,
    required List<ChatEntry> entries,
    required Set<String> hiddenToolUseIds,
    required bool transcriptTailComplete,
    required Map<int, List<GeneratedImagePreviewItem>> imageItemsByAnchor,
    required Set<int> imageGroupMemberIndices,
  }) {
    final expanded = _expandedProcessSegments.contains(segment.key);
    final children = <Widget>[];
    if (segment.assistantEntryIndex case final assistantIndex?) {
      children.add(
        _buildTranscriptEntry(
          entries: entries,
          entryIndex: assistantIndex,
          hiddenToolUseIds: hiddenToolUseIds,
          transcriptTailComplete: transcriptTailComplete,
          showAssistantProcessDetails: false,
        ),
      );
    }
    if (segment.detailCount > 0) {
      children.add(
        _anchoredDisclosure(
          'process:${segment.key}',
          ChatProcessDisclosure(
            segment: segment,
            expanded: expanded,
            onToggle: () => _toggleProcessSegment(segment.key),
          ),
        ),
      );
      if (expanded) {
        children.addAll(
          _buildProcessSegmentDetails(
            segment: segment,
            entries: entries,
            hiddenToolUseIds: hiddenToolUseIds,
            transcriptTailComplete: transcriptTailComplete,
            imageItemsByAnchor: imageItemsByAnchor,
            imageGroupMemberIndices: imageGroupMemberIndices,
          ),
        );
      }
    }
    return Column(
      key: ValueKey('chat_process_group_${segment.key}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _buildCurrentProcessGroup({
    required ChatProcessTurnLayout turn,
    required ChatProcessSegmentLayout segment,
    required String progressKey,
    required List<ChatEntry> entries,
    required Set<String> hiddenToolUseIds,
    required bool transcriptTailComplete,
    required Map<int, List<GeneratedImagePreviewItem>> imageItemsByAnchor,
    required Set<int> imageGroupMemberIndices,
  }) {
    final expanded = _expandedCurrentProgress.contains(progressKey);
    final currentTool = turn.currentTool;
    final hasDetails = segment.detailCount > 0 || currentTool != null;
    final children = <Widget>[
      _anchoredDisclosure(
        'current:$progressKey',
        ChatCurrentProgressHeader(
          turnKey: progressKey,
          expanded: expanded,
          hasDetails: hasDetails,
          onToggle: () => _toggleCurrentProgress(progressKey),
        ),
      ),
    ];
    if (segment.assistantEntryIndex case final assistantIndex?) {
      children.add(
        _buildTranscriptEntry(
          entries: entries,
          entryIndex: assistantIndex,
          hiddenToolUseIds: hiddenToolUseIds,
          transcriptTailComplete: transcriptTailComplete,
          showAssistantProcessDetails: false,
        ),
      );
    }
    if (currentTool != null) {
      children.add(
        ChatCurrentToolActivityLine(
          activity: currentTool,
          onTap: () => _toggleCurrentProgress(progressKey),
        ),
      );
    }
    if (expanded) {
      children.addAll(
        _buildProcessSegmentDetails(
          segment: segment,
          entries: entries,
          hiddenToolUseIds: hiddenToolUseIds,
          transcriptTailComplete: transcriptTailComplete,
          imageItemsByAnchor: imageItemsByAnchor,
          imageGroupMemberIndices: imageGroupMemberIndices,
        ),
      );
    }
    return Column(
      key: ValueKey('chat_current_process_group_${turn.key}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
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
    final processLayout = _processLayoutFor(
      allEntries,
      latestTurnIsActive: latestTurnIsActive,
      hasTransientCurrentOutput: hasStreaming,
    );
    final messageCount = allEntries.length + (hasStreaming ? 1 : 0);
    final streamingCubit = context.read<StreamingStateCubit>();
    final imageGroups = groupGeneratedImageResponses(allEntries);
    final imageGroupMemberIndices = <int>{};
    final imageItemsByAnchor = <int, List<GeneratedImagePreviewItem>>{};
    for (final group in imageGroups) {
      final items = generatedImageItemsFromToolResults(
        group.messages,
        httpBaseUrl: widget.httpBaseUrl,
        itemCache: _generatedImageItemCache,
      );
      if (items.isEmpty) continue;
      imageItemsByAnchor[group.anchorEntryIndex] = items;
      imageGroupMemberIndices.addAll(group.memberEntryIndices);
    }
    final effectiveHiddenToolUseIds = {
      ...hiddenToolUseIds,
      ...completedGeneratedImageToolUseIds(allEntries),
    };

    final paging = chatCubit.localHistoryPaging.value;
    final content = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // Only unfocus when user drags the list (not programmatic scroll).
        // This prevents the keyboard from being dismissed during automatic
        // scroll-to-bottom triggered by streaming updates.
        if (notification is UserScrollNotification) {
          if (notification.direction != ScrollDirection.idle) {
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
          shouldMaintain: () {
            final controller = widget.scrollController;
            return streamingCubit.state.isStreaming &&
                (controller is! ReadingPositionAutoScrollController ||
                    !controller.hasAnchorMutation);
          },
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
            return ReadingPositionItem(
              child: _anchoredDisclosure(
                'current:$progressKey',
                BlocSelector<StreamingStateCubit, StreamingState, bool>(
                  selector: (state) => state.isStreaming,
                  builder: (context, streamingState) {
                    if (!streamingState) {
                      return const SizedBox.shrink();
                    }
                    final currentTool = turn?.currentTool;
                    final expanded = _expandedCurrentProgress.contains(
                      progressKey,
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        BlocSelector<StreamingStateCubit, StreamingState, bool>(
                          selector: (state) => state.thinking.trim().isNotEmpty,
                          builder: (context, hasThinking) {
                            return ChatCurrentProgressHeader(
                              turnKey: progressKey,
                              expanded: expanded,
                              hasDetails: hasThinking || currentTool != null,
                              onToggle: () =>
                                  _toggleCurrentProgress(progressKey),
                            );
                          },
                        ),
                        BlocSelector<
                          StreamingStateCubit,
                          StreamingState,
                          String
                        >(
                          selector: (state) => state.text,
                          builder: (context, text) {
                            if (text.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return ChatEntryWidget(
                              entry: StreamingChatEntry(text: text),
                              previous: null,
                              httpBaseUrl: widget.httpBaseUrl,
                              sessionId: widget.sessionId,
                              projectPath: widget.projectPath,
                              onRetryMessage: null,
                              collapseToolResults: null,
                              hiddenToolUseIds: const {},
                              isCodex: widget.isCodex,
                            );
                          },
                        ),
                        if (currentTool != null)
                          ChatCurrentToolActivityLine(
                            activity: currentTool,
                            onTap: () => _toggleCurrentProgress(progressKey),
                          ),
                        if (expanded)
                          BlocSelector<
                            StreamingStateCubit,
                            StreamingState,
                            String
                          >(
                            selector: (state) => state.thinking.trim(),
                            builder: (context, thinking) {
                              if (thinking.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return ChatLiveThinkingDetails(text: thinking);
                            },
                          ),
                      ],
                    );
                  },
                ),
              ),
            );
          }

          final entry = allEntries[entryIndex];
          final processSegment = processLayout.segmentForEntry(entryIndex);
          final intermediateTurn = processLayout.turnForEntry(entryIndex);
          if (intermediateTurn?.isPlanUpdateEntry(entryIndex) == true) {
            if (!intermediateTurn!.showsPlanUpdateAt(entryIndex)) {
              return const SizedBox.shrink();
            }
            final input = intermediateTurn.latestPlanUpdateInput;
            if (input == null) return const SizedBox.shrink();
            return _timelineItem(
              key: 'plan_update:${intermediateTurn.key}',
              entryIndex: entryIndex,
              child: TodoWriteWidget(
                key: ValueKey('live_plan_update_${intermediateTurn.key}'),
                input: input,
                collapseNotifier: widget.collapseToolResults,
              ),
            );
          }
          final isIntermediateEntry =
              intermediateTurn?.isIntermediateEntry(entryIndex) == true;
          final transcriptTailComplete =
              chatState.status == ProcessStatus.idle &&
              chatState.queuedInput == null &&
              !hasStreaming;

          // One outer fold is one real ListView item. Its temporary outputs,
          // nested disclosures and process details are descendants of that
          // item instead of independently appearing/disappearing peer rows.
          if (isIntermediateEntry) {
            if (intermediateTurn == null ||
                !intermediateTurn.showsIntermediateSummaryAt(entryIndex)) {
              return const SizedBox.shrink();
            }
            final intermediateExpanded = _expandedIntermediateTurns.contains(
              intermediateTurn.key,
            );
            return _timelineItem(
              key: 'intermediate:${intermediateTurn.key}',
              entryIndex: entryIndex,
              child: ChatIntermediateProcessGroup(
                turn: intermediateTurn,
                expanded: intermediateExpanded,
                outerDisclosure: _anchoredDisclosure(
                  'intermediate:${intermediateTurn.key}',
                  ChatIntermediateOutputsDisclosure(
                    turn: intermediateTurn,
                    expanded: intermediateExpanded,
                    onToggle: () =>
                        _toggleIntermediateTurn(intermediateTurn.key),
                  ),
                ),
                segmentBuilder: (segment) => _buildHistoricalProcessGroup(
                  segment: segment,
                  entries: allEntries,
                  hiddenToolUseIds: effectiveHiddenToolUseIds,
                  transcriptTailComplete: transcriptTailComplete,
                  imageItemsByAnchor: imageItemsByAnchor,
                  imageGroupMemberIndices: imageGroupMemberIndices,
                ),
                auxiliaryEntryBuilder: (entryIndex) =>
                    switch (imageItemsByAnchor[entryIndex]) {
                      final items? => GeneratedImageChatGroup(items: items),
                      _ when imageGroupMemberIndices.contains(entryIndex) =>
                        const SizedBox.shrink(),
                      _ => _buildTranscriptEntry(
                        entries: allEntries,
                        entryIndex: entryIndex,
                        hiddenToolUseIds: effectiveHiddenToolUseIds,
                        transcriptTailComplete: transcriptTailComplete,
                        showAssistantProcessDetails: true,
                      ),
                    },
              ),
            );
          }

          final currentSegment = intermediateTurn?.currentSegment;
          final isCurrentSegmentEntry =
              !hasStreaming &&
              currentSegment != null &&
              currentSegment.containsEntry(entryIndex);
          if (isCurrentSegmentEntry) {
            if (!currentSegment.showsSummaryAt(entryIndex)) {
              return const SizedBox.shrink();
            }
            final progressKey = 'entry:${intermediateTurn!.key}';
            return _timelineItem(
              key: 'current:$progressKey',
              entryIndex: entryIndex,
              child: _buildCurrentProcessGroup(
                turn: intermediateTurn,
                segment: currentSegment,
                progressKey: progressKey,
                entries: allEntries,
                hiddenToolUseIds: effectiveHiddenToolUseIds,
                transcriptTailComplete: transcriptTailComplete,
                imageItemsByAnchor: imageItemsByAnchor,
                imageGroupMemberIndices: imageGroupMemberIndices,
              ),
            );
          }

          if (processSegment != null) {
            if (!processSegment.showsSummaryAt(entryIndex)) {
              return const SizedBox.shrink();
            }
            final itemKey = processSegment.assistantEntryIndex != null
                ? _entryKey(entry, entryIndex)
                : 'process:${processSegment.key}';
            return _timelineItem(
              key: itemKey,
              entryIndex: entryIndex,
              child: _buildHistoricalProcessGroup(
                segment: processSegment,
                entries: allEntries,
                hiddenToolUseIds: effectiveHiddenToolUseIds,
                transcriptTailComplete: transcriptTailComplete,
                imageItemsByAnchor: imageItemsByAnchor,
                imageGroupMemberIndices: imageGroupMemberIndices,
              ),
            );
          }

          final imageItems = imageItemsByAnchor[entryIndex];
          return _timelineItem(
            key: _entryKey(entry, entryIndex),
            entryIndex: entryIndex,
            child: imageItems != null
                ? GeneratedImageChatGroup(items: imageItems)
                : imageGroupMemberIndices.contains(entryIndex)
                ? const SizedBox.shrink()
                : _buildTranscriptEntry(
                    entries: allEntries,
                    entryIndex: entryIndex,
                    hiddenToolUseIds: effectiveHiddenToolUseIds,
                    transcriptTailComplete: transcriptTailComplete,
                    showAssistantProcessDetails: true,
                  ),
          );
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
    _toggleWithStableReadingPosition('process:$segmentKey', () {
      if (!_expandedProcessSegments.add(segmentKey)) {
        _expandedProcessSegments.remove(segmentKey);
      }
    });
  }

  void _toggleIntermediateTurn(String turnKey) {
    _toggleWithStableReadingPosition('intermediate:$turnKey', () {
      if (!_expandedIntermediateTurns.add(turnKey)) {
        _expandedIntermediateTurns.remove(turnKey);
      }
    });
  }

  void _toggleCurrentProgress(String progressKey) {
    _toggleWithStableReadingPosition('current:$progressKey', () {
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
