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
    expect(ClaudeEffortMotionTokens.particles, hasLength(24));
    expect(
      ClaudeEffortMotionTokens.particleCount(ClaudeEffortAccent.xHigh),
      lessThan(ClaudeEffortMotionTokens.particleCount(ClaudeEffortAccent.max)),
    );
    expect(
      ClaudeEffortMotionTokens.particleCount(ClaudeEffortAccent.max),
      lessThan(
        ClaudeEffortMotionTokens.particleCount(ClaudeEffortAccent.ultra),
      ),
    );
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

  test('purple particles and thumb deformation have finite endpoints', () {
    final particle = ClaudeEffortMotionTokens.particles.first;
    expect(
      ClaudeEffortMotionTokens.particleProgress(
        ClaudeEffortAccent.xHigh,
        0,
        particle,
      ),
      -1,
    );
    expect(
      ClaudeEffortMotionTokens.particleProgress(
        ClaudeEffortAccent.xHigh,
        0.5,
        particle,
      ),
      inInclusiveRange(0.0, 1.0),
    );
    expect(
      ClaudeEffortMotionTokens.particleProgress(
        ClaudeEffortAccent.xHigh,
        1,
        particle,
      ),
      -1,
    );
    expect(
      ClaudeEffortMotionTokens.thumbTravelEnvelope(movePhase: 0, travel: 1),
      closeTo(0, 0.0001),
    );
    expect(
      ClaudeEffortMotionTokens.thumbTravelEnvelope(movePhase: 0.5, travel: 1),
      greaterThan(0.95),
    );
    expect(
      ClaudeEffortMotionTokens.thumbTravelEnvelope(movePhase: 1, travel: 1),
      closeTo(0, 0.0001),
    );
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
      await tester.pumpAndSettle();
      expect(key.currentState!.wireEfforts, isNotEmpty);
      expect(key.currentState!.wireEfforts.last, ReasoningEffort.ultra);
      expect(key.currentState!.effort, ReasoningEffort.ultra);
    },
  );

  testWidgets('local Max acknowledgement does not restart its reveal', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key, deferAck: true));
    final bounds = tester.getRect(find.byKey(const ValueKey('motion_slider')));
    final maxX = bounds.left + 16 + (bounds.width - 32) * 0.8;

    await tester.tapAt(Offset(maxX, bounds.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.hasRunningAnimations, isTrue);
    key.currentState!.ackPendingEffort();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1510));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
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
    expect(painter().debugThumbTravelEnvelope, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 190));
    expect(painter().debugLogicalPosition, closeTo(0.6, 0.001));
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
    await tester.pumpAndSettle();
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

    key.currentState!.showXHighAtSameIndex();
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(
      ClaudeEffortMotionTokens.xHighRevealDuration +
          const Duration(milliseconds: 10),
    );
    expect(tester.hasRunningAnimations, isFalse);

    key.currentState!.showMaxAtSameIndex();
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(
      ClaudeEffortMotionTokens.maxRevealDuration +
          const Duration(milliseconds: 10),
    );
    expect(tester.hasRunningAnimations, isFalse);

    key.currentState!.showUltraAtSameIndex();
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(
      ClaudeEffortMotionTokens.ultraRevealDuration +
          const Duration(milliseconds: 10),
    );
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('RTL pointer and keyboard directions remain native', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key, rtl: true));
    final finder = find.byKey(const ValueKey('motion_slider'));
    final bounds = tester.getRect(finder);

    await tester.tapAt(Offset(bounds.left + 15, bounds.center.dy));
    await tester.pumpAndSettle();
    expect(key.currentState!.effort, ReasoningEffort.ultra);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(key.currentState!.effort, ReasoningEffort.max);
  });

  testWidgets(
    'Fast and high-tier effects are finite and dispose their ticker',
    (tester) async {
      final key = GlobalKey<_EffortHarnessState>();
      await tester.pumpWidget(_EffortHarness(key: key));

      key.currentState!.setFast(true);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 1160));
      expect(tester.hasRunningAnimations, isFalse);

      key.currentState!.setEffort(ReasoningEffort.max);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(
        ClaudeEffortMotionTokens.maxRevealDuration +
            const Duration(milliseconds: 10),
      );
      expect(tester.hasRunningAnimations, isFalse);

      key.currentState!.setEffort(ReasoningEffort.ultra);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(
        ClaudeEffortMotionTokens.ultraRevealDuration -
            const Duration(milliseconds: 10),
      );
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.hasRunningAnimations, isFalse);

      final customPaint = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('motion_slider_paint')),
      );
      final dynamic painter = customPaint.painter;
      expect(painter.animation.isAnimating, isFalse);

      key.currentState!.setFast(false);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 360));
      expect(tester.hasRunningAnimations, isFalse);

      key.currentState!.setEffort(ReasoningEffort.high);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 310));
      final dynamic oldPainter = tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('motion_slider_paint')),
          )
          .painter;
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

  testWidgets('opening on Ultra performs one finite Claude-style reveal', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(
      _EffortHarness(key: key, initialEffort: ReasoningEffort.ultra),
    );
    await tester.pump();

    dynamic painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('motion_slider_paint')))
        .painter;

    expect(painter().debugAccent, ClaudeEffortAccent.ultra);
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(const Duration(milliseconds: 700));
    expect(painter().debugParticleProgress(0), inInclusiveRange(0.0, 1.0));
    await tester.pump(
      ClaudeEffortMotionTokens.ultraRevealDuration -
          const Duration(milliseconds: 690),
    );
    expect(tester.hasRunningAnimations, isFalse);
    expect(painter().animation.isAnimating, isFalse);
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
    await tester.pump(const Duration(milliseconds: 310));

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
