import 'package:ccpocket/features/chat_session/widgets/bottom_overlay_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keyboard inset does not rebuild chat content', (tester) async {
    addTearDown(tester.view.resetViewInsets);
    var contentBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BottomOverlayLayout(
            content: _BuildCounter(onBuild: () => contentBuilds++),
            overlay: const SizedBox(height: 80),
          ),
        ),
      ),
    );
    expect(contentBuilds, 1);

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();

    expect(contentBuilds, 1);
  });
}

class _BuildCounter extends StatelessWidget {
  final VoidCallback onBuild;

  const _BuildCounter({required this.onBuild});

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox.expand();
  }
}
