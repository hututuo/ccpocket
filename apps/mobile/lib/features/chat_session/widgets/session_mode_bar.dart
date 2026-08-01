import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/codex_effort_slider.dart';
import '../state/chat_session_state.dart';
import '../state/chat_session_cubit.dart';
import 'codex_settings_sheet.dart';

class SessionModeBar extends StatelessWidget {
  final Future<void> Function()? onBeforeRestart;
  final bool showExtendedCodexEfforts;
  final List<Widget> trailingWidgets;

  const SessionModeBar({
    super.key,
    this.onBeforeRestart,
    this.showExtendedCodexEfforts = false,
    this.trailingWidgets = const [],
  });

  @override
  Widget build(BuildContext context) {
    final chatCubit = context.watch<ChatSessionCubit>();
    final executionMode = chatCubit.state.executionMode;
    final planMode = chatCubit.state.planMode;
    final sandboxMode = chatCubit.state.sandboxMode;
    final permissionMode = chatCubit.state.permissionMode;
    final isCodex = chatCubit.provider == Provider.codex;
    final permissionChangePending = chatCubit.isPermissionChangePending;
    final codexSettingsActionability = chatCubit.codexSettingsActionability;
    final codexSettingsEditable =
        codexSettingsActionability == CodexSettingsActionability.editable;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          decoration: BoxDecoration(
            color: isDark
                ? cs.surface.withValues(alpha: 0.6)
                : cs.surface.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.white.withValues(alpha: 0.6),
            ),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: IntrinsicHeight(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isCodex) ...[
                    ValueListenableBuilder<int>(
                      valueListenable: chatCubit.codexModelCatalogRevision,
                      builder: (context, _, _) {
                        final codexModel = chatCubit.codexModelSettingsKnown
                            ? _currentCodexModel(chatCubit)
                            : null;
                        // The chip reports the current thread fact. Candidate
                        // defaults belong only inside the settings sheet and
                        // must not make an unknown Desktop effort look like high.
                        final codexReasoningEffort =
                            chatCubit.state.codexModelReasoningEffort;
                        return ValueListenableBuilder<String?>(
                          valueListenable: chatCubit.codexServiceTierRaw,
                          builder: (context, serviceTierRaw, _) =>
                              CodexModelChip(
                                model: codexModel,
                                reasoningEffort: codexReasoningEffort,
                                speed: chatCubit.state.codexSpeed,
                                serviceTierRaw: serviceTierRaw,
                                settingsKnown:
                                    chatCubit.codexModelSettingsKnown,
                                onTap: () {
                                  if (!codexSettingsEditable ||
                                      !chatCubit.codexModelSettingsKnown) {
                                    showCodexSettingsUnavailable(
                                      context,
                                      chatCubit,
                                    );
                                    return;
                                  }
                                  showCodexModelMenu(
                                    context,
                                    chatCubit,
                                    showExtendedEfforts:
                                        showExtendedCodexEfforts,
                                  );
                                },
                              ),
                        );
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: cs.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                    IgnorePointer(
                      key: const ValueKey('plan_mode_pending_guard'),
                      ignoring: permissionChangePending,
                      child: Opacity(
                        opacity: permissionChangePending ? 0.5 : 1,
                        child: PlanModeChip(
                          enabled: planMode,
                          known: chatCubit.codexPlanModeKnown,
                          activeGlow: false,
                          onTap: () {
                            if (!codexSettingsEditable ||
                                !chatCubit.codexPlanModeKnown) {
                              showCodexSettingsUnavailable(context, chatCubit);
                              return;
                            }
                            togglePlanMode(
                              context,
                              chatCubit,
                              onBeforeRestart: onBeforeRestart,
                            );
                          },
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: cs.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                    IgnorePointer(
                      key: const ValueKey('permission_mode_pending_guard'),
                      ignoring: permissionChangePending,
                      child: Opacity(
                        opacity: permissionChangePending ? 0.5 : 1,
                        child: ExecutionModeChip(
                          currentMode: executionMode,
                          codexApprovalPolicy:
                              chatCubit.state.codexApprovalPolicy,
                          codexApprovalsReviewer:
                              chatCubit.state.codexApprovalsReviewer,
                          codexPermissionsMode:
                              chatCubit.state.codexPermissionsMode,
                          codexPermissionStateKnown:
                              chatCubit.state.codexPermissionStateKnown,
                          provider: chatCubit.provider,
                          onTap: () {
                            if (!codexSettingsEditable ||
                                !chatCubit.state.codexPermissionStateKnown) {
                              showCodexSettingsUnavailable(context, chatCubit);
                              return;
                            }
                            showCodexPermissionsMenu(
                              context,
                              chatCubit,
                              onBeforeRestart: onBeforeRestart,
                            );
                          },
                        ),
                      ),
                    ),
                  ] else ...[
                    PermissionModeChip(
                      currentMode: permissionMode,
                      onTap: () => showPermissionModeMenu(
                        context,
                        chatCubit,
                        onBeforeRestart: onBeforeRestart,
                      ),
                    ),
                  ],
                  if (!isCodex) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: cs.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                    SandboxModeChip(
                      currentMode: sandboxMode,
                      provider: chatCubit.provider,
                      onTap: () => showSandboxModeMenu(
                        context,
                        chatCubit,
                        onBeforeRestart: onBeforeRestart,
                      ),
                    ),
                  ],
                  ...trailingWidgets,
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ValueListenableBuilder<bool>(
        valueListenable: chatCubit.historySyncing,
        child: bar,
        builder: (context, historySyncing, child) => _HistorySyncModeBarSurface(
          isSyncing: historySyncing,
          child: child!,
        ),
      ),
    );
  }
}

class _HistorySyncModeBarSurface extends StatefulWidget {
  final bool isSyncing;
  final Widget child;

  const _HistorySyncModeBarSurface({
    required this.isSyncing,
    required this.child,
  });

  @override
  State<_HistorySyncModeBarSurface> createState() =>
      _HistorySyncModeBarSurfaceState();
}

class _HistorySyncModeBarSurfaceState extends State<_HistorySyncModeBarSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _tickerEnabled = true;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 2500),
      vsync: this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    final media = MediaQuery.maybeOf(context);
    _reduceMotion =
        media?.disableAnimations == true || media?.accessibleNavigation == true;
    _synchronizeAnimation();
  }

