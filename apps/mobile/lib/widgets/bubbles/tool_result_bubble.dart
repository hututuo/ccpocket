import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/generated_image_preview/generated_image_preview_mapper.dart';
import '../../features/generated_image_preview/widgets/generated_image_chat_group.dart';
import '../../l10n/app_localizations.dart';
import '../../models/messages.dart';
import 'package:auto_route/auto_route.dart';

import '../../router/app_router.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_theme.dart';
import '../../utils/tool_categories.dart';
import '../../utils/text_line_preview.dart';
import '../../utils/artifact_link_matcher.dart';
import '../../features/file_peek/file_path_syntax.dart';
import '../chat_selection_actions.dart';
import 'artifact_attachment_chip.dart';
import 'image_preview.dart';

/// Three-level expansion state for tool result content.
enum ToolResultExpansion { collapsed, preview, expanded }

const _imageGenerationToolName = 'ImageGeneration';

class ToolResultBubble extends StatefulWidget {
  final ToolResultMessage message;
  final String? httpBaseUrl;
  final String? sessionId;
  final String? projectPath;
  final FilePathTapCallback? onFileTap;
  final ArtifactOpenCallback? onArtifactOpen;

  /// When this notifier's value changes, the bubble auto-collapses.
  ///
  /// Session surfaces also use this for the global "collapse all" command and
  /// whenever the route is deactivated.
  final ValueNotifier<int>? collapseNotifier;

  const ToolResultBubble({
    super.key,
    required this.message,
    this.httpBaseUrl,
    this.sessionId,
    this.projectPath,
    this.onFileTap,
    this.onArtifactOpen,
    this.collapseNotifier,
  });

  @override
  State<ToolResultBubble> createState() => ToolResultBubbleState();
}

class ToolResultBubbleState extends State<ToolResultBubble> {
  ToolResultExpansion _expansion = ToolResultExpansion.collapsed;
  String? _summaryContent;
  _ToolResultSummary? _summaryCache;

  static const _previewLines = 5;

  @override
  void initState() {
    super.initState();
    widget.collapseNotifier?.addListener(_onCollapseSignal);
  }

