import 'package:ccpocket/hooks/use_app_resume_callback.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'observes a background-to-resumed transition while frames are disabled',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var resumeCount = 0;

      await tester.pumpWidget(
        HookBuilder(
          builder: (context) {
            final lifecycleState = useAppLifecycleState();
            useAppResumeCallback(lifecycleState, () => resumeCount += 1);
            return const SizedBox.shrink();
          },
        ),
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(resumeCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(resumeCount, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(resumeCount, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(resumeCount, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(resumeCount, 2);
    },
  );
}