  @override
  void didUpdateWidget(_HistorySyncModeBarSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _synchronizeAnimation();
  }

  void _synchronizeAnimation() {
    if (widget.isSyncing &&
        _tickerEnabled &&
        !_reduceMotion &&
        !_controller.isAnimating) {
      _controller.repeat();
    } else if ((!widget.isSyncing || !_tickerEnabled || _reduceMotion) &&
        (_controller.isAnimating || _controller.value != 0)) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (!widget.isSyncing) {
      return widget.child;
    }

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          return CustomPaint(
            key: const ValueKey('session_history_sync_glow'),
            painter: _RotatingBorderPainter(
              progress: _controller.value,
              color: appColors.statusRunning,
              glowColor: Color.lerp(
                appColors.statusRunning,
                Colors.white,
                0.35,
              )!,
              borderRadius: 12,
              strokeWidth: 1.5,
              isDark: isDark,
            ),
            child: child,
          );
        },
      ),
    );
  }
}

class _RotatingBorderPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color glowColor;
  final double borderRadius;
  final double strokeWidth;
  final bool isDark;

  _RotatingBorderPainter({
    required this.progress,
    required this.color,
    required this.glowColor,
    required this.borderRadius,
    required this.strokeWidth,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));

    // Subtle base border
    final basePaint = Paint()
      ..color = color.withValues(alpha: isDark ? 0.12 : 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawRRect(rrect, basePaint);

    // Build path from the rounded rect and find the dot position
    final path = Path()..addRRect(rrect);
    final metric = path.computeMetrics().first;
    final totalLen = metric.length;
    final dotOffset = metric.getTangentForOffset(totalLen * progress)!.position;

    // Radial gradient centered on the dot for a clean glow
    final glowRadius = 18.0;
    final dotRect = Rect.fromCircle(center: dotOffset, radius: glowRadius);
    final radial = RadialGradient(
      colors: [
        glowColor.withValues(alpha: isDark ? 0.85 : 0.7),
        color.withValues(alpha: isDark ? 0.4 : 0.25),
        Colors.transparent,
      ],
      stops: const [0.0, 0.35, 1.0],
    );

    // Clip to border stroke region (outer rrect minus inner rrect)
    final halfW = (strokeWidth + 4) / 2;
    final outerRRect = RRect.fromRectAndRadius(
      rect.inflate(halfW),
      Radius.circular(borderRadius + halfW),
    );
    final innerRRect = RRect.fromRectAndRadius(
      rect.deflate(halfW),
      Radius.circular((borderRadius - halfW).clamp(0, double.infinity)),
    );
    final clipPath = Path()
      ..addRRect(outerRRect)
      ..addRRect(innerRRect)
      ..fillType = PathFillType.evenOdd;

    canvas.save();
    canvas.clipPath(clipPath);

    // Outer glow
    final glowPaint = Paint()
      ..shader = radial.createShader(dotRect)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawRect(dotRect, glowPaint);

    // Bright core
    final coreRect = Rect.fromCircle(center: dotOffset, radius: 8);
    final coreGradient = RadialGradient(
      colors: [
        glowColor.withValues(alpha: isDark ? 1.0 : 0.9),
        color.withValues(alpha: isDark ? 0.5 : 0.35),
        Colors.transparent,
      ],
      stops: const [0.0, 0.4, 1.0],
    );
    final corePaint = Paint()..shader = coreGradient.createShader(coreRect);
    canvas.drawRect(coreRect, corePaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_RotatingBorderPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.glowColor != glowColor ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.isDark != isDark;
}

String? _currentCodexModel(ChatSessionCubit chatCubit) {
  final models = chatCubit.codexModels.isNotEmpty
      ? chatCubit.codexModels
      : defaultCodexModels;
  final current = normalizeCodexModelForAvailableList(
    chatCubit.state.codexModel,
    models,
  );
  if (current != null || chatCubit.detachedPreview) return current;
  return models.isNotEmpty ? models.first : defaultCodexModels.first;
}

List<ReasoningEffort> _codexReasoningEffortsForModel(
  BuildContext context,
  String model,
) {
  final raw = context
      .read<ChatSessionCubit>()
      .codexModelReasoningEfforts[model];
  final efforts = <ReasoningEffort>[];
  if (raw != null) {
    for (final value in raw) {
      final effort = reasoningEffortByValue(value);
      if (effort != null && !efforts.contains(effort)) efforts.add(effort);
    }
  }
  if (efforts.isEmpty) {
    efforts.addAll(const [
      ReasoningEffort.low,
      ReasoningEffort.medium,
      ReasoningEffort.high,
      ReasoningEffort.xhigh,
    ]);
  }
  return efforts;
}

ReasoningEffort _effectiveCodexReasoningEffort(
  ReasoningEffort? current,
  List<ReasoningEffort> efforts,
) => preferredCodexEffort(efforts, current: current);

void showCodexModelMenu(
  BuildContext context,
  ChatSessionCubit chatCubit, {
  bool showExtendedEfforts = false,
}) {
  final models = chatCubit.codexModels.isNotEmpty
      ? chatCubit.codexModels
      : defaultCodexModels;
  final currentModel = _currentCodexModel(chatCubit);
  if (currentModel == null || !chatCubit.codexModelSettingsKnown) {
    showCodexSettingsUnavailable(context, chatCubit);
    return;
  }
  final currentEfforts = _codexReasoningEffortsForModel(context, currentModel);
  final currentEffort = _effectiveCodexReasoningEffort(
    chatCubit.state.codexModelReasoningEffort,
    currentEfforts,
  );
  final modelEfforts = {
    for (final model in models)
      model: _codexReasoningEffortsForModel(context, model),
  };

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => CodexSettingsSheet(
      models: models,
      modelEfforts: modelEfforts,
      modelServiceTiers: chatCubit.codexModelServiceTiers,
      initialModel: currentModel,
      initialEffort: currentEffort,
      initialSpeed: chatCubit.state.codexSpeed,
      initialServiceTierRaw: chatCubit.codexServiceTierRaw.value,
      showExtendedEfforts: showExtendedEfforts,
      optimisticUpdates: !chatCubit.detachedPreview,
      onModelChanged: (model, effort) =>
          chatCubit.setCodexModel(model, reasoningEffort: effort),
      onEffortChanged: (model, effort) =>
          chatCubit.setCodexModel(model, reasoningEffort: effort),
      onSpeedChanged: chatCubit.setCodexSpeed,
    ),
  );
}

