import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../features/chat_session/widgets/reading_position_auto_scroll_controller.dart';

/// Cross-session scroll offset persistence.
final Map<String, double> _scrollOffsets = {};

/// Minimum change in maxScrollExtent (in logical pixels) to be considered a
/// layout-driven shift rather than floating-point rounding noise.
const _kExtentChangeTolerance = 1.0;

/// Result record returned by [useScrollTracking].
typedef ScrollTrackingResult = ({
  AutoScrollController controller,
  bool isScrolledUp,
  void Function() scrollToBottom,
});

/// Manages scroll position tracking with three responsibilities:
///
/// 1. **Scrolled-up detection**: Returns `isScrolledUp` when the user scrolls
///    more than 100px from the bottom.
/// 2. **Cross-session offset persistence**: Saves/restores scroll offset keyed
///    by [sessionId] so switching sessions preserves position.
/// 3. **Scroll-to-bottom**: Provides a [scrollToBottom] callback that smoothly
///    animates to the bottom (skipped when the user has scrolled up).
ScrollTrackingResult useScrollTracking(String sessionId) {
  final controller = useMemoized(ReadingPositionAutoScrollController.new);
  // Dispose the controller when the hook is disposed.
  useEffect(() => controller.dispose, const []);

  final isScrolledUp = useState(false);

  // Ref to track isScrolledUp without rebuilds (for scrollToBottom closure).
  final isScrolledUpRef = useRef(false);

  // Track previous maxScrollExtent to detect layout-driven changes
  // (e.g. Android notification shade toggling safe-area padding).
  final prevMaxExtent = useRef<double?>(null);

  useEffect(() {
    void onScroll() {
      if (!controller.hasClients) return;
      final pos = controller.position;

      final prevMax = prevMaxExtent.value;
      prevMaxExtent.value = pos.maxScrollExtent;

      // When maxScrollExtent shifts (viewport/layout change) while we were
      // already at the bottom, ignore this event — don't flip isScrolledUp.
      // The framework will settle the scroll position on the next frame.
      // This prevents the FAB from flashing when the Android notification
      // shade is pulled down/up.
      // Note: when isScrolledUp is already true (user scrolled up), we don't
      // guard — the user's intent takes priority over layout shifts.
      if (prevMax != null && !isScrolledUpRef.value) {
        final extentDelta = (pos.maxScrollExtent - prevMax).abs();
        if (extentDelta > _kExtentChangeTolerance) return;
      }

      // Reverse list: offset 0 = bottom, higher offset = scrolled up.
      final scrolled = pos.pixels > 100;
      isScrolledUpRef.value = scrolled;
      if (scrolled != isScrolledUp.value) {
        isScrolledUp.value = scrolled;
      }
    }

    controller.addListener(onScroll);

    // Restore saved offset after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final saved = _scrollOffsets[sessionId];
      if (saved != null && controller.hasClients) {
        controller.jumpTo(saved);
      }
    });

    return () {
      // Persist offset before disposal.
      if (controller.hasClients) {
        _scrollOffsets[sessionId] = controller.offset;
      }
      controller.removeListener(onScroll);
      prevMaxExtent.value = null;
    };
  }, [sessionId]);

  void scrollToBottom() {
    if (isScrolledUpRef.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) {
        controller.animateTo(
          0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  return (
    controller: controller,
    isScrolledUp: isScrolledUp.value,
    scrollToBottom: scrollToBottom,
  );
}
