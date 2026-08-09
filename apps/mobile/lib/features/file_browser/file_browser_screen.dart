import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../models/messages.dart';
import '../../widgets/workspace_pane_chrome.dart';
import '../artifact_preview/artifact_preview_entry.dart';
import '../session_list/workspace_shell_screen.dart';
import 'file_browser_service.dart';
import 'file_browser_strings.dart';

class FileBrowserScreen extends StatefulWidget {
  final bool embedded;
  final VoidCallback? onBack;
  final VoidCallback? onClose;

  const FileBrowserScreen({
    super.key,
    this.embedded = false,
    this.onBack,
    this.onClose,
  });

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  final ScrollController _scrollController = ScrollController();
  FileBrowserService? _service;
  FileBrowserRoot? _root;
  String _relativePath = '';
  FileBrowserDirectorySnapshot? _directory;
  String? _directoryError;
  bool _loadingDirectory = false;
  bool _loadingMore = false;
  bool _showHidden = false;
  bool _syncScheduled = false;
  bool _refreshingRoots = false;
  int _loadGeneration = 0;
  int _previewGeneration = 0;
  int _serviceScopeRevision = -1;
  final Set<String> _busyNodeActions = <String>{};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<FileBrowserService>();
    if (!identical(next, _service)) {
      _service?.removeListener(_scheduleServiceSync);
      _service = next..addListener(_scheduleServiceSync);
      _serviceScopeRevision = -1;
    }
    _scheduleServiceSync();
  }

  @override
  void dispose() {
    _service?.removeListener(_scheduleServiceSync);
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleServiceSync() {
    if (_syncScheduled || !mounted) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      final service = _service!;
      final scopeChanged = service.scopeRevision != _serviceScopeRevision;
      if (scopeChanged) {
        setState(() => _adoptServiceScope(service));
      }
      if (service.isConnected &&
          service.supportedByBridge &&
          service.roots.isEmpty &&
          service.availability == FileBrowserAvailability.loading &&
          !_refreshingRoots) {
        unawaited(_refreshRoots());
      } else if (!scopeChanged) {
        setState(() {});
      }
    });
  }

  void _adoptServiceScope(FileBrowserService service) {
    if (_serviceScopeRevision == service.scopeRevision) return;
    _serviceScopeRevision = service.scopeRevision;
    _loadGeneration++;
    _previewGeneration++;
    _root = null;
    _relativePath = '';
    _directory = null;
    _directoryError = null;
    _loadingDirectory = false;
    _loadingMore = false;
    _busyNodeActions.clear();
  }

  Future<void> _refreshRoots({bool showFailure = false}) async {
    if (_refreshingRoots) return;
    _refreshingRoots = true;
    final service = _service!;
    try {
      await service.refreshRoots();
      if (!mounted) return;
      setState(() {
        _adoptServiceScope(service);
        final currentRoot = _root;
        if (currentRoot == null) return;
        FileBrowserRoot? matching;
        for (final root in service.roots) {
          if (root.rootId == currentRoot.rootId) {
            matching = root;
            break;
          }
        }
        if (matching == null) {
          _root = null;
          _relativePath = '';
          _directory = null;
          _directoryError = null;
        } else {
          _root = matching;
        }
      });
    } on FileBrowserException catch (error) {
      if (mounted) {
        setState(() {});
        if (showFailure) _showError(error);
      }
    } catch (_) {
      if (mounted) {
        setState(() {});
        if (showFailure) {
          _showSnack(FileBrowserStrings.of(context).operationFailed(''));
        }
      }
    } finally {
      _refreshingRoots = false;
      if (mounted) _scheduleServiceSync();
    }
  }

  Future<void> _openDirectory(
    FileBrowserRoot root,
    String relativePath, {
    bool refresh = false,
  }) async {
    final generation = ++_loadGeneration;
    _previewGeneration++;
    final targetChanged =
        _root?.rootId != root.rootId ||
        _relativePath != relativePath ||
        _directory?.rootId != root.rootId ||
        _directory?.relativePath != relativePath;
    setState(() {
      _root = root;
      _relativePath = relativePath;
      _loadingDirectory = true;
      _loadingMore = false;
      _directoryError = null;
      if (refresh || targetChanged) _directory = null;
    });
    try {
      final snapshot = await _service!.loadDirectory(
        rootId: root.rootId,
        relativePath: relativePath,
        showHidden: _showHidden,
        refresh: refresh,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _directory = snapshot;
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    } on FileBrowserException catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _directoryError = error.code;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _directoryError = 'unexpected_error');
    } finally {
      if (mounted && generation == _loadGeneration && _loadingDirectory) {
        setState(() => _loadingDirectory = false);
      }
    }
  }

  Future<void> _maybeLoadMore() async {
    if (!_scrollController.hasClients ||
        _scrollController.position.extentAfter > 360 ||
        _loadingMore ||
        _loadingDirectory) {
      return;
    }
    final current = _directory;
    if (current == null || !current.hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = await _service!.loadNextPage(
        current,
        showHidden: _showHidden,
      );
      if (!mounted || _directory != current) return;
      setState(() => _directory = next);
    } on FileBrowserException catch (error) {
      if (!mounted || _directory != current || _loadingDirectory) return;
      if (const {
        'directory_changed',
        'invalid_cursor',
        'cursor_expired',
      }.contains(error.code)) {
        _showSnack(FileBrowserStrings.of(context).paginationRestarted);
        await _openDirectory(_root!, _relativePath, refresh: true);
      } else {
        _showError(error);
      }
    } catch (_) {
      if (mounted && _directory == current && !_loadingDirectory) {
        _showSnack(FileBrowserStrings.of(context).operationFailed(''));
      }
    } finally {
      if (mounted && _loadingMore) setState(() => _loadingMore = false);
    }
  }

  void _handleBack() {
    _previewGeneration++;
    if (_root != null) {
      if (_relativePath.isNotEmpty) {
        final segments = _relativePath.split('/')..removeLast();
        unawaited(_openDirectory(_root!, segments.join('/')));
      } else {
        setState(() {
          _root = null;
          _relativePath = '';
          _directory = null;
          _directoryError = null;
        });
      }
      return;
    }
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _toggleCurrentPin() async {
    final root = _root;
    if (root == null) return;
    try {
      await _service!.togglePin(root: root, relativePath: _relativePath);
    } on FileBrowserException catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _toggleNodePin(FileBrowserNode node) async {
    final root = _root;
    if (root == null) return;
    try {
      await _service!.togglePin(
        root: root,
        relativePath: node.relativePath,
        label: node.name,
      );
    } on FileBrowserException catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _removePin(FileBrowserPin pin) async {
    try {
      await _service!.removePin(pin);
    } on FileBrowserException catch (error) {
      if (mounted) _showError(error);
    } catch (_) {
      if (mounted) {
        _showSnack(FileBrowserStrings.of(context).operationFailed(''));
      }
    }
  }

  Future<void> _openNode(FileBrowserNode node) async {
    final root = _root;
    if (root == null) return;
    if (node.isDirectory) {
      final actionKey = _nodeActionKey('open', root.rootId, node.relativePath);
      if (!_beginNodeAction(actionKey)) return;
      try {
        await _openDirectory(root, node.relativePath);
      } finally {
        _endNodeAction(actionKey);
      }
      return;
    }
    if (node.canPreview) {
      await _previewNode(node);
      return;
    }
    if (node.canDownload) {
      if (!_service!.canReceiveDownloads) {
        _showSnack(_downloadUnavailableMessage(_service!, node));
        return;
      }
      _showSnack(FileBrowserStrings.of(context).previewUnavailable);
      await _downloadNode(node);
    }
  }

  Future<void> _previewNode(FileBrowserNode node) async {
    final root = _root;
    if (root == null) return;
    final service = _service!;
    final scope = service.scopeRevision;
    final originRootId = root.rootId;
    final originRelativePath = _relativePath;
    final previewGeneration = ++_previewGeneration;
    final actionKey = _nodeActionKey('preview', root.rootId, node.relativePath);
    if (!_beginNodeAction(actionKey)) return;
    FileBrowserPreview preview;
    try {
      preview = await service.preview(node, root.rootId);
    } on FileBrowserException catch (error) {
      if (mounted) _showError(error);
      return;
    } catch (_) {
      if (mounted) {
        _showSnack(FileBrowserStrings.of(context).operationFailed(''));
      }
      return;
    } finally {
      _endNodeAction(actionKey);
    }
    if (!mounted ||
        service.scopeRevision != scope ||
        previewGeneration != _previewGeneration ||
        _root?.rootId != originRootId ||
        _relativePath != originRelativePath) {
      return;
    }
    final strings = FileBrowserStrings.of(context);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ArtifactPreviewScreen(
          previewUrl: preview.previewUri,
          filename: preview.filename,
          mimeType: preview.mimeType,
          sizeBytes: preview.sizeBytes,
          expiresAt: preview.expiresAt,
          accessRefresher: () async {
            if (service.scopeRevision != scope) {
              throw const FileBrowserException('bridge_scope_changed');
            }
            final refreshed = await service.preview(node, root.rootId);
            return ArtifactPreviewAccess(
              previewUrl: refreshed.previewUri,
              expiresAt: refreshed.expiresAt,
            );
          },
          downloadUnavailableMessage: () {
            if (!node.canDownload || !service.downloadAvailable) {
              return strings.downloadUnavailable;
            }
            if (!service.hasStableConnectionIdentity) {
              return strings.downloadRequiresSavedMachine;
            }
            return null;
          },
          onDownloadRequested: node.canDownload
              ? () {
                  if (service.scopeRevision != scope) {
                    throw const FileBrowserException('bridge_scope_changed');
                  }
                  return _downloadNode(
                    node,
                    rootOverride: root,
                    expectedScope: scope,
                    showConfirmation: false,
                    propagateError: true,
                  );
                }
              : null,
        ),
      ),
    );
  }

  Future<void> _downloadNode(
    FileBrowserNode node, {
    FileBrowserRoot? rootOverride,
    int? expectedScope,
    bool showConfirmation = true,
    bool propagateError = false,
  }) async {
    final root = rootOverride ?? _root;
    final service = _service!;
    if (root == null ||
        (expectedScope != null && service.scopeRevision != expectedScope)) {
      final error = const FileBrowserException('bridge_scope_changed');
      if (propagateError) throw error;
      if (mounted) _showError(error);
      return;
    }
    if (!service.canReceiveDownloads) {
      final error = FileBrowserException(
        service.downloadAvailable && node.canDownload
            ? 'stable_bridge_identity_required'
            : 'download_unavailable',
      );
      if (propagateError) throw error;
      if (mounted) _showSnack(_downloadUnavailableMessage(service, node));
      return;
    }
    final actionKey = _nodeActionKey(
      'download',
      root.rootId,
      node.relativePath,
    );
    if (!_beginNodeAction(actionKey)) {
      if (propagateError) {
        throw const FileBrowserException('operation_in_progress');
      }
      return;
    }
    try {
      await service.download(node, root.rootId);
      if (mounted && showConfirmation) {
        _showSnack(FileBrowserStrings.of(context).downloadStarted);
      }
    } on FileBrowserException catch (error) {
      if (propagateError) rethrow;
      if (mounted) _showError(error);
    } catch (_) {
      if (propagateError) rethrow;
      if (mounted) {
        _showSnack(FileBrowserStrings.of(context).operationFailed(''));
      }
    } finally {
      _endNodeAction(actionKey);
    }
  }

  String _nodeActionKey(String action, String rootId, String relativePath) =>
      '$action\u0000$rootId\u0000$relativePath';

  bool _beginNodeAction(String key) {
    if (_busyNodeActions.contains(key)) return false;
    if (mounted) setState(() => _busyNodeActions.add(key));
    return true;
  }

  void _endNodeAction(String key) {
    if (!mounted || !_busyNodeActions.contains(key)) return;
    setState(() => _busyNodeActions.remove(key));
  }

  bool _isNodeBusy(String rootId, String relativePath) {
    final suffix = '\u0000$rootId\u0000$relativePath';
    return _busyNodeActions.any((key) => key.endsWith(suffix));
  }

  void _showError(FileBrowserException error) {
    _showSnack(FileBrowserStrings.of(context).operationFailed(error.message));
  }

  String _downloadUnavailableMessage(
    FileBrowserService service,
    FileBrowserNode node,
  ) {
    final strings = FileBrowserStrings.of(context);
    if (!node.canDownload || !service.downloadAvailable) {
      return strings.downloadUnavailable;
    }
    return strings.downloadRequiresSavedMachine;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = FileBrowserStrings.of(context);
    final shell = WorkspaceShellScreen.maybeOf(context);
    final chrome = resolveWorkspacePaneChrome(
      platform: Theme.of(context).platform,
      isAdaptiveWorkspace: shell != null && !shell.isSinglePane,
      isLeftPaneVisible: shell?.isLeftPaneVisible ?? false,
      slot: WorkspacePaneSlot.center,
    );
    final service = context.watch<FileBrowserService>();
    final hasLocalBack = _root != null;
    final leading = hasLocalBack || widget.onBack != null
        ? IconButton(
            key: const ValueKey('file_browser_back_button'),
            onPressed: _handleBack,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            style: chrome.useMacOSAdaptiveChrome
                ? chrome.compactButtonStyle()
                : null,
            icon: const Icon(Icons.arrow_back),
          )
        : null;

    final appBar = chrome.wrapAppBar(
      AppBar(
        toolbarHeight: chrome.toolbarHeight,
        automaticallyImplyLeading: !widget.embedded,
        leading: chrome.wrapLeading(leading),
        leadingWidth: chrome.resolveLeadingWidth(
          hasLeading: leading != null,
          baseWidth: chrome.useMacOSAdaptiveChrome
              ? kWorkspaceMacOSToolbarLeadingSlotWidth
              : kToolbarHeight,
        ),
        titleSpacing: chrome.resolveTitleSpacing(hasLeading: leading != null),
        title: chrome.wrapTitle(
          Text(
            _root == null
                ? strings.title
                : _directoryTitle(_root!, _relativePath),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        actions: chrome.padActions([
          if (_root != null)
            IconButton(
              key: const ValueKey('file_browser_pin_button'),
              onPressed: service.canPersistPins ? _toggleCurrentPin : null,
              tooltip: !service.canPersistPins
                  ? strings.pinRequiresSavedMachine
                  : service.isPinned(_root!.rootId, _relativePath)
                  ? strings.unpinFolder
                  : strings.pinFolder,
              icon: Icon(
                service.isPinned(_root!.rootId, _relativePath)
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
              ),
            ),
          if (_root != null)
            IconButton(
              key: const ValueKey('file_browser_hidden_button'),
              onPressed: () {
                setState(() => _showHidden = !_showHidden);
                unawaited(_openDirectory(_root!, _relativePath, refresh: true));
              },
              tooltip: _showHidden ? strings.hideHidden : strings.showHidden,
              icon: Icon(_showHidden ? Icons.visibility_off : Icons.visibility),
            ),
          IconButton(
            key: const ValueKey('file_browser_refresh_button'),
            onPressed: service.isConnected && service.supportedByBridge
                ? () => _root == null
                      ? unawaited(_refreshRoots(showFailure: true))
                      : unawaited(
                          _openDirectory(_root!, _relativePath, refresh: true),
                        )
                : null,
            tooltip: strings.refresh,
            icon: const Icon(Icons.refresh),
          ),
          if (widget.embedded && widget.onClose != null)
            IconButton(
              key: const ValueKey('file_browser_close_button'),
              onPressed: widget.onClose,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: const Icon(Icons.close),
            ),
        ]),
      ),
    );

    return PopScope<void>(
      canPop: _root == null && widget.onBack == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(appBar: appBar, body: _buildBody(service, strings)),
    );
  }

  Widget _buildBody(FileBrowserService service, FileBrowserStrings strings) {
    if (!service.isConnected) {
      return _StatusState(
        icon: Icons.cloud_off_outlined,
        title: strings.disconnected,
      );
    }
    if (!service.supportedByBridge ||
        service.availability == FileBrowserAvailability.unsupported) {
      return _StatusState(
        icon: Icons.system_update_alt,
        title: strings.updateBridgeTitle,
        body: strings.updateBridgeBody,
      );
    }
    if (_root == null) {
      if (service.roots.isEmpty &&
          service.availability == FileBrowserAvailability.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (service.roots.isEmpty &&
          service.availability == FileBrowserAvailability.error) {
        return _StatusState(
          icon: Icons.folder_off_outlined,
          title: strings.loadFailed,
          actionLabel: AppLocalizations.of(context).retry,
          onAction: _refreshRoots,
        );
      }
      if (service.roots.isEmpty) {
        return _StatusState(
          icon: Icons.folder_off_outlined,
          title: strings.noLocations,
          body: strings.noLocationsBody,
        );
      }
      return _buildRootList(service, strings);
    }
    return _buildDirectory(service, strings);
  }

  Widget _buildRootList(
    FileBrowserService service,
    FileBrowserStrings strings,
  ) {
    final pins = service.currentPins;
    return RefreshIndicator(
      onRefresh: () => _refreshRoots(showFailure: true),
      child: ListView(
        key: const ValueKey('file_browser_root_list'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          if (pins.isNotEmpty) ...[
            _SectionTitle(strings.pinned),
            Card(
              margin: const EdgeInsets.only(bottom: 20),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var index = 0; index < pins.length; index++) ...[
                    _PinnedTile(
                      pin: pins[index],
                      root: _rootForPin(service, pins[index]),
                      onOpen: (root) =>
                          _openDirectory(root, pins[index].relativePath),
                      onUnpin: () => _removePin(pins[index]),
                    ),
                    if (index != pins.length - 1) const Divider(height: 1),
                  ],
                ],
              ),
            ),
          ],
          _SectionTitle(strings.locations),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var index = 0; index < service.roots.length; index++) ...[
                  ListTile(
                    key: ValueKey(
                      'file_browser_root_${service.roots[index].rootId}',
                    ),
                    leading: const _RoundedLeadingIcon(
                      icon: Icons.computer_outlined,
                    ),
                    title: Text(service.roots[index].label),
                    subtitle: Text(service.roots[index].displayPath),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openDirectory(service.roots[index], ''),
                  ),
                  if (index != service.roots.length - 1)
                    const Divider(height: 1, indent: 72),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDirectory(
    FileBrowserService service,
    FileBrowserStrings strings,
  ) {
    final directory = _directory;
    if (_loadingDirectory && directory == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_directoryError != null && directory == null) {
      return _StatusState(
        icon: Icons.folder_off_outlined,
        title: strings.loadFailed,
        actionLabel: AppLocalizations.of(context).retry,
        onAction: () => _openDirectory(_root!, _relativePath, refresh: true),
      );
    }
    final entries = directory?.entries ?? const <FileBrowserNode>[];
    final truncated = directory?.truncated ?? false;
    final contentCount = entries.isEmpty ? 1 : entries.length;
    final truncatedIndex = 1 + contentCount;
    final loadingIndex = truncatedIndex + (truncated ? 1 : 0);
    return RefreshIndicator(
      onRefresh: () => _openDirectory(_root!, _relativePath, refresh: true),
      child: ListView.builder(
        key: ValueKey('file_browser_directory_${_root!.rootId}_$_relativePath'),
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        itemCount:
            1 + contentCount + (truncated ? 1 : 0) + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == 0) return _buildBreadcrumbs();
          if (index == 1 && entries.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 96, horizontal: 24),
              child: Column(
                children: [
                  Icon(
                    Icons.folder_open_outlined,
                    size: 52,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 14),
                  Text(strings.emptyFolder),
                ],
              ),
            );
          }
          if (truncated && index == truncatedIndex) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                strings.directoryLimitReached,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          if (_loadingMore && index == loadingIndex) {
            return const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final entryIndex = index - 1;
          if (entryIndex < 0 || entryIndex >= entries.length) {
            return const SizedBox.shrink();
          }
          final node = entries[entryIndex];
          return _FileNodeTile(
            node: node,
            isBusy: _isNodeBusy(_root!.rootId, node.relativePath),
            isPinned: service.isPinned(_root!.rootId, node.relativePath),
            onOpen: () => _openNode(node),
            onDownload: node.canDownload ? () => _downloadNode(node) : null,
            onTogglePin: node.isDirectory && service.canPersistPins
                ? () => _toggleNodePin(node)
                : null,
          );
        },
      ),
    );
  }

  Widget _buildBreadcrumbs() {
    final root = _root!;
    final segments = _relativePath.isEmpty
        ? const <String>[]
        : _relativePath.split('/');
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: segments.length + 1,
          separatorBuilder: (_, _) => const Icon(Icons.chevron_right, size: 18),
          itemBuilder: (context, index) {
            final path = index == 0 ? '' : segments.take(index).join('/');
            final label = index == 0 ? root.label : segments[index - 1];
            final selected = index == segments.length;
            return TextButton(
              onPressed: selected ? null : () => _openDirectory(root, path),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 36),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: selected
                    ? TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      )
                    : null,
              ),
            );
          },
        ),
      ),
    );
  }

  FileBrowserRoot? _rootForPin(FileBrowserService service, FileBrowserPin pin) {
    for (final root in service.roots) {
      if (root.rootId == pin.rootId) return root;
    }
    return null;
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

class _PinnedTile extends StatelessWidget {
  final FileBrowserPin pin;
  final FileBrowserRoot? root;
  final ValueChanged<FileBrowserRoot> onOpen;
  final VoidCallback onUnpin;

  const _PinnedTile({
    required this.pin,
    required this.root,
    required this.onOpen,
    required this.onUnpin,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    leading: _RoundedLeadingIcon(icon: _commonPinIcon(pin.relativePath)),
    title: Text(
      _pinDisplayLabel(context, pin),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      pin.relativePath.isEmpty
          ? pin.rootLabel
          : '${pin.rootLabel} / ${pin.relativePath}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    onTap: root == null ? null : () => onOpen(root!),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (root == null) const Icon(Icons.link_off_outlined),
        IconButton(
          key: ValueKey('file_browser_unpin_${pin.rootId}_${pin.relativePath}'),
          tooltip: FileBrowserStrings.of(context).unpinFolder,
          onPressed: onUnpin,
          icon: const Icon(Icons.push_pin),
        ),
      ],
    ),
  );
}

String _pinDisplayLabel(BuildContext context, FileBrowserPin pin) {
  if (pin.label == pin.relativePath) {
    return FileBrowserStrings.of(context).commonFolderLabel(pin.relativePath);
  }
  return pin.label;
}

IconData _commonPinIcon(String relativePath) => switch (relativePath) {
  'Desktop' => Icons.desktop_mac_outlined,
  'Downloads' => Icons.download_outlined,
  'Documents' => Icons.description_outlined,
  _ => Icons.folder_outlined,
};

class _FileNodeTile extends StatelessWidget {
  final FileBrowserNode node;
  final bool isBusy;
  final bool isPinned;
  final VoidCallback onOpen;
  final VoidCallback? onDownload;
  final VoidCallback? onTogglePin;

  const _FileNodeTile({
    required this.node,
    required this.isBusy,
    required this.isPinned,
    required this.onOpen,
    required this.onDownload,
    required this.onTogglePin,
  });

  @override
  Widget build(BuildContext context) {
    final strings = FileBrowserStrings.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          key: ValueKey('file_browser_node_${node.relativePath}'),
          contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          leading: _RoundedLeadingIcon(icon: _iconForNode(node)),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  node.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (node.isSymlink) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.link,
                  size: 15,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
          subtitle: _nodeSubtitle(node),
          onTap: !isBusy && (node.canOpen || node.canDownload) ? onOpen : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isBusy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (onTogglePin != null)
                IconButton(
                  tooltip: isPinned ? strings.unpinFolder : strings.pinFolder,
                  onPressed: onTogglePin,
                  icon: Icon(
                    isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 20,
                  ),
                ),
              if (!isBusy && onDownload != null)
                IconButton(
                  key: ValueKey('file_browser_download_${node.relativePath}'),
                  tooltip: AppLocalizations.of(context).download,
                  onPressed: onDownload,
                  icon: const Icon(Icons.download_outlined, size: 21),
                ),
              if (!isBusy && node.isDirectory)
                const Icon(Icons.chevron_right)
              else if (!isBusy && node.canPreview)
                const Icon(Icons.visibility_outlined, size: 20),
            ],
          ),
        ),
        const Divider(height: 1, indent: 72),
      ],
    );
  }
}

