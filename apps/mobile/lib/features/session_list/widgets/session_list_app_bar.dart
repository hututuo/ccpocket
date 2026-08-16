import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../router/app_router.dart';
import '../../../services/app_update_service.dart';
import '../../../widgets/workspace_pane_chrome.dart';
import '../../file_browser/file_browser_strings.dart';
import '../../session_archive/session_archive_strings.dart';

/// Floating SliverAppBar for the session list screen.
///
/// Hides on scroll-down and snaps back on scroll-up (Material 3
/// enterAlways behaviour).
class SessionListSliverAppBar extends StatelessWidget {
  final VoidCallback onTitleTap;
  final VoidCallback onDisconnect;
  final VoidCallback? onOpenArchivedSessions;
  final VoidCallback? onOpenFileBrowser;
  final Future<void> Function()? onRefresh;
  final bool isRefreshing;
  final bool forceElevated;
  final double? toolbarHeight;
  final String? bridgeLabel;

  const SessionListSliverAppBar({
    super.key,
    required this.onTitleTap,
    required this.onDisconnect,
    this.onOpenArchivedSessions,
    this.onOpenFileBrowser,
    this.onRefresh,
    this.isRefreshing = false,
    this.forceElevated = false,
    this.toolbarHeight,
    this.bridgeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final compactActions = MediaQuery.sizeOf(context).width <= 375;
    void openGallery() => context.router.navigate(GalleryRoute());

    return SliverAppBar(
      floating: true,
      snap: true,
      forceElevated: forceElevated,
      toolbarHeight: toolbarHeight ?? kToolbarHeight,
      title: GestureDetector(
        onTap: onTitleTap,
        child: _SessionListTitle(title: l.appTitle, subtitle: bridgeLabel),
      ),
      actions: [
        if (onRefresh != null)
          IconButton(
            key: const ValueKey('refresh_sessions_button'),
            icon: isRefreshing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: isRefreshing ? null : () => unawaited(onRefresh!.call()),
            tooltip: l.refresh,
          ),
        if (!compactActions && onOpenArchivedSessions != null)
          IconButton(
            key: const ValueKey('archived_sessions_button'),
            icon: const Icon(Icons.archive_outlined),
            onPressed: onOpenArchivedSessions,
            tooltip: SessionArchiveStrings.of(context).title,
          ),
        IconButton(
          key: const ValueKey('settings_button'),
          icon: Badge(
            isLabelVisible: AppUpdateService.instance.cachedUpdate != null,
            smallSize: 8,
            child: const Icon(Icons.settings),
          ),
          onPressed: () => context.router.navigate(SettingsRoute()),
          tooltip: l.settings,
        ),
        if (onOpenFileBrowser != null)
          IconButton(
            key: const ValueKey('file_browser_button'),
            icon: const Icon(Icons.folder_open_outlined),
            onPressed: onOpenFileBrowser,
            tooltip: FileBrowserStrings.of(context).title,
          ),
        if (compactActions)
          _PaneHeaderOverflowButton(
            compact: false,
            archiveLabel: onOpenArchivedSessions == null
                ? null
                : SessionArchiveStrings.of(context).title,
            galleryLabel: l.gallery,
            disconnectLabel: l.disconnect,
            onOpenArchivedSessions: onOpenArchivedSessions,
            onOpenGallery: openGallery,
            onDisconnect: onDisconnect,
          )
        else ...[
          IconButton(
            key: const ValueKey('gallery_button'),
            icon: const Icon(Icons.collections),
            onPressed: openGallery,
            tooltip: l.gallery,
          ),
          IconButton(
            key: const ValueKey('disconnect_button'),
            icon: const Icon(Icons.link_off),
            onPressed: onDisconnect,
            tooltip: l.disconnect,
          ),
        ],
      ],
    );
  }
}

class SessionListPaneHeader extends StatelessWidget {
  final VoidCallback onTitleTap;
  final VoidCallback onOpenSettings;
  final VoidCallback? onOpenGallery;
  final VoidCallback? onOpenFileBrowser;
  final VoidCallback? onOpenArchivedSessions;
  final VoidCallback? onDisconnect;
  final VoidCallback? onTogglePaneVisibility;
  final Future<void> Function()? onRefresh;
  final bool isRefreshing;
  final String? bridgeLabel;

