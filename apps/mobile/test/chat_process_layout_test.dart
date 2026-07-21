import 'package:ccpocket/features/chat_session/widgets/chat_process_layout.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('groups reasoning and tool execution before the final reply', () {
    final entries = <ChatEntry>[
      UserChatEntry('inspect', clientMessageId: 'turn-1'),
      ServerChatEntry(
        _assistant('work', const [
          ThinkingContent(thinking: 'reasoning'),
          ToolUseContent(
            id: 'tool-1',
            name: 'Read',
            input: {'file_path': 'a.txt'},
          ),
        ]),
      ),
      ServerChatEntry(
        const ToolResultMessage(
          toolUseId: 'tool-1',
          toolName: 'Read',
          content: 'contents',
        ),
      ),
      ServerChatEntry(_assistant('final', const [TextContent(text: 'answer')])),
      ServerChatEntry(const ResultMessage(subtype: 'success')),
    ];

    final layout = buildChatProcessLayout(entries);
    final segment = layout.segmentForEntry(1)!;

    expect(segment.turnKey, 'client:turn-1');
    expect(segment.processEntryIndices, {1, 2});
    expect(segment.summaryEntryIndex, 1);
    expect(segment.thinkingBlocks, 1);
    expect(segment.toolCalls, 1);
    expect(segment.toolResults, 1);
    expect(layout.segmentForEntry(3), isNull);
  });

  test('keeps image and artifact results outside the collapsed process', () {
    final entries = <ChatEntry>[
      UserChatEntry('draw', clientMessageId: 'turn-image'),
      ServerChatEntry(
        const ToolResultMessage(
          toolUseId: 'image-tool',
          toolName: 'ImageGeneration',
          content: 'generated',
          images: [
            ImageRef(id: 'image-1', url: '/images/1', mimeType: 'image/png'),
          ],
        ),
      ),
      ServerChatEntry(_assistant('final', const [TextContent(text: 'done')])),
    ];

    final layout = buildChatProcessLayout(entries);

    expect(layout.segmentForEntry(1), isNull);
    expect(layout.segmentForEntry(2), isNull);
  });

  test('attaches inline reasoning disclosure to the final answer', () {
    final entries = <ChatEntry>[
      UserChatEntry('answer', clientMessageId: 'turn-inline'),
      ServerChatEntry(
        _assistant('final', const [
          ThinkingContent(thinking: 'reasoning'),
          TextContent(text: 'answer'),
        ]),
      ),
    ];

    final segment = buildChatProcessLayout(entries).segmentForEntry(1)!;

    expect(segment.summaryEntryIndex, 1);
    expect(segment.hasInlineProcessAt(1), isTrue);
    expect(segment.processEntryIndices, isEmpty);
  });

  test('keeps tools in per-output segments under a second-level turn fold', () {
    final entries = <ChatEntry>[
      UserChatEntry('investigate', clientMessageId: 'turn-phases'),
      ServerChatEntry(
        _assistant('update-1', const [
          ThinkingContent(thinking: 'first thought'),
          TextContent(text: 'I will inspect the first file.'),
          ToolUseContent(
            id: 'tool-1',
            name: 'Read',
            input: {'file_path': 'first.txt'},
          ),
        ]),
      ),
      ServerChatEntry(
        const ToolResultMessage(
          toolUseId: 'tool-1',
          toolName: 'Read',
          content: 'first result',
        ),
      ),
      ServerChatEntry(
        _assistant('hidden-work', const [
          ToolUseContent(
            id: 'tool-2',
            name: 'Read',
            input: {'file_path': 'second.txt'},
          ),
        ]),
      ),
      ServerChatEntry(
        const ToolResultMessage(
          toolUseId: 'tool-2',
          toolName: 'Read',
          content: 'second result',
        ),
      ),
      ServerChatEntry(
        _assistant('update-2', const [
          TextContent(text: 'The second file confirms the issue.'),
        ]),
      ),
      ServerChatEntry(
        _assistant('final', const [TextContent(text: 'Final answer')]),
      ),
    ];

    final layout = buildChatProcessLayout(entries);
    final firstSegment = layout.segmentForEntry(1)!;
    final secondSegment = layout.segmentForEntry(3)!;
    final turn = layout.turnForEntry(1)!;

    expect(firstSegment.processEntryIndices, {2});
    expect(firstSegment.thinkingBlocks, 1);
    expect(firstSegment.toolCalls, 1);
    expect(firstSegment.toolResults, 1);
    expect(secondSegment.processEntryIndices, {3, 4});
    expect(secondSegment.toolCalls, 1);
    expect(secondSegment.toolResults, 1);
    expect(secondSegment.key, isNot(firstSegment.key));
    expect(turn.intermediateAssistantEntryIndices, {1, 5});
    expect(turn.intermediateEntryIndices, {1, 2, 3, 4, 5});
    expect(turn.intermediateSummaryEntryIndex, 1);
    expect(turn.finalAssistantEntryIndex, 6);
    expect(layout.segmentForEntry(6), isNull);
  });
}

AssistantServerMessage _assistant(String id, List<AssistantContent> content) =>
    AssistantServerMessage(
      message: AssistantMessage(
        id: id,
        role: 'assistant',
        content: content,
        model: 'codex',
      ),
    );
