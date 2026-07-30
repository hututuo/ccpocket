import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../l10n/app_localizations.dart';
import '../../models/bridge_data_source_identity.dart';
import '../../models/messages.dart';
import '../../router/app_router.dart';
import '../../router/session_stack_navigation.dart';
import '../../services/bridge_service.dart';
import 'state/session_link_cubit.dart';
import 'state/session_link_state.dart';
import 'widgets/session_unavailable_view.dart';

@RoutePage()
class SessionLinkScreen extends StatelessWidget {
  const SessionLinkScreen({
    super.key,
    required this.sessionId,
    this.provider = 'claude',
    this.providerSessionId,
    this.bridgeInstanceId,
    this.codexSourceId,
    this.bridgeRouteIdentity,
  });

  final String sessionId;
  final String provider;
  final String? providerSessionId;
  final String? bridgeInstanceId;
  final String? codexSourceId;
  final String? bridgeRouteIdentity;

  @override
  Widget build(BuildContext context) {
    final expectedDataSourceIdentity =
        BridgeDataSourceIdentity.fromMap(<String, String?>{
          'bridgeInstanceId': bridgeInstanceId,
          'codexSourceId': codexSourceId,
          'bridgeRouteIdentity': bridgeRouteIdentity,
        });
    final durableSessionId = providerSessionId?.trim();
    return BlocProvider(
      create: (context) => SessionLinkCubit(
        bridge: context.read<BridgeService>(),
        sourceSessionId: durableSessionId?.isNotEmpty == true
            ? durableSessionId!
            : sessionId,
        provider: provider,
        expectedDataSourceIdentity: expectedDataSourceIdentity,
      )..resolve(),
      child: _SessionLinkScreenBody(
        sourceSessionId: sessionId,
        provider: provider,
        providerSessionId: durableSessionId?.isNotEmpty == true
            ? durableSessionId
            : null,
        expectedDataSourceIdentity: expectedDataSourceIdentity,
      ),
    );
  }
}

class _SessionLinkScreenBody extends StatelessWidget {
  const _SessionLinkScreenBody({
    required this.sourceSessionId,
    required this.provider,
    required this.providerSessionId,
    required this.expectedDataSourceIdentity,
  });

  final String sourceSessionId;
  final String provider;
  final String? providerSessionId;
  final BridgeDataSourceIdentity expectedDataSourceIdentity;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SessionLinkCubit, SessionLinkState>(
      listenWhen: (_, state) => switch (state) {
        SessionLinkOpenLive() ||
        SessionLinkOpenResumed() ||
        SessionLinkOpenLegacy() => true,
        _ => false,
      },
      listener: (context, state) {
        switch (state) {
          case SessionLinkOpenLive(:final bridgeSessionId, :final provider):
            _openSession(
              context,
              sessionId: bridgeSessionId,
              provider: provider,
              durableProviderSessionId: providerSessionId,
            );
          case SessionLinkOpenResumed(:final session, :final gitBranch):
            _openSession(
              context,
              sessionId: session.sessionId!,
              provider: session.provider ?? provider,
              projectPath: session.projectPath,
              worktreePath: session.worktreePath,
              gitBranch: session.worktreeBranch ?? gitBranch,
              permissionMode: session.permissionMode,
              sandboxMode: session.sandboxMode,
              approvalPolicy: session.approvalPolicy,
              approvalsReviewer: session.approvalsReviewer,
              durableProviderSessionId:
                  session.claudeSessionId ?? providerSessionId,
            );
          case SessionLinkOpenLegacy():
            _openSession(
              context,
              sessionId: sourceSessionId,
              provider: provider,
              durableProviderSessionId: providerSessionId,
            );
          default:
            return;
        }
      },
      builder: (context, state) {
        final isUnavailable = state is SessionLinkUnavailable;
        final cubit = context.read<SessionLinkCubit>();
        return StreamBuilder<SessionLinkProgressMessage>(
          key: ValueKey('session_link_progress_attempt_${cubit.attempt}'),
          stream: cubit.progress,
          initialData: cubit.currentProgress,
          builder: (context, progress) => SessionLinkStatusView(
            unavailable: isUnavailable,
            resuming: state is SessionLinkResuming,
            progress: progress.data,
            diagnosticCode: cubit.lastFailureCode,
            onRetry: isUnavailable ? () => unawaited(cubit.retry()) : null,
            onBack: () {
              unawaited(
                context.router.maybePop().then((didPop) {
                  if (!didPop && context.mounted) {
                    context.router.replaceAll([AdaptiveHomeRoute()]);
                  }
                }),
              );
            },
            onOpenRecentSessions: () {
              context.router.replaceAll([AdaptiveHomeRoute()]);
            },
          ),
        );
      },
    );
  }

  void _openSession(
    BuildContext context, {
    required String sessionId,
    required String provider,
    String? projectPath,
    String? gitBranch,
    String? worktreePath,
    String? permissionMode,
    String? sandboxMode,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? durableProviderSessionId,
  }) {
    final normalizedProvider = provider == Provider.codex.value
        ? Provider.codex.value
        : Provider.claude.value;
    if (SessionStackNavigation.revealStackedSession(
      context.router,
      sessionId: sessionId,
      provider: normalizedProvider,
      dataSourceIdentity: expectedDataSourceIdentity,
    )) {
      return;
    }
    context.router.replace(
      _sessionRoute(
        sessionId: sessionId,
        provider: normalizedProvider,
        projectPath: projectPath,
        gitBranch: gitBranch,
        worktreePath: worktreePath,
        permissionMode: permissionMode,
        sandboxMode: sandboxMode,
        approvalPolicy: approvalPolicy,
        approvalsReviewer: approvalsReviewer,
        durableProviderSessionId: durableProviderSessionId,
      ),
    );
  }

  PageRouteInfo _sessionRoute({
    required String sessionId,
    required String provider,
    String? projectPath,
    String? gitBranch,
    String? worktreePath,
    String? permissionMode,
    String? sandboxMode,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? durableProviderSessionId,
  }) {
    if (provider == Provider.codex.value) {
      return CodexSessionRoute(
        sessionId: sessionId,
        projectPath: projectPath,
        gitBranch: gitBranch,
        worktreePath: worktreePath,
        initialPermissionMode: permissionMode,
        initialSandboxMode: sandboxMode,
        initialApprovalPolicy: approvalPolicy,
        initialApprovalsReviewer: approvalsReviewer,
        durableProviderSessionId: durableProviderSessionId,
        dataSourceIdentity: expectedDataSourceIdentity,
      );
    }
    return ClaudeSessionRoute(
      sessionId: sessionId,
      projectPath: projectPath,
      gitBranch: gitBranch,
      worktreePath: worktreePath,
      initialPermissionMode: permissionMode,
      initialSandboxMode: sandboxMode,
      durableProviderSessionId: durableProviderSessionId,
      dataSourceIdentity: expectedDataSourceIdentity,
    );
  }
}