  const SessionListPaneHeader({
    super.key,
    required this.onTitleTap,
    required this.onOpenSettings,
    this.onOpenGallery,
    this.onOpenFileBrowser,
    this.onOpenArchivedSessions,
    this.onDisconnect,
    this.onTogglePaneVisibility,
    this.onRefresh,
    this.isRefreshing = false,
    this.bridgeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final openGallery = onOpenGallery;
    final openFileBrowser = onOpenFileBrowser;
    final disconnect = onDisconnect;
    final togglePaneVisibility = onTogglePaneVisibility;
    final chrome = resolveWorkspacePaneChrome(
      platform: Theme.of(context).platform,
      isAdaptiveWorkspace: true,
      isLeftPaneVisible: true,
      slot: WorkspacePaneSlot.left,
    );
    final titleStyle = Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700);
    final actionGap = chrome.useMacOSAdaptiveChrome ? 8.0 : 0.0;
    final collapseSecondaryActions =
        chrome.useMacOSAdaptiveChrome &&
        openFileBrowser != null &&
        (onOpenArchivedSessions != null ||
            openGallery != null ||
            disconnect != null);

    return SizedBox(
      height: chrome.toolbarHeight,
      child: Padding(
        padding: chrome.headerPadding(),
        child: Row(
          children: [
            if (!chrome.useMacOSAdaptiveChrome)
              Expanded(
                child: GestureDetector(
                  onTap: onTitleTap,
                  child: _SessionListTitle(
                    key: const ValueKey('session_list_pane_title'),
                    title: l.appTitle,
                    subtitle: bridgeLabel,
                    titleStyle: titleStyle,
                  ),
                ),
              )
            else
              const Expanded(
                child: MacOSWindowDragHandle(child: SizedBox.expand()),
              ),
            if (onRefresh != null)
              _PaneHeaderActionButton(
                key: const ValueKey('refresh_sessions_button'),
                tooltip: l.refresh,
                onPressed: isRefreshing
                    ? null
                    : () => unawaited(onRefresh!.call()),
                icon: isRefreshing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                compact: chrome.useMacOSAdaptiveChrome,
              ),
            _PaneHeaderActionButton(
              key: const ValueKey('settings_button'),
              tooltip: l.settings,
              onPressed: onOpenSettings,
              icon: Badge(
                isLabelVisible: AppUpdateService.instance.cachedUpdate != null,
                smallSize: 8,
                child: const Icon(Icons.settings),
              ),
              compact: chrome.useMacOSAdaptiveChrome,
            ),
            if (onOpenArchivedSessions != null && !collapseSecondaryActions)
              _PaneHeaderActionButton(
                key: const ValueKey('archived_sessions_button'),
                tooltip: SessionArchiveStrings.of(context).title,
                onPressed: onOpenArchivedSessions!,
                icon: const Icon(Icons.archive_outlined),
                compact: chrome.useMacOSAdaptiveChrome,
              ),
            if (openFileBrowser != null ||
                openGallery != null ||
                disconnect != null ||
                togglePaneVisibility != null)
              SizedBox(width: actionGap),
            if (openFileBrowser != null)
              _PaneHeaderActionButton(
                key: const ValueKey('file_browser_button'),
                tooltip: FileBrowserStrings.of(context).title,
                onPressed: openFileBrowser,
                icon: const Icon(Icons.folder_open_outlined),
                compact: chrome.useMacOSAdaptiveChrome,
              ),
            if (openFileBrowser != null &&
                (openGallery != null ||
                    disconnect != null ||
                    togglePaneVisibility != null))
              SizedBox(width: actionGap),
            if (openGallery != null && !collapseSecondaryActions)
              _PaneHeaderActionButton(
                key: const ValueKey('gallery_button'),
                tooltip: l.gallery,
                onPressed: openGallery,
                icon: const Icon(Icons.collections_outlined),
                compact: chrome.useMacOSAdaptiveChrome,
              ),
            if (!collapseSecondaryActions &&
                openGallery != null &&
                (disconnect != null || togglePaneVisibility != null))
              SizedBox(width: actionGap),
            if (disconnect != null && !collapseSecondaryActions)
              _PaneHeaderActionButton(
                key: const ValueKey('disconnect_button'),
                tooltip: l.disconnect,
                onPressed: disconnect,
                icon: const Icon(Icons.link_off),
                compact: chrome.useMacOSAdaptiveChrome,
              ),
            if (collapseSecondaryActions) ...[
              _PaneHeaderOverflowButton(
                compact: chrome.useMacOSAdaptiveChrome,
                archiveLabel: onOpenArchivedSessions == null
                    ? null
                    : SessionArchiveStrings.of(context).title,
                galleryLabel: openGallery == null ? null : l.gallery,
                disconnectLabel: disconnect == null ? null : l.disconnect,
                onOpenArchivedSessions: onOpenArchivedSessions,
                onOpenGallery: openGallery,
                onDisconnect: disconnect,
              ),
              if (togglePaneVisibility != null) SizedBox(width: actionGap),
            ],
            if (!collapseSecondaryActions &&
                disconnect != null &&
                togglePaneVisibility != null)
              SizedBox(width: actionGap),
            if (togglePaneVisibility != null)
              _PaneHeaderActionButton(
                key: const ValueKey('collapse_left_pane_button'),
                tooltip: l.hideSessions,
                onPressed: togglePaneVisibility,
                icon: const Icon(Icons.chevron_left),
                compact: chrome.useMacOSAdaptiveChrome,
              ),
          ],
        ),
      ),
    );
  }
}

enum _PaneHeaderOverflowAction { archive, gallery, disconnect }

class _PaneHeaderOverflowButton extends StatelessWidget {
  final bool compact;
  final String? archiveLabel;
  final String? galleryLabel;
  final String? disconnectLabel;
  final VoidCallback? onOpenArchivedSessions;
  final VoidCallback? onOpenGallery;
  final VoidCallback? onDisconnect;

