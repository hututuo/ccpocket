import 'dart:math' as math;
import 'dart:ui' show SemanticsAction;

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/widgets/claude_effort_motion_style.dart';
import 'package:ccpocket/widgets/codex_effort_motion.dart';
import 'package:ccpocket/widgets/codex_effort_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keeps mobile geometry and preserves effort wire mapping', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key));

    expect(find.byType(Slider), findsNothing);
    expect(
      find.byKey(const ValueKey('motion_slider_repaint_boundary')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('motion_slider'))).height,
      CodexEffortMotionMetrics.interactionHeight,
    );
    expect(CodexEffortMotionMetrics.trackHeight, 24);
    expect(CodexEffortMotionMetrics.thumbDiameter, 28);
    expect(CodexEffortMotionMetrics.activeThumbDiameter, 32);
    expect(CodexEffortMotionMetrics.tickDiameter, 4);
    expect(ClaudeEffortMotionTokens.burstParticles, hasLength(16));
    expect(ClaudeEffortMotionTokens.pixelColumns, 72);
    expect(ClaudeEffortMotionTokens.maxPixelRows, 6);
    expect(
      ClaudeEffortMotionTokens.burstParticleCount(ClaudeEffortAccent.xHigh),
      lessThan(
        ClaudeEffortMotionTokens.burstParticleCount(ClaudeEffortAccent.max),
      ),
    );
    expect(
      ClaudeEffortMotionTokens.burstParticleCount(ClaudeEffortAccent.max),
      lessThan(
        ClaudeEffortMotionTokens.burstParticleCount(ClaudeEffortAccent.ultra),
      ),
    );
    expect(codexEffortPixelCellCapacity, 432);
    expect(codexFastParticleCount, 14);

    final bounds = tester.getRect(find.byKey(const ValueKey('motion_slider')));
    await tester.tapAt(Offset(bounds.right - 15, bounds.center.dy));
    await tester.pump();

    expect(key.currentState!.effort, ReasoningEffort.ultra);
    expect(key.currentState!.effort.value, 'ultra');
    expect(find.text('ultra'), findsOneWidget);
  });

  test('Claude accent mapping is semantic rather than position-based', () {
    expect(
      ClaudeEffortMotionTokens.accentForIndex(
        selectedIndex: 0,
        xHighIndex: 0,
        maxIndex: 1,
        ultraIndex: 2,
      ),
      ClaudeEffortAccent.xHigh,
    );
    expect(
      ClaudeEffortMotionTokens.accentForIndex(
        selectedIndex: 1,
        xHighIndex: 0,
        maxIndex: 1,
        ultraIndex: 2,
      ),
      ClaudeEffortAccent.max,
    );
    expect(
      ClaudeEffortMotionTokens.accentForIndex(
        selectedIndex: 2,
        xHighIndex: 0,
        maxIndex: 1,
        ultraIndex: 2,
      ),
      ClaudeEffortAccent.ultra,
    );
    expect(
      ClaudeEffortMotionTokens.accentForIndex(
        selectedIndex: 3,
        xHighIndex: 0,
        maxIndex: 1,
        ultraIndex: 2,
      ),
      ClaudeEffortAccent.standard,
    );
  });

  test('arrival burst is finite and pixel-fire tiers stay bounded', () {
    final particle = ClaudeEffortMotionTokens.burstParticles.first;
    expect(
      ClaudeEffortMotionTokens.burstProgress(
        accent: ClaudeEffortAccent.xHigh,
        phase: 0,
        positionInterval: 0.4,
        particle: particle,
      ),
      -1,
    );
    expect(
      ClaudeEffortMotionTokens.burstProgress(
        accent: ClaudeEffortAccent.xHigh,
        phase: 0.45,
        positionInterval: 0.4,
        particle: particle,
      ),
      inInclusiveRange(0.0, 1.0),
    );
    expect(
      ClaudeEffortMotionTokens.burstProgress(
        accent: ClaudeEffortAccent.xHigh,
        phase: 1,
        positionInterval: 0.4,
        particle: particle,
      ),
      -1,
    );
    expect(ClaudeEffortMotionTokens.pixelRows(ClaudeEffortAccent.xHigh), 4);
    expect(ClaudeEffortMotionTokens.pixelRows(ClaudeEffortAccent.max), 5);
    expect(ClaudeEffortMotionTokens.pixelRows(ClaudeEffortAccent.ultra), 6);
    expect(
      ClaudeEffortMotionTokens.pixelReach(ClaudeEffortAccent.xHigh),
      lessThan(ClaudeEffortMotionTokens.pixelReach(ClaudeEffortAccent.max)),
    );
    expect(
      ClaudeEffortMotionTokens.pixelReach(ClaudeEffortAccent.max),
      lessThan(ClaudeEffortMotionTokens.pixelReach(ClaudeEffortAccent.ultra)),
    );
    expect(
      ClaudeEffortMotionTokens.pixelDensity(ClaudeEffortAccent.xHigh),
      lessThan(ClaudeEffortMotionTokens.pixelDensity(ClaudeEffortAccent.max)),
    );
    expect(
      ClaudeEffortMotionTokens.pixelDensity(ClaudeEffortAccent.max),
      lessThan(ClaudeEffortMotionTokens.pixelDensity(ClaudeEffortAccent.ultra)),
    );
    expect(
      ClaudeEffortMotionTokens.pixelSeed(7, 3),
      ClaudeEffortMotionTokens.pixelSeed(7, 3),
    );
    final seeds = <double>[
      for (
        var column = 0;
        column < ClaudeEffortMotionTokens.pixelColumns;
        column++
      )
        for (var row = 0; row < ClaudeEffortMotionTokens.maxPixelRows; row++)
          ClaudeEffortMotionTokens.pixelSeed(column, row),
    ];
    expect(seeds.toSet().length, greaterThan(420));
    expect(seeds.any((value) => value < 0.04), isTrue);
    expect(seeds.any((value) => value > 0.96), isTrue);
  });

  test('pixel wave crest travels outward instead of reversing direction', () {
    const flow = 0.64;
    const frequencySeed = 0.30;
    const speedSeed = 0.70;
    const phaseSeed = 0.30;
    const cellSeed = 0.50;
    const laterElapsed = 0.40;
    final waveNumber = math.pi * (4.55 + frequencySeed * 0.75);
    final angularSpeed = 1.85 + flow * 1.55 + speedSeed * 0.35;
    final phaseOffset = phaseSeed * math.pi * 2 + (cellSeed - 0.5) * 0.20;
    final crestPhase = math.pi / 2 + math.pi * 2;
    final initialDistance = (crestPhase - phaseOffset) / waveNumber;
    final laterDistance =
        (crestPhase + laterElapsed * angularSpeed - phaseOffset) / waveNumber;

    final initialCrest = ClaudeEffortMotionTokens.pixelTravelWave(
      distance: initialDistance,
      elapsed: 0,
      flow: flow,
      frequencySeed: frequencySeed,
      speedSeed: speedSeed,
      phaseSeed: phaseSeed,
      cellSeed: cellSeed,
    );
    final laterAtOldPosition = ClaudeEffortMotionTokens.pixelTravelWave(
      distance: initialDistance,
      elapsed: laterElapsed,
      flow: flow,
      frequencySeed: frequencySeed,
      speedSeed: speedSeed,
      phaseSeed: phaseSeed,
      cellSeed: cellSeed,
    );
    final laterCrest = ClaudeEffortMotionTokens.pixelTravelWave(
      distance: laterDistance,
      elapsed: laterElapsed,
      flow: flow,
      frequencySeed: frequencySeed,
      speedSeed: speedSeed,
      phaseSeed: phaseSeed,
      cellSeed: cellSeed,
    );

    expect(initialDistance, inInclusiveRange(0.38, 0.42));
    expect(laterDistance, greaterThan(initialDistance));
    expect(initialCrest, greaterThan(0.99));
    expect(laterCrest, greaterThan(0.99));
    expect(laterCrest, greaterThan(laterAtOldPosition + 0.5));
  });

  test('pixel rows use separated primary and secondary phases', () {
    for (final secondary in <bool>[false, true]) {
      final phases = <double>[
        for (var row = 0; row < 6; row++)
          ClaudeEffortMotionTokens.pixelRowPhase(row, secondary: secondary),
      ];
      expect(phases.toSet(), hasLength(6));
      for (var first = 0; first < phases.length; first++) {
        for (var second = first + 1; second < phases.length; second++) {
          final rawDistance = (phases[first] - phases[second]).abs();
          final circularDistance = math.min(rawDistance, 1 - rawDistance);
          expect(circularDistance, greaterThan(0.15));
        }
      }
    }
  });

  testWidgets(
    'drag start/end emits its tier and same-frame return is not lost',
    (tester) async {
      final key = GlobalKey<_EffortHarnessState>();
      await tester.pumpWidget(_EffortHarness(key: key));

      GestureDetector detector() => tester.widget<GestureDetector>(
        find.descendant(
          of: find.byKey(const ValueKey('motion_slider')),
          matching: find.byType(GestureDetector),
        ),
      );

      final width = tester
          .getSize(find.byKey(const ValueKey('motion_slider')))
          .width;
      double xFor(double position) {
        final inset = CodexEffortMotionMetrics.maxVisualThumbRadius;
        return inset + (width - inset * 2) * position;
      }

      // Drag recognizers may deliver start followed immediately by end. The
      // start position itself must therefore update the real effort state.
      detector().onHorizontalDragStart!(
        DragStartDetails(localPosition: Offset(xFor(1), 24)),
      );
      detector().onHorizontalDragEnd!(DragEndDetails());
      expect(key.currentState!.wireEfforts, [ReasoningEffort.ultra]);

      key.currentState!.reset();
      await tester.pump();
      final sameFrameDetector = detector();
      sameFrameDetector.onHorizontalDragStart!(
        DragStartDetails(localPosition: Offset(xFor(0.4), 24)),
      );
      sameFrameDetector.onHorizontalDragUpdate!(
        DragUpdateDetails(
          globalPosition: Offset(xFor(0.6), 24),
          localPosition: Offset(xFor(0.6), 24),
        ),
      );
      sameFrameDetector.onHorizontalDragUpdate!(
        DragUpdateDetails(
          globalPosition: Offset(xFor(0.4), 24),
          localPosition: Offset(xFor(0.4), 24),
        ),
      );
      sameFrameDetector.onHorizontalDragEnd!(DragEndDetails());
      expect(key.currentState!.wireEfforts, [
        ReasoningEffort.xhigh,
        ReasoningEffort.high,
      ]);

      key.currentState!.reset();
      await tester.pumpAndSettle();
      final bounds = tester.getRect(
        find.byKey(const ValueKey('motion_slider')),
      );
      final gesture = await tester.startGesture(
        Offset(bounds.left + xFor(0.4), bounds.center.dy),
      );
      await gesture.moveTo(Offset(bounds.left + xFor(1), bounds.center.dy));
      await gesture.up();
      await tester.pump(
        ClaudeEffortMotionTokens.draggedUltraRevealDuration +
            const Duration(milliseconds: 40),
      );
      expect(key.currentState!.wireEfforts, isNotEmpty);
      expect(key.currentState!.wireEfforts.last, ReasoningEffort.ultra);
      expect(key.currentState!.effort, ReasoningEffort.ultra);
    },
  );

  testWidgets('late local Max acknowledgement does not replay its burst', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key, deferAck: true));
    final bounds = tester.getRect(find.byKey(const ValueKey('motion_slider')));
    final maxX = bounds.left + 16 + (bounds.width - 32) * 0.8;

    await tester.tapAt(Offset(maxX, bounds.center.dy));
    await tester.pump();
    await tester.pump(
      ClaudeEffortMotionTokens.maxRevealDuration +
          const Duration(milliseconds: 40),
    );
    final dynamic beforeAck = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('motion_slider_paint')))
        .painter;
    expect(beforeAck.animation.isAnimating, isFalse);
    expect(beforeAck.debugBurstProgress(0), -1);

    key.currentState!.ackPendingEffort();
    await tester.pump();
    final dynamic afterAck = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('motion_slider_paint')))
        .painter;
    expect(afterAck.animation.isAnimating, isFalse);
    expect(afterAck.debugBurstProgress(0), -1);

    await tester.pump(const Duration(milliseconds: 1510));
    await tester.pump();
    final dynamic painter = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('motion_slider_paint')))
        .painter;
    expect(painter.animation.isAnimating, isFalse);
    expect(painter.debugPixelFieldOpacity, greaterThan(0));
    expect(painter.debugPixelFieldReach, greaterThan(0));
    expect(painter.debugPixelFieldFlowsToPhysicalLeft, isTrue);
    final reachBeforeRebuild = painter.debugPixelFieldReach as double;
    key.currentState!.rebuildOnly();
    await tester.pump(const Duration(milliseconds: 120));
    final dynamic rebuilt = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('motion_slider_paint')))
        .painter;
    expect(
      rebuilt.debugPixelFieldReach,
      greaterThanOrEqualTo(reachBeforeRebuild),
    );
  });

  testWidgets('Fast acknowledgement does not interrupt a tier arrival burst', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key, deferAck: true));
    final bounds = tester.getRect(find.byKey(const ValueKey('motion_slider')));
    final maxX = bounds.left + 16 + (bounds.width - 32) * 0.8;

    dynamic painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('motion_slider_paint')))
        .painter;

    await tester.tapAt(Offset(maxX, bounds.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(painter().debugIsTierReveal, isTrue);
    expect(painter().debugBurstProgress(0), inInclusiveRange(0.0, 1.0));

    key.currentState!.ackPendingEffortWithFast(true);
    await tester.pump(const Duration(milliseconds: 10));
    expect(key.currentState!.effort, ReasoningEffort.max);
    expect(key.currentState!.speed, CodexSpeed.fast);
    expect(painter().debugIsTierReveal, isTrue);
    expect(painter().debugBurstProgress(0), inInclusiveRange(0.0, 1.0));

    await tester.pump(const Duration(milliseconds: 600));
    expect(painter().debugIsTierReveal, isFalse);
    expect(painter().animation.isAnimating, isTrue);
    await tester.pump(const Duration(milliseconds: 1160));
    expect(painter().animation.isAnimating, isFalse);
  });

  testWidgets('drag keeps ownership after canceling reveal with queued Fast', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key, deferAck: true));
    final slider = find.byKey(const ValueKey('motion_slider'));
    final bounds = tester.getRect(slider);
    final maxX = bounds.left + 16 + (bounds.width - 32) * 0.8;

    dynamic painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('motion_slider_paint')))
        .painter;
    GestureDetector detector() => tester.widget<GestureDetector>(
      find.descendant(of: slider, matching: find.byType(GestureDetector)),
    );
    double xFor(double position) {
      final inset = CodexEffortMotionMetrics.maxVisualThumbRadius;
      return inset + (bounds.width - inset * 2) * position;
    }

    await tester.tapAt(Offset(maxX, bounds.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    key.currentState!.ackPendingEffortWithFast(true);
    await tester.pump(const Duration(milliseconds: 10));
    expect(painter().debugIsTierReveal, isTrue);

    detector().onHorizontalDragStart!(
      DragStartDetails(localPosition: Offset(xFor(0.8), 24)),
    );
    await tester.pump();
    expect(painter().debugIsDragging, isTrue);

    detector().onHorizontalDragUpdate!(
      DragUpdateDetails(
        globalPosition: Offset(xFor(0.2), 24),
        localPosition: Offset(xFor(0.2), 24),
      ),
    );
    await tester.pump();
    expect(painter().debugIsDragging, isTrue);
    detector().onHorizontalDragEnd!(DragEndDetails());
    await tester.pump();

    expect(painter().debugIsDragging, isFalse);
    expect(key.currentState!.wireEfforts.last, ReasoningEffort.medium);
    await tester.pump(
      ClaudeEffortMotionTokens.dragSettleDuration +
          const Duration(milliseconds: 20),
    );
    expect(painter().animation.isAnimating, isFalse);
  });

  testWidgets('effort increase visibly glides the thumb and active range', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key));
    final finder = find.byKey(const ValueKey('motion_slider'));
    final bounds = tester.getRect(finder);
    final targetX =
        bounds.left +
        CodexEffortMotionMetrics.maxVisualThumbRadius +
        (bounds.width - CodexEffortMotionMetrics.maxVisualThumbRadius * 2) *
            0.6;

    dynamic painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('motion_slider_paint')))
        .painter;

    expect(painter().debugLogicalPosition, closeTo(0.4, 0.001));
    await tester.tapAt(Offset(targetX, bounds.center.dy));
    await tester.pump();
    expect(painter().debugLogicalPosition, closeTo(0.4, 0.001));
    await tester.pump(const Duration(milliseconds: 120));
    expect(painter().debugLogicalPosition, greaterThan(0.4));
    expect(painter().debugLogicalPosition, lessThan(0.6));
    expect(painter().debugBurstParticleCount, 8);
    await tester.pump(const Duration(milliseconds: 190));
    expect(painter().debugLogicalPosition, closeTo(0.6, 0.001));
  });

  testWidgets('Ultra pixel ignition expands gradually with varied cells', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key));

    dynamic painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('motion_slider_paint')))
        .painter;

    key.currentState!.setEffort(ReasoningEffort.ultra);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(painter().debugPixelFieldReach, inInclusiveRange(0.20, 0.45));
    expect(painter().debugLitPixelCellCount, inInclusiveRange(4, 240));
    expect(painter().debugLitPixelRowCount, greaterThan(1));
    final checksum = painter().debugPixelEnergyChecksum as double;
    await tester.pump(const Duration(milliseconds: 120));
    expect(painter().debugPixelEnergyChecksum, isNot(closeTo(checksum, 0.001)));

    for (var frame = 0; frame < 18; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(painter().debugPixelFieldReach, greaterThan(0.95));
    expect(painter().debugFarthestStrongPixelColumn, greaterThanOrEqualTo(66));
    expect(painter().debugStrongPixelColumnCount, greaterThan(48));
  });

  testWidgets('endpoint dots and overshooting thumb stay inside the control', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key));
    final paintFinder = find.byKey(const ValueKey('motion_slider_paint'));
    final size = tester.getSize(paintFinder);
    final dynamic painter = tester.widget<CustomPaint>(paintFinder).painter;
    final Rect track = painter.debugTrackBounds(size) as Rect;
    final firstX = CodexEffortMotionMetrics.maxVisualThumbRadius;
    final lastX = size.width - CodexEffortMotionMetrics.maxVisualThumbRadius;
    final tickRadius = CodexEffortMotionMetrics.tickDiameter / 2;

    expect(firstX - tickRadius, greaterThanOrEqualTo(track.left));
    expect(lastX + tickRadius, lessThanOrEqualTo(track.right));

    key.currentState!.setEffort(ReasoningEffort.ultra);
    await tester.pump();
    await tester.pump(
      ClaudeEffortMotionTokens.ultraRevealDuration +
          const Duration(milliseconds: 20),
    );
    final dynamic ultraPainter = tester
        .widget<CustomPaint>(paintFinder)
        .painter;
    final Rect ultraActive = ultraPainter.debugActiveBounds(size) as Rect;
    expect(ultraActive.right, closeTo(track.right, 0.001));

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 24,
            child: CodexEffortMotionSlider(
              labels: const ['light', 'ultra'],
              selectedIndex: 1,
              sliderKey: 'narrow_slider',
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    final narrowPaint = find.byKey(const ValueKey('narrow_slider_paint'));
    final narrowSize = tester.getSize(narrowPaint);
    final dynamic narrowPainter = tester
        .widget<CustomPaint>(narrowPaint)
        .painter;
    expect(
      narrowPainter.debugThumbCenterX(narrowSize.width),
      inInclusiveRange(0.0, narrowSize.width),
    );
  });

  testWidgets('exposes slider semantics and keyboard steps', (tester) async {
    final semantics = tester.ensureSemantics();
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key));

    final finder = find.byKey(const ValueKey('motion_slider'));
    final data = tester.getSemantics(finder).getSemanticsData();
    expect(data.flagsCollection.isSlider, isTrue);
    expect(data.hasAction(SemanticsAction.increase), isTrue);
    expect(data.hasAction(SemanticsAction.decrease), isTrue);
    expect(data.label, 'Effort');
    expect(data.value, 'high');

    final bounds = tester.getRect(finder);
    await tester.tapAt(
      Offset(bounds.left + bounds.width * 0.4, bounds.center.dy),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(key.currentState!.effort, ReasoningEffort.xhigh);

    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(key.currentState!.effort, ReasoningEffort.ultra);
    semantics.dispose();
  });

  testWidgets('same index enters X-high, Max and Ultra as semantics change', (
    tester,
  ) async {
    final key = GlobalKey<_SemanticTierHarnessState>();
    await tester.pumpWidget(_SemanticTierHarness(key: key));

    dynamic painter() => tester
        .widget<CustomPaint>(
          find.byKey(const ValueKey('semantic_motion_slider_paint')),
        )
        .painter;

    key.currentState!.showXHighAtSameIndex();
    await tester.pump();
    expect(painter().animation.isAnimating, isTrue);
    await tester.pump(
      ClaudeEffortMotionTokens.xHighRevealDuration +
          const Duration(milliseconds: 10),
    );
    expect(painter().animation.isAnimating, isFalse);
    expect(painter().debugPixelFieldOpacity, greaterThan(0));
    final xHighReach = painter().debugPixelFieldReach as double;

    key.currentState!.showMaxAtSameIndex();
    await tester.pump();
    expect(painter().animation.isAnimating, isTrue);
    expect(painter().debugPixelFieldOpacity, greaterThan(0));
    expect(painter().debugPixelFieldReach, greaterThanOrEqualTo(xHighReach));
    await tester.pump(
      ClaudeEffortMotionTokens.maxRevealDuration +
          const Duration(milliseconds: 10),
    );
    expect(painter().animation.isAnimating, isFalse);
    final maxReach = painter().debugPixelFieldReach as double;
    expect(maxReach, greaterThan(xHighReach));

    key.currentState!.showUltraAtSameIndex();
    await tester.pump();
    expect(painter().animation.isAnimating, isTrue);
    expect(painter().debugPixelFieldOpacity, greaterThan(0));
    expect(painter().debugPixelFieldReach, greaterThanOrEqualTo(maxReach));
    await tester.pump(
      ClaudeEffortMotionTokens.ultraRevealDuration +
          const Duration(milliseconds: 10),
    );
    expect(painter().animation.isAnimating, isFalse);
    expect(tester.hasRunningAnimations, isTrue);
  });

  testWidgets('RTL pointer and keyboard directions remain native', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key, rtl: true));
    final finder = find.byKey(const ValueKey('motion_slider'));
    final bounds = tester.getRect(finder);

    await tester.tapAt(Offset(bounds.left + 15, bounds.center.dy));
    await tester.pump();
    await tester.pump(
      ClaudeEffortMotionTokens.ultraRevealDuration +
          const Duration(milliseconds: 20),
    );
    expect(key.currentState!.effort, ReasoningEffort.ultra);

    final paintFinder = find.byKey(const ValueKey('motion_slider_paint'));
    final paintSize = tester.getSize(paintFinder);
    final dynamic painter = tester.widget<CustomPaint>(paintFinder).painter;
    final Rect track = painter.debugTrackBounds(paintSize) as Rect;
    final Rect field = painter.debugPixelFieldBounds(paintSize) as Rect;
    expect(painter.debugPixelFieldFlowsToPhysicalLeft, isFalse);
    expect(painter.debugPixelFieldFlowsToPhysicalRight, isTrue);
    expect(field.width, greaterThan(track.width * 0.5));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(key.currentState!.effort, ReasoningEffort.max);
  });

  testWidgets(
    'arrival burst is finite while pixel fire is bounded and disposable',
    (tester) async {
      final key = GlobalKey<_EffortHarnessState>();
      await tester.pumpWidget(_EffortHarness(key: key));

      dynamic painter() => tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('motion_slider_paint')),
          )
          .painter;

      key.currentState!.setFast(true);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 1160));
      expect(tester.hasRunningAnimations, isFalse);

      key.currentState!.setEffort(ReasoningEffort.max);
      await tester.pump();
      expect(painter().animation.isAnimating, isTrue);
      expect(painter().debugBurstParticleCount, 12);
      await tester.pump(const Duration(milliseconds: 300));
      expect(painter().debugBurstProgress(0), inInclusiveRange(0.0, 1.0));
      await tester.pump(
        ClaudeEffortMotionTokens.maxRevealDuration -
            const Duration(milliseconds: 290),
      );
      expect(painter().animation.isAnimating, isFalse);
      expect(painter().debugBurstProgress(0), -1);
      expect(painter().debugPixelCellCapacity, 432);
      expect(painter().debugPixelFieldOpacity, greaterThan(0));
      expect(painter().debugPixelFieldReach, greaterThan(0));
      expect(painter().debugPixelFieldFlowsToPhysicalLeft, isTrue);
      final paintSize = tester.getSize(
        find.byKey(const ValueKey('motion_slider_paint')),
      );
      final Rect track = painter().debugTrackBounds(paintSize) as Rect;
      final Rect field = painter().debugPixelFieldBounds(paintSize) as Rect;
      expect(field.left, greaterThanOrEqualTo(track.left));
      expect(field.right, lessThanOrEqualTo(track.right));
      expect(tester.hasRunningAnimations, isTrue);

      key.currentState!.setEffort(ReasoningEffort.ultra);
      await tester.pump();
      expect(painter().animation.isAnimating, isTrue);
      await tester.pump(
        ClaudeEffortMotionTokens.ultraRevealDuration -
            const Duration(milliseconds: 10),
      );
      expect(painter().animation.isAnimating, isTrue);
      await tester.pump(const Duration(milliseconds: 20));
      expect(painter().animation.isAnimating, isFalse);
      expect(painter().debugPixelFieldOpacity, greaterThan(0));
      expect(painter().debugPixelFieldReach, greaterThan(0));
      expect(tester.hasRunningAnimations, isTrue);

      key.currentState!.setFast(false);
      await tester.pump();
      expect(painter().animation.isAnimating, isTrue);
      await tester.pump(const Duration(milliseconds: 360));
      expect(painter().animation.isAnimating, isFalse);
      expect(tester.hasRunningAnimations, isTrue);

      key.currentState!.setEffort(ReasoningEffort.high);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 850));
      expect(tester.hasRunningAnimations, isFalse);
      final dynamic oldPainter = tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('motion_slider_paint')),
          )
          .painter;
      expect(oldPainter.debugPixelFieldOpacity, 0);
      expect(oldPainter.debugUsesSolidActivePaint, isTrue);
      key.currentState!.rebuildOnly();
      await tester.pump();
      final dynamic rebuiltPainter = tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('motion_slider_paint')),
          )
          .painter;
      expect(identical(oldPainter, rebuiltPainter), isFalse);
      expect(rebuiltPainter.shouldRepaint(oldPainter), isFalse);

      key.currentState!.setFast(true);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.hasRunningAnimations, isFalse);
    },
  );

  testWidgets(
    'opening on Ultra shows settled pixel fire without replaying arrival burst',
    (tester) async {
      final key = GlobalKey<_EffortHarnessState>();
      await tester.pumpWidget(
        _EffortHarness(key: key, initialEffort: ReasoningEffort.ultra),
      );
      await tester.pump();

      dynamic painter() => tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('motion_slider_paint')),
          )
          .painter;

      expect(painter().debugAccent, ClaudeEffortAccent.ultra);
      expect(painter().animation.isAnimating, isFalse);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 240));
      expect(painter().debugPixelFieldOpacity, 1);
      expect(painter().debugPixelFieldReach, 1);
      expect(painter().debugPixelFieldFlowsToPhysicalLeft, isTrue);
      expect(painter().debugLitPixelCellCount, greaterThan(120));
      expect(painter().debugLitPixelRowCount, 6);
      expect(
        painter().debugFarthestStrongPixelColumn,
        greaterThanOrEqualTo(66),
      );
      expect(painter().debugStrongPixelColumnCount, greaterThan(48));
      final checksum = painter().debugPixelEnergyChecksum as double;
      expect(painter().debugBurstProgress(0), -1);
      await tester.pump(const Duration(milliseconds: 240));
      expect(
        painter().debugPixelEnergyChecksum,
        isNot(closeTo(checksum, 0.001)),
      );

      final sampleCoordinates = <(int, int)>[
        for (final column in <int>[4, 12, 20, 28, 36, 44, 52, 60, 68])
          for (var row = 0; row < 6; row++) (column, row),
      ];
      List<double> sampleEnergies() => [
        for (final coordinate in sampleCoordinates)
          painter().debugPixelEnergyAt(coordinate.$1, coordinate.$2) as double,
      ];

      var previousEnergies = sampleEnergies();
      final brightenedCells = <int>{};
      final dimmedCells = <int>{};
      final reversedCells = <int>{};
      final lastDirection = List<int>.filled(sampleCoordinates.length, 0);
      for (var frame = 0; frame < 18; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        final currentEnergies = sampleEnergies();
        for (var index = 0; index < currentEnergies.length; index++) {
          final delta = currentEnergies[index] - previousEnergies[index];
          final direction = delta > 0.002
              ? 1
              : delta < -0.002
              ? -1
              : 0;
          if (direction > 0) brightenedCells.add(index);
          if (direction < 0) dimmedCells.add(index);
          if (direction != 0 &&
              lastDirection[index] != 0 &&
              direction != lastDirection[index]) {
            reversedCells.add(index);
          }
          if (direction != 0) lastDirection[index] = direction;
        }
        previousEnergies = currentEnergies;
      }
      expect(brightenedCells.length, greaterThan(8));
      expect(dimmedCells.length, greaterThan(8));
      expect(reversedCells.length, greaterThan(4));

      List<List<double>> rowProfiles() => [
        for (var row = 0; row < 6; row++)
          [
            for (var column = 0; column < 72; column++)
              painter().debugPixelEnergyAt(column, row) as double,
          ],
      ];

      double shiftedCorrelation(
        List<double> before,
        List<double> after,
        int shift,
      ) {
        final start = math.max(8, 8 - shift);
        final end = math.min(64, 64 - shift);
        final count = end - start;
        if (count < 8) return -1;
        var beforeMean = 0.0;
        var afterMean = 0.0;
        for (var column = start; column < end; column++) {
          beforeMean += before[column];
          afterMean += after[column + shift];
        }
        beforeMean /= count;
        afterMean /= count;
        var numerator = 0.0;
        var beforeVariance = 0.0;
        var afterVariance = 0.0;
        for (var column = start; column < end; column++) {
          final beforeDelta = before[column] - beforeMean;
          final afterDelta = after[column + shift] - afterMean;
          numerator += beforeDelta * afterDelta;
          beforeVariance += beforeDelta * beforeDelta;
          afterVariance += afterDelta * afterDelta;
        }
        final denominator = math.sqrt(beforeVariance * afterVariance);
        return denominator <= 0.000001 ? -1 : numerator / denominator;
      }

      final beforeFlow = rowProfiles();
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      final afterFlow = rowProfiles();
      final bestShifts = <int>[];
      for (var row = 0; row < 6; row++) {
        var bestShift = -8;
        var bestCorrelation = double.negativeInfinity;
        for (var shift = -8; shift <= 8; shift++) {
          final correlation = shiftedCorrelation(
            beforeFlow[row],
            afterFlow[row],
            shift,
          );
          if (correlation > bestCorrelation) {
            bestCorrelation = correlation;
            bestShift = shift;
          }
        }
        bestShifts.add(bestShift);
      }
      expect(
        bestShifts.where((shift) => shift >= 2).length,
        greaterThanOrEqualTo(3),
        reason: 'Expected outward column motion, got shifts $bestShifts',
      );
      final rowPairCorrelations = <double>[];
      for (var first = 0; first < 6; first++) {
        for (var second = first + 1; second < 6; second++) {
          rowPairCorrelations.add(
            shiftedCorrelation(afterFlow[first], afterFlow[second], 0),
          );
        }
      }
      expect(
        rowPairCorrelations.reduce(math.max),
        lessThan(0.92),
        reason: 'Rows must not collapse into a synchronized bright band',
      );
      expect(tester.hasRunningAnimations, isTrue);
      expect(painter().animation.isAnimating, isFalse);
    },
  );

  testWidgets('TickerMode pauses pixel fire without accumulating hidden time', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(
      _EffortHarness(key: key, initialEffort: ReasoningEffort.ultra),
    );
    await tester.pump(const Duration(milliseconds: 80));

    dynamic painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('motion_slider_paint')))
        .painter;

    final elapsedBeforePause = painter().debugPixelFieldElapsed as double;
    key.currentState!.setTickerEnabled(false);
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(painter().debugPixelFieldElapsed, elapsedBeforePause);

    key.currentState!.setTickerEnabled(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.hasRunningAnimations, isTrue);
    expect(
      painter().debugPixelFieldElapsed,
      inInclusiveRange(elapsedBeforePause, elapsedBeforePause + 0.08),
    );
  });

  testWidgets('reduce motion jumps effort, Fast, Max and Ultra to rest', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(
      _EffortHarness(
        key: key,
        disableAnimations: true,
        initialEffort: ReasoningEffort.ultra,
      ),
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);

    key.currentState!.setFast(true);
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);

    key.currentState!.setEffort(ReasoningEffort.max);
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);

    key.currentState!.setEffort(ReasoningEffort.ultra);
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);

    final customPaint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('motion_slider_paint')),
    );
    final dynamic painter = customPaint.painter;
    expect(painter.animation.isAnimating, isFalse);
  });

  testWidgets('enabling reduce motion stops an in-flight reveal', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key));

    key.currentState!.setEffort(ReasoningEffort.max);
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.hasRunningAnimations, isTrue);
    key.currentState!.setReduceMotion(true);
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid effort and Fast prop churn settles on the latest state', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key));

    key.currentState!.setEffort(ReasoningEffort.max);
    await tester.pump(const Duration(milliseconds: 80));
    key.currentState!.setFast(true);
    await tester.pump(const Duration(milliseconds: 80));
    key.currentState!.setEffort(ReasoningEffort.ultra);
    await tester.pump(const Duration(milliseconds: 80));
    key.currentState!.setFast(false);
    await tester.pump(const Duration(milliseconds: 80));
    key.currentState!.setEffort(ReasoningEffort.low);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 850));

    expect(key.currentState!.effort, ReasoningEffort.low);
    expect(key.currentState!.speed, CodexSpeed.standard);
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });
}

