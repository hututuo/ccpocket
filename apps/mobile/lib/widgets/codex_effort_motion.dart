import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui show VertexMode, Vertices;
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'claude_effort_motion_style.dart';
import 'third_party/astraeus/claude_range_slider_fire.dart';

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
  static const double activeFillThumbUnderlap = 8;
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

ClaudeEffortAccent _accentForWidget(CodexEffortMotionSlider widget) {
  final selected = widget.labels.isEmpty
      ? 0
      : widget.selectedIndex.clamp(0, widget.labels.length - 1);
  return ClaudeEffortMotionTokens.accentForIndex(
    selectedIndex: selected,
    xHighIndex: widget.xHighIndex,
    maxIndex: widget.maxIndex,
    ultraIndex: widget.ultraIndex,
  );
}

bool _accentUsesPersistentFire(ClaudeEffortAccent accent) =>
    accent == ClaudeEffortAccent.max || accent == ClaudeEffortAccent.ultra;

ClaudeRangeSliderFireTier _fireTierForAccent(ClaudeEffortAccent accent) =>
    accent == ClaudeEffortAccent.max
    ? ClaudeRangeSliderFireTier.max
    : ClaudeRangeSliderFireTier.ultra;

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

@visibleForTesting
int get codexEffortPixelCellCapacity =>
    ClaudeEffortMotionTokens.pixelColumns *
    ClaudeEffortMotionTokens.maxPixelRows;

/// The three fire layers are submitted as one indexed vertex batch per frame.
@visibleForTesting
const int codexEffortPixelFireDrawBatchCount = 1;

class _EffortPixelFieldState {
  static const int _columns = ClaudeRangeSliderFireSimulation.columns;
  static const int _rows = ClaudeRangeSliderFireSimulation.rows;

  final ClaudeRangeSliderFireSimulation _simulation =
      ClaudeRangeSliderFireSimulation();

  ClaudeEffortAccent accent = ClaudeEffortAccent.standard;
  double opacity = 0;
  bool _extinguishing = false;

  double get elapsed => _simulation.elapsed;
  double get reach => _simulation.reach;
  double get slider => _simulation.slider;
  int get litCellCount => _simulation.litCellCount;
  int get litRowCount => _simulation.litRowCount;
  double get energyChecksum => _simulation.energyChecksum;

  double columnEnergy(int column) {
    assert(column >= 0 && column < _columns);
    return _simulation.columnEnergy(column);
  }

  int farthestColumnAbove(double threshold) =>
      _simulation.highestColumnAbove(threshold);

  int lowestColumnAbove(double threshold) =>
      _simulation.lowestColumnAbove(threshold);

  int columnCountAbove(double threshold) =>
      _simulation.columnCountAbove(threshold);

  double energyAt(int column, int row) {
    assert(column >= 0 && column < _columns);
    assert(row >= 0 && row < _rows);
    return _simulation.luminanceAt(column, row);
  }

  double redAt(int column, int row) => _simulation.redAt(column, row);
  double greenAt(int column, int row) => _simulation.greenAt(column, row);
  double blueAt(int column, int row) => _simulation.blueAt(column, row);
  double glowRedAt(int column, int row) => _simulation.glowRedAt(column, row);
  double glowGreenAt(int column, int row) =>
      _simulation.glowGreenAt(column, row);
  double glowBlueAt(int column, int row) => _simulation.glowBlueAt(column, row);
  double redAtIndex(int index) => _simulation.redAtIndex(index);
  double greenAtIndex(int index) => _simulation.greenAtIndex(index);
  double blueAtIndex(int index) => _simulation.blueAtIndex(index);
  double glowRedAtIndex(int index) => _simulation.glowRedAtIndex(index);
  double glowGreenAtIndex(int index) => _simulation.glowGreenAtIndex(index);
  double glowBlueAtIndex(int index) => _simulation.glowBlueAtIndex(index);

  void setSliderPosition(double position) {
    _simulation.setSlider(position);
  }

  void setFramebufferMetrics({
    required Size size,
    required double devicePixelRatio,
  }) {
    final track = _trackRectForSize(size);
    _simulation.setFramebufferMetrics(
      width: track.width,
      height: track.height,
      devicePixelRatio: devicePixelRatio,
    );
  }

