import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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

class _EffortPixelFieldState {
  static const int _columns = ClaudeEffortMotionTokens.pixelColumns;
  static const int _rows = ClaudeEffortMotionTokens.maxPixelRows;

  ClaudeEffortAccent accent = ClaudeEffortAccent.standard;
  double elapsed = 0;
  double opacity = 0;
  double anchorX = 0;
  double reach = 0;
  double _reachFrom = 0;
  double _reachTo = 0;
  double _reachTransitionElapsed = 0;
  double _reachTransitionDuration = 0.01;
  double _reachCellDelay = 0;
  List<double> _energy = List<double>.filled(
    codexEffortPixelCellCapacity,
    0,
    growable: false,
  );
  List<double> _nextEnergy = List<double>.filled(
    codexEffortPixelCellCapacity,
    0,
    growable: false,
  );

  List<double> get energy => _energy;

  int get litCellCount => _energy.where((value) => value > 0.045).length;

  double columnEnergy(int column) {
    assert(column >= 0 && column < _columns);
    var total = 0.0;
    for (var row = 0; row < _rows; row++) {
      total += _energy[column * _rows + row];
    }
    return total / _rows;
  }

  int farthestColumnAbove(double threshold) {
    for (var column = _columns - 1; column >= 0; column--) {
      for (var row = 0; row < _rows; row++) {
        if (_energy[column * _rows + row] > threshold) return column;
      }
    }
    return -1;
  }

  int columnCountAbove(double threshold) {
    var result = 0;
    for (var column = 0; column < _columns; column++) {
      var strong = false;
      for (var row = 0; row < _rows; row++) {
        if (_energy[column * _rows + row] > threshold) {
          strong = true;
          break;
        }
      }
      if (strong) result += 1;
    }
    return result;
  }

  int get litRowCount {
    var result = 0;
    for (var row = 0; row < _rows; row++) {
      var lit = false;
      for (var column = 0; column < _columns; column++) {
        if (_energy[column * _rows + row] > 0.045) {
          lit = true;
          break;
        }
      }
      if (lit) result += 1;
    }
    return result;
  }

  double get energyChecksum {
    var result = 0.0;
    for (var index = 0; index < _energy.length; index++) {
      result += _energy[index] * (index + 1);
    }
    return result;
  }

  double energyAt(int column, int row) {
    assert(column >= 0 && column < _columns);
    assert(row >= 0 && row < _rows);
    return _energy[column * _rows + row];
  }

  void activate(ClaudeEffortAccent nextAccent, {required bool restart}) {
    if (accent == nextAccent && !restart) return;
    final wasVisible = accent != ClaudeEffortAccent.standard && opacity > 0.001;
    if (!wasVisible) {
      elapsed = 0;
      reach = 0;
    }
    _reachFrom = reach;
    _reachTo = ClaudeEffortMotionTokens.pixelReach(nextAccent);
    _reachTransitionElapsed = 0;
    _reachTransitionDuration = wasVisible
        ? 0.36
        : ClaudeEffortMotionTokens.pixelGrowthSeconds(nextAccent);
    _reachCellDelay = wasVisible
        ? 0.18
        : ClaudeEffortMotionTokens.pixelCellDelaySeconds(nextAccent);
    accent = nextAccent;
  }

  void settleInitial(ClaudeEffortAccent initialAccent) {
    accent = initialAccent;
    elapsed = ClaudeEffortMotionTokens.pixelGrowthSeconds(initialAccent);
    opacity = 1;
    reach = ClaudeEffortMotionTokens.pixelReach(initialAccent);
    _reachFrom = reach;
    _reachTo = reach;
    _reachCellDelay = ClaudeEffortMotionTokens.pixelCellDelaySeconds(
      initialAccent,
    );
    _reachTransitionElapsed = _reachTransitionDuration + _reachCellDelay;
    _primeSettledField();
  }

