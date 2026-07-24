import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/assistant_bubble.dart';
import 'package:ccpocket/widgets/bubbles/inline_edit_diff.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    theme: AppTheme.darkTheme,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  group('ToolUseTile - collapsed state', () {
    testWidgets('shows inline row with icon, name, summary, chevron', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ToolUseTile(
            name: 'Read',
            input: {'file_path': 'lib/main.dart'},
          ),
        ),
      );

      // Tool name
      expect(find.text('Read file'), findsOneWidget);
      // Input summary: file name only (category=read extracts basename)
      expect(find.text('main.dart'), findsOneWidget);
      // Chevron right (collapsed)
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      // No expand icons
      expect(find.byIcon(Icons.expand_less), findsNothing);

      // Category icon (12px) instead of colored dot
      final iconFinder = find.byWidgetPredicate((w) {
        if (w is Icon && w.size == 12) {
          return true;
        }
        return false;
      });
      expect(iconFinder, findsOneWidget);

      // No card background (no Container with borderRadius + color)
      final cardFinder = find.byWidgetPredicate((w) {
        if (w is Container && w.decoration is BoxDecoration) {
          final deco = w.decoration as BoxDecoration;
          return deco.borderRadius != null && deco.color != null;
        }
        return false;
      });
      expect(cardFinder, findsNothing);
    });

    testWidgets('hides Bash command until the disclosure is opened', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ToolUseTile(
            name: 'Bash',
            input: {'command': 'ls -la /project'},
          ),
        ),
      );

      expect(find.text('Run command'), findsOneWidget);
      expect(find.text('ls -la /project'), findsNothing);

      await tester.tap(find.byType(InkWell).first);
      await tester.pump();
      expect(find.text('ls -la /project'), findsOneWidget);
    });

    testWidgets('does not build a long command while collapsed', (
      tester,
    ) async {
      final command = 'a' * 100;
      await tester.pumpWidget(
        _wrap(ToolUseTile(name: 'Bash', input: {'command': command})),
      );

      expect(find.textContaining('aaa'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('does not expose arbitrary structured keys while collapsed', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ToolUseTile(
            name: 'Custom',
            input: {'foo': 'bar', 'baz': 'qux'},
          ),
        ),
      );

      expect(find.text('foo, baz'), findsNothing);
    });
  });

  group('ToolUseTile - ImageGeneration', () {
    testWidgets('keeps the prompt lazy behind the standard disclosure', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ToolUseTile(
            name: 'ImageGeneration',
            input: {
              'status': 'in_progress',
              'revisedPrompt': 'A cover image for a mobile agent app',
            },
          ),
        ),
      );

      expect(find.text('Generate image'), findsOneWidget);
      expect(find.text('in progress'), findsOneWidget);
      expect(find.text('A cover image for a mobile agent app'), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNothing);
      expect(find.byIcon(Icons.expand_less), findsNothing);

      await tester.tap(find.byType(InkWell).first);
      await tester.pump();
      expect(
        find.textContaining('A cover image for a mobile agent app'),
        findsOneWidget,
      );
    });

    testWidgets(
      'can hide completed image generation from an assistant bubble',
      (tester) async {
        const toolUseId = 'generated-image-1';
        await tester.pumpWidget(
          _wrap(
            const AssistantBubble(
              hiddenToolUseIds: {toolUseId},
              message: AssistantServerMessage(
                message: AssistantMessage(
                  id: 'assistant-image-generation',
                  role: 'assistant',
                  content: [
                    TextContent(text: 'Here are the generated options.'),
                    ToolUseContent(
                      id: toolUseId,
                      name: 'ImageGeneration',
                      input: {
                        'status': 'in_progress',
                        'revisedPrompt': 'Hidden generation prompt',
                      },
                    ),
                  ],
                  model: 'gpt-5.6',
                ),
              ),
            ),
          ),
        );

        expect(find.text('Here are the generated options.'), findsOneWidget);
        expect(find.text('Generating image'), findsNothing);
        expect(find.text('Hidden generation prompt'), findsNothing);
      },
    );
  });

  group('ToolUseTile - disclosure and explicit show-more', () {
    testWidgets(
      'header toggles preview while show-more alone opens full Bash input',
      (tester) async {
        final longCmd = List.generate(
          8,
          (index) => 'echo "private command line $index"',
        ).join('\n');

        await tester.pumpWidget(
          _wrap(ToolUseTile(name: 'Bash', input: {'command': longCmd})),
        );

        // --- collapsed ---
        expect(find.byIcon(Icons.chevron_right), findsOneWidget);

        // Tap → preview
        await tester.tap(find.byType(InkWell).first);
        await tester.pumpAndSettle();

        // Preview details are created only after opening.
        expect(find.byIcon(Icons.expand_less), findsOneWidget);
        expect(find.byIcon(Icons.chevron_right), findsNothing);
        expect(find.textContaining('private command line 0'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('tool_use_show_more')),
          findsOneWidget,
        );
        expect(find.byType(SelectableText), findsNothing);

        // Card background should exist
        final cardFinder = find.byWidgetPredicate((w) {
          if (w is Container && w.decoration is BoxDecoration) {
            final deco = w.decoration as BoxDecoration;
            return deco.borderRadius != null &&
                deco.color != null &&
                deco.border != null;
          }
          return false;
        });
        expect(cardFinder, findsOneWidget);

        // A second header tap collapses immediately; it does not open full text.
        await tester.tap(find.byKey(const ValueKey('tool_use_disclosure')));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.chevron_right), findsOneWidget);
        expect(find.textContaining('private command line 0'), findsNothing);

        // Reopen the preview, then use the dedicated show-more control.
        await tester.tap(find.byType(InkWell).first);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('tool_use_show_more')));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.expand_less), findsOneWidget);
        expect(find.byType(SelectableText), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('tool_use_disclosure')));
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.chevron_right), findsOneWidget);
        expect(find.byIcon(Icons.expand_less), findsNothing);
        expect(find.byIcon(Icons.expand_more), findsNothing);
      },
    );

    testWidgets('preview shows "... N more lines" for multiline commands', (
      tester,
    ) async {
      // Create a command with more than 5 lines
      final lines = List.generate(10, (i) => 'echo "line $i"');
      final longCmd = lines.join('\n');

      await tester.pumpWidget(
        _wrap(ToolUseTile(name: 'Bash', input: {'command': longCmd})),
      );

      // Tap → preview
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('tool_use_show_more')), findsOneWidget);
    });

    testWidgets('short command in preview shows no "more lines" indicator', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const ToolUseTile(name: 'Bash', input: {'command': 'ls -la'})),
      );

      // Tap → preview
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('tool_use_show_more')), findsNothing);
    });

    testWidgets('Read tool also uses 3-state expansion', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const ToolUseTile(
            name: 'Read',
            input: {
              'file_path':
                  '/Users/project/apps/mobile/lib/widgets/bubbles/assistant_bubble.dart',
            },
          ),
        ),
      );

      // collapsed
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      // Tap → preview (shows full path)
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.expand_less), findsOneWidget);
      expect(find.textContaining('assistant_bubble.dart'), findsWidgets);

      // A second header tap collapses.
      await tester.tap(find.byKey(const ValueKey('tool_use_disclosure')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });
  });

  group('ToolUseTile - edit details are lazy', () {
    testWidgets('Edit defaults collapsed and builds diff after opening', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ToolUseTile(
            name: 'Edit',
            input: {
              'file_path': 'lib/main.dart',
              'old_string': 'hello',
              'new_string': 'world',
            },
          ),
        ),
      );

      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.byType(InlineEditDiff), findsNothing);

      // First tap builds the diff.
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.expand_less), findsOneWidget);
      expect(find.byType(InlineEditDiff), findsOneWidget);

      // Header arrow toggles directly back to collapsed.
      await tester.tap(find.byKey(const ValueKey('tool_use_disclosure')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.byType(InlineEditDiff), findsNothing);
    });

    testWidgets('collapse notifier closes an open tool invocation', (
      tester,
    ) async {
      final notifier = ValueNotifier<int>(0);
      await tester.pumpWidget(
        _wrap(
          ToolUseTile(
            name: 'Bash',
            input: const {'command': 'secret command'},
            collapseNotifier: notifier,
          ),
        ),
      );
      await tester.tap(find.byType(InkWell).first);
      await tester.pump();
      expect(find.text('secret command'), findsOneWidget);

      notifier.value++;
      await tester.pump();
      expect(find.text('secret command'), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });
  });

  group('ToolUseTile - long press copy', () {
    testWidgets('long press copies content to clipboard', (tester) async {
      String? clipboardContent;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            final args = methodCall.arguments as Map;
            clipboardContent = args['text'] as String?;
          }
          return null;
        },
      );

      await tester.pumpWidget(
        _wrap(
          const ToolUseTile(name: 'Bash', input: {'command': 'echo hello'}),
        ),
      );

      await tester.longPress(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(clipboardContent, contains('Bash'));
      expect(clipboardContent, contains('"command"'));
      expect(clipboardContent, contains('echo hello'));
      expect(find.text('Copied'), findsOneWidget);
    });
  });
}