  void activate(
    ClaudeEffortAccent nextAccent, {
    required bool restart,
    required double sliderPosition,
  }) {
    assert(_accentUsesPersistentFire(nextAccent));
    accent = nextAccent;
    _extinguishing = false;
    _simulation.ignite(
      slider: sliderPosition,
      tier: _fireTierForAccent(nextAccent),
      restart: restart,
    );
  }

  void settleInitial(
    ClaudeEffortAccent initialAccent, {
    required double sliderPosition,
  }) {
    assert(_accentUsesPersistentFire(initialAccent));
    accent = initialAccent;
    opacity = 1;
    _extinguishing = false;
    _simulation.settle(
      slider: sliderPosition,
      tier: _fireTierForAccent(initialAccent),
    );
  }

  void advanceEnergy(double deltaSeconds) {
    _simulation.advance(deltaSeconds);
  }

  void decayEnergy(double deltaSeconds) {
    if (!_extinguishing) {
      _simulation.extinguish(slider: slider);
      _extinguishing = true;
    }
    _simulation.advance(deltaSeconds);
  }

  void clear() {
    accent = ClaudeEffortAccent.standard;
    opacity = 0;
    _extinguishing = false;
    _simulation.clear();
  }
}

class _PixelFieldRepaint extends ChangeNotifier {
  void markNeedsPaint() => notifyListeners();
}

