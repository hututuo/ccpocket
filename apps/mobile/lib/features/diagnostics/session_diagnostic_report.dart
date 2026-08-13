import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:uuid/uuid.dart';

import '../../models/messages.dart';
import '../../models/bridge_data_source_identity.dart';
import '../../services/bridge_service.dart';
import '../chat_session/state/chat_session_cubit.dart';
import '../chat_session/state/chat_session_state.dart';
import '../chat_session/widgets/chat_message_list.dart';
import '../conversation_content_sync/conversation_content_sync_service.dart';
import '../file_browser/file_mutation_authorization.dart';
import '../file_transfer/file_transfer_service.dart';
import '../session_list/cache/session_catalog_cache_repository.dart';
import '../session_list/state/session_list_cubit.dart';
import 'diagnostic_sanitizer.dart';
import 'home_diagnostic_projection.dart';

const _diagnosticReportUuid = Uuid();
const _maximumDiagnosticReportBytes = 16 * 1024 * 1024;
const _diagnosticCaptureTimeout = Duration(seconds: 20);
final _activeDiagnosticReports = <String>{};

Future<void> uploadCurrentSessionDiagnosticReport({
  required BuildContext context,
  required String provider,
  required String providerSessionId,
  required bool detachedPreview,
  required BridgeDataSourceIdentity expectedDataSourceIdentity,
  required ChatMessageListDiagnosticController presentation,
}) async {
  final service = context.read<FileTransferService>();
  final messenger = ScaffoldMessenger.of(context);
  if (!service.diagnosticReportsSupportedByBridge) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('当前连接未提供会话诊断能力；请使用密钥或已配对设备连接，并确认 Bridge 已更新。'),
      ),
    );
    return;
  }
  final bridgeId = expectedDataSourceIdentity.bridgeInstanceId?.trim();
  final sourceId = expectedDataSourceIdentity.codexSourceId?.trim();
  final durableSessionId = providerSessionId.trim();
  if (bridgeId == null ||
      bridgeId.isEmpty ||
      durableSessionId.isEmpty ||
      sourceId == null ||
      sourceId.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('持久会话或数据源身份尚未确认，暂不能上报诊断。')),
    );
    return;
  }
  final flightKey =
      '$bridgeId\u0000$sourceId\u0000$provider\u0000$durableSessionId';
  if (!_activeDiagnosticReports.add(flightKey)) {
    messenger.showSnackBar(const SnackBar(content: Text('这个会话的诊断报告正在采集或上传。')));
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text('正在采集真实会话状态并上传到 Mac…'),
        duration: Duration(minutes: 2),
      ),
    );
  try {
    final builder = SessionDiagnosticReportBuilder(
      bridge: context.read<BridgeService>(),
      sessionList: context.read<SessionListCubit>(),
      chatSession: context.read<ChatSessionCubit>(),
      contentSync: context.read<ConversationContentSyncService>(),
      cache: context.read<SessionCatalogCacheRepository>(),
      packageInfoLoader: PackageInfo.fromPlatform,
    );
    final report = await builder.build(
      provider: provider,
      providerSessionId: durableSessionId,
      detachedPreview: detachedPreview,
      expectedDataSourceIdentity: expectedDataSourceIdentity,
      presentation: presentation,
    );
    final bytes = Uint8List.fromList(utf8.encode(report.json));
    if (bytes.length > _maximumDiagnosticReportBytes) {
      throw StateError('诊断快照为 ${bytes.length} bytes，超过 16 MiB 安全上限。');
    }
    if (!context.mounted) return;
    final ticket = await service.enqueueDiagnosticReport(
      filename: report.filename,
      bytes: Stream<List<int>>.value(bytes),
      expectedSizeBytes: bytes.length,
      metadata: <String, Object?>{
        'schemaVersion': 1,
        'reportId': report.reportId,
        'provider': provider,
        'providerSessionId': durableSessionId,
        'bridgeInstanceId': report.bridgeInstanceId,
        'codexSourceId': report.codexSourceId,
        'capturedAtStart': report.capturedAtStart,
        'capturedAtEnd': report.capturedAtEnd,
        'sha256': sha256.convert(bytes).toString(),
      },
      authorizeMutation: service.diagnosticReportMutationAuthRequired
          ? (operation) {
              if (!context.mounted) return Future.value(null);
              return requestFileMutationAuthorization(context, operation);
            }
          : null,
    );
    final result = await ticket.completion;
    if (!context.mounted) return;
    if (result.status != FileTransferStatus.succeeded) {
      final detail = result.error ?? result.errorCode ?? result.status.name;
      throw FileTransferException(
        result.errorCode ?? 'diagnostic_upload_${result.status.name}',
        detail,
      );
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '诊断已上传：${report.reportId}\n'
            'Mac 路径：${result.savedPath ?? result.savedFilename ?? '已保存'}',
          ),
          duration: const Duration(seconds: 12),
        ),
      );
  } catch (error) {
    if (!context.mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('诊断上报失败：$error'),
          duration: const Duration(seconds: 10),
        ),
      );
  } finally {
    _activeDiagnosticReports.remove(flightKey);
  }
}