void showCodexSettingsUnavailable(
  BuildContext context,
  ChatSessionCubit chatCubit,
) {
  final l = AppLocalizations.of(context);
  final message = switch (chatCubit.codexSettingsActionability) {
    CodexSettingsActionability.waitingForRuntime =>
      l.codexSettingsWaitingForRuntime,
    CodexSettingsActionability.readOnlyDesktopOwner =>
      l.codexSettingsReadOnlyDesktop,
    CodexSettingsActionability.unavailable => l.codexSettingsUnavailable,
    CodexSettingsActionability.editable => l.codexSettingsUnknown,
  };
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

void showCodexPermissionsMenu(
  BuildContext context,
  ChatSessionCubit chatCubit, {
  Future<void> Function()? onBeforeRestart,
}) {
  if (chatCubit.provider != Provider.codex) {
    showPermissionModeMenu(
      context,
      chatCubit,
      onBeforeRestart: onBeforeRestart,
    );
    return;
  }
  final currentMode = chatCubit.state.codexPermissionStateKnown
      ? chatCubit.state.codexPermissionsMode
      : null;
  final l = AppLocalizations.of(context);

  showModalBottomSheet(
    context: context,
    builder: (sheetContext) {
      final sheetCs = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l.permission,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: sheetCs.onSurface,
                    ),
                  ),
                ),
              ),
              for (final mode in CodexPermissionsMode.values)
                ListTile(
                  leading: Icon(
                    _codexPermissionsIcon(mode),
                    color: mode == currentMode
                        ? (mode == CodexPermissionsMode.fullAccess
                              ? sheetCs.error
                              : sheetCs.primary)
                        : sheetCs.onSurfaceVariant,
                  ),
                  title: Text(_codexPermissionsLabel(mode, l)),
                  subtitle: Text(
                    _codexPermissionsSubtitle(mode, l),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: mode == currentMode
                      ? Icon(
                          Icons.check,
                          color: mode == CodexPermissionsMode.fullAccess
                              ? sheetCs.error
                              : sheetCs.primary,
                          size: 20,
                        )
                      : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (mode == currentMode) return;
                    HapticFeedback.lightImpact();
                    _chooseCodexPermissionsModeApplication(
                      context,
                      chatCubit,
                      mode,
                      onBeforeRestart: onBeforeRestart,
                    );
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> _chooseCodexPermissionsModeApplication(
  BuildContext context,
  ChatSessionCubit chatCubit,
  CodexPermissionsMode mode, {
  Future<void> Function()? onBeforeRestart,
}) async {
  if (chatCubit.detachedPreview) {
    if (!chatCubit.supportsCodexPermissionApplyStrategy) {
      showCodexSettingsUnavailable(context, chatCubit);
      return;
    }
    chatCubit.setCodexPermissionsMode(
      mode,
      applyStrategy: CodexPermissionApplyStrategy.nextTurn,
    );
    return;
  }
  if (!chatCubit.supportsCodexPermissionApplyStrategy) {
    await _confirmCodexPermissionsRestart(
      context,
      chatCubit,
      mode,
      onBeforeRestart: onBeforeRestart,
    );
    return;
  }

  final l = AppLocalizations.of(context);
  final strategy = await showDialog<CodexPermissionApplyStrategy>(
    context: context,
    builder: (dialogContext) {
      final cs = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        scrollable: true,
        title: Text(l.applyPermissionsTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.applyPermissionsBody(mode.label)),
            const SizedBox(height: 12),
            ListTile(
              key: const ValueKey('permission_apply_next_turn'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.update, color: cs.primary),
              title: Text(l.applyPermissionsNextTurnTitle),
              subtitle: Text(l.applyPermissionsNextTurnDescription),
              onTap: () => Navigator.pop(
                dialogContext,
                CodexPermissionApplyStrategy.nextTurn,
              ),
            ),
            ListTile(
              key: const ValueKey('permission_apply_restart_now'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.restart_alt,
                color: mode == CodexPermissionsMode.fullAccess
                    ? cs.error
                    : cs.onSurfaceVariant,
              ),
              title: Text(l.applyPermissionsRestartNowTitle),
              subtitle: Text(l.applyPermissionsRestartNowDescription),
              onTap: () => Navigator.pop(
                dialogContext,
                CodexPermissionApplyStrategy.restartNow,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l.cancel),
          ),
        ],
      );
    },
  );

  if (strategy == CodexPermissionApplyStrategy.nextTurn) {
    chatCubit.setCodexPermissionsMode(
      mode,
      applyStrategy: CodexPermissionApplyStrategy.nextTurn,
    );
  } else if (strategy == CodexPermissionApplyStrategy.restartNow) {
    await onBeforeRestart?.call();
    chatCubit.setCodexPermissionsMode(
      mode,
      applyStrategy: CodexPermissionApplyStrategy.restartNow,
    );
  }
}

