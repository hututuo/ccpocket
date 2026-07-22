import 'package:ccpocket/features/chat_session/widgets/chat_process_layout.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('folds every historical output and tool before the completed reply', () {
    final entries = <ChatEntry>[
      UserChatEntry('inspect', clientMessageId: 'turn-1'),
      ServerChatEntry(
        _assistant('work', const [
          ThinkingContent(thinking: 'reasoning'),
          TextContent(text: 'I will inspect the file first.'),
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
    final segment = layout.segmentForEntry(1)!;

    expect(segment.turnKey, 'client:turn-1');
    expect(segment.processEntryIndices, {2});
    expect(segment.thinkingBlocks, 1);
    expect(segment.toolCalls, 1);
    expect(segment.toolResults, 1);
    expect(turn.intermediateAssistantEntryIndices, {1});
    expect(turn.intermediateEntryIndices, {1, 2});
    expect(turn.intermediateSummaryEntryIndex, 1);
    expect(turn.finalAssistantEntryIndex, 3);
    expect(turn.currentAssistantEntryIndex, isNull);
    expect(layout.segmentForEntry(3), isNotNull);
  });

  test(
    'retains generic desktop tool shapes instead of treating only files as process',
    () {
      final entries = <ChatEntry>[
        UserChatEntry('search', clientMessageId: 'turn-mcp'),
        ServerChatEntry(
          _assistant('update', const [
            TextContent(text: 'Looking it up.'),
            ToolUseContent(
              id: 'mcp-1',
              name: 'mcp__workspace__lookup',
              input: {'query': 'session history'},
            ),
          ]),
        ),
        ServerChatEntry(
          const ToolResultMessage(
            toolUseId: 'mcp-1',
            toolName: 'mcp__workspace__lookup',
            content: 'matching history',
          ),
        ),
        ServerChatEntry(_assistant('final', const [TextContent(text: 'done')])),
      ];

      final turn = buildChatProcessLayout(entries).turnForEntry(1)!;
      final activity = turn.segments.first.latestTool!;

      expect(turn.intermediateEntryIndices, {1, 2});
      expect(activity.name, 'mcp__workspace__lookup');
      expect(activity.completed, isTrue);
      expect(activity.output, 'matching history');
    },
  );

  test(
    'keeps only the latest persisted interval outside while a turn is active',
    () {
      final entries = <ChatEntry>[
        UserChatEntry('investigate', clientMessageId: 'turn-active'),
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
          _assistant('update-2', const [
            ThinkingContent(thinking: 'current thought'),
            TextContent(text: 'The second file is being checked.'),
            ToolUseContent(
              id: 'tool-2',
              name: 'Bash',
              input: {'command': 'git status --short'},
            ),
          ]),
        ),
      ];

      final layout = buildChatProcessLayout(entries, latestTurnIsActive: true);
      final turn = layout.turnForEntry(1)!;

      expect(turn.intermediateAssistantEntryIndices, {1});
      expect(turn.intermediateEntryIndices, {1, 2});
      expect(turn.currentAssistantEntryIndex, 3);
      expect(turn.currentSegment, isNotNull);
      expect(turn.currentSegment!.assistantEntryIndex, 3);
      expect(turn.currentTool!.name, 'Bash');
      expect(turn.currentTool!.completed, isFalse);
    },
  );

  test(
    'uses the dedicated current-progress surface for a transient stream',
    () {
      final entries = <ChatEntry>[
        UserChatEntry('investigate', clientMessageId: 'turn-stream'),
        ServerChatEntry(
          _assistant('update-1', const [
            TextContent(text: 'Earlier update.'),
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
          _assistant('persisted-before-stream', const [
            TextContent(text: 'Persisted before the live delta.'),
            ToolUseContent(
              id: 'tool-2',
              name: 'WebSearch',
              input: {'query': 'Codex Desktop tool output'},
            ),
          ]),
        ),
      ];

      final layout = buildChatProcessLayout(
        entries,
        latestTurnIsActive: true,
        hasTransientCurrentOutput: true,
      );
      final turn = layout.turnForEntry(1)!;

      expect(turn.hasTransientCurrentOutput, isTrue);
      expect(turn.currentSegment, isNull);
      expect(turn.currentAssistantEntryIndex, isNull);
      expect(turn.intermediateAssistantEntryIndices, {1, 3});
      expect(turn.intermediateEntryIndices, {1, 2, 3});
      expect(turn.currentTool!.name, 'WebSearch');
    },
  );

  test('outer fold owns auxiliary entries between its historical segments', () {
    final entries = <ChatEntry>[
      UserChatEntry('inspect', clientMessageId: 'turn-auxiliary'),
      ServerChatEntry(const StatusMessage(status: ProcessStatus.running)),
      ServerChatEntry(
        _assistant('update', const [TextContent(text: 'Working update')]),
      ),
      ServerChatEntry(
        _assistant('final', const [TextContent(text: 'Completed answer')]),
      ),
      ServerChatEntry(const ResultMessage(subtype: 'success')),
    ];

    final layout = buildChatProcessLayout(entries);
    final turn = layout.turnForEntry(1)!;

    expect(turn.intermediateEntryIndices, {1, 2});
    expect(turn.intermediateSummaryEntryIndex, 1);
    expect(turn.segmentForIntermediateEntry(1), isNull);
    expect(turn.segmentForIntermediateEntry(2)?.assistantEntryIndex, 2);
    expect(turn.finalAssistantEntryIndex, 3);
  });

  test('a delayed tool result stays with its historical inner segment', () {
    final entries = <ChatEntry>[
      UserChatEntry('inspect', clientMessageId: 'turn-delayed-result'),
      ServerChatEntry(
        _assistant('update', const [
          TextContent(text: 'Working update'),
          ToolUseContent(
            id: 'delayed-tool',
            name: 'Read',
            input: {'file_path': 'delayed.txt'},
          ),
        ]),
      ),
      ServerChatEntry(
        _assistant('final', const [TextContent(text: 'Completed answer')]),
      ),
      ServerChatEntry(
        const ToolResultMessage(
          toolUseId: 'delayed-tool',
          toolName: 'Read',
          content: 'delayed result',
        ),
      ),
      ServerChatEntry(const ResultMessage(subtype: 'success')),
    ];

    final layout = buildChatProcessLayout(entries);
    final turn = layout.turnForEntry(1)!;
    final historical = turn.segmentForIntermediateEntry(1)!;

    expect(turn.intermediateEntryIndices, {1, 3});
    expect(turn.segmentForIntermediateEntry(3), same(historical));
    expect(historical.processEntryIndices, {3});
    expect(turn.finalAssistantEntryIndex, 2);
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
