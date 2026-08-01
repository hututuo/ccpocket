import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../models/messages.dart';
import '../../../../services/bridge_service.dart';
import '../../subagents/state/subagents_controller.dart';
import '../../subagents/widgets/subagents_panel.dart';
import '../l10n/side_chat_strings.dart';
import '../state/ephemeral_side_chat_registry_service.dart';

typedef OpenAuxiliarySideChat =
    Future<void> Function(
      String parentSessionId,
      String parentProviderSessionId,
      EphemeralSideChatEntry? entry,
    );

enum _DockEdge { left, right }

/// A lightweight in-app handle for live auxiliary work.
///
/// It has no ticker and owns no transcript state. The collapsed handle can
/// rest freely and docks half off an edge only after it is dragged far enough
/// outside the viewport. Expanding creates an in-tree panel without a route,
/// barrier, or modal surface, so the surrounding conversation stays usable.
class AuxiliaryFloatingDock extends StatefulWidget {
  const AuxiliaryFloatingDock({
    super.key,
    required this.sessionId,
    this.parentProviderSessionId,
    required this.bridgeService,
    required this.registryService,
    required this.onOpenSideChat,
    this.legacyRuntimeParentSessionId,
    this.detachedSubagentsProviderThreadId,
    this.detachedSubagentsCodexSourceId,
  });

  final String sessionId;
  final String? parentProviderSessionId;
  final BridgeService bridgeService;
  final EphemeralSideChatRegistryService registryService;
  final OpenAuxiliarySideChat onOpenSideChat;

  /// Runtime parent identity required only by an older Bridge that cannot
  /// resolve the durable provider thread identity. A detached durable page may
  /// legitimately have no such attachment yet.
  final String? legacyRuntimeParentSessionId;
  final String? detachedSubagentsProviderThreadId;
  final String? detachedSubagentsCodexSourceId;

  @override
  State<AuxiliaryFloatingDock> createState() => _AuxiliaryFloatingDockState();
}

class _AuxiliaryFloatingDockState extends State<AuxiliaryFloatingDock> {
  static const _handleEdgePreference = 'auxiliary_floating_dock_handle_edge_v1';
  static const _handleHiddenPreference =
      'auxiliary_floating_dock_handle_hidden_v1';
  static const _handleLeftPreference = 'auxiliary_floating_dock_handle_left_v1';
  static const _handleTopPreference = 'auxiliary_floating_dock_handle_top_v1';
  static const _panelEdgePreference = 'auxiliary_floating_dock_panel_edge_v1';
  static const _panelLeftPreference = 'auxiliary_floating_dock_panel_left_v1';
  static const _panelTopPreference = 'auxiliary_floating_dock_panel_top_v1';
  static const _handleSize = 48.0;
  static const _visibleInset = 12.0;
  static const _hiddenInset = 24.0;
  static const _panelPullWidth = 44.0;
  static const _panelInset = 10.0;
  static const _panelMaxWidth = 360.0;
  static const _panelMaxHeight = 520.0;
  static const _dockThresholdFraction = 0.25;
  double? _handleLeft;
  double? _handleTop;
  double? _panelLeft;
  double? _panelTop;
  Size _lastSize = Size.zero;
  _DockEdge _handleEdge = _DockEdge.right;
  _DockEdge? _panelHiddenEdge;
  double _handleLeftFraction = 1;
  double _handleTopFraction = 0.42;
  double _panelLeftFraction = 1;
  double _panelTopFraction = 0.42;
  bool _handleHidden = false;
  bool _hasPanelPlacement = false;
  bool _positionTouched = false;
  bool _expanded = false;
  bool _dragging = false;
  late SubagentsController _subagentsController;
  int _lastSubagentActiveCount = 0;

