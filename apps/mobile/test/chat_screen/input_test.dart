import 'package:ccpocket/features/chat_session/widgets/chat_input_with_overlays.dart';
import 'package:ccpocket/features/chat_session/widgets/durable_session_preview.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/session_list/pending_session_binding.dart';
import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol_finders/patrol_finders.dart';

import 'helpers/chat_test_helpers.dart';

Finder durableCodexPreview(String providerSessionId) {
  final prefix = 'durable-codex-$providerSessionId-';
  return find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> && key.value.startsWith(prefix);
  });
}

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
        var attachmentRequests = 0;
        final binding = PendingSessionBinding(
          kind: PendingSessionRequestKind.resume,
          requestId: 'claude-resume',
          provider: 'claude',
          projectPath: '/tmp/project',
          providerSessionId: 'durable-thread',
          allowLegacyFallback: false,
          onAttachmentRequested: () async {
            attachmentRequests += 1;
          },
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
        expect(find.byType(DurableSessionBindingBanner), findsNothing);
        await $.tester.enterText(
          find.byKey(const ValueKey('message_input')),
          'Send after attaching',
        );
        await pumpN($.tester);
        await $(#send_button).tap();
        await pumpN($.tester);

        expect(findSentMessage(bridge, 'input'), isNull);
        expect(find.text('Send after attaching'), findsOneWidget);
        expect(find.textContaining('Queued locally'), findsNothing);
        expect(attachmentRequests, 1);
        expect(find.byType(DurableSessionBindingBanner), findsOneWidget);

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
        expect(find.byType(DurableSessionBindingBanner), findsNothing);
      },
    );

    patrolWidgetTest(
      'H2c: durable Codex preview sends the queued input to the bound runtime',
      ($) async {
        bridge.advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
        };
        var attachmentRequests = 0;
        final binding = PendingSessionBinding(
          kind: PendingSessionRequestKind.resume,
          requestId: 'codex-resume',
          provider: 'codex',
          projectPath: '/tmp/project',
          providerSessionId: 'durable-codex-thread',
          allowLegacyFallback: false,
          onAttachmentRequested: () async {
            attachmentRequests += 1;
          },
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

        expect(find.byType(DurableSessionBindingBanner), findsNothing);
        final durableElementBefore = $.tester.element(
          durableCodexPreview('durable-codex-thread'),
        );
        await $.tester.enterText(
          find.byKey(const ValueKey('message_input')),
          'Continue the Codex task',
        );
        await pumpN($.tester);
        await $(#send_button).tap();
        await pumpN($.tester);
        expect(findSentMessage(bridge, 'input'), isNull);
        expect(find.textContaining('Queued locally'), findsNothing);
        expect(attachmentRequests, 1);
        expect(find.byType(DurableSessionBindingBanner), findsOneWidget);

        binding.value = const SystemMessage(
          subtype: 'session_created',
          sessionId: 'live-codex-runtime',
          provider: 'codex',
          projectPath: '/tmp/project',
        );
        await pumpN($.tester);

        expect(
          findSentMessage(bridge, 'input'),
          isNull,
          reason: 'session_created alone does not prove writer authority',
        );
        expect(find.byType(DurableSessionBindingBanner), findsOneWidget);
        final attachedCubit = BlocProvider.of<ChatSessionCubit>(
          $.tester.element(find.byKey(const ValueKey('message_input'))),
        );
        attachedCubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-codex-thread',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T05:00:00.000Z',
            executionHost: 'unknown',
            controlState: 'writable',
            authorityGeneration: 'authority-after-create',
          ),
          sourceFingerprint: 'bridge-test/source-test',
        );
        await pumpN($.tester);

        final inputs = findAllSentMessages(bridge, 'input');
        expect(inputs, hasLength(1));
        final input = inputs.single;
        expect(input, isNotNull);
        expect(input['sessionId'], 'live-codex-runtime');
        expect(input['text'], 'Continue the Codex task');
        expect(find.byType(DurableSessionBindingBanner), findsNothing);
        expect(durableCodexPreview('durable-codex-thread'), findsOneWidget);
        expect(
          $.tester.element(durableCodexPreview('durable-codex-thread')),
          same(durableElementBefore),
        );
        expect(
          attachedCubit.detachedLiveRuntimeSessionId,
          'live-codex-runtime',
        );
        await pumpN($.tester);
        expect(findAllSentMessages(bridge, 'input'), hasLength(1));
        expect(
          attachedCubit.runtimeSessionIdForMutation(allowSteerable: false),
          'live-codex-runtime',
        );

        bridge.sentMessages.clear();
        await $.tester.enterText(
          find.byKey(const ValueKey('message_input')),
          '/compact',
        );
        await pumpN($.tester);
        await $(#send_button).tap();
        await pumpN($.tester);
        final compact = findSentMessage(bridge, 'codex_compact_request');
        expect(compact, isNotNull);
        expect(compact!['sessionId'], 'live-codex-runtime');
        await $.tester.pump(const Duration(milliseconds: 700));
      },
    );

    patrolWidgetTest(
      'H2c2: same-project session_created cannot claim another Codex preview',
      ($) async {
        final notifier = ValueNotifier<SystemMessage?>(null);
        addTearDown(notifier.dispose);
        await $.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-codex-a',
            projectPath: '/tmp/shared-project',
            isPending: true,
            durableProviderSessionId: 'durable-codex-a',
            pendingSessionCreated: notifier,
          ),
        );
        await pumpN($.tester);

        expect(durableCodexPreview('durable-codex-a'), findsOneWidget);
        bridge.emitMessage(
          const SystemMessage(
            subtype: 'session_created',
            sessionId: 'runtime-for-thread-b',
            provider: 'codex',
            projectPath: '/tmp/shared-project',
            sourceSessionId: 'durable-codex-b',
            resumeRequestId: 'resume-b',
          ),
        );
        await pumpN($.tester);

        expect(durableCodexPreview('durable-codex-a'), findsOneWidget);
        expect(bridge.lastRequestedSessionId, isNot('runtime-for-thread-b'));
      },
    );

    patrolWidgetTest(
      'H2c4: a stopped durable runtime reattaches once before sending',
      ($) async {
        bridge.emitRecentSessions(const [
          RecentSession(
            sessionId: 'durable-stopped-thread',
            provider: 'codex',
            firstPrompt: 'Durable stopped thread',
            created: '2026-08-01T00:00:00.000Z',
            modified: '2026-08-01T00:01:00.000Z',
            gitBranch: 'main',
            projectPath: '/tmp/stopped-project',
            isSidechain: false,
          ),
        ]);
        await $.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'runtime-before-stop',
            projectPath: '/tmp/stopped-project',
            durableProviderSessionId: 'durable-stopped-thread',
          ),
        );
        await pumpN($.tester);

        bridge.emitStoppedSession('runtime-before-stop');
        await pumpN($.tester);
        final stoppedCubit = BlocProvider.of<ChatSessionCubit>(
          $.tester.element(find.byKey(const ValueKey('message_input'))),
        );
        expect(stoppedCubit.detachedLiveRuntimeSessionId, isNull);
        expect(stoppedCubit.state.status, ProcessStatus.unknown);
        await $.tester.enterText(
          find.byKey(const ValueKey('message_input')),
          'Continue after runtime replacement',
        );
        await pumpN($.tester);
        await $(#send_button).tap();
        await pumpN($.tester);
        expect(find.byType(DurableSessionBindingBanner), findsOneWidget);

        final resumeMessages = findAllSentMessages(bridge, 'resume_session');
        expect(
          resumeMessages,
          hasLength(1),
          reason:
              'sent types: ${bridge.sentMessages.map((message) => message.type)}',
        );
        expect(resumeMessages.single['sessionId'], 'durable-stopped-thread');
        expect(findSentMessage(bridge, 'input'), isNull);
        final resumeRequestId =
            resumeMessages.single['resumeRequestId'] as String;

        bridge.emitMessage(
          SystemMessage(
            subtype: 'session_created',
            sessionId: 'runtime-after-stop',
            claudeSessionId: 'durable-stopped-thread',
            sourceSessionId: 'durable-stopped-thread',
            resumeRequestId: resumeRequestId,
            provider: 'codex',
            projectPath: '/tmp/stopped-project',
          ),
        );
        await pumpN($.tester);

        final input = findSentMessage(bridge, 'input');
        expect(input, isNotNull);
        expect(input!['sessionId'], 'runtime-after-stop');
        expect(input['sessionId'], isNot('runtime-before-stop'));
        expect(input['text'], 'Continue after runtime replacement');
        expect(findAllSentMessages(bridge, 'resume_session'), hasLength(1));
      },
    );

    patrolWidgetTest(
      'H2c5: a source A page cannot reattach the same thread id on source B',
      ($) async {
        bridge
          ..authenticatedBridgeInstanceId = 'shared-bridge'
          ..authenticatedCodexSourceId = 'codex-source-b';
        bridge.emitRecentSessions(const [
          RecentSession(
            sessionId: 'same-durable-thread',
            provider: 'codex',
            firstPrompt: 'Source B thread with the same id',
            created: '2026-08-01T00:00:00.000Z',
            modified: '2026-08-01T00:01:00.000Z',
            gitBranch: 'main',
            projectPath: '/tmp/source-b-project',
            isSidechain: false,
          ),
        ]);
        await $.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'runtime-source-a-before-stop',
            projectPath: '/tmp/source-a-project',
            durableProviderSessionId: 'same-durable-thread',
            dataSourceIdentity: const BridgeDataSourceIdentity(
              bridgeInstanceId: 'shared-bridge',
              codexSourceId: 'codex-source-a',
            ),
          ),
        );
        await pumpN($.tester);

        bridge.emitStoppedSession('runtime-source-a-before-stop');
        await pumpN($.tester);
        await $.tester.enterText(
          find.byKey(const ValueKey('message_input')),
          'Must not attach source B',
        );
        await pumpN($.tester);
        await $(#send_button).tap();
        await pumpN($.tester);

        expect(findAllSentMessages(bridge, 'resume_session'), isEmpty);
        expect(findSentMessage(bridge, 'input'), isNull);
        expect(find.byType(DurableSessionBindingBanner), findsNothing);
      },
    );

    patrolWidgetTest(
      'H2c3: same-project session_created cannot claim another Claude preview',
      ($) async {
        final notifier = ValueNotifier<SystemMessage?>(null);
        addTearDown(notifier.dispose);
        await $.pumpWidget(
          await buildTestClaudeSessionScreen(
            bridge: bridge,
            sessionId: 'pending-claude-a',
            projectPath: '/tmp/shared-project',
            isPending: true,
            durableProviderSessionId: 'durable-claude-a',
            pendingSessionCreated: notifier,
          ),
        );
        await pumpN($.tester);

        expect(
          find.byKey(const ValueKey('durable-claude-durable-claude-a')),
          findsOneWidget,
        );
        bridge.emitMessage(
          const SystemMessage(
            subtype: 'session_created',
            sessionId: 'runtime-for-claude-thread-b',
            provider: 'claude',
            projectPath: '/tmp/shared-project',
            sourceSessionId: 'durable-claude-b',
            resumeRequestId: 'resume-claude-b',
          ),
        );
        await pumpN($.tester);

        expect(
          find.byKey(const ValueKey('durable-claude-durable-claude-a')),
          findsOneWidget,
        );
        expect(
          bridge.lastRequestedSessionId,
          isNot('runtime-for-claude-thread-b'),
        );
      },
    );

    patrolWidgetTest('H2d: Codex compact command sends the direct request', (
      $,
    ) async {
      await $.pumpWidget(await buildTestCodexSessionScreen(bridge: bridge));
      await pumpN($.tester);
      await emitAndPump($.tester, bridge, [
        const StatusMessage(status: ProcessStatus.idle),
      ]);

      await $.tester.enterText(
        find.byKey(const ValueKey('message_input')),
        '/compact',
      );
      await pumpN($.tester);
      await $(#send_button).tap();
      await pumpN($.tester);

      final compact = findSentMessage(bridge, 'codex_compact_request');
      expect(
        compact,
        isNotNull,
        reason: bridge.sentMessages
            .map(decodeClientMessage)
            .toList()
            .toString(),
      );
      expect(compact!['sessionId'], testSessionId);
      expect(compact['requestId'], isNotEmpty);
      expect(findSentMessage(bridge, 'input'), isNull);
    });

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