  @override
  void didUpdateWidget(ToolResultBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapseNotifier != widget.collapseNotifier) {
      oldWidget.collapseNotifier?.removeListener(_onCollapseSignal);
      widget.collapseNotifier?.addListener(_onCollapseSignal);
    }
    if (oldWidget.message.toolUseId != widget.message.toolUseId ||
        oldWidget.message.content != widget.message.content ||
        oldWidget.message.toolName != widget.message.toolName) {
      _expansion = ToolResultExpansion.collapsed;
      _summaryContent = null;
      _summaryCache = null;
    }
  }

  @override
  void dispose() {
    widget.collapseNotifier?.removeListener(_onCollapseSignal);
    super.dispose();
  }

  void _onCollapseSignal() {
    if (_expansion != ToolResultExpansion.collapsed) {
      setState(() => _expansion = ToolResultExpansion.collapsed);
    }
  }

  void _toggleDisclosure() {
    setState(() {
      _expansion = _expansion == ToolResultExpansion.collapsed
          ? ToolResultExpansion.preview
          : ToolResultExpansion.collapsed;
    });
    HapticFeedback.selectionClick();
  }

  void _showMore() {
    if (_expansion != ToolResultExpansion.preview) return;
    setState(() => _expansion = ToolResultExpansion.expanded);
    HapticFeedback.selectionClick();
  }

  void _showLess() {
    if (_expansion != ToolResultExpansion.expanded) return;
    setState(() => _expansion = ToolResultExpansion.preview);
    HapticFeedback.selectionClick();
  }

  bool get _isImageGenerationResult =>
      widget.message.toolName == _imageGenerationToolName;

  bool get _hasRenderableImage => widget.message.images.any(
    (image) =>
        canResolveGeneratedImageUrl(image.url, httpBaseUrl: widget.httpBaseUrl),
  );

  ToolCategory get _category =>
      categorizeToolName(widget.message.toolName ?? '');

  _ToolResultSummary get _summary {
    final content = widget.message.content;
    if (_summaryContent != content || _summaryCache == null) {
      _summaryContent = content;
      _summaryCache = _scanToolResultSummary(content);
    }
    return _summaryCache!;
  }

  String _summaryText(AppLocalizations l) {
    if (!_isFileChangeTool(widget.message.toolName)) return '';
    final summary = _summary;
    final counts = l.diffSummaryAddedRemoved(summary.added, summary.removed);
    return summary.fileName == null ? counts : '${summary.fileName} · $counts';
  }

  /// Whether this tool result contains a viewable diff.
  bool get _isDiffContent {
    final toolName = widget.message.toolName;
    if (toolName != 'Edit' &&
        toolName != 'FileEdit' &&
        toolName != 'FileChange') {
      return false;
    }
    final content = widget.message.content;
    // Check for unified diff markers
    return content.contains('---') && content.contains('+++') ||
        _hasDiffLines(content);
  }

  static bool _hasDiffLines(String content) {
    final lines = content.split('\n');
    for (final line in lines) {
      if ((line.startsWith('+') && !line.startsWith('+++')) ||
          (line.startsWith('-') && !line.startsWith('---'))) {
        return true;
      }
    }
    return false;
  }

  String? _extractFilePath() {
    final content = widget.message.content;
    final match = RegExp(r'\+\+\+ b/(.+)').firstMatch(content);
    return match?.group(1);
  }

  void _openGitScreen() {
    context.router.push(
      GitRoute(
        initialDiff: widget.message.content,
        title: _summary.filePath ?? _extractFilePath(),
      ),
    );
  }

  void _copyContent(BuildContext context) {
    final content = widget.message.content;
    if (content.isEmpty) return;
    Clipboard.setData(ClipboardData(text: content));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).copiedToClipboard),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  bool _canOpenArtifact(ArtifactRef artifact) {
    if (artifact.isSource) {
      return widget.onFileTap != null &&
          widget.onArtifactOpen != null &&
          isSafeProjectRelativePath(artifact.projectRelativePath);
    }
    return artifact.isPreview && widget.onArtifactOpen != null;
  }

  Future<void> _openArtifact(ArtifactRef artifact) async {
    if (artifact.isSource) {
      final path = artifact.projectRelativePath;
      if (widget.onFileTap != null &&
          widget.onArtifactOpen != null &&
          isSafeProjectRelativePath(path)) {
        await widget.onArtifactOpen!(artifact);
      }
      return;
    }
    if (artifact.isPreview) await widget.onArtifactOpen?.call(artifact);
  }

  @override
  Widget build(BuildContext context) {
    late final Widget result;
    final l = AppLocalizations.of(context);
    final summary = _summaryText(l);
    if (_expansion != ToolResultExpansion.collapsed &&
        _isImageGenerationResult &&
        _hasRenderableImage) {
      result = _ImageGenerationResultCard(
        message: widget.message,
        httpBaseUrl: widget.httpBaseUrl,
        onLongPress: () => _copyContent(context),
        onCollapse: _toggleDisclosure,
      );
    } else {
      if (_expansion == ToolResultExpansion.collapsed) {
        result = _CollapsedToolResult(
          toolName: widget.message.toolName == null
              ? null
              : getToolDisplayName(
                  widget.message.toolName!,
                  zh: Localizations.localeOf(context).languageCode == 'zh',
                  phase: ToolDisplayPhase.result,
                ),
          category: _category,
          summary: summary,
          onTap: _toggleDisclosure,
          onLongPress: () => _copyContent(context),
        );
      } else {
        result = _ExpandedToolResult(
          message: widget.message,
          httpBaseUrl: widget.httpBaseUrl,
          category: _category,
          summary: summary,
          expansion: _expansion,
          onToggle: _toggleDisclosure,
          onShowMore: _showMore,
          onShowLess: _showLess,
          onLongPress: () => _copyContent(context),
          onOpenGitScreen: _isDiffContent ? _openGitScreen : null,
        );
      }
    }

    if (widget.message.artifacts.isEmpty ||
        _expansion == ToolResultExpansion.collapsed) {
      return result;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        result,
        ArtifactAttachmentGroup(
          artifacts: widget.message.artifacts,
          onOpen: _openArtifact,
          canOpen: _canOpenArtifact,
        ),
      ],
    );
  }
}

