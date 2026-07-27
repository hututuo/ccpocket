import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../../services/bridge_service.dart';
import 'gallery_filter_chips.dart';
import 'gallery_image_viewer.dart';
import 'gallery_tile.dart';

class GalleryContent extends StatelessWidget {
  final List<GalleryImage> images;
  final String? selectedProject;
  final bool isSessionMode;
  final String httpBaseUrl;
  final ValueChanged<String?> onProjectSelected;

  const GalleryContent({
    super.key,
    required this.images,
    required this.selectedProject,
    required this.isSessionMode,
    required this.httpBaseUrl,
    required this.onProjectSelected,
  });

  Map<String, int> _projectCounts() {
    final counts = <String, int>{};
    for (final img in images) {
      counts[img.projectName] = (counts[img.projectName] ?? 0) + 1;
    }
    return counts;
  }

  List<GalleryImage> _filteredImages() {
    if (selectedProject == null) return images;
    return images.where((img) => img.projectName == selectedProject).toList();
  }

  static String timeAgo(String isoDate, AppLocalizations l) {
    final date = DateTime.tryParse(isoDate)?.toLocal();
    if (date == null) return '';
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1) return l.justNow;
    if (diff.inMinutes < 60) return l.minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l.hoursAgo(diff.inHours);
    if (diff.inDays < 30) return l.daysAgo(diff.inDays);
    return l.monthsAgo((diff.inDays / 30).floor());
  }

  void _openViewer(
    BuildContext context,
    List<GalleryImage> filtered,
    int index,
  ) {
    final bridge = context.read<BridgeService>();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GalleryImageViewer(
          images: filtered,
          initialIndex: index,
          httpBaseUrl: httpBaseUrl,
          onDelete: (id) => bridge.deleteGalleryImage(id),
        ),
      ),
    );
  }

  Future<void> _showDeleteDialog(
    BuildContext context,
    GalleryImage image,
  ) async {
    final confirmed = await showDeleteConfirmDialog(context);
    if (!confirmed || !context.mounted) return;

    final bridge = context.read<BridgeService>();
    final success = await bridge.deleteGalleryImage(image.id);
    if (!context.mounted) return;
    final l = AppLocalizations.of(context);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(success ? l.screenshotDeleted : l.failedToDeleteImage),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final filtered = _filteredImages();
    final counts = _projectCounts();

    return Column(
      children: [
        if (!isSessionMode && counts.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: GalleryFilterChips(
              projectCounts: counts,
              totalCount: images.length,
              selectedProject: selectedProject,
              onSelected: onProjectSelected,
            ),
          ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.75,
            ),
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final image = filtered[index];
              return GalleryTile(
                image: image,
                httpBaseUrl: httpBaseUrl,
                timeAgo: timeAgo(image.addedAt, l),
                onTap: () => _openViewer(context, filtered, index),
                onLongPress: () => _showDeleteDialog(context, image),
              );
            },
          ),
        ),
      ],
    );
  }
}
