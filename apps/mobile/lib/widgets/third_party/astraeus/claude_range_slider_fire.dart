// SPDX-License-Identifier: GPL-2.0-only
//
// Copyright (C) 2026 Astraeus
// Dart adaptation for the CC Pocket compatibility fork, 2026.
//
// Derived from Astraeuszhao/UI/claude-range-slider at revision
// 528cf0a6899d1a0c71bbb91e7dc7eaca75fdeafa, specifically the fixed 72x6
// fire simulation, separable blur, and tone-map composite pipeline in
// shaders/index.ts and hooks/useWebglFire.ts.
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 only. See the
// repository LICENSE and THIRD_PARTY_NOTICES.md files for the complete terms
// and attribution.

import 'dart:math' as math;

/// CC Pocket's two persistent fire treatments.
///
/// [ultra] keeps the GPL reference palette. [max] is the local extension: it
/// uses the same simulation on the same fixed grid, but with a cooler palette
/// and lower intensity so the two wire-level effort tiers remain distinct.
enum ClaudeRangeSliderFireTier { max, ultra }

/// CPU-side, fixed-grid adaptation of the reference WebGL fire pipeline.
///
/// The original renderer evaluates the simulation for every canvas pixel. The
/// mobile adaptation evaluates the same equations at the centre of each of the
/// reference's 72-by-6 cells, then lets the Flutter painter provide the crisp
/// cell shape and screen-blended halo. Crucially, these UV coordinates never
/// depend on the thumb position: dragging changes only [slider], the ignition
/// mask, and the front computed by the simulation.
final class ClaudeRangeSliderFireSimulation {
  ClaudeRangeSliderFireSimulation();

  static const int columns = 72;
  static const int rows = 6;
  static const int cellCount = columns * rows;
  static const double fixedStepSeconds = 1 / 60;
  static const int referenceSettleFrames = 228;
  static const int defaultSettleFeedbackFrames = 72;
  static const int maxCatchUpSteps = 2;

  static const double _blurCentre = 0.227027;
  static const double _blurOne = 0.194595;
  static const double _blurTwo = 0.121622;
  static const double _blurThree = 0.054054;
  static const List<int> _blurSampleOffsets = <int>[0, 1, -1, 2, -2, 3, -3];
  static const List<double> _blurSampleWeights = <double>[
    _blurCentre,
    _blurOne,
    _blurOne,
    _blurTwo,
    _blurTwo,
    _blurThree,
    _blurThree,
  ];

  static final List<double> _columnCenters = List<double>.generate(
    columns,
    (column) => (column + 0.5) / columns,
    growable: false,
  );
  static final List<double> _rowCenters = List<double>.generate(
    rows,
    (row) => (row + 0.5) / rows,
    growable: false,
  );
  static final List<double> _columnFadeMasks = List<double>.generate(
    columns,
    (column) => _smoothStep(0, 0.45, _columnCenters[column]),
    growable: false,
  );
  static final List<double> _rowVerticalEnvelopes = List<double>.generate(
    rows,
    (row) {
      final vertical = (_rowCenters[row] - 0.5).abs() * 2;
      return math
          .pow(math.max(1 - vertical * vertical * 0.45, 0.0), 0.75)
          .toDouble();
    },
    growable: false,
  );
  static final List<double> _cellHashes = List<double>.generate(
    cellCount,
    (index) => _hash((index ~/ rows).toDouble(), (index % rows).toDouble()),
    growable: false,
  );
  static final List<double> _secondCellHashes = List<double>.generate(
    cellCount,
    (index) => _hash(index ~/ rows + 99.0, index % rows + 33.0),
    growable: false,
  );
  static final List<double> _cellSpeeds = List<double>.generate(
    cellCount,
    (index) => 0.85 + _cellHashes[index] * 0.30,
    growable: false,
  );
  static final List<double> _cellOffsets = List<double>.generate(
    cellCount,
    (index) => (_cellHashes[index] - 0.5) * 0.05,
    growable: false,
  );

