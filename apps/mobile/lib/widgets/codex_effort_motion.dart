import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  static const double thumbDiameter = 28;
  static const double activeThumbDiameter = 32;
  static const double tickDiameter = 4;
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
  maxReveal,
  ultraReveal,
  fastEnter,
  fastExit,
  drag,
  thumb,
}

class _EffortParticleSpec {
  final double unitX;
  final double unitY;
  final double distance;
  final double radius;
  final double delay;

  const _EffortParticleSpec(
    this.unitX,
    this.unitY,
    this.distance,
    this.radius,
    this.delay,
  );
}

// Precomputed so the painter never allocates random particle geometry per
// frame. Values intentionally have a little asymmetry like the Desktop burst.
const _maxParticles = <_EffortParticleSpec>[
  _EffortParticleSpec(-0.98356, -0.18060, 25, 1.35, 0.00),
  _EffortParticleSpec(-0.84641, -0.53253, 21, 1.10, 0.08),
  _EffortParticleSpec(-0.58850, -0.80850, 28, 1.45, 0.02),
  _EffortParticleSpec(-0.24663, -0.96911, 24, 1.05, 0.12),
  _EffortParticleSpec(0.12050, -0.99271, 29, 1.40, 0.04),
  _EffortParticleSpec(0.49757, -0.86742, 22, 1.15, 0.15),
  _EffortParticleSpec(0.78999, -0.61312, 27, 1.35, 0.07),
  _EffortParticleSpec(0.96891, -0.24740, 23, 1.00, 0.18),
  _EffortParticleSpec(0.98384, 0.17903, 26, 1.40, 0.01),
  _EffortParticleSpec(0.83646, 0.54802, 21, 1.05, 0.11),
  _EffortParticleSpec(0.57352, 0.81919, 29, 1.30, 0.05),
  _EffortParticleSpec(0.19945, 0.97991, 24, 1.10, 0.16),
  _EffortParticleSpec(-0.18808, 0.98215, 27, 1.45, 0.03),
  _EffortParticleSpec(-0.52201, 0.85294, 22, 1.00, 0.13),
  _EffortParticleSpec(-0.78901, 0.61437, 28, 1.35, 0.06),
  _EffortParticleSpec(-0.94873, 0.31608, 23, 1.10, 0.17),
];

@visibleForTesting
int get codexMaxParticleCount => _maxParticles.length;

/// A discrete, self-painted effort slider modelled after the Codex Desktop
/// control. It owns one finite [AnimationController]; no animation repeats.
class CodexEffortMotionSlider extends StatefulWidget {
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final String sliderKey;
  final int? maxIndex;
  final int? ultraIndex;
  final bool fastModeEnabled;

  const CodexEffortMotionSlider({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    required this.sliderKey,
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

  int get _count => widget.labels.length;

  int get _selectedIndex =>
      _count == 0 ? 0 : widget.selectedIndex.clamp(0, _count - 1);

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
    if (next == _reduceMotion) return;
    _reduceMotion = next;
    if (next && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 1;
      _motion = _EffortMotion.idle;
    }
  }

  @override
  void didUpdateWidget(CodexEffortMotionSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _normalizedIndex(_selectedIndex, _count);
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
        ((enteringMax && _motion == _EffortMotion.maxReveal) ||
            (enteringUltra && _motion == _EffortMotion.ultraReveal));
    if (preservesLocalTierReveal) return;
    if (enteringMax || enteringUltra) {
      _animateTo(next, enteringMax: enteringMax, enteringUltra: enteringUltra);
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
    if (_motion == _EffortMotion.maxReveal ||
        _motion == _EffortMotion.ultraReveal) {
      // The position settles in 300 ms while the gradient reveal continues.
      positionPhase = _clampUnit(positionPhase / _maxPositionInterval);
    }
    return lerpDouble(
          _fromPosition,
          _toPosition,
          codexDesktopMotionCurve.transform(positionPhase),
        ) ??
        _toPosition;
  }

  double _thumbAt(double phase) {
    if (_motion == _EffortMotion.drag) return 1;
    if (_motion == _EffortMotion.idle) return _toThumb;
    var thumbPhase = _clampUnit(phase);
    if (_motion == _EffortMotion.maxReveal ||
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
    bool enteringMax = false,
    bool enteringUltra = false,
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
    _maxPositionInterval = enteringUltra
        ? fromDrag
              ? 150 / 1100
              : 300 / 1100
        : fromDrag
        ? 0.075
        : 0.15;
    _maxThumbInterval = enteringUltra
        ? fromDrag
              ? 150 / 1100
              : 220 / 1100
        : fromDrag
        ? 0.075
        : 0.11;
    _motion = enteringMax
        ? _EffortMotion.maxReveal
        : enteringUltra
        ? _EffortMotion.ultraReveal
        : _EffortMotion.move;
    if (_reduceMotion) {
      _controller.value = 1;
      _motion = _EffortMotion.idle;
      return;
    }
    _controller.duration = enteringMax
        ? const Duration(milliseconds: 2000)
        : enteringUltra
        ? const Duration(milliseconds: 1100)
        : fromDrag
        ? const Duration(milliseconds: 150)
        : const Duration(milliseconds: 300);
    setState(() {});
    _controller.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted || _controller.isAnimating) return;
      setState(() => _motion = _EffortMotion.idle);
    });
  }