class _EffortHarness extends StatefulWidget {
  final bool disableAnimations;
  final bool rtl;
  final bool deferAck;
  final ReasoningEffort initialEffort;

  const _EffortHarness({
    super.key,
    this.disableAnimations = false,
    this.rtl = false,
    this.deferAck = false,
    this.initialEffort = ReasoningEffort.high,
  });

  @override
  State<_EffortHarness> createState() => _EffortHarnessState();
}

class _EffortHarnessState extends State<_EffortHarness> {
  late ReasoningEffort effort;
  CodexSpeed speed = CodexSpeed.standard;
  final wireEfforts = <ReasoningEffort>[];
  late bool reduceMotion;
  bool tickerEnabled = true;
  ReasoningEffort? pendingEffort;

  @override
  void initState() {
    super.initState();
    effort = widget.initialEffort;
    reduceMotion = widget.disableAnimations;
  }

  void setEffort(ReasoningEffort value) => setState(() => effort = value);

  void setFast(bool value) =>
      setState(() => speed = value ? CodexSpeed.fast : CodexSpeed.standard);

  void setReduceMotion(bool value) => setState(() => reduceMotion = value);

  void setTickerEnabled(bool value) => setState(() => tickerEnabled = value);

  void rebuildOnly() => setState(() {});