  List<double> _sceneR = List<double>.filled(cellCount, 0, growable: false);
  List<double> _sceneG = List<double>.filled(cellCount, 0, growable: false);
  List<double> _sceneB = List<double>.filled(cellCount, 0, growable: false);
  List<double> _nextR = List<double>.filled(cellCount, 0, growable: false);
  List<double> _nextG = List<double>.filled(cellCount, 0, growable: false);
  List<double> _nextB = List<double>.filled(cellCount, 0, growable: false);
  final List<double> _blurHorizontalR = List<double>.filled(
    cellCount,
    0,
    growable: false,
  );
  final List<double> _blurHorizontalG = List<double>.filled(
    cellCount,
    0,
    growable: false,
  );
  final List<double> _blurHorizontalB = List<double>.filled(
    cellCount,
    0,
    growable: false,
  );
  final List<double> _glowR = List<double>.filled(
    cellCount,
    0,
    growable: false,
  );
  final List<double> _glowG = List<double>.filled(
    cellCount,
    0,
    growable: false,
  );
  final List<double> _glowB = List<double>.filled(
    cellCount,
    0,
    growable: false,
  );
  final List<double> _compositeR = List<double>.filled(
    cellCount,
    0,
    growable: false,
  );
  final List<double> _compositeG = List<double>.filled(
    cellCount,
    0,
    growable: false,
  );
  final List<double> _compositeB = List<double>.filled(
    cellCount,
    0,
    growable: false,
  );

  bool _active = false;
  ClaudeRangeSliderFireTier _tier = ClaudeRangeSliderFireTier.ultra;
  double _accumulator = 0;
  double _time = 0;
  double _elapsed = -1;
  double _slider = 0;
  double _blurOffsetColumns = 0.14;
  double _blurOffsetRows = 0.15;

  bool get active => _active;
  ClaudeRangeSliderFireTier get tier => _tier;
  double get elapsed => math.max(0, _elapsed);
  double get slider => _slider;

  /// Approximate position of the delayed ignition front for diagnostics.
  double get reach {
    if (_elapsed < 0) return 0;
    final progress = _clamp(_elapsed / 2.5);
    return 1 - math.pow(1 - progress, 3).toDouble();
  }

  static double columnCenter(int column) =>
      _columnCenters[column.clamp(0, columns - 1).toInt()];

  static double rowCenter(int row) =>
      _rowCenters[row.clamp(0, rows - 1).toInt()];

  void setSlider(double value) {
    _slider = _clamp(value);
  }

  /// Mirrors `u_dir * 1.8 / u_res` from the reference blur shader.
  ///
  /// The simulation stores one value per logical grid cell, so framebuffer
  /// pixel offsets are converted back into column/row fractions.
  void setFramebufferMetrics({
    required double width,
    required double height,
    required double devicePixelRatio,
  }) {
    if (width <= 0 || height <= 0 || devicePixelRatio <= 0) return;
    _blurOffsetColumns = 1.8 * columns / (width * devicePixelRatio);
    _blurOffsetRows = 1.8 * rows / (height * devicePixelRatio);
  }

  void ignite({
    required double slider,
    ClaudeRangeSliderFireTier tier = ClaudeRangeSliderFireTier.ultra,
    bool restart = false,
  }) {
    setSlider(slider);
    _tier = tier;
    if (!_active || restart) {
      _clearFrames();
      _accumulator = 0;
      _elapsed = 0;
    }
    _active = true;
  }

  void extinguish({required double slider}) {
    setSlider(slider);
    _active = false;
    _elapsed = -1;
  }

  /// Produces a mature first frame without replaying the ignition when a
  /// session opens with Max or Ultra already selected.
  ///
  /// The absolute shader time still lands at the reference's 228th frame. Only
  /// the final feedback window is evaluated because earlier contributions are
  /// below 0.06% after 72 iterations of the source's 0.90 decay.
  void settle({
    required double slider,
    ClaudeRangeSliderFireTier tier = ClaudeRangeSliderFireTier.ultra,
    int feedbackFrames = defaultSettleFeedbackFrames,
  }) {
    setSlider(slider);
    _tier = tier;
    _clearFrames();
    _active = true;
    _accumulator = 0;
    final boundedFeedbackFrames = feedbackFrames
        .clamp(1, referenceSettleFrames)
        .toInt();
    final skippedFrames = referenceSettleFrames - boundedFeedbackFrames;
    _time = skippedFrames * fixedStepSeconds;
    _elapsed = _time;
    for (var frame = 0; frame < boundedFeedbackFrames; frame++) {
      _stepFrame();
    }
  }

