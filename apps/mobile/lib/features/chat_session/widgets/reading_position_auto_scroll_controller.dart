import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

/// Marks the full extent of one variable-height timeline item.
///
/// The render object records its own laid-out size while it is allowed to read
/// it. Anchor correction can then use an exact item extent without asking an
/// unrelated RenderBox for `size` during the viewport's layout pass.
class ReadingPositionItem extends SingleChildRenderObjectWidget {
  const ReadingPositionItem({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReadingPositionItem();
}

class _RenderReadingPositionItem extends RenderProxyBox {
  double? laidOutMainAxisExtent;

  @override
  void performLayout() {
    super.performLayout();
    laidOutMainAxisExtent = size.height;
  }
}

/// An [AutoScrollController] that can keep one visible row fixed while a
/// reverse, variable-height chat list changes around it.
///
/// The correction is applied from [ScrollPosition.correctForNewDimensions],
/// while the viewport is still laying out. The displaced state is therefore
/// never painted, and large disclosures do not rely on a later `jumpTo`.
class ReadingPositionAutoScrollController extends SimpleAutoScrollController {
  ReadingPositionAutoScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.suggestedRowHeight,
    super.viewportBoundaryGetter,
    super.debugLabel,
  }) : super(beginGetter: _verticalBegin, endGetter: _verticalEnd);

  _AnchorMutation? _anchorMutation;
  int _generation = 0;

  bool get hasAnchorMutation => _anchorMutation != null;

  int? beginAnchorMutation(GlobalKey anchorKey) {
    final layoutOffset = _sliverMainAxisOffsetFor(anchorKey);
    if (layoutOffset == null) return null;
    final generation = ++_generation;
    _anchorMutation = _AnchorMutation(
      generation: generation,
      anchorKey: anchorKey,
      initialLayoutOffset: layoutOffset,
    );
    return generation;
  }

  void endAnchorMutation(int? generation) {
    if (generation == null || _anchorMutation?.generation != generation) {
      return;
    }
    _anchorMutation = null;
  }

  double? correctionFor(ScrollMetrics metrics) {
    final mutation = _anchorMutation;
    if (mutation == null) return null;
    final currentLayoutOffset = _sliverMainAxisOffsetFor(mutation.anchorKey);
    if (currentLayoutOffset == null) return null;
    final requiredCorrection =
        currentLayoutOffset - mutation.initialLayoutOffset;
    final additionalCorrection =
        requiredCorrection - mutation.appliedCorrection;
    if (additionalCorrection.abs() < 0.5) return null;
    mutation.appliedCorrection = requiredCorrection;
    return (metrics.pixels + additionalCorrection)
        .clamp(metrics.minScrollExtent, metrics.maxScrollExtent)
        .toDouble();
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _ReadingPositionScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      controller: this,
    );
  }
}

class _ReadingPositionScrollPosition extends ScrollPositionWithSingleContext {
  _ReadingPositionScrollPosition({
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    required super.oldPosition,
    required super.debugLabel,
    required this.controller,
  });

  final ReadingPositionAutoScrollController controller;

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    final correctedPixels = controller.correctionFor(newPosition);
    if (correctedPixels != null && correctedPixels != pixels) {
      correctPixels(correctedPixels);
      return false;
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
  }
}

class _AnchorMutation {
  _AnchorMutation({
    required this.generation,
    required this.anchorKey,
    required this.initialLayoutOffset,
  });

  final int generation;
  final GlobalKey anchorKey;
  final double initialLayoutOffset;
  double appliedCorrection = 0;
}

double? _sliverMainAxisOffsetFor(GlobalKey anchorKey) {
  final context = anchorKey.currentContext;
  if (context == null || !context.mounted) return null;
  RenderObject? current = context.findRenderObject();
  if (current == null || !current.attached) return null;
  var boxOffset = 0.0;
  double? exactItemExtent;
  while (current?.parent != null) {
    if (current is _RenderReadingPositionItem) {
      exactItemExtent = current.laidOutMainAxisExtent;
    }
    final parent = current!.parent;
    if (parent is RenderSliverMultiBoxAdaptor) {
      final parentData = current.parentData;
      if (parentData is! SliverMultiBoxAdaptorParentData ||
          current is! RenderBox) {
        return null;
      }
      final sliverOffset = parentData.layoutOffset;
      if (sliverOffset == null) return null;
      final effectiveAxisDirection = applyGrowthDirectionToAxisDirection(
        parent.constraints.axisDirection,
        parent.constraints.growthDirection,
      );
      final rightWayUp =
          effectiveAxisDirection == AxisDirection.down ||
          effectiveAxisDirection == AxisDirection.right;
      if (rightWayUp) {
        return sliverOffset + boxOffset;
      }
      var childExtent = exactItemExtent;
      if (childExtent == null) {
        final nextChild = parent.childAfter(current);
        final nextParentData = nextChild?.parentData;
        final nextOffset = nextParentData is SliverMultiBoxAdaptorParentData
            ? nextParentData.layoutOffset
            : null;
        if (nextOffset == null) return null;
        childExtent = nextOffset - sliverOffset;
      }
      if (childExtent <= 0) return null;
      return sliverOffset + childExtent - boxOffset;
    }
    final parentData = current.parentData;
    if (parentData is BoxParentData) boxOffset += parentData.offset.dy;
    current = parent;
  }
  return null;
}

double _verticalBegin(Rect rect) => rect.top;
double _verticalEnd(Rect rect) => rect.bottom;
