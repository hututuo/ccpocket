import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart' as provider;

import '../../l10n/app_localizations.dart';
import '../../models/messages.dart';
import '../../services/bridge_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/code_text_style.dart';
import '../../theme/markdown_style.dart'
    show
        buildMarkdownStyle,
        colorCodeInlineSyntaxes,
        handleMarkdownLink,
        highlightToTextSpans,
        markdownBuilders;
import '../../widgets/bubbles/image_preview.dart';
import '../../widgets/workspace_pane_chrome.dart';
import '../artifact_preview/artifact_preview_entry.dart';
import '../file_browser/file_browser_service.dart';
import '../file_browser/file_browser_strings.dart';
import 'html_preview_document.dart';
import 'widgets/html_file_preview.dart';

FileBrowserService? projectFilePreviewServiceOrNull(BuildContext context) {
  if (!supportsEmbeddedArtifactPreview()) return null;
  try {
    final service = provider.Provider.of<FileBrowserService>(
      context,
      listen: false,
    );
    return service.projectPreviewSupportedByBridge ? service : null;
  } on provider.ProviderNotFoundException {
    return null;
  }
}

Future<void> openProjectFilePreview(
  BuildContext context, {
  required FileBrowserService service,
  required String projectPath,
  required String filePath,
}) async {
  final connectionGeneration = service.connectionGeneration;
  try {
    final preview = await service.previewProjectFile(
      projectPath: projectPath,
      filePath: filePath,
    );
    if (!context.mounted ||
        service.connectionGeneration != connectionGeneration ||
        !service.projectPreviewSupportedByBridge) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ArtifactPreviewScreen(
          previewUrl: preview.previewUri,
          filename: preview.filename,
          mimeType: preview.mimeType,
          sizeBytes: preview.sizeBytes,
          expiresAt: preview.expiresAt,
          accessRefresher: () async {
            if (service.connectionGeneration != connectionGeneration ||
                !service.projectPreviewSupportedByBridge) {
              throw const FileBrowserException('bridge_scope_changed');
            }
            final refreshed = await service.previewProjectFile(
              projectPath: projectPath,
              filePath: filePath,
            );
            return ArtifactPreviewAccess(
              previewUrl: refreshed.previewUri,
              expiresAt: refreshed.expiresAt,
            );
          },
        ),
      ),
    );
  } on FileBrowserException {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(FileBrowserStrings.of(context).previewUnavailable),
      ),
    );
  }
}
/// Resolves a potentially partial file path against the project's file list,
/// then shows the file peek sheet.
///
/// If the path matches exactly or resolves to a single candidate, opens
/// directly. If multiple candidates match, shows a picker first.
Future<void> openFilePeek(
  BuildContext context, {
  required BridgeService bridge,
  required String projectPath,
  required String filePath,
  required List<String> projectFiles,
  ValueChanged<String>? onResolvedFilePath,
}) async {
  final resolved = _resolveFilePath(filePath, projectFiles);
  final previewService = projectFilePreviewServiceOrNull(context);

  Future<void> showResolvedFile(String resolvedPath) => showFilePeekSheet(
    context,
    bridge: bridge,
    projectPath: projectPath,
    filePath: resolvedPath,
    onOpenPreviewRequested: previewService == null
        ? null
        : () => openProjectFilePreview(
            context,
            service: previewService,
            projectPath: projectPath,
            filePath: resolvedPath,
          ),
  );

  switch (resolved.length) {
    case 1:
      // Single match — open directly.
      onResolvedFilePath?.call(resolved.first);
      return showResolvedFile(resolved.first);
    case 0:
      // No match — try the original path as-is (Bridge may still find it).
      onResolvedFilePath?.call(filePath);
      return showResolvedFile(filePath);
    default:
      // Multiple matches — let the user pick.
      final picked = await _showFilePickerSheet(context, filePath, resolved);
      if (picked != null && context.mounted) {
        onResolvedFilePath?.call(picked);
        return showResolvedFile(picked);
      }
  }
}