  void advance(double deltaSeconds) {
    _accumulator += deltaSeconds.clamp(0.0, 0.12).toDouble();
    final availableSteps = (_accumulator / fixedStepSeconds).floor();
    final skippedSteps = math.max(0, availableSteps - maxCatchUpSteps);
    if (skippedSteps > 0) _skipSimulationFrames(skippedSteps);
    final simulatedSteps = math.min(availableSteps, maxCatchUpSteps);
    for (var step = 0; step < simulatedSteps; step++) {
      _stepFrame();
    }
    _accumulator -= availableSteps * fixedStepSeconds;
  }

  /// Drops stale simulation work after a long UI frame while preserving the
  /// last visible feedback buffer. Decaying that buffer without also evaluating
  /// the skipped source frames produces a conspicuous brightness dip, so only
  /// the shader clocks advance before the final bounded catch-up steps run.
  void _skipSimulationFrames(int count) {
    _time += count * fixedStepSeconds;
    if (_active) _elapsed += count * fixedStepSeconds;
  }

  void clear() {
    _active = false;
    _tier = ClaudeRangeSliderFireTier.ultra;
    _accumulator = 0;
    _time = 0;
    _elapsed = -1;
    _slider = 0;
    _clearFrames();
  }

  double redAt(int column, int row) => _compositeR[_index(column, row)];
  double greenAt(int column, int row) => _compositeG[_index(column, row)];
  double blueAt(int column, int row) => _compositeB[_index(column, row)];
  double glowRedAt(int column, int row) => _glowR[_index(column, row)];
  double glowGreenAt(int column, int row) => _glowG[_index(column, row)];
  double glowBlueAt(int column, int row) => _glowB[_index(column, row)];

  double redAtIndex(int index) => _compositeR[index];
  double greenAtIndex(int index) => _compositeG[index];
  double blueAtIndex(int index) => _compositeB[index];
  double glowRedAtIndex(int index) => _glowR[index];
  double glowGreenAtIndex(int index) => _glowG[index];
  double glowBlueAtIndex(int index) => _glowB[index];

  double luminanceAt(int column, int row) {
    final index = _index(column, row);
    return _luminance(
      _compositeR[index],
      _compositeG[index],
      _compositeB[index],
    );
  }

  int get litCellCount => _countCellsAbove(0.045);

  int get litRowCount {
    var count = 0;
    for (var row = 0; row < rows; row++) {
      var lit = false;
      for (var column = 0; column < columns; column++) {
        if (luminanceAt(column, row) > 0.045) {
          lit = true;
          break;
        }
      }
      if (lit) count += 1;
    }
    return count;
  }

  double get energyChecksum {
    var total = 0.0;
    for (var index = 0; index < cellCount; index++) {
      total +=
          _luminance(
            _compositeR[index],
            _compositeG[index],
            _compositeB[index],
          ) *
          (index + 1);
    }
    return total;
  }

  double columnEnergy(int column) {
    final safeColumn = column.clamp(0, columns - 1).toInt();
    var total = 0.0;
    for (var row = 0; row < rows; row++) {
      total += luminanceAt(safeColumn, row);
    }
    return total / rows;
  }

  int lowestColumnAbove(double threshold) {
    for (var column = 0; column < columns; column++) {
      for (var row = 0; row < rows; row++) {
        if (luminanceAt(column, row) > threshold) return column;
      }
    }
    return -1;
  }

  int highestColumnAbove(double threshold) {
    for (var column = columns - 1; column >= 0; column--) {
      for (var row = 0; row < rows; row++) {
        if (luminanceAt(column, row) > threshold) return column;
      }
    }
    return -1;
  }

  int columnCountAbove(double threshold) {
    var count = 0;
    for (var column = 0; column < columns; column++) {
      var strong = false;
      for (var row = 0; row < rows; row++) {
        if (luminanceAt(column, row) > threshold) {
          strong = true;
          break;
        }
      }
      if (strong) count += 1;
    }
    return count;
  }

  int _countCellsAbove(double threshold) {
    var count = 0;
    for (var column = 0; column < columns; column++) {
      for (var row = 0; row < rows; row++) {
        if (luminanceAt(column, row) > threshold) count += 1;
      }
    }
    return count;
  }