class _ImageGenerationResultCard extends StatelessWidget {
  final ToolResultMessage message;
  final String? httpBaseUrl;
  final VoidCallback onLongPress;
  final VoidCallback onCollapse;

  const _ImageGenerationResultCard({
    required this.message,
    required this.httpBaseUrl,
    required this.onLongPress,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final colorScheme = Theme.of(context).colorScheme;
    final items = generatedImageItemsFromToolResults([
      message,
    ], httpBaseUrl: httpBaseUrl);

    return Container(
      key: const ValueKey('image_generation_result_card'),
      margin: const EdgeInsets.symmetric(
        vertical: 4,
        horizontal: AppSpacing.bubbleMarginH,
      ),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: appColors.toolResultBackground,
            borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
            border: Border.all(
              color: colorScheme.secondary.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                key: const ValueKey('image_generation_disclosure'),
                onTap: onCollapse,
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 15,
                      color: colorScheme.secondary,
                    ),
                    const SizedBox(width: 7),
                    const Expanded(
                      child: Text(
                        'Generated image',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.expand_less,
                      size: 16,
                      color: appColors.subtleText,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              GeneratedImageChatGroup(items: items),
            ],
          ),
        ),
      ),
    );
  }
}

/// Collapsed: inline log row -- no card background.
class _CollapsedToolResult extends StatelessWidget {
  final String? toolName;
  final ToolCategory category;
  final String summary;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _CollapsedToolResult({
    required this.toolName,
    required this.category,
    required this.summary,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final l = AppLocalizations.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.bubbleMarginH,
        vertical: 1,
      ),
      child: InkWell(
        key: const ValueKey('tool_result_disclosure'),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              // Category icon
              Icon(
                getToolCategoryIcon(category),
                size: 12,
                color: getToolCategoryColor(category, appColors),
              ),
              const SizedBox(width: 6),
              // Tool name
              Text(
                toolName ?? l.toolResult,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              // Summary -- plain text, no badge
              Expanded(
                child: Text(
                  summary,
                  style: TextStyle(fontSize: 11, color: appColors.subtleText),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Chevron
              Icon(Icons.chevron_right, size: 14, color: appColors.subtleText),
            ],
          ),
        ),
      ),
    );
  }
}

/// Preview / Expanded: card with background + content.
class _ExpandedToolResult extends StatelessWidget {
  final ToolResultMessage message;
  final String? httpBaseUrl;
  final ToolCategory category;
  final String summary;
  final ToolResultExpansion expansion;
  final VoidCallback onToggle;
  final VoidCallback onShowMore;
  final VoidCallback onShowLess;
  final VoidCallback onLongPress;
  final VoidCallback? onOpenGitScreen;

  static const _previewLines = ToolResultBubbleState._previewLines;

