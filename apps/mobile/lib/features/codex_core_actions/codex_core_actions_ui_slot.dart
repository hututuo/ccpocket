import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../local_session_features/host/local_session_feature.dart';
import 'codex_core_actions_panel.dart';
import 'codex_core_actions_strings.dart';

final LocalSessionFeatureSlot codexCoreActionsUiSlot =
    _CodexCoreActionsUiSlot();

class _CodexCoreActionsUiSlot extends LocalSessionFeatureSlot {
  @override
  String get featureId => 'codex_core_actions';

  @override
  List<SessionMenuAction> overflowActions(CodexSessionFeatureContext context) =>
      context.durableCacheIdentityConfirmed &&
          context.runtimeMutationSessionId == null
      ? const []
      : [
          SessionMenuAction(
            featureId: featureId,
            label: CodexCoreActionsStrings.of(context.context).title,
            icon: Icons.construction_outlined,
            order: 15,
          ),
        ];

  @override
  WorkspaceFeaturePaneDescriptor get paneDescriptor =>
      WorkspaceFeaturePaneDescriptor(
        featureId: featureId,
        title: (context) => CodexCoreActionsStrings.of(context).title,
        builder: (context) {
          final durableRoute = context.arguments['durableRoute'] == true;
          final staticRuntimeSessionId =
              context.arguments['runtimeSessionId'] as String?;
          final resolverValue = context.arguments['runtimeSessionIdResolver'];
          final runtimeSessionIdResolver = resolverValue is String? Function()
              ? resolverValue
              : null;
          final revisionValue = context.arguments['runtimeRevisionListenable'];
          final runtimeRevisionListenable =
              revisionValue is ValueListenable<int> ? revisionValue : null;

          Widget buildForCurrentRuntime() {
            final runtimeSessionId = runtimeSessionIdResolver != null
                ? runtimeSessionIdResolver()
                : staticRuntimeSessionId;
            if (durableRoute && runtimeSessionId == null) {
              return Center(
                child: Text(CodexCoreActionsStrings.of(context.context).failed),
              );
            }
            final effectiveSessionId = runtimeSessionId ?? context.sessionId;
            return CodexCoreActionsPanel(
              key: ValueKey('codex-core-actions-$effectiveSessionId'),
              sessionId: effectiveSessionId,
              bridge: context.bridge,
              initialSection: context.arguments['section'] as String?,
              sessionIdIsCurrent: runtimeSessionIdResolver == null
                  ? null
                  : (candidate) => runtimeSessionIdResolver() == candidate,
            );
          }

          if (runtimeRevisionListenable == null) {
            return buildForCurrentRuntime();
          }
          return ValueListenableBuilder<int>(
            valueListenable: runtimeRevisionListenable,
            builder: (_, _, _) => buildForCurrentRuntime(),
          );
        },
        rememberPerSession: false,
      );
}
