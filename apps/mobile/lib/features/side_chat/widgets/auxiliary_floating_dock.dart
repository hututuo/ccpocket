import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../models/messages.dart';
import '../../../../services/bridge_service.dart';
import '../../subagents/widgets/subagents_panel.dart';
import '../state/ephemeral_side_chat_registry_service.dart';

typedef OpenAuxiliarySideChat =
    Future<void> Function(
      String parentSessionId,
      EphemeralSideChatEntry? entry,
    );

/// A lightweight in-app handle for live auxiliary work.
///
/// It has no ticker and owns no transcript state. The collapsed handle snaps
/// half off an edge; expanding creates an in-tree panel without a route,
/// barrier, or modal surface, so the surrounding conversation stays usable.
class AuxiliaryFloatingDock extends StatefulWidget {
  const AuxiliaryFloatingDock({
    super.key,
    required this.sessionId,
    required this.bridgeService,
    required this.registryService,
    required this.onOpenSideChat,
  });

  final String sessionId;
  final BridgeService bridgeService;
  final EphemeralSideChatRegistryService registryService;
  final OpenAuxiliarySideChat onOpenSideChat;

  @override
  State<AuxiliaryFloatingDock> createState() => _AuxiliaryFloatingDockState();
}

class _AuxiliaryFloatingDockState extends State<AuxiliaryFloatingDock> {
  static const _handleSize = 48.0;
  static const _visibleInset = 12.0;
  static const _hiddenInset = 24.0;
  static const _panelInset = 10.0;
  static const _panelMaxWidth = 360.0;
  static const _panelMaxHeight = 520.0;
  double? _handleLeft;
  double? _handleTop;
  double? _panelLeft;
  double? _panelTop;
  Size _lastSize = Size.zero;
  bool _expanded = false;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    widget.registryService.addListener(_registryChanged);
  }

  @override
  void didUpdateWidget(covariant AuxiliaryFloatingDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registryService != widget.registryService) {
      oldWidget.registryService.removeListener(_registryChanged);
      widget.registryService.addListener(_registryChanged);
    }
  }

  void _registryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.registryService.removeListener(_registryChanged);
    super.dispose();
  }

  void _normalizePosition(Size size) {
    if (_lastSize == size &&
        _handleLeft != null &&
        _handleTop != null &&
        _panelLeft != null &&
        _panelTop != null) {
      return;
    }
    final panelSize = _panelSize(size);
    final currentHandleLeft =
        _handleLeft ?? size.width - _handleSize - _visibleInset;
    final currentHandleTop = _handleTop ?? (size.height * 0.42);
    _handleLeft = currentHandleLeft.clamp(
      -_hiddenInset,
      size.width - _handleSize + _hiddenInset,
    );
    _handleTop = currentHandleTop.clamp(
      8.0,
      (size.height - _handleSize - 8).clamp(8.0, size.height),
    );
    _panelLeft = (_panelLeft ?? size.width - panelSize.width - _panelInset)
        .clamp(
          _panelInset,
          math.max(_panelInset, size.width - panelSize.width - _panelInset),
        );
    _panelTop = (_panelTop ?? _handleTop!).clamp(
      _panelInset,
      math.max(_panelInset, size.height - panelSize.height - _panelInset),
    );
    _lastSize = size;
  }

  Size _panelSize(Size available) {
    final width = math.max(
      0.0,
      math.min(_panelMaxWidth, available.width - (_panelInset * 2)),
    );
    final height = math.max(
      0.0,
      math.min(_panelMaxHeight, available.height - (_panelInset * 2)),
    );
    return Size(width, height);
  }

  void _dragHandle(PointerMoveEvent event) {
    final size = _lastSize;
    if (size.isEmpty) return;
    setState(() {
      _dragging = true;
      _handleLeft = ((_handleLeft ?? 0) + event.delta.dx).clamp(
        -_hiddenInset,
        size.width - _handleSize + _hiddenInset,
      );
      _handleTop = ((_handleTop ?? 0) + event.delta.dy).clamp(
        8.0,
        (size.height - _handleSize - 8).clamp(8.0, size.height),
      );
    });
  }

  void _snapHandle() {
    final size = _lastSize;
    if (size.isEmpty) return;
    setState(() {
      _dragging = false;
      final center = (_handleLeft ?? 0) + (_handleSize / 2);
      _handleLeft = center < size.width / 2
          ? -_hiddenInset
          : size.width - _handleSize + _hiddenInset;
    });
  }

  void _expand() {
    final size = _lastSize;
    if (size.isEmpty) return;
    final panelSize = _panelSize(size);
    final handleCenter = (_handleLeft ?? 0) + (_handleSize / 2);
    setState(() {
      _expanded = true;
      _dragging = false;
      _panelLeft = handleCenter < size.width / 2
          ? _panelInset
          : math.max(
              _panelInset,
              size.width - panelSize.width - _panelInset,
            );
      _panelTop = (_handleTop ?? 0).clamp(
        _panelInset,
        math.max(_panelInset, size.height - panelSize.height - _panelInset),
      );
    });
  }

  void _collapse() {
    final size = _lastSize;
    if (size.isEmpty) return;
    final panelSize = _panelSize(size);
    final panelCenter = (_panelLeft ?? 0) + (panelSize.width / 2);
    setState(() {
      _expanded = false;
      _dragging = false;
      _handleLeft = panelCenter < size.width / 2
          ? _visibleInset
          : size.width - _handleSize - _visibleInset;
      _handleTop = (_panelTop ?? 0).clamp(
        8.0,
        (size.height - _handleSize - 8).clamp(8.0, size.height),
      );
    });
  }

  void _dragPanel(PointerMoveEvent event) {
    final size = _lastSize;
    if (size.isEmpty) return;
    final panelSize = _panelSize(size);
    setState(() {
      _dragging = true;
      _panelLeft = ((_panelLeft ?? 0) + event.delta.dx).clamp(
        _panelInset,
        math.max(_panelInset, size.width - panelSize.width - _panelInset),
      );
      _panelTop = ((_panelTop ?? 0) + event.delta.dy).clamp(
        _panelInset,
        math.max(_panelInset, size.height - panelSize.height - _panelInset),
      );
    });
  }

  void _snapPanel() {
    final size = _lastSize;
    if (size.isEmpty) return;
    final panelSize = _panelSize(size);
    setState(() {
      _dragging = false;
      final center = (_panelLeft ?? 0) + (panelSize.width / 2);
      _panelLeft = center < size.width / 2
          ? _panelInset
          : math.max(
              _panelInset,
              size.width - panelSize.width - _panelInset,
            );
    });
  }

  Future<void> _openSideChat(
    String parentSessionId,
    EphemeralSideChatEntry? entry,
  ) async {
    _collapse();
    await widget.onOpenSideChat(parentSessionId, entry);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _normalizePosition(size);
        final entries = widget.registryService.entries;
        final activeCount = entries
            .where(
              (entry) => const {
                'starting',
                'running',
                'waiting_approval',
                'compacting',
              }.contains(entry.status),
            )
            .length;
        final badgeCount = activeCount > 0 ? activeCount : entries.length;
        final colorScheme = Theme.of(context).colorScheme;
        final panelSize = _panelSize(size);
        final parentForNew =
            widget.registryService
                .entryForChild(widget.sessionId)
                ?.parentSessionId ??
            widget.sessionId;

        return Stack(
          children: [
            if (_expanded)
              Positioned(
                key: const ValueKey('auxiliary_floating_panel_position'),
                left: _panelLeft,
                top: _panelTop,
                width: panelSize.width,
                height: panelSize.height,
                child: Material(
                  key: const ValueKey('auxiliary_floating_panel'),
                  color: colorScheme.surface,
                  elevation: _dragging ? 5 : 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(color: colorScheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _AuxiliaryRegistryPanel(
                    currentSessionId: widget.sessionId,
                    parentForNew: parentForNew,
                    bridgeService: widget.bridgeService,
                    registryService: widget.registryService,
                    onOpenSideChat: _openSideChat,
                    onCollapse: _collapse,
                    onHeaderPointerMove: _dragPanel,
                    onHeaderPointerEnd: _snapPanel,
                  ),
                ),
              )
            else
              Positioned(
                key: const ValueKey('auxiliary_floating_dock_position'),
                left: _handleLeft,
                top: _handleTop,
                width: _handleSize,
                height: _handleSize,
                child: Semantics(
                  button: true,
                  label: _label(context, '辅助任务', 'Auxiliary tasks'),
                  child: Listener(
                    key: const ValueKey('auxiliary_floating_dock'),
                    behavior: HitTestBehavior.opaque,
                    onPointerMove: _dragHandle,
                    onPointerUp: (_) {
                      if (_dragging) _snapHandle();
                    },
                    onPointerCancel: (_) {
                      if (_dragging) _snapHandle();
                    },
                    child: Material(
                      color: activeCount > 0
                          ? colorScheme.primary
                          : colorScheme.secondaryContainer,
                      elevation: _dragging ? 4 : 1,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        key: const ValueKey('auxiliary_floating_dock_tap'),
                        customBorder: const CircleBorder(),
                        onTap: _expand,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Icon(
                              Icons.hub_outlined,
                              color: activeCount > 0
                                  ? colorScheme.onPrimary
                                  : colorScheme.onSecondaryContainer,
                            ),
                            if (badgeCount > 0)
                              Positioned(
                                right: 5,
                                top: 5,
                                child: Container(
                                  constraints: const BoxConstraints(
                                    minWidth: 16,
                                    minHeight: 16,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.error,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    badgeCount > 9 ? '9+' : '$badgeCount',
                                    style: TextStyle(
                                      color: colorScheme.onError,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AuxiliaryRegistryPanel extends StatelessWidget {
  const _AuxiliaryRegistryPanel({
    required this.currentSessionId,
    required this.parentForNew,
    required this.bridgeService,
    required this.registryService,
    required this.onOpenSideChat,
    required this.onCollapse,
    required this.onHeaderPointerMove,
    required this.onHeaderPointerEnd,
  });

  final String currentSessionId;
  final String parentForNew;
  final BridgeService bridgeService;
  final EphemeralSideChatRegistryService registryService;
  final OpenAuxiliarySideChat onOpenSideChat;
  final VoidCallback onCollapse;
  final PointerMoveEventListener onHeaderPointerMove;
  final VoidCallback onHeaderPointerEnd;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            Listener(
              key: const ValueKey('auxiliary_floating_panel_header'),
              behavior: HitTestBehavior.opaque,
              onPointerMove: onHeaderPointerMove,
              onPointerUp: (_) => onHeaderPointerEnd(),
              onPointerCancel: (_) => onHeaderPointerEnd(),
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 10),
                    child: Icon(Icons.drag_indicator, size: 19),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                      child: Text(
                        _label(context, '辅助任务', 'Auxiliary tasks'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('auxiliary_floating_panel_collapse'),
                    tooltip: _label(context, '收起', 'Collapse'),
                    onPressed: onCollapse,
                    icon: const Icon(Icons.unfold_less),
                  ),
                ],
              ),
            ),
            TabBar(
              tabs: [
                Tab(text: _label(context, '临时会话', 'Side chats')),
                Tab(text: _label(context, '子 Agent', 'Subagents')),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _EphemeralSideChatList(
                    parentForNew: parentForNew,
                    registryService: registryService,
                    onOpen: onOpenSideChat,
                  ),
                  SubagentsPanel(
                    sessionId: currentSessionId,
                    bridgeService: bridgeService,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EphemeralSideChatList extends StatefulWidget {
  const _EphemeralSideChatList({
    required this.parentForNew,
    required this.registryService,
    required this.onOpen,
  });

  final String parentForNew;
  final EphemeralSideChatRegistryService registryService;
  final OpenAuxiliarySideChat onOpen;

  @override
  State<_EphemeralSideChatList> createState() => _EphemeralSideChatListState();
}

class _EphemeralSideChatListState extends State<_EphemeralSideChatList> {
  final Set<String> _closingIds = {};

  @override
  void initState() {
    super.initState();
    widget.registryService.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _EphemeralSideChatList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registryService != widget.registryService) {
      oldWidget.registryService.removeListener(_changed);
      widget.registryService.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.registryService.removeListener(_changed);
    super.dispose();
  }

  Future<void> _close(EphemeralSideChatEntry entry) async {
    if (!_closingIds.add(entry.childSessionId)) return;
    setState(() {});
    try {
      await widget.registryService.close(entry.childSessionId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _label(context, '临时会话关闭失败', 'Unable to close side chat'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _closingIds.remove(entry.childSessionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.registryService.entries;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('auxiliary_new_side_chat'),
              onPressed: widget.registryService.isSupported
                  ? () => widget.onOpen(widget.parentForNew, null)
                  : null,
              icon: const Icon(Icons.add_comment_outlined),
              label: Text(
                _label(context, '新建官方临时会话', 'New temporary side chat'),
              ),
            ),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    _label(context, '暂无正在保留的临时会话', 'No live side chats'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: widget.registryService.refresh,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final closing = _closingIds.contains(
                        entry.childSessionId,
                      );
                      final running = const {
                        'starting',
                        'running',
                        'waiting_approval',
                        'compacting',
                      }.contains(entry.status);
                      return Card(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          key: ValueKey(
                            'auxiliary_side_chat_${entry.childSessionId}',
                          ),
                          leading: Icon(
                            running
                                ? Icons.motion_photos_on_outlined
                                : Icons.chat_bubble_outline,
                            color: running
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                          ),
                          title: Text(
                            _label(context, '临时会话', 'Temporary side chat'),
                          ),
                          subtitle: Text(
                            '${entry.status} · ${_shortProject(entry.projectPath)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: closing
                              ? null
                              : () =>
                                    widget.onOpen(entry.parentSessionId, entry),
                          trailing: IconButton(
                            tooltip: _label(context, '结束', 'End'),
                            onPressed: closing ? null : () => _close(entry),
                            icon: closing
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.close),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

String _shortProject(String path) {
  final normalized = path.replaceAll('\\', '/');
  final pieces = normalized.split('/').where((piece) => piece.isNotEmpty);
  return pieces.isEmpty ? path : pieces.last;
}

String _label(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
