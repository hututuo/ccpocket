import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../../providers/bridge_cubits.dart';
import '../../../services/bridge_service.dart';
import '../../../services/performance_probe_extension.dart';
import '../../../utils/artifact_link_matcher.dart';
import '../../../widgets/bubbles/assistant_bubble.dart';
import '../../../widgets/bubbles/guardian_approval_notice.dart';
import '../../../widgets/bubbles/todo_write_widget.dart';
import '../../../widgets/bubbles/tool_result_bubble.dart';
import '../../../widgets/chat_selection_actions.dart';
import '../../../widgets/chat_message_timestamp.dart';
import '../../../widgets/message_bubble.dart';
import '../../artifact_preview/artifact_preview_entry.dart';
import '../../generated_image_preview/generated_image_preview_mapper.dart';
import '../../generated_image_preview/generated_image_preview_item.dart';
import '../../generated_image_preview/generated_image_response_grouping.dart';
import '../../generated_image_preview/widgets/generated_image_chat_group.dart';
import '../../file_peek/file_peek_sheet.dart';
import '../../message_images/message_images_screen.dart';
import '../state/chat_session_cubit.dart';
import '../state/chat_session_state.dart';
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
bool shouldPreferUnifiedArtifactPreview(
  ArtifactRef artifact, [
  TargetPlatform? platform,
]) =>
    artifact.isSource &&
    artifact.line == null &&
    supportsEmbeddedArtifactPreview(platform);

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

String chatMessageEntryStableKey(ChatEntry entry) {
  return switch (entry) {
    ServerChatEntry(:final message) => switch (message) {
      ToolResultMessage() =>
        'tool:${chatToolResultEntryStableIdentity(message, entry.timestamp)}',
      AssistantServerMessage() =>
        'assistant:${chatAssistantEntryStableIdentity(message, entry.timestamp)}',
      PermissionRequestMessage(:final toolUseId) => 'permission:$toolUseId',
      ToolUseSummaryMessage(:final precedingToolUseIds) =>
        precedingToolUseIds.isNotEmpty
            ? 'tool_summary:${precedingToolUseIds.first}'
            : 'tool_summary:${entry.timestamp.microsecondsSinceEpoch}',
      _ => '${message.runtimeType}:${entry.timestamp.microsecondsSinceEpoch}',
    },
    UserChatEntry() => 'user:${chatUserEntryStableIdentity(entry)}',
    StreamingChatEntry() => 'streaming',
  };
}

@visibleForTesting
bool shouldLoadOlderLocalHistory(
  ScrollMetrics metrics, {
  double threshold = 480,
}) =>
    metrics.maxScrollExtent > 0 &&
    metrics.pixels >= metrics.maxScrollExtent - threshold;

