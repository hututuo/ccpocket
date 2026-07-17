import 'dart:convert';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/bridge_cubits.dart';
import '../../models/messages.dart';
import '../../router/app_router.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_theme.dart';
import '../../theme/markdown_style.dart';
import '../../utils/structured_error_inference.dart';
import '../../utils/diff_parser.dart';
import '../../utils/tool_categories.dart';
import '../../utils/codex_plan_update.dart';
import '../../utils/artifact_link_matcher.dart';
import '../../features/file_peek/file_path_syntax.dart';
import '../../features/file_peek/markdown_link_handler.dart';
import 'artifact_attachment_chip.dart';
import 'error_bubble.dart';
import '../plan_detail_sheet.dart';
import '../google_search_text_selection.dart';
import 'inline_edit_diff.dart';
import 'message_action_bar.dart';
import 'plan_card.dart';
import 'thinking_bubble.dart';
import 'todo_write_widget.dart';

const _imageGenerationToolName = 'ImageGeneration';

class AssistantBubble extends StatefulWidget {
  final AssistantServerMessage message;

  /// Pre-resolved plan text extracted from a Write tool in a *different*
  /// AssistantMessage.  When the real SDK writes the plan to a file via the
  /// Write tool, ExitPlanMode and Write are in separate messages, so the
  /// bubble's own [message.content] won't contain the plan text.
  final String? resolvedPlanText;

  /// Callback for tapping file paths in markdown content.
  final FilePathTapCallback? onFileTap;
  final ArtifactOpenCallback? onArtifactOpen;
  final String? sessionId;
  final String? projectPath;
  final VoidCallback? onFork;

  const AssistantBubble({
    super.key,
    required this.message,
    this.resolvedPlanText,
    this.onFileTap,
    this.onArtifactOpen,
    this.sessionId,
    this.projectPath,
    this.onFork,
  });

  @override
  State<AssistantBubble> createState() => _AssistantBubbleState();
}

class _AssistantBubbleState extends State<AssistantBubble> {
  bool _plainTextMode = false;

  String _allText() {
    return widget.message.message.content
        .whereType<TextContent>()
        .map((c) => c.text)
        .join('\n\n');
  }

  @override
  Widget build(BuildContext context) {
    final contents = widget.message.message.content;
    final hasTextContent = contents.any((c) => c is TextContent);
    final hasPlanExit = contents.any(
      (c) => c is ToolUseContent && c.name == 'ExitPlanMode',
    );
    final allText = _allText();
    // Only infer structured errors from short, text-only messages that are
    // likely actual error messages from the CLI — not long assistant prose
    // that happens to contain keywords like "oauth" or "credentials".
    final inferredErrorCode = allText.length <= 500
        ? inferStructuredErrorCode(message: allText)
        : null;
    final hasOnlyTextContent =
        contents.isNotEmpty && contents.every((c) => c is TextContent);

    if (hasOnlyTextContent && inferredErrorCode != null) {
      return ErrorBubble(
        message: ErrorMessage(
          message: _allText(),
          errorCode: inferredErrorCode,
        ),
      );
    }

    if (hasPlanExit) {
      return _PlanLayout(
        contents: contents,
        hasTextContent: hasTextContent,
        resolvedPlanText: widget.resolvedPlanText,
        allText: _allText(),
        plainTextMode: _plainTextMode,
        onFork: widget.onFork,
        artifacts: widget.message.artifacts,
        onArtifactOpen: widget.onArtifactOpen,
        onFileTap: widget.onFileTap,
        artifactContentIndexOffset: widget.message.artifactContentIndexOffset,
        onTogglePlainText: () {
          setState(() => _plainTextMode = !_plainTextMode);
        },
      );
    }

    return _DefaultLayout(
      contents: contents,
      hasTextContent: hasTextContent,
      plainTextMode: _plainTextMode,
      allText: _allText(),
      onFileTap: widget.onFileTap,
      artifacts: widget.message.artifacts,
      onArtifactOpen: widget.onArtifactOpen,
      artifactContentIndexOffset: widget.message.artifactContentIndexOffset,
      onFork: widget.onFork,
      onTogglePlainText: () {
        setState(() => _plainTextMode = !_plainTextMode);
      },
    );
  }
}

