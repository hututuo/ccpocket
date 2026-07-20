import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Visual tiers for the Claude-inspired treatment of the Codex effort slider.
///
/// This module deliberately knows nothing about Codex wire values. The caller
/// maps model-advertised efforts to semantic indices, so removing the visual
/// feature cannot change session or protocol behaviour.
enum ClaudeEffortAccent { standard, xHigh, max, ultra }

/// One deterministic purple mote in the finite high-effort particle reveal.
///
/// Geometry is precomputed rather than randomized per frame. That keeps the
/// animation visually stable, allocation-light, and straightforward to test.
@immutable
class ClaudeEffortParticleSpec {
  const ClaudeEffortParticleSpec({
    required this.angle,
    required this.distance,
    required this.radius,
    required this.delay,
    required this.arc,
  });

  final double angle;
  final double distance;
  final double radius;
  final double delay;
  final double arc;
}

/// Motion and colour tokens for the purple-particle effort treatment.
///
/// Claude's public effort controls use a compact, quick position transition;
/// the higher tiers add lavender energy without turning the whole control into
/// a permanent animation. Mobile keeps that hierarchy with one finite reveal:
/// x-high is restrained, Max is denser, and Ultra adds a second particle wave.
abstract final class ClaudeEffortMotionTokens {
  static const Curve glideCurve = Cubic(0.22, 1, 0.36, 1);
  static const Curve colourCurve = Cubic(0.16, 1, 0.3, 1);

  static const Duration selectionDuration = Duration(milliseconds: 260);
  static const Duration dragSettleDuration = Duration(milliseconds: 170);
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

