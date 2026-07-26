import 'package:flutter_test/flutter_test.dart';
import 'package:ccpocket/models/messages.dart';
import 'dart:convert';

void main() {
  test('preserves exact Bridge receipt time and approximate source time', () {
    final exact = ServerMessage.fromJson({
      'type': 'assistant',
      'message': {
        'id': 'assistant-exact',
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'exact'},
        ],
        'model': 'test',
      },
      'receivedAt': '2026-07-25T03:04:05.678Z',
      'sourceTimestamp': '2026-07-25T01:02:03.000Z',
    });
    final approximate = ServerMessage.fromJson({
      'type': 'assistant',
      'message': {
        'id': 'assistant-source',
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'source'},
        ],
        'model': 'test',
      },
      'sourceTimestamp': '2026-07-25T01:02:03.000Z',
    });

    expect(
      serverMessageTimestamp(exact),
      isA<ServerMessageTimestamp>()
          .having(
            (value) => value.value,
            'value',
            DateTime.parse('2026-07-25T03:04:05.678Z'),
          )
          .having(
            (value) => value.isBridgeReceived,
            'isBridgeReceived',
            isTrue,
          ),
    );
    expect(
      serverMessageTimestamp(approximate),
      isA<ServerMessageTimestamp>()
          .having(
            (value) => value.value,
            'value',
            DateTime.parse('2026-07-25T01:02:03.000Z'),
          )
          .having(
            (value) => value.isBridgeReceived,
            'isBridgeReceived',
            isFalse,
          ),
    );
  });

  test('serializes persisted Codex fork requests for the session list', () {
    final json = jsonDecode(
      ClientMessage.forkRecentSession(
        threadId: 'thread-1',
        projectPath: '/tmp/project',
      ).toJson(),
    );
    expect(json, {
      'type': 'fork',
      'sessionId': 'thread-1',
      'targetUuid': 'codex:user-turn:latest',
      'projectPath': '/tmp/project',
    });
  });

  test('serializes and parses session link resolution messages', () {
    expect(
      jsonDecode(
        ClientMessage.resolveSessionLink(
          requestId: 'link-1',
          sessionId: 'claude-uuid',
          provider: 'claude',
        ).toJson(),
      ),
      {
        'type': 'resolve_session_link',
        'requestId': 'link-1',
        'sessionId': 'claude-uuid',
        'provider': 'claude',
      },
    );

    final message =
        ServerMessage.fromJson({
              'type': 'session_link_resolution',
              'requestId': 'link-1',
              'sourceSessionId': 'claude-uuid',
              'status': 'recent',
              'provider': 'claude',
              'recentSession': {
                'sessionId': 'claude-uuid',
                'provider': 'claude',
                'projectPath': '/workspace/app',
                'gitBranch': 'main',
                'firstPrompt': 'Continue this task',
                'created': '2026-07-24T00:00:00Z',
                'modified': '2026-07-24T01:00:00Z',
                'isSidechain': false,
              },
            })
            as SessionLinkResolutionMessage;

    expect(message.requestId, 'link-1');
    expect(message.status, SessionLinkResolutionStatus.recent);
    expect(message.recentSession?.sessionId, 'claude-uuid');
    expect(message.recentSession?.projectPath, '/workspace/app');
  });

  test('parses a scoped session-not-found error', () {
    final message =
        ServerMessage.fromJson({
              'type': 'error',
              'message': 'Session missing not found',
              'errorCode': 'session_not_found',
              'sessionId': 'missing',
            })
            as ErrorMessage;

    expect(message.errorCode, 'session_not_found');
    expect(message.sessionId, 'missing');
  });

  test('serializes tool suggestion installation action', () {
    expect(
      jsonDecode(
        ClientMessage.installToolSuggestion(
          'approval-0',
          sessionId: 'session-1',
        ).toJson(),
      ),
      {
        'type': 'install_tool_suggestion',
        'toolUseId': 'approval-0',
        'sessionId': 'session-1',
      },
    );
  });

  test('parses structured tool suggestion state', () {
    final message =
        ServerMessage.fromJson({
              'type': 'permission_request',
              'toolUseId': 'approval-0',
              'toolName': 'ToolSuggestion',
              'input': {
                'toolName': 'GitHub',
                'toolType': 'plugin',
                'suggestReason': 'Inspect forks on GitHub.',
                'installState': 'needs_auth',
                'appsNeedingAuth': [
                  {
                    'id': 'github-app',
                    'name': 'GitHub',
                    'installUrl': 'https://example.com/connect',
                  },
                ],
              },
            })
            as PermissionRequestMessage;

    expect(message.isToolSuggestion, isTrue);
    expect(message.usesAskUserUi, isFalse);
    expect(message.suggestedToolName, 'GitHub');
    expect(message.toolSuggestionInstallState, 'needs_auth');
    expect(message.appsNeedingAuthentication.single.name, 'GitHub');
    expect(
      message.appsNeedingAuthentication.single.installUrl,
      'https://example.com/connect',
    );
  });

  test('parses Codex goal state and serializes goal actions', () {
    final message =
        ServerMessage.fromJson({
              'type': 'goal_state',
              'sessionId': 's1',
              'goalChangeId': 'goal-change-1',
              'goalOperationSequence': 7,
              'goal': {
                'threadId': 'thread-1',
                'objective': 'Ship Goal support',
                'status': 'usageLimited',
                'tokenBudget': 80000,
                'tokensUsed': 12400,
                'timeUsedSeconds': 1080,
                'createdAt': 1,
                'updatedAt': 2,
              },
            })
            as GoalStateMessage;

    expect(message.sessionId, 's1');
    expect(message.goalChangeId, 'goal-change-1');
    expect(message.goalOperationSequence, 7);
    expect(message.goal?.objective, 'Ship Goal support');
    expect(message.goal?.status, CodexThreadGoalStatus.usageLimited);
    expect(message.goal?.tokenBudget, 80000);
    expect(
      jsonDecode(
        ClientMessage.setGoal(
          sessionId: 's1',
          status: CodexThreadGoalStatus.paused,
          tokenBudget: null,
          includeTokenBudget: true,
          goalChangeId: 'goal-change-1',
          expectedGoalOperationSequence: 7,
        ).toJson(),
      ),
      {
        'type': 'set_goal',
        'sessionId': 's1',
        'status': 'paused',
        'tokenBudget': null,
        'goalChangeId': 'goal-change-1',
        'expectedGoalOperationSequence': 7,
      },
    );
    final clear = ClientMessage.clearGoal(
      's1',
      goalChangeId: 'goal-change-2',
      expectedGoalOperationSequence: 8,
    );
    expect(jsonDecode(clear.toJson()), {
      'type': 'clear_goal',
      'sessionId': 's1',
      'goalChangeId': 'goal-change-2',
      'expectedGoalOperationSequence': 8,
    });
    expect(clear.delivery, ClientMessageDelivery.ephemeral);
    expect(
      ClientMessage.getGoal('s1').delivery,
      ClientMessageDelivery.ephemeral,
    );
  });

  test('Codex Goal preserves future statuses without widening the enum', () {
    expect(
      CodexThreadGoalStatus.fromString('waitingForFutureResource'),
      CodexThreadGoalStatus.active,
    );
    final goal = CodexGoal.fromJson({
      'threadId': 'thread-1',
      'objective': 'Wait safely',
      'status': 'waitingForFutureResource',
      'tokenBudget': null,
    });
    expect(goal.status, CodexThreadGoalStatus.active);
    expect(goal.hasUnknownStatus, isTrue);
    expect(goal.effectiveStatus, 'waitingForFutureResource');
  });

  test('Codex Goal operation routing survives errors and session lists', () {
    final error =
        ServerMessage.fromJson({
              'type': 'error',
              'message': 'Goal is temporarily blocked',
              'errorCode': 'permission_restart_in_progress',
              'sessionId': 's1',
              'goalChangeId': 'goal-change-3',
            })
            as ErrorMessage;
    expect(error.sessionId, 's1');
    expect(error.goalChangeId, 'goal-change-3');

    final session = SessionInfo.fromJson({
      'id': 's1',
      'provider': 'codex',
      'projectPath': '/tmp/project',
      'status': 'idle',
      'createdAt': '',
      'lastActivityAt': '',
      'codexGoalControlSupported': true,
    });
    expect(session.codexGoalControlSupported, isTrue);
    expect(
      session
          .copyWith(clearCodexGoalControlSupported: true)
          .codexGoalControlSupported,
      isNull,
    );
  });

  test('parses structured Guardian approval notices', () {
    final message =
        ServerMessage.fromJson({
              'type': 'guardian_approval',
              'risk': 'high',
              'reason': 'The command changes files outside the workspace.',
              'authorization': 'high',
              'reviewId': 'guardian-1',
              'targetItemId': 'command-1',
              'action': {
                'type': 'command',
                'command': 'git clean -fd',
                'cwd': '/workspace',
              },
            })
            as GuardianApprovalMessage;

    expect(message.risk, GuardianApprovalRisk.high);
    expect(message.status, GuardianApprovalStatus.approved);
    expect(message.reason, 'The command changes files outside the workspace.');
    expect(message.authorization, 'high');
    expect(message.reviewId, 'guardian-1');
    expect(message.targetItemId, 'command-1');
    expect(message.action?['command'], 'git clean -fd');
  });

  test('upgrades a compatible Codex warning into a Guardian review notice', () {
    final message =
        ServerMessage.fromJson({
              'type': 'error',
              'errorCode': 'codex_warning',
              'message':
                  'Automatic approval review approved (risk: low, authorization: high): reason',
              'guardianReview': {
                'status': 'approved',
                'risk': 'low',
                'reason': 'The command only reads database metadata.',
                'authorization': 'high',
                'action': {
                  'type': 'command',
                  'command': 'ls -la simulator.db*',
                  'cwd': '/tmp',
                },
              },
            })
            as GuardianApprovalMessage;

    expect(message.risk, GuardianApprovalRisk.low);
    expect(message.reason, 'The command only reads database metadata.');
    expect(message.authorization, 'high');
    expect(message.action?['command'], 'ls -la simulator.db*');
  });

  test('upgrades a legacy auto-review warning without Bridge metadata', () {
    final message =
        ServerMessage.fromJson({
              'type': 'error',
              'errorCode': 'codex_warning',
              'message':
                  'Automatic approval review approved (risk: low, authorization: high):\n'
                  'The command only reads database metadata.',
            })
            as GuardianApprovalMessage;

    expect(message.risk, GuardianApprovalRisk.low);
    expect(message.status, GuardianApprovalStatus.approved);
    expect(message.reason, 'The command only reads database metadata.');
    expect(message.authorization, 'high');
    expect(message.action, isNull);
  });

  test('keeps unrelated Codex warnings as ordinary errors', () {
    final message = ServerMessage.fromJson({
      'type': 'error',
      'errorCode': 'codex_warning',
      'message': 'thread/rollback is deprecated',
    });

    expect(message, isA<ErrorMessage>());
  });

  test('ReasoningEffort preserves model-advertised future values', () {
    final effort = reasoningEffortByValue('future-tier');

    expect(effort?.value, 'future-tier');
    expect(effort?.label, 'Future Tier');
    expect(reasoningEffortByValue('  '), isNull);
  });

  test('ReasoningEffort keeps display labels separate from wire values', () {
    const efforts = [
      ReasoningEffort.low,
      ReasoningEffort.medium,
      ReasoningEffort.high,
      ReasoningEffort.xhigh,
      ReasoningEffort.max,
      ReasoningEffort.ultra,
    ];

    expect(efforts.map((effort) => effort.label), [
      'light',
      'medium',
      'high',
      'x-high',
      'max',
      'ultra',
    ]);
    expect(efforts.map((effort) => effort.value), [
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
      'ultra',
    ]);
  });

  test('Codex speed accepts the app-server priority alias as Fast', () {
    expect(codexSpeedFromRaw('fast'), CodexSpeed.fast);
    expect(codexSpeedFromRaw('priority'), CodexSpeed.fast);
    expect(codexSpeedFromRaw('standard'), CodexSpeed.standard);
  });

  test('running Codex sessions preserve unknown service tiers', () {
    expect(codexRuntimeSpeedFromRaw('standard'), CodexSpeed.standard);
    expect(codexRuntimeSpeedFromRaw('priority'), CodexSpeed.fast);
    expect(codexRuntimeSpeedFromRaw('flex'), CodexSpeed.unknown);
    expect(codexRuntimeSpeedFromRaw(null), isNull);
    // Selectable new-session forms keep their stable fallback contract.
    expect(codexSpeedFromRaw('flex'), CodexSpeed.unknown);
    expect(codexSelectableSpeedFromRaw('flex'), CodexSpeed.standard);
  });

  test('Codex effort display choices serialize canonical wire values', () {
    final cases = <ReasoningEffort, String>{
      ReasoningEffort.low: 'low',
      ReasoningEffort.xhigh: 'xhigh',
      ReasoningEffort.ultra: 'ultra',
    };

    for (final entry in cases.entries) {
      final message = ClientMessage.setCodexModel(
        'gpt-5.6-sol',
        modelReasoningEffort: entry.key.value,
        sessionId: 's1',
      );
      final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
      expect(json['modelReasoningEffort'], entry.value);
    }
  });

  group('pathBasename', () {
    test('handles POSIX and Windows path separators', () {
      expect(pathBasename('/Users/me/project-a'), 'project-a');
      expect(pathBasename(r'C:\Users\me\project-b'), 'project-b');
      expect(pathBasename(r'C:\Users\me\project-b\'), 'project-b');
      expect(pathBasename('project-c'), 'project-c');
      expect(pathBasename(''), '');
    });
  });

  group('Codex permissions mode', () {
    test('derives only complete known presets', () {
      expect(
        codexPermissionsModeFromSettings(
          approvalPolicy: 'on-request',
          sandboxMode: 'workspace-write',
        ),
        CodexPermissionsMode.defaultPermissions,
      );
      expect(
        codexPermissionsModeFromSettings(
          approvalPolicy: 'on-request',
          approvalsReviewer: 'auto_review',
          sandboxMode: 'workspace-write',
        ),
        CodexPermissionsMode.autoReview,
      );
      expect(
        codexPermissionsModeFromSettings(
          approvalPolicy: 'never',
          sandboxMode: 'danger-full-access',
        ),
        CodexPermissionsMode.fullAccess,
      );
    });

    test('classifies read-only, mismatched, and unknown tuples as custom', () {
      expect(
        codexPermissionsModeFromSettings(
          approvalPolicy: 'on-request',
          sandboxMode: 'read-only',
        ),
        CodexPermissionsMode.custom,
      );
      expect(
        codexPermissionsModeFromSettings(
          approvalPolicy: 'never',
          sandboxMode: 'workspace-write',
        ),
        CodexPermissionsMode.custom,
      );
      expect(
        codexPermissionsModeFromSettings(
          codexPermissionsMode: 'future-mode',
          approvalPolicy: 'never',
          sandboxMode: 'danger-full-access',
        ),
        CodexPermissionsMode.custom,
      );
    });

    test(
      'session parsers derive complete settings but not partial metadata',
      () {
        final complete = SessionInfo.fromJson({
          'id': 'complete',
          'provider': 'codex',
          'projectPath': '/tmp/project',
          'status': 'idle',
          'createdAt': '',
          'lastActivityAt': '',
          'codexSettings': {
            'approvalPolicy': 'on-request',
            'sandboxMode': 'read-only',
          },
        });
        final partial = SessionInfo.fromJson({
          'id': 'partial',
          'provider': 'codex',
          'projectPath': '/tmp/project',
          'status': 'idle',
          'createdAt': '',
          'lastActivityAt': '',
          'codexSettings': {'approvalPolicy': 'on-request'},
        });

        expect(complete.codexPermissionsMode, 'custom');
        expect(partial.codexPermissionsMode, isNull);
      },
    );

    test('RecentSession follows the same complete and partial rules', () {
      Map<String, dynamic> recentJson(
        String id,
        Map<String, dynamic> codexSettings,
      ) => {
        'sessionId': id,
        'provider': 'codex',
        'firstPrompt': 'resume',
        'created': '2026-02-13T00:00:00Z',
        'modified': '2026-02-13T00:00:00Z',
        'gitBranch': 'main',
        'projectPath': '/tmp/project',
        'isSidechain': false,
        'codexSettings': codexSettings,
      };

      final complete = RecentSession.fromJson(
        recentJson('complete', {
          'approvalPolicy': 'on-request',
          'approvalsReviewer': 'auto_review',
          'sandboxMode': 'workspace-write',
        }),
      );
      final partial = RecentSession.fromJson(
        recentJson('partial', {'approvalsReviewer': 'auto_review'}),
      );

      expect(complete.codexPermissionsMode, 'autoReview');
      expect(partial.codexPermissionsMode, isNull);
    });
  });

  group('SystemMessage', () {
    test('parses resume request correlation', () {
      final message =
          ServerMessage.fromJson({
                'type': 'system',
                'subtype': 'session_created',
                'sessionId': 'bridge-1',
                'resumeRequestId': 'link-request-1',
              })
              as SystemMessage;

      expect(message.resumeRequestId, 'link-request-1');
    });

    test('parses start request correlation failure', () {
      final message =
          ServerMessage.fromJson({
                'type': 'system',
                'subtype': 'session_start_failed',
                'startRequestId': 'start-request-1',
                'errorMessage': 'profile missing',
              })
              as SystemMessage;

      expect(message.startRequestId, 'start-request-1');
      expect(message.errorMessage, 'profile missing');
    });

    test('parses Codex CLI join target', () {
      final msg = ServerMessage.fromJson({
        'type': 'system',
        'subtype': 'init',
        'provider': 'codex',
        'sessionId': 'thr_123',
        'codexCliJoin': {
          'url': 'ws://127.0.0.1:8767',
          'command': 'codex resume thr_123 --remote ws://127.0.0.1:8767',
        },
      });

      expect(msg, isA<SystemMessage>());
      final system = msg as SystemMessage;
      expect(system.codexCliJoin?.url, 'ws://127.0.0.1:8767');
      expect(
        system.codexCliJoin?.command,
        'codex resume thr_123 --remote ws://127.0.0.1:8767',
      );
      expect(system.codexCliJoin?.isValid, isTrue);
    });
  });

  group('FileContentMessage', () {
    test('parses legacy text file content as text kind', () {
      final msg = ServerMessage.fromJson({
        'type': 'file_content',
        'requestId': 'file-request-1',
        'filePath': 'README.md',
        'content': '# Hello',
        'language': 'markdown',
        'totalLines': 1,
      });

      expect(msg, isA<FileContentMessage>());
      final file = msg as FileContentMessage;
      expect(file.requestId, 'file-request-1');
      expect(file.kind, 'text');
      expect(file.content, '# Hello');
      expect(file.language, 'markdown');
      expect(file.totalLines, 1);
      expect(file.base64, isNull);
    });

    test('parses image file content metadata', () {
      final msg = ServerMessage.fromJson({
        'type': 'file_content',
        'filePath': 'docs/image.png',
        'kind': 'image',
        'content': '',
        'base64': 'aGVsbG8=',
        'mimeType': 'image/png',
        'sizeBytes': 5,
      });

      expect(msg, isA<FileContentMessage>());
      final file = msg as FileContentMessage;
      expect(file.kind, 'image');
      expect(file.content, '');
      expect(file.base64, 'aGVsbG8=');
      expect(file.mimeType, 'image/png');
      expect(file.sizeBytes, 5);
    });
  });

  group('ToolUseSummaryMessage', () {
    test('parses from JSON correctly', () {
      final json = {
        'type': 'tool_use_summary',
        'summary': 'Read 3 files and analyzed code',
        'precedingToolUseIds': ['tu-1', 'tu-2', 'tu-3'],
      };

      final msg = ServerMessage.fromJson(json);

      expect(msg, isA<ToolUseSummaryMessage>());
      final summary = msg as ToolUseSummaryMessage;
      expect(summary.summary, 'Read 3 files and analyzed code');
      expect(summary.precedingToolUseIds, ['tu-1', 'tu-2', 'tu-3']);
    });

    test('handles empty precedingToolUseIds', () {
      final json = {
        'type': 'tool_use_summary',
        'summary': 'Quick analysis completed',
        'precedingToolUseIds': <String>[],
      };

      final msg = ServerMessage.fromJson(json);

      expect(msg, isA<ToolUseSummaryMessage>());
      final summary = msg as ToolUseSummaryMessage;
      expect(summary.summary, 'Quick analysis completed');
      expect(summary.precedingToolUseIds, isEmpty);
    });

    test('handles missing precedingToolUseIds as empty list', () {
      final json = {'type': 'tool_use_summary', 'summary': 'Analyzed codebase'};

      final msg = ServerMessage.fromJson(json);

      expect(msg, isA<ToolUseSummaryMessage>());
      final summary = msg as ToolUseSummaryMessage;
      expect(summary.summary, 'Analyzed codebase');
      expect(summary.precedingToolUseIds, isEmpty);
    });
  });

  group('Codex thread options', () {
    test('ClientMessage.clientCapabilities advertises supported messages', () {
      final msg = ClientMessage.clientCapabilities(appVersion: '1.72.1');

      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'client_capabilities');
      expect(json['appVersion'], '1.72.1');
      expect(json['protocolVersion'], 1);
      expect(json['supportedServerMessages'], [
        'conversation_queue',
        'goal_state',
        'goal_state_raw_status',
        'guardian_approval',
        'history_delta',
        'history_snapshot',
        'bounded_history_window_v1',
        turnAwareHistoryWindowCapability,
        historyPageCapability,
        historyToolDetailCapability,
        sessionActivityAtCapability,
        sessionRequestCorrelationCapability,
        sessionCatalogChangedMessageType,
        'git_status_result',
        'prompt_history_status',
        'artifact_resolved',
        'client_delivery_mode_state_v1',
        'background_notification_v1',
        'background_activity_state_v1',
        'push_registration_state_v1',
        'archived_sessions_result',
        'unarchive_result',
        'delete_session_result',
        ...LocalFeatureProtocolHost.supportedServerMessageTypes.where(
          (type) => !fileTransferProtocolSlot.supportedServerMessageTypes
              .contains(type),
        ),
      ]);

      final nativeSupported =
          jsonDecode(
                ClientMessage.clientCapabilities(
                  fileTransferSupported: true,
                ).toJson(),
              )
              as Map<String, dynamic>;
      expect(
        nativeSupported['supportedServerMessages'],
        containsAll(fileTransferProtocolSlot.supportedServerMessageTypes),
      );

      final runtime =
          jsonDecode(
                ClientMessage.clientCapabilities(
                  mobileRuntime: const {
                    'baseVersion': '1.107.2',
                    'buildNumber': '198',
                    'patchNumber': 4,
                    'hostSchemaVersion': 1,
                    'nativeCapabilities': {'fileTransfer': 2},
                  },
                ).toJson(),
              )
              as Map<String, dynamic>;
      expect(runtime['mobileRuntime'], {
        'baseVersion': '1.107.2',
        'buildNumber': '198',
        'patchNumber': 4,
        'hostSchemaVersion': 1,
        'nativeCapabilities': {'fileTransfer': 2},
      });
    });

    test('ClientMessage.getHistoryDelta serializes sinceSeq', () {
      final msg = ClientMessage.getHistoryDelta('s1', sinceSeq: 42);

      expect(jsonDecode(msg.toJson()), {
        'type': 'get_history_delta',
        'sessionId': 's1',
        'sinceSeq': 42,
      });
    });

    test('ClientMessage.getHistoryPage serializes a bounded cursor', () {
      final msg = ClientMessage.getHistoryPage(
        requestId: 'page-1',
        sessionId: 's1',
        beforeSeq: 42,
        beforeCursor: 'user:turn-42',
      );

      expect(jsonDecode(msg.toJson()), {
        'type': 'get_history_page',
        'requestId': 'page-1',
        'sessionId': 's1',
        'beforeSeq': 42,
        'beforeCursor': 'user:turn-42',
      });
    });

    test('ClientMessage.getHistoryToolDetails serializes requested IDs', () {
      final msg = ClientMessage.getHistoryToolDetails(
        requestId: 'tools-1',
        sessionId: 's1',
        toolUseIds: const ['tool-1', 'tool-2'],
      );

      expect(jsonDecode(msg.toJson()), {
        'type': 'get_history_tool_details',
        'requestId': 'tools-1',
        'sessionId': 's1',
        'toolUseIds': ['tool-1', 'tool-2'],
      });
    });

    test('ClientMessage.input serializes strict ack metadata', () {
      final msg = ClientMessage.input(
        'hello',
        sessionId: 's1',
        clientMessageId: 'cm-1',
        baseSeq: 7,
      );

      expect(jsonDecode(msg.toJson()), {
        'type': 'input',
        'text': 'hello',
        'sessionId': 's1',
        'clientMessageId': 'cm-1',
        'baseSeq': 7,
      });
    });

    test('ClientMessage.setCodexModel serializes model settings', () {
      final msg = ClientMessage.setCodexModel(
        'gpt-5.4-mini',
        modelReasoningEffort: 'low',
        sessionId: 's1',
      );

      expect(jsonDecode(msg.toJson()), {
        'type': 'set_codex_model',
        'model': 'gpt-5.4-mini',
        'modelReasoningEffort': 'low',
        'sessionId': 's1',
      });
    });

    test('permission apply strategies are correlated and live-only', () {
      final message = ClientMessage.setSessionMode(
        legacyMode: 'acceptEdits',
        codexPermissionsMode: 'autoReview',
        applyStrategy: CodexPermissionApplyStrategy.nextTurn,
        permissionChangeId: 'permission-change-1',
        sessionId: 's1',
      );
      final json = jsonDecode(message.toJson()) as Map<String, dynamic>;

      expect(message.delivery, ClientMessageDelivery.ephemeral);
      expect(json['applyStrategy'], 'next_turn');
      expect(json['permissionChangeId'], 'permission-change-1');
      expect(json['sessionId'], 's1');
    });

    test(
      'permission acknowledgements and errors preserve operation routing',
      () {
        final acknowledgement =
            ServerMessage.fromJson({
                  'type': 'system',
                  'subtype': 'set_permission_mode',
                  'sessionId': 's1',
                  'permissionChangeId': 'permission-change-1',
                })
                as SystemMessage;
        final error =
            ServerMessage.fromJson({
                  'type': 'error',
                  'message': 'permission update failed',
                  'errorCode': 'set_permission_mode_rejected',
                  'sessionId': 's1',
                  'permissionChangeId': 'permission-change-1',
                })
                as ErrorMessage;

        expect(acknowledgement.permissionChangeId, 'permission-change-1');
        expect(error.sessionId, 's1');
        expect(error.permissionChangeId, 'permission-change-1');
      },
    );

    test('ServerMessage parses history_delta', () {
      final msg = ServerMessage.fromJson({
        'type': 'history_delta',
        'sessionId': 's1',
        'fromSeq': 4,
        'toSeq': 5,
        'status': 'running',
        'messages': [
          {
            'seq': 5,
            'message': {'type': 'status', 'status': 'running'},
          },
        ],
      });

      expect(msg, isA<HistoryDeltaMessage>());
      final delta = msg as HistoryDeltaMessage;
      expect(delta.sessionId, 's1');
      expect(delta.fromSeq, 4);
      expect(delta.toSeq, 5);
      expect(delta.status, ProcessStatus.running);
      expect(delta.entries.single.seq, 5);
      expect(delta.entries.single.message, isA<StatusMessage>());
    });

    test('ServerMessage parses history_snapshot', () {
      final msg = ServerMessage.fromJson({
        'type': 'history_snapshot',
        'sessionId': 's1',
        'fromSeq': 10,
        'toSeq': 12,
        'reason': 'compacted',
        'historyWindow': {
          'capability': turnAwareHistoryWindowCapability,
          'fromSeq': 10,
          'hasMore': true,
          'cursor': 'user:turn-10',
        },
        'messages': [
          {
            'seq': 12,
            'message': {'type': 'status', 'status': 'idle'},
          },
        ],
      });

      expect(msg, isA<HistorySnapshotMessage>());
      final snapshot = msg as HistorySnapshotMessage;
      expect(snapshot.fromSeq, 10);
      expect(snapshot.toSeq, 12);
      expect(snapshot.reason, 'compacted');
      expect(snapshot.historyWindow?.fromSeq, 10);
      expect(snapshot.historyWindow?.hasMore, isTrue);
      expect(snapshot.historyWindow?.cursor, 'user:turn-10');
      expect(snapshot.entries.single.message, isA<StatusMessage>());
    });

    test('ServerMessage parses a correlated history page', () {
      final msg = ServerMessage.fromJson({
        'type': 'history_page',
        'requestId': 'page-1',
        'sessionId': 's1',
        'beforeSeq': 10,
        'nextBeforeSeq': 5,
        'nextBeforeCursor': 'user:older',
        'hasMore': true,
        'messages': [
          {
            'seq': 5,
            'message': {'type': 'user_input', 'text': 'older'},
          },
        ],
      });

      expect(msg, isA<HistoryPageMessage>());
      final page = msg as HistoryPageMessage;
      expect(page.requestId, 'page-1');
      expect(page.nextBeforeSeq, 5);
      expect(page.nextBeforeCursor, 'user:older');
      expect(page.hasMore, isTrue);
      expect(page.entries.single.message, isA<UserInputMessage>());
    });

    test('ServerMessage parses bounded assistant tool-detail gaps', () {
      final message =
          ServerMessage.fromJson({
                'type': 'assistant',
                'message': {
                  'id': 'assistant-1',
                  'role': 'assistant',
                  'model': 'test',
                  'content': [
                    {'type': 'text', 'text': 'Visible reply'},
                  ],
                },
                'historyToolDetailGaps': [
                  {
                    'gapId': 'gap-1',
                    'toolUseIds': [' tool-1 ', 'tool-1', '', 'tool-2'],
                    'toolNames': ['Read', 'Duplicate', '', 'Search'],
                    'toolCallCount': 999999,
                  },
                  {
                    'gapId': '',
                    'toolUseIds': ['ignored'],
                    'toolNames': ['Read'],
                  },
                ],
              })
              as AssistantServerMessage;

      expect(message.historyToolDetailGaps, hasLength(1));
      final gap = message.historyToolDetailGaps.single;
      expect(gap.gapId, 'gap-1');
      expect(gap.toolUseIds, ['tool-1', 'tool-2']);
      expect(gap.toolNames, ['Read', 'Search']);
      expect(gap.toolCallCount, 2);
    });

    test('ServerMessage parses correlated history tool details', () {
      final message =
          ServerMessage.fromJson({
                'type': 'history_tool_details',
                'requestId': 'tools-1',
                'sessionId': 's1',
                'details': [
                  {
                    'toolUseId': 'tool-1',
                    'toolName': 'Read',
                    'input': {'file_path': '/tmp/a.txt'},
                    'result': {'content': 'contents', 'toolName': 'Read'},
                  },
                ],
              })
              as HistoryToolDetailsMessage;

      expect(message.requestId, 'tools-1');
      expect(message.sessionId, 's1');
      expect(message.details, hasLength(1));
      expect(message.details.single.input['file_path'], '/tmp/a.txt');
      expect(message.details.single.result?.content, 'contents');
    });

    test('ClientMessage.start serializes codex thread options', () {
      final msg = ClientMessage.start(
        '/tmp/project',
        provider: 'codex',
        profile: 'ccpocket',
        modelReasoningEffort: 'high',
        networkAccessEnabled: true,
        webSearchMode: 'live',
        additionalWritableRoots: const ['/tmp/shared'],
        autoRename: true,
        startRequestId: 'start-request-1',
      );

      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['profile'], 'ccpocket');
      expect(json['modelReasoningEffort'], 'high');
      expect(json['networkAccessEnabled'], true);
      expect(json['webSearchMode'], 'live');
      expect(json['additionalWritableRoots'], ['/tmp/shared']);
      expect(json['autoRename'], true);
      expect(json['startRequestId'], 'start-request-1');
    });

    test('ClientMessage.resumeSession serializes codex add-dir roots', () {
      final msg = ClientMessage.resumeSession(
        'session-1',
        '/tmp/project',
        provider: 'codex',
        additionalWritableRoots: const ['/tmp/shared', '/tmp/tools'],
        resumeRequestId: 'link-request-1',
      );

      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'resume_session');
      expect(json['sessionId'], 'session-1');
      expect(json['additionalWritableRoots'], ['/tmp/shared', '/tmp/tools']);
      expect(json['resumeRequestId'], 'link-request-1');
    });

    test('ClientMessage.steerQueuedInput serializes codex queued item', () {
      final msg = ClientMessage.steerQueuedInput(
        sessionId: 'session-1',
        itemId: 'queued-1',
        expectedTurnId: 'desktop-turn-1',
      );

      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'steer_queued_input');
      expect(json['sessionId'], 'session-1');
      expect(json['itemId'], 'queued-1');
      expect(json['expectedTurnId'], 'desktop-turn-1');
      expect(msg.delivery, ClientMessageDelivery.ephemeral);
    });

    test('RecentSession parses codex thread options from codexSettings', () {
      final session = RecentSession.fromJson({
        'sessionId': 's1',
        'provider': 'codex',
        'firstPrompt': 'hello',
        'messageCount': 1,
        'created': '2026-02-13T00:00:00Z',
        'modified': '2026-02-13T00:00:00Z',
        'gitBranch': 'main',
        'projectPath': '/tmp/project',
        'isSidechain': false,
        'codexSettings': {
          'profile': 'ccpocket',
          'modelReasoningEffort': 'medium',
          'serviceTier': 'fast',
          'networkAccessEnabled': false,
          'webSearchMode': 'cached',
          'additionalWritableRoots': ['/tmp/shared'],
        },
      });

      expect(session.codexProfile, 'ccpocket');
      expect(session.codexModelReasoningEffort, 'medium');
      expect(session.codexServiceTier, 'fast');
      expect(session.codexNetworkAccessEnabled, false);
      expect(session.codexWebSearchMode, 'cached');
      expect(session.codexAdditionalWritableRoots, ['/tmp/shared']);
    });

    test('RecentSession cache serialization and rename preserve identity', () {
      final original = RecentSession.fromJson({
        'sessionId': 's-cache',
        'provider': 'codex',
        'permissionMode': 'default',
        'forkedFromThreadId': 'parent-thread',
        'name': 'Before rename',
        'summary': 'Cached summary',
        'firstPrompt': 'hello',
        'lastPrompt': 'continue',
        'created': '2026-02-13T00:00:00Z',
        'modified': '2026-02-13T00:01:00Z',
        'gitBranch': 'feature/cache',
        'projectPath': '/tmp/project',
        'resumeCwd': '/tmp/worktree',
        'isSidechain': false,
        'executionMode': 'default',
        'planMode': true,
        'codexSettings': {
          'approvalPolicy': 'on-request',
          'approvalsReviewer': 'auto_review',
          'codexPermissionsMode': 'autoReview',
          'sandboxMode': 'workspace-write',
          'model': 'gpt-5.3-codex-spark',
          'profile': 'ccpocket',
          'modelReasoningEffort': 'high',
          'serviceTier': 'fast',
          'networkAccessEnabled': true,
          'webSearchMode': 'live',
          'additionalWritableRoots': ['/tmp/shared'],
        },
      });

      final restored = RecentSession.fromJson(original.toJson());
      final renamed = restored.copyWithName(name: 'After rename');

      expect(restored.forkedFromThreadId, 'parent-thread');
      expect(restored.codexPermissionsMode, 'autoReview');
      expect(restored.codexAdditionalWritableRoots, ['/tmp/shared']);
      expect(renamed.name, 'After rename');
      expect(renamed.forkedFromThreadId, 'parent-thread');
      expect(renamed.codexPermissionsMode, 'autoReview');
    });

    test('SessionListMessage parses model metadata', () {
      final msg = ServerMessage.fromJson({
        'type': 'session_list',
        'bridgeInstanceId': 'bridge-machine-a',
        'sessions': const [
          {
            'id': 's1',
            'provider': 'codex',
            'projectPath': '/tmp/project',
            'status': 'idle',
            'createdAt': '',
            'lastActivityAt': '',
            'codexPermissionApplyStrategySupported': true,
            'codexNativePlanModeSupported': true,
          },
        ],
        'allowedDirs': const [],
        'claudeModels': ['claude-opus-4-7', 'claude-haiku-4-6'],
        'claudeModelEfforts': {
          'claude-opus-4-7': ['low', 'medium', 'high', 'xhigh', 'max'],
          'claude-haiku-4-6': [],
        },
        'codexModels': ['gpt-5.5'],
        'codexModelReasoningEfforts': {
          'gpt-5.5': ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
        },
        'codexModelServiceTiers': {
          'gpt-5.5': ['fast'],
        },
        'codexProfiles': ['ccpocket', 'research'],
        'defaultCodexProfile': 'ccpocket',
        'bridgeCapabilities': ['codex_permission_apply_strategy_v1'],
        'codexAutoReviewDisabled': true,
      });

      expect(msg, isA<SessionListMessage>());
      final sessionList = msg as SessionListMessage;
      expect(sessionList.bridgeInstanceId, 'bridge-machine-a');
      expect(sessionList.claudeModels, ['claude-opus-4-7', 'claude-haiku-4-6']);
      expect(sessionList.claudeModelEfforts['claude-opus-4-7'], [
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ]);
      expect(sessionList.claudeModelEfforts['claude-haiku-4-6'], isEmpty);
      expect(sessionList.codexModels, ['gpt-5.5']);
      expect(sessionList.codexModelReasoningEfforts['gpt-5.5'], [
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
        'ultra',
      ]);
      expect(sessionList.codexModelServiceTiers['gpt-5.5'], ['fast']);
      expect(sessionList.codexProfiles, ['ccpocket', 'research']);
      expect(sessionList.bridgeCapabilities, [
        'codex_permission_apply_strategy_v1',
      ]);
      expect(
        sessionList.sessions.single.codexPermissionApplyStrategySupported,
        isTrue,
      );
      expect(sessionList.sessions.single.codexNativePlanModeSupported, isTrue);
      expect(sessionList.defaultCodexProfile, 'ccpocket');
      expect(sessionList.codexAutoReviewDisabled, isTrue);
    });

    test(
      'SessionInfo distinguishes explicit native Plan refusal from an old Bridge',
      () {
        final unsupported = SessionInfo.fromJson({
          'id': 'unsupported',
          'provider': 'codex',
          'projectPath': '/tmp/project',
          'status': 'idle',
          'createdAt': '',
          'lastActivityAt': '',
          'codexNativePlanModeSupported': false,
        });
        final oldBridge = SessionInfo.fromJson({
          'id': 'old-bridge',
          'provider': 'codex',
          'projectPath': '/tmp/project',
          'status': 'idle',
          'createdAt': '',
          'lastActivityAt': '',
        });

        expect(unsupported.codexNativePlanModeSupported, isFalse);
        expect(oldBridge.codexNativePlanModeSupported, isNull);
        expect(
          unsupported
              .copyWith(clearCodexNativePlanModeSupported: true)
              .codexNativePlanModeSupported,
          isNull,
        );
      },
    );

    test('RecentSessionsMessage parses request metadata', () {
      final msg = ServerMessage.fromJson({
        'type': 'recent_sessions',
        'sessions': const [],
        'hasMore': true,
        'limit': 20,
        'offset': 40,
        'projectPath': '/tmp/project',
        'requestScope': 'project',
        'requestId': 'catalog-7-12',
        'queryGeneration': 7,
        'catalogRevision': 23,
        'provider': 'codex',
        'namedOnly': true,
        'searchQuery': 'needle',
      });

      expect(msg, isA<RecentSessionsMessage>());
      final recentSessions = msg as RecentSessionsMessage;
      expect(recentSessions.hasMore, isTrue);
      expect(recentSessions.limit, 20);
      expect(recentSessions.offset, 40);
      expect(recentSessions.projectPath, '/tmp/project');
      expect(recentSessions.requestScope, 'project');
      expect(recentSessions.requestId, 'catalog-7-12');
      expect(recentSessions.queryGeneration, 7);
      expect(recentSessions.catalogRevision, 23);
      expect(recentSessions.provider, 'codex');
      expect(recentSessions.namedOnly, isTrue);
      expect(recentSessions.searchQuery, 'needle');
    });

    test('RecentSession parses resumeCwd for worktree resume target', () {
      final session = RecentSession.fromJson({
        'sessionId': 's2',
        'provider': 'codex',
        'firstPrompt': 'resume',
        'messageCount': 1,
        'created': '2026-02-13T00:00:00Z',
        'modified': '2026-02-13T00:00:00Z',
        'gitBranch': 'feature/x',
        'projectPath': '/tmp/project',
        'resumeCwd': '/tmp/project-worktrees/feature-x',
        'isSidechain': false,
      });

      expect(session.projectPath, '/tmp/project');
      expect(session.resumeCwd, '/tmp/project-worktrees/feature-x');
    });

    test('RecentSession ignores placeholder codex model names', () {
      final session = RecentSession.fromJson({
        'sessionId': 's3',
        'provider': 'codex',
        'firstPrompt': 'resume',
        'created': '2026-02-13T00:00:00Z',
        'modified': '2026-02-13T00:00:00Z',
        'gitBranch': 'main',
        'projectPath': '/tmp/project',
        'isSidechain': false,
        'codexSettings': {'model': 'codex'},
      });

      expect(session.codexModel, isNull);
    });

    test('RecentSession preserves raw Claude auto permission mode', () {
      final session = RecentSession.fromJson({
        'sessionId': 's-auto',
        'provider': 'claude',
        'firstPrompt': 'resume',
        'created': '2026-02-13T00:00:00Z',
        'modified': '2026-02-13T00:00:00Z',
        'gitBranch': 'main',
        'projectPath': '/tmp/project',
        'permissionMode': 'auto',
        'executionMode': 'default',
        'isSidechain': false,
      });

      expect(session.rawPermissionMode, 'auto');
      expect(session.effectivePermissionMode, 'auto');
      expect(session.resolvedExecutionMode, ExecutionMode.defaultMode);
    });

    test('AssistantMessage ignores placeholder codex model names', () {
      final message = AssistantMessage.fromJson({
        'id': 'a1',
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'hello'},
        ],
        'model': 'codex',
      });

      expect(message.model, isEmpty);
    });

    test('normalizes deprecated codex model to first available model', () {
      expect(
        normalizeCodexModelForAvailableList('gpt-5.2-codex', [
          'gpt-5.3-codex',
          'gpt-5.4-mini',
        ]),
        'gpt-5.3-codex',
      );
    });

    test('uses default codex list when available list is empty', () {
      expect(
        normalizeCodexModelForAvailableList('gpt-5.2-codex', const []),
        defaultCodexModels.first,
      );
    });

    test('skips deprecated entries when selecting replacement model', () {
      expect(
        normalizeCodexModelForAvailableList('gpt-5.2-codex', [
          'gpt-5.2-codex',
          'gpt-5.4-mini',
        ]),
        'gpt-5.4-mini',
      );
    });
  });

  group('Claude advanced options', () {
    test('ClientMessage.start serializes advanced Claude options', () {
      final msg = ClientMessage.start(
        '/tmp/project',
        provider: 'claude',
        model: 'claude-sonnet-4-5',
        effort: 'high',
        maxTurns: 8,
        maxBudgetUsd: 1.25,
        fallbackModel: 'claude-haiku-4-5',
        persistSession: false,
      );

      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['model'], 'claude-sonnet-4-5');
      expect(json['effort'], 'high');
      expect(json['maxTurns'], 8);
      expect(json['maxBudgetUsd'], 1.25);
      expect(json['fallbackModel'], 'claude-haiku-4-5');
      expect(json['persistSession'], false);
      expect(json.containsKey('forkSession'), isFalse);
    });

    test('ClientMessage.resumeSession serializes resume-only options', () {
      final msg = ClientMessage.resumeSession(
        'session-1',
        '/tmp/project',
        provider: 'claude',
        permissionMode: 'acceptEdits',
        model: 'claude-sonnet-4-5',
        effort: 'medium',
        maxTurns: 5,
        maxBudgetUsd: 0.5,
        fallbackModel: 'claude-haiku-4-5',
        forkSession: true,
        persistSession: true,
      );

      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'resume_session');
      expect(json['sessionId'], 'session-1');
      expect(json['permissionMode'], 'acceptEdits');
      expect(json['model'], 'claude-sonnet-4-5');
      expect(json['effort'], 'medium');
      expect(json['maxTurns'], 5);
      expect(json['maxBudgetUsd'], 0.5);
      expect(json['fallbackModel'], 'claude-haiku-4-5');
      expect(json['forkSession'], true);
      expect(json['persistSession'], true);
    });
  });

  group('Result message parsing', () {
    test('parses token and tool usage fields', () {
      final msg = ServerMessage.fromJson({
        'type': 'result',
        'subtype': 'success',
        'cost': 0.1234,
        'duration': 4567,
        'inputTokens': 1000,
        'cachedInputTokens': 250,
        'outputTokens': 333,
        'toolCalls': 9,
        'fileEdits': 3,
      });

      expect(msg, isA<ResultMessage>());
      final result = msg as ResultMessage;
      expect(result.inputTokens, 1000);
      expect(result.cachedInputTokens, 250);
      expect(result.outputTokens, 333);
      expect(result.toolCalls, 9);
      expect(result.fileEdits, 3);
    });
  });

  group('InputAck message parsing', () {
    test('parses queued=true', () {
      final msg = ServerMessage.fromJson({
        'type': 'input_ack',
        'sessionId': 's1',
        'queued': true,
      });

      expect(msg, isA<InputAckMessage>());
      final ack = msg as InputAckMessage;
      expect(ack.sessionId, 's1');
      expect(ack.queued, isTrue);
      expect(ack.clientMessageId, isNull);
      expect(ack.acceptedSeq, isNull);
    });

    test('defaults queued to false when omitted', () {
      final msg = ServerMessage.fromJson({
        'type': 'input_ack',
        'sessionId': 's1',
      });

      expect(msg, isA<InputAckMessage>());
      final ack = msg as InputAckMessage;
      expect(ack.sessionId, 's1');
      expect(ack.queued, isFalse);
    });

    test('parses strict ack metadata', () {
      final msg = ServerMessage.fromJson({
        'type': 'input_ack',
        'sessionId': 's1',
        'clientMessageId': 'cm-1',
        'acceptedSeq': 12,
      });

      expect(msg, isA<InputAckMessage>());
      final ack = msg as InputAckMessage;
      expect(ack.clientMessageId, 'cm-1');
      expect(ack.acceptedSeq, 12);
    });
  });

  group('ConversationQueue message parsing', () {
    test('parses queued items', () {
      final msg = ServerMessage.fromJson({
        'type': 'conversation_queue',
        'sessionId': 's1',
        'limit': 1,
        'items': [
          {
            'itemId': 'q1',
            'text': 'Follow up',
            'createdAt': '2026-04-25T00:00:00.000Z',
            'imageCount': 1,
            'skills': [
              {'name': 'skill-a', 'path': '/tmp/skill-a'},
            ],
          },
        ],
      });

      expect(msg, isA<ConversationQueueMessage>());
      final queue = msg as ConversationQueueMessage;
      expect(queue.sessionId, 's1');
      expect(queue.limit, 1);
      expect(queue.items.single.itemId, 'q1');
      expect(queue.items.single.text, 'Follow up');
      expect(queue.items.single.imageCount, 1);
      expect(queue.items.single.skills.single['name'], 'skill-a');
    });

    test('parses queued input on session info', () {
      final session = SessionInfo.fromJson({
        'id': 's1',
        'provider': 'codex',
        'projectPath': '/tmp/project',
        'status': 'running',
        'createdAt': '',
        'lastActivityAt': '',
        'queuedInput': {
          'itemId': 'q1',
          'text': 'Queued',
          'createdAt': '2026-04-25T00:00:00.000Z',
        },
      });

      expect(session.queuedInput?.itemId, 'q1');
      expect(session.queuedInput?.text, 'Queued');
    });
  });

  // ---- Git Operations (Phase 1-3) ----

  group('GitStageResultMessage', () {
    test('parses success', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_stage_result',
        'success': true,
      });
      expect(msg, isA<GitStageResultMessage>());
      expect((msg as GitStageResultMessage).success, isTrue);
      expect(msg.error, isNull);
    });

    test('parses failure with error', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_stage_result',
        'success': false,
        'error': 'file not found',
      });
      expect(msg, isA<GitStageResultMessage>());
      final r = msg as GitStageResultMessage;
      expect(r.success, isFalse);
      expect(r.error, 'file not found');
    });
  });

  group('GitUnstageResultMessage', () {
    test('parses success', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_unstage_result',
        'success': true,
      });
      expect(msg, isA<GitUnstageResultMessage>());
      expect((msg as GitUnstageResultMessage).success, isTrue);
    });
  });

  group('GitUnstageHunksResultMessage', () {
    test('parses success', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_unstage_hunks_result',
        'success': true,
      });
      expect(msg, isA<GitUnstageHunksResultMessage>());
      expect((msg as GitUnstageHunksResultMessage).success, isTrue);
    });
  });

  group('GitCommitResultMessage', () {
    test('parses success with hash and message', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_commit_result',
        'success': true,
        'commitHash': 'abc1234',
        'message': 'feat: add login',
      });
      expect(msg, isA<GitCommitResultMessage>());
      final r = msg as GitCommitResultMessage;
      expect(r.success, isTrue);
      expect(r.commitHash, 'abc1234');
      expect(r.message, 'feat: add login');
      expect(r.error, isNull);
    });

    test('parses failure', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_commit_result',
        'success': false,
        'error': 'Nothing to commit',
      });
      final r = msg as GitCommitResultMessage;
      expect(r.success, isFalse);
      expect(r.error, 'Nothing to commit');
    });
  });

  group('GitPushResultMessage', () {
    test('parses success', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_push_result',
        'success': true,
      });
      final r = msg as GitPushResultMessage;
      expect(r.success, isTrue);
      expect(r.error, isNull);
    });
  });

  group('GitBranchesResultMessage', () {
    test('parses branches list', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_branches_result',
        'current': 'main',
        'branches': ['main', 'feat/login', 'fix/bug'],
        'remoteStatusByBranch': {
          'feat/login': {'ahead': 2, 'behind': 1, 'hasUpstream': true},
        },
      });
      final r = msg as GitBranchesResultMessage;
      expect(r.current, 'main');
      expect(r.branches, ['main', 'feat/login', 'fix/bug']);
      expect(r.remoteStatusByBranch['feat/login']?.ahead, 2);
      expect(r.error, isNull);
    });

    test('parses error', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_branches_result',
        'current': '',
        'branches': <String>[],
        'error': 'not a git repo',
      });
      final r = msg as GitBranchesResultMessage;
      expect(r.error, 'not a git repo');
    });
  });

  group('GitCreateBranchResultMessage', () {
    test('parses success', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_create_branch_result',
        'success': true,
      });
      expect((msg as GitCreateBranchResultMessage).success, isTrue);
    });

    test('parses failure', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_create_branch_result',
        'success': false,
        'error': 'branch exists',
      });
      final r = msg as GitCreateBranchResultMessage;
      expect(r.success, isFalse);
      expect(r.error, 'branch exists');
    });
  });

  group('GitCheckoutBranchResultMessage', () {
    test('parses success', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_checkout_branch_result',
        'success': true,
      });
      expect((msg as GitCheckoutBranchResultMessage).success, isTrue);
    });

    test('parses failure', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_checkout_branch_result',
        'success': false,
        'error': 'branch not found',
      });
      final r = msg as GitCheckoutBranchResultMessage;
      expect(r.success, isFalse);
      expect(r.error, 'branch not found');
    });
  });

  group('ClientMessage git operations serialization', () {
    test('gitStage with files', () {
      final msg = ClientMessage.gitStage('/p', files: ['a.txt', 'b.txt']);
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'git_stage');
      expect(json['projectPath'], '/p');
      expect(json['files'], ['a.txt', 'b.txt']);
    });

    test('gitStage with hunks', () {
      final msg = ClientMessage.gitStage(
        '/p',
        hunks: [
          {'file': 'a.txt', 'hunkIndex': 0},
        ],
      );
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'git_stage');
      expect(json['hunks'], [
        {'file': 'a.txt', 'hunkIndex': 0},
      ]);
    });

    test('gitUnstage', () {
      final msg = ClientMessage.gitUnstage('/p', files: ['a.txt']);
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'git_unstage');
      expect(json['files'], ['a.txt']);
    });

    test('gitUnstageHunks', () {
      final msg = ClientMessage.gitUnstageHunks('/p', [
        {'file': 'a.txt', 'hunkIndex': 0},
      ]);
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'git_unstage_hunks');
      expect(json['hunks'], [
        {'file': 'a.txt', 'hunkIndex': 0},
      ]);
    });

    test('gitCommit with message', () {
      final msg = ClientMessage.gitCommit('/p', message: 'feat: add x');
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'git_commit');
      expect(json['message'], 'feat: add x');
    });

    test('gitCommit with autoGenerate', () {
      final msg = ClientMessage.gitCommit('/p', autoGenerate: true);
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['autoGenerate'], isTrue);
    });

    test('gitCommit with sessionId', () {
      final msg = ClientMessage.gitCommit(
        '/p',
        sessionId: 's-1',
        autoGenerate: true,
      );
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['sessionId'], 's-1');
      expect(json['autoGenerate'], isTrue);
    });

    test('gitPush', () {
      final msg = ClientMessage.gitPush('/p');
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'git_push');
      expect(json['projectPath'], '/p');
    });

    test('gitBranches', () {
      final msg = ClientMessage.gitBranches('/p');
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'git_branches');
      expect(json['projectPath'], '/p');
    });

    test('gitCreateBranch', () {
      final msg = ClientMessage.gitCreateBranch('/p', 'feat/x', checkout: true);
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'git_create_branch');
      expect(json['name'], 'feat/x');
      expect(json['checkout'], isTrue);
    });

    test('gitCheckoutBranch', () {
      final msg = ClientMessage.gitCheckoutBranch('/p', 'main');
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'git_checkout_branch');
      expect(json['branch'], 'main');
    });

    test('gitRevertHunks', () {
      final msg = ClientMessage.gitRevertHunks('/p', [
        {'file': 'a.txt', 'hunkIndex': 1},
      ]);
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'git_revert_hunks');
      expect(json['hunks'], [
        {'file': 'a.txt', 'hunkIndex': 1},
      ]);
    });

    test('getDiff with staged', () {
      final msg = ClientMessage.getDiff('/p', staged: true);
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'get_diff');
      expect(json['staged'], isTrue);
    });

    test('getDiff without staged (backward compat)', () {
      final msg = ClientMessage.getDiff('/p');
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'get_diff');
      expect(json.containsKey('staged'), isFalse);
      expect(json.containsKey('requestId'), isFalse);
    });

    test('getDiff with requestId', () {
      final msg = ClientMessage.getDiff('/p', requestId: 'gitdiff-3');
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'get_diff');
      expect(json['requestId'], 'gitdiff-3');
    });

    test('parses diff_result requestId echo (absent on old Bridge)', () {
      final withId =
          ServerMessage.fromJson({
                'type': 'diff_result',
                'diff': 'diff --git a/a b/a',
                'requestId': 'gitdiff-3',
              })
              as DiffResultMessage;
      expect(withId.requestId, 'gitdiff-3');

      final withoutId =
          ServerMessage.fromJson({'type': 'diff_result', 'diff': ''})
              as DiffResultMessage;
      expect(withoutId.requestId, isNull);
    });

    test('gitStatus with sessionId', () {
      final msg = ClientMessage.gitStatus(
        '/p',
        sessionId: 's1',
        includeRemote: true,
      );
      final json = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(json['type'], 'git_status');
      expect(json['projectPath'], '/p');
      expect(json['sessionId'], 's1');
      expect(json['includeRemote'], isTrue);
    });

    test('parses gitStatusResult', () {
      final msg = ServerMessage.fromJson({
        'type': 'git_status_result',
        'sessionId': 's1',
        'projectPath': '/p',
        'hasUncommittedChanges': true,
        'stagedCount': 1,
        'unstagedCount': 2,
        'untrackedCount': 3,
        'remoteStatusIncluded': true,
        'hasRemoteChanges': true,
        'commitsAhead': 4,
        'commitsBehind': 5,
        'hasUpstream': true,
        'branch': 'main',
      });

      expect(msg, isA<GitStatusResultMessage>());
      final status = msg as GitStatusResultMessage;
      expect(status.sessionId, 's1');
      expect(status.projectPath, '/p');
      expect(status.hasUncommittedChanges, isTrue);
      expect(status.stagedCount, 1);
      expect(status.unstagedCount, 2);
      expect(status.untrackedCount, 3);
      expect(status.remoteStatusIncluded, isTrue);
      expect(status.hasRemoteChanges, isTrue);
      expect(status.commitsAhead, 4);
      expect(status.commitsBehind, 5);
      expect(status.hasUpstream, isTrue);
      expect(status.branch, 'main');
    });

    test('parses correlated archived session lifecycle results', () {
      final list =
          ServerMessage.fromJson({
                'type': 'archived_sessions_result',
                'requestId': 'list-1',
                'success': true,
                'truncated': true,
                'sessions': [
                  {
                    'sessionId': 'thread-1',
                    'provider': 'codex',
                    'projectPath': '/project',
                    'archivedAt': '2026-07-18T00:00:00Z',
                    'name': 'Named thread',
                  },
                ],
              })
              as ArchivedSessionsResultMessage;
      expect(list.requestId, 'list-1');
      expect(list.truncated, isTrue);
      expect(list.sessions.single.displayTitle, 'Named thread');

      final result =
          ServerMessage.fromJson({
                'type': 'delete_session_result',
                'requestId': 'delete-1',
                'sessionId': 'thread-1',
                'success': false,
                'errorCode': 'session_active',
              })
              as SessionLifecycleResultMessage;
      expect(result.type, 'delete_session_result');
      expect(result.requestId, 'delete-1');
      expect(result.sessionId, 'thread-1');
      expect(result.errorCode, 'session_active');

      final archiveResult =
          ServerMessage.fromJson({
                'type': 'archive_result',
                'requestId': 'archive-1',
                'sessionId': 'shared-id',
                'provider': 'codex',
                'success': true,
              })
              as ArchiveResultMessage;
      expect(archiveResult.requestId, 'archive-1');
      expect(archiveResult.provider, 'codex');
      expect(
        providerSessionIdentityKey('codex', 'shared-id'),
        isNot(providerSessionIdentityKey('claude', 'shared-id')),
      );
    });

    test('archive lifecycle client messages are ephemeral and correlated', () {
      final archive = ClientMessage.archiveSession(
        requestId: 'archive-1',
        sessionId: 'thread-1',
        provider: 'codex',
        projectPath: '/project',
        name: 'Named thread',
      );
      expect(archive.delivery, ClientMessageDelivery.ephemeral);
      expect(
        jsonDecode(archive.toJson()),
        containsPair('requestId', 'archive-1'),
      );

      final unarchive = ClientMessage.unarchiveSession(
        requestId: 'restore-1',
        sessionId: 'thread-1',
        provider: 'codex',
        projectPath: '/project',
      );
      expect(unarchive.delivery, ClientMessageDelivery.ephemeral);

      final delete = ClientMessage.deleteSession(
        requestId: 'delete-1',
        sessionId: 'thread-1',
        projectPath: '/project',
      );
      final deleteJson = jsonDecode(delete.toJson()) as Map<String, dynamic>;
      expect(delete.delivery, ClientMessageDelivery.ephemeral);
      expect(deleteJson['provider'], 'codex');
      expect(deleteJson['confirmDescendantDeletion'], isTrue);
    });
  });

  group('Guardian approval status parsing', () {
    test('keeps recognized wire literals', () {
      expect(
        GuardianApprovalStatus.fromString('approved'),
        GuardianApprovalStatus.approved,
      );
      expect(
        GuardianApprovalStatus.fromString('denied'),
        GuardianApprovalStatus.denied,
      );
      expect(
        GuardianApprovalStatus.fromString('timedOut'),
        GuardianApprovalStatus.timedOut,
      );
      expect(
        GuardianApprovalStatus.fromString('aborted'),
        GuardianApprovalStatus.aborted,
      );
    });

    test('missing status still means approved for old Bridges', () {
      // Old Bridges emit guardian_approval only for approved reviews and
      // omit the status field entirely.
      expect(
        GuardianApprovalStatus.fromString(null),
        GuardianApprovalStatus.approved,
      );
    });

    test('fails closed on unrecognized status literals', () {
      expect(
        GuardianApprovalStatus.fromString('escalated'),
        GuardianApprovalStatus.denied,
      );
      final message =
          ServerMessage.fromJson({
                'type': 'guardian_approval',
                'risk': 'high',
                'status': 'someFutureStatus',
                'reason': 'reason',
              })
              as GuardianApprovalMessage;
      expect(message.status, GuardianApprovalStatus.denied);
    });
  });

  group('session_list parsing resilience', () {
    Map<String, dynamic> validSession(String id) => {
      'id': id,
      'provider': 'codex',
      'projectPath': '/tmp/project',
      'status': 'idle',
      'createdAt': '',
      'lastActivityAt': '',
    };

    test('skips malformed session entries and counts them', () {
      final msg =
          ServerMessage.fromJson({
                'type': 'session_list',
                'sessions': [
                  validSession('s1'),
                  'not-a-map',
                  {'id': 42, 'projectPath': '/tmp/project'},
                  validSession('s2'),
                ],
              })
              as SessionListMessage;

      expect(msg.sessions.map((s) => s.id), ['s1', 's2']);
      expect(msg.droppedSessionCount, 2);
    });

    test('parses a fully valid list with zero drops', () {
      final msg =
          ServerMessage.fromJson({
                'type': 'session_list',
                'sessions': [validSession('s1')],
              })
              as SessionListMessage;

      expect(msg.sessions.single.id, 's1');
      expect(msg.droppedSessionCount, 0);
    });

    test('a malformed pendingPermission does not drop the session', () {
      final withBadPermission = validSession('s1')
        ..['pendingPermission'] = {
          // Missing toolName and input.
          'toolUseId': 'tool-1',
        };
      final msg =
          ServerMessage.fromJson({
                'type': 'session_list',
                'sessions': [withBadPermission],
              })
              as SessionListMessage;

      expect(msg.sessions.single.id, 's1');
      expect(msg.sessions.single.pendingPermission, isNull);
      expect(msg.droppedSessionCount, 0);
    });
  });

  group('string list parsing drops non-string elements eagerly', () {
    test('file_list files never throw at iteration time', () {
      final msg =
          ServerMessage.fromJson({
                'type': 'file_list',
                'files': ['a.txt', 42, 'b.txt'],
              })
              as FileListMessage;

      // The old lazy cast<String>() deferred the TypeError to first access
      // (widget build time); iterating here must be safe.
      expect(msg.files.toList(), ['a.txt', 'b.txt']);
    });

    test('git_branches_result branches never throw at iteration time', () {
      final msg =
          ServerMessage.fromJson({
                'type': 'git_branches_result',
                'current': 'main',
                'branches': ['main', 7, 'dev'],
                'checkedOutBranches': ['main', true],
              })
              as GitBranchesResultMessage;

      expect(msg.branches.toList(), ['main', 'dev']);
      expect(msg.checkedOutBranches.toList(), ['main']);
    });
  });
}