/// Legacy Bridge fallback: old servers do not advertise the safe next-turn
/// update contract, so keep their existing restart-only behavior.
Future<void> _confirmCodexPermissionsRestart(
  BuildContext context,
  ChatSessionCubit chatCubit,
  CodexPermissionsMode mode, {
  Future<void> Function()? onBeforeRestart,
}) async {
  final l = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final cs = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(l.changeApprovalPolicyTitle),
        content: Text(l.changeApprovalPolicyBody(mode.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: mode == CodexPermissionsMode.fullAccess
                ? FilledButton.styleFrom(backgroundColor: cs.error)
                : null,
            child: Text(l.restart),
          ),
        ],
      );
    },
  );
  if (confirmed == true) {
    await onBeforeRestart?.call();
    chatCubit.setCodexPermissionsMode(
      mode,
      applyStrategy: chatCubit.bridgeSupportsCodexPermissionApplyStrategy
          ? CodexPermissionApplyStrategy.restartNow
          : null,
    );
  }
}

Future<void> togglePlanMode(
  BuildContext context,
  ChatSessionCubit chatCubit, {
  Future<void> Function()? onBeforeRestart,
}) async {
  if (chatCubit.isPermissionChangePending) return;
  final nextPlanMode = !chatCubit.state.planMode;
  if (chatCubit.isCodex &&
      nextPlanMode &&
      chatCubit.state.codexNativePlanModeSupport ==
          CodexNativePlanModeSupport.unsupported) {
    showCodexNativePlanModeUnavailable(context);
    return;
  }
  final hasPendingApproval = chatCubit.state.approval is! ApprovalNone;
  final l = AppLocalizations.of(context);
  final canToggleInPlace =
      chatCubit.isCodex &&
      chatCubit.state.status == ProcessStatus.idle &&
      !hasPendingApproval;

  if (canToggleInPlace) {
    HapticFeedback.lightImpact();
    chatCubit.setSessionModes(planMode: nextPlanMode);
    return;
  }

  if (chatCubit.detachedPreview) {
    showCodexSettingsUnavailable(context, chatCubit);
    return;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(
          nextPlanMode ? l.enablePlanModeTitle : l.disablePlanModeTitle,
        ),
        content: Text(
          nextPlanMode ? l.enablePlanModeBody : l.disablePlanModeBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.restart),
          ),
        ],
      );
    },
  );
  if (confirmed == true) {
    await onBeforeRestart?.call();
    chatCubit.setSessionModes(planMode: nextPlanMode);
  }
}