  void _animateFastTo(bool enabled) {
    final currentPosition = _positionAt(_controller.value);
    final currentThumb = _thumbAt(_controller.value);
    final currentFast = _fastAt(_controller.value);
    _controller.stop();
    _fromPosition = currentPosition;
    _toPosition = currentPosition;
    _fromThumb = currentThumb;
    _toThumb = _pressed || _hovered ? 1 : 0;
    _fromFast = currentFast;
    _toFast = enabled ? 1 : 0;
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
    final enteringMax =
        next == widget.maxIndex && _selectedIndex != widget.maxIndex;
    final enteringUltra =
        next == widget.ultraIndex && _selectedIndex != widget.ultraIndex;
    _animateTo(
      _normalizedIndex(next, _count),
      enteringMax: enteringMax,
      enteringUltra: enteringUltra,
      fromDrag: fromDrag,
    );
    if (next != _selectedIndex) {
      HapticFeedback.selectionClick();
      widget.onSelected(next);
    }
  }

  double _positionFromLocal(double dx, double width, TextDirection direction) {
    final inset = CodexEffortMotionMetrics.activeThumbDiameter / 2;
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
    final enteringMax =
        next == widget.maxIndex && _dragStartedIndex != widget.maxIndex;
    final enteringUltra =
        next == widget.ultraIndex && _dragStartedIndex != widget.ultraIndex;
    _emitDragIndex(next);
    _dragStartedIndex = null;
    _dragLastEmittedIndex = null;
    _animateTo(
      _normalizedIndex(next, _count),
      enteringMax: enteringMax,
      enteringUltra: enteringUltra,
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
    final maxSelected = widget.maxIndex == _selectedIndex;
    final ultraSelected = widget.ultraIndex == _selectedIndex;
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
                      maxSelected: maxSelected,
                      ultraSelected: ultraSelected,
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
  final bool maxSelected;
  final bool ultraSelected;
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
    required this.maxSelected,
    required this.ultraSelected,
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
      !maxSelected &&
      !ultraSelected &&
      _fast(reduceMotion ? 1 : animation.value) <= 0.0001;

  double _position(double phase) {
    if (motion == _EffortMotion.drag) return _clampUnit(phase);
    if (motion == _EffortMotion.idle || motion == _EffortMotion.thumb) {
      return toPosition;
    }
    var value = _clampUnit(phase);
    if (motion == _EffortMotion.maxReveal ||
        motion == _EffortMotion.ultraReveal) {
      value = _clampUnit(value / maxPositionInterval);
    }
    return lerpDouble(
          fromPosition,
          toPosition,
          codexDesktopMotionCurve.transform(value),
        ) ??
        toPosition;
  }

  double _thumb(double phase) {
    if (motion == _EffortMotion.drag) return 1;
    if (motion == _EffortMotion.idle) return toThumb;
    var value = _clampUnit(phase);
    if (motion == _EffortMotion.maxReveal ||
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

  @override
  void paint(Canvas canvas, Size size) {
    final phase = reduceMotion ? 1.0 : animation.value;
    final logicalPosition = _position(phase);
    final fastProgress = _fast(phase);
    final visualPosition = direction == TextDirection.rtl
        ? 1 - logicalPosition
        : logicalPosition;
    const inset = CodexEffortMotionMetrics.activeThumbDiameter / 2;
    final usable = math.max(1.0, size.width - inset * 2);
    final thumbX = inset + usable * visualPosition;
    final centerY = size.height / 2;
    final trackRect = Rect.fromLTWH(
      inset,
      centerY - CodexEffortMotionMetrics.trackHeight / 2,
      usable,
      CodexEffortMotionMetrics.trackHeight,
    );
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

    final highTier = maxSelected || ultraSelected;
    final reveal =
        motion == _EffortMotion.maxReveal || motion == _EffortMotion.ultraReveal
        ? codexDesktopMotionCurve.transform(_clampUnit(phase))
        : 1.0;
    final purpleMix = highTier ? reveal : 0.0;
    final fastHighlight = Color.lerp(primary, onPrimary, 0.18)!;
    final activeStart = Color.lerp(
      Color.lerp(primary, fastHighlight, fastProgress * 0.24)!,
      purple,
      purpleMix * 0.45,
    )!;
    final activeEnd = Color.lerp(
      Color.lerp(primary, fastHighlight, fastProgress * 0.52)!,
      purple,
      purpleMix,
    )!;
    final activeRect = direction == TextDirection.rtl
        ? Rect.fromLTRB(
            thumbX,
            trackRect.top,
            trackRect.right,
            trackRect.bottom,
          )
        : Rect.fromLTRB(
            trackRect.left,
            trackRect.top,
            thumbX,
            trackRect.bottom,
          );
    final useSolidActivePaint = !highTier && fastProgress <= 0.0001;
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
        colors: [activeStart, activeEnd],
      ).createShader(trackRect);
    }

    canvas.save();
    canvas.clipRRect(trackRRect);
    canvas.drawRect(activeRect, activePaint);

    if (motion == _EffortMotion.fastEnter && !reduceMotion) {
      _paintFastBurst(canvas, Offset(thumbX, centerY), phase, trackRect);
    }
    if (motion == _EffortMotion.ultraReveal && !reduceMotion) {
      _paintUltraSweep(canvas, activeRect, trackRect, phase);
    }
    canvas.restore();

    final tickPaint = Paint();
    for (var i = 0; i <= divisions; i++) {
      final raw = divisions == 0 ? 0.0 : i / divisions;
      final x = inset + usable * raw;
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

    if (motion == _EffortMotion.maxReveal && !reduceMotion) {
      _paintMaxBurst(canvas, Offset(thumbX, centerY), phase);
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
    final thumbCenter = Offset(thumbX, thumbY);
    final thumbPaint = Paint();
    if (useSolidActivePaint) {
      thumbPaint.color = primary;
    } else {
      thumbPaint.shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [activeStart, activeEnd],
      ).createShader(Rect.fromCircle(center: thumbCenter, radius: thumbRadius));
    }
    canvas.drawCircle(thumbCenter, thumbRadius, thumbPaint);
    canvas.drawCircle(
      thumbCenter,
      thumbRadius - 0.75,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = onPrimary.withValues(alpha: enabled ? 0.42 : 0.22),
    );
  }

  void _paintMaxBurst(Canvas canvas, Offset origin, double phase) {
    final burst = _clampUnit(phase / 0.31);
    final particlePaint = Paint();
    for (final particle in _maxParticles) {
      final local = _clampUnit((burst - particle.delay) / (1 - particle.delay));
      if (local <= 0 || local >= 1) continue;
      final eased = Curves.easeOutCubic.transform(local);
      final distance = particle.distance * eased;
      particlePaint.color = Color.lerp(
        primary,
        purple,
        eased,
      )!.withValues(alpha: math.pow(1 - local, 1.7).toDouble());
      canvas.drawCircle(
        origin + Offset(particle.unitX * distance, particle.unitY * distance),
        particle.radius * (1 - local * 0.35),
        particlePaint,
      );
    }
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

  void _paintUltraSweep(
    Canvas canvas,
    Rect activeRect,
    Rect trackRect,
    double phase,
  ) {
    if (activeRect.width <= 0) return;
    final progress = codexDesktopMotionCurve.transform(_clampUnit(phase));
    final sweepWidth = math.max(22.0, trackRect.width * 0.34);
    final travel = trackRect.width + sweepWidth * 2;
    final leading = direction == TextDirection.rtl
        ? trackRect.right + sweepWidth - travel * progress
        : trackRect.left - sweepWidth + travel * progress;
    final sweepRect = Rect.fromCenter(
      center: Offset(leading, trackRect.center.dy),
      width: sweepWidth,
      height: trackRect.height,
    );
    final visibleSweep = sweepRect.intersect(activeRect);
    if (visibleSweep.isEmpty) return;
    canvas.drawRect(
      visibleSweep,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.34),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(sweepRect),
    );
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
      maxSelected != oldDelegate.maxSelected ||
      ultraSelected != oldDelegate.ultraSelected ||
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
