import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'claude_effort_motion_style.dart';

/// The easing used by the Codex Desktop effort and speed controls.
const Curve codexDesktopMotionCurve = Cubic(0.23, 1, 0.32, 1);

final TweenSequence<double> _fastSelectionScale = TweenSequence<double>([
  TweenSequenceItem(tween: Tween(begin: 0.80, end: 1.15), weight: 58),
  TweenSequenceItem(tween: Tween(begin: 1.15, end: 1.0), weight: 42),
]);

/// Stable geometry for the effort control. Keeping these values together makes
/// the visual contract easy to test without relying on device screenshots.
abstract final class CodexEffortMotionMetrics {
  static const double interactionHeight = 48;
  static const double trackHeight = 24;
  static const double trackRadius = 12;
  static const double trackOuterInset = 3;
  static const double thumbDiameter = 28;
  static const double activeThumbDiameter = 32;
  static const double tickDiameter = 4;
  static const double maxVisualThumbRadius =
      activeThumbDiameter / 2 * 1.16 * 1.15;
}

bool codexMotionDisabled(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  return media?.disableAnimations == true ||
      media?.accessibleNavigation == true;
}

double _clampUnit(double value) => value.clamp(0.0, 1.0).toDouble();

double _normalizedIndex(int index, int count) {
  if (count < 2) return 0;
  return index.clamp(0, count - 1) / (count - 1);
}

double _safeThumbRadius(double width) => math.min(
  CodexEffortMotionMetrics.maxVisualThumbRadius,
  math.max(0, width) / 2,
);

double _positionX(double position, double width, TextDirection direction) {
  final inset = _safeThumbRadius(width);
  final usable = math.max(0.0, width - inset * 2);
  final visual = direction == TextDirection.rtl
      ? 1 - _clampUnit(position)
      : _clampUnit(position);
  return inset + usable * visual;
}

Rect _trackRectForSize(Size size) {
  final inset = math.min(
    CodexEffortMotionMetrics.trackOuterInset,
    math.max(0, size.width) / 2,
  );
  return Rect.fromLTWH(
    inset,
    size.height / 2 - CodexEffortMotionMetrics.trackHeight / 2,
    math.max(0, size.width - inset * 2),
    CodexEffortMotionMetrics.trackHeight,
  );
}

bool _selectsSemanticIndex(CodexEffortMotionSlider widget, int? semanticIndex) {
  if (semanticIndex == null ||
      semanticIndex < 0 ||
      semanticIndex >= widget.labels.length ||
      widget.labels.isEmpty) {
    return false;
  }
  return widget.selectedIndex.clamp(0, widget.labels.length - 1) ==
      semanticIndex;
}

enum _EffortMotion {
  idle,
  move,
  xHighReveal,
  maxReveal,
  ultraReveal,
  fastEnter,
  fastExit,
  drag,
  thumb,
}

/// A discrete, self-painted effort slider modelled after the Codex Desktop
/// control. It owns one finite [AnimationController]; no animation repeats.
class CodexEffortMotionSlider extends StatefulWidget {
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final String sliderKey;
  final int? xHighIndex;
  final int? maxIndex;
  final int? ultraIndex;
  final bool fastModeEnabled;

  const CodexEffortMotionSlider({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    required this.sliderKey,
    this.xHighIndex,
    this.maxIndex,
    this.ultraIndex,
    this.fastModeEnabled = false,
  });

  @override
  State<CodexEffortMotionSlider> createState() =>
      _CodexEffortMotionSliderState();
}