  void advanceReach(double deltaSeconds) {
    _reachTransitionElapsed = math.min(
      _reachTransitionDuration + _reachCellDelay,
      _reachTransitionElapsed + deltaSeconds,
    );
    final progress = _reachTransitionDuration <= 0
        ? 1.0
        : _clampUnit(_reachTransitionElapsed / _reachTransitionDuration);
    final eased = math.pow(progress, 0.72).toDouble();
    reach = lerpDouble(_reachFrom, _reachTo, eased)!;
  }

  void advanceEnergy(double deltaSeconds) {
    final activeRows = ClaudeEffortMotionTokens.pixelRows(accent);
    final density = ClaudeEffortMotionTokens.pixelDensity(accent);
    final flow = ClaudeEffortMotionTokens.pixelFlowSpeed(accent);
    // Retain enough of the previous frame to resemble the reference's
    // feedback texture, but always blend back toward the current target. The
    // old max(previous, target) rule latched bright pixels indefinitely and
    // made the trail look like a static bitmap.
    final feedbackRetention = math.pow(0.88, deltaSeconds * 30).toDouble();
    final targetResponse = 1 - feedbackRetention;
    final safeReach = math.max(0.001, reach);
    final frontIsMoving =
        _reachTransitionElapsed < _reachTransitionDuration + _reachCellDelay;

    for (var column = 0; column < _columns; column++) {
      final distance = (column + 0.5) / _columns;
      for (var row = 0; row < _rows; row++) {
        final index = column * _rows + row;
        final previous = _energy[index];
        final seedA = ClaudeEffortMotionTokens.pixelSeed(column, row);
        final seedB = ClaudeEffortMotionTokens.pixelSeed(column + 97, row + 43);
        final seedC = ClaudeEffortMotionTokens.pixelSeed(
          column + 211,
          row + 131,
        );
        final cellDelay = seedA * _reachCellDelay;
        final cellElapsed = math.max(0.0, _reachTransitionElapsed - cellDelay);
        final cellProgress = _reachTransitionDuration <= 0
            ? 1.0
            : _clampUnit(cellElapsed / _reachTransitionDuration);
        final cellEasingPower = 0.64 + seedB * 0.20;
        final cellReach = lerpDouble(
          _reachFrom,
          _reachTo,
          math.pow(cellProgress, cellEasingPower).toDouble(),
        )!;
        if (row >= activeRows || distance > cellReach) {
          final faded = previous * feedbackRetention;
          _nextEnergy[index] = faded < 0.004 ? 0 : faded;
          continue;
        }

        final proximity = _clampUnit(1 - distance / safeReach);
        final frequencySeed = ClaudeEffortMotionTokens.pixelSeed(row + 17, 257);
        final speedSeed = ClaudeEffortMotionTokens.pixelSeed(row + 41, 409);
        final phaseSeed = ClaudeEffortMotionTokens.pixelRowPhase(row);
        final phaseA =
            elapsed * (0.58 + seedA * 0.66) +
            seedB * math.pi * 2 +
            seedC * 1.73;
        final phaseB =
            elapsed * (0.23 + seedB * 0.43) +
            seedC * math.pi * 2 +
            seedA * 4.31;
        final pulseA = 0.5 + math.sin(phaseA) * 0.5;
        final pulseB = 0.5 + math.sin(phaseB) * 0.5;
        final independentFlicker = _clampUnit(pulseA * 0.64 + pulseB * 0.36);

        // Per-row phase and per-cell jitter keep this outward-moving front
        // from collapsing into one diagonal bright line.
        final travelWave = ClaudeEffortMotionTokens.pixelTravelWave(
          distance: distance,
          elapsed: elapsed,
          flow: flow,
          frequencySeed: frequencySeed,
          speedSeed: speedSeed,
          phaseSeed: phaseSeed,
          cellSeed: seedA,
        );
        final secondaryFrequencySeed = ClaudeEffortMotionTokens.pixelSeed(
          row + 61,
          613,
        );
        final secondarySpeedSeed = ClaudeEffortMotionTokens.pixelSeed(
          row + 113,
          821,
        );
        final secondaryWave = ClaudeEffortMotionTokens.pixelTravelWave(
          distance: _clampUnit(distance * 0.86 + 0.06),
          elapsed: elapsed * 0.73,
          flow: flow * 0.86,
          frequencySeed: secondaryFrequencySeed,
          speedSeed: secondarySpeedSeed,
          phaseSeed: ClaudeEffortMotionTokens.pixelRowPhase(
            row,
            secondary: true,
          ),
          cellSeed: seedC,
        );
        final flowWave = math.max(travelWave, secondaryWave * 0.42);
        final turbulence = _clampUnit(
          0.46 +
              math.sin(phaseA) * 0.22 +
              math.sin(phaseB) * 0.16 +
              (flowWave - 0.35) * 0.24,
        );

        final gatePulse =
            0.5 +
            math.sin(elapsed * (0.31 + seedA * 0.49) + seedC * math.pi * 2) *
                0.5;
        final animatedGate = seedB * 0.56 + gatePulse * 0.44;
        final visibility =
            density * (0.34 + proximity * 0.68) +
            (independentFlicker - 0.5) * 0.24 +
            flowWave * 0.15;
        final visible = animatedGate < visibility;

        final frontGap = (cellReach - distance).abs();
        final frontFlash = frontIsMoving
            ? math.exp(-math.pow(frontGap / 0.046, 2)) * (0.32 + seedA * 0.48)
            : 0.0;
        final sparkCycle =
            (elapsed * (0.080 + seedA * 0.052) + seedC * 13.7) % 1.0;
        final spark = sparkCycle < 0.028 && seedA > 0.57
            ? math.pow(1 - sparkCycle / 0.028, 2).toDouble() * 0.72
            : 0.0;
        final core =
            math.exp(-distance * 24) * (0.70 + independentFlicker * 0.38);
        final randomTarget = visible
            ? _clampUnit(
                (0.05 + proximity * 0.34 + turbulence * 0.20 + core) *
                    (0.48 + independentFlicker * 0.62) *
                    (0.35 + proximity * 0.65),
              )
            : 0.0;
        // The traveling structure must remain visible across the whole active
        // reach. Random per-cell flicker modulates it, but no longer decides
        // whether the flow exists at all.
        final flowTarget = _clampUnit(
          flowWave *
              (0.44 + density * 0.44) *
              (0.80 + proximity * 0.20) *
              (0.88 + independentFlicker * 0.18),
        );
        final localTarget = _clampUnit(
          math.max(randomTarget, flowTarget) + frontFlash + spark,
        );

        // Feed a bounded amount of the previous column into this one. Columns
        // increase away from the thumb, so this is a real outward advection
        // path rather than a globally synchronized alpha pulse.
        var advected = 0.0;
        if (column > 0) {
          final upstream = _energy[(column - 1) * _rows + row];
          final neighbourRow = seedC < 0.5
              ? math.max(0, row - 1)
              : math.min(activeRows - 1, row + 1);
          final neighbour = _energy[(column - 1) * _rows + neighbourRow];
          final upstreamEnergy = math.max(upstream, neighbour * 0.58);
          advected =
              upstreamEnergy * (0.55 + flowWave * 0.28) * (0.80 + flow * 0.22);
        }
        final target = math.max(localTarget, advected);
        final smoothed = previous * feedbackRetention + target * targetResponse;
        // Front/spark impulses may appear immediately, but the next frame goes
        // back through feedback decay so they cannot latch permanently.
        final impulse = math.max(frontFlash * 0.82, spark);
        final next = _clampUnit(math.max(smoothed, impulse));
        _nextEnergy[index] = next < 0.004 ? 0 : next;
      }
    }

    final oldEnergy = _energy;
    _energy = _nextEnergy;
    _nextEnergy = oldEnergy;
  }