class _PlanLayout extends StatelessWidget {
  final List<AssistantContent> contents;
  final bool hasTextContent;
  final String? resolvedPlanText;
  final String allText;
  final bool plainTextMode;
  final VoidCallback? onFork;
  final List<ArtifactRef> artifacts;
  final ArtifactOpenCallback? onArtifactOpen;
  final FilePathTapCallback? onFileTap;
  final int artifactContentIndexOffset;
  final VoidCallback onTogglePlainText;

  const _PlanLayout({
    required this.contents,
    required this.hasTextContent,
    required this.resolvedPlanText,
    required this.allText,
    required this.plainTextMode,
    this.onFork,
    this.artifacts = const [],
    this.onArtifactOpen,
    this.onFileTap,
    this.artifactContentIndexOffset = 0,
    required this.onTogglePlainText,
  });

  @override
  Widget build(BuildContext context) {
    var originalPlanText = contents
        .whereType<TextContent>()
        .map((c) => c.text)
        .join('\n\n');

    // Real SDK: plan is written to a file via Write tool in a *different*
    // AssistantMessage.  Use resolvedPlanText (pre-extracted from all entries)
    // when TextContent doesn't look like an actual plan (< 10 lines).
    if (originalPlanText.split('\n').length < 10 && resolvedPlanText != null) {
      originalPlanText = resolvedPlanText!;
    }
    final fileSuffixes = onFileTap != null
        ? FilePathSyntax.buildSuffixSet(context.watch<FileListCubit>().state)
        : const <String>{};
    final textContentIndexes = <int>[
      for (var i = 0; i < contents.length; i++)
        if (contents[i] is TextContent) i - artifactContentIndexOffset,
    ];
    final artifactTextContentIndex = textContentIndexes.length == 1
        ? textContentIndexes.single
        : -1;
    Future<void> handlePlanLink(String label, String? href, String title) =>
        _handlePlanLink(
          context,
          label,
          href,
          title,
          artifactTextContentIndex,
          fileSuffixes,
        );
    Widget buildPlanImage(Uri uri, String? title, String? alt) =>
        _buildPlanImage(context, uri, title, alt, artifactTextContentIndex);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Render thinking blocks and non-ExitPlanMode tool uses
        for (final content in contents)
          switch (content) {
            ThinkingContent(:final thinking) => ThinkingBubble(
              thinking: thinking,
            ),
            ToolUseContent(:final id, :final name, :final input) =>
              name == 'ExitPlanMode'
                  ? const SizedBox.shrink()
                  : ToolUseTile(toolUseId: id, name: name, input: input),
            TextContent() => const SizedBox.shrink(),
          },
        PlanCard(
          planText: originalPlanText,
          onTapLink: handlePlanLink,
          imageBuilder: buildPlanImage,
          onFileTap: onFileTap,
          onViewFullPlan: () => showPlanDetailSheet(
            context,
            originalPlanText,
            onTapLink: handlePlanLink,
            imageBuilder: buildPlanImage,
            onFileTap: onFileTap,
          ),
        ),
        ArtifactAttachmentGroup(
          artifacts: artifacts
              .where(
                (artifact) => plainTextMode || artifact.originalHref == null,
              )
              .toList(growable: false),
          onOpen: (artifact) => _openArtifact(
            artifact,
            onFileTap: onFileTap,
            onArtifactOpen: onArtifactOpen,
          ),
          canOpen: (artifact) => _canOpenArtifact(
            artifact,
            onFileTap: onFileTap,
            onArtifactOpen: onArtifactOpen,
          ),
        ),
        if (hasTextContent)
          MessageActionBar(
            textToCopy: allText,
            isPlainTextMode: plainTextMode,
            onFork: onFork,
            onTogglePlainText: onTogglePlainText,
          ),
      ],
    );
  }

  Future<void> _handlePlanLink(
    BuildContext context,
    String label,
    String? href,
    String title,
    int textContentIndex,
    Set<String> fileSuffixes,
  ) async {
    if (href == null || href.isEmpty) return;
    final artifact = matchArtifactHref(
      artifacts: artifacts,
      textContentIndex: textContentIndex,
      href: href,
    );
    if (artifact != null) {
      if (_canOpenArtifact(
        artifact,
        onFileTap: onFileTap,
        onArtifactOpen: onArtifactOpen,
      )) {
        await _openArtifact(
          artifact,
          onFileTap: onFileTap,
          onArtifactOpen: onArtifactOpen,
        );
      } else {
        _showArtifactUnavailable(context);
      }
      return;
    }
    buildChatMarkdownLinkHandler(
      context,
      onFileTap: onFileTap,
      knownPathSuffixes: fileSuffixes,
    )(label, href, title);
  }

  Widget _buildPlanImage(
    BuildContext context,
    Uri uri,
    String? title,
    String? alt,
    int textContentIndex,
  ) {
    final href = uri.toString();
    final artifact = matchArtifactHref(
      artifacts: artifacts,
      textContentIndex: textContentIndex,
      href: href,
    );
    if (artifact != null) {
      return ArtifactAttachmentChip(
        artifact: artifact,
        compact: true,
        onOpen:
            _canOpenArtifact(
              artifact,
              onFileTap: onFileTap,
              onArtifactOpen: onArtifactOpen,
            )
            ? (value) => _openArtifact(
                value,
                onFileTap: onFileTap,
                onArtifactOpen: onArtifactOpen,
              )
            : null,
      );
    }
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return Image.network(href, semanticLabel: alt);
    }
    if (uri.scheme == 'data' && uri.data != null) {
      try {
        return Image.memory(uri.data!.contentAsBytes(), semanticLabel: alt);
      } on FormatException {
        // Fall through to the non-broken placeholder below.
      }
    }
    final label = alt?.trim().isNotEmpty == true ? alt!.trim() : 'Image';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.broken_image_outlined,
          size: 16,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(width: 5),
        Flexible(child: Text(label)),
      ],
    );
  }
}

