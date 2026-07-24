import 'dart:async';

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
/// It has no ticker and owns no transcript state. Dragging snaps it half off
/// the nearest edge; tapping a hidden handle reveals it before opening.
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
  static const _size = 48.0;
  static const _visibleInset = 12.0;
  static const _hiddenInset = 24.0;
  double? _left;
  double? _top;
  Size _lastSize = Size.zero;
  bool _hidden = false;
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
    if (_lastSize == size && _left != null && _top != null) return;
    final currentLeft = _left ?? size.width - _size - _visibleInset;
    final currentTop = _top ?? (size.height * 0.42);
    _left = currentLeft.clamp(-_hiddenInset, size.width - _size + _hiddenInset);
    _top = currentTop.clamp(
      8.0,
      (size.height - _size - 8).clamp(8.0, size.height),
    );
    _lastSize = size;
  }

  void _drag(PointerMoveEvent event) {
    final size = _lastSize;
    if (size.isEmpty) return;
    setState(() {
      _dragging = true;
      _hidden = false;
      _left = ((_left ?? 0) + event.delta.dx).clamp(
        -_hiddenInset,
        size.width - _size + _hiddenInset,
      );
      _top = ((_top ?? 0) + event.delta.dy).clamp(
        8.0,
        (size.height - _size - 8).clamp(8.0, size.height),
      );
    });
  }

  void _snap() {
    final size = _lastSize;
    if (size.isEmpty) return;
    setState(() {
      _dragging = false;
      _hidden = true;
      final center = (_left ?? 0) + (_size / 2);
      _left = center < size.width / 2
          ? -_hiddenInset
          : size.width - _size + _hiddenInset;
    });
  }

  void _tap() {
    if (_hidden) {
      final size = _lastSize;
      setState(() {
        _hidden = false;
        final onLeft = ((_left ?? 0) + (_size / 2)) < size.width / 2;
        _left = onLeft ? _visibleInset : size.width - _size - _visibleInset;
      });
      return;
    }
    unawaited(_showRegistry());
  }

  Future<void> _showRegistry() async {
    final registry = widget.registryService;
    final parentForNew =
        registry.entryForChild(widget.sessionId)?.parentSessionId ??
        widget.sessionId;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.86,
        child: _AuxiliaryRegistrySheet(
          currentSessionId: widget.sessionId,
          parentForNew: parentForNew,
          bridgeService: widget.bridgeService,
          registryService: registry,
          onOpenSideChat: (parentSessionId, entry) async {
            Navigator.of(sheetContext).pop();
            await widget.onOpenSideChat(parentSessionId, entry);
          },
        ),
      ),
    );
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

        return Stack(
          children: [
            Positioned(
              key: const ValueKey('auxiliary_floating_dock_position'),
              left: _left,
              top: _top,
              width: _size,
              height: _size,
              child: Semantics(
                button: true,
                label: _label(context, '辅助任务', 'Auxiliary tasks'),
                child: Listener(
                  key: const ValueKey('auxiliary_floating_dock'),
                  behavior: HitTestBehavior.opaque,
                  onPointerMove: _drag,
                  onPointerUp: (_) {
                    if (_dragging) _snap();
                  },
                  onPointerCancel: (_) {
                    if (_dragging) _snap();
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
                      onTap: _tap,
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

class _AuxiliaryRegistrySheet extends StatelessWidget {
  const _AuxiliaryRegistrySheet({
    required this.currentSessionId,
    required this.parentForNew,
    required this.bridgeService,
    required this.registryService,
    required this.onOpenSideChat,
  });

  final String currentSessionId;
  final String parentForNew;
  final BridgeService bridgeService;
  final EphemeralSideChatRegistryService registryService;
  final OpenAuxiliarySideChat onOpenSideChat;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                    child: Text(
                      _label(context, '辅助任务', 'Auxiliary tasks'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
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
