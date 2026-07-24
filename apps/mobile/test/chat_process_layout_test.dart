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

  test('attaches Guardian review to its tool by target item id', () {
    final entries = <ChatEntry>[
      UserChatEntry('run it', clientMessageId: 'turn-guardian'),
      ServerChatEntry(
        _assistant('guardian-update', const [
          TextContent(text: 'Running the command.'),
          ToolUseContent(
            id: 'guardian-tool',
            name: 'Bash',
            input: {'command': 'git status --short'},
          ),
        ]),
      ),
      ServerChatEntry(
        const ToolResultMessage(
          toolUseId: 'guardian-tool',
          toolName: 'Bash',
          content: 'clean',
        ),
      ),
      ServerChatEntry(
        const GuardianApprovalMessage(
          risk: GuardianApprovalRisk.medium,
          reason: 'The command inspects repository state.',
          reviewId: 'review-guardian',
          targetItemId: 'guardian-tool',
        ),
      ),
    ];

    final layout = buildChatProcessLayout(entries, latestTurnIsActive: true);
    final turn = layout.turnForEntry(1)!;
    final segment = layout.segmentForEntry(3)!;

    expect(segment.processEntryIndices, {2, 3});
    expect(segment.attachedGuardianEntryIndices, {3});
    expect(turn.currentTool?.toolUseId, 'guardian-tool');
    expect(turn.currentTool?.completed, isTrue);
    expect(turn.currentTool?.guardianEntryIndex, 3);
    expect(turn.currentTool?.guardianReview?.reviewId, 'review-guardian');
  });

  test('late Guardian review stays with the tool segment that issued it', () {
    final entries = <ChatEntry>[
      UserChatEntry('inspect both', clientMessageId: 'turn-guardian-late'),
      ServerChatEntry(
        _assistant('guardian-earlier', const [
          TextContent(text: 'Inspecting the first item.'),
          ToolUseContent(
            id: 'guardian-old-tool',
            name: 'Read',
            input: {'file_path': 'first.txt'},
          ),
        ]),
      ),
      ServerChatEntry(
        _assistant('guardian-current', const [
          TextContent(text: 'Inspecting the second item.'),
          ToolUseContent(
            id: 'guardian-current-tool',
            name: 'Read',
            input: {'file_path': 'second.txt'},
          ),
        ]),
      ),
      ServerChatEntry(
        const GuardianApprovalMessage(
          risk: GuardianApprovalRisk.low,
          reason: 'The first read is safe.',
          targetItemId: 'guardian-old-tool',
        ),
      ),
    ];

    final turn = buildChatProcessLayout(
      entries,
      latestTurnIsActive: true,
    ).turnForEntry(1)!;
    final reviewedSegment = turn.segmentForIntermediateEntry(3)!;

    expect(reviewedSegment.assistantEntryIndex, 1);
    expect(reviewedSegment.latestTool?.toolUseId, 'guardian-old-tool');
    expect(reviewedSegment.attachedGuardianEntryIndices, {3});
    expect(turn.currentTool?.toolUseId, 'guardian-current-tool');
    expect(turn.currentTool?.guardianReview, isNull);
  });

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

  test('folds a leading partial turn whose user entry was paged out', () {
    final entries = <ChatEntry>[
      ServerChatEntry(
        _assistant('partial-update', const [
          ThinkingContent(thinking: 'partial reasoning'),
          TextContent(text: 'A visible update inside the retained window.'),
          ToolUseContent(
            id: 'partial-tool',
            name: 'Read',
            input: {'file_path': 'partial.txt'},
          ),
        ]),
      ),
      ServerChatEntry(
        const ToolResultMessage(
          toolUseId: 'partial-tool',
          toolName: 'Read',
          content: 'partial result',
        ),
      ),
      ServerChatEntry(
        _assistant('partial-final', const [
          TextContent(text: 'The retained final answer.'),
        ]),
      ),
      ServerChatEntry(const ResultMessage(subtype: 'success')),
    ];

    final layout = buildChatProcessLayout(entries);
    final turn = layout.turnForEntry(0)!;

    expect(turn.key, 'partial:id:partial-update');
    expect(turn.intermediateAssistantEntryIndices, {0});
    expect(turn.intermediateEntryIndices, {0, 1});
    expect(turn.intermediateSummaryEntryIndex, 0);
    expect(turn.finalAssistantEntryIndex, 2);
    expect(turn.hasIntermediateEntries, isTrue);
    expect(layout.segmentForEntry(0)?.toolCalls, 1);
    expect(layout.segmentForEntry(1)?.toolResults, 1);
  });

  test(
    'keeps every persisted segment in a partial active turn behind transient progress',
    () {
      final entries = <ChatEntry>[
        ServerChatEntry(
          _assistant('partial-update-1', const [
            TextContent(text: 'Earlier retained update.'),
            ToolUseContent(
              id: 'partial-tool-1',
              name: 'Read',
              input: {'file_path': 'first.txt'},
            ),
          ]),
        ),
        ServerChatEntry(
          const ToolResultMessage(
            toolUseId: 'partial-tool-1',
            toolName: 'Read',
            content: 'first result',
          ),
        ),
        ServerChatEntry(
          _assistant('partial-update-2', const [
            ThinkingContent(thinking: 'latest persisted reasoning'),
            TextContent(text: 'Latest persisted update.'),
            ToolUseContent(
              id: 'partial-tool-2',
              name: 'Bash',
              input: {'command': 'git status --short'},
            ),
          ]),
        ),
      ];

      final layout = buildChatProcessLayout(
        entries,
        latestTurnIsActive: true,
        hasTransientCurrentOutput: true,
      );
      final turn = layout.turnForEntry(0)!;

      expect(turn.hasTransientCurrentOutput, isTrue);
      expect(turn.currentSegment, isNull);
      expect(turn.intermediateAssistantEntryIndices, {0, 2});
      expect(turn.intermediateEntryIndices, {0, 1, 2});
      expect(turn.currentTool?.name, 'Bash');
    },
  );

  test('does not absorb an unrelated leading status without process data', () {
    final entries = <ChatEntry>[
      ServerChatEntry(const StatusMessage(status: ProcessStatus.idle)),
      UserChatEntry('next turn', clientMessageId: 'next-turn'),
      ServerChatEntry(
        _assistant('next-final', const [TextContent(text: 'Next answer')]),
      ),
    ];

    final layout = buildChatProcessLayout(entries);

    expect(layout.turnForEntry(0), isNull);
    expect(layout.latestTurnKey, 'client:next-turn');
    expect(layout.turnForEntry(2)?.finalAssistantEntryIndex, 2);
  });

  test(
    'keeps the latest plan update outside process folds and current tools',
    () {
      final entries = <ChatEntry>[
        UserChatEntry('implement', clientMessageId: 'turn-plan'),
        ServerChatEntry(
          _assistant('plan-1', const [
            ToolUseContent(
              id: 'plan-tool-1',
              name: 'UpdatePlan',
              input: {
                'title': 'Plan',
                'todos': [
                  {
                    'content': 'Inspect',
                    'status': 'in_progress',
                    'activeForm': 'Inspecting',
                  },
                ],
              },
            ),
          ]),
        ),
        ServerChatEntry(
          _assistant('working', const [
            TextContent(text: 'Inspecting the source.'),
            ToolUseContent(
              id: 'read-tool',
              name: 'Read',
              input: {'file_path': 'source.dart'},
            ),
          ]),
        ),
        ServerChatEntry(
          _assistant('plan-2', const [
            ToolUseContent(
              id: 'plan-tool-2',
              name: 'UpdatePlan',
              input: {
                'title': 'Plan',
                'todos': [
                  {
                    'content': 'Inspect',
                    'status': 'completed',
                    'activeForm': '',
                  },
                  {
                    'content': 'Implement',
                    'status': 'in_progress',
                    'activeForm': 'Implementing',
                  },
                ],
              },
            ),
          ]),
        ),
      ];

      final layout = buildChatProcessLayout(entries, latestTurnIsActive: true);
      final turn = layout.turnForEntry(1)!;

      expect(turn.planUpdateEntryIndices, {1, 3});
      expect(turn.showsPlanUpdateAt(1), isFalse);
      expect(turn.showsPlanUpdateAt(3), isTrue);
      expect(turn.latestPlanUpdateInput?['todos'], hasLength(2));
      expect(turn.currentTool?.name, 'Read');
      expect(turn.intermediateEntryIndices, isNot(contains(1)));
      expect(turn.intermediateEntryIndices, isNot(contains(3)));
    },
  );

  test('recognizes a legacy plan-only text update as an outer live card', () {
    final entries = <ChatEntry>[
      UserChatEntry('implement', clientMessageId: 'turn-legacy-plan'),
      ServerChatEntry(
        _assistant('legacy-plan', const [
          TextContent(
            text:
                'Plan update: implementation started\n'
                '1. [completed] Inspect\n'
                '2. [in progress] Implement',
          ),
        ]),
      ),
    ];

    final turn = buildChatProcessLayout(
      entries,
      latestTurnIsActive: true,
    ).turnForEntry(1)!;

    expect(turn.planUpdateEntryIndices, {1});
    expect(
      turn.latestPlanUpdateInput?['explanation'],
      'implementation started',
    );
    expect(turn.currentTool, isNull);
  });

  test(
    'keeps an idless process segment key stable when history is prepended',
    () {
      final currentTurn = <ChatEntry>[
        UserChatEntry('inspect', clientMessageId: 'stable-turn'),
        ServerChatEntry(
          AssistantServerMessage(
            message: const AssistantMessage(
              id: '',
              role: 'assistant',
              content: [
                ThinkingContent(thinking: 'checking'),
                TextContent(text: 'Inspecting now.'),
                ToolUseContent(
                  id: 'stable-tool-id',
                  name: 'Read',
                  input: {'file_path': 'stable.txt'},
                ),
              ],
              model: 'codex',
            ),
          ),
        ),
        ServerChatEntry(
          const ToolResultMessage(
            toolUseId: 'stable-tool-id',
            toolName: 'Read',
            content: 'contents',
          ),
        ),
        ServerChatEntry(
          _assistant('stable-final', const [TextContent(text: 'Done')]),
        ),
      ];

      final initialKey = buildChatProcessLayout(
        currentTurn,
      ).segmentForEntry(1)!.key;
      final withOlderTurn = <ChatEntry>[
        UserChatEntry('older', clientMessageId: 'older-turn'),
        ServerChatEntry(
          _assistant('older-final', const [TextContent(text: 'Older answer')]),
        ),
        ...currentTurn,
      ];
      final prependedKey = buildChatProcessLayout(
        withOlderTurn,
      ).segmentForEntry(3)!.key;

      expect(initialKey, prependedKey);
      expect(initialKey, contains('tool:stable-tool-id'));
    },
  );
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