class _DefaultLayout extends StatelessWidget {
  final List<AssistantContent> contents;
  final bool hasTextContent;
  final bool plainTextMode;
  final String allText;
  final FilePathTapCallback? onFileTap;
  final List<ArtifactRef> artifacts;
  final ArtifactOpenCallback? onArtifactOpen;
  final int artifactContentIndexOffset;
  final VoidCallback? onFork;
  final VoidCallback onTogglePlainText;

  const _DefaultLayout({
    required this.contents,
    required this.hasTextContent,
    required this.plainTextMode,
    required this.allText,
    this.onFileTap,
    this.artifacts = const [],
    this.onArtifactOpen,
    this.artifactContentIndexOffset = 0,
    this.onFork,
    required this.onTogglePlainText,
  });

  @override
  Widget build(BuildContext context) {
    final fileSuffixes = onFileTap != null
        ? FilePathSyntax.buildSuffixSet(context.watch<FileListCubit>().state)
        : const <String>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (
          var contentIndex = 0;
          contentIndex < contents.length;
          contentIndex++
        )
          switch (contents[contentIndex]) {
            TextContent(:final text) => _buildTextContent(
              context,
              text,
              fileSuffixes,
              contentIndex - artifactContentIndexOffset,
            ),
            ToolUseContent(:final id, :final name, :final input) =>
              name == 'TodoWrite' || isCodexUpdatePlanTool(name)
                  ? TodoWriteWidget(input: input)
                  : ToolUseTile(toolUseId: id, name: name, input: input),
            ThinkingContent(:final thinking) => ThinkingBubble(
              thinking: thinking,
            ),
          },
        ArtifactAttachmentGroup(
          artifacts: artifacts
              .where(
                (artifact) => plainTextMode || artifact.originalHref == null,
              )
              .toList(growable: false),
          onOpen: (artifact) => _openArtifact(
            artifact,
            onFileTap: onFileTap,
            onArtifactOpen: onArtifactOpen,
          ),
          canOpen: (artifact) => _canOpenArtifact(
            artifact,
            onFileTap: onFileTap,
            onArtifactOpen: onArtifactOpen,
          ),
        ),
        if (hasTextContent)
          MessageActionBar(
            textToCopy: allText,
            isPlainTextMode: plainTextMode,
            onFork: onFork,
            onTogglePlainText: onTogglePlainText,
          ),
      ],
    );
  }

  Widget _buildTextContent(
    BuildContext context,
    String text,
    Set<String> fileSuffixes,
    int textContentIndex,
  ) {
    final planInput = plainTextMode ? null : codexPlanUpdateInputFromText(text);
    if (planInput != null) {
      return TodoWriteWidget(input: planInput);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.bubbleMarginV,
        horizontal: AppSpacing.bubbleMarginH,
      ),
      child: plainTextMode
          ? SelectableText(
              text,
              style: Theme.of(context).textTheme.bodyMedium,
              contextMenuBuilder: googleSearchSelectableTextContextMenuBuilder,
            )
          : GoogleSearchSelectionArea(
              child: MarkdownBody(
                data: text,
                selectable: !googleSearchSelectionMenuEnabled,
                styleSheet: buildMarkdownStyle(context),
                onTapLink: (label, href, title) => _handleLink(
                  context,
                  label,
                  href,
                  title,
                  textContentIndex,
                  fileSuffixes,
                ),
                imageBuilder: (uri, title, alt) =>
                    _buildImage(context, uri, title, alt, textContentIndex),
                inlineSyntaxes: [
                  if (onFileTap != null) ...[
                    FilePathSyntax(knownPathSuffixes: fileSuffixes),
                    BareFilePathSyntax(knownPathSuffixes: fileSuffixes),
                  ],
                  ...colorCodeInlineSyntaxes,
                ],
                builders: {
                  if (onFileTap != null)
                    'filePath': FilePathBuilder(onTap: onFileTap),
                  ...markdownBuilders,
                },
              ),
            ),
    );
  }

  Future<void> _handleLink(
    BuildContext context,
    String label,
    String? href,
    String title,
    int textContentIndex,
    Set<String> fileSuffixes,
  ) async {
    if (href == null || href.isEmpty) return;
    final artifact = matchArtifactHref(
      artifacts: artifacts,
      textContentIndex: textContentIndex,
      href: href,
    );
    if (artifact != null) {
      if (_canOpenArtifact(
        artifact,
        onFileTap: onFileTap,
        onArtifactOpen: onArtifactOpen,
      )) {
        await _openArtifact(
          artifact,
          onFileTap: onFileTap,
          onArtifactOpen: onArtifactOpen,
        );
      } else {
        _showArtifactUnavailable(context);
      }
      return;
    }
    buildChatMarkdownLinkHandler(
      context,
      onFileTap: onFileTap,
      knownPathSuffixes: fileSuffixes,
    )(label, href, title);
  }

  Widget _buildImage(
    BuildContext context,
    Uri uri,
    String? title,
    String? alt,
    int textContentIndex,
  ) {
    final href = uri.toString();
    final artifact = matchArtifactHref(
      artifacts: artifacts,
      textContentIndex: textContentIndex,
      href: href,
    );
    if (artifact != null) {
      return ArtifactAttachmentChip(
        artifact: artifact,
        compact: true,
        onOpen:
            _canOpenArtifact(
              artifact,
              onFileTap: onFileTap,
              onArtifactOpen: onArtifactOpen,
            )
            ? (value) => _openArtifact(
                value,
                onFileTap: onFileTap,
                onArtifactOpen: onArtifactOpen,
              )
            : null,
      );
    }
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return Image.network(href, semanticLabel: alt);
    }
    if (uri.scheme == 'data' && uri.data != null) {
      try {
        return Image.memory(uri.data!.contentAsBytes(), semanticLabel: alt);
      } on FormatException {
        // Fall through to the non-broken placeholder below.
      }
    }
    final label = alt?.trim().isNotEmpty == true ? alt!.trim() : 'Image';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.broken_image_outlined,
          size: 16,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(width: 5),
        Flexible(child: Text(label)),
      ],
    );
  }
}

