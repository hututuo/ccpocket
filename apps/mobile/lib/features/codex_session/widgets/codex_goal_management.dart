import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../chat_session/state/chat_session_cubit.dart';
import '../../chat_session/state/chat_session_state.dart';
import 'codex_goal_card.dart';

/// Self-contained mobile presentation layer for Codex Goal management.
///
/// Bridge protocol and authoritative state remain in [ChatSessionCubit], so
/// this module can be removed without changing the Goal transport contract.
abstract final class CodexGoalManagement {
  static bool _sameWritableGoal(CodexGoal? left, CodexGoal? right) {
    if (identical(left, right)) return true;
    if (left == null || right == null) return false;
    return left.threadId == right.threadId &&
        left.createdAt == right.createdAt &&
        left.objective == right.objective &&
        left.effectiveStatus == right.effectiveStatus &&
        left.tokenBudget == right.tokenBudget;
  }

  static void _showChangedElsewhere(BuildContext context, AppLocalizations l) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.goalChangedElsewhere)));
  }

  static CodexGoalCardData? cardData(CodexGoal? goal) {
    if (goal == null) return null;
    return CodexGoalCardData(
      objective: goal.objective,
      rawStatus: goal.effectiveStatus,
      tokensUsed: goal.tokensUsed,
      timeUsedSeconds: goal.timeUsedSeconds,
      tokenBudget: goal.tokenBudget,
      status: goal.hasUnknownStatus
          ? CodexGoalStatus.unknown
          : switch (goal.status) {
              CodexThreadGoalStatus.active => CodexGoalStatus.active,
              CodexThreadGoalStatus.paused => CodexGoalStatus.paused,
              CodexThreadGoalStatus.blocked => CodexGoalStatus.blocked,
              CodexThreadGoalStatus.usageLimited =>
                CodexGoalStatus.usageLimited,
              CodexThreadGoalStatus.budgetLimited =>
                CodexGoalStatus.budgetLimited,
              CodexThreadGoalStatus.complete => CodexGoalStatus.complete,
            },
    );
  }

  static String? mutationLabel(
    CodexGoalMutationKind? kind,
    AppLocalizations l,
  ) => switch (kind) {
    CodexGoalMutationKind.create => l.goalMutationStarting,
    CodexGoalMutationKind.edit => l.goalMutationSaving,
    CodexGoalMutationKind.pause => l.goalMutationPausing,
    CodexGoalMutationKind.resume => l.goalMutationResuming,
    CodexGoalMutationKind.updateBudget => l.goalMutationBudget,
    CodexGoalMutationKind.clear => l.goalMutationClearing,
    null => null,
  };

  static String errorLabel(
    CodexGoalErrorKind? kind,
    String fallback,
    AppLocalizations l,
  ) => switch (kind) {
    CodexGoalErrorKind.disconnected ||
    CodexGoalErrorKind.connectRequired => l.goalReconnectToManage,
    CodexGoalErrorKind.unsupported => l.goalUnavailableBody,
    CodexGoalErrorKind.unknownStatus => l.goalUnknownExplanation,
    CodexGoalErrorKind.invalidBudget => l.goalTokenBudgetPositive,
    CodexGoalErrorKind.timeout => l.goalMutationTimeout,
    CodexGoalErrorKind.objectiveRequired => l.goalObjectiveRequired,
    CodexGoalErrorKind.objectiveTooLong => l.goalObjectiveTooLong,
    CodexGoalErrorKind.budgetResumeRequired => l.goalBudgetLimitedExplanation,
    CodexGoalErrorKind.conflict => l.goalChangedElsewhere,
    CodexGoalErrorKind.readFailed => l.goalLoadFailedBody,
    CodexGoalErrorKind.updateFailed => l.goalUpdateFailed,
    CodexGoalErrorKind.clearFailed => l.goalClearFailed,
    null => fallback,
  };

  static String controlsDisabledLabel(
    ChatSessionState state,
    CodexGoal goal,
    AppLocalizations l,
  ) {
    if (goal.hasUnknownStatus) {
      return l.goalUnknownExplanation;
    }
    if (state.goalSupport == CodexGoalSupport.unsupported) {
      return l.goalUnavailableBody;
    }
    if (state.goalLoadErrorKind == CodexGoalErrorKind.readFailed) {
      return l.goalLoadFailedBody;
    }
    return l.goalReconnectToManage;
  }

  static String? _statusExplanation(CodexGoal goal, AppLocalizations l) {
    if (goal.hasUnknownStatus) return l.goalUnknownExplanation;
    return switch (goal.status) {
      CodexThreadGoalStatus.blocked => l.goalBlockedExplanation,
      CodexThreadGoalStatus.usageLimited => l.goalUsageLimitedExplanation,
      CodexThreadGoalStatus.budgetLimited => l.goalBudgetLimitedExplanation,
      CodexThreadGoalStatus.complete => l.goalCompleteExplanation,
      CodexThreadGoalStatus.active || CodexThreadGoalStatus.paused => null,
    };
  }

  static Future<void> showManager(BuildContext context) async {
    final cubit = context.read<ChatSessionCubit>();
    if (cubit.state.goalLoadErrorKind == null &&
        cubit.state.goalSupport != CodexGoalSupport.unsupported) {
      cubit.requestGoal(userInitiated: true);
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StreamBuilder<ChatSessionState>(
        stream: cubit.stream,
        initialData: cubit.state,
        builder: (sheetContext, snapshot) {
          final state = snapshot.data ?? cubit.state;
          final l = AppLocalizations.of(sheetContext);
          final goal = state.goal;
          if (state.goalSupport == CodexGoalSupport.unsupported) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.info_outline, size: 36),
                    const SizedBox(height: 12),
                    Text(
                      l.goalUnavailable,
                      key: const ValueKey('goal_unsupported_title'),
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(l.goalUnavailableBody, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => cubit.requestGoal(userInitiated: true),
                      icon: const Icon(Icons.refresh),
                      label: Text(l.refresh),
                    ),
                  ],
                ),
              ),
            );
          }
          if (goal == null && state.goalLoadErrorKind != null) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 36),
                    const SizedBox(height: 12),
                    Text(
                      l.goalLoadFailedTitle,
                      key: const ValueKey('goal_load_failed_title'),
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      errorLabel(
                        state.goalLoadErrorKind,
                        l.goalLoadFailedBody,
                        l,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      key: const ValueKey('goal_load_retry_button'),
                      onPressed: () => cubit.requestGoal(userInitiated: true),
                      icon: const Icon(Icons.refresh),
                      label: Text(l.refresh),
                    ),
                  ],
                ),
              ),
            );
          }
          if (goal == null && !state.goalStateLoaded) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox.square(
                      dimension: 28,
                      child: CircularProgressIndicator.adaptive(strokeWidth: 3),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l.goalLoading,
                      key: const ValueKey('goal_loading_label'),
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      key: const ValueKey('goal_loading_refresh_button'),
                      onPressed: () => cubit.requestGoal(userInitiated: true),
                      icon: const Icon(Icons.refresh),
                      label: Text(l.refresh),
                    ),
                  ],
                ),
              ),
            );
          }
          if (goal == null) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.track_changes, size: 36),
                    const SizedBox(height: 12),
                    Text(
                      l.goalNoActiveTitle,
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(l.goalNoActiveBody, textAlign: TextAlign.center),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      key: const ValueKey('goal_start_button'),
                      onPressed: state.goalMutation == null
                          ? () {
                              Navigator.of(sheetContext).pop();
                              unawaited(showEditor(context, null));
                            }
                          : null,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(l.goalStart),
                    ),
                  ],
                ),
              ),
            );
          }

          final card = cardData(goal)!;
          final canManageGoal =
              state.goalStateLoaded &&
              state.goalSupport == CodexGoalSupport.supported &&
              !goal.hasUnknownStatus;
          final baseExplanation = _statusExplanation(goal, l);
          var explanation =
              goal.status == CodexThreadGoalStatus.budgetLimited &&
                  !cubit.supportsAdvancedGoalControl
              ? '${baseExplanation ?? ''}\n${l.goalBudgetBridgeUpdate}'
              : baseExplanation;
          if (!canManageGoal && !goal.hasUnknownStatus) {
            final disabled = controlsDisabledLabel(state, goal, l);
            explanation = explanation == null
                ? disabled
                : '$explanation\n$disabled';
          }
          return SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                bottom: 12 + MediaQuery.viewInsetsOf(sheetContext).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l.goalManagementTitle,
                            style: Theme.of(sheetContext).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('goal_refresh_button'),
                          tooltip: l.goalRefreshTooltip,
                          onPressed: state.goalMutation == null
                              ? () => cubit.requestGoal(userInitiated: true)
                              : null,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                  ),
                  CodexGoalCard(
                    goal: card,
                    busy: state.goalMutation != null,
                    busyLabel: mutationLabel(state.goalMutation?.kind, l),
                    controlsEnabled: canManageGoal,
                    disabledLabel: controlsDisabledLabel(state, goal, l),
                    onEdit: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(showEditor(context, goal));
                    },
                    onTogglePaused: () {
                      if (goal.status == CodexThreadGoalStatus.blocked ||
                          goal.status == CodexThreadGoalStatus.usageLimited) {
                        cubit.resumeGoal();
                      } else {
                        cubit.toggleGoalPaused();
                      }
                    },
                    onResolveBudget: cubit.supportsAdvancedGoalControl
                        ? () {
                            Navigator.of(sheetContext).pop();
                            unawaited(
                              showEditor(context, goal, resumeAfterSave: true),
                            );
                          }
                        : null,
                    onClear: () => unawaited(confirmClear(context, goal)),
                  ),
                  if (explanation != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Text(
                        explanation,
                        key: const ValueKey('goal_status_explanation'),
                        style: Theme.of(sheetContext).textTheme.bodySmall
                            ?.copyWith(
                              color: Theme.of(
                                sheetContext,
                              ).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static Future<void> showEditor(
    BuildContext context,
    CodexGoal? goal, {
    bool resumeAfterSave = false,
  }) async {
    final cubit = context.read<ChatSessionCubit>();
    final l = AppLocalizations.of(context);
    final baselineGoal = goal;
    if (!_sameWritableGoal(baselineGoal, cubit.state.goal)) {
      _showChangedElsewhere(context, l);
      return;
    }
    if (goal?.hasUnknownStatus == true) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l.goalUnknownExplanation)));
      return;
    }
    final supportsBudget = cubit.supportsAdvancedGoalControl;
    if (resumeAfterSave && !supportsBudget) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l.goalBudgetBridgeUpdate)));
      return;
    }
    final formKey = GlobalKey<FormState>();
    var objectiveValue = goal?.objective ?? '';
    var budgetValue = goal?.tokenBudget?.toString() ?? '';
    var limitBudget = supportsBudget && goal?.tokenBudget != null;
    var submitting = false;
    String? submitError;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(
            resumeAfterSave
                ? l.goalUpdateBudgetResume
                : goal == null
                ? l.goalStartTitle
                : l.goalEditTitle,
          ),
          content: SizedBox(
            width: 480,
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      key: const ValueKey('goal_objective_field'),
                      initialValue: objectiveValue,
                      onChanged: (value) => objectiveValue = value,
                      autofocus: true,
                      minLines: 3,
                      maxLines: 8,
                      maxLength: 4000,
                      decoration: InputDecoration(
                        labelText: l.goalObjectiveLabel,
                        hintText: l.goalObjectiveHint,
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? l.goalObjectiveRequired
                          : null,
                    ),
                    if (supportsBudget)
                      SwitchListTile.adaptive(
                        key: const ValueKey('goal_budget_toggle'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(l.goalTokenBudgetTitle),
                        subtitle: Text(l.goalTokenBudgetDescription),
                        value: limitBudget,
                        onChanged: (value) {
                          setDialogState(() => limitBudget = value);
                        },
                      ),
                    if (!supportsBudget && goal?.tokenBudget != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(l.goalBudgetBridgeUpdateExisting),
                      ),
                    if (limitBudget)
                      TextFormField(
                        key: const ValueKey('goal_budget_field'),
                        initialValue: budgetValue,
                        onChanged: (value) => budgetValue = value,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: l.goalMaximumTokens,
                          helperText: goal == null
                              ? null
                              : '${goal.tokensUsed} ${l.goalTokensAlreadyUsedSuffix}',
                        ),
                        validator: (value) {
                          if (!limitBudget) return null;
                          final parsed = int.tryParse(value?.trim() ?? '');
                          if (parsed == null || parsed <= 0) {
                            return l.goalTokenBudgetPositive;
                          }
                          if (resumeAfterSave &&
                              goal != null &&
                              parsed <= goal.tokensUsed) {
                            return l.goalTokenBudgetAboveUsed;
                          }
                          return null;
                        },
                      ),
                    if (resumeAfterSave) ...[
                      const SizedBox(height: 12),
                      Text(l.goalBudgetResumeDescription),
                    ],
                    if (submitError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        submitError!,
                        key: const ValueKey('goal_editor_error'),
                        style: TextStyle(
                          color: Theme.of(dialogContext).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting
                  ? null
                  : () => Navigator.of(dialogContext).pop(),
              child: Text(l.cancel),
            ),
            FilledButton(
              key: const ValueKey('goal_save_button'),
              onPressed: submitting
                  ? null
                  : () async {
                      if (formKey.currentState?.validate() != true) return;
                      final currentState = cubit.state;
                      if (!_sameWritableGoal(baselineGoal, currentState.goal)) {
                        setDialogState(
                          () => submitError = l.goalChangedElsewhere,
                        );
                        return;
                      }
                      final currentGoal = baselineGoal;
                      if (!currentState.goalStateLoaded ||
                          currentState.goalSupport !=
                              CodexGoalSupport.supported ||
                          currentGoal?.hasUnknownStatus == true) {
                        final fallbackGoal = currentGoal ?? goal;
                        setDialogState(
                          () => submitError = fallbackGoal == null
                              ? errorLabel(
                                  currentState.goalLoadErrorKind,
                                  l.goalReconnectToManage,
                                  l,
                                )
                              : controlsDisabledLabel(
                                  currentState,
                                  fallbackGoal,
                                  l,
                                ),
                        );
                        return;
                      }
                      if (supportsBudget &&
                          !cubit.supportsAdvancedGoalControl) {
                        setDialogState(
                          () => submitError = l.goalBudgetBridgeUpdate,
                        );
                        return;
                      }

                      final objective = objectiveValue.trim();
                      final budget = limitBudget
                          ? int.tryParse(budgetValue.trim())
                          : null;
                      var started = false;
                      if (currentGoal == null) {
                        started = cubit.startGoal(
                          objective,
                          tokenBudget: budget,
                          includeTokenBudget: supportsBudget && limitBudget,
                        );
                      } else if (resumeAfterSave) {
                        started = cubit.resumeGoal(
                          objective: objective == currentGoal.objective
                              ? null
                              : objective,
                          tokenBudget: budget,
                          includeTokenBudget: true,
                        );
                      } else {
                        final budgetChanged =
                            supportsBudget &&
                            (limitBudget != (currentGoal.tokenBudget != null) ||
                                (limitBudget &&
                                    budget != currentGoal.tokenBudget));
                        final objectiveChanged =
                            objective != currentGoal.objective;
                        if (!objectiveChanged && !budgetChanged) {
                          Navigator.of(dialogContext).pop();
                          return;
                        }
                        started = cubit.editGoal(
                          objective,
                          tokenBudget: budget,
                          includeTokenBudget: budgetChanged,
                          includeObjective: objectiveChanged,
                        );
                      }

                      if (!started) {
                        final state = cubit.state;
                        setDialogState(
                          () => submitError = errorLabel(
                            state.goalMutationErrorKind,
                            state.goalMutationError ?? l.goalUpdateFailed,
                            l,
                          ),
                        );
                        return;
                      }
                      final mutationId = cubit.state.goalMutation?.id;
                      if (mutationId == null) {
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                        return;
                      }
                      setDialogState(() {
                        submitting = true;
                        submitError = null;
                      });
                      final completion = await _waitForGoalMutation(
                        cubit,
                        mutationId,
                      );
                      if (!dialogContext.mounted) return;
                      if (completion.goalMutation == null &&
                          completion.goalMutationError == null) {
                        Navigator.of(dialogContext).pop();
                        return;
                      }
                      setDialogState(() {
                        submitting = false;
                        submitError = errorLabel(
                          completion.goalMutationErrorKind,
                          completion.goalMutationError ?? l.goalMutationTimeout,
                          l,
                        );
                      });
                    },
              child: submitting
                  ? SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator.adaptive(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Theme.of(dialogContext).colorScheme.onPrimary,
                        ),
                      ),
                    )
                  : Text(
                      resumeAfterSave
                          ? l.goalResumeAction
                          : goal == null
                          ? l.start
                          : l.save,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static Future<ChatSessionState> _waitForGoalMutation(
    ChatSessionCubit cubit,
    String mutationId,
  ) async {
    if (cubit.state.goalMutation?.id != mutationId) return cubit.state;
    try {
      return await cubit.stream
          .firstWhere((state) => state.goalMutation?.id != mutationId)
          .timeout(const Duration(seconds: 22), onTimeout: () => cubit.state);
    } on StateError {
      return cubit.state;
    }
  }

  static Future<void> confirmClear(
    BuildContext context,
    CodexGoal openingGoal,
  ) async {
    final cubit = context.read<ChatSessionCubit>();
    final l = AppLocalizations.of(context);
    final baselineGoal = openingGoal;
    var submitting = false;
    String? submitError;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(l.goalClearTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.goalClearBody),
              if (submitError != null) ...[
                const SizedBox(height: 12),
                Text(
                  submitError!,
                  key: const ValueKey('goal_clear_error'),
                  style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: submitting
                  ? null
                  : () => Navigator.of(dialogContext).pop(),
              child: Text(l.cancel),
            ),
            FilledButton.tonal(
              key: const ValueKey('goal_clear_confirm_button'),
              onPressed: submitting
                  ? null
                  : () async {
                      final state = cubit.state;
                      if (!_sameWritableGoal(baselineGoal, state.goal)) {
                        setDialogState(
                          () => submitError = l.goalChangedElsewhere,
                        );
                        return;
                      }
                      if (!state.goalStateLoaded ||
                          state.goalSupport != CodexGoalSupport.supported ||
                          baselineGoal.hasUnknownStatus) {
                        setDialogState(
                          () => submitError = controlsDisabledLabel(
                            state,
                            baselineGoal,
                            l,
                          ),
                        );
                        return;
                      }
                      if (!cubit.clearGoal()) {
                        final current = cubit.state;
                        setDialogState(
                          () => submitError = errorLabel(
                            current.goalMutationErrorKind,
                            current.goalMutationError ?? l.goalClearFailed,
                            l,
                          ),
                        );
                        return;
                      }
                      final mutationId = cubit.state.goalMutation?.id;
                      if (mutationId == null) return;
                      setDialogState(() {
                        submitting = true;
                        submitError = null;
                      });
                      final completion = await _waitForGoalMutation(
                        cubit,
                        mutationId,
                      );
                      if (!dialogContext.mounted) return;
                      if (completion.goalMutation == null &&
                          completion.goalMutationError == null) {
                        Navigator.of(dialogContext).pop();
                        return;
                      }
                      setDialogState(() {
                        submitting = false;
                        submitError = errorLabel(
                          completion.goalMutationErrorKind,
                          completion.goalMutationError ?? l.goalClearFailed,
                          l,
                        );
                      });
                    },
              child: submitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                    )
                  : Text(l.goalClearAction),
            ),
          ],
        ),
      ),
    );
  }
}