  void decayEnergy(double deltaSeconds) {
    final decay = math.pow(0.78, deltaSeconds * 30).toDouble();
    for (var index = 0; index < _energy.length; index++) {
      final value = _energy[index] * decay;
      _energy[index] = value < 0.004 ? 0 : value;
    }
  }

  void _primeSettledField() {
    final activeRows = ClaudeEffortMotionTokens.pixelRows(accent);
    final density = ClaudeEffortMotionTokens.pixelDensity(accent);
    for (var column = 0; column < _columns; column++) {
      final distance = (column + 0.5) / _columns;
      final proximity = _clampUnit(1 - distance / math.max(0.001, reach));
      for (var row = 0; row < _rows; row++) {
        final index = column * _rows + row;
        final seed = ClaudeEffortMotionTokens.pixelSeed(column, row);
        final secondary = ClaudeEffortMotionTokens.pixelSeed(
          column + 97,
          row + 43,
        );
        final visible =
            row < activeRows &&
            distance <= reach + (seed - 0.5) * 0.035 &&
            secondary < density * (0.42 + proximity * 0.70);
        _energy[index] = visible
            ? _clampUnit(0.16 + proximity * 0.63 + seed * 0.21)
            : 0;
      }
    }
  }

  void clear() {
    accent = ClaudeEffortAccent.standard;
    elapsed = 0;
    opacity = 0;
    reach = 0;
    _reachFrom = 0;
    _reachTo = 0;
    _reachTransitionElapsed = 0;
    _reachTransitionDuration = 0.01;
    _reachCellDelay = 0;
    _energy.fillRange(0, _energy.length, 0);
    _nextEnergy.fillRange(0, _nextEnergy.length, 0);
  }
}