bool _canOpenArtifact(
  ArtifactRef artifact, {
  FilePathTapCallback? onFileTap,
  ArtifactOpenCallback? onArtifactOpen,
}) {
  if (artifact.isSource) {
    return onFileTap != null &&
        onArtifactOpen != null &&
        isSafeProjectRelativePath(artifact.projectRelativePath);
  }
  return artifact.isPreview && onArtifactOpen != null;
}

Future<void> _openArtifact(
  ArtifactRef artifact, {
  FilePathTapCallback? onFileTap,
  ArtifactOpenCallback? onArtifactOpen,
}) async {
  if (artifact.isSource) {
    final path = artifact.projectRelativePath;
    if (onFileTap != null &&
        onArtifactOpen != null &&
        isSafeProjectRelativePath(path)) {
      await onArtifactOpen(artifact);
    }
    return;
  }
  if (artifact.isPreview) await onArtifactOpen?.call(artifact);
}

void _showArtifactUnavailable(BuildContext context) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(AppLocalizations.of(context).artifactUnavailable),
      duration: const Duration(seconds: 2),
    ),
  );
}

class ToolUseTile extends StatefulWidget {
  final String toolUseId;
  final String name;
  final Map<String, dynamic> input;
  const ToolUseTile({
    super.key,
    this.toolUseId = '',
    required this.name,
    required this.input,
  });

