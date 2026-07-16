import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/messages.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_theme.dart';

typedef ArtifactOpenCallback = Future<void> Function(ArtifactRef artifact);

class ArtifactAttachmentChip extends StatefulWidget {
  final ArtifactRef artifact;
  final ArtifactOpenCallback? onOpen;
  final bool compact;

  const ArtifactAttachmentChip({
    super.key,
    required this.artifact,
    this.onOpen,
    this.compact = false,
  });

  @override
  State<ArtifactAttachmentChip> createState() =>
      _ArtifactAttachmentChipState();
}

class _ArtifactAttachmentChipState extends State<ArtifactAttachmentChip> {
  bool _opening = false;

  Future<void> _open() async {
    final onOpen = widget.onOpen;
    if (onOpen == null || _opening) return;
    setState(() => _opening = true);
    try {
      await onOpen(widget.artifact);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = Theme.of(context).extension<AppColors>()!;
    final artifact = widget.artifact;
    final enabled = widget.onOpen != null;
    final localizations = AppLocalizations.of(context);
    final baseLabel = artifact.filename.isEmpty
        ? localizations.artifactFile
        : artifact.filename;
    final locationSuffix = artifact.line == null
        ? ''
        : ':${artifact.line}'
              '${artifact.column == null ? '' : ':${artifact.column}'}';
    final displayLabel = artifact.isSource && artifact.line != null
        ? '$baseLabel$locationSuffix'
        : baseLabel;

    return Material(
      key: ValueKey('artifact_attachment_${artifact.id}'),
      color: appColors.subtleText.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
      child: InkWell(
        onTap: enabled ? _open : null,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        child: Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 8 : 10,
            vertical: widget.compact ? 5 : 7,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          child: Row(
            mainAxisSize: widget.compact ? MainAxisSize.min : MainAxisSize.max,
            children: [
              if (_opening)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: colors.primary,
                  ),
                )
              else
                Icon(
                  artifact.isSource
                      ? Icons.code
                      : _iconForMimeType(artifact.mimeType),
                  size: 17,
                  color: enabled ? colors.primary : appColors.subtleText,
                ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  displayLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: enabled ? null : appColors.subtleText,
                  ),
                ),
              ),
              if (!widget.compact) ...[
                const SizedBox(width: 8),
                Text(
                  artifact.isSource
                      ? localizations.artifactSource
                      : artifact.sizeLabel,
                  style: TextStyle(fontSize: 10, color: appColors.subtleText),
                ),
                const SizedBox(width: 3),
                Icon(
                  artifact.isSource
                      ? Icons.chevron_right
                      : Icons.open_in_new,
                  size: 14,
                  color: appColors.subtleText,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ArtifactAttachmentGroup extends StatelessWidget {
  final List<ArtifactRef> artifacts;
  final ArtifactOpenCallback? onOpen;
  final bool Function(ArtifactRef artifact)? canOpen;

  const ArtifactAttachmentGroup({
    super.key,
    required this.artifacts,
    this.onOpen,
    this.canOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (artifacts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.bubbleMarginH,
        3,
        AppSpacing.bubbleMarginH,
        5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < artifacts.length; i++) ...[
            if (i > 0) const SizedBox(height: 5),
            ArtifactAttachmentChip(
              artifact: artifacts[i],
              onOpen: canOpen?.call(artifacts[i]) == false ? null : onOpen,
            ),
          ],
        ],
      ),
    );
  }
}

IconData _iconForMimeType(String mimeType) {
  if (mimeType.startsWith('image/')) return Icons.image_outlined;
  if (mimeType == 'application/pdf') return Icons.picture_as_pdf;
  if (mimeType.contains('zip') || mimeType.contains('compressed')) {
    return Icons.archive_outlined;
  }
  return Icons.description_outlined;
}