class SessionDiagnosticReportBuildResult {
  const SessionDiagnosticReportBuildResult({
    required this.reportId,
    required this.filename,
    required this.capturedAtStart,
    required this.capturedAtEnd,
    required this.json,
    required this.bridgeInstanceId,
    required this.codexSourceId,
  });

  final String reportId;
  final String filename;
  final String capturedAtStart;
  final String capturedAtEnd;
  final String json;
  final String bridgeInstanceId;
  final String codexSourceId;
}

class SessionDiagnosticReportBuilder {
  const SessionDiagnosticReportBuilder({
    required this.bridge,
    required this.sessionList,
    required this.chatSession,
    required this.contentSync,
    required this.cache,
    required this.packageInfoLoader,
  });

  final BridgeService bridge;
  final SessionListCubit sessionList;
  final ChatSessionCubit chatSession;
  final ConversationContentSyncService contentSync;
  final SessionCatalogCacheRepository cache;
  final Future<PackageInfo> Function() packageInfoLoader;

  Future<SessionDiagnosticReportBuildResult> build({
    required String provider,
    required String providerSessionId,
    required bool detachedPreview,
    required BridgeDataSourceIdentity expectedDataSourceIdentity,
    required ChatMessageListDiagnosticController presentation,
  }) async {
    final start = DateTime.now().toUtc();
    final reportId =
        'ccp-${start.microsecondsSinceEpoch}-'
        '${_diagnosticReportUuid.v4().substring(0, 8)}';
    final identity = contentSync.currentDataSourceIdentity;
    if (!expectedDataSourceIdentity.isSatisfiedBy(
          identity,
          provider: provider,
        ) ||
        !diagnosticDataSourceIdentityMatchesExact(
          expectedDataSourceIdentity,
          identity,
        )) {
      throw StateError('会话数据源已切换，请返回列表重新打开会话后再上报。');
    }
    final bridgeInstanceId = identity.bridgeInstanceId?.trim();
    final codexSourceId = identity.codexSourceId?.trim();
    if (bridgeInstanceId == null ||
        bridgeInstanceId.isEmpty ||
        codexSourceId == null ||
        codexSourceId.isEmpty) {
      throw StateError('Bridge 或数据源身份尚未确认。');
    }
    final presentationAtStart = presentation.capture();
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: identity.bridgeInstanceId,
      codexSourceId: identity.codexSourceId,
      logicalConnectionIdentity: bridge.logicalConnectionIdentity,
      websocketUrl: bridge.lastUrl,
    );
    final beforeEpoch = contentSync.cacheCommitEpochFor(
      targetFingerprint: target.fingerprint,
      provider: provider,
      providerSessionId: providerSessionId,
    );
    final results =
        await Future.wait<Object?>([
          cache.loadConversationDiagnosticWindow(
            target: target,
            provider: provider,
            providerSessionId: providerSessionId,
          ),
          cache.loadConversationSyncState(target),
          cache.loadConversationStatus(
            target: target,
            provider: provider,
            providerSessionId: providerSessionId,
          ),
          cache.loadReadWatermark(
            target: target,
            provider: provider,
            providerSessionId: providerSessionId,
          ),
          cache.cacheStatsForTarget(target),
          packageInfoLoader(),
          presentation.observeTemporalChanges(),
        ]).timeout(
          _diagnosticCaptureTimeout,
          onTimeout: () => throw TimeoutException(
            '会话诊断状态采集超过 ${_diagnosticCaptureTimeout.inSeconds} 秒，请重试。',
          ),
        );
    if (!expectedDataSourceIdentity.isSatisfiedBy(
          contentSync.currentDataSourceIdentity,
          provider: provider,
        ) ||
        !diagnosticDataSourceIdentityMatchesExact(
          expectedDataSourceIdentity,
          contentSync.currentDataSourceIdentity,
        )) {
      throw StateError('采集过程中会话数据源发生变化，请重试。');
    }
    final endIdentity = contentSync.currentDataSourceIdentity;
    if (endIdentity.bridgeInstanceId?.trim() != bridgeInstanceId ||
        endIdentity.codexSourceId?.trim() != codexSourceId) {
      throw StateError('采集过程中 Bridge 或数据源身份发生变化，请重试。');
    }
    final window = results[0] as Map<String, Object?>?;
    final syncState = results[1] as ConversationSyncCacheState;
    final status = results[2] as ConversationSyncV2Status?;
    final watermark = results[3] as ConversationSyncV2ReadWatermark?;
    final stats = results[4] as SessionCatalogCacheStats;
    final packageInfo = results[5] as PackageInfo;
    final presentationTemporal = results[6] as Map<String, Object?>;
    final presentationAtEnd = presentation.capture();
    final end = DateTime.now().toUtc();
    final afterEpoch = contentSync.cacheCommitEpochFor(
      targetFingerprint: target.fingerprint,
      provider: provider,
      providerSessionId: providerSessionId,
    );
    final catalog = sessionList.conversationMetadataFor(
      provider,
      providerSessionId,
    );
    final exactStatus = status == null
        ? const <Map<String, dynamic>>[]
        : <Map<String, dynamic>>[status.toJson()];
    final listMatches = <Map<String, Object?>>[
      for (var index = 0; index < sessionList.state.sessions.length; index++)
        if ((sessionList.state.sessions[index].provider ??
                    Provider.claude.value) ==
                provider &&
            sessionList.state.sessions[index].sessionId == providerSessionId)
          <String, Object?>{
            'index': index,
            'session': sessionList.state.sessions[index].toJson(),
          },
    ];
    final chatState = chatSession.state;
    final homeProjection = HomeDiagnosticProjectionRegistry.instance.capture(
      bridgeInstanceId: bridgeInstanceId,
      codexSourceId: codexSourceId,
      provider: provider,
      providerSessionId: providerSessionId,
    );
    final presentationRevisionBefore =
        presentationAtStart['presentationRevision'];
    final presentationRevisionAfter = presentationAtEnd['presentationRevision'];
    final presentationAvailableAtStart =
        presentationAtStart['available'] == true;
    final presentationAvailableAtEnd = presentationAtEnd['available'] == true;
    final presentationStable = diagnosticPresentationCaptureStable(
      presentationAtStart,
      presentationAtEnd,
    );
    final noObservedPresentationChanges =
        presentationTemporal['noObservedChanges'] == true;
    final report = <String, Object?>{
      'schemaVersion': 1,
      'reportId': reportId,
      'capture': <String, Object?>{
        'startedAt': start.toIso8601String(),
        'endedAt': end.toIso8601String(),
        'stable':
            beforeEpoch == afterEpoch &&
            presentationStable &&
            noObservedPresentationChanges,
        'endpointEqual': presentationStable,
        'noObservedPresentationChanges': noObservedPresentationChanges,
        'cacheCommitEpochBefore': beforeEpoch,
        'cacheCommitEpochAfter': afterEpoch,
        'presentationAvailableAtStart': presentationAvailableAtStart,
        'presentationAvailableAtEnd': presentationAvailableAtEnd,
        'presentationUnavailableReasonAtStart': presentationAtStart['reason'],
        'presentationUnavailableReasonAtEnd': presentationAtEnd['reason'],
        'presentationRevisionBefore': presentationRevisionBefore,
        'presentationRevisionAfter': presentationRevisionAfter,
        'temporalPresentation': presentationTemporal,
      },
      'target': <String, Object?>{
        'provider': provider,
        'providerSessionId': providerSessionId,
        'detachedPreview': detachedPreview,
        'projectPath': chatState.projectPath,
      },
      'mobile': <String, Object?>{
        'app': <String, Object?>{
          'version': packageInfo.version,
          'buildNumber': packageInfo.buildNumber,
          'packageName': packageInfo.packageName,
        },
        'infrastructure': <String, Object?>{
          'connectionState': bridge.currentBridgeConnectionState.name,
          'transportHealthy': bridge.isTransportHealthy,
          'bootstrapPhase': bridge.currentConnectionBootstrap.phase.name,
          'connectionEpoch': bridge.currentConnectionBootstrap.connectionEpoch,
          'bridgeInstanceId': bridgeInstanceId,
          'codexSourceId': codexSourceId,
          'bridgeVersion': bridge.bridgeVersion,
          'clientBridgeCompatibilityRevision':
              bridge.clientBridgeCompatibilityRevision,
          'authoritativeSessionListGeneration':
              bridge.authoritativeSessionListGeneration,
          'authoritativeSessionList':
              bridge.hasAuthoritativeSessionListForCurrentConnection,
          'authoritativeRecentSessions':
              bridge.hasAuthoritativeRecentSessionsForCurrentConnection,
          'capabilities': bridge.bridgeCapabilities.toList()..sort(),
        },
        'listProjection': <String, Object?>{
          'state': <String, Object?>{
            'sessionCount': sessionList.state.sessions.length,
            'hasMore': sessionList.state.hasMore,
            'isLoadingMore': sessionList.state.isLoadingMore,
            'isInitialLoading': sessionList.state.isInitialLoading,
            'searchQuery': sessionList.state.searchQuery,
            'selectedProjectKey': sessionList.state.selectedProjectKey,
            'providerFilter': sessionList.state.providerFilter.name,
            'namedOnly': sessionList.state.namedOnly,
            'pinned':
                catalog != null &&
                sessionList.state.pinnedSessionKeys.contains(
                  recentSessionPinKey(catalog),
                ),
          },
          'catalogSession': catalog?.toJson(),
          'matchingCubitRows': listMatches,
          'actualHomeProjection': homeProjection,
          'sourceFingerprint': sessionList.conversationSourceFingerprint,
          'usableCatalog': sessionList.hasUsableCatalogForCurrentTarget,
          'cachedCatalog': sessionList.hasCachedCatalogForCurrentTarget,
          'conversationStatus': exactStatus,
          'unread': sessionList.unreadConversationKeys.contains(
            '$provider\u0000$providerSessionId',
          ),
        },
        'sessionProjection': <String, Object?>{
          'state': _diagnosticChatState(chatState),
          'runtime': chatSession.diagnosticRuntimeProjection,
          'presentation': presentationAtStart,
          'presentationAtStart': presentationAtStart,
          'presentationAtEnd': presentationAtEnd,
        },
        'sync': contentSync.diagnosticSnapshot(
          provider: provider,
          providerSessionId: providerSessionId,
        ),
        'sqlite': <String, Object?>{
          'targetFingerprint': target.fingerprint,
          'stats': <String, Object?>{
            'sessionSummaries': stats.sessionSummaries,
            'conversationWindows': stats.conversationWindows,
          },
          'syncState': <String, Object?>{
            'catalogState': syncState.catalogState,
            'statusState': syncState.statusState,
            'priorityReady': syncState.priorityReady,
            'updatedAt': syncState.updatedAt?.toIso8601String(),
          },
          'targetStatuses': exactStatus,
          'targetReadWatermarks': watermark == null
              ? const <Map<String, dynamic>>[]
              : <Map<String, dynamic>>[watermark.toJson()],
          'window': window,
        },
      },
    };
    final sanitized = sanitizeDiagnosticValue(report);
    final sanitizedReport = <String, Object?>{
      ...(sanitized.value! as Map<String, Object?>),
      'sanitization': <String, Object?>{
        'credentialRedactions': sanitized.redactedCredentialCount,
        'truncatedValues': sanitized.truncatedValueCount,
        'visitedNodes': sanitized.visitedNodeCount,
      },
    };
    return SessionDiagnosticReportBuildResult(
      reportId: reportId,
      filename: '$reportId.json',
      capturedAtStart: start.toIso8601String(),
      capturedAtEnd: end.toIso8601String(),
      bridgeInstanceId: bridgeInstanceId,
      codexSourceId: codexSourceId,
      json: '${jsonEncode(sanitizedReport)}\n',
    );
  }
}