class SessionLinkStatusView extends StatelessWidget {
  const SessionLinkStatusView({
    super.key,
    required this.unavailable,
    required this.resuming,
    this.progress,
    this.diagnosticCode,
    this.onRetry,
    this.onBack,
    required this.onOpenRecentSessions,
  });

  final bool unavailable;
  final bool resuming;
  final SessionLinkProgressMessage? progress;
  final String? diagnosticCode;
  final VoidCallback? onRetry;
  final VoidCallback? onBack;
  final VoidCallback onOpenRecentSessions;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final completedUnits = progress?.completedUnits;
    final totalUnits = progress?.totalUnits;
    final hasBoundedProgress =
        completedUnits != null &&
        totalUnits != null &&
        totalUnits > 0 &&
        completedUnits >= 0;
    final progressValue = hasBoundedProgress
        ? (completedUnits / totalUnits).clamp(0.0, 1.0)
        : null;
    final stageText = progress == null
        ? (resuming ? l.resumingLinkedSession : l.resolvingLinkedSession)
        : l.sessionLinkProgressStage(progress!.stage.wireValue);
    final detailedStageText = hasBoundedProgress
        ? '$stageText · $completedUnits / $totalUnits'
        : stageText;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: unavailable
                  ? SessionUnavailableView(
                      onOpenRecentSessions: onOpenRecentSessions,
                      onRetry: onRetry,
                      diagnosticText: [
                        if (progress != null) detailedStageText,
                        if (diagnosticCode != null) 'Code: $diagnosticCode',
                      ].join('\n'),
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (progressValue == null)
                              const CircularProgressIndicator.adaptive(
                                key: ValueKey(
                                  'session_link_progress_indicator',
                                ),
                              )
                            else
                              SizedBox(
                                width: 220,
                                child: LinearProgressIndicator(
                                  key: const ValueKey(
                                    'session_link_progress_indicator',
                                  ),
                                  value: progressValue,
                                ),
                              ),
                            const SizedBox(height: 16),
                            Text(
                              detailedStageText,
                              key: const ValueKey(
                                'session_link_progress_stage',
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            if (onBack != null)
              Positioned(
                left: 4,
                top: 4,
                child: BackButton(
                  key: const ValueKey('session_link_back_button'),
                  onPressed: onBack,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