  void _stepFrame() {
    _time += fixedStepSeconds;
    if (_active) _elapsed += fixedStepSeconds;
    _simulatePass();
    _horizontalBlurPass();
    _verticalBlurPass();
    _compositePass();
    final oldR = _sceneR;
    final oldG = _sceneG;
    final oldB = _sceneB;
    _sceneR = _nextR;
    _sceneG = _nextG;
    _sceneB = _nextB;
    _nextR = oldR;
    _nextG = oldG;
    _nextB = oldB;
  }

  void _simulatePass() {
    // The reference activates at slider == 1. CC Pocket deliberately extends
    // the same fire to Max as well, so tier activation is explicit while the
    // actual slider value still controls the front and mask geometry.
    final activation = _tier == ClaudeRangeSliderFireTier.max
        ? 1.0
        : _smoothStep(0.95, 1, _slider);
    final energyScale = _mix(0.15, 0.50, math.min(_elapsed / 1.0, 1.0));
    final timeScale = _mix(0.85, 1.0, math.min(_elapsed / 1.5, 1.0));
    final pulse = math.sin(_time * 2.8) * 0.15 + 1;
    final isMax = _tier == ClaudeRangeSliderFireTier.max;
    final emberR = isMax ? 0.12 : 0.28;
    const emberG = 0.10;
    final emberB = isMax ? 0.50 : 0.58;
    final purpleR = isMax ? 0.34 : 0.62;
    final purpleG = isMax ? 0.42 : 0.32;
    const purpleB = 1.0;
    final whiteR = isMax ? 0.82 : 1.0;
    final whiteG = isMax ? 0.91 : 0.94;
    final whiteB = isMax ? 1.0 : 0.98;
    final tierIntensity = isMax ? 0.74 : 1.0;
    for (var column = 0; column < columns; column++) {
      final uvX = _columnCenters[column];
      final fadeMask = _columnFadeMasks[column];
      final core = math.exp(-math.pow((uvX - _slider) * 16, 2));
      final wideCore = math.exp(-math.pow((uvX - _slider) * 3.5, 2));
      for (var row = 0; row < rows; row++) {
        final index = _index(column, row);
        final uvY = _rowCenters[row];
        final cellHash = _cellHashes[index];
        final decayR = _sceneR[index] * 0.90 * fadeMask;
        final decayG = _sceneG[index] * 0.90 * fadeMask;
        final decayB = _sceneB[index] * 0.90 * fadeMask;
        if (activation < 0.01 || _elapsed < 0) {
          _nextR[index] = decayR;
          _nextG[index] = decayG;
          _nextB[index] = decayB;
          continue;
        }

        final cellAge = math.max(_elapsed - cellHash * 1.2, 0.0);
        final ignited = _step(0.001, cellAge);
        final cellSpeed = _cellSpeeds[index];
        final growth = _clamp(cellAge / 2.5);
        final eased = 1 - math.pow(1 - growth, 3).toDouble();
        final distance = eased * _slider * cellSpeed * ignited;
        final cellOffset = _cellOffsets[index];
        final front = math.max(_slider - distance - cellOffset, 0.02);
        final tail = math.max(_slider - front, 0.001);
        final inZone = _step(front - 0.003, uvX) * _step(uvX, _slider + 0.003);
        final normalizedTail = _clamp(math.max(_slider - uvX, 0.0) / tail);
        var brightness = math.pow(1 - normalizedTail, 0.65).toDouble();
        brightness = math.max(brightness, 0.04 * ignited) * inZone;
        brightness *= 1 - _smoothStep(0.94, 1.05, normalizedTail);

        final verticalEnvelope = _rowVerticalEnvelopes[row];
        final waveOne = math.sin(
          uvX * 30 + _time * 15 * timeScale + cellHash * 6.28,
        );
        final waveTwo = math.sin(
          uvX * 17 + _time * 8 * timeScale + cellHash * 3.14,
        );
        final waveThree = math.sin(
          uvX * 52 + _time * 25 * timeScale + cellHash * 10,
        );
        final flame = _smoothStep(
          0.08,
          0.92,
          (waveOne + waveTwo * 0.5 + waveThree * 0.25) * 0.35 + 0.5,
        );

        final rhythmOne = math.sin(
          normalizedTail * 16 - _time * 5 * timeScale + cellHash * 3,
        );
        final rhythmTwo = math.sin(
          normalizedTail * 8 - _time * 2.5 * timeScale + cellHash * 5,
        );
        var rhythm =
            _smoothStep(-0.15, 0.55, rhythmOne) * (rhythmTwo * 0.5 + 0.5);
        rhythm = math.pow(math.max(rhythm, 0.0), 1.2).toDouble();

        final averageSpeed = distance / math.max(cellAge, 0.001);
        final arrivalAge = math.max(
          cellAge -
              math.max(_slider - uvX, 0.0) / math.max(averageSpeed, 0.001),
          0.0,
        );
        final flash = _step(0, arrivalAge) * math.exp(-arrivalAge * 3.2);

        final sparkProgress = _fract(
          _time * (0.38 + cellHash * 0.15) + cellHash * 7,
        );
        final sparkX = _slider - sparkProgress * tail;
        final sparkY =
            0.5 + math.sin(sparkProgress * 11 + cellHash * 6.28) * 0.28;
        final spark =
            _smoothStep(0.014, 0, (uvX - sparkX).abs()) *
            _smoothStep(0.18, 0, (uvY - sparkY).abs()) *
            math.pow(1 - sparkProgress, 2).toDouble() *
            energyScale;

        var energy =
            brightness * verticalEnvelope * (flame * 0.42 + rhythm * 0.38) +
            flash * brightness * verticalEnvelope * 0.55 +
            spark * 0.70 * inZone;
        energy *= energyScale;

        final edgeBase = math.exp(-math.pow((uvX - front) * 18, 2));
        final edgeWaveOne =
            math.sin(uvX * 45 + _time * 20 * timeScale + cellHash * 6.28) *
                0.5 +
            0.5;
        final edgeWaveTwo =
            math.sin(uvX * 28 + _time * 11 * timeScale + cellHash * 3.14) *
                0.5 +
            0.5;
        final edge =
            edgeBase *
            (0.25 + edgeWaveOne * edgeWaveTwo * 1.5) *
            1.6 *
            activation *
            energyScale;

        final leadDistance = front - uvX;
        final leadZone =
            _smoothStep(0.07, 0, leadDistance) *
            _step(0, leadDistance) *
            verticalEnvelope;
        final secondHash = _secondCellHashes[index];
        final leadFlicker =
            math.sin(
                  leadDistance * 100 +
                      _time * 20 * timeScale +
                      secondHash * 6.28,
                ) *
                0.5 +
            0.5;
        final leadSpark =
            leadZone *
            _step(0.6, secondHash) *
            leadFlicker *
            activation *
            energyScale *
            0.5;
        final total = energy + edge + leadSpark;

        final temperature = 1 - normalizedTail;
        final whiteMix = math.pow(temperature, 4.5).toDouble();
        var red = _mix(emberR, purpleR, temperature);
        var green = _mix(emberG, purpleG, temperature);
        var blue = _mix(emberB, purpleB, temperature);
        red = _mix(red, whiteR, whiteMix) * total;
        green = _mix(green, whiteG, whiteMix) * total;
        blue = _mix(blue, whiteB, whiteMix) * total;

        red +=
            whiteR * core * 2.2 * pulse * activation * energyScale +
            purpleR * wideCore * 0.12 * activation * energyScale;
        green +=
            whiteG * core * 2.2 * pulse * activation * energyScale +
            purpleG * wideCore * 0.12 * activation * energyScale;
        blue +=
            whiteB * core * 2.2 * pulse * activation * energyScale +
            purpleB * wideCore * 0.12 * activation * energyScale;

        red *= tierIntensity;
        green *= tierIntensity;
        blue *= tierIntensity;

        red *= fadeMask;
        green *= fadeMask;
        blue *= fadeMask;
        _nextR[index] = math.min(decayR + red, 1.5);
        _nextG[index] = math.min(decayG + green, 1.5);
        _nextB[index] = math.min(decayB + blue, 1.5);
      }
    }
  }