@visibleForTesting
bool diagnosticDataSourceIdentityMatchesExact(
  BridgeDataSourceIdentity expected,
  BridgeDataSourceIdentity current,
) {
  final expectedBridgeId = expected.bridgeInstanceId?.trim();
  final expectedSourceId = expected.codexSourceId?.trim();
  return expectedBridgeId != null &&
      expectedBridgeId.isNotEmpty &&
      expectedSourceId != null &&
      expectedSourceId.isNotEmpty &&
      current.bridgeInstanceId?.trim() == expectedBridgeId &&
      current.codexSourceId?.trim() == expectedSourceId;
}

@visibleForTesting
bool diagnosticPresentationCaptureStable(
  Map<String, Object?> before,
  Map<String, Object?> after,
) {
  final beforeRevision = before['presentationRevision'];
  final afterRevision = after['presentationRevision'];
  return before['available'] == true &&
      after['available'] == true &&
      beforeRevision is String &&
      beforeRevision.isNotEmpty &&
      afterRevision is String &&
      beforeRevision == afterRevision;
}

Map<String, Object?> _diagnosticChatState(ChatSessionState state) =>
    <String, Object?>{
      'status': state.status.name,
      'entryCount': state.entries.length,
      'capturedEntryStableKeyCount': state.entries.length.clamp(0, 1024),
      'omittedEntryStableKeyCount': state.entries.length > 1024
          ? state.entries.length - 1024
          : 0,
      'entryStableKeys': [
        for (final entry in state.entries.skip(
          state.entries.length > 1024 ? state.entries.length - 1024 : 0,
        ))
          chatMessageEntryStableKey(entry),
      ],
      'pastHistoryLoaded': state.pastHistoryLoaded,
      'bulkLoading': state.bulkLoading,
      'sessionUnavailable': state.sessionUnavailable,
      'externalDesktopTurnActive': state.externalDesktopTurnActive,
      'externalDesktopTurnId': state.externalDesktopTurnId,
      'claudeSessionId': state.claudeSessionId,
      'projectPath': state.projectPath,
      'gitBranch': state.gitBranch,
      'permissionMode': state.permissionMode.name,
      'executionMode': state.executionMode.name,
      'sandboxMode': state.sandboxMode.name,
      'codexPermissionStateKnown': state.codexPermissionStateKnown,
      'codexApprovalPolicy': state.codexApprovalPolicy.name,
      'codexApprovalsReviewer': state.codexApprovalsReviewer,
      'codexPermissionsMode': state.codexPermissionsMode.name,
      'codexModel': state.codexModel,
      'codexModelReasoningEffort': state.codexModelReasoningEffort?.value,
      'codexSpeed': state.codexSpeed.name,
      'planMode': state.planMode,
      'nativePlanSupport': state.codexNativePlanModeSupport.name,
      'queuedInput': state.queuedInput == null
          ? null
          : <String, Object?>{
              'itemId': state.queuedInput!.itemId,
              'text': state.queuedInput!.text,
              'clientMessageId': state.queuedInput!.clientMessageId,
              'deliveryStage': state.queuedInput!.deliveryStage?.wireValue,
            },
      'approval': switch (state.approval) {
        ApprovalNone() => const <String, Object?>{'kind': 'none'},
        ApprovalPermission() => <String, Object?>{
          'kind': 'permission',
          'toolUseId': (state.approval as ApprovalPermission).toolUseId,
          'toolName': (state.approval as ApprovalPermission).request.toolName,
          'input': (state.approval as ApprovalPermission).request.input,
        },
        ApprovalAskUser() => <String, Object?>{
          'kind': 'askUser',
          'toolUseId': (state.approval as ApprovalAskUser).toolUseId,
          'input': (state.approval as ApprovalAskUser).input,
        },
        _ => <String, Object?>{'kind': state.approval.runtimeType.toString()},
      },
      'goal': state.goal == null
          ? null
          : <String, Object?>{
              'threadId': state.goal!.threadId,
              'objective': state.goal!.objective,
              'status': state.goal!.effectiveStatus,
              'tokenBudget': state.goal!.tokenBudget,
              'tokensUsed': state.goal!.tokensUsed,
              'updatedAt': state.goal!.updatedAt,
            },
      'goalStateLoaded': state.goalStateLoaded,
      'goalSupport': state.goalSupport.name,
      'goalMutationError': state.goalMutationError,
      'totalCost': state.totalCost,
      'totalDurationMicros': state.totalDuration?.inMicroseconds,
    };