void showCodexNativePlanModeUnavailable(BuildContext context) {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          AppLocalizations.of(context).codexNativePlanModeUnavailable,
        ),
      ),
    );
}

void showSandboxModeMenu(
  BuildContext context,
  ChatSessionCubit chatCubit, {
  Future<void> Function()? onBeforeRestart,
}) {
  final currentMode = chatCubit.state.sandboxMode;
  final isClaude = chatCubit.provider != Provider.codex;
  final l = AppLocalizations.of(context);

  showModalBottomSheet(
    context: context,
    builder: (sheetContext) {
      final sheetCs = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l.sandbox,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: sheetCs.onSurface,
                  ),
                ),
              ),
            ),
            for (final mode
                in isClaude ? SandboxMode.values.reversed : SandboxMode.values)
              ListTile(
                leading: Icon(
                  _sandboxMenuIcon(mode, isClaude),
                  color: mode == currentMode
                      ? sheetCs.primary
                      : _sandboxMenuIconColor(mode, isClaude, sheetCs),
                ),
                title: Text(
                  _sandboxMenuTitle(mode, isClaude, l),
                  style: TextStyle(
                    color:
                        !isClaude &&
                            mode == SandboxMode.off &&
                            currentMode != mode
                        ? sheetCs.error
                        : null,
                  ),
                ),
                subtitle: Text(
                  _sandboxMenuSubtitle(mode, isClaude, l),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: mode == currentMode
                    ? Icon(Icons.check, color: sheetCs.primary, size: 20)
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (mode == currentMode) return;
                  HapticFeedback.lightImpact();
                  _confirmSandboxModeChange(
                    context,
                    chatCubit,
                    mode,
                    isClaude: isClaude,
                    onBeforeRestart: onBeforeRestart,
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

IconData _sandboxMenuIcon(SandboxMode mode, bool isClaude) {
  if (mode == SandboxMode.on) return Icons.shield_outlined;
  return isClaude ? Icons.code : Icons.warning_amber;
}

Color _sandboxMenuIconColor(SandboxMode mode, bool isClaude, ColorScheme cs) {
  if (mode == SandboxMode.off && !isClaude) return cs.error;
  return cs.onSurfaceVariant;
}

String _sandboxMenuTitle(SandboxMode mode, bool isClaude, AppLocalizations l) {
  if (isClaude) {
    return mode == SandboxMode.on ? l.sandboxSafeMode : l.sandboxStandard;
  }
  return mode == SandboxMode.on ? l.sandboxOnLabel : l.sandboxOffLabel;
}

String _sandboxMenuSubtitle(
  SandboxMode mode,
  bool isClaude,
  AppLocalizations l,
) {
  if (isClaude) {
    return mode == SandboxMode.on
        ? l.sandboxRestrictedDescription
        : l.sandboxNativeDescription;
  }
  return mode == SandboxMode.on
      ? l.sandboxRestrictedDescription
      : l.sandboxNativeCautionDescription;
}

/// Show confirmation dialog before changing sandbox mode, because
/// the change requires a session restart (thread/resume with new sandbox).
Future<void> _confirmSandboxModeChange(
  BuildContext context,
  ChatSessionCubit chatCubit,
  SandboxMode mode, {
  bool isClaude = false,
  Future<void> Function()? onBeforeRestart,
}) async {
  final l = AppLocalizations.of(context);
  final modeLabel = isClaude
      ? (mode == SandboxMode.on ? l.sandboxSafeMode : l.sandboxStandard)
      : (mode == SandboxMode.on ? l.sandboxOnLabel : l.sandboxOffLabel);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final cs = Theme.of(dialogContext).colorScheme;
      // For Codex, turning off sandbox is dangerous (red button).
      // For Claude, turning off is standard — no red.
      final useErrorStyle = mode == SandboxMode.off && !isClaude;
      return AlertDialog(
        title: Text(l.changeSandboxModeTitle),
        content: Text(l.changeSandboxModeBody(modeLabel)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: useErrorStyle
                ? FilledButton.styleFrom(backgroundColor: cs.error)
                : null,
            child: Text(l.restart),
          ),
        ],
      );
    },
  );
  if (confirmed == true) {
    await onBeforeRestart?.call();
    chatCubit.setSandboxMode(mode);
  }
}

