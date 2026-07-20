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
    final turn = layout.turnForEntry(1)!;

    expect(turn.key, 'client:turn-1');
    expect(turn.processEntryIndices, {1, 2});
    expect(turn.summaryEntryIndex, 1);
    expect(turn.thinkingBlocks, 1);
    expect(turn.toolCalls, 1);
    expect(turn.toolResults, 1);
    expect(layout.turnForEntry(3), isNull);
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

    expect(layout.turnForEntry(1), isNull);
    expect(layout.turnForEntry(2), isNull);
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

    final turn = buildChatProcessLayout(entries).turnForEntry(1)!;

    expect(turn.summaryEntryIndex, 1);
    expect(turn.hasInlineProcessAt(1), isTrue);
    expect(turn.processEntryIndices, isEmpty);
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
