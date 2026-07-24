import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/utils/history_window_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps the latest five root turns with ordinary output', () {
    final messages = <ServerMessage>[
      for (var index = 0; index < 10; index++) ...[
        UserInputMessage(text: 'question $index'),
        _assistant('update $index'),
        const ResultMessage(subtype: 'success'),
      ],
    ];

    final selected = selectTurnAwareServerMessageWindow(messages);

    expect(selected, hasLength(15));
    expect(
      selected.first,
      isA<UserInputMessage>().having(
        (message) => message.text,
        'text',
        'question 5',
      ),
    );
  });

  test('counts matching tool use and result as one recent call', () {
    final messages = <ServerMessage>[
      const UserInputMessage(text: 'inspect'),
      for (var index = 0; index < 205; index++) ...[
        _toolUse('tool-$index'),
        ToolResultMessage(toolUseId: 'tool-$index', content: 'result $index'),
      ],
      _assistant('final answer'),
    ];

    final selected = selectTurnAwareServerMessageWindow(messages);

    expect(selected, hasLength(402));
    expect(
      selected.whereType<ToolResultMessage>().any(
        (message) => message.toolUseId == 'tool-0',
      ),
      isFalse,
    );
    expect(
      selected.whereType<ToolResultMessage>().any(
        (message) => message.toolUseId == 'tool-204',
      ),
      isTrue,
    );
  });

  test('retains a visible assistant envelope even with zero tool budget', () {
    final selected = selectTurnAwareServerMessageWindow([
      const UserInputMessage(text: 'inspect'),
      AssistantServerMessage(
        message: const AssistantMessage(
          id: 'visible-tool',
          role: 'assistant',
          model: 'codex',
          content: [
            TextContent(text: 'I am checking the file.'),
            ToolUseContent(
              id: 'only-tool',
              name: 'Read',
              input: {'file_path': 'a.txt'},
            ),
          ],
        ),
      ),
    ], toolCalls: 0);

    expect(selected, hasLength(2));
  });
}

AssistantServerMessage _assistant(String text) => AssistantServerMessage(
  message: AssistantMessage(
    id: 'assistant-$text',
    role: 'assistant',
    model: 'codex',
    content: [TextContent(text: text)],
  ),
);

AssistantServerMessage _toolUse(String id) => AssistantServerMessage(
  message: AssistantMessage(
    id: 'assistant-$id',
    role: 'assistant',
    model: 'codex',
    content: [
      ToolUseContent(id: id, name: 'Read', input: {'file_path': '$id.txt'}),
    ],
  ),
);
