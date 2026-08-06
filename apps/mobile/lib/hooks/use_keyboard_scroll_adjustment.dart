import 'dart:ui' show FlutterView;

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

@visibleForTesting
bool shouldAdjustForKeyboard({
  required double pixels,
  required double minScrollExtent,
}) => pixels > minScrollExtent + 1;

/// Adjusts scroll position when the soft keyboard appears/disappears,
/// keeping the currently visible content in view.
void useKeyboardScrollAdjustment(ScrollController controller) {
  final view = View.of(useContext());
  final observer = useMemoized(
    () => _KeyboardScrollObserver(controller, view),
    [controller, view],
  );
  useEffect(() {
    final binding = WidgetsBinding.instance;
    observer.activate();
    observer.syncCurrentHeight();
    binding.addObserver(observer);
    return () {
      observer.deactivate();
      binding.removeObserver(observer);
    };
  }, [observer]);
}

class _KeyboardScrollObserver with WidgetsBindingObserver {
  final ScrollController controller;
  final FlutterView view;
  double _previousKeyboardHeight = 0;
  var _active = false;

  _KeyboardScrollObserver(this.controller, this.view);

  void activate() => _active = true;

  void deactivate() => _active = false;

  void syncCurrentHeight() {
    _previousKeyboardHeight = _keyboardHeight;
  }

  double get _keyboardHeight {
    return view.viewInsets.bottom / view.devicePixelRatio;
  }

  @override
  void didChangeMetrics() {
    final keyboardHeight = _keyboardHeight;
    final delta = keyboardHeight - _previousKeyboardHeight;
    _previousKeyboardHeight = keyboardHeight;
    if (delta == 0) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_active || !controller.hasClients) return;
      final position = controller.position;
      // A reversed chat list naturally keeps its newest content anchored at
      // offset zero while the viewport changes. Jumping by every keyboard
      // animation delta here needlessly moves the list away from the bottom
      // and forces an extra layout on every animation frame.
      if (!shouldAdjustForKeyboard(
        pixels: position.pixels,
        minScrollExtent: position.minScrollExtent,
      )) {
        return;
      }
      final target = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      controller.jumpTo(target);
    });
  }
}