  @override
  void initState() {
    super.initState();
    widget.registryService.addListener(_registryChanged);
    _subagentsController = _createSubagentsController()
      ..addListener(_subagentsChanged);
    _lastSubagentActiveCount = _subagentsController.activeCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _subagentsController.refresh();
    });
    unawaited(_restorePlacement());
  }

  @override
  void didUpdateWidget(covariant AuxiliaryFloatingDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registryService != widget.registryService) {
      oldWidget.registryService.removeListener(_registryChanged);
      widget.registryService.addListener(_registryChanged);
    }
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.bridgeService != widget.bridgeService ||
        oldWidget.detachedSubagentsProviderThreadId !=
            widget.detachedSubagentsProviderThreadId ||
        oldWidget.detachedSubagentsCodexSourceId !=
            widget.detachedSubagentsCodexSourceId) {
      _subagentsController.removeListener(_subagentsChanged);
      _subagentsController.dispose();
      _subagentsController = _createSubagentsController()
        ..addListener(_subagentsChanged)
        ..setDetailsVisible(_expanded)
        ..refresh();
      _lastSubagentActiveCount = _subagentsController.activeCount;
    }
  }

  SubagentsController _createSubagentsController() => SubagentsController(
    sessionId: widget.sessionId,
    bridge: widget.bridgeService,
    detachedProviderThreadId: widget.detachedSubagentsProviderThreadId,
    detachedCodexSourceId: widget.detachedSubagentsCodexSourceId,
  );

  void _registryChanged() {
    if (mounted) setState(() {});
  }

  void _subagentsChanged() {
    final next = _subagentsController.activeCount;
    if (next == _lastSubagentActiveCount) return;
    _lastSubagentActiveCount = next;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.registryService.removeListener(_registryChanged);
    _subagentsController.setDetailsVisible(false);
    _subagentsController.removeListener(_subagentsChanged);
    _subagentsController.dispose();
    super.dispose();
  }

  Future<void> _restorePlacement() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted || _positionTouched) return;
      final hasStoredPlacement =
          preferences.containsKey(_handleEdgePreference) ||
          preferences.containsKey(_handleHiddenPreference) ||
          preferences.containsKey(_handleLeftPreference) ||
          preferences.containsKey(_handleTopPreference) ||
          preferences.containsKey(_panelEdgePreference) ||
          preferences.containsKey(_panelLeftPreference) ||
          preferences.containsKey(_panelTopPreference);
      if (!hasStoredPlacement) return;
      final handleEdge = _edgeFromPreference(
        preferences.getString(_handleEdgePreference),
      );
      final panelEdge = _edgeFromPreference(
        preferences.getString(_panelEdgePreference),
      );
      final handleTop = _validFraction(
        preferences.getDouble(_handleTopPreference),
        _handleTopFraction,
      );
      final handleLeft = _validFraction(
        preferences.getDouble(_handleLeftPreference),
        handleEdge == _DockEdge.left ? 0 : _handleLeftFraction,
      );
      final panelLeft = _validFraction(
        preferences.getDouble(_panelLeftPreference),
        _panelLeftFraction,
      );
      final panelTop = _validFraction(
        preferences.getDouble(_panelTopPreference),
        _panelTopFraction,
      );
      setState(() {
        _handleEdge = handleEdge ?? _handleEdge;
        _handleHidden =
            preferences.getBool(_handleHiddenPreference) ?? _handleHidden;
        _handleLeftFraction = handleLeft;
        _handleTopFraction = handleTop;
        _panelHiddenEdge = panelEdge;
        _panelLeftFraction = panelLeft;
        _panelTopFraction = panelTop;
        _hasPanelPlacement =
            panelEdge != null ||
            preferences.containsKey(_panelLeftPreference) ||
            preferences.containsKey(_panelTopPreference);
        _lastSize = Size.zero;
      });
    } catch (_) {
      // Placement persistence is an optional convenience. The dock remains
      // fully usable with deterministic defaults if preferences are missing.
    }
  }

  Future<void> _persistPlacement() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await Future.wait([
        preferences.setString(_handleEdgePreference, _handleEdge.name),
        preferences.setBool(_handleHiddenPreference, _handleHidden),
        preferences.setDouble(_handleLeftPreference, _handleLeftFraction),
        preferences.setDouble(_handleTopPreference, _handleTopFraction),
        preferences.setDouble(_panelLeftPreference, _panelLeftFraction),
        preferences.setDouble(_panelTopPreference, _panelTopFraction),
        if (_panelHiddenEdge case final edge?)
          preferences.setString(_panelEdgePreference, edge.name)
        else
          preferences.remove(_panelEdgePreference),
      ]);
    } catch (_) {
      // A failed preference write must never block the conversation UI.
    }
  }

  static _DockEdge? _edgeFromPreference(String? value) => switch (value) {
    'left' => _DockEdge.left,
    'right' => _DockEdge.right,
    _ => null,
  };

  static double _validFraction(double? value, double fallback) {
    if (value == null || !value.isFinite) return fallback;
    return value.clamp(0.0, 1.0);
  }

  static double _positionFromFraction(
    double fraction,
    double minimum,
    double maximum,
  ) {
    if (maximum <= minimum) return minimum;
    return minimum + ((maximum - minimum) * fraction.clamp(0.0, 1.0));
  }

  static double _positionFraction(
    double value,
    double minimum,
    double maximum,
  ) {
    if (maximum <= minimum) return 0;
    return ((value - minimum) / (maximum - minimum)).clamp(0.0, 1.0);
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
    final minHandleLeft = _visibleInset;
    final maxHandleLeft = math.max(
      minHandleLeft,
      size.width - _handleSize - _visibleInset,
    );
    final maxHandleTop = (size.height - _handleSize - 8).clamp(
      8.0,
      size.height,
    );
    _handleLeft = _handleHidden
        ? switch (_handleEdge) {
            _DockEdge.left => -_hiddenInset,
            _DockEdge.right => size.width - _handleSize + _hiddenInset,
          }
        : _positionFromFraction(
            _handleLeftFraction,
            minHandleLeft,
            maxHandleLeft,
          );
    _handleTop = _positionFromFraction(_handleTopFraction, 8, maxHandleTop);
    final maxPanelLeft = math.max(
      _panelInset,
      size.width - panelSize.width - _panelInset,
    );
    _panelLeft = switch (_panelHiddenEdge) {
      _DockEdge.left => -panelSize.width + _panelPullWidth,
      _DockEdge.right => size.width - _panelPullWidth,
      null => _positionFromFraction(
        _panelLeftFraction,
        _panelInset,
        maxPanelLeft,
      ),
    };
    _panelTop = _positionFromFraction(
      _panelTopFraction,
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
      _positionTouched = true;
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
      final currentLeft = _handleLeft ?? _visibleInset;
      final leftOverflow = math.max(0.0, -currentLeft);
      final rightOverflow = math.max(
        0.0,
        currentLeft + _handleSize - size.width,
      );
      final threshold = _handleSize * _dockThresholdFraction;
      final minHandleLeft = _visibleInset;
      final maxHandleLeft = math.max(
        minHandleLeft,
        size.width - _handleSize - _visibleInset,
      );
      if (leftOverflow >= threshold) {
        _handleEdge = _DockEdge.left;
        _handleHidden = true;
        _handleLeft = -_hiddenInset;
      } else if (rightOverflow >= threshold) {
        _handleEdge = _DockEdge.right;
        _handleHidden = true;
        _handleLeft = size.width - _handleSize + _hiddenInset;
      } else {
        _handleHidden = false;
        _handleLeft = currentLeft.clamp(minHandleLeft, maxHandleLeft);
        _handleEdge = (_handleLeft! + (_handleSize / 2)) < size.width / 2
            ? _DockEdge.left
            : _DockEdge.right;
      }
      _handleLeftFraction = _positionFraction(
        _handleLeft!.clamp(minHandleLeft, maxHandleLeft),
        minHandleLeft,
        maxHandleLeft,
      );
      _handleTopFraction = _positionFraction(
        _handleTop ?? 0,
        8,
        (size.height - _handleSize - 8).clamp(8.0, size.height),
      );
    });
    unawaited(_persistPlacement());
  }

  void _expand() {
    final size = _lastSize;
    if (size.isEmpty) return;
    _subagentsController.setDetailsVisible(true);
    _subagentsController.refresh();
    final panelSize = _panelSize(size);
    final handleCenter = (_handleLeft ?? 0) + (_handleSize / 2);
    setState(() {
      _expanded = true;
      _dragging = false;
      if (!_hasPanelPlacement) {
        _panelHiddenEdge = null;
        _panelLeft = handleCenter < size.width / 2
            ? _panelInset
            : math.max(_panelInset, size.width - panelSize.width - _panelInset);
        _panelTop = (_handleTop ?? 0).clamp(
          _panelInset,
          math.max(_panelInset, size.height - panelSize.height - _panelInset),
        );
        _panelLeftFraction = _positionFraction(
          _panelLeft!,
          _panelInset,
          math.max(_panelInset, size.width - panelSize.width - _panelInset),
        );
        _panelTopFraction = _positionFraction(
          _panelTop!,
          _panelInset,
          math.max(_panelInset, size.height - panelSize.height - _panelInset),
        );
        _hasPanelPlacement = true;
      }
    });
  }

  void _collapse() {
    final size = _lastSize;
    if (size.isEmpty) return;
    _subagentsController.setDetailsVisible(false);
    setState(() {
      _expanded = false;
      _dragging = false;
    });
    unawaited(_persistPlacement());
  }

  void _dragPanel(PointerMoveEvent event) {
    final size = _lastSize;
    if (size.isEmpty) return;
    final panelSize = _panelSize(size);
    setState(() {
      _positionTouched = true;
      _dragging = true;
      _panelLeft = ((_panelLeft ?? 0) + event.delta.dx).clamp(
        -panelSize.width + _panelPullWidth,
        math.max(_panelInset, size.width - _panelPullWidth),
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
      final currentLeft = _panelLeft ?? _panelInset;
      final leftOverflow = math.max(0.0, -currentLeft);
      final rightOverflow = math.max(
        0.0,
        currentLeft + panelSize.width - size.width,
      );
      final threshold = panelSize.width * _dockThresholdFraction;
      if (leftOverflow >= threshold) {
        _panelHiddenEdge = _DockEdge.left;
        _panelLeft = -panelSize.width + _panelPullWidth;
      } else if (rightOverflow >= threshold) {
        _panelHiddenEdge = _DockEdge.right;
        _panelLeft = size.width - _panelPullWidth;
      } else {
        _panelHiddenEdge = null;
        _panelLeft = currentLeft.clamp(
          _panelInset,
          math.max(_panelInset, size.width - panelSize.width - _panelInset),
        );
      }
      _panelLeftFraction = _positionFraction(
        _panelLeft!.clamp(
          _panelInset,
          math.max(_panelInset, size.width - panelSize.width - _panelInset),
        ),
        _panelInset,
        math.max(_panelInset, size.width - panelSize.width - _panelInset),
      );
      _panelTopFraction = _positionFraction(
        _panelTop ?? _panelInset,
        _panelInset,
        math.max(_panelInset, size.height - panelSize.height - _panelInset),
      );
      _hasPanelPlacement = true;
    });
    unawaited(_persistPlacement());
  }

  Future<void> _openSideChat(
    String parentSessionId,
    String parentProviderSessionId,
    EphemeralSideChatEntry? entry,
  ) async {
    _collapse();
    await widget.onOpenSideChat(
      parentSessionId,
      parentProviderSessionId,
      entry,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _normalizePosition(size);
        final childEntry = widget.registryService.entryForChild(
          widget.sessionId,
        );
        final legacyRuntimeParentSessionId =
            widget.legacyRuntimeParentSessionId ??
            (widget.detachedSubagentsProviderThreadId == null
                ? widget.sessionId
                : null);
        final parentSessionId =
            childEntry?.parentSessionId ??
            legacyRuntimeParentSessionId ??
            widget.sessionId;
        final parentProviderSessionId =
            childEntry?.canonicalParentSessionId ??
            widget.parentProviderSessionId ??
            parentSessionId;
        final entries = widget.registryService.entriesForParent(
          parentProviderSessionId,
          legacyParentSessionId: parentSessionId,
        );
        final activeSideChatCount = entries
            .where(
              (entry) => const {
                'starting',
                'running',
                'waiting_approval',
                'compacting',
              }.contains(entry.status),
            )
            .length;
        final activeSubagentCount = _subagentsController.activeCount;
        final activeCount = activeSideChatCount + activeSubagentCount;
        final badgeCount = activeCount > 0 ? activeCount : entries.length;
        final colorScheme = Theme.of(context).colorScheme;
        final panelSize = _panelSize(size);

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
                    parentSessionId: parentSessionId,
                    parentProviderSessionId: parentProviderSessionId,
                    bridgeService: widget.bridgeService,
                    registryService: widget.registryService,
                    subagentsController: _subagentsController,
                    detachedSubagentsProviderThreadId:
                        widget.detachedSubagentsProviderThreadId,
                    detachedSubagentsCodexSourceId:
                        widget.detachedSubagentsCodexSourceId,
                    canOpenNewSideChat:
                        widget.bridgeService.bridgeCapabilities.contains(
                          ephemeralSideChatParentIdentityCapability,
                        ) ||
                        legacyRuntimeParentSessionId != null,
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
                  label: SideChatStrings.of(context).auxiliaryTasks,
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
    required this.parentSessionId,
    required this.parentProviderSessionId,
    required this.bridgeService,
    required this.registryService,
    required this.subagentsController,
    this.detachedSubagentsProviderThreadId,
    this.detachedSubagentsCodexSourceId,
    required this.canOpenNewSideChat,
    required this.onOpenSideChat,
    required this.onCollapse,
    required this.onHeaderPointerMove,
    required this.onHeaderPointerEnd,
  });

  final String currentSessionId;
  final String parentSessionId;
  final String parentProviderSessionId;
  final BridgeService bridgeService;
  final EphemeralSideChatRegistryService registryService;
  final SubagentsController subagentsController;
  final String? detachedSubagentsProviderThreadId;
  final String? detachedSubagentsCodexSourceId;
  final bool canOpenNewSideChat;
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
                        SideChatStrings.of(context).auxiliaryTasks,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('auxiliary_floating_panel_collapse'),
                    tooltip: SideChatStrings.of(context).collapse,
                    onPressed: onCollapse,
                    icon: const Icon(Icons.unfold_less),
                  ),
                ],
              ),
            ),
            TabBar(
              tabs: [
                Tab(text: SideChatStrings.of(context).sideChats),
                Tab(text: SideChatStrings.of(context).subagents),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _EphemeralSideChatList(
                    parentSessionId: parentSessionId,
                    parentProviderSessionId: parentProviderSessionId,
                    registryService: registryService,
                    canOpenNewSideChat: canOpenNewSideChat,
                    onOpen: onOpenSideChat,
                  ),
                  SubagentsPanel(
                    sessionId: currentSessionId,
                    bridgeService: bridgeService,
                    detachedProviderThreadId: detachedSubagentsProviderThreadId,
                    detachedCodexSourceId: detachedSubagentsCodexSourceId,
                    controller: subagentsController,
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
    required this.parentSessionId,
    required this.parentProviderSessionId,
    required this.registryService,
    required this.canOpenNewSideChat,
    required this.onOpen,
  });

  final String parentSessionId;
  final String parentProviderSessionId;
  final EphemeralSideChatRegistryService registryService;
  final bool canOpenNewSideChat;
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
          SnackBar(content: Text(SideChatStrings.of(context).closeFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _closingIds.remove(entry.childSessionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.registryService.entriesForParent(
      widget.parentProviderSessionId,
      legacyParentSessionId: widget.parentSessionId,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('auxiliary_new_side_chat'),
              onPressed:
                  widget.registryService.isSupported &&
                      widget.canOpenNewSideChat
                  ? () => widget.onOpen(
                      widget.parentSessionId,
                      widget.parentProviderSessionId,
                      null,
                    )
                  : null,
              icon: const Icon(Icons.add_comment_outlined),
              label: Text(SideChatStrings.of(context).newTemporarySideChat),
            ),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    SideChatStrings.of(context).noLiveSideChats,
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
                            SideChatStrings.of(context).temporarySession,
                          ),
                          subtitle: Text(
                            '${entry.status} · ${_shortProject(entry.projectPath)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: closing
                              ? null
                              : () => widget.onOpen(
                                  entry.parentSessionId,
                                  entry.canonicalParentSessionId,
                                  entry,
                                ),
                          trailing: IconButton(
                            tooltip: SideChatStrings.of(context).end,
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
