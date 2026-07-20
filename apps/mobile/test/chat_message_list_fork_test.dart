import 'package:ccpocket/features/chat_session/widgets/chat_message_list.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldShowForkForAssistant', () {
    test('keeps an earlier text reply forkable while a newer reply runs', () {
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

      expect(shouldShowForkForAssistant(entries, 1), isTrue);
      expect(shouldShowForkForAssistant(entries, 3), isTrue);
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
    });

    test('only exposes a result-less transcript tail when the turn is idle', () {
      final entries = <ChatEntry>[
        UserChatEntry('first'),
        ServerChatEntry(_assistant('a1')),
      ];

      expect(shouldShowForkForAssistant(entries, 1), isFalse);
      expect(
        shouldShowForkForAssistant(
          entries,
          1,
          transcriptTailComplete: true,
        ),
        isTrue,
      );
    });

    test('keeps a prior visible assistant block forkable', () {
      final entries = <ChatEntry>[
        UserChatEntry('first'),
        ServerChatEntry(_assistant('tool-preface')),
        ServerChatEntry(_toolResult('tool')),
        ServerChatEntry(_assistant('final-reply')),
      ];

      expect(
        shouldShowForkForAssistant(
          entries,
          1,
          transcriptTailComplete: true,
        ),
        isTrue,
      );
      expect(
        shouldShowForkForAssistant(
          entries,
          3,
          transcriptTailComplete: true,
        ),
        isTrue,
      );
    });

    test('shows one fork action under every completed assistant reply', () {
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
      expect(shouldShowForkForAssistant(entries, 4), isTrue);
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