  const _PaneHeaderOverflowButton({
    required this.compact,
    this.archiveLabel,
    this.galleryLabel,
    this.disconnectLabel,
    this.onOpenArchivedSessions,
    this.onOpenGallery,
    this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final chrome = resolveWorkspacePaneChrome(
      platform: Theme.of(context).platform,
      isAdaptiveWorkspace: true,
      isLeftPaneVisible: true,
      slot: WorkspacePaneSlot.left,
    );
    return PopupMenuButton<_PaneHeaderOverflowAction>(
      key: const ValueKey('session_list_more_button'),
      style: compact ? chrome.compactButtonStyle() : null,
      tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
      icon: const Icon(Icons.more_horiz),
      onSelected: (action) {
        switch (action) {
          case _PaneHeaderOverflowAction.archive:
            onOpenArchivedSessions?.call();
          case _PaneHeaderOverflowAction.gallery:
            onOpenGallery?.call();
          case _PaneHeaderOverflowAction.disconnect:
            onDisconnect?.call();
        }
      },
      itemBuilder: (context) => [
        if (onOpenArchivedSessions != null)
          PopupMenuItem(
            value: _PaneHeaderOverflowAction.archive,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.archive_outlined),
              title: Text(archiveLabel!),
            ),
          ),
        if (onOpenGallery != null)
          PopupMenuItem(
            value: _PaneHeaderOverflowAction.gallery,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.collections_outlined),
              title: Text(galleryLabel!),
            ),
          ),
        if (onDisconnect != null)
          PopupMenuItem(
            value: _PaneHeaderOverflowAction.disconnect,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link_off),
              title: Text(disconnectLabel!),
            ),
          ),
      ],
    );
  }
}

class _SessionListTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final TextStyle? titleStyle;

  const _SessionListTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.titleStyle,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    final theme = Theme.of(context);
    final defaultTitleStyle = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
    );
    if (subtitle == null || subtitle.isEmpty) {
      return Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: titleStyle ?? defaultTitleStyle,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: titleStyle ?? defaultTitleStyle,
        ),
        const SizedBox(height: 1),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _PaneHeaderActionButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback? onPressed;
  final Widget icon;
  final bool compact;

  const _PaneHeaderActionButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      style: compact
          ? resolveWorkspacePaneChrome(
              platform: Theme.of(context).platform,
              isAdaptiveWorkspace: true,
              isLeftPaneVisible: true,
              slot: WorkspacePaneSlot.left,
            ).compactButtonStyle()
          : null,
      constraints: compact
          ? const BoxConstraints.tightFor(width: 32, height: 32)
          : null,
      padding: compact ? EdgeInsets.zero : null,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
      tooltip: tooltip,
      icon: icon,
    );
  }
}