  void _horizontalBlurPass() {
    for (var column = 0; column < columns; column++) {
      for (var row = 0; row < rows; row++) {
        var resultR = 0.0;
        var resultG = 0.0;
        var resultB = 0.0;
        for (
          var sampleIndex = 0;
          sampleIndex < _blurSampleOffsets.length;
          sampleIndex++
        ) {
          final sampleColumn =
              column + _blurSampleOffsets[sampleIndex] * _blurOffsetColumns;
          final position = sampleColumn.clamp(0.0, columns - 1.0).toDouble();
          final lowerColumn = position.floor();
          final upperColumn = math.min(columns - 1, lowerColumn + 1);
          final amount = position - lowerColumn;
          final lowerIndex = lowerColumn * rows + row;
          final upperIndex = upperColumn * rows + row;
          final red = _mix(_nextR[lowerIndex], _nextR[upperIndex], amount);
          final green = _mix(_nextG[lowerIndex], _nextG[upperIndex], amount);
          final blue = _mix(_nextB[lowerIndex], _nextB[upperIndex], amount);
          if (_luminance(red, green, blue) < 0.30) continue;
          final weight = _blurSampleWeights[sampleIndex];
          resultR += red * weight;
          resultG += green * weight;
          resultB += blue * weight;
        }
        final index = column * rows + row;
        _blurHorizontalR[index] = resultR;
        _blurHorizontalG[index] = resultG;
        _blurHorizontalB[index] = resultB;
      }
    }
  }