/// A discrete, self-painted effort slider modelled after the Codex Desktop
/// control. Tier transitions use one finite [AnimationController]. A separate
/// 60 fps ticker drives a deterministic fixed-grid pixel fire only while Max
/// or Ultra is visible; it never allocates particle state per frame.
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
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Ticker _pixelTicker;
  late final FocusNode _focusNode;
  final _PixelFieldRepaint _pixelRepaint = _PixelFieldRepaint();
  final _EffortPixelFieldState _pixelField = _EffortPixelFieldState();
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
  bool _tickerModeEnabled = true;
  bool? _pendingFastAfterTierReveal;
  int _animationGeneration = 0;
  int? _locallyRequestedIndex;
  int? _dragStartedIndex;
  int? _dragLastEmittedIndex;
  int? _activePointer;
  int? _pointerOriginIndex;
  int? _pointerDownIndex;
  Duration? _lastPixelTick;

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
    final initialAccent = _accentForWidget(widget);
    if (_accentUsesPersistentFire(initialAccent)) {
      _pixelField.settleInitial(initialAccent, sliderPosition: initial);
    }
    _controller = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 300),
    );
    _pixelTicker = createTicker(_onPixelTick);
    _focusNode = FocusNode(debugLabel: '${widget.sliderKey}.focus');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextTickerModeEnabled = TickerMode.valuesOf(context).enabled;
    if (nextTickerModeEnabled != _tickerModeEnabled) {
      _tickerModeEnabled = nextTickerModeEnabled;
      _lastPixelTick = null;
    }
    final next = codexMotionDisabled(context);
    final changed = next != _reduceMotion;
    _reduceMotion = next;
    if (changed && next && _controller.isAnimating) {
      _pendingFastAfterTierReveal = null;
      _animationGeneration += 1;
      _controller.stop();
      _controller.value = 1;
      _motion = _EffortMotion.idle;
    }
    if (next) {
      _clearPixelField();
    } else {
      _syncPixelTicker();
    }
  }

  @override
  void didUpdateWidget(CodexEffortMotionSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousAccent = _accentForWidget(oldWidget);
    final currentAccent = _accentForWidget(widget);
    _syncPixelTicker(
      restart:
          _accentUsesPersistentFire(currentAccent) &&
          !_accentUsesPersistentFire(previousAccent),
    );
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
    final acknowledgesLocalPosition =
        acknowledged && (_toPosition - next).abs() < 0.0001;
    if (acknowledgesLocalPosition) {
      if (oldWidget.fastModeEnabled != widget.fastModeEnabled) {
        _applyFastModeChange(widget.fastModeEnabled);
      }
      return;
    }
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
      _applyFastModeChange(widget.fastModeEnabled);
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
    _pixelTicker.dispose();
    _pixelRepaint.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _shouldAnimatePixelField =>
      !_reduceMotion &&
      _accentUsesPersistentFire(_accentForIndex(_selectedIndex));

  void _syncPixelTicker({bool restart = false}) {
    if (_reduceMotion) {
      _clearPixelField();
      return;
    }
    if (!_shouldAnimatePixelField && _pixelField.opacity <= 0.001) {
      if (_pixelTicker.isActive) _pixelTicker.stop();
      _lastPixelTick = null;
      return;
    }
    if (_shouldAnimatePixelField) {
      final accent = _accentForIndex(_selectedIndex);
      final shouldRestart =
          restart || !_accentUsesPersistentFire(_pixelField.accent);
      final sliderPosition = _positionAt(_controller.value);
      _pixelField.activate(
        accent,
        restart: shouldRestart,
        sliderPosition: sliderPosition,
      );
      if (_pixelField.opacity <= 0.001) _pixelField.opacity = 0.14;
      _pixelRepaint.markNeedsPaint();
    }
    if (!_pixelTicker.isActive) {
      _lastPixelTick = Duration.zero;
      _pixelTicker.start();
    }
  }

  void _clearPixelField() {
    final changed = _pixelField.opacity > 0.001;
    _pixelField.clear();
    _lastPixelTick = null;
    if (_pixelTicker.isActive) _pixelTicker.stop();
    if (changed) _pixelRepaint.markNeedsPaint();
  }

  void _onPixelTick(Duration elapsed) {
    final previous = _lastPixelTick;
    if (previous == null) {
      _lastPixelTick = elapsed;
      return;
    }
    final micros = (elapsed - previous).inMicroseconds;
    if (micros < ClaudeEffortMotionTokens.pixelFrameInterval.inMicroseconds) {
      return;
    }
    _lastPixelTick = elapsed;
    final elapsedSeconds = (micros / Duration.microsecondsPerSecond)
        .clamp(0.0, 1.0)
        .toDouble();
    if (_shouldAnimatePixelField) {
      final accent = _accentForIndex(_selectedIndex);
      if (_pixelField.accent != accent) {
        _pixelField.activate(
          accent,
          restart: !_accentUsesPersistentFire(_pixelField.accent),
          sliderPosition: _positionAt(_controller.value),
        );
      }
      _updatePixelSliderPosition();
      _pixelField.advanceEnergy(elapsedSeconds);
      _pixelField.opacity = math.min(
        1,
        _pixelField.opacity + elapsedSeconds / 0.22,
      );
    } else {
      _pixelField.decayEnergy(elapsedSeconds);
      final fadeSeconds =
          ClaudeEffortMotionTokens.pixelFadeOutDuration.inMicroseconds /
          Duration.microsecondsPerSecond;
      _pixelField.opacity = math.max(
        0,
        _pixelField.opacity - elapsedSeconds / fadeSeconds,
      );
    }

    _pixelRepaint.markNeedsPaint();
    if (!_shouldAnimatePixelField && _pixelField.opacity <= 0.001) {
      _pixelField.clear();
      _pixelTicker.stop();
      _lastPixelTick = null;
    }
  }

  void _updatePixelSliderPosition() {
    _pixelField.setSliderPosition(_positionAt(_controller.value));
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
    bool snapPosition = false,
  }) {
    _pendingFastAfterTierReveal = null;
    final generation = ++_animationGeneration;
    final currentPosition = _positionAt(_controller.value);
    final currentThumb = _thumbAt(_controller.value);
    final currentFast = _fastAt(_controller.value);
    _controller.stop();
    final targetPosition = _clampUnit(position);
    _fromPosition = snapPosition ? targetPosition : currentPosition;
    _toPosition = targetPosition;
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
      if (!mounted ||
          generation != _animationGeneration ||
          _controller.isAnimating) {
        return;
      }
      final pendingFast = _pendingFastAfterTierReveal;
      _pendingFastAfterTierReveal = null;
      if (pendingFast != null && (_toFast >= 0.5) != pendingFast) {
        _animateFastTo(pendingFast);
        return;
      }
      setState(() => _motion = _EffortMotion.idle);
    });
  }

  bool get _tierRevealInFlight =>
      _controller.isAnimating &&
      (_motion == _EffortMotion.xHighReveal ||
          _motion == _EffortMotion.maxReveal ||
          _motion == _EffortMotion.ultraReveal);

  void _applyFastModeChange(bool enabled) {
    if (_tierRevealInFlight) {
      _pendingFastAfterTierReveal = enabled;
      return;
    }
    _animateFastTo(enabled);
  }

  void _animateFastTo(bool enabled) {
    _pendingFastAfterTierReveal = null;
    final generation = ++_animationGeneration;
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
      if (!mounted ||
          generation != _animationGeneration ||
          _controller.isAnimating) {
        return;
      }
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
    final generation = ++_animationGeneration;
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
      if (!mounted ||
          generation != _animationGeneration ||
          _controller.isAnimating) {
        return;
      }
      setState(() => _motion = _EffortMotion.idle);
    });
  }

  void _notifyIndex(
    int index, {
    bool fromDrag = false,
    bool snapPosition = false,
  }) {
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
      snapPosition: snapPosition,
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

  void _beginPressAt(PointerDownEvent event, double position) {
    if (_activePointer != null || (event.buttons & kPrimaryButton) == 0) return;
    _activePointer = event.pointer;
    _pointerOriginIndex = _selectedIndex;
    final next = _indexFromPosition(position).clamp(0, _count - 1);
    _pointerDownIndex = next;
    _pressed = true;
    _focusNode.requestFocus();
    if (next == _selectedIndex) {
      _animateThumbTo(1, const Duration(milliseconds: 120));
    } else {
      _notifyIndex(next, snapPosition: true);
    }
  }

  void _endPointer(int pointer) {
    if (_activePointer != pointer) return;
    _activePointer = null;
    _pointerOriginIndex = null;
    _pointerDownIndex = null;
    if (_motion == _EffortMotion.drag) return;
    _pressed = false;
    _animateThumbTo(_hovered ? 1 : 0, const Duration(milliseconds: 220));
  }

  void _startDrag(double position) {
    _animationGeneration += 1;
    _pendingFastAfterTierReveal = null;
    _controller.stop();
    _motion = _EffortMotion.drag;
    _pressed = true;
    _dragStartedIndex = _pointerOriginIndex ?? _selectedIndex;
    _dragLastEmittedIndex = _pointerDownIndex ?? _selectedIndex;
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
    _pointerOriginIndex = null;
    _pointerDownIndex = null;
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
            _pixelField.setFramebufferMetrics(
              size: Size(width, CodexEffortMotionMetrics.interactionHeight),
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            );
            if (_shouldAnimatePixelField && !_pixelTicker.isActive) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _syncPixelTicker();
              });
            }
            return Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: enabled
                  ? (event) => _beginPressAt(
                      event,
                      _positionFromLocal(
                        event.localPosition.dx,
                        width,
                        direction,
                      ),
                    )
                  : null,
              onPointerUp: enabled
                  ? (event) => _endPointer(event.pointer)
                  : null,
              onPointerCancel: enabled
                  ? (event) => _endPointer(event.pointer)
                  : null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
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
                        pixelField: _pixelField,
                        pixelRepaint: _pixelRepaint,
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