class _CodexEffortMotionSliderState extends State<CodexEffortMotionSlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final FocusNode _focusNode;
  _EffortMotion _motion = _EffortMotion.idle;
  double _fromPosition = 0;
  double _toPosition = 0;
  double _fromThumb = 0;
  double _toThumb = 0;
  late double _fromFast;
  late double _toFast;
  double _maxPositionInterval = 0.15;
  double _maxThumbInterval = 0.11;
  bool _pressed = false;
  bool _hovered = false;
  bool _showFocus = false;
  bool _reduceMotion = false;
  int? _locallyRequestedIndex;
  int? _dragStartedIndex;
  int? _dragLastEmittedIndex;
  bool _didScheduleInitialTierReveal = false;

  int get _count => widget.labels.length;

  int get _selectedIndex =>
      _count == 0 ? 0 : widget.selectedIndex.clamp(0, _count - 1);

  ClaudeEffortAccent _accentForIndex(int index) =>
      ClaudeEffortMotionTokens.accentForIndex(
        selectedIndex: index,
        xHighIndex: widget.xHighIndex,
        maxIndex: widget.maxIndex,
        ultraIndex: widget.ultraIndex,
      );

  @override
  void initState() {
    super.initState();
    final initial = _normalizedIndex(_selectedIndex, _count);
    _fromPosition = initial;
    _toPosition = initial;
    _fromFast = widget.fastModeEnabled ? 1 : 0;
    _toFast = _fromFast;
    _controller = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 300),
    );
    _focusNode = FocusNode(debugLabel: '${widget.sliderKey}.focus');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = codexMotionDisabled(context);
    final changed = next != _reduceMotion;
    _reduceMotion = next;
    if (changed && next && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 1;
      _motion = _EffortMotion.idle;
    }
    if (_didScheduleInitialTierReveal) return;
    _didScheduleInitialTierReveal = true;
    final accent = _accentForIndex(_selectedIndex);
    if (next || accent == ClaudeEffortAccent.standard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _controller.isAnimating) return;
      _animateTo(
        _normalizedIndex(_selectedIndex, _count),
        revealAccent: accent,
      );
    });
  }

  @override
  void didUpdateWidget(CodexEffortMotionSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _normalizedIndex(_selectedIndex, _count);
    final enteringXHigh =
        _selectsSemanticIndex(widget, widget.xHighIndex) &&
        !_selectsSemanticIndex(oldWidget, oldWidget.xHighIndex);
    final enteringMax =
        _selectsSemanticIndex(widget, widget.maxIndex) &&
        !_selectsSemanticIndex(oldWidget, oldWidget.maxIndex);
    final enteringUltra =
        _selectsSemanticIndex(widget, widget.ultraIndex) &&
        !_selectsSemanticIndex(oldWidget, oldWidget.ultraIndex);
    final acknowledged = _locallyRequestedIndex == _selectedIndex;
    if (acknowledged) _locallyRequestedIndex = null;
    if (_motion == _EffortMotion.drag) {
      _toPosition = next;
      _toFast = widget.fastModeEnabled ? 1 : 0;
      return;
    }
    final preservesLocalTierReveal =
        acknowledged &&
        (_toPosition - next).abs() < 0.0001 &&
        ((enteringXHigh && _motion == _EffortMotion.xHighReveal) ||
            (enteringMax && _motion == _EffortMotion.maxReveal) ||
            (enteringUltra && _motion == _EffortMotion.ultraReveal));
    if (preservesLocalTierReveal) return;
    if (enteringXHigh || enteringMax || enteringUltra) {
      _animateTo(
        next,
        revealAccent: enteringUltra
            ? ClaudeEffortAccent.ultra
            : enteringMax
            ? ClaudeEffortAccent.max
            : ClaudeEffortAccent.xHigh,
      );
      return;
    }
    if (oldWidget.fastModeEnabled != widget.fastModeEnabled &&
        (next - _toPosition).abs() < 0.0001) {
      _animateFastTo(widget.fastModeEnabled);
      return;
    }
    if (acknowledged &&
        (_toPosition - next).abs() < 0.0001 &&
        oldWidget.fastModeEnabled == widget.fastModeEnabled) {
      return;
    }
    if ((next - _toPosition).abs() < 0.0001 &&
        oldWidget.labels.length == widget.labels.length) {
      return;
    }
    _animateTo(next);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  double _positionAt(double phase) {
    if (_motion == _EffortMotion.drag) return _clampUnit(phase);
    if (_motion == _EffortMotion.idle || _motion == _EffortMotion.thumb) {
      return _toPosition;
    }
    var positionPhase = _clampUnit(phase);
    if (_motion == _EffortMotion.xHighReveal ||
        _motion == _EffortMotion.maxReveal ||
        _motion == _EffortMotion.ultraReveal ||
        _motion == _EffortMotion.fastEnter ||
        _motion == _EffortMotion.fastExit) {
      // The thumb settles first while the finite purple particle reveal runs.
      positionPhase = _clampUnit(positionPhase / _maxPositionInterval);
    }
    return lerpDouble(
          _fromPosition,
          _toPosition,
          ClaudeEffortMotionTokens.glideCurve.transform(positionPhase),
        ) ??
        _toPosition;
  }

  double _thumbAt(double phase) {
    if (_motion == _EffortMotion.drag) return 1;
    if (_motion == _EffortMotion.idle) return _toThumb;
    var thumbPhase = _clampUnit(phase);
    if (_motion == _EffortMotion.xHighReveal ||
        _motion == _EffortMotion.maxReveal ||
        _motion == _EffortMotion.ultraReveal) {
      thumbPhase = _clampUnit(thumbPhase / _maxThumbInterval);
    }
    final curved = Curves.easeOutBack.transform(thumbPhase);
    return lerpDouble(_fromThumb, _toThumb, curved) ?? _toThumb;
  }

  double _fastAt(double phase) {
    if (_motion == _EffortMotion.idle || _motion == _EffortMotion.drag) {
      return _toFast;
    }
    return lerpDouble(
          _fromFast,
          _toFast,
          codexDesktopMotionCurve.transform(_clampUnit(phase)),
        ) ??
        _toFast;
  }

  void _animateTo(
    double position, {
    ClaudeEffortAccent? revealAccent,
    bool fromDrag = false,
  }) {
    final currentPosition = _positionAt(_controller.value);
    final currentThumb = _thumbAt(_controller.value);
    final currentFast = _fastAt(_controller.value);
    _controller.stop();
    _fromPosition = currentPosition;
    _toPosition = _clampUnit(position);
    _fromThumb = currentThumb;
    _toThumb = _pressed || _hovered ? 1 : 0;
    _fromFast = currentFast;
    _toFast = widget.fastModeEnabled ? 1 : 0;
    final accent = revealAccent ?? ClaudeEffortAccent.standard;
    _maxPositionInterval = ClaudeEffortMotionTokens.positionInterval(
      accent,
      fromDrag: fromDrag,
    );
    _maxThumbInterval = ClaudeEffortMotionTokens.thumbInterval(
      accent,
      fromDrag: fromDrag,
    );
    _motion = switch (accent) {
      ClaudeEffortAccent.standard => _EffortMotion.move,
      ClaudeEffortAccent.xHigh => _EffortMotion.xHighReveal,
      ClaudeEffortAccent.max => _EffortMotion.maxReveal,
      ClaudeEffortAccent.ultra => _EffortMotion.ultraReveal,
    };
    if (_reduceMotion) {
      _controller.value = 1;
      _motion = _EffortMotion.idle;
      return;
    }
    _controller.duration = ClaudeEffortMotionTokens.revealDuration(
      accent,
      fromDrag: fromDrag,
    );
    setState(() {});
    _controller.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted || _controller.isAnimating) return;
      setState(() => _motion = _EffortMotion.idle);
    });
  }

  void _animateFastTo(bool enabled) {
    final currentPosition = _positionAt(_controller.value);
    final targetPosition = _toPosition;
    final currentThumb = _thumbAt(_controller.value);
    final currentFast = _fastAt(_controller.value);
    _controller.stop();
    _fromPosition = currentPosition;
    _toPosition = targetPosition;
    _fromThumb = currentThumb;
    _toThumb = _pressed || _hovered ? 1 : 0;
    _fromFast = currentFast;
    _toFast = enabled ? 1 : 0;
    _maxPositionInterval = enabled ? 300 / 1150 : 300 / 350;
    _motion = enabled ? _EffortMotion.fastEnter : _EffortMotion.fastExit;
    if (_reduceMotion) {
      _controller.value = 1;
      _motion = _EffortMotion.idle;
      return;
    }
    _controller.duration = enabled
        ? const Duration(milliseconds: 1150)
        : const Duration(milliseconds: 350);
    setState(() {});
    _controller.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted || _controller.isAnimating) return;
      setState(() => _motion = _EffortMotion.idle);
    });
  }

  void _animateThumbTo(double target, Duration duration) {
    if (_motion == _EffortMotion.drag) return;
    if (_controller.isAnimating &&
        _motion != _EffortMotion.idle &&
        _motion != _EffortMotion.thumb) {
      // Hover/press feedback must not stop an in-flight tier glide. The shared
      // controller can finish the position first and settle the thumb at this
      // latest target without freezing halfway between two efforts.
      setState(() => _toThumb = target);
      return;
    }
    final currentPosition = _positionAt(_controller.value);
    final currentThumb = _thumbAt(_controller.value);
    final currentFast = _fastAt(_controller.value);
    _controller.stop();
    _fromPosition = currentPosition;
    _toPosition = currentPosition;
    _fromThumb = currentThumb;
    _toThumb = target;
    _fromFast = currentFast;
    _toFast = widget.fastModeEnabled ? 1 : 0;
    _motion = _EffortMotion.thumb;
    if (_reduceMotion) {
      _controller.value = 1;
      _motion = _EffortMotion.idle;
      return;
    }
    _controller.duration = duration;
    setState(() {});
    _controller.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted || _controller.isAnimating) return;
      setState(() => _motion = _EffortMotion.idle);
    });
  }

  void _notifyIndex(int index, {bool fromDrag = false}) {
    if (_count < 2) return;
    final next = index.clamp(0, _count - 1);
    if (next == _selectedIndex && !fromDrag) return;
    _locallyRequestedIndex = next;
    final enteringXHigh =
        next == widget.xHighIndex && _selectedIndex != widget.xHighIndex;
    final enteringMax =
        next == widget.maxIndex && _selectedIndex != widget.maxIndex;
    final enteringUltra =
        next == widget.ultraIndex && _selectedIndex != widget.ultraIndex;
    _animateTo(
      _normalizedIndex(next, _count),
      revealAccent: enteringUltra
          ? ClaudeEffortAccent.ultra
          : enteringMax
          ? ClaudeEffortAccent.max
          : enteringXHigh
          ? ClaudeEffortAccent.xHigh
          : null,
      fromDrag: fromDrag,
    );
    if (next != _selectedIndex) {
      HapticFeedback.selectionClick();
      widget.onSelected(next);
    }
  }

  double _positionFromLocal(double dx, double width, TextDirection direction) {
    final inset = _safeThumbRadius(width);
    final usable = math.max(1.0, width - inset * 2);
    var result = _clampUnit((dx - inset) / usable);
    if (direction == TextDirection.rtl) result = 1 - result;
    return result;
  }

  int _indexFromPosition(double position) =>
      (_clampUnit(position) * math.max(0, _count - 1)).round();

  void _beginPress() {
    _pressed = true;
    _focusNode.requestFocus();
    _animateThumbTo(1, const Duration(milliseconds: 150));
  }

  void _endPress() {
    _pressed = false;
    _animateThumbTo(_hovered ? 1 : 0, const Duration(milliseconds: 220));
  }

  void _startDrag(double position) {
    _controller.stop();
    _motion = _EffortMotion.drag;
    _pressed = true;
    _dragStartedIndex = _selectedIndex;
    _dragLastEmittedIndex = _selectedIndex;
    setState(() {});
    final normalized = _clampUnit(position);
    _controller.value = normalized;
    _emitDragIndex(_indexFromPosition(normalized));
  }

  void _updateDrag(double position) {
    if (_motion != _EffortMotion.drag) return;
    final normalized = _clampUnit(position);
    _controller.value = normalized;
    _emitDragIndex(_indexFromPosition(normalized));
  }

  void _emitDragIndex(int index) {
    final next = index.clamp(0, _count - 1);
    final changed = next != _dragLastEmittedIndex;
    if (!changed) return;
    _dragLastEmittedIndex = next;
    _locallyRequestedIndex = next;
    HapticFeedback.selectionClick();
    widget.onSelected(next);
  }

  void _finishDrag() {
    if (_motion != _EffortMotion.drag) return;
    final next = _indexFromPosition(_controller.value);
    _pressed = false;
    final enteringXHigh =
        next == widget.xHighIndex && _dragStartedIndex != widget.xHighIndex;
    final enteringMax =
        next == widget.maxIndex && _dragStartedIndex != widget.maxIndex;
    final enteringUltra =
        next == widget.ultraIndex && _dragStartedIndex != widget.ultraIndex;
    _emitDragIndex(next);
    _dragStartedIndex = null;
    _dragLastEmittedIndex = null;
    _animateTo(
      _normalizedIndex(next, _count),
      revealAccent: enteringUltra
          ? ClaudeEffortAccent.ultra
          : enteringMax
          ? ClaudeEffortAccent.max
          : enteringXHigh
          ? ClaudeEffortAccent.xHigh
          : null,
      fromDrag: true,
    );
  }

  void _step(int delta) {
    if (_count < 2) return;
    _notifyIndex((_selectedIndex + delta).clamp(0, _count - 1));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final direction = Directionality.of(context);
    final enabled = _count > 1;
    final previous = _selectedIndex > 0
        ? widget.labels[_selectedIndex - 1]
        : null;
    final next = _selectedIndex + 1 < _count
        ? widget.labels[_selectedIndex + 1]
        : null;
    final purple = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFB59CFF)
        : const Color(0xFF7957E8);

    final shortcuts = direction == TextDirection.ltr
        ? const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowRight):
                _IncreaseEffortIntent(),
            SingleActivator(LogicalKeyboardKey.arrowUp):
                _IncreaseEffortIntent(),
            SingleActivator(LogicalKeyboardKey.arrowLeft):
                _DecreaseEffortIntent(),
            SingleActivator(LogicalKeyboardKey.arrowDown):
                _DecreaseEffortIntent(),
            SingleActivator(LogicalKeyboardKey.home): _MinimumEffortIntent(),
            SingleActivator(LogicalKeyboardKey.end): _MaximumEffortIntent(),
          }
        : const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowLeft):
                _IncreaseEffortIntent(),
            SingleActivator(LogicalKeyboardKey.arrowUp):
                _IncreaseEffortIntent(),
            SingleActivator(LogicalKeyboardKey.arrowRight):
                _DecreaseEffortIntent(),
            SingleActivator(LogicalKeyboardKey.arrowDown):
                _DecreaseEffortIntent(),
            SingleActivator(LogicalKeyboardKey.home): _MinimumEffortIntent(),
            SingleActivator(LogicalKeyboardKey.end): _MaximumEffortIntent(),
          };

    return Semantics(
      key: ValueKey(widget.sliderKey),
      container: true,
      slider: true,
      enabled: enabled,
      focusable: enabled,
      focused: _focusNode.hasFocus,
      label: 'Effort',
      value: _count == 0 ? '' : widget.labels[_selectedIndex],
      increasedValue: next,
      decreasedValue: previous,
      onIncrease: next == null ? null : () => _step(1),
      onDecrease: previous == null ? null : () => _step(-1),
      child: FocusableActionDetector(
        enabled: enabled,
        focusNode: _focusNode,
        includeFocusSemantics: false,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        shortcuts: shortcuts,
        actions: <Type, Action<Intent>>{
          _IncreaseEffortIntent: CallbackAction<_IncreaseEffortIntent>(
            onInvoke: (_) {
              _step(1);
              return null;
            },
          ),
          _DecreaseEffortIntent: CallbackAction<_DecreaseEffortIntent>(
            onInvoke: (_) {
              _step(-1);
              return null;
            },
          ),
          _MinimumEffortIntent: CallbackAction<_MinimumEffortIntent>(
            onInvoke: (_) {
              _notifyIndex(0);
              return null;
            },
          ),
          _MaximumEffortIntent: CallbackAction<_MaximumEffortIntent>(
            onInvoke: (_) {
              _notifyIndex(_count - 1);
              return null;
            },
          ),
        },
        onShowFocusHighlight: (value) => setState(() => _showFocus = value),
        onShowHoverHighlight: (value) {
          _hovered = value;
          _animateThumbTo(
            value || _pressed ? 1 : 0,
            Duration(milliseconds: value ? 220 : 220),
          );
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 240.0;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: enabled ? (_) => _beginPress() : null,
              onTapCancel: enabled ? _endPress : null,
              onTapUp: enabled
                  ? (details) {
                      final position = _positionFromLocal(
                        details.localPosition.dx,
                        width,
                        direction,
                      );
                      _pressed = false;
                      final index = _indexFromPosition(position);
                      if (index == _selectedIndex) {
                        _animateThumbTo(
                          _hovered ? 1 : 0,
                          const Duration(milliseconds: 220),
                        );
                      } else {
                        _notifyIndex(index);
                      }
                    }
                  : null,
              onHorizontalDragStart: enabled
                  ? (details) => _startDrag(
                      _positionFromLocal(
                        details.localPosition.dx,
                        width,
                        direction,
                      ),
                    )
                  : null,
              onHorizontalDragUpdate: enabled
                  ? (details) => _updateDrag(
                      _positionFromLocal(
                        details.localPosition.dx,
                        width,
                        direction,
                      ),
                    )
                  : null,
              onHorizontalDragEnd: enabled ? (_) => _finishDrag() : null,
              onHorizontalDragCancel: enabled ? _finishDrag : null,
              child: RepaintBoundary(
                key: ValueKey('${widget.sliderKey}_repaint_boundary'),
                child: SizedBox(
                  height: CodexEffortMotionMetrics.interactionHeight,
                  width: double.infinity,
                  child: CustomPaint(
                    key: ValueKey('${widget.sliderKey}_paint'),
                    painter: _CodexEffortTrackPainter(
                      animation: _controller,
                      motion: _motion,
                      fromPosition: _fromPosition,
                      toPosition: _toPosition,
                      fromThumb: _fromThumb,
                      toThumb: _toThumb,
                      fromFast: _fromFast,
                      toFast: _toFast,
                      maxPositionInterval: _maxPositionInterval,
                      maxThumbInterval: _maxThumbInterval,
                      divisions: math.max(0, _count - 1),
                      direction: direction,
                      focused: _showFocus,
                      enabled: enabled,
                      xHighIndex: widget.xHighIndex,
                      maxIndex: widget.maxIndex,
                      ultraIndex: widget.ultraIndex,
                      reduceMotion: _reduceMotion,
                      primary: cs.primary,
                      onPrimary: cs.onPrimary,
                      inactive: cs.surfaceContainerHighest,
                      tick: cs.onSurfaceVariant,
                      outline: cs.outlineVariant,
                      purple: purple,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _IncreaseEffortIntent extends Intent {
  const _IncreaseEffortIntent();
}

class _DecreaseEffortIntent extends Intent {
  const _DecreaseEffortIntent();
}

class _MinimumEffortIntent extends Intent {
  const _MinimumEffortIntent();
}

class _MaximumEffortIntent extends Intent {
  const _MaximumEffortIntent();
}

/// Public only so structural tests can verify repaint boundaries and geometry.
/// Product code should construct [CodexEffortMotionSlider] instead.
class _CodexEffortTrackPainter extends CustomPainter {
  final Animation<double> animation;
  final _EffortMotion motion;
  final double fromPosition;
  final double toPosition;
  final double fromThumb;
  final double toThumb;
  final double fromFast;
  final double toFast;
  final double maxPositionInterval;
  final double maxThumbInterval;
  final int divisions;
  final TextDirection direction;
  final bool focused;
  final bool enabled;
  final int? xHighIndex;
  final int? maxIndex;
  final int? ultraIndex;
  final bool reduceMotion;
  final Color primary;
  final Color onPrimary;
  final Color inactive;
  final Color tick;
  final Color outline;
  final Color purple;

  _CodexEffortTrackPainter({
    required this.animation,
    required this.motion,
    required this.fromPosition,
    required this.toPosition,
    required this.fromThumb,
    required this.toThumb,
    required this.fromFast,
    required this.toFast,
    required this.maxPositionInterval,
    required this.maxThumbInterval,
    required this.divisions,
    required this.direction,
    required this.focused,
    required this.enabled,
    required this.xHighIndex,
    required this.maxIndex,
    required this.ultraIndex,
    required this.reduceMotion,
    required this.primary,
    required this.onPrimary,
    required this.inactive,
    required this.tick,
    required this.outline,
    required this.purple,
  }) : super(repaint: animation);

  @visibleForTesting
  bool get debugUsesSolidActivePaint =>
      _targetAccent == ClaudeEffortAccent.standard &&
      _fast(reduceMotion ? 1 : animation.value) <= 0.0001;

  @visibleForTesting
  ClaudeEffortAccent get debugAccent => _targetAccent;

  @visibleForTesting
  double get debugLogicalPosition =>
      _position(reduceMotion ? 1 : animation.value);

  @visibleForTesting
  double debugThumbCenterX(double width) =>
      _positionX(debugLogicalPosition, width, direction);

  @visibleForTesting
  Rect debugTrackBounds(Size size) => _trackRectForSize(size);

  @visibleForTesting
  Rect debugActiveBounds(Size size) => _activeRect(
    _trackRectForSize(size),
    _position(reduceMotion ? 1 : animation.value),
    size.width,
  );

  Rect _activeRect(Rect trackRect, double logicalPosition, double width) {
    final thumbX = _positionX(logicalPosition, width, direction);
    final fillThumbRadius = _safeThumbRadius(width);
    return direction == TextDirection.rtl
        ? Rect.fromLTRB(
            math.max(trackRect.left, thumbX - fillThumbRadius),
            trackRect.top,
            trackRect.right,
            trackRect.bottom,
          )
        : Rect.fromLTRB(
            trackRect.left,
            trackRect.top,
            math.min(trackRect.right, thumbX + fillThumbRadius),
            trackRect.bottom,
          );
  }

  int _indexForPosition(double position) =>
      (_clampUnit(position) * math.max(0, divisions)).round();

  ClaudeEffortAccent _accentForPosition(double position) =>
      ClaudeEffortMotionTokens.accentForIndex(
        selectedIndex: _indexForPosition(position),
        xHighIndex: xHighIndex,
        maxIndex: maxIndex,
        ultraIndex: ultraIndex,
      );

  ClaudeEffortAccent get _targetAccent => _accentForPosition(toPosition);

  double _position(double phase) {
    if (motion == _EffortMotion.drag) return _clampUnit(phase);
    if (motion == _EffortMotion.idle || motion == _EffortMotion.thumb) {
      return toPosition;
    }
    var value = _clampUnit(phase);
    if (motion == _EffortMotion.xHighReveal ||
        motion == _EffortMotion.maxReveal ||
        motion == _EffortMotion.ultraReveal ||
        motion == _EffortMotion.fastEnter ||
        motion == _EffortMotion.fastExit) {
      value = _clampUnit(value / maxPositionInterval);
    }
    return lerpDouble(
          fromPosition,
          toPosition,
          ClaudeEffortMotionTokens.glideCurve.transform(value),
        ) ??
        toPosition;
  }

  double _thumb(double phase) {
    if (motion == _EffortMotion.drag) return 1;
    if (motion == _EffortMotion.idle) return toThumb;
    var value = _clampUnit(phase);
    if (motion == _EffortMotion.xHighReveal ||
        motion == _EffortMotion.maxReveal ||
        motion == _EffortMotion.ultraReveal) {
      value = _clampUnit(value / maxThumbInterval);
    }
    return lerpDouble(
          fromThumb,
          toThumb,
          Curves.easeOutBack.transform(value),
        ) ??
        toThumb;
  }

  double _fast(double phase) {
    if (motion == _EffortMotion.idle || motion == _EffortMotion.drag) {
      return toFast;
    }
    return lerpDouble(
          fromFast,
          toFast,
          codexDesktopMotionCurve.transform(_clampUnit(phase)),
        ) ??
        toFast;
  }

  bool get _isTierReveal =>
      motion == _EffortMotion.xHighReveal ||
      motion == _EffortMotion.maxReveal ||
      motion == _EffortMotion.ultraReveal;

  double _movePhase(double phase) {
    if (motion == _EffortMotion.drag ||
        motion == _EffortMotion.idle ||
        motion == _EffortMotion.thumb) {
      return 1;
    }
    if (_isTierReveal ||
        motion == _EffortMotion.fastEnter ||
        motion == _EffortMotion.fastExit) {
      return _clampUnit(phase / maxPositionInterval);
    }
    return _clampUnit(phase);
  }

  @visibleForTesting
  double get debugThumbTravelEnvelope =>
      ClaudeEffortMotionTokens.thumbTravelEnvelope(
        movePhase: _movePhase(reduceMotion ? 1 : animation.value),
        travel: (toPosition - fromPosition).abs(),
      );

  @visibleForTesting
  double debugParticleProgress(int index) =>
      ClaudeEffortMotionTokens.particleProgress(
        _targetAccent,
        reduceMotion ? 1 : animation.value,
        ClaudeEffortMotionTokens.particles[index],
      );

  @override
  void paint(Canvas canvas, Size size) {
    final phase = reduceMotion ? 1.0 : animation.value;
    final logicalPosition = _position(phase);
    final fastProgress = _fast(phase);
    final thumbX = _positionX(logicalPosition, size.width, direction);
    final positionInset = _safeThumbRadius(size.width);
    final positionTravel = math.max(0.0, size.width - positionInset * 2);
    final centerY = size.height / 2;
    final trackRect = _trackRectForSize(size);
    final trackRRect = RRect.fromRectAndRadius(
      trackRect,
      const Radius.circular(CodexEffortMotionMetrics.trackRadius),
    );

    final backgroundPaint = Paint()..color = inactive;
    canvas.drawRRect(trackRRect, backgroundPaint);
    canvas.drawRRect(
      trackRRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = outline.withValues(alpha: 0.34),
    );

    if (focused) {
      canvas.drawRRect(
        trackRRect.inflate(2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = primary.withValues(alpha: 0.48),
      );
    }

    final fromAccent = _accentForPosition(fromPosition);
    final targetAccent = _targetAccent;
    final colourInterval = _isTierReveal
        ? math.min(1.0, maxPositionInterval * 1.8)
        : 1.0;
    final colourMix =
        motion == _EffortMotion.idle ||
            motion == _EffortMotion.drag ||
            motion == _EffortMotion.thumb ||
            motion == _EffortMotion.fastEnter ||
            motion == _EffortMotion.fastExit
        ? 1.0
        : ClaudeEffortMotionTokens.colourCurve.transform(
            _clampUnit(phase / math.max(0.0001, colourInterval)),
          );
    final fromColours = ClaudeEffortMotionTokens.gradientColors(
      accent: fromAccent,
      primary: primary,
      purple: purple,
      fastProgress: fastProgress,
    );
    final targetColours = ClaudeEffortMotionTokens.gradientColors(
      accent: targetAccent,
      primary: primary,
      purple: purple,
      fastProgress: fastProgress,
    );
    final activeColours = List<Color>.generate(
      targetColours.length,
      (index) =>
          Color.lerp(fromColours[index], targetColours[index], colourMix)!,
      growable: false,
    );
    final activeRect = _activeRect(trackRect, logicalPosition, size.width);
    final useSolidActivePaint =
        fromAccent == ClaudeEffortAccent.standard &&
        targetAccent == ClaudeEffortAccent.standard &&
        fastProgress <= 0.0001;
    final activePaint = Paint();
    if (useSolidActivePaint) {
      activePaint.color = primary;
    } else {
      activePaint.shader = LinearGradient(
        begin: direction == TextDirection.rtl
            ? Alignment.centerRight
            : Alignment.centerLeft,
        end: direction == TextDirection.rtl
            ? Alignment.centerLeft
            : Alignment.centerRight,
        colors: activeColours,
      ).createShader(trackRect);
    }

    canvas.save();
    canvas.clipRRect(trackRRect);
    canvas.drawRect(activeRect, activePaint);

    if (motion == _EffortMotion.fastEnter && !reduceMotion) {
      _paintFastBurst(canvas, Offset(thumbX, centerY), phase, trackRect);
    }
    canvas.restore();

    final tickPaint = Paint();
    for (var i = 0; i <= divisions; i++) {
      final raw = divisions == 0 ? 0.0 : i / divisions;
      final x = positionInset + positionTravel * raw;
      final tickLogical = direction == TextDirection.rtl ? 1 - raw : raw;
      final active = tickLogical <= logicalPosition + 0.0001;
      final baseTickColor = active
          ? onPrimary.withValues(alpha: enabled ? 0.72 : 0.38)
          : tick.withValues(alpha: enabled ? 0.46 : 0.26);
      final selectedTick =
          (tickLogical - logicalPosition).abs() <=
          (divisions == 0 ? 0.001 : 0.5 / divisions);
      var tickRadius = CodexEffortMotionMetrics.tickDiameter / 2;
      var tickY = centerY;
      var tickAlphaMultiplier = 1.0;
      if (selectedTick && _isTierReveal && !reduceMotion) {
        final tierPulse = math.sin(math.pi * _clampUnit(phase));
        tickRadius *= 1 + tierPulse * 0.24;
        tickAlphaMultiplier *= 0.78 + tierPulse * 0.22;
      }
      if (selectedTick && fastProgress > 0) {
        var scale = 1.0;
        var translate = 0.0;
        var fade = fastProgress;
        if (motion == _EffortMotion.fastEnter && !reduceMotion) {
          final enter = _clampUnit(phase / 0.70);
          scale = _fastSelectionScale.transform(enter);
          translate = -2 * (1 - codexDesktopMotionCurve.transform(enter));
          fade = _clampUnit(phase / 0.44);
        }
        tickRadius *= scale;
        tickY += translate;
        tickAlphaMultiplier = _clampUnit(0.5 + fade * 0.5);
      }
      canvas.drawCircle(
        Offset(x, tickY),
        tickRadius,
        tickPaint
          ..color = baseTickColor.withValues(
            alpha: baseTickColor.a * tickAlphaMultiplier,
          ),
      );
    }

    if (_isTierReveal && !reduceMotion) {
      _paintClaudeParticles(
        canvas,
        size,
        Offset(thumbX, centerY),
        phase,
        targetAccent,
      );
    }

    final thumbExpansion = _thumb(phase).clamp(0.0, 1.16).toDouble();
    var thumbRadius = lerpDouble(
      CodexEffortMotionMetrics.thumbDiameter / 2,
      CodexEffortMotionMetrics.activeThumbDiameter / 2,
      thumbExpansion,
    )!;
    var thumbY = centerY;
    if (motion == _EffortMotion.fastEnter && !reduceMotion) {
      final enter = _clampUnit(phase / 0.70);
      thumbRadius *= _fastSelectionScale.transform(enter);
      thumbY -= 2 * (1 - codexDesktopMotionCurve.transform(enter));
    }
    thumbRadius = math.min(thumbRadius, _safeThumbRadius(size.width));
    final thumbCenter = Offset(thumbX, thumbY);
    final movePhase = _movePhase(phase);
    final travelEnvelope = reduceMotion
        ? 0.0
        : ClaudeEffortMotionTokens.thumbTravelEnvelope(
            movePhase: movePhase,
            travel: (toPosition - fromPosition).abs(),
          );
    final landingPulse = reduceMotion
        ? 0.0
        : ClaudeEffortMotionTokens.landingPulse(movePhase);
    final halfWidth = math.min(
      _safeThumbRadius(size.width),
      thumbRadius * (1 + travelEnvelope * 0.08),
    );
    final halfHeight = math.min(
      _safeThumbRadius(size.width),
      thumbRadius * (1 - travelEnvelope * 0.03 + landingPulse),
    );
    final thumbRect = Rect.fromCenter(
      center: thumbCenter,
      width: halfWidth * 2,
      height: halfHeight * 2,
    );
    canvas.drawOval(
      thumbRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [activeColours.first, activeColours.last],
        ).createShader(thumbRect),
    );
    canvas.drawOval(
      thumbRect.deflate(0.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = onPrimary.withValues(alpha: enabled ? 0.42 : 0.22),
    );
  }

  void _paintFastBurst(
    Canvas canvas,
    Offset origin,
    double phase,
    Rect trackRect,
  ) {
    final burst = _clampUnit(phase / 0.70);
    final particlePaint = Paint();
    for (final particle in _fastParticles) {
      final local = _clampUnit((burst - particle.delay) / (1 - particle.delay));
      if (local <= 0 || local >= 1) continue;
      final eased = Curves.easeOutCubic.transform(local);
      final rawOffset = Offset(
        particle.unitX * particle.distance * eased,
        particle.unitY * particle.distance * eased * 0.48,
      );
      final point = origin + rawOffset;
      if (!trackRect.inflate(1).contains(point)) continue;
      particlePaint.color = Colors.white.withValues(
        alpha: math.pow(1 - local, 1.8).toDouble(),
      );
      canvas.drawCircle(point, 1.5 * (1 - local * 0.32), particlePaint);
    }
  }

  void _paintClaudeParticles(
    Canvas canvas,
    Size size,
    Offset movingThumb,
    double phase,
    ClaudeEffortAccent accent,
  ) {
    final movePhase = _movePhase(phase);
    final originX = _positionX(fromPosition, size.width, direction);
    final destinationX = _positionX(toPosition, size.width, direction);
    final travel = destinationX - originX;
    final trailCount = ClaudeEffortMotionTokens.trailParticleCount(accent);
    final trailEnvelope = math.sin(math.pi * movePhase.clamp(0.0, 1.0));
    final glowPaint = Paint();
    final particlePaint = Paint();

    if (travel.abs() > 1 && trailEnvelope > 0.001) {
      for (var index = 0; index < trailCount; index++) {
        final lag = index * 0.045;
        final local = (movePhase - lag).clamp(0.0, 1.0);
        final x = lerpDouble(
          originX,
          destinationX,
          ClaudeEffortMotionTokens.glideCurve.transform(local),
        )!;
        final wave = math.sin(index * 1.84 + movePhase * math.pi * 2);
        final alpha =
            trailEnvelope * (1 - index / math.max(1, trailCount)) * 0.70;
        final radius = 1.05 + (index % 3) * 0.22;
        final color = ClaudeEffortMotionTokens.particleColor(index, purple);
        canvas.drawCircle(
          Offset(x, movingThumb.dy + wave * (1.2 + index * 0.16)),
          radius + 1.5,
          glowPaint..color = color.withValues(alpha: alpha * 0.16),
        );
        canvas.drawCircle(
          Offset(x, movingThumb.dy + wave * (1.2 + index * 0.16)),
          radius,
          particlePaint..color = color.withValues(alpha: alpha),
        );
      }
    }

    final origin = Offset(destinationX, movingThumb.dy);
    final count = ClaudeEffortMotionTokens.particleCount(accent);
    final horizontalRoom = math.max(
      1.0,
      math.min(origin.dx, size.width - origin.dx) - 1.5,
    );
    for (var index = 0; index < count; index++) {
      final particle = ClaudeEffortMotionTokens.particles[index];
      final progress = ClaudeEffortMotionTokens.particleProgress(
        accent,
        phase,
        particle,
      );
      if (progress < 0) continue;
      final opacity = ClaudeEffortMotionTokens.particleOpacity(progress);
      if (opacity <= 0.001) continue;
      final eased = Curves.easeOutCubic.transform(progress);
      final angle =
          particle.angle + particle.arc * math.sin(math.pi * progress);
      final distance = 10 + particle.distance * eased * 0.76;
      final horizontalScale = math.min(
        1.0,
        horizontalRoom / math.max(1.0, 10 + particle.distance * 0.76),
      );
      final point =
          origin +
          Offset(
            math.cos(angle) * distance * horizontalScale,
            math.sin(angle) * distance * 0.86,
          );
      final color = ClaudeEffortMotionTokens.particleColor(index, purple);
      final radius = particle.radius * 1.32 * (1 - progress * 0.18);
      canvas.drawCircle(
        point,
        radius + 1.85,
        glowPaint..color = color.withValues(alpha: opacity * 0.18),
      );
      canvas.drawCircle(
        point,
        radius,
        particlePaint..color = color.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CodexEffortTrackPainter oldDelegate) =>
      animation != oldDelegate.animation ||
      motion != oldDelegate.motion ||
      fromPosition != oldDelegate.fromPosition ||
      toPosition != oldDelegate.toPosition ||
      fromThumb != oldDelegate.fromThumb ||
      toThumb != oldDelegate.toThumb ||
      fromFast != oldDelegate.fromFast ||
      toFast != oldDelegate.toFast ||
      maxPositionInterval != oldDelegate.maxPositionInterval ||
      maxThumbInterval != oldDelegate.maxThumbInterval ||
      divisions != oldDelegate.divisions ||
      direction != oldDelegate.direction ||
      focused != oldDelegate.focused ||
      enabled != oldDelegate.enabled ||
      xHighIndex != oldDelegate.xHighIndex ||
      maxIndex != oldDelegate.maxIndex ||
      ultraIndex != oldDelegate.ultraIndex ||
      reduceMotion != oldDelegate.reduceMotion ||
      primary != oldDelegate.primary ||
      onPrimary != oldDelegate.onPrimary ||
      inactive != oldDelegate.inactive ||
      tick != oldDelegate.tick ||
      outline != oldDelegate.outline ||
      purple != oldDelegate.purple;
}

class _FastParticleSpec {
  final double unitX;
  final double unitY;
  final double distance;
  final double delay;

  const _FastParticleSpec(this.unitX, this.unitY, this.distance, this.delay);
}

const _fastParticles = <_FastParticleSpec>[
  _FastParticleSpec(-0.98170, -0.19042, 23, 0.00),
  _FastParticleSpec(-0.81295, -0.58233, 19, 0.08),
  _FastParticleSpec(-0.48748, -0.87313, 24, 0.02),
  _FastParticleSpec(-0.05917, -0.99825, 21, 0.12),
  _FastParticleSpec(0.38092, -0.92461, 24, 0.04),
  _FastParticleSpec(0.74517, -0.66687, 20, 0.14),
  _FastParticleSpec(0.96106, -0.27636, 23, 0.06),
  _FastParticleSpec(0.98384, 0.17903, 20, 0.11),
  _FastParticleSpec(0.80803, 0.58914, 24, 0.01),
  _FastParticleSpec(0.47133, 0.88196, 21, 0.13),
  _FastParticleSpec(0.05077, 0.99871, 23, 0.05),
  _FastParticleSpec(-0.39788, 0.91744, 19, 0.15),
  _FastParticleSpec(-0.75732, 0.65304, 24, 0.03),
  _FastParticleSpec(-0.96061, 0.27789, 21, 0.10),
];

@visibleForTesting
int get codexFastParticleCount => _fastParticles.length;