  @override
  State<ToolUseTile> createState() => _ToolUseTileState();
}

/// Three-level expansion state for tool use content (non-edit tools).
/// Edit tools use only [collapsed] and [expanded].
enum ToolUseExpansion { collapsed, preview, expanded }

class _ToolUseTileState extends State<ToolUseTile> {
  late ToolUseExpansion _expansion;
  bool _restoredFromStorage = false;

  late final ToolCategory _category = categorizeToolName(widget.name);
  late final DiffFile? _editDiff = synthesizeEditToolDiff(
    widget.name,
    widget.input,
  );

  bool get _isEditTool => _editDiff != null;

  @override
  void initState() {
    super.initState();
    _expansion = _defaultExpansion;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredFromStorage) return;
    _restoredFromStorage = true;

    final saved = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _storageKey);
    // Backwards-compat: legacy bool values
    if (saved is bool) {
      _expansion = saved
          ? ToolUseExpansion.expanded
          : ToolUseExpansion.collapsed;
      return;
    }
    if (saved is String) {
      for (final value in ToolUseExpansion.values) {
        if (value.name == saved) {
          _expansion = value;
          return;
        }
      }
    }
    // Unknown saved value (e.g. corrupt storage) → fall back to default
    _expansion = _defaultExpansion;
  }

  String _inputSummary() {
    return getToolSummary(_category, widget.input);
  }

  void _copyContent() {
    final inputStr = const JsonEncoder.withIndent('  ').convert(widget.input);
    Clipboard.setData(ClipboardData(text: '${widget.name}\n$inputStr'));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).copied),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _cycleExpansion() {
    setState(() {
      if (_isEditTool) {
        // Edit tools: 2-state toggle (collapsed ↔ expanded)
        _expansion = _expansion == ToolUseExpansion.collapsed
            ? ToolUseExpansion.expanded
            : ToolUseExpansion.collapsed;
      } else {
        // Non-edit tools: 3-state cycle
        _expansion = switch (_expansion) {
          ToolUseExpansion.collapsed => ToolUseExpansion.preview,
          ToolUseExpansion.preview => ToolUseExpansion.expanded,
          ToolUseExpansion.expanded => ToolUseExpansion.collapsed,
        };
      }
    });
    _persistExpandedState();
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.name == _imageGenerationToolName) {
      return _ImageGenerationToolUseStatus(
        input: widget.input,
        onLongPress: _copyContent,
      );
    }

    if (_expansion == ToolUseExpansion.collapsed) {
      return _ToolUseCollapsed(
        name: widget.name,
        category: _category,
        inputSummary: _inputSummary(),
        onTap: _cycleExpansion,
        onLongPress: _copyContent,
      );
    }
    return _ToolUseCard(
      name: widget.name,
      input: widget.input,
      category: _category,
      inputSummary: _inputSummary(),
      editDiff: _editDiff,
      expansion: _expansion,
      onTap: _cycleExpansion,
      onLongPress: _copyContent,
      onOpenGitScreen: _openGitScreen,
    );
  }

  void _openGitScreen() {
    final diff = _editDiff;
    if (diff == null) return;
    final diffText = reconstructUnifiedDiff(diff);
    final filePath = diff.filePath.split('/').lastOrNull ?? diff.filePath;
    context.router.push(GitRoute(initialDiff: diffText, title: filePath));
  }

  String get _storageKey {
    if (widget.toolUseId.isNotEmpty) return 'tool_use:${widget.toolUseId}';
    final encoded = const JsonEncoder().convert(widget.input);
    return 'tool_use_fallback:${widget.name}:${encoded.hashCode}';
  }

  ToolUseExpansion get _defaultExpansion =>
      _isEditTool ? ToolUseExpansion.expanded : ToolUseExpansion.collapsed;

  void _persistExpandedState() {
    PageStorage.maybeOf(
      context,
    )?.writeState(context, _expansion.name, identifier: _storageKey);
  }
}

class _ImageGenerationToolUseStatus extends StatelessWidget {
  final Map<String, dynamic> input;
  final VoidCallback onLongPress;