  void reset() => setState(() {
    effort = ReasoningEffort.high;
    speed = CodexSpeed.standard;
    pendingEffort = null;
    wireEfforts.clear();
  });

  void _onEffortChanged(ReasoningEffort value) {
    wireEfforts.add(value);
    if (widget.deferAck) {
      pendingEffort = value;
    } else {
      setState(() => effort = value);
    }
  }

  void ackPendingEffort() {
    final pending = pendingEffort;
    if (pending == null) return;
    pendingEffort = null;
    setState(() => effort = pending);
  }

  void ackPendingEffortWithFast(bool enabled) {
    final pending = pendingEffort;
    if (pending == null) return;
    pendingEffort = null;
    setState(() {
      effort = pending;
      speed = enabled ? CodexSpeed.fast : CodexSpeed.standard;
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        disableAnimations: reduceMotion,
        accessibleNavigation: reduceMotion,
      ),
      child: Directionality(
        textDirection: widget.rtl ? TextDirection.rtl : TextDirection.ltr,
        child: TickerMode(
          enabled: tickerEnabled,
          child: Material(
            child: Center(
              child: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CodexEffortSlider(
                      efforts: const [
                        ReasoningEffort.low,
                        ReasoningEffort.medium,
                        ReasoningEffort.high,
                        ReasoningEffort.xhigh,
                        ReasoningEffort.max,
                        ReasoningEffort.ultra,
                      ],
                      value: effort,
                      speed: speed,
                      onChanged: _onEffortChanged,
                      sliderKey: 'motion_slider',
                      includeExtended: true,
                    ),
                    Text(effort.label),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SemanticTierHarness extends StatefulWidget {
  const _SemanticTierHarness({super.key});

  @override
  State<_SemanticTierHarness> createState() => _SemanticTierHarnessState();
}

class _SemanticTierHarnessState extends State<_SemanticTierHarness> {
  List<String> labels = const ['light', 'medium', 'high'];
  int? xHighIndex;
  int? maxIndex;
  int? ultraIndex;

  void showXHighAtSameIndex() => setState(() {
    labels = const ['light', 'medium', 'x-high'];
    xHighIndex = 2;
    maxIndex = null;
    ultraIndex = null;
  });

  void showMaxAtSameIndex() => setState(() {
    labels = const ['light', 'medium', 'max'];
    xHighIndex = null;
    maxIndex = 2;
    ultraIndex = null;
  });

  void showUltraAtSameIndex() => setState(() {
    labels = const ['light', 'medium', 'ultra'];
    xHighIndex = null;
    maxIndex = null;
    ultraIndex = 2;
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Material(
      child: Center(
        child: SizedBox(
          width: 320,
          child: CodexEffortMotionSlider(
            labels: labels,
            selectedIndex: 2,
            xHighIndex: xHighIndex,
            maxIndex: maxIndex,
            ultraIndex: ultraIndex,
            onSelected: (_) {},
            sliderKey: 'semantic_motion_slider',
          ),
        ),
      ),
    ),
  );
}
