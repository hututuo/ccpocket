import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

/// Calls [onResume] only on genuine resume from background
/// (paused/hidden/detached),
/// not from inactive (e.g. Android notification shade).
void useAppResumeCallback(
  AppLifecycleState? lifecycleState,
  VoidCallback onResume,
) {
  final wasBackgrounded = useRef(
    lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.hidden ||
        lifecycleState == AppLifecycleState.detached,
  );
  final onResumeRef = useRef(onResume);
  onResumeRef.value = onResume;
  useOnAppLifecycleStateChange((_, current) {
    if (current == AppLifecycleState.paused ||
        current == AppLifecycleState.hidden ||
        current == AppLifecycleState.detached) {
      wasBackgrounded.value = true;
    } else if (current == AppLifecycleState.resumed &&
        wasBackgrounded.value) {
      wasBackgrounded.value = false;
      onResumeRef.value();
    }
  });
}