  const _ImageGenerationToolUseStatus({
    required this.input,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final colorScheme = Theme.of(context).colorScheme;
    final status = input['status']?.toString();
    final revisedPrompt = input['revisedPrompt']?.toString();
    final subtitle = revisedPrompt != null && revisedPrompt.isNotEmpty
        ? revisedPrompt
        : status?.replaceAll('_', ' ');

    return Padding(
      key: const ValueKey('image_generation_tool_use_status'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.bubbleMarginH,
        vertical: 1,
      ),
      child: InkWell(
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Icon(Icons.auto_awesome, size: 13, color: colorScheme.secondary),
              const SizedBox(width: 7),
              const Text(
                'Generating image',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, color: appColors.subtleText),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolUseCollapsed extends StatelessWidget {
  final String name;
  final ToolCategory category;
  final String inputSummary;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ToolUseCollapsed({
    required this.name,
    required this.category,
    required this.inputSummary,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.bubbleMarginH,
        vertical: 1,
      ),
      child: InkWell(
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
                name,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              // Input summary
              Expanded(
                child: Text(
                  inputSummary,
                  style: TextStyle(fontSize: 11, color: appColors.subtleText),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.chevron_right, size: 14, color: appColors.subtleText),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolUseCard extends StatelessWidget {
  final String name;
  final Map<String, dynamic> input;
  final ToolCategory category;
  final String inputSummary;
  final DiffFile? editDiff;
  final ToolUseExpansion expansion;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onOpenGitScreen;

  static const _previewLines = 5;

  const _ToolUseCard({
    required this.name,
    required this.input,
    required this.category,
    required this.inputSummary,
    required this.editDiff,
    required this.expansion,
    required this.onTap,
    required this.onLongPress,
    required this.onOpenGitScreen,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final diffFile = editDiff;
    final chevronIcon = expansion == ToolUseExpansion.expanded
        ? Icons.expand_less
        : Icons.expand_more;

    return Container(
      margin: const EdgeInsets.symmetric(
        vertical: 2,
        horizontal: AppSpacing.bubbleMarginH,
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: appColors.toolBubble,
            borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
            border: Border.all(color: appColors.toolBubbleBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    getToolCategoryIcon(category),
                    size: 14,
                    color: getToolCategoryColor(category, appColors),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      inputSummary,
                      style: TextStyle(
                        fontSize: 11,
                        color: appColors.subtleText,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (diffFile != null) ...[
                    _DiffStatsMini(diffFile: diffFile, appColors: appColors),
                    const SizedBox(width: 4),
                  ],
                  Icon(chevronIcon, size: 16, color: appColors.subtleText),
                ],
              ),
              const SizedBox(height: 6),
              if (diffFile != null)
                InlineEditDiff(
                  diffFile: diffFile,
                  onTapFullDiff: onOpenGitScreen,
                )
              else
                _buildInputBody(appColors),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputBody(AppColors appColors) {
    final fullText = getToolFullInput(category, input);
    final lines = fullText.split('\n');
    final hasMore = lines.length > _previewLines;

    if (expansion == ToolUseExpansion.expanded) {
      return SelectableText(
        fullText,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: appColors.toolResultTextExpanded,
          height: 1.4,
        ),
        contextMenuBuilder: googleSearchSelectableTextContextMenuBuilder,
      );
    }

    // preview
    final previewText = hasMore
        ? lines.take(_previewLines).join('\n')
        : fullText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '... ${lines.length - _previewLines} more lines',
              style: TextStyle(
                fontSize: 10,
                fontStyle: FontStyle.italic,
                color: appColors.subtleText,
              ),
            ),
          ),
      ],
    );
  }
}

/// Inline +N -M stats shown in the card header for edit tools.
class _DiffStatsMini extends StatelessWidget {
  final DiffFile diffFile;
  final AppColors appColors;

  const _DiffStatsMini({required this.diffFile, required this.appColors});

  @override
  Widget build(BuildContext context) {
    final stats = diffFile.stats;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (stats.added > 0)
          Text(
            '+${stats.added}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: appColors.diffAdditionText,
            ),
          ),
        if (stats.added > 0 && stats.removed > 0) const SizedBox(width: 3),
        if (stats.removed > 0)
          Text(
            '-${stats.removed}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: appColors.diffDeletionText,
            ),
          ),
      ],
    );
  }
}
