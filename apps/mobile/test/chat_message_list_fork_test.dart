import 'package:ccpocket/features/chat_session/widgets/chat_message_list.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldShowForkForAssistant', () {
    test('only exposes the final visible reply inside one completed turn', () {
      final first = _assistant('a1');
      final second = _assistant('a2');
      final entries = <ChatEntry>[
        UserChatEntry('hello'),
        ServerChatEntry(first),
        ServerChatEntry(_toolResult('tool1')),
        ServerChatEntry(second),
        ServerChatEntry(_toolResult('tool2')),
        ServerChatEntry(_result()),
      ];

      expect(shouldShowForkForAssistant(entries, 1), isFalse);
      expect(shouldShowForkForAssistant(entries, 3), isTrue);
      expect(forkableAssistantEntryIndices(entries), {3});
    });

    test('uses the next user turn as a completed Desktop-history boundary', () {
      final entries = <ChatEntry>[
        UserChatEntry('first'),
        ServerChatEntry(_assistant('a1')),
        UserChatEntry('second'),
        ServerChatEntry(_assistant('a2')),
      ];

      expect(shouldShowForkForAssistant(entries, 1), isTrue);
      expect(shouldShowForkForAssistant(entries, 3), isFalse);
      expect(forkableAssistantEntryIndices(entries), {1});
    });

    test('does not split one turn at result-only boundaries', () {
      final entries = <ChatEntry>[
        ServerChatEntry(_assistant('a1')),
        ServerChatEntry(_result()),
        ServerChatEntry(_assistant('a2')),
        ServerChatEntry(_toolResult('tool')),
        ServerChatEntry(_result()),
      ];

      expect(shouldShowForkForAssistant(entries, 0), isFalse);
      expect(shouldShowForkForAssistant(entries, 2), isTrue);
      expect(forkableAssistantEntryIndices(entries), {2});
    });

    test(
      'only exposes a result-less transcript tail when the turn is idle',
      () {
        final entries = <ChatEntry>[
          UserChatEntry('first'),
          ServerChatEntry(_assistant('a1')),
        ];

        expect(shouldShowForkForAssistant(entries, 1), isFalse);
        expect(
          shouldShowForkForAssistant(entries, 1, transcriptTailComplete: true),
          isTrue,
        );
      },
    );

    test('does not expose a progress update before the final reply', () {
      final entries = <ChatEntry>[
        UserChatEntry('first'),
        ServerChatEntry(_assistant('tool-preface')),
        ServerChatEntry(_toolResult('tool')),
        ServerChatEntry(_assistant('final-reply')),
      ];

      expect(
        shouldShowForkForAssistant(entries, 1, transcriptTailComplete: true),
        isFalse,
      );
      expect(
        shouldShowForkForAssistant(entries, 3, transcriptTailComplete: true),
        isTrue,
      );
    });

    test('shows one fork action for each completed user turn', () {
      final firstReply = _assistant('first-reply');
      final intermediate = _assistant('tool-preface');
      final secondReply = _assistant('second-reply');
      final entries = <ChatEntry>[
        UserChatEntry('first'),
        ServerChatEntry(firstReply),
        ServerChatEntry(_result()),
        UserChatEntry('second'),
        ServerChatEntry(intermediate),
        ServerChatEntry(_toolResult('tool')),
        ServerChatEntry(secondReply),
        ServerChatEntry(_result()),
      ];

      expect(shouldShowForkForAssistant(entries, 1), isTrue);
      expect(shouldShowForkForAssistant(entries, 4), isFalse);
      expect(shouldShowForkForAssistant(entries, 6), isTrue);
    });

    test('does not expose fork for assistant blocks without visible text', () {
      final entries = <ChatEntry>[
        UserChatEntry('first'),
        ServerChatEntry(_toolOnlyAssistant('tool-only')),
        ServerChatEntry(_result()),
      ];

      expect(shouldShowForkForAssistant(entries, 1), isFalse);
    });
  });
}

AssistantServerMessage _assistant(String id) => AssistantServerMessage(
  message: AssistantMessage(
    id: id,
    role: 'assistant',
    content: [TextContent(text: id)],
    model: 'codex',
  ),
);

AssistantServerMessage _toolOnlyAssistant(String id) => AssistantServerMessage(
  message: AssistantMessage(
    id: id,
    role: 'assistant',
    content: [
      ToolUseContent(id: id, name: 'Read', input: const {'path': 'a.txt'}),
    ],
    model: 'codex',
  ),
);

ToolResultMessage _toolResult(String id) =>
    ToolResultMessage(toolUseId: id, content: 'ok');

ResultMessage _result() => const ResultMessage(subtype: 'success');
