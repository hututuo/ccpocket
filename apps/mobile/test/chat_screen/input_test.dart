import 'package:ccpocket/features/chat_session/widgets/chat_input_with_overlays.dart';
import 'package:ccpocket/features/session_list/pending_session_binding.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol_finders/patrol_finders.dart';

import 'helpers/chat_test_helpers.dart';

void main() {
  late MockBridgeService bridge;

  setUp(() {
    bridge = MockBridgeService();
  });

  tearDown(() {
    bridge.dispose();
  });

  group('Chat input', () {
    patrolWidgetTest('H1: Idle shows input field', ($) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.idle),
      ]);
      await pumpN($.tester);

      expect($(#message_input), findsOneWidget);
      expect($(#send_button), findsOneWidget);
    });

    patrolWidgetTest('H2: Send message sends to bridge', ($) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.idle),
      ]);
      await pumpN($.tester);

      await $.tester.enterText(
        find.byKey(const ValueKey('message_input')),
        'Hello Claude',
      );
      await pumpN($.tester);

      await $(#send_button).tap();
      await pumpN($.tester);

      final msg = findSentMessage(bridge, 'input');
      expect(msg, isNotNull);
      expect(msg!['text'], 'Hello Claude');

      // Verify the TextField is cleared
      final textField = $.tester.widget<TextField>(
        find.byKey(const ValueKey('message_input')),
      );
      expect(textField.controller?.text, isEmpty);
    });

    patrolWidgetTest(
      'H2b: durable preview queues first input and sends after runtime binds',
      ($) async {
        final binding = PendingSessionBinding(
          kind: PendingSessionRequestKind.resume,
          requestId: 'claude-resume',
          provider: 'claude',
          projectPath: '/tmp/project',
          providerSessionId: 'durable-thread',
          allowLegacyFallback: false,
        );
        addTearDown(binding.dispose);
        await $.pumpWidget(
          await buildTestClaudeSessionScreen(
            bridge: bridge,
            sessionId: 'pending-runtime',
            isPending: true,
            durableProviderSessionId: 'durable-thread',
            pendingSessionCreated: binding,
          ),
        );
        await pumpN($.tester);

        expect($(#message_input), findsOneWidget);
        await $.tester.enterText(
          find.byKey(const ValueKey('message_input')),
          'Send after attaching',
        );
        await pumpN($.tester);
        await $(#send_button).tap();
        await pumpN($.tester);

        expect(findSentMessage(bridge, 'input'), isNull);
        expect(find.text('Send after attaching'), findsOneWidget);

        binding.value = const SystemMessage(
          subtype: 'session_created',
          sessionId: 'live-runtime',
          projectPath: '/tmp/project',
        );
        await pumpN($.tester);

        final input = findSentMessage(bridge, 'input');
        expect(input, isNotNull);
        expect(input!['sessionId'], 'live-runtime');
        expect(input['text'], 'Send after attaching');
      },
    );

    patrolWidgetTest(
      'H2c: durable Codex preview sends the queued input to the bound runtime',
      ($) async {
        final binding = PendingSessionBinding(
          kind: PendingSessionRequestKind.resume,
          requestId: 'codex-resume',
          provider: 'codex',
          projectPath: '/tmp/project',
          providerSessionId: 'durable-codex-thread',
          allowLegacyFallback: false,
        );
        addTearDown(binding.dispose);
        await $.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-codex-runtime',
            isPending: true,
            durableProviderSessionId: 'durable-codex-thread',
            pendingSessionCreated: binding,
          ),
        );
        await pumpN($.tester);

        await $.tester.enterText(
          find.byKey(const ValueKey('message_input')),
          'Continue the Codex task',
        );
        await pumpN($.tester);
        await $(#send_button).tap();
        await pumpN($.tester);
        expect(findSentMessage(bridge, 'input'), isNull);

        binding.value = const SystemMessage(
          subtype: 'session_created',
          sessionId: 'live-codex-runtime',
          provider: 'codex',
          projectPath: '/tmp/project',
        );
        await pumpN($.tester);

        final input = findSentMessage(bridge, 'input');
        expect(input, isNotNull);
        expect(input!['sessionId'], 'live-codex-runtime');
        expect(input['text'], 'Continue the Codex task');
        await $.tester.pump(const Duration(milliseconds: 700));
      },
    );

    patrolWidgetTest('H3: Running shows stop button', ($) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.running),
      ]);
      await pumpN($.tester);

      expect($(#stop_button), findsOneWidget);
    });

    patrolWidgetTest('H4: Empty text does not send', ($) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.idle),
      ]);
      await pumpN($.tester);

      await $(#send_button).tap();
      await pumpN($.tester);

      final msg = findSentMessage(bridge, 'input');
      expect(msg, isNull);
    });

    patrolWidgetTest('H5: WaitingApproval hides input area', ($) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        makeAssistantMessage(
          'a1',
          'Running command.',
          toolUses: [
            const ToolUseContent(
              id: 'tool-1',
              name: 'Bash',
              input: {'command': 'ls'},
            ),
          ],
        ),
        const PermissionRequestMessage(
          toolUseId: 'tool-1',
          toolName: 'Bash',
          input: {'command': 'ls'},
        ),
        const StatusMessage(status: ProcessStatus.waitingApproval),
      ]);
      await pumpN($.tester);

      expect($(ChatInputWithOverlays), findsNothing);
    });

    patrolWidgetTest(
      'H6: Arrow keys navigate file completion and Tab selects',
      ($) async {
        await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
        await pumpN($.tester);

        await emitAndPump($.tester, bridge, [
          const StatusMessage(status: ProcessStatus.idle),
        ]);
        bridge.emitFileList(['a.dart', 'bb.dart', 'ccc.dart']);
        await pumpN($.tester);

        await $.tester.enterText(
          find.byKey(const ValueKey('message_input')),
          '@',
        );
        await pumpN($.tester);

        expect(find.text('a.dart'), findsOneWidget);
        expect(find.text('bb.dart'), findsOneWidget);

        await $.tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
        await $.tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
        await $.tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
        await $.tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
        await pumpN($.tester);

        final textField = $.tester.widget<TextField>(
          find.byKey(const ValueKey('message_input')),
        );
        expect(textField.controller?.text, '@bb.dart ');
      },
    );

    patrolWidgetTest('H7: Ctrl+N/P navigate file completion and Tab selects', (
      $,
    ) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.idle),
      ]);
      bridge.emitFileList(['a.dart', 'bb.dart', 'ccc.dart']);
      await pumpN($.tester);

      await $.tester.enterText(
        find.byKey(const ValueKey('message_input')),
        '@',
      );
      await pumpN($.tester);

      await $.tester.sendKeyDownEvent(
        LogicalKeyboardKey.keyN,
        character: '\u000e',
      );
      await $.tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
      await $.tester.sendKeyDownEvent(
        LogicalKeyboardKey.keyN,
        character: '\u000e',
      );
      await $.tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
      await $.tester.sendKeyDownEvent(
        LogicalKeyboardKey.keyP,
        character: '\u0010',
      );
      await $.tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
      await $.tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await $.tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await pumpN($.tester);

      final textField = $.tester.widget<TextField>(
        find.byKey(const ValueKey('message_input')),
      );
      expect(textField.controller?.text, '@bb.dart ');
    });

    patrolWidgetTest('H8: Ctrl+A/E jump to first and last file completions', (
      $,
    ) async {
      await $.pumpWidget(await buildTestChatScreen(bridge: bridge));
      await pumpN($.tester);

      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.idle),
      ]);
      bridge.emitFileList(['a.dart', 'bb.dart', 'ccc.dart']);
      await pumpN($.tester);

      await $.tester.enterText(
        find.byKey(const ValueKey('message_input')),
        '@',
      );
      await pumpN($.tester);

      await $.tester.sendKeyDownEvent(
        LogicalKeyboardKey.keyE,
        character: '\u0005',
      );
      await $.tester.sendKeyUpEvent(LogicalKeyboardKey.keyE);
      await $.tester.sendKeyDownEvent(
        LogicalKeyboardKey.keyA,
        character: '\u0001',
      );
      await $.tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await $.tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await $.tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await pumpN($.tester);

      var textField = $.tester.widget<TextField>(
        find.byKey(const ValueKey('message_input')),
      );
      expect(textField.controller?.text, '@a.dart ');

      await $.tester.enterText(
        find.byKey(const ValueKey('message_input')),
        '@',
      );
      await pumpN($.tester);

      await $.tester.sendKeyDownEvent(
        LogicalKeyboardKey.keyE,
        character: '\u0005',
      );
      await $.tester.sendKeyUpEvent(LogicalKeyboardKey.keyE);
      await $.tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await $.tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await pumpN($.tester);

      textField = $.tester.widget<TextField>(
        find.byKey(const ValueKey('message_input')),
      );
      expect(textField.controller?.text, '@ccc.dart ');
    });

    patrolWidgetTest(
      'H9: Active dollar query refreshes when skills become available',
      ($) async {
        await $.pumpWidget(await buildTestCodexSessionScreen(bridge: bridge));
        await pumpN($.tester);

        await emitAndPump($.tester, bridge, [
          const StatusMessage(status: ProcessStatus.idle),
        ]);
        await $.tester.enterText(
          find.byKey(const ValueKey('message_input')),
          r'$',
        );
        await pumpN($.tester);
        expect(find.text(r'$skill-creator'), findsNothing);

        bridge.emitMessage(
          const SystemMessage(
            subtype: 'supported_commands',
            provider: 'codex',
            skills: ['skill-creator'],
            skillMetadata: [
              CodexSkillMetadata(
                name: 'skill-creator',
                path: '/tmp/skill-creator/SKILL.md',
                description: 'Create a skill',
              ),
            ],
          ),
          sessionId: testSessionId,
        );
        await $.tester.pumpAndSettle();

        expect(find.text(r'$skill-creator'), findsOneWidget);
      },
    );
  });
}
