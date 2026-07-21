import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'third_party/astraeus/claude_range_slider_fire.dart';

/// Visual tiers for the Claude-inspired treatment of the Codex effort slider.
///
/// This module deliberately knows nothing about Codex wire values. The caller
/// maps model-advertised efforts to semantic indices, so removing the visual
/// feature cannot change session or protocol behaviour.
enum ClaudeEffortAccent { standard, xHigh, max, ultra }

/// One deterministic particle in the one-shot arrival burst.
@immutable
class ClaudeEffortBurstSpec {
  const ClaudeEffortBurstSpec({
    required this.unitX,
    required this.unitY,
    required this.distance,
    required this.radius,
    required this.delay,
  });

  final double unitX;
  final double unitY;
  final double distance;
  final double radius;
  final double delay;
}

/// Motion, colour and density tokens for the two-layer high-effort treatment.
///
/// Entering x-high, Max or Ultra produces one bounded arrival burst. While the
/// selected Max or Ultra tier remains active, a deterministic fixed-grid field
/// carries red-leaning magenta or white-hot purple pixels toward lower logical
/// effort (physical screen-left in LTR and screen-right in RTL). The field is
/// disabled entirely by Reduce Motion.
abstract final class ClaudeEffortMotionTokens {
  static const Curve glideCurve = Cubic(0.23, 1, 0.32, 1);
  static const Curve colourCurve = Cubic(0.16, 1, 0.3, 1);

  static const Duration selectionDuration = Duration(milliseconds: 120);
  static const Duration dragSettleDuration = Duration(milliseconds: 150);
  static const Duration xHighRevealDuration = Duration(milliseconds: 720);
  static const Duration maxRevealDuration = Duration(milliseconds: 880);
  static const Duration ultraRevealDuration = Duration(milliseconds: 1080);
  static const Duration draggedXHighRevealDuration = Duration(
    milliseconds: 620,
  );
  static const Duration draggedMaxRevealDuration = Duration(milliseconds: 760);
  static const Duration draggedUltraRevealDuration = Duration(
    milliseconds: 920,
  );

  static const Color lavender = Color(0xFFD0B4FF);
  static const Color violet = Color(0xFFA78BFA);
  static const Color deepViolet = Color(0xFF7957E8);

  /// The GPL reference renderer uses one immutable 72-by-6 UV grid. The thumb
  /// changes only the fire mask/front; it never moves or rescales these cells.
  static const int pixelColumns = ClaudeRangeSliderFireSimulation.columns;
  static const int maxPixelRows = ClaudeRangeSliderFireSimulation.rows;
  static const Duration pixelFrameInterval = Duration(milliseconds: 16);
  static const Duration pixelFadeOutDuration = Duration(milliseconds: 300);

  /// The restrained radial burst used before the exhaust trail was added.
  /// Lower tiers use a prefix so the arrival cue scales without changing its
  /// shape or allocating random geometry per frame.
  static const List<ClaudeEffortBurstSpec> burstParticles = [
    ClaudeEffortBurstSpec(
      unitX: -0.98356,
      unitY: -0.18060,
      distance: 25,
      radius: 1.35,
      delay: 0.00,
    ),
    ClaudeEffortBurstSpec(
      unitX: -0.84641,
      unitY: -0.53253,
      distance: 21,
      radius: 1.10,
      delay: 0.08,
    ),
    ClaudeEffortBurstSpec(
      unitX: -0.58850,
      unitY: -0.80850,
      distance: 28,
      radius: 1.45,
      delay: 0.02,
    ),
    ClaudeEffortBurstSpec(
      unitX: -0.24663,
      unitY: -0.96911,
      distance: 24,
      radius: 1.05,
      delay: 0.12,
    ),
    ClaudeEffortBurstSpec(
      unitX: 0.12050,
      unitY: -0.99271,
      distance: 29,
      radius: 1.40,
      delay: 0.04,
    ),
    ClaudeEffortBurstSpec(
      unitX: 0.49757,
      unitY: -0.86742,
      distance: 22,
      radius: 1.15,
      delay: 0.15,
    ),
    ClaudeEffortBurstSpec(
      unitX: 0.78999,
      unitY: -0.61312,
      distance: 27,
      radius: 1.35,
      delay: 0.07,
    ),
    ClaudeEffortBurstSpec(
      unitX: 0.96891,
      unitY: -0.24740,
      distance: 23,
      radius: 1.00,
      delay: 0.18,
    ),
    ClaudeEffortBurstSpec(
      unitX: 0.98384,
      unitY: 0.17903,
      distance: 26,
      radius: 1.40,
      delay: 0.01,
    ),
    ClaudeEffortBurstSpec(
      unitX: 0.83646,
      unitY: 0.54802,
      distance: 21,
      radius: 1.05,
      delay: 0.11,
    ),
    ClaudeEffortBurstSpec(
      unitX: 0.57352,
      unitY: 0.81919,
      distance: 29,
      radius: 1.30,
      delay: 0.05,
    ),
    ClaudeEffortBurstSpec(
      unitX: 0.19945,
      unitY: 0.97991,
      distance: 24,
      radius: 1.10,
      delay: 0.16,
    ),
    ClaudeEffortBurstSpec(
      unitX: -0.18808,
      unitY: 0.98215,
      distance: 27,
      radius: 1.45,
      delay: 0.03,
    ),
    ClaudeEffortBurstSpec(
      unitX: -0.52201,
      unitY: 0.85294,
      distance: 22,
      radius: 1.00,
      delay: 0.13,
    ),
    ClaudeEffortBurstSpec(
      unitX: -0.78901,
      unitY: 0.61437,
      distance: 28,
      radius: 1.35,
      delay: 0.06,
    ),
    ClaudeEffortBurstSpec(
      unitX: -0.94873,
      unitY: 0.31608,
      distance: 23,
      radius: 1.10,
      delay: 0.17,
    ),
  ];

