import 'package:flutter/widgets.dart';

import 'chat_process_layout.dart';

typedef ChatIntermediateSegmentBuilder =
    Widget Function(ChatProcessSegmentLayout segment);
typedef ChatIntermediateEntryBuilder = Widget Function(int entryIndex);

/// Renders one turn's historical progress as an actual two-level tree.
///
/// The outer disclosure is the first child and remains mounted while expanded.
/// Each visible assistant update is followed by exactly one process disclosure;
/// that disclosure owns all inline reasoning/tools and later process entries in
/// the same segment. Nothing is revealed by toggling unrelated ListView rows.
class ChatIntermediateProcessGroup extends StatelessWidget {
  const ChatIntermediateProcessGroup({
    super.key,
    required this.turn,
    required this.expanded,
    required this.outerDisclosure,
    required this.segmentBuilder,
    required this.auxiliaryEntryBuilder,
  });

  final ChatProcessTurnLayout turn;
  final bool expanded;
  final Widget outerDisclosure;
  final ChatIntermediateSegmentBuilder segmentBuilder;
  final ChatIntermediateEntryBuilder auxiliaryEntryBuilder;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[outerDisclosure];
    if (expanded) {
      final indices = turn.intermediateEntryIndices.toList()..sort();
      final segmentsByEntryIndex = <int, ChatProcessSegmentLayout>{};
      for (final segment in turn.intermediateSegments) {
        if (segment.assistantEntryIndex case final assistantIndex?
            when turn.intermediateEntryIndices.contains(assistantIndex)) {
          segmentsByEntryIndex[assistantIndex] = segment;
        }
        for (final processIndex in segment.processEntryIndices) {
          if (turn.intermediateEntryIndices.contains(processIndex)) {
            segmentsByEntryIndex[processIndex] = segment;
          }
        }
      }
      final renderedSegmentKeys = <String>{};
      for (final entryIndex in indices) {
        final segment = segmentsByEntryIndex[entryIndex];
        if (segment != null) {
          // Render each segment once at its earliest owned entry. All of its
          // thought/tool rows remain direct descendants of that segment even
          // if a delayed tool result arrived after a later visible update.
          if (renderedSegmentKeys.add(segment.key)) {
            children.add(
              KeyedSubtree(
                key: ValueKey(
                  'chat_intermediate_segment_${turn.key}_${segment.key}',
                ),
                child: segmentBuilder(segment),
              ),
            );
          }
          continue;
        }

        // Non-process entries inside the historical interval still belong to
        // the outer fold, but not to any inner thought/tool disclosure.
        children.add(_entry(entryIndex, auxiliaryEntryBuilder(entryIndex)));
      }
    }

    return Column(
      key: ValueKey('chat_intermediate_group_${turn.key}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _entry(int entryIndex, Widget child) => KeyedSubtree(
    key: ValueKey('chat_intermediate_entry_${turn.key}_$entryIndex'),
    child: child,
  );
}