  void _verticalBlurPass() {
    for (var column = 0; column < columns; column++) {
      for (var row = 0; row < rows; row++) {
        var resultR = 0.0;
        var resultG = 0.0;
        var resultB = 0.0;
        for (
          var sampleIndex = 0;
          sampleIndex < _blurSampleOffsets.length;
          sampleIndex++
        ) {
          final sampleRow =
              row + _blurSampleOffsets[sampleIndex] * _blurOffsetRows;
          final position = sampleRow.clamp(0.0, rows - 1.0).toDouble();
          final lowerRow = position.floor();
          final upperRow = math.min(rows - 1, lowerRow + 1);
          final amount = position - lowerRow;
          final lowerIndex = column * rows + lowerRow;
          final upperIndex = column * rows + upperRow;
          final weight = _blurSampleWeights[sampleIndex];
          resultR +=
              _mix(
                _blurHorizontalR[lowerIndex],
                _blurHorizontalR[upperIndex],
                amount,
              ) *
              weight;
          resultG +=
              _mix(
                _blurHorizontalG[lowerIndex],
                _blurHorizontalG[upperIndex],
                amount,
              ) *
              weight;
          resultB +=
              _mix(
                _blurHorizontalB[lowerIndex],
                _blurHorizontalB[upperIndex],
                amount,
              ) *
              weight;
        }
        final index = column * rows + row;
        _glowR[index] = resultR;
        _glowG[index] = resultG;
        _glowB[index] = resultB;
      }
    }
  }

  void _compositePass() {
    for (var index = 0; index < cellCount; index++) {
      _compositeR[index] = _toneMap(_nextR[index], _glowR[index]);
      _compositeG[index] = _toneMap(_nextG[index], _glowG[index]);
      _compositeB[index] = _toneMap(_nextB[index], _glowB[index]);
    }
  }

  static double _toneMap(double scene, double glow) =>
      1 - math.exp(-(scene + glow * 1.2 + scene * glow * 0.35) * 1.15);

  void _clearFrames() {
    for (final buffer in <List<double>>[
      _sceneR,
      _sceneG,
      _sceneB,
      _nextR,
      _nextG,
      _nextB,
      _blurHorizontalR,
      _blurHorizontalG,
      _blurHorizontalB,
      _glowR,
      _glowG,
      _glowB,
      _compositeR,
      _compositeG,
      _compositeB,
    ]) {
      buffer.fillRange(0, buffer.length, 0);
    }
  }

  static int _index(int column, int row) =>
      column.clamp(0, columns - 1).toInt() * rows +
      row.clamp(0, rows - 1).toInt();

  static double _hash(double x, double y) =>
      _fract(math.sin(x * 127.1 + y * 311.7) * 43758.5453);

  static double _fract(double value) => value - value.floorToDouble();

  static double _clamp(double value) => value.clamp(0.0, 1.0).toDouble();

  static double _mix(double from, double to, double amount) =>
      from + (to - from) * amount;

  static double _step(double edge, double value) => value < edge ? 0 : 1;

  static double _smoothStep(double edge0, double edge1, double value) {
    if (edge0 == edge1) return value < edge0 ? 0 : 1;
    final amount = _clamp((value - edge0) / (edge1 - edge0));
    return amount * amount * (3 - 2 * amount);
  }

  static double _luminance(double red, double green, double blue) =>
      red * 0.2126 + green * 0.7152 + blue * 0.0722;
}