@visibleForTesting
Set<int> forkableAssistantEntryIndices(
  List<ChatEntry> entries, {
  bool transcriptTailComplete = false,
}) {
  final result = <int>{};
  int? candidate;
  var candidateHasTerminalResult = false;

  void finishCandidate({required bool followedByUser}) {
    if (candidate != null &&
        (followedByUser ||
            candidateHasTerminalResult ||
            transcriptTailComplete)) {
      result.add(candidate!);
    }
    candidate = null;
    candidateHasTerminalResult = false;
  }

  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    if (entry is UserChatEntry) {
      finishCandidate(followedByUser: true);
      continue;
    }
    if (entry is! ServerChatEntry) continue;
    switch (entry.message) {
      case AssistantServerMessage(:final message):
        final hasVisibleReply = message.content.any(
          (content) => content is TextContent && content.text.trim().isNotEmpty,
        );
        if (hasVisibleReply) {
          candidate = index;
          candidateHasTerminalResult = false;
        }
        break;
      case ResultMessage():
        if (candidate != null) candidateHasTerminalResult = true;
        break;
      default:
        break;
    }
  }
  finishCandidate(followedByUser: false);
  return result;
}

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
  List<ChatEntry>? _processLayoutEntries;
  bool? _processLayoutLatestTurnIsActive;
  bool? _processLayoutHasTransientCurrentOutput;
  ChatProcessLayout? _cachedProcessLayout;
  final Set<String> _expandedProcessSegments = {};
  final Set<String> _expandedIntermediateTurns = {};
  final Set<String> _expandedCurrentProgress = {};
  final Map<String, GlobalKey> _disclosureAnchorKeys = {};
  final _generatedImageItemCache =
      <GeneratedImageItemCacheKey, GeneratedImagePreviewItem>{};
  ChatSessionState? _derivedForState;
  List<ChatEntry>? _derivedEntries;
  String? _derivedForHttpBaseUrl;
  bool? _derivedForTranscriptTailComplete;
  _ChatListDerivedData? _derivedData;

  @override
  void initState() {
    super.initState();
    widget.scrollToUserEntry?.addListener(_onScrollToUserEntry);
    widget.collapseToolResults?.addListener(_onCollapseSignal);
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
    if (oldWidget.collapseToolResults != widget.collapseToolResults) {
      oldWidget.collapseToolResults?.removeListener(_onCollapseSignal);
      widget.collapseToolResults?.addListener(_onCollapseSignal);
      _collapseAllState();
    }
  }

  @override
  void dispose() {
    widget.scrollToUserEntry?.removeListener(_onScrollToUserEntry);
    widget.collapseToolResults?.removeListener(_onCollapseSignal);
    _pagingCubit?.localHistoryPaging.removeListener(_onPagingChanged);
    super.dispose();
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
    _migratePartialTurnDisclosureState(layout.turnKeyAliases);
    _processLayoutEntries = entries;
    _processLayoutLatestTurnIsActive = latestTurnIsActive;
    _processLayoutHasTransientCurrentOutput = hasTransientCurrentOutput;
    _cachedProcessLayout = layout;
    return layout;
  }

  void _migratePartialTurnDisclosureState(Map<String, String> turnKeyAliases) {
    for (final alias in turnKeyAliases.entries) {
      final partialKey = alias.key;
      final canonicalKey = alias.value;
      if (_expandedIntermediateTurns.remove(partialKey)) {
        _expandedIntermediateTurns.add(canonicalKey);
      }

      final partialProgressKey = _currentProgressKey(partialKey);
      if (_expandedCurrentProgress.remove(partialProgressKey)) {
        _expandedCurrentProgress.add(_currentProgressKey(canonicalKey));
      }

      final segmentPrefix = '$partialKey:segment:';
      final migratedSegments = <String>[];
      for (final segmentKey in _expandedProcessSegments) {
        if (!segmentKey.startsWith(segmentPrefix)) continue;
        migratedSegments.add(
          '$canonicalKey:segment:${segmentKey.substring(segmentPrefix.length)}',
        );
      }
      if (migratedSegments.isEmpty) continue;
      _expandedProcessSegments.removeWhere(
        (segmentKey) => segmentKey.startsWith(segmentPrefix),
      );
      _expandedProcessSegments.addAll(migratedSegments);
    }
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
      if (shouldPreferUnifiedArtifactPreview(artifact)) {
        try {
          await _openResolvedArtifactPreview(
            bridge: bridge,
            requestSessionId: requestSessionId,
            requestProjectPath: requestProjectPath,
            messageId: messageId,
            artifact: artifact,
          );
          return;
        } on ArtifactResolveException catch (error) {
          // Source refs predate the unified preview route on some Bridges.
          // Preserve their exact File Peek path instead of turning an
          // additive preview improvement into a compatibility break.
          if (error.code != 'artifact_resolve_unsupported') {
            if (mounted && widget.sessionId == requestSessionId) {
              _showArtifactError(_artifactErrorMessage(error.code));
            }
            return;
          }
        } catch (_) {
          if (mounted && widget.sessionId == requestSessionId) {
            _showArtifactError(AppLocalizations.of(context).artifactOpenFailed);
          }
          return;
        }
      }
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
          onOpenPreviewRequested: supportsEmbeddedArtifactPreview()
              ? () async {
                  try {
                    await _openResolvedArtifactPreview(
                      bridge: bridge,
                      requestSessionId: requestSessionId,
                      requestProjectPath: requestProjectPath,
                      messageId: messageId,
                      artifact: artifact,
                    );
                  } on ArtifactResolveException catch (error) {
                    if (mounted && widget.sessionId == requestSessionId) {
                      _showArtifactError(_artifactErrorMessage(error.code));
                    }
                  } catch (_) {
                    if (mounted && widget.sessionId == requestSessionId) {
                      _showArtifactError(
                        AppLocalizations.of(context).artifactOpenFailed,
                      );
                    }
                  }
                }
              : null,
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
      await _openResolvedArtifactPreview(
        bridge: bridge,
        requestSessionId: requestSessionId,
        requestProjectPath: requestProjectPath,
        messageId: messageId,
        artifact: artifact,
      );
    } on ArtifactResolveException catch (error) {
      if (!mounted || widget.sessionId != requestSessionId) return;
      _showArtifactError(_artifactErrorMessage(error.code));
    } catch (_) {
      if (mounted && widget.sessionId == requestSessionId) {
        _showArtifactError(AppLocalizations.of(context).artifactOpenFailed);
      }
    }
  }

  Future<void> _openResolvedArtifactPreview({
    required BridgeService bridge,
    required String requestSessionId,
    required String? requestProjectPath,
    required String messageId,
    required ArtifactRef artifact,
  }) async {
    final resolved = await bridge.resolveArtifact(
      sessionId: requestSessionId,
      messageId: messageId,
      artifactId: artifact.id,
    );
    if (!mounted || widget.sessionId != requestSessionId) return;
    if (widget.projectPath != requestProjectPath) {
      throw const ArtifactResolveException(
        code: 'bridge_changed',
        message: 'The active project changed while preparing the file.',
      );
    }
    if (supportsEmbeddedArtifactPreview()) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ArtifactPreviewScreen(
            previewUrl: resolved.url,
            filename: artifact.filename,
            mimeType: artifact.mimeType,
            sizeBytes: artifact.sizeBytes,
            expiresAt: resolved.expiresAt,
            accessRefresher: () async {
              final refreshed = await bridge.resolveArtifact(
                sessionId: requestSessionId,
                messageId: messageId,
                artifactId: artifact.id,
              );
              return ArtifactPreviewAccess(
                previewUrl: refreshed.url,
                expiresAt: refreshed.expiresAt,
              );
            },
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
      throw const ArtifactResolveException(
        code: 'artifact_open_failed',
        message: 'The artifact preview could not be opened.',
      );
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
    return _derivedData?.latestPlanText ?? _findPlanFromWriteTool();
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
            (_derivedData?.forkableAssistantEntryIndices.contains(entryIndex) ??
                shouldShowForkForAssistant(
                  entries,
                  entryIndex,
                  transcriptTailComplete: transcriptTailComplete,
                ))
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
        historyToolDetailGapBuilder: (gap) => _HistoryToolDetailGapView(
          key: ValueKey('history_tool_detail_view_${gap.gapId}'),
          cubit: context.read<ChatSessionCubit>(),
          gap: gap,
          httpBaseUrl: widget.httpBaseUrl,
          sessionId: widget.sessionId,
          projectPath: widget.projectPath,
          collapseNotifier: widget.collapseToolResults,
          onFilePeekOpened: widget.onFilePeekOpened,
          onArtifactOpen: _openArtifact,
        ),
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
    Set<int> excludedProcessEntryIndices = const {},
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
      if (excludedProcessEntryIndices.contains(processIndex)) continue;
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
            timestamp: _timestampForEntryIndex(entries, segment.lastEntryIndex),
          ),
        ),
      );
      if (expanded) {
        children.add(
          _ProcessDetailsViewport(
            key: ValueKey('process_details_viewport_${segment.key}'),
            expanded: true,
            children: _buildProcessSegmentDetails(
              segment: segment,
              entries: entries,
              hiddenToolUseIds: hiddenToolUseIds,
              transcriptTailComplete: transcriptTailComplete,
              imageItemsByAnchor: imageItemsByAnchor,
              imageGroupMemberIndices: imageGroupMemberIndices,
            ),
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
    if (currentTool != null || expanded) {
      children.add(
        _ProcessDetailsViewport(
          key: ValueKey('process_details_viewport_current_$progressKey'),
          expanded: expanded,
          transientGuardianReview: currentTool?.guardianReview,
          children: [
            if (currentTool != null)
              ChatCurrentToolActivityLine(
                activity: currentTool,
                expanded: expanded,
                onTap: () => _toggleCurrentProgress(progressKey),
                timestamp: _timestampForEntryIndex(
                  entries,
                  currentTool.entryIndex,
                ),
              ),
            if (expanded)
              ..._buildProcessSegmentDetails(
                segment: segment,
                entries: entries,
                hiddenToolUseIds: hiddenToolUseIds,
                transcriptTailComplete: transcriptTailComplete,
                imageItemsByAnchor: imageItemsByAnchor,
                imageGroupMemberIndices: imageGroupMemberIndices,
                excludedProcessEntryIndices:
                    segment.attachedGuardianEntryIndices,
              ),
          ],
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
    chatListPerformanceProbe.recordBuild();
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
    final transcriptTailComplete =
        chatState.status == ProcessStatus.idle &&
        chatState.queuedInput == null &&
        !hasStreaming;
    final derivedData = _deriveData(
      chatState,
      allEntries,
      transcriptTailComplete: transcriptTailComplete,
    );
    final imageItemsByAnchor = derivedData.imageItemsByAnchor;
    final imageGroupMemberIndices = derivedData.imageGroupMemberIndices;
    final effectiveHiddenToolUseIds = {
      ...hiddenToolUseIds,
      ...derivedData.completedGeneratedImageToolUseIds,
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
            final progressKey = _currentProgressKey(turnKey);
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
                        if (currentTool != null || expanded)
                          _ProcessDetailsViewport(
                            key: ValueKey(
                              'live_process_details_viewport_$progressKey',
                            ),
                            expanded: expanded,
                            transientGuardianReview:
                                currentTool?.guardianReview,
                            children: [
                              if (currentTool != null)
                                ChatCurrentToolActivityLine(
                                  activity: currentTool,
                                  expanded: expanded,
                                  onTap: () =>
                                      _toggleCurrentProgress(progressKey),
                                  timestamp: _timestampForEntryIndex(
                                    allEntries,
                                    currentTool.entryIndex,
                                  ),
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
                                    return ChatLiveThinkingDetails(
                                      text: thinking,
                                    );
                                  },
                                ),
                            ],
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
                    timestamp: _timestampForEntryIndex(
                      allEntries,
                      intermediateTurn.intermediateSegments.isNotEmpty
                          ? intermediateTurn
                                .intermediateSegments
                                .last
                                .lastEntryIndex
                          : intermediateTurn.intermediateSummaryEntryIndex,
                    ),
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
            final progressKey = _currentProgressKey(intermediateTurn!.key);
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
                ? _entryKey(entry)
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
            key: _entryKey(entry),
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

  _ChatListDerivedData _deriveData(
    ChatSessionState chatState,
    List<ChatEntry> entries, {
    required bool transcriptTailComplete,
  }) {
    final cached = _derivedData;
    if (_derivedForHttpBaseUrl == widget.httpBaseUrl &&
        _derivedForTranscriptTailComplete == transcriptTailComplete &&
        cached != null) {
      if (identical(_derivedForState, chatState)) return cached;
      final previousEntries = _derivedEntries;
      if (previousEntries != null && listEquals(previousEntries, entries)) {
        _derivedForState = chatState;
        return cached;
      }
    }

    final stopwatch = kDebugMode ? (Stopwatch()..start()) : null;
    final imageGroupMemberIndices = <int>{};
    final imageItemsByAnchor = <int, List<GeneratedImagePreviewItem>>{};
    for (final group in groupGeneratedImageResponses(entries)) {
      final items = generatedImageItemsFromToolResults(
        group.messages,
        httpBaseUrl: widget.httpBaseUrl,
        itemCache: _generatedImageItemCache,
      );
      if (items.isEmpty) continue;
      imageItemsByAnchor[group.anchorEntryIndex] = items;
      imageGroupMemberIndices.addAll(group.memberEntryIndices);
    }
    final next = _ChatListDerivedData(
      imageGroupMemberIndices: imageGroupMemberIndices,
      imageItemsByAnchor: imageItemsByAnchor,
      completedGeneratedImageToolUseIds: completedGeneratedImageToolUseIds(
        entries,
      ),
      forkableAssistantEntryIndices: forkableAssistantEntryIndices(
        entries,
        transcriptTailComplete: transcriptTailComplete,
      ),
      latestPlanText: _findPlanFromWriteTool(),
    );
    _derivedForState = chatState;
    _derivedEntries = entries;
    _derivedForHttpBaseUrl = widget.httpBaseUrl;
    _derivedForTranscriptTailComplete = transcriptTailComplete;
    _derivedData = next;
    stopwatch?.stop();
    if (stopwatch != null) {
      chatListPerformanceProbe.recordDerivedData(stopwatch.elapsed);
    }
    return next;
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

  String _entryKey(ChatEntry entry) {
    return chatMessageEntryStableKey(entry);
  }
}

class _ChatListDerivedData {
  final Set<int> imageGroupMemberIndices;
  final Map<int, List<GeneratedImagePreviewItem>> imageItemsByAnchor;
  final Set<String> completedGeneratedImageToolUseIds;
  final Set<int> forkableAssistantEntryIndices;
  final String? latestPlanText;

  const _ChatListDerivedData({
    required this.imageGroupMemberIndices,
    required this.imageItemsByAnchor,
    required this.completedGeneratedImageToolUseIds,
    required this.forkableAssistantEntryIndices,
    required this.latestPlanText,
  });
}

String _currentProgressKey(String turnKey) => 'turn:$turnKey';

ChatMessageTimestampData? _timestampForEntryIndex(
  List<ChatEntry> entries,
  int? entryIndex,
) {
  if (entryIndex == null || entryIndex < 0 || entryIndex >= entries.length) {
    return null;
  }
  return ChatMessageTimestampData.fromEntry(entries[entryIndex]);
}

class _ProcessDetailsViewport extends StatefulWidget {
  const _ProcessDetailsViewport({
    super.key,
    required this.expanded,
    required this.children,
    this.transientGuardianReview,
  });

  final bool expanded;
  final List<Widget> children;
  final GuardianApprovalMessage? transientGuardianReview;

  @override
  State<_ProcessDetailsViewport> createState() =>
      _ProcessDetailsViewportState();
}

class _ProcessDetailsViewportState extends State<_ProcessDetailsViewport> {
  static const _maximumVisibleRows = 8;
  static const _compactRowExtent = 44.0;
  static const _guardianVisibility = Duration(seconds: 3);
  final ScrollController _controller = ScrollController();
  Timer? _guardianTimer;
  String? _guardianIdentity;
  bool _showGuardian = false;

  @override
  void initState() {
    super.initState();
    _syncGuardianReview();
  }

  @override
  void didUpdateWidget(covariant _ProcessDetailsViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncGuardianReview();
  }

  @override
  void dispose() {
    _guardianTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _syncGuardianReview() {
    final review = widget.transientGuardianReview;
    final identity = review == null ? null : chatGuardianReviewIdentity(review);
    if (identity == _guardianIdentity) return;
    _guardianTimer?.cancel();
    _guardianIdentity = identity;
    _showGuardian = review != null;
    if (review == null) return;
    _guardianTimer = Timer(_guardianVisibility, () {
      if (!mounted || _guardianIdentity != identity) return;
      setState(() => _showGuardian = false);
    });
  }

  List<Widget> get _visibleChildren {
    final review = widget.transientGuardianReview;
    return [
      ...widget.children,
      if (_showGuardian && review != null)
        KeyedSubtree(
          key: ValueKey(
            'chat_current_guardian_${chatGuardianReviewIdentity(review)}',
          ),
          child: GuardianApprovalNotice(message: review),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.expanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _visibleChildren,
      );
    }
    final media = MediaQuery.of(context);
    final textScale = media.textScaler.scale(1).clamp(1.0, 1.6).toDouble();
    final eightRowHeight = _compactRowExtent * _maximumVisibleRows * textScale;
    final screenHeightCap = media.size.height * 0.55;
    final maximumHeight = eightRowHeight < screenHeightCap
        ? eightRowHeight
        : screenHeightCap;

    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 2, 0, 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.8),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maximumHeight),
            child: NotificationListener<ScrollNotification>(
              // This nested viewport owns its vertical gesture. Do not let its
              // metrics trigger the transcript's older-history pagination.
              onNotification: (_) => true,
              child: Scrollbar(
                controller: _controller,
                child: SingleChildScrollView(
                  key: const ValueKey('process_details_scroll_view'),
                  controller: _controller,
                  primary: false,
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _visibleChildren,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryToolDetailGapView extends StatefulWidget {
  const _HistoryToolDetailGapView({
    super.key,
    required this.cubit,
    required this.gap,
    required this.sessionId,
    required this.onArtifactOpen,
    this.httpBaseUrl,
    this.projectPath,
    this.collapseNotifier,
    this.onFilePeekOpened,
  });

  final ChatSessionCubit cubit;
  final HistoryToolDetailGap gap;
  final String sessionId;
  final String? httpBaseUrl;
  final String? projectPath;
  final ValueNotifier<int>? collapseNotifier;
  final ValueChanged<String>? onFilePeekOpened;
  final Future<void> Function(String messageId, ArtifactRef artifact)
  onArtifactOpen;

  @override
  State<_HistoryToolDetailGapView> createState() =>
      _HistoryToolDetailGapViewState();
}

class _HistoryToolDetailGapViewState extends State<_HistoryToolDetailGapView> {
  @override
  void initState() {
    super.initState();
    _scheduleInitialPage();
  }

  @override
  void didUpdateWidget(_HistoryToolDetailGapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gap.gapId != widget.gap.gapId) {
      _scheduleInitialPage();
    }
  }

  void _scheduleInitialPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.cubit.isClosed) return;
      final state = widget.cubit.historyToolDetailState(widget.gap.gapId);
      if (state.details.isEmpty &&
          !state.loading &&
          !state.complete &&
          state.error == null) {
        unawaited(widget.cubit.loadHistoryToolDetailGap(widget.gap));
      }
    });
  }

  void _openFile(String filePath) {
    final projectPath = widget.projectPath;
    if (projectPath == null || projectPath.isEmpty) return;
    openFilePeek(
      context,
      bridge: context.read<BridgeService>(),
      projectPath: projectPath,
      filePath: filePath,
      projectFiles: context.read<FileListCubit>().state,
      onResolvedFilePath: widget.onFilePeekOpened,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.cubit.historyToolDetailRevision,
      builder: (context, _, _) {
        final loadState = widget.cubit.historyToolDetailState(widget.gap.gapId);
        return Column(
          key: ValueKey('history_tool_detail_gap_content_${widget.gap.gapId}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final detail in loadState.details) ...[
              ToolUseTile(
                key: ValueKey(
                  'history_tool_use_${widget.gap.gapId}_${detail.toolUseId}',
                ),
                toolUseId: detail.toolUseId,
                name: detail.toolName,
                input: detail.input,
                collapseNotifier: widget.collapseNotifier,
              ),
              if (detail.result case final result?)
                ToolResultBubble(
                  key: ValueKey(
                    'history_tool_result_'
                    '${widget.gap.gapId}_${detail.toolUseId}',
                  ),
                  message: result,
                  httpBaseUrl: widget.httpBaseUrl,
                  sessionId: widget.sessionId,
                  projectPath: widget.projectPath,
                  onFileTap: widget.projectPath?.isNotEmpty == true
                      ? _openFile
                      : null,
                  onArtifactOpen: result.artifacts.isEmpty
                      ? null
                      : (artifact) =>
                            widget.onArtifactOpen(detail.toolUseId, artifact),
                  collapseNotifier: widget.collapseNotifier,
                ),
            ],
            _HistoryToolDetailLoadControl(
              gap: widget.gap,
              state: loadState,
              onLoad: () =>
                  unawaited(widget.cubit.loadHistoryToolDetailGap(widget.gap)),
            ),
          ],
        );
      },
    );
  }
}

class _HistoryToolDetailLoadControl extends StatelessWidget {
  const _HistoryToolDetailLoadControl({
    required this.gap,
    required this.state,
    required this.onLoad,
  });

  final HistoryToolDetailGap gap;
  final HistoryToolDetailLoadState state;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    if (state.complete) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final remaining = gap.toolUseIds.length - state.nextOffset;
    final nextCount = remaining > 8 ? 8 : remaining;
    final colors = Theme.of(context).colorScheme;
    if (state.loading) {
      return Padding(
        key: ValueKey('history_tool_detail_loading_${gap.gapId}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            ),
            const SizedBox(width: 9),
            Text(
              l.loadingOlderToolDetails,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (state.error != null) {
      return Padding(
        key: ValueKey('history_tool_detail_error_${gap.gapId}'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: TextButton.icon(
          onPressed: onLoad,
          icon: const Icon(Icons.refresh, size: 17),
          label: Text(l.loadToolDetailsFailed),
        ),
      );
    }
    return Padding(
      key: ValueKey('history_tool_detail_more_${gap.gapId}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: TextButton.icon(
        onPressed: nextCount > 0 ? onLoad : null,
        icon: const Icon(Icons.expand_more, size: 18),
        label: Text(l.loadNextToolDetails(nextCount)),
      ),
    );
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