void showPermissionModeMenu(
  BuildContext context,
  ChatSessionCubit chatCubit, {
  Future<void> Function()? onBeforeRestart,
}) {
  final currentMode = chatCubit.state.permissionMode;
  final l = AppLocalizations.of(context);
  const purple = Color(0xFFBB86FC);
  final appColors = Theme.of(context).extension<AppColors>()!;
  final autoModeColor = Theme.of(context).brightness == Brightness.dark
      ? appColors.warningText
      : appColors.warningBubbleBorder;

  final modeDetails =
      <PermissionMode, ({IconData icon, String description, Color color})>{
        PermissionMode.defaultMode: (
          icon: Icons.tune,
          description: l.permissionDefaultDescription,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        PermissionMode.auto: (
          icon: Icons.auto_mode_outlined,
          description: l.permissionAutoDescription,
          color: autoModeColor,
        ),
        PermissionMode.acceptEdits: (
          icon: Icons.edit_note,
          description: l.permissionAcceptEditsDescription,
          color: purple,
        ),
        PermissionMode.plan: (
          icon: Icons.assignment_outlined,
          description: l.permissionPlanDescription,
          color: Theme.of(context).extension<AppColors>()!.statusPlan,
        ),
        PermissionMode.bypassPermissions: (
          icon: Icons.flash_on,
          description: l.permissionBypassDescription,
          color: Theme.of(context).colorScheme.error,
        ),
      };

  showModalBottomSheet(
    context: context,
    builder: (sheetContext) {
      final sheetCs = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Permission',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: sheetCs.onSurface,
                  ),
                ),
              ),
            ),
            for (final mode in PermissionMode.values)
              ListTile(
                leading: Icon(
                  modeDetails[mode]!.icon,
                  color: mode == currentMode
                      ? modeDetails[mode]!.color
                      : sheetCs.onSurfaceVariant,
                ),
                title: Text(mode.label),
                subtitle: Text(
                  modeDetails[mode]!.description,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: mode == currentMode
                    ? Icon(
                        Icons.check,
                        color: modeDetails[mode]!.color,
                        size: 20,
                      )
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (mode == currentMode) return;
                  HapticFeedback.lightImpact();
                  _confirmPermissionModeChange(
                    context,
                    chatCubit,
                    mode,
                    onBeforeRestart: onBeforeRestart,
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

Future<void> _confirmPermissionModeChange(
  BuildContext context,
  ChatSessionCubit chatCubit,
  PermissionMode mode, {
  Future<void> Function()? onBeforeRestart,
}) async {
  final l = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final cs = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(l.changePermissionModeTitle),
        content: Text(l.changePermissionModeBody(mode.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: mode == PermissionMode.bypassPermissions
                ? FilledButton.styleFrom(backgroundColor: cs.error)
                : null,
            child: Text(l.restart),
          ),
        ],
      );
    },
  );
  if (confirmed == true) {
    await onBeforeRestart?.call();
    chatCubit.setPermissionMode(mode);
  }
}

