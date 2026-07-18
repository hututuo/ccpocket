import 'dart:ui' show SemanticsAction;

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/widgets/codex_effort_motion.dart';
import 'package:ccpocket/widgets/codex_effort_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('uses the Desktop geometry and preserves effort wire mapping', (
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
    expect(codexMaxParticleCount, 16);
    expect(codexFastParticleCount, 14);

    final bounds = tester.getRect(find.byKey(const ValueKey('motion_slider')));
    await tester.tapAt(Offset(bounds.right - 15, bounds.center.dy));
    await tester.pump();

    expect(key.currentState!.effort, ReasoningEffort.ultra);
    expect(key.currentState!.effort.value, 'ultra');
    expect(find.text('ultra'), findsOneWidget);
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
      await tester.pump(const Duration(milliseconds: 2010));
      expect(tester.hasRunningAnimations, isFalse);

      key.currentState!.setEffort(ReasoningEffort.ultra);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 1090));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.hasRunningAnimations, isFalse);

      final customPaint = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('motion_slider_paint')),
      );
      final dynamic painter = customPaint.painter;
      expect(painter.animation.isAnimating, isFalse);
      expect(painter.shouldRepaint(painter), isFalse);

      key.currentState!.setFast(false);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 360));
      expect(tester.hasRunningAnimations, isFalse);

      key.currentState!.setFast(true);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.hasRunningAnimations, isFalse);
    },
  );

  testWidgets('reduce motion jumps effort, Fast, Max and Ultra to rest', (
    tester,
  ) async {
    final key = GlobalKey<_EffortHarnessState>();
    await tester.pumpWidget(_EffortHarness(key: key, disableAnimations: true));

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
}

class _EffortHarness extends StatefulWidget {
  final bool disableAnimations;

  const _EffortHarness({super.key, this.disableAnimations = false});

  @override
  State<_EffortHarness> createState() => _EffortHarnessState();
}

class _EffortHarnessState extends State<_EffortHarness> {
  ReasoningEffort effort = ReasoningEffort.high;
  CodexSpeed speed = CodexSpeed.standard;

  void setEffort(ReasoningEffort value) => setState(() => effort = value);

  void setFast(bool value) =>
      setState(() => speed = value ? CodexSpeed.fast : CodexSpeed.standard);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        disableAnimations: widget.disableAnimations,
        accessibleNavigation: widget.disableAnimations,
      ),
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
                  onChanged: setEffort,
                  sliderKey: 'motion_slider',
                ),
                Text(effort.label),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