class _RoundedLeadingIcon extends StatelessWidget {
  final IconData icon;

  const _RoundedLeadingIcon({required this.icon});

  @override
  Widget build(BuildContext context) => Container(
    width: 42,
    height: 42,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    alignment: Alignment.center,
    child: Icon(
      icon,
      size: 23,
      color: Theme.of(context).colorScheme.onSecondaryContainer,
    ),
  );
}

class _StatusState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final FutureOr<void> Function()? onAction;

  const _StatusState({
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => onAction!(),
                icon: const Icon(Icons.refresh),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

String _directoryTitle(FileBrowserRoot root, String relativePath) {
  if (relativePath.isEmpty) return root.label;
  return relativePath.split('/').last;
}

IconData _iconForNode(FileBrowserNode node) {
  if (node.isDirectory) return Icons.folder_outlined;
  return switch (node.previewKind) {
    'image' => Icons.image_outlined,
    'pdf' => Icons.picture_as_pdf_outlined,
    'text' || 'markdown' || 'code' => Icons.description_outlined,
    'audio' => Icons.audio_file_outlined,
    'video' => Icons.video_file_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

Widget? _nodeSubtitle(FileBrowserNode node) {
  final labels = <String>[];
  final size = node.sizeBytes;
  if (size != null) labels.add(_formatFileSize(size));
  final modifiedAt = DateTime.tryParse(node.modifiedAt ?? '');
  if (modifiedAt != null) {
    labels.add(
      '${modifiedAt.toLocal().year}-${modifiedAt.toLocal().month.toString().padLeft(2, '0')}-${modifiedAt.toLocal().day.toString().padLeft(2, '0')}',
    );
  }
  return labels.isEmpty
      ? null
      : Text(labels.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis);
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