  /// A fixed asymmetric cloud, ordered from the earliest/core motes to the
  /// later outer wave. Lower tiers simply use a prefix of this list.
  static const List<ClaudeEffortParticleSpec> particles = [
    ClaudeEffortParticleSpec(
      angle: -2.96,
      distance: 19,
      radius: 1.35,
      delay: 0.00,
      arc: -0.16,
    ),
    ClaudeEffortParticleSpec(
      angle: -2.54,
      distance: 15,
      radius: 1.05,
      delay: 0.07,
      arc: 0.22,
    ),
    ClaudeEffortParticleSpec(
      angle: -2.15,
      distance: 20,
      radius: 1.50,
      delay: 0.02,
      arc: -0.19,
    ),
    ClaudeEffortParticleSpec(
      angle: -1.76,
      distance: 14,
      radius: 0.95,
      delay: 0.12,
      arc: 0.25,
    ),
    ClaudeEffortParticleSpec(
      angle: -1.36,
      distance: 18,
      radius: 1.28,
      delay: 0.04,
      arc: -0.23,
    ),
    ClaudeEffortParticleSpec(
      angle: -0.98,
      distance: 16,
      radius: 1.10,
      delay: 0.15,
      arc: 0.18,
    ),
    ClaudeEffortParticleSpec(
      angle: -0.60,
      distance: 21,
      radius: 1.42,
      delay: 0.06,
      arc: -0.20,
    ),
    ClaudeEffortParticleSpec(
      angle: -0.20,
      distance: 15,
      radius: 0.92,
      delay: 0.18,
      arc: 0.24,
    ),
    ClaudeEffortParticleSpec(
      angle: 0.18,
      distance: 20,
      radius: 1.36,
      delay: 0.01,
      arc: -0.18,
    ),
    ClaudeEffortParticleSpec(
      angle: 0.58,
      distance: 14,
      radius: 1.02,
      delay: 0.11,
      arc: 0.21,
    ),
    ClaudeEffortParticleSpec(
      angle: 0.96,
      distance: 19,
      radius: 1.48,
      delay: 0.05,
      arc: -0.24,
    ),
    ClaudeEffortParticleSpec(
      angle: 1.36,
      distance: 16,
      radius: 1.08,
      delay: 0.16,
      arc: 0.19,
    ),
    ClaudeEffortParticleSpec(
      angle: 1.75,
      distance: 21,
      radius: 1.38,
      delay: 0.03,
      arc: -0.22,
    ),
    ClaudeEffortParticleSpec(
      angle: 2.14,
      distance: 15,
      radius: 0.96,
      delay: 0.13,
      arc: 0.24,
    ),
    ClaudeEffortParticleSpec(
      angle: 2.53,
      distance: 20,
      radius: 1.32,
      delay: 0.08,
      arc: -0.17,
    ),
    ClaudeEffortParticleSpec(
      angle: 2.92,
      distance: 16,
      radius: 1.04,
      delay: 0.17,
      arc: 0.20,
    ),
    ClaudeEffortParticleSpec(
      angle: -2.72,
      distance: 23,
      radius: 0.88,
      delay: 0.24,
      arc: 0.26,
    ),
    ClaudeEffortParticleSpec(
      angle: -1.90,
      distance: 22,
      radius: 1.16,
      delay: 0.21,
      arc: -0.25,
    ),
    ClaudeEffortParticleSpec(
      angle: -1.08,
      distance: 24,
      radius: 0.92,
      delay: 0.27,
      arc: 0.22,
    ),
    ClaudeEffortParticleSpec(
      angle: -0.28,
      distance: 22,
      radius: 1.12,
      delay: 0.23,
      arc: -0.27,
    ),
    ClaudeEffortParticleSpec(
      angle: 0.54,
      distance: 24,
      radius: 0.90,
      delay: 0.28,
      arc: 0.24,
    ),
    ClaudeEffortParticleSpec(
      angle: 1.34,
      distance: 22,
      radius: 1.18,
      delay: 0.20,
      arc: -0.23,
    ),
    ClaudeEffortParticleSpec(
      angle: 2.16,
      distance: 23,
      radius: 0.94,
      delay: 0.26,
      arc: 0.25,
    ),
    ClaudeEffortParticleSpec(
      angle: 2.92,
      distance: 21,
      radius: 1.10,
      delay: 0.22,
      arc: -0.21,
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

  static int particleCount(ClaudeEffortAccent accent) => switch (accent) {
    ClaudeEffortAccent.standard => 0,
    ClaudeEffortAccent.xHigh => 12,
    ClaudeEffortAccent.max => 18,
    ClaudeEffortAccent.ultra => 24,
  };

  static int trailParticleCount(ClaudeEffortAccent accent) => switch (accent) {
    ClaudeEffortAccent.standard => 0,
    ClaudeEffortAccent.xHigh => 3,
    ClaudeEffortAccent.max => 5,
    ClaudeEffortAccent.ultra => 7,
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
    final fastHighlight = Color.lerp(primary, Colors.white, 0.20)!;
    final base = Color.lerp(primary, fastHighlight, fastProgress * 0.32)!;
    return switch (accent) {
      ClaudeEffortAccent.standard => <Color>[base, base],
      ClaudeEffortAccent.xHigh => <Color>[
        Color.lerp(base, purple, 0.34)!,
        Color.lerp(purple, violet, 0.18)!,
      ],
      ClaudeEffortAccent.max => <Color>[
        Color.lerp(base, deepViolet, 0.46)!,
        Color.lerp(purple, lavender, 0.22)!,
      ],
      ClaudeEffortAccent.ultra => <Color>[
        Color.lerp(base, deepViolet, 0.58)!,
        Color.lerp(purple, lavender, 0.40)!,
      ],
    };
  }

  /// Returns -1 outside this particle's finite visible interval.
  static double particleProgress(
    ClaudeEffortAccent accent,
    double phase,
    ClaudeEffortParticleSpec particle,
  ) {
    if (accent == ClaudeEffortAccent.standard) return -1;
    final waveStart = switch (accent) {
      ClaudeEffortAccent.standard => 1.0,
      ClaudeEffortAccent.xHigh => 0.18,
      ClaudeEffortAccent.max => 0.14,
      ClaudeEffortAccent.ultra => 0.10,
    };
    final delayedStart = waveStart + particle.delay * 0.42;
    final local = (phase - delayedStart) / math.max(0.0001, 1 - delayedStart);
    if (local <= 0 || local >= 1) return -1;
    return local.clamp(0.0, 1.0);
  }

  static double particleOpacity(double progress) {
    if (progress < 0 || progress > 1) return 0;
    final envelope = math.sin(math.pi * progress.clamp(0.0, 1.0));
    return math.pow(math.max(0.0, envelope), 0.72).toDouble();
  }

  static Color particleColor(int index, Color purple) => switch (index % 3) {
    0 => lavender,
    1 => Color.lerp(purple, violet, 0.35)!,
    _ => Color.lerp(deepViolet, purple, 0.44)!,
  };

  static double thumbTravelEnvelope({
    required double movePhase,
    required double travel,
  }) {
    final normalizedTravel = (travel * 3.2).clamp(0.0, 1.0);
    return math.sin(math.pi * movePhase.clamp(0.0, 1.0)) * normalizedTravel;
  }

  static double landingPulse(double movePhase) {
    if (movePhase <= 0.70 || movePhase >= 1) return 0;
    final local = (movePhase - 0.70) / 0.30;
    return math.sin(math.pi * local) * (1 - local) * 0.040;
  }
}