class PermissionModeChip extends StatelessWidget {
  final PermissionMode currentMode;
  final VoidCallback onTap;

  const PermissionModeChip({
    super.key,
    required this.currentMode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    const purple = Color(0xFFBB86FC);
    final plan = Theme.of(context).extension<AppColors>()!.statusPlan;
    final appColors = Theme.of(context).extension<AppColors>()!;
    final autoModeColor = Theme.of(context).brightness == Brightness.dark
        ? appColors.warningText
        : appColors.warningBubbleBorder;

    final (IconData icon, String label, Color fg) = switch (currentMode) {
      PermissionMode.defaultMode => (
        Icons.tune,
        l.permissionDefaultMode,
        cs.onSurfaceVariant,
      ),
      PermissionMode.auto => (
        Icons.auto_mode_outlined,
        l.permissionAutoMode,
        autoModeColor,
      ),
      PermissionMode.acceptEdits => (
        Icons.edit_note,
        l.permissionChipAcceptEdits,
        purple,
      ),
      PermissionMode.plan => (
        Icons.assignment_outlined,
        l.permissionPlanMode,
        plan,
      ),
      PermissionMode.bypassPermissions => (
        Icons.flash_on,
        l.permissionChipBypass,
        cs.error,
      ),
    };

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: fg),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                size: 14,
                color: fg.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ExecutionModeChip extends StatelessWidget {
  final ExecutionMode currentMode;
  final CodexApprovalPolicy? codexApprovalPolicy;
  final String? codexApprovalsReviewer;
  final CodexPermissionsMode? codexPermissionsMode;
  final bool codexPermissionStateKnown;
  final Provider? provider;
  final VoidCallback onTap;

  const ExecutionModeChip({
    super.key,
    required this.currentMode,
    this.codexApprovalPolicy,
    this.codexApprovalsReviewer,
    this.codexPermissionsMode,
    this.codexPermissionStateKnown = true,
    this.provider,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);

    // Colors aligned with Claude Code CLI
    const purple = Color(0xFFBB86FC);

    final (IconData icon, String label, Color fg) = provider == Provider.codex
        ? (codexPermissionStateKnown
              ? _codexPermissionsChipStyle(
                  codexPermissionsMode ??
                      codexPermissionsModeFromSettings(
                        approvalPolicy: codexApprovalPolicy?.value,
                        approvalsReviewer: codexApprovalsReviewer,
                        sandboxMode: null,
                      ),
                  cs,
                  l,
                )
              : (
                  Icons.help_outline,
                  l.guardianApprovalAuthorizationUnknown,
                  cs.onSurfaceVariant,
                ))
        : switch (currentMode) {
            ExecutionMode.defaultMode => (
              Icons.tune,
              l.permissionDefaultMode,
              cs.onSurfaceVariant,
            ),
            ExecutionMode.acceptEdits => (
              Icons.edit_note,
              l.permissionChipAcceptEdits,
              purple,
            ),
            ExecutionMode.fullAccess => (
              Icons.flash_on,
              l.executionFullShort,
              cs.error,
            ),
          };

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: fg),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                size: 14,
                color: fg.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CodexModelChip extends StatelessWidget {
  final String? model;
  final ReasoningEffort? reasoningEffort;
  final CodexSpeed speed;
  final String? serviceTierRaw;
  final bool settingsKnown;
  final VoidCallback onTap;

  const CodexModelChip({
    super.key,
    required this.model,
    this.reasoningEffort,
    required this.speed,
    this.serviceTierRaw,
    this.settingsKnown = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final fg = cs.onSurfaceVariant;
    final label = settingsKnown && model != null
        ? codexModelDisplayName(model!)
        : l.codexSettingsUnknown;
    final suffix = reasoningEffort == null ? '' : ' ${reasoningEffort!.label}';
    final normalizedTier = serviceTierRaw?.trim();
    final unknownTier =
        codexRuntimeSpeedFromRaw(normalizedTier) == CodexSpeed.unknown
        ? normalizedTier
        : null;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (speed == CodexSpeed.fast) ...[
                Icon(Icons.bolt, size: 13, color: cs.primary),
                const SizedBox(width: 2),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: Text(
                  '$label${settingsKnown ? suffix : ''}${unknownTier == null ? '' : ' · $unknownTier'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                size: 14,
                color: fg.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _codexPermissionsIcon(CodexPermissionsMode mode) => switch (mode) {
  CodexPermissionsMode.defaultPermissions => Icons.back_hand_outlined,
  CodexPermissionsMode.autoReview => Icons.shield_outlined,
  CodexPermissionsMode.fullAccess => Icons.warning_amber_outlined,
  CodexPermissionsMode.custom => Icons.settings_outlined,
};

String _codexPermissionsSubtitle(
  CodexPermissionsMode mode,
  AppLocalizations l,
) => switch (mode) {
  CodexPermissionsMode.defaultPermissions => l.sandboxRestrictedDescription,
  CodexPermissionsMode.autoReview => l.codexAutoReviewDescription,
  CodexPermissionsMode.fullAccess => l.sandboxNativeCautionDescription,
  CodexPermissionsMode.custom => l.codexPermissionsFromConfig,
};

String _codexPermissionsLabel(CodexPermissionsMode mode, AppLocalizations l) =>
    switch (mode) {
      CodexPermissionsMode.defaultPermissions => l.codexPermissionsOnRequest,
      CodexPermissionsMode.autoReview => l.codexAutoReview,
      CodexPermissionsMode.fullAccess => l.codexPermissionsFullAccess,
      CodexPermissionsMode.custom => l.codexPermissionsCustom,
    };

(IconData, String, Color) _codexPermissionsChipStyle(
  CodexPermissionsMode mode,
  ColorScheme cs,
  AppLocalizations l,
) => switch (mode) {
  CodexPermissionsMode.defaultPermissions => (
    _codexPermissionsIcon(mode),
    l.codexPermissionsOnRequest,
    cs.onSurfaceVariant,
  ),
  CodexPermissionsMode.autoReview => (
    _codexPermissionsIcon(mode),
    l.codexAutoReview,
    cs.primary,
  ),
  CodexPermissionsMode.fullAccess => (
    _codexPermissionsIcon(mode),
    l.executionFullShort,
    cs.error,
  ),
  CodexPermissionsMode.custom => (
    _codexPermissionsIcon(mode),
    l.codexPermissionsCustomShort,
    cs.primary,
  ),
};

class PlanModeChip extends StatelessWidget {
  final bool enabled;
  final bool known;
  final bool activeGlow;
  final VoidCallback onTap;

  const PlanModeChip({
    super.key,
    required this.enabled,
    this.known = true,
    this.activeGlow = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final fg = known && enabled ? appColors.statusPlan : cs.onSurfaceVariant;

    final chip = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                known
                    ? (enabled ? l.planOnShort : l.planOffShort)
                    : l.codexSettingsUnknown,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!activeGlow) return chip;

    return DecoratedBox(
      key: const ValueKey('plan_mode_chip_glow'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: appColors.statusPlanGlow.withValues(alpha: 0.65),
        ),
        boxShadow: [
          BoxShadow(
            color: appColors.statusPlanGlow.withValues(alpha: 0.22),
            blurRadius: 6,
          ),
        ],
      ),
      child: chip,
    );
  }
}

class SandboxModeChip extends StatelessWidget {
  final SandboxMode currentMode;
  final Provider? provider;
  final VoidCallback onTap;

  const SandboxModeChip({
    super.key,
    required this.currentMode,
    this.provider,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final isClaude = provider != Provider.codex;

    final (IconData icon, String label, Color fg) = switch (currentMode) {
      SandboxMode.on => (Icons.shield_outlined, l.sandbox, cs.tertiary),
      SandboxMode.off =>
        isClaude
            ? (Icons.code, l.sandboxStandard, cs.onSurfaceVariant)
            : (Icons.warning_amber, l.sandboxOffShort, cs.error),
    };

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: fg),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                size: 14,
                color: fg.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