class _PixelFireMeshGeometry {
  _PixelFireMeshGeometry._({
    required this.trackRect,
    required this.direction,
    required this.positions,
    required this.indices,
    required this.colors,
  });

  static const int layerCount = 3;
  static const int verticesPerQuad = 4;
  static const int indicesPerQuad = 6;
  static const int quadCount =
      ClaudeRangeSliderFireSimulation.cellCount * layerCount;
  static const int vertexCount = quadCount * verticesPerQuad;

  final Rect trackRect;
  final TextDirection direction;
  final Float32List positions;
  final Uint16List indices;
  final Int32List colors;

  bool matches(Rect nextTrackRect, TextDirection nextDirection) =>
      trackRect == nextTrackRect && direction == nextDirection;

  factory _PixelFireMeshGeometry.create(
    Rect trackRect,
    TextDirection direction,
  ) {
    const columns = ClaudeRangeSliderFireSimulation.columns;
    const rows = ClaudeRangeSliderFireSimulation.rows;
    final cellStepX = trackRect.width / columns;
    final cellStepY = trackRect.height / rows;
    final cellSize = math.min(cellStepX, cellStepY);
    final outerCellSize = Size(cellStepX * 0.756, cellStepY * 0.68);
    final coreCellSize = Size(cellStepX * 0.489, cellStepY * 0.44);
    final positions = Float32List(vertexCount * 2);
    final indices = Uint16List(quadCount * indicesPerQuad);
    final colors = Int32List(vertexCount);

    var quad = 0;
    for (var layer = 0; layer < layerCount; layer++) {
      for (var column = 0; column < columns; column++) {
        final logicalX = ClaudeRangeSliderFireSimulation.columnCenter(column);
        final x = direction == TextDirection.rtl
            ? trackRect.right - logicalX * trackRect.width
            : trackRect.left + logicalX * trackRect.width;
        for (var row = 0; row < rows; row++) {
          final logicalY = ClaudeRangeSliderFireSimulation.rowCenter(row);
          final centre = Offset(x, trackRect.top + logicalY * trackRect.height);
          final outerRect = Rect.fromCenter(
            center: centre,
            width: outerCellSize.width,
            height: outerCellSize.height,
          );
          final rect = switch (layer) {
            0 => outerRect.inflate(cellSize * 0.72),
            1 => outerRect,
            _ => Rect.fromCenter(
              center: centre,
              width: coreCellSize.width,
              height: coreCellSize.height,
            ),
          };
          _writeQuad(positions, indices, quad, rect);
          quad += 1;
        }
      }
    }
    return _PixelFireMeshGeometry._(
      trackRect: trackRect,
      direction: direction,
      positions: positions,
      indices: indices,
      colors: colors,
    );
  }

