import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'advertises app-server status semantics to compatible Bridge versions',
    () {
      expect(
        LocalFeatureProtocolHost.supportedServerMessageTypes,
        contains(appServerStatusV1Capability),
      );
      expect(
        LocalFeatureProtocolHost.supportedServerMessageTypes,
        contains(conversationWindowCoverageCapability),
      );
    },
  );

  test('decodes an authoritative unknown status without inventing idle', () {
    final decoded =
        ServerMessage.fromJson(<String, dynamic>{
              ..._baseFrame,
              'event': 'status_changes',
              'statusState': 'status-1',
              'pageIndex': 0,
              'pageCount': 1,
              'changes': [
                {
                  'provider': 'codex',
                  'providerSessionId': 'thread-1',
                  'activity': 'unknown',
                  'attention': 'none',
                  'result': 'none',
                  'runtimeAttachment': 'notLoaded',
                  'source': 'appServer',
                  'confidence': 'authoritative',
                  'observedAt': '2026-07-30T00:00:00.000Z',
                },
              ],
            })
            as ConversationSyncV2EventMessage;

    expect(decoded.event, ConversationSyncV2EventKind.statusChanges);
    expect(decoded.statusChanges.single.activity, 'unknown');
    expect(decoded.statusChanges.single.runtimeAttachment, 'notLoaded');
    expect(decoded.statusChanges.single.executionHost, isNull);
    expect(decoded.statusChanges.single.activeTurnId, isNull);
    expect(decoded.statusChanges.single.controlState, isNull);
    expect(decoded.statusChanges.single.authorityGeneration, isNull);
  });

  test('decodes and persists additive turn authority fields', () {
    final decoded =
        ServerMessage.fromJson(<String, dynamic>{
              ..._baseFrame,
              'event': 'status_changes',
              'statusState': 'status-authority',
              'pageIndex': 0,
              'pageCount': 1,
              'changes': [
                {
                  'provider': 'codex',
                  'providerSessionId': 'thread-authority',
                  'activity': 'working',
                  'attention': 'none',
                  'result': 'none',
                  'runtimeAttachment': 'loaded',
                  'source': 'appServer',
                  'confidence': 'authoritative',
                  'observedAt': '2026-08-01T00:00:00.000Z',
                  'executionHost': 'bridge',
                  'activeTurnId': 'turn-1',
                  'controlState': 'writable',
                  'authorityGeneration': 'authority-7',
                },
              ],
            })
            as ConversationSyncV2EventMessage;

    final status = decoded.statusChanges.single;
    expect(status.executionHost, 'bridge');
    expect(status.activeTurnId, 'turn-1');
    expect(status.controlState, 'writable');
    expect(status.authorityGeneration, 'authority-7');
    expect(status.toJson(), containsPair('executionHost', 'bridge'));
    expect(status.toJson(), containsPair('activeTurnId', 'turn-1'));
    expect(status.toJson(), containsPair('controlState', 'writable'));
    expect(status.toJson(), containsPair('authorityGeneration', 'authority-7'));
  });

  test('rejects unsupported execution host and control state values', () {
    Map<String, dynamic> frameWithStatus(Map<String, dynamic> additions) => {
      ..._baseFrame,
      'event': 'status_changes',
      'statusState': 'status-invalid',
      'pageIndex': 0,
      'pageCount': 1,
      'changes': [
        {
          'provider': 'codex',
          'providerSessionId': 'thread-invalid',
          'activity': 'working',
          'attention': 'none',
          'result': 'none',
          'runtimeAttachment': 'loaded',
          'source': 'appServer',
          'confidence': 'authoritative',
          'observedAt': '2026-08-01T00:00:00.000Z',
          ...additions,
        },
      ],
    };

    expect(
      () => ServerMessage.fromJson(
        frameWithStatus({'executionHost': 'anotherHost'}),
      ),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson(
        frameWithStatus({'controlState': 'implicitlyWritable'}),
      ),
      throwsFormatException,
    );
  });

  test(
    'bounds legacy Bridge catalog display text instead of dropping sync',
    () {
      final decoded =
          ServerMessage.fromJson(<String, dynamic>{
                ..._baseFrame,
                'event': 'catalog_changes',
                'catalogState': 'catalog-1',
                'pageIndex': 0,
                'pageCount': 1,
                'created': [
                  {
                    'provider': 'codex',
                    'providerSessionId': 'thread-1',
                    'revision': 'revision-1',
                    'projectPath': '/workspace',
                    'name': 'n' * 800,
                    'summary': 's' * 8000,
                    'firstPrompt': '${'p' * 4094}😀${'x' * 24000}',
                    'createdAt': '2026-07-30T00:00:00.000Z',
                    'modifiedAt': '2026-07-30T00:01:00.000Z',
                    'recencyAt': '2026-07-30T00:02:00.000Z',
                    'availability': 'durable',
                  },
                ],
                'updated': const [],
                'destroyed': const [],
              })
              as ConversationSyncV2EventMessage;

      final entry = decoded.created.single;
      expect(entry.name, hasLength(512));
      expect(entry.summary, hasLength(4096));
      expect(entry.firstPrompt, hasLength(4095));
      expect(entry.firstPrompt, endsWith('…'));
      expect(entry.firstPrompt, isNot(contains('\ud83d')));
    },
  );

  test('decodes detached Codex model settings into cached metadata', () {
    final decoded =
        ServerMessage.fromJson(<String, dynamic>{
              ..._baseFrame,
              'event': 'catalog_changes',
              'catalogState': 'catalog-settings',
              'pageIndex': 0,
              'pageCount': 1,
              'created': [
                {
                  'provider': 'codex',
                  'providerSessionId': 'thread-settings',
                  'revision': 'revision-settings',
                  'projectPath': '/workspace',
                  'projectGroupKind': 'desktopProject',
                  'projectGroupId': 'project-ccpocket',
                  'projectGroupName': 'CC Pocket',
                  'projectGroupPath': '/workspace/ccpocket',
                  'projectGroupingSnapshotComplete': true,
                  'firstPrompt': 'Prompt',
                  'model': 'gpt-5.6-sol',
                  'modelReasoningEffort': 'ultra',
                  'serviceTier': 'fast',
                  'approvalPolicy': 'on-request',
                  'approvalsReviewer': 'user',
                  'sandboxMode': 'workspace-write',
                  'collaborationMode': 'plan',
                  'networkAccessEnabled': true,
                  'webSearchMode': 'live',
                  'codexSettingsSnapshotComplete': true,
                  'createdAt': '2026-07-30T00:00:00.000Z',
                  'modifiedAt': '2026-07-30T00:01:00.000Z',
                  'recencyAt': '2026-07-30T00:02:00.000Z',
                  'availability': 'durable',
                },
              ],
              'updated': const [],
              'destroyed': const [],
            })
            as ConversationSyncV2EventMessage;

    final session = decoded.created.single.toRecentSession(
      codexSourceId: 'source-1',
    );
    expect(session.contentRevision, 'revision-settings');
    expect(session.projectGroupingKey, 'desktop-project:project-ccpocket');
    expect(session.projectName, 'CC Pocket');
    expect(session.effectiveProjectGroupPath, '/workspace/ccpocket');
    expect(session.projectGroupingSnapshotComplete, isTrue);
    expect(session.codexModel, 'gpt-5.6-sol');
    expect(session.codexModelReasoningEffort, 'ultra');
    expect(session.codexServiceTier, 'fast');
    expect(session.codexApprovalPolicy, 'on-request');
    expect(session.codexApprovalsReviewer, 'user');
    expect(session.codexSandboxMode, 'workspace-write');
    expect(session.codexCollaborationMode, 'plan');
    expect(session.planMode, isTrue);
    expect(session.codexNetworkAccessEnabled, isTrue);
    expect(session.codexWebSearchMode, 'live');
    expect(session.codexSettingsSnapshotComplete, isTrue);

    final restored = RecentSession.fromJson(session.toJson());
    expect(restored.contentRevision, 'revision-settings');
    expect(restored.projectGroupingKey, 'desktop-project:project-ccpocket');
    expect(restored.projectName, 'CC Pocket');
    expect(restored.codexCollaborationMode, 'plan');
    expect(restored.codexSettingsSnapshotComplete, isTrue);
  });

  test('old v2 catalog settings remain incremental without completeness', () {
    final entry = ConversationSyncV2CatalogEntry.fromJson(<String, dynamic>{
      'provider': 'codex',
      'providerSessionId': 'thread-partial-settings',
      'revision': 'revision-partial-settings',
      'projectPath': '/workspace',
      'model': 'gpt-5.6-sol',
      'createdAt': '2026-07-30T00:00:00.000Z',
      'modifiedAt': '2026-07-30T00:01:00.000Z',
      'recencyAt': '2026-07-30T00:02:00.000Z',
      'availability': 'durable',
    });

    final session = entry.toRecentSession(codexSourceId: 'source-1');
    expect(session.codexModel, 'gpt-5.6-sol');
    expect(session.codexSettingsSnapshotComplete, isFalse);
  });

  test('does not treat malformed Desktop grouping as a complete clear', () {
    final entry = ConversationSyncV2CatalogEntry.fromJson(<String, dynamic>{
      'provider': 'codex',
      'providerSessionId': 'thread-malformed-project',
      'revision': 'revision-malformed-project',
      'projectPath': '/workspace',
      'projectGroupKind': 'desktopProject',
      'projectGroupingSnapshotComplete': true,
      'createdAt': '2026-07-30T00:00:00.000Z',
      'modifiedAt': '2026-07-30T00:01:00.000Z',
      'recencyAt': '2026-07-30T00:02:00.000Z',
      'availability': 'durable',
    });

    expect(entry.projectGroupingSnapshotComplete, isFalse);
    expect(
      RecentSession.fromJson({
        ...entry.toRecentSession(codexSourceId: 'source-1').toJson(),
        'projectGroupingSnapshotComplete': true,
      }).projectGroupingSnapshotComplete,
      isFalse,
    );

    final legacy = RecentSession.fromJson({
      ...entry.toRecentSession(codexSourceId: 'source-1').toJson(),
      'projectGroupKind': 'desktopProject',
      'projectGroupId': 7,
      'projectGroupName': ['not', 'a', 'string'],
      'projectGroupPath': {'path': '/workspace'},
      'projectGroupingSnapshotComplete': true,
    });
    expect(legacy.projectGroupId, isNull);
    expect(legacy.projectGroupName, isNull);
    expect(legacy.projectGroupPath, isNull);
    expect(legacy.projectGroupingSnapshotComplete, isFalse);
  });

  test('builds a bounded subscription without endpoint identity', () {
    final message = conversationSyncV2Subscribe(
      requestId: 'request-1',
      catalogState: 'catalog-1',
      statusState: 'status-1',
      threadContentStates: [
        const ConversationSyncV2ThreadState(
          provider: 'codex',
          providerSessionId: 'thread-1',
          revision: 'revision-1',
        ),
      ],
      readWatermarks: [
        const ConversationSyncV2ReadWatermark(
          provider: 'codex',
          providerSessionId: 'thread-1',
          readAt: '2026-07-30T00:00:00.000Z',
        ),
      ],
    );

    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    expect(json['type'], 'conversation_sync_subscribe');
    expect(json['protocolVersion'], 2);
    expect(json['threadContentStates'], hasLength(1));
    expect(json, isNot(contains('host')));
    expect(json, isNot(contains('ip')));
  });

  test('builds an ephemeral per-subscription read watermark', () {
    final message = conversationSyncV2Read(
      subscriptionId: 'subscription-1',
      watermark: const ConversationSyncV2ReadWatermark(
        provider: 'codex',
        providerSessionId: 'thread-1',
        readAt: '2026-07-30T00:00:00.000Z',
      ),
    );

    expect(
      jsonDecode(message.toJson()),
      containsPair('type', 'conversation_sync_read'),
    );
    expect(message.delivery, ClientMessageDelivery.ephemeral);
  });

  test('rejects malformed timeline pagination and oversized data', () {
    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'timeline_page',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'revision': 'revision-1',
        'mode': 'snapshot',
        'pageIndex': 1,
        'pageCount': 1,
        'entries': const [],
        'deletes': const [],
        'hasEarlier': false,
        'sourceEntryCount': 0,
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'timeline_page',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'revision': 'revision-1',
        'mode': 'snapshot',
        'phase': 'priority',
        'timelineIndex': 1,
        'pageIndex': 0,
        'pageCount': 1,
        'entries': const [],
        'deletes': const [],
        'hasEarlier': false,
        'sourceEntryCount': 0,
      }),
      throwsFormatException,
    );
    final positioned =
        ServerMessage.fromJson({
              ..._baseFrame,
              'event': 'timeline_page',
              'provider': 'codex',
              'providerSessionId': 'thread-1',
              'revision': 'revision-1',
              'mode': 'snapshot',
              'phase': 'priority',
              'timelineIndex': 1,
              'timelineCount': 3,
              'pageIndex': 0,
              'pageCount': 1,
              'entries': const [],
              'deletes': const [],
              'hasEarlier': false,
              'sourceEntryCount': 0,
            })
            as ConversationSyncV2EventMessage;
    expect(positioned.timelineIndex, 1);
    expect(positioned.timelineCount, 3);
    for (final timelineCount in const [4096, 4097, 10000]) {
      final boundary =
          ServerMessage.fromJson({
                ..._baseFrame,
                'event': 'timeline_page',
                'provider': 'codex',
                'providerSessionId': 'thread-1',
                'revision': 'revision-1',
                'mode': 'snapshot',
                'phase': 'priority',
                'timelineIndex': timelineCount - 1,
                'timelineCount': timelineCount,
                'pageIndex': 0,
                'pageCount': 1,
                'entries': const [],
                'deletes': const [],
                'hasEarlier': false,
                'sourceEntryCount': 0,
              })
              as ConversationSyncV2EventMessage;
      expect(boundary.timelineCount, timelineCount);
    }
    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'timeline_page',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'revision': 'revision-1',
        'mode': 'snapshot',
        'phase': 'priority',
        'timelineIndex': 10000,
        'timelineCount': 10001,
        'pageIndex': 0,
        'pageCount': 1,
        'entries': const [],
        'deletes': const [],
        'hasEarlier': false,
        'sourceEntryCount': 0,
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'turns_page_response',
        'requestId': 'request-1',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'data': List<Object?>.filled(201, const {}),
        'nextCursor': null,
      }),
      throwsFormatException,
    );
  });

  test('decodes latest-turn repair metadata without reusing older cursor', () {
    final message =
        ServerMessage.fromJson({
              ..._baseFrame,
              'event': 'timeline_page',
              'provider': 'codex',
              'providerSessionId': 'thread-1',
              'revision': 'revision-1',
              'mode': 'snapshot',
              'pageIndex': 0,
              'pageCount': 1,
              'entries': const [],
              'deletes': const [],
              'hasEarlier': true,
              'turnsNextCursor': 'older-turns',
              'latestTurnComplete': false,
              'latestTurnGap': const {
                'turnId': 'turn-current',
                'missingEntryCount': 3,
                'payloadOmitted': true,
                'firstMissingSourceIndex': 41,
                'repair': 'items_page',
              },
              'sourceEntryCount': 44,
            })
            as ConversationSyncV2EventMessage;

    expect(message.turnsNextCursor, 'older-turns');
    expect(message.latestTurnComplete, isFalse);
    expect(message.latestTurnGap?.turnId, 'turn-current');
    expect(message.latestTurnGap?.repair, 'items_page');
    expect(message.latestTurnGap?.firstMissingSourceIndex, 41);
    expect(message.windowComplete, isNull);
    expect(message.effectiveWindowComplete, isFalse);

    final complete =
        ServerMessage.fromJson({
              ..._baseFrame,
              'event': 'timeline_page',
              'provider': 'codex',
              'providerSessionId': 'thread-1',
              'revision': 'revision-complete',
              'mode': 'snapshot',
              'pageIndex': 0,
              'pageCount': 1,
              'entries': const [],
              'deletes': const [],
              'hasEarlier': false,
              'windowComplete': true,
              'latestTurnComplete': true,
              'sourceEntryCount': 0,
            })
            as ConversationSyncV2EventMessage;
    expect(complete.effectiveWindowComplete, isTrue);

    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'timeline_page',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'revision': 'revision-contradictory',
        'mode': 'snapshot',
        'pageIndex': 0,
        'pageCount': 1,
        'entries': const [],
        'deletes': const [],
        'hasEarlier': true,
        'windowComplete': true,
        'latestTurnComplete': false,
        'latestTurnGap': const {
          'missingEntryCount': 1,
          'payloadOmitted': false,
          'repair': 'turns_page',
        },
        'sourceEntryCount': 1,
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'timeline_page',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'revision': 'revision-1',
        'mode': 'snapshot',
        'pageIndex': 0,
        'pageCount': 1,
        'entries': const [],
        'deletes': const [],
        'hasEarlier': true,
        'latestTurnComplete': false,
        'latestTurnGap': const {
          'missingEntryCount': 1,
          'payloadOmitted': false,
          'repair': 'items_page',
        },
        'sourceEntryCount': 1,
      }),
      throwsFormatException,
    );
  });

  test('decodes bounded item projection completeness metadata', () {
    final message =
        ServerMessage.fromJson({
              ..._baseFrame,
              'event': 'items_page_response',
              'requestId': 'items-bounded',
              'provider': 'codex',
              'providerSessionId': 'thread-1',
              'turnId': 'turn-1',
              'data': const [
                {'type': 'user_input', 'text': 'bounded'},
              ],
              'nextCursor': 'after-bounded',
              'pageComplete': false,
              'latestTurnGap': const {
                'turnId': 'turn-1',
                'missingEntryCount': 0,
                'payloadOmitted': true,
                'repair': 'items_page',
              },
            })
            as ConversationSyncV2EventMessage;
    expect(message.pageComplete, isFalse);
    expect(message.latestTurnGap?.payloadOmitted, isTrue);
  });

  test('validates normalized messages inside turn page responses', () {
    final message =
        ServerMessage.fromJson({
              ..._baseFrame,
              'event': 'turns_page_response',
              'requestId': 'request-1',
              'provider': 'codex',
              'providerSessionId': 'thread-1',
              'data': [
                {
                  'turnId': 'turn-1',
                  'messages': [
                    {
                      'type': 'user_input',
                      'text': 'Earlier prompt',
                      'userMessageUuid': 'user-earlier',
                    },
                  ],
                  'itemCount': 1,
                  'itemsView': 'summary',
                },
              ],
              'nextCursor': 'cursor-2',
            })
            as ConversationSyncV2EventMessage;

    expect(message.pageRawMessages().single['text'], 'Earlier prompt');
    expect(
      () => ServerMessage.fromJson({
        ..._baseFrame,
        'event': 'turns_page_response',
        'requestId': 'request-2',
        'provider': 'codex',
        'providerSessionId': 'thread-1',
        'data': [
          {
            'turnId': 'turn-bad',
            'messages': ['not-a-message-map'],
          },
        ],
        'nextCursor': null,
      }),
      throwsFormatException,
    );
  });
}

const _baseFrame = <String, dynamic>{
  'type': conversationSyncV2Capability,
  'subscriptionId': 'subscription-1',
  'bridgeInstanceId': 'bridge-1',
  'codexSourceId': 'source-1',
  'batchId': 'batch-1',
  'sequence': 1,
};