  const _ExpandedToolResult({
    required this.message,
    required this.httpBaseUrl,
    required this.category,
    required this.summary,
    required this.expansion,
    required this.onToggle,
    required this.onShowMore,
    required this.onShowLess,
    required this.onLongPress,
    this.onOpenGitScreen,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final l = AppLocalizations.of(context);
    final content = message.content;
    final toolName = message.toolName == null
        ? null
        : getToolDisplayName(
            message.toolName!,
            zh: Localizations.localeOf(context).languageCode == 'zh',
            phase: ToolDisplayPhase.result,
          );
    final preview = buildTextLinePreview(content, maxLines: _previewLines);
    final hasMore = preview.hasMore;
    final previewText = preview.text;

    return Container(
      margin: const EdgeInsets.symmetric(
        vertical: 2,
        horizontal: AppSpacing.bubbleMarginH,
      ),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: appColors.toolResultBackground,
          borderRadius: BorderRadius.circular(AppSpacing.codeRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              key: const ValueKey('tool_result_disclosure'),
              onTap: onToggle,
              onLongPress: onLongPress,
              borderRadius: BorderRadius.circular(AppSpacing.codeRadius),
              child: Row(
                children: [
                  Icon(
                    getToolCategoryIcon(category),
                    size: 14,
                    color: getToolCategoryColor(category, appColors),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    toolName ?? l.toolResult,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      summary,
                      style: TextStyle(
                        fontSize: 11,
                        color: appColors.subtleText,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.expand_less,
                    size: 16,
                    color: appColors.subtleText,
                  ),
                ],
              ),
            ),
            if (message.images.isNotEmpty && httpBaseUrl != null) ...[
              const SizedBox(height: 8),
              ImagePreviewWidget(
                images: message.images,
                httpBaseUrl: httpBaseUrl!,
              ),
            ],
            const SizedBox(height: 6),
            if (expansion == ToolResultExpansion.preview) ...[
              Text(
                previewText,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: appColors.toolResultText,
                  height: 1.4,
                ),
                maxLines: _previewLines,
                overflow: TextOverflow.ellipsis,
              ),
              if (hasMore)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('tool_result_show_more'),
                    onPressed: onShowMore,
                    child: Text(l.showMore),
                  ),
                ),
            ] else ...[
              SelectableText(
                content,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: appColors.toolResultTextExpanded,
                  height: 1.4,
                ),
                contextMenuBuilder: chatSelectableTextContextMenuBuilder,
              ),
              if (hasMore)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('tool_result_show_less'),
                    onPressed: onShowLess,
                    child: Text(l.showLess),
                  ),
                ),
            ],
            if (onOpenGitScreen != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('tool_result_open_full_diff'),
                  onPressed: onOpenGitScreen,
                  icon: const Icon(Icons.difference_outlined, size: 16),
                  label: Text(
                    Localizations.localeOf(context).languageCode == 'zh'
                        ? '查看完整差异'
                        : 'View full diff',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToolResultSummary {
  const _ToolResultSummary({this.filePath, this.added = 0, this.removed = 0});

  final String? filePath;
  final int added;
  final int removed;

  String? get fileName {
    final path = filePath;
    if (path == null || path.isEmpty) return null;
    final normalized = path.replaceAll(r'\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }
}

_ToolResultSummary _scanToolResultSummary(String content) {
  var added = 0;
  var removed = 0;
  String? filePath;
  var lineStart = 0;

  void inspectLine(int lineEnd) {
    final line = content.substring(lineStart, lineEnd);
    if (line.startsWith('+++ b/')) {
      filePath ??= line.substring(6).trim();
    } else if (line.startsWith('diff --git ')) {
      final marker = line.lastIndexOf(' b/');
      if (marker >= 0) filePath ??= line.substring(marker + 3).trim();
    } else if (line.startsWith('+') && !line.startsWith('+++')) {
      added++;
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      removed++;
    }
  }

  for (var index = 0; index < content.length; index++) {
    if (content.codeUnitAt(index) != 10) continue;
    inspectLine(index);
    lineStart = index + 1;
  }
  if (lineStart <= content.length) inspectLine(content.length);
  return _ToolResultSummary(filePath: filePath, added: added, removed: removed);
}

bool _isFileChangeTool(String? toolName) =>
    toolName == 'Edit' ||
    toolName == 'FileEdit' ||
    toolName == 'MultiEdit' ||
    toolName == 'Write' ||
    toolName == 'NotebookEdit' ||
    toolName == 'FileChange';