/// Returns project file paths whose suffix matches [filePath].
List<String> _resolveFilePath(String filePath, List<String> projectFiles) {
  final filesOnly = projectFiles.where((f) => !f.endsWith('/'));
  // Exact match first.
  if (filesOnly.contains(filePath)) return [filePath];

  // Suffix match: e.g. "lib/main.dart" matches "apps/mobile/lib/main.dart".
  final suffix = filePath.startsWith('/') ? filePath : '/$filePath';
  final candidates = filesOnly.where((f) => '/$f'.endsWith(suffix)).toList();

  return candidates;
}

/// Bottom sheet that lists candidate file paths for the user to pick from.
Future<String?> _showFilePickerSheet(
  BuildContext context,
  String originalPath,
  List<String> candidates,
) {
  final appColors = Theme.of(context).extension<AppColors>()!;

  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: appColors.subtleText.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Icon(Icons.help_outline, size: 18, color: appColors.subtleText),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$originalPath — ${candidates.length} files found',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: appColors.subtleText,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: candidates.length,
              itemBuilder: (context, index) {
                final path = candidates[index];
                final fileName = path.split('/').last;
                final dir = path.contains('/')
                    ? path.substring(0, path.lastIndexOf('/'))
                    : '';
                return ListTile(
                  leading: Icon(
                    Icons.description_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(fileName, style: const TextStyle(fontSize: 14)),
                  subtitle: dir.isNotEmpty
                      ? Text(
                          dir,
                          style: TextStyle(
                            fontSize: 12,
                            color: appColors.subtleText,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
                  dense: true,
                  onTap: () => Navigator.of(context).pop(path),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// Shows a bottom sheet that loads and displays file content from Bridge.
///
/// [projectPath] is the project root on the server.
/// [filePath] is the relative path within the project (e.g. "lib/main.dart").
Future<void> showFilePeekSheet(
  BuildContext context, {
  required BridgeService bridge,
  required String projectPath,
  required String filePath,
  int? initialLine,
  String? artifactSessionId,
  String? artifactMessageId,
  String? artifactId,
  FileContentMessage? initialContent,
  VoidCallback? onOpened,
  Future<void> Function()? onOpenPreviewRequested,
}) {
  onOpened?.call();
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    constraints: macOSModalBottomSheetConstraints(context),
    useSafeArea: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => _FilePeekContent(
        bridge: bridge,
        projectPath: projectPath,
        filePath: filePath,
        initialLine: initialLine,
        artifactSessionId: artifactSessionId,
        artifactMessageId: artifactMessageId,
        artifactId: artifactId,
        initialContent: initialContent,
        onOpenPreviewRequested: onOpenPreviewRequested,
        scrollController: scrollController,
      ),
    ),
  );
}

class _FilePeekContent extends StatefulWidget {
  final BridgeService bridge;
  final String projectPath;
  final String filePath;
  final int? initialLine;
  final String? artifactSessionId;
  final String? artifactMessageId;
  final String? artifactId;
  final FileContentMessage? initialContent;
  final Future<void> Function()? onOpenPreviewRequested;
  final ScrollController scrollController;

  const _FilePeekContent({
    required this.bridge,
    required this.projectPath,
    required this.filePath,
    this.initialLine,
    this.artifactSessionId,
    this.artifactMessageId,
    this.artifactId,
    this.initialContent,
    this.onOpenPreviewRequested,
    required this.scrollController,
  });

  @override
  State<_FilePeekContent> createState() => _FilePeekContentState();
}

class _FilePeekContentState extends State<_FilePeekContent> {
  FileContentMessage? _result;
  bool _loading = true;
  late bool _showRaw;
  bool _didJumpToInitialLine = false;
  bool _openingPreview = false;

  @override
  void initState() {
    super.initState();
    _showRaw = widget.initialLine != null;
    final initialContent = widget.initialContent;
    if (initialContent == null) {
      _loadFile();
    } else {
      _result = initialContent;
      _loading = false;
      _scheduleInitialLineJump();
    }
  }

  Future<void> _loadFile() async {
    try {
      final maxLines = filePeekMaxLinesForInitialLine(widget.initialLine);
      final result = await readFilePeekContent(
        bridge: widget.bridge,
        projectPath: widget.projectPath,
        filePath: widget.filePath,
        artifactSessionId: widget.artifactSessionId,
        artifactMessageId: widget.artifactMessageId,
        artifactId: widget.artifactId,
        maxLines: maxLines,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      _scheduleInitialLineJump();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _result = FileContentMessage(
          filePath: widget.filePath,
          content: '',
          error: error.toString(),
        );
        _loading = false;
      });
    }
  }

  void _scheduleInitialLineJump() {
    final line = normalizedFilePeekInitialLine(widget.initialLine);
    if (line == null || _didJumpToInitialLine) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _didJumpToInitialLine) return;
      final controller = widget.scrollController;
      if (!controller.hasClients) return;
      final fontSize = codeTextSettingsOf(context).style().fontSize ?? 14;
      final position = controller.position;
      final offset = filePeekOffsetForLine(
        line: line,
        lineExtent: fontSize * 1.5,
        viewportExtent: position.viewportDimension,
        maxScrollExtent: position.maxScrollExtent,
      );
      _didJumpToInitialLine = true;
      controller.jumpTo(offset);
    });
  }

  void _copyPath() {
    Clipboard.setData(ClipboardData(text: '@${widget.filePath}'));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).copied),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _openUnifiedPreview() async {
    final callback = widget.onOpenPreviewRequested;
    if (callback == null || _openingPreview) return;
    setState(() => _openingPreview = true);
    try {
      await callback();
    } finally {
      if (mounted) setState(() => _openingPreview = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final fileName = widget.filePath.split('/').lastOrNull ?? widget.filePath;
    final isMarkdown = widget.filePath.endsWith('.md');
    final isHtml = isHtmlPreviewPath(widget.filePath);
    final isImage = _result?.kind == 'image';
    final canPreviewHtml = isHtml && supportsEmbeddedHtmlPreview;

    return Column(
      children: [
        // Drag handle
        Container(
          margin: const EdgeInsets.only(top: 8),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: appColors.subtleText.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 18,
                color: appColors.subtleText,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        fileName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: _copyPath,
                      child: Icon(
                        Icons.content_copy,
                        size: 14,
                        color: appColors.subtleText,
                      ),
                    ),
                  ],
                ),
              ),
              if (isImage && !_loading && _result?.error == null)
                IconButton(
                  key: const ValueKey('file_peek_image_fullscreen_button'),
                  icon: const Icon(Icons.open_in_full, size: 18),
                  onPressed: _openImageFullScreen,
                  visualDensity: VisualDensity.compact,
                ),
              if ((isMarkdown || canPreviewHtml) &&
                  !isImage &&
                  !_loading &&
                  _result?.error == null)
                IconButton(
                  key: const ValueKey('file_peek_source_toggle_button'),
                  icon: Icon(
                    _showRaw ? Icons.preview_outlined : Icons.code,
                    size: 18,
                    color: _showRaw
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  onPressed: () => setState(() => _showRaw = !_showRaw),
                  visualDensity: VisualDensity.compact,
                  tooltip: _showRaw
                      ? AppLocalizations.of(context).filePreviewShowPreview
                      : AppLocalizations.of(context).filePreviewShowSource,
                ),
              if (widget.onOpenPreviewRequested != null)
                IconButton(
                  key: const ValueKey('file_peek_unified_preview_button'),
                  tooltip: FileBrowserStrings.of(context).preview,
                  icon: _openingPreview
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.visibility_outlined, size: 18),
                  onPressed: _openingPreview ? null : _openUnifiedPreview,
                  visualDensity: VisualDensity.compact,
                ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.of(context).pop(),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        // Full path
        if (widget.filePath != fileName)
          Padding(
            padding: const EdgeInsets.only(left: 42, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.filePath,
                style: TextStyle(
                  fontSize: 11,
                  color: appColors.subtleText,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        if (_result != null && _result!.totalLines != null)
          Padding(
            padding: const EdgeInsets.only(left: 42, top: 2, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_result!.totalLines} lines${_result!.truncated ? ' (truncated)' : ''}${_result!.language != null ? ' \u00b7 ${_result!.language}' : ''}',
                style: TextStyle(fontSize: 11, color: appColors.subtleText),
              ),
            ),
          ),
        if (normalizedFilePeekInitialLine(widget.initialLine)
            case final initialLine?)
          Padding(
            padding: const EdgeInsets.only(left: 42, top: 2, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                AppLocalizations.of(context).artifactLineLabel(initialLine),
                key: const ValueKey('file_peek_initial_line_label'),
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        if (_result != null && _result!.kind == 'image')
          Padding(
            padding: const EdgeInsets.only(left: 42, top: 2, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                [
                  if (_result!.sizeBytes != null)
                    _formatFileSize(_result!.sizeBytes!),
                  if (_result!.mimeType != null) _result!.mimeType!,
                ].join(' · '),
                style: TextStyle(fontSize: 11, color: appColors.subtleText),
              ),
            ),
          ),
        const Divider(height: 1),
        // Content
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator.adaptive())
              : _result?.error != null
              ? _buildError(appColors)
              : _result?.kind == 'image'
              ? _buildImageContent(appColors)
              : (canPreviewHtml && !_showRaw)
              ? HtmlFilePreview(html: _result!.content)
              : (isMarkdown && !_showRaw)
              ? _buildMarkdownPreview()
              : _buildCodeContent(appColors),
        ),
      ],
    );
  }

  void _openImageFullScreen() {
    final bytes = _imageBytes();
    if (bytes == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullScreenImageViewer(
          bytes: bytes,
          isSvg: _result?.mimeType == 'image/svg+xml',
        ),
      ),
    );
  }

  Uint8List? _imageBytes() {
    final base64 = _result?.base64;
    if (base64 == null || base64.isEmpty) return null;
    try {
      return base64Decode(base64);
    } catch (_) {
      return null;
    }
  }

  Widget _buildError(AppColors appColors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: appColors.subtleText),
            const SizedBox(height: 12),
            Text(
              _result!.error!,
              style: TextStyle(color: appColors.subtleText),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMarkdownPreview() {
    return Markdown(
      controller: widget.scrollController,
      data: _result!.content,
      selectable: true,
      styleSheet: buildMarkdownStyle(context),
      onTapLink: handleMarkdownLink,
      inlineSyntaxes: colorCodeInlineSyntaxes,
      builders: markdownBuilders,
      padding: const EdgeInsets.all(16),
    );
  }

  Widget _buildImageContent(AppColors appColors) {
    final bytes = _imageBytes();
    if (bytes == null) {
      return Center(
        child: Icon(Icons.broken_image, size: 40, color: appColors.subtleText),
      );
    }
    return _FilePeekImagePreview(
      bytes: bytes,
      isSvg: _result?.mimeType == 'image/svg+xml',
      onOpenFullScreen: _openImageFullScreen,
    );
  }

  Widget _buildCodeContent(AppColors appColors) {
    final content = _result!.content;
    final language = _result!.language;
    final lines = content.split('\n');
    final gutterWidth = '${lines.length}'.length;

    final baseStyle = codeTextSettingsOf(
      context,
    ).style(height: 1.5, color: Theme.of(context).colorScheme.onSurface);

    final gutterStyle = baseStyle.copyWith(
      color: appColors.subtleText.withValues(alpha: 0.5),
    );
    final targetLine = normalizedFilePeekInitialLine(widget.initialLine);
    final targetBackground = Theme.of(
      context,
    ).colorScheme.primary.withValues(alpha: 0.14);

    // Get highlighted spans for each line.
    final highlightedLines = <List<InlineSpan>>[];
    final highlighted = highlightToTextSpans(
      context: context,
      source: content,
      baseStyle: baseStyle,
      language: language,
    );

    // Split highlighted spans into per-line lists.
    if (highlighted.length == 1 && highlighted.first.text == content) {
      // No highlighting — split plain text by line.
      for (final line in lines) {
        highlightedLines.add([TextSpan(text: line, style: baseStyle)]);
      }
    } else {
      highlightedLines.addAll(_splitSpansByLine(highlighted, lines.length));
    }

    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: MediaQuery.of(context).size.width,
          ),
          child: SelectableText.rich(
            TextSpan(
              style: baseStyle,
              children: [
                for (var i = 0; i < highlightedLines.length; i++) ...[
                  TextSpan(
                    text: '${' ${i + 1}'.padLeft(gutterWidth + 1)}  ',
                    style: i + 1 == targetLine
                        ? gutterStyle.copyWith(
                            backgroundColor: targetBackground,
                          )
                        : gutterStyle,
                  ),
                  if (i + 1 == targetLine)
                    TextSpan(
                      style: baseStyle.copyWith(
                        backgroundColor: targetBackground,
                      ),
                      children: highlightedLines[i],
                    )
                  else
                    ...highlightedLines[i],
                  const TextSpan(text: '\n'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Splits a flat list of highlighted [TextSpan]s into per-line groups.
  List<List<InlineSpan>> _splitSpansByLine(
    List<TextSpan> spans,
    int lineCount,
  ) {
    final result = List.generate(lineCount, (_) => <InlineSpan>[]);
    var lineIndex = 0;

    void addText(String text, TextStyle? style) {
      final parts = text.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0 && lineIndex < lineCount - 1) lineIndex++;
        if (parts[i].isNotEmpty && lineIndex < lineCount) {
          result[lineIndex].add(TextSpan(text: parts[i], style: style));
        }
      }
    }

    void walkSpan(TextSpan span) {
      if (span.text != null) {
        addText(span.text!, span.style);
      }
      if (span.children != null) {
        for (final child in span.children!) {
          if (child is TextSpan) walkSpan(child);
        }
      }
    }

    for (final span in spans) {
      walkSpan(span);
    }
    return result;
  }
}

/// Selects the identity-authorized source RPC whenever File Peek belongs to an
/// artifact. Keeping this decision in the reload path prevents retries from
/// silently falling back to the unrestricted project file reader.
@visibleForTesting
Future<FileContentMessage> readFilePeekContent({
  required BridgeService bridge,
  required String projectPath,
  required String filePath,
  String? artifactSessionId,
  String? artifactMessageId,
  String? artifactId,
  int? maxLines,
}) {
  final artifactIdentity = [artifactSessionId, artifactMessageId, artifactId];
  final hasAnyArtifactIdentity = artifactIdentity.any((value) => value != null);
  final hasCompleteArtifactIdentity = artifactIdentity.every(
    (value) => value?.trim().isNotEmpty == true,
  );
  if (hasAnyArtifactIdentity && !hasCompleteArtifactIdentity) {
    return Future<FileContentMessage>.error(
      ArgumentError('Artifact source identity is incomplete.'),
    );
  }
  if (hasCompleteArtifactIdentity) {
    return bridge.readArtifactSource(
      sessionId: artifactSessionId!,
      messageId: artifactMessageId!,
      artifactId: artifactId!,
      filePath: filePath,
      maxLines: maxLines,
    );
  }
  return bridge.readFile(
    projectPath: projectPath,
    filePath: filePath,
    maxLines: maxLines,
  );
}

@visibleForTesting
int? normalizedFilePeekInitialLine(int? line) {
  if (line == null) return null;
  return line.clamp(1, 100000).toInt();
}

int? filePeekMaxLinesForInitialLine(int? line) {
  final normalized = normalizedFilePeekInitialLine(line);
  if (normalized == null) return null;
  final requested = normalized + 100;
  final withDefaultWindow = requested < 5000 ? 5000 : requested;
  return withDefaultWindow.clamp(1, 100000).toInt();
}

@visibleForTesting
double filePeekOffsetForLine({
  required int line,
  required double lineExtent,
  required double viewportExtent,
  required double maxScrollExtent,
}) {
  final centered = (line - 1) * lineExtent - viewportExtent / 3;
  return centered.clamp(0.0, maxScrollExtent).toDouble();
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _FilePeekImagePreview extends StatelessWidget {
  final Uint8List bytes;
  final bool isSvg;
  final VoidCallback onOpenFullScreen;

  const _FilePeekImagePreview({
    required this.bytes,
    required this.isSvg,
    required this.onOpenFullScreen,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('file_peek_image_preview'),
      behavior: HitTestBehavior.opaque,
      onTap: onOpenFullScreen,
      child: Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: isSvg
              ? SvgPicture.memory(bytes, fit: BoxFit.contain)
              : Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.broken_image,
                    color: Colors.white54,
                    size: 48,
                  ),
                ),
        ),
      ),
    );
  }
}