  static void _writeQuad(
    Float32List positions,
    Uint16List indices,
    int quad,
    Rect rect,
  ) {
    final vertex = quad * verticesPerQuad;
    final position = vertex * 2;
    positions[position] = rect.left;
    positions[position + 1] = rect.top;
    positions[position + 2] = rect.right;
    positions[position + 3] = rect.top;
    positions[position + 4] = rect.right;
    positions[position + 5] = rect.bottom;
    positions[position + 6] = rect.left;
    positions[position + 7] = rect.bottom;

    final index = quad * indicesPerQuad;
    indices[index] = vertex;
    indices[index + 1] = vertex + 1;
    indices[index + 2] = vertex + 2;
    indices[index + 3] = vertex;
    indices[index + 4] = vertex + 2;
    indices[index + 5] = vertex + 3;
  }
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
  final _EffortPixelFieldState pixelField;
  final Listenable pixelRepaint;
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
  final Paint _pixelFireBatchPaint = Paint()
    ..isAntiAlias = false
    ..blendMode = BlendMode.screen;
  _PixelFireMeshGeometry? _pixelFireMeshGeometry;

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
    required this.pixelField,
    required this.pixelRepaint,
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
  }) : super(repaint: Listenable.merge(<Listenable>[animation, pixelRepaint]));

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

  @visibleForTesting
  Rect debugPixelPaintClipBounds(Size size) => debugActiveBounds(size);

  Rect _activeRect(Rect trackRect, double logicalPosition, double width) {
    final thumbX = _positionX(logicalPosition, width, direction);
    final underlap = CodexEffortMotionMetrics.activeFillThumbUnderlap;
    final edge =
        (direction == TextDirection.rtl ? thumbX + underlap : thumbX - underlap)
            .clamp(trackRect.left, trackRect.right)
            .toDouble();
    return direction == TextDirection.rtl
        ? Rect.fromLTRB(edge, trackRect.top, trackRect.right, trackRect.bottom)
        : Rect.fromLTRB(trackRect.left, trackRect.top, edge, trackRect.bottom);
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

  @visibleForTesting
  int get debugPixelCellCapacity => codexEffortPixelCellCapacity;

  @visibleForTesting
  double get debugPixelFieldOpacity => pixelField.opacity;

  @visibleForTesting
  double get debugPixelFieldReach => pixelField.reach;

  @visibleForTesting
  double get debugPixelFieldElapsed => pixelField.elapsed;

  @visibleForTesting
  int get debugLitPixelCellCount => pixelField.litCellCount;

  @visibleForTesting
  int get debugLitPixelRowCount => pixelField.litRowCount;

  @visibleForTesting
  double get debugPixelEnergyChecksum => pixelField.energyChecksum;

  @visibleForTesting
  double debugPixelEnergyAt(int column, int row) =>
      pixelField.energyAt(column, row);

  @visibleForTesting
  double debugPixelColumnEnergy(int column) => pixelField.columnEnergy(column);

  @visibleForTesting
  int get debugFarthestStrongPixelColumn =>
      pixelField.farthestColumnAbove(0.08);

  @visibleForTesting
  int get debugLowestStrongPixelColumn => pixelField.lowestColumnAbove(0.08);

  @visibleForTesting
  int get debugLowestVisiblePixelColumn => pixelField.lowestColumnAbove(0.012);

  @visibleForTesting
  int get debugStrongPixelColumnCount => pixelField.columnCountAbove(0.08);

  @visibleForTesting
  Rect debugPixelFieldBounds(Size size) => _trackRectForSize(size);

  @visibleForTesting
  double debugPixelColumnCenterX(Size size, int column) {
    final track = _trackRectForSize(size);
    final logical = ClaudeRangeSliderFireSimulation.columnCenter(column);
    return direction == TextDirection.rtl
        ? track.right - logical * track.width
        : track.left + logical * track.width;
  }

  @visibleForTesting
  Size debugPixelCellSize(Size size) {
    final track = _trackRectForSize(size);
    return Size(
      track.width / ClaudeRangeSliderFireSimulation.columns,
      track.height / ClaudeRangeSliderFireSimulation.rows,
    );
  }

  @visibleForTesting
  bool get debugPixelFieldFlowsToPhysicalLeft =>
      direction == TextDirection.ltr &&
      _accentUsesPersistentFire(pixelField.accent);

  @visibleForTesting
  bool get debugPixelFieldFlowsToPhysicalRight =>
      direction == TextDirection.rtl &&
      _accentUsesPersistentFire(pixelField.accent);

  @visibleForTesting
  bool get debugIsTierReveal => _isTierReveal;

  @visibleForTesting
  bool get debugIsDragging => motion == _EffortMotion.drag;

  @visibleForTesting
  int get debugBurstParticleCount =>
      ClaudeEffortMotionTokens.burstParticleCount(_targetAccent);

  @visibleForTesting
  double debugBurstProgress(int index) =>
      ClaudeEffortMotionTokens.burstProgress(
        accent: _targetAccent,
        phase: reduceMotion ? 1 : animation.value,
        positionInterval: maxPositionInterval,
        particle: ClaudeEffortMotionTokens.burstParticles[index],
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
      final trackBlend = ClaudeEffortMotionTokens.pixelTrackBlend(targetAccent);
      final trackColours = activeColours
          .map((color) => Color.lerp(inactive, color, trackBlend)!)
          .toList(growable: false);
      activePaint.shader = LinearGradient(
        begin: direction == TextDirection.rtl
            ? Alignment.centerRight
            : Alignment.centerLeft,
        end: direction == TextDirection.rtl
            ? Alignment.centerLeft
            : Alignment.centerRight,
        colors: trackColours,
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
      var tickAlphaMultiplier = 1 - _clampUnit(pixelField.opacity) * 0.72;
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

    if (!reduceMotion) {
      canvas.save();
      canvas.clipRRect(trackRRect);
      canvas.clipRect(activeRect);
      _paintPixelFire(canvas, trackRect);
      canvas.restore();
      if (_isTierReveal) {
        _paintArrivalBurst(
          canvas,
          Offset(thumbX, centerY),
          phase,
          targetAccent,
        );
      }
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
    final thumbRect = Rect.fromCircle(center: thumbCenter, radius: thumbRadius);
    canvas.drawCircle(
      thumbCenter,
      thumbRadius,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [activeColours.first, activeColours.last],
        ).createShader(thumbRect),
    );
    canvas.drawCircle(
      thumbCenter,
      math.max(0, thumbRadius - 0.75),
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

  void _paintPixelFire(Canvas canvas, Rect trackRect) {
    final fieldOpacity = _clampUnit(pixelField.opacity);
    if (fieldOpacity <= 0.001 || trackRect.isEmpty) return;

    var geometry = _pixelFireMeshGeometry;
    if (geometry == null || !geometry.matches(trackRect, direction)) {
      geometry = _PixelFireMeshGeometry.create(trackRect, direction);
      _pixelFireMeshGeometry = geometry;
    }

    const columns = ClaudeRangeSliderFireSimulation.columns;
    const rows = ClaudeRangeSliderFireSimulation.rows;
    const cells = ClaudeRangeSliderFireSimulation.cellCount;
    final maskEnd = math.min(1.0, pixelField.slider + 0.02);
    final colors = geometry.colors..fillRange(0, geometry.colors.length, 0);

    for (var column = 0; column < columns; column++) {
      final logicalX = ClaudeRangeSliderFireSimulation.columnCenter(column);
      if (logicalX > maskEnd) continue;
      for (var row = 0; row < rows; row++) {
        final cell = column * rows + row;
        final red = pixelField.redAtIndex(cell);
        final green = pixelField.greenAtIndex(cell);
        final blue = pixelField.blueAtIndex(cell);
        final value = red * 0.2126 + green * 0.7152 + blue * 0.0722;
        final glowRed = pixelField.glowRedAtIndex(cell);
        final glowGreen = pixelField.glowGreenAtIndex(cell);
        final glowBlue = pixelField.glowBlueAtIndex(cell);
        final glowLuminance =
            glowRed * 0.2126 + glowGreen * 0.7152 + glowBlue * 0.0722;
        if (value <= 0.008 && glowLuminance <= 0.008) continue;

        if (glowLuminance > 0.008) {
          _setPixelQuadColor(
            colors,
            cell,
            _pixelArgb32(
              glowRed,
              glowGreen,
              glowBlue,
              fieldOpacity * math.min(0.32, glowLuminance * 0.22),
            ),
          );
        }
        if (value > 0.008) {
          _setPixelQuadColor(
            colors,
            cells + cell,
            _pixelArgb32(
              red,
              green,
              blue,
              fieldOpacity * math.min(0.58, value * 0.72),
            ),
          );
          _setPixelQuadColor(
            colors,
            cells * 2 + cell,
            _pixelArgb32(
              red,
              green,
              blue,
              fieldOpacity * math.min(1.0, value * 1.34),
            ),
          );
        }
      }
    }

    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      geometry.positions,
      colors: colors,
      indices: geometry.indices,
    );
    canvas.drawVertices(vertices, BlendMode.dst, _pixelFireBatchPaint);
    vertices.dispose();
  }

  void _setPixelQuadColor(Int32List colors, int quad, int color) {
    final vertex = quad * _PixelFireMeshGeometry.verticesPerQuad;
    colors[vertex] = color;
    colors[vertex + 1] = color;
    colors[vertex + 2] = color;
    colors[vertex + 3] = color;
  }

  int _pixelArgb32(double red, double green, double blue, double opacity) {
    final alpha = (_clampUnit(opacity) * 255).round();
    final redChannel = (_clampUnit(red) * 255).round();
    final greenChannel = (_clampUnit(green) * 255).round();
    final blueChannel = (_clampUnit(blue) * 255).round();
    return (alpha << 24) |
        (redChannel << 16) |
        (greenChannel << 8) |
        blueChannel;
  }

  void _paintArrivalBurst(
    Canvas canvas,
    Offset origin,
    double phase,
    ClaudeEffortAccent accent,
  ) {
    final count = ClaudeEffortMotionTokens.burstParticleCount(accent);
    final particlePaint = Paint();
    for (var index = 0; index < count; index++) {
      final particle = ClaudeEffortMotionTokens.burstParticles[index];
      final progress = ClaudeEffortMotionTokens.burstProgress(
        accent: accent,
        phase: phase,
        positionInterval: maxPositionInterval,
        particle: particle,
      );
      if (progress < 0) continue;
      final opacity = ClaudeEffortMotionTokens.burstOpacity(progress);
      if (opacity <= 0.001) continue;
      final eased = Curves.easeOutCubic.transform(progress);
      final distance = particle.distance * eased;
      final point =
          origin + Offset(particle.unitX * distance, particle.unitY * distance);
      particlePaint.color = ClaudeEffortMotionTokens.burstColor(
        primary: primary,
        purple: purple,
        progress: progress,
      ).withValues(alpha: opacity);
      canvas.drawCircle(
        point,
        particle.radius * (1 - progress * 0.35),
        particlePaint,
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