  static ClaudeEffortAccent accentForIndex({
    required int selectedIndex,
    int? xHighIndex,
    int? maxIndex,
    int? ultraIndex,
  }) {
    if (selectedIndex == ultraIndex) return ClaudeEffortAccent.ultra;
    if (selectedIndex == maxIndex) return ClaudeEffortAccent.max;
    if (selectedIndex == xHighIndex) return ClaudeEffortAccent.xHigh;
    return ClaudeEffortAccent.standard;
  }

  static int burstParticleCount(ClaudeEffortAccent accent) => switch (accent) {
    ClaudeEffortAccent.standard => 0,
    ClaudeEffortAccent.xHigh => 8,
    ClaudeEffortAccent.max => 12,
    ClaudeEffortAccent.ultra => 16,
  };

  static double pixelTrackBlend(ClaudeEffortAccent accent) => switch (accent) {
    ClaudeEffortAccent.standard => 1,
    ClaudeEffortAccent.xHigh => 0.42,
    ClaudeEffortAccent.max => 0.34,
    ClaudeEffortAccent.ultra => 0.27,
  };

  static Duration revealDuration(
    ClaudeEffortAccent accent, {
    required bool fromDrag,
  }) {
    if (fromDrag) {
      return switch (accent) {
        ClaudeEffortAccent.standard => dragSettleDuration,
        ClaudeEffortAccent.xHigh => draggedXHighRevealDuration,
        ClaudeEffortAccent.max => draggedMaxRevealDuration,
        ClaudeEffortAccent.ultra => draggedUltraRevealDuration,
      };
    }
    return switch (accent) {
      ClaudeEffortAccent.standard => selectionDuration,
      ClaudeEffortAccent.xHigh => xHighRevealDuration,
      ClaudeEffortAccent.max => maxRevealDuration,
      ClaudeEffortAccent.ultra => ultraRevealDuration,
    };
  }

  static double positionInterval(
    ClaudeEffortAccent accent, {
    required bool fromDrag,
  }) {
    final total = revealDuration(accent, fromDrag: fromDrag).inMicroseconds;
    final move =
        (fromDrag ? dragSettleDuration : selectionDuration).inMicroseconds;
    return total == 0 ? 1 : (move / total).clamp(0.0, 1.0);
  }

  static double thumbInterval(
    ClaudeEffortAccent accent, {
    required bool fromDrag,
  }) {
    final total = revealDuration(accent, fromDrag: fromDrag).inMicroseconds;
    final settle = fromDrag ? 150000 : 220000;
    return total == 0 ? 1 : (settle / total).clamp(0.0, 1.0);
  }

  static List<Color> gradientColors({
    required ClaudeEffortAccent accent,
    required Color primary,
    required Color purple,
    double fastProgress = 0,
  }) {
    final fastHighlight = Color.lerp(primary, Colors.white, 0.18)!;
    final base = Color.lerp(primary, fastHighlight, fastProgress * 0.32)!;
    final strength = switch (accent) {
      ClaudeEffortAccent.standard => 0.0,
      ClaudeEffortAccent.xHigh => 0.72,
      ClaudeEffortAccent.max => 0.86,
      ClaudeEffortAccent.ultra => 1.0,
    };
    return <Color>[
      Color.lerp(base, purple, strength * 0.45)!,
      Color.lerp(base, purple, strength)!,
    ];
  }

  /// Returns -1 outside this burst particle's single visible interval.
  static double burstProgress({
    required ClaudeEffortAccent accent,
    required double phase,
    required double positionInterval,
    required ClaudeEffortBurstSpec particle,
  }) {
    if (accent == ClaudeEffortAccent.standard) return -1;
    final arrival = (positionInterval * 0.72).clamp(0.06, 0.34);
    final span = switch (accent) {
      ClaudeEffortAccent.standard => 0.0,
      ClaudeEffortAccent.xHigh => 0.34,
      ClaudeEffortAccent.max => 0.38,
      ClaudeEffortAccent.ultra => 0.42,
    };
    final burst = (phase - arrival) / math.max(0.0001, span);
    final local =
        (burst - particle.delay) / math.max(0.0001, 1 - particle.delay);
    if (local <= 0 || local >= 1) return -1;
    return local.clamp(0.0, 1.0);
  }

  static double burstOpacity(double progress) {
    if (progress < 0 || progress > 1) return 0;
    return math.pow(1 - progress, 1.7).toDouble();
  }

  static Color burstColor({
    required Color primary,
    required Color purple,
    required double progress,
  }) => Color.lerp(primary, purple, Curves.easeOutCubic.transform(progress))!;
}