class _PixelFieldRepaint extends ChangeNotifier {
  void markNeedsPaint() => notifyListeners();
}

/// A discrete, self-painted effort slider modelled after the Codex Desktop
/// control. Tier transitions use one finite [AnimationController]. A separate
/// 30 fps ticker drives a deterministic fixed-grid pixel fire only while a
/// high tier is visible; it never allocates particle state per frame.
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
  Duration? _lastPixelTick;
  double _sliderWidth = 0;
  TextDirection _sliderDirection = TextDirection.ltr;

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
    if (initialAccent != ClaudeEffortAccent.standard) {
      _pixelField.settleInitial(initialAccent);
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
          currentAccent != ClaudeEffortAccent.standard &&
          currentAccent != previousAccent,
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
      _sliderWidth > 0 &&
      _accentForIndex(_selectedIndex) != ClaudeEffortAccent.standard;

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
      final shouldRestart = restart || _pixelField.accent != accent;
      _pixelField.activate(accent, restart: shouldRestart);
      _updatePixelAnchor();
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
        _pixelField.activate(accent, restart: true);
      }
      _updatePixelAnchor();
      _pixelField.elapsed += elapsedSeconds;
      _pixelField.advanceReach(elapsedSeconds);
      _pixelField.advanceEnergy(elapsedSeconds);
      _pixelField.opacity = math.min(
        1,
        _pixelField.opacity + elapsedSeconds / 0.22,
      );
    } else {
      _pixelField.elapsed += elapsedSeconds.clamp(0.0, 0.05).toDouble();
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

  void _updatePixelAnchor() {
    if (_sliderWidth <= 0) return;
    final position = _positionAt(_controller.value);
    final thumbX = _positionX(position, _sliderWidth, _sliderDirection);
    final innerThumbEdge = CodexEffortMotionMetrics.thumbDiameter / 2 - 2;
    _pixelField.anchorX = _sliderDirection == TextDirection.rtl
        ? thumbX + innerThumbEdge
        : thumbX - innerThumbEdge;
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
    _pendingFastAfterTierReveal = null;
    final generation = ++_animationGeneration;
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
    _animationGeneration += 1;
    _pendingFastAfterTierReveal = null;
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
            _sliderWidth = width;
            _sliderDirection = direction;
            if (_shouldAnimatePixelField && !_pixelTicker.isActive) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _syncPixelTicker();
              });
            }
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
  int get debugStrongPixelColumnCount => pixelField.columnCountAbove(0.08);

  @visibleForTesting
  Rect debugPixelFieldBounds(Size size) {
    final track = _trackRectForSize(size);
    final anchor = pixelField.anchorX.clamp(track.left, track.right);
    if (direction == TextDirection.rtl) {
      final right = anchor + (track.right - anchor) * pixelField.reach;
      return Rect.fromLTRB(
        math.max(track.left, anchor),
        track.top,
        math.min(track.right, right),
        track.bottom,
      );
    }
    final left = anchor - (anchor - track.left) * pixelField.reach;
    return Rect.fromLTRB(
      math.max(track.left, left),
      track.top,
      math.min(track.right, anchor),
      track.bottom,
    );
  }

  @visibleForTesting
  bool get debugPixelFieldFlowsToPhysicalLeft =>
      direction == TextDirection.ltr &&
      ClaudeEffortMotionTokens.pixelFlowSpeed(pixelField.accent) >= 0;

  @visibleForTesting
  bool get debugPixelFieldFlowsToPhysicalRight =>
      direction == TextDirection.rtl &&
      ClaudeEffortMotionTokens.pixelFlowSpeed(pixelField.accent) >= 0;

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

    final anchorX = pixelField.anchorX.clamp(trackRect.left, trackRect.right);
    final availableTrail = direction == TextDirection.rtl
        ? math.max(0.0, trackRect.right - anchorX)
        : math.max(0.0, anchorX - trackRect.left);
    final columns = ClaudeEffortMotionTokens.pixelColumns;
    final rows = ClaudeEffortMotionTokens.maxPixelRows;
    if (availableTrail <= 1 || columns <= 0 || rows <= 0) return;

    final columnStep = availableTrail / columns;
    final top = trackRect.top + 3;
    final bottom = trackRect.bottom - 3;
    final rowStep = (bottom - top) / math.max(1, rows - 1);
    final energy = pixelField.energy;
    final pixelPaint = Paint()..isAntiAlias = false;
    final glowPaint = Paint()..isAntiAlias = false;
    for (var column = 0; column < columns; column++) {
      final normalizedDistance = (column + 0.5) / columns;
      final columnOffset = (column + 0.5) * columnStep;
      final x = direction == TextDirection.rtl
          ? anchorX + columnOffset
          : anchorX - columnOffset;
      final proximity = _clampUnit(
        1 - normalizedDistance / math.max(0.001, pixelField.reach),
      );
      for (var row = 0; row < rows; row++) {
        final value = energy[column * rows + row];
        if (value <= 0.016) continue;
        final heat = _clampUnit(value * 0.72 + proximity * 0.42);
        final alpha = fieldOpacity * math.pow(value, 0.70).toDouble();
        final basePixelSize = columnStep >= 2.6 ? 2.0 : 1.0;
        final pixelSize = value > 0.78
            ? math.min(3.0, basePixelSize + 1)
            : basePixelSize;
        final y = top + row * rowStep;
        final rect = Rect.fromLTWH(
          (x - pixelSize / 2).roundToDouble(),
          (y - pixelSize / 2).roundToDouble(),
          pixelSize,
          pixelSize,
        );
        final color = ClaudeEffortMotionTokens.pixelColor(
          purple: purple,
          heat: heat,
        );
        if (value > 0.58) {
          glowPaint.color = color.withValues(alpha: _clampUnit(alpha * 0.12));
          canvas.drawRect(rect.inflate(1.2), glowPaint);
        }
        pixelPaint.color = color.withValues(alpha: _clampUnit(alpha));
        canvas.drawRect(rect, pixelPaint);
      }
    }
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
