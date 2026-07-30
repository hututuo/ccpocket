import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart'
    show
        ContextUsage,
        SessionUsageInfo,
        SessionUsageLimitCard,
        SessionUsageResetCredit,
        SessionUsageResetCredits,
        SessionUsageWindow;
import '../../../services/bridge_service.dart';
import '../l10n/session_insights_strings.dart';
import '../state/session_insights_controller.dart';

/// Compact context meter with a self-contained, read-only quota detail sheet.
class SessionInsightsBar extends StatefulWidget {
  const SessionInsightsBar({
    super.key,
    required this.sessionId,
    this.runtimeSessionId,
    required this.bridgeService,
    this.selectedModel,
    this.controller,
    this.onCompact,
    this.compact = false,
    this.showLeadingDivider = false,
  });

  final String sessionId;
  final String? runtimeSessionId;
  final BridgeService bridgeService;
  final String? selectedModel;
  final SessionInsightsController? controller;
  final VoidCallback? onCompact;
  final bool compact;
  final bool showLeadingDivider;

  @override
  State<SessionInsightsBar> createState() => _SessionInsightsBarState();
}

class _SessionInsightsBarState extends State<SessionInsightsBar> {
  late SessionInsightsController _controller;
  late bool _ownsController;

  @override
  void initState() {
    super.initState();
    _installController();
  }

  @override
  void didUpdateWidget(covariant SessionInsightsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId == widget.sessionId &&
        oldWidget.runtimeSessionId == widget.runtimeSessionId &&
        oldWidget.bridgeService == widget.bridgeService &&
        oldWidget.controller == widget.controller) {
      return;
    }
    _removeController();
    _installController();
  }

  void _installController() {
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        SessionInsightsController(
          sessionId: widget.sessionId,
          runtimeSessionId: widget.runtimeSessionId,
          bridge: widget.bridgeService,
        );
    _controller.addListener(_changed);
    _controller.start();
  }

  void _removeController() {
    _controller.removeListener(_changed);
    if (_ownsController) _controller.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _removeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usage = _controller.contextUsage;
    final hasContext = usage != null && usage.modelContextWindow > 0;
    final quota = _controller.codexUsage;
    final quotaWindows = _primaryQuotaWindows(quota, widget.selectedModel);
    final fiveHour = quotaWindows.fiveHour;
    final sevenDay = quotaWindows.sevenDay;
    if (!hasContext && !(quota?.hasData ?? false) && !_controller.isLoading) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final percent = hasContext ? (usage.utilization * 100).round() : null;
    final percentValue = percent ?? 0;
    final color = _meterColor(cs, percentValue.toDouble());
    final l = AppLocalizations.of(context);
    final strings = SessionInsightsStrings.of(context);
    final label = hasContext
        ? '$percent% · ${_compactTokens(usage.last.totalTokens)} / '
              '${_compactTokens(usage.modelContextWindow)}'
        : _compactQuotaSummary(l, strings, quota, widget.selectedModel);
    final compactLabel = hasContext
        ? '$percent%'
        : _controller.isLoading
        ? ''
        : strings.quota;
    final semanticParts = <String>[
      if (hasContext) '${strings.context} $percent%',
      if (fiveHour != null)
        '${l.usageFiveHour} ${fiveHour.utilization.clamp(0, 100).round()}%',
      if (sevenDay != null)
        '${l.usageSevenDay} ${sevenDay.utilization.clamp(0, 100).round()}%',
      if (!hasContext && fiveHour == null && sevenDay == null) strings.quota,
    ];
    final bar = Semantics(
      button: true,
      label: semanticParts.join(', '),
      child: InkWell(
        key: ValueKey(
          widget.compact
              ? 'session_insights_mode_chip'
              : 'session_insights_bar',
        ),
        onTap: _showDetails,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 8 : 10,
            vertical: 7,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasContext) ...[
                SizedBox.square(
                  dimension: widget.compact ? 16 : 18,
                  child: CircularProgressIndicator(
                    key: const ValueKey('session_insights_context_ring'),
                    value: usage.utilization,
                    strokeWidth: widget.compact ? 2.25 : 2.5,
                    backgroundColor: cs.surfaceContainerHighest,
                    color: color,
                  ),
                ),
                SizedBox(width: widget.compact ? 5 : 7),
                Text(
                  widget.compact ? compactLabel : label,
                  style: widget.compact
                      ? Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        )
                      : Theme.of(context).textTheme.labelMedium,
                ),
              ] else if (!widget.compact ||
                  (fiveHour == null && sevenDay == null)) ...[
                SizedBox.square(
                  dimension: widget.compact ? 16 : 18,
                  child: _controller.isLoading
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : Icon(Icons.data_usage, size: 18, color: cs.primary),
                ),
                SizedBox(width: widget.compact ? 5 : 7),
                Text(
                  widget.compact ? compactLabel : label,
                  style: widget.compact
                      ? Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        )
                      : Theme.of(context).textTheme.labelMedium,
                ),
              ],
              if (widget.compact && fiveHour != null) ...[
                if (hasContext) const SizedBox(width: 5),
                _CompactQuotaRing(
                  key: const ValueKey('session_insights_five_hour_ring'),
                  label: '5h',
                  window: fiveHour,
                ),
              ],
              if (widget.compact && sevenDay != null) ...[
                if (hasContext || fiveHour != null) const SizedBox(width: 4),
                _CompactQuotaRing(
                  key: const ValueKey('session_insights_seven_day_ring'),
                  label: '7d',
                  window: sevenDay,
                ),
              ],
              if (!widget.compact) ...[
                const SizedBox(width: 2),
                const Icon(Icons.expand_more, size: 17),
              ],
            ],
          ),
        ),
      ),
    );
    if (!widget.showLeadingDivider) return bar;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SizedBox(
            height: 20,
            child: VerticalDivider(
              width: 1,
              thickness: 1,
              color: cs.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ),
        bar,
      ],
    );
  }

  Future<void> _showDetails() async {
    _controller.refresh(force: true);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.82,
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => _InsightsDetails(
            contextUsage: _controller.contextUsage,
            usageInfo: _controller.codexUsage,
            loading: _controller.isLoading,
            onRefresh: () => _controller.refresh(force: true),
            onCompact: widget.onCompact == null
                ? null
                : () {
                    Navigator.of(context).pop();
                    widget.onCompact!();
                  },
          ),
        ),
      ),
    );
  }
}

class _CompactQuotaRing extends StatelessWidget {
  const _CompactQuotaRing({
    super.key,
    required this.label,
    required this.window,
  });

  final String label;
  final SessionUsageWindow window;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final utilization = window.utilization.clamp(0, 100).toDouble();
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 18,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: utilization / 100,
                strokeWidth: 2.25,
                backgroundColor: cs.surfaceContainerHighest,
                color: _meterColor(cs, utilization),
              ),
            ),
            Text(
              label,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 6.5,
                height: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-size details pane used by the local-feature host and `/context`.
class SessionInsightsPanel extends StatefulWidget {
  const SessionInsightsPanel({
    super.key,
    required this.sessionId,
    this.runtimeSessionId,
    required this.bridgeService,
    this.controller,
    this.requestTimeout = const Duration(seconds: 12),
  });

  final String sessionId;
  final String? runtimeSessionId;
  final BridgeService bridgeService;
  final SessionInsightsController? controller;
  final Duration requestTimeout;

  @override
  State<SessionInsightsPanel> createState() => _SessionInsightsPanelState();
}

class _SessionInsightsPanelState extends State<SessionInsightsPanel> {
  late SessionInsightsController _controller;
  late bool _ownsController;

  @override
  void initState() {
    super.initState();
    _installController();
  }

  @override
  void didUpdateWidget(covariant SessionInsightsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId == widget.sessionId &&
        oldWidget.runtimeSessionId == widget.runtimeSessionId &&
        oldWidget.bridgeService == widget.bridgeService &&
        oldWidget.controller == widget.controller &&
        oldWidget.requestTimeout == widget.requestTimeout) {
      return;
    }
    _removeController();
    _installController();
  }

  void _installController() {
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        SessionInsightsController(
          sessionId: widget.sessionId,
          runtimeSessionId: widget.runtimeSessionId,
          bridge: widget.bridgeService,
          requestTimeout: widget.requestTimeout,
        );
    _controller.addListener(_changed);
    _controller.start();
  }

  void _removeController() {
    _controller.removeListener(_changed);
    if (_ownsController) _controller.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _removeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _InsightsDetails(
    contextUsage: _controller.contextUsage,
    usageInfo: _controller.codexUsage,
    loading: _controller.isLoading,
    onRefresh: () => _controller.refresh(force: true),
    onCompact: null,
  );
}

class _InsightsDetails extends StatelessWidget {
  const _InsightsDetails({
    required this.contextUsage,
    required this.usageInfo,
    required this.loading,
    required this.onRefresh,
    required this.onCompact,
  });

  final ContextUsage? contextUsage;
  final SessionUsageInfo? usageInfo;
  final bool loading;
  final VoidCallback onRefresh;
  final VoidCallback? onCompact;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final strings = SessionInsightsStrings.of(context);
    final info = usageInfo;
    final cards = info?.limitCards ?? const <SessionUsageLimitCard>[];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  strings.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                key: const ValueKey('session_insights_refresh'),
                tooltip: l.refresh,
                onPressed: loading ? null : onRefresh,
                icon: loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            children: [
              _ContextCard(usage: contextUsage, onCompact: onCompact),
              const SizedBox(height: 12),
              Text(
                strings.quota,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (info == null)
                _EmptyCard(text: strings.quotaUnavailable)
              else if (cards.isNotEmpty)
                ...cards.map(
                  (card) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _QuotaCard(
                      title: card.displayName,
                      fiveHour: card.fiveHour,
                      sevenDay: card.sevenDay,
                    ),
                  ),
                )
              else
                _QuotaCard(
                  title: 'Codex',
                  fiveHour: info.fiveHour,
                  sevenDay: info.sevenDay,
                ),
              if (info?.source case final source?) ...[
                const SizedBox(height: 4),
                Text(
                  '${strings.source}: $source',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 16),
              _ResetCreditsCard(resetCredits: info?.resetCredits),
            ],
          ),
        ),
      ],
    );
  }
}

class _ContextCard extends StatelessWidget {
  const _ContextCard({required this.usage, required this.onCompact});
  final ContextUsage? usage;
  final VoidCallback? onCompact;

  @override
  Widget build(BuildContext context) {
    final strings = SessionInsightsStrings.of(context);
    final value = usage;
    if (value == null || value.modelContextWindow <= 0) {
      return _EmptyCard(text: strings.contextUnavailable);
    }
    final pct = value.utilization;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(strings.context)),
                Text('${(pct * 100).toStringAsFixed(0)}%'),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: pct),
            const SizedBox(height: 8),
            Text(
              '${_formatTokens(value.last.totalTokens)} / '
              '${_formatTokens(value.modelContextWindow)}',
            ),
            const SizedBox(height: 4),
            Text(
              '${strings.input}: ${_formatTokens(value.last.inputTokens)} · '
              '${strings.cached}: ${_formatTokens(value.last.cachedInputTokens)} · '
              '${strings.output}: ${_formatTokens(value.last.outputTokens)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (onCompact != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  key: const ValueKey('session_insights_compact'),
                  onPressed: onCompact,
                  icon: const Icon(Icons.compress, size: 18),
                  label: Text(strings.compactContext),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QuotaCard extends StatelessWidget {
  const _QuotaCard({
    required this.title,
    required this.fiveHour,
    required this.sevenDay,
  });
  final String title;
  final SessionUsageWindow? fiveHour;
  final SessionUsageWindow? sevenDay;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          if (fiveHour != null)
            _QuotaWindow(
              label: _windowLabel(
                fiveHour!,
                fallback: AppLocalizations.of(context).usageFiveHour,
              ),
              window: fiveHour!,
            ),
          if (fiveHour != null && sevenDay != null) const SizedBox(height: 10),
          if (sevenDay != null)
            _QuotaWindow(
              label: _windowLabel(
                sevenDay!,
                fallback: AppLocalizations.of(context).usageSevenDay,
              ),
              window: sevenDay!,
            ),
          if (fiveHour == null && sevenDay == null)
            Text(SessionInsightsStrings.of(context).quotaUnavailable),
        ],
      ),
    ),
  );
}

class _QuotaWindow extends StatelessWidget {
  const _QuotaWindow({required this.label, required this.window});
  final String label;
  final SessionUsageWindow window;

  @override
  Widget build(BuildContext context) {
    final used = (window.utilization.clamp(0, 100)).toDouble();
    final reset = window.resetsAtDateTime;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text('${used.round()}%'),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: used / 100),
        if (reset != null) ...[
          const SizedBox(height: 4),
          Text(
            '${SessionInsightsStrings.of(context).resetsIn}: '
            '${_remaining(reset)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _ResetCreditsCard extends StatelessWidget {
  const _ResetCreditsCard({required this.resetCredits});
  final SessionUsageResetCredits? resetCredits;

  @override
  Widget build(BuildContext context) {
    final strings = SessionInsightsStrings.of(context);
    final snapshot = resetCredits;
    final credits = sortResetCreditsForDisplay(snapshot?.credits ?? const []);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(strings.resetCredits)),
                if (snapshot != null)
                  Text('${snapshot.availableCount} ${strings.available}'),
              ],
            ),
            const SizedBox(height: 8),
            if (snapshot == null)
              Text(strings.resetCreditsUnavailable)
            else if (credits.isEmpty)
              Text(strings.noResetCreditDetails)
            else
              ...credits.map(
                (credit) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    credit.isAvailable
                        ? Icons.confirmation_number_outlined
                        : Icons.check_circle_outline,
                  ),
                  title: Text(credit.title ?? credit.id),
                  subtitle: Text(
                    [
                      credit.status,
                      if (credit.expiresAtDateTime case final expiry?)
                        _remaining(expiry),
                      ?credit.source,
                    ].join(' · '),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

List<SessionUsageResetCredit> sortResetCreditsForDisplay(
  Iterable<SessionUsageResetCredit> credits,
) => List<SessionUsageResetCredit>.of(credits)
  ..sort((a, b) {
    if (a.isAvailable != b.isAvailable) return a.isAvailable ? -1 : 1;
    final left = a.expiresAtDateTime;
    final right = b.expiresAtDateTime;
    if (left == null && right != null) return 1;
    if (left != null && right == null) return -1;
    final expiryOrder = left == null || right == null
        ? 0
        : left.compareTo(right);
    if (expiryOrder != 0) return expiryOrder;
    return a.id.compareTo(b.id);
  });

({SessionUsageWindow? fiveHour, SessionUsageWindow? sevenDay})
_primaryQuotaWindows(SessionUsageInfo? info, String? selectedModel) {
  if (info == null) return (fiveHour: null, sevenDay: null);
  final card = _quotaCardForModel(info.limitCards, selectedModel);
  if (card != null) {
    return (fiveHour: card.fiveHour, sevenDay: card.sevenDay);
  }
  return (fiveHour: info.fiveHour, sevenDay: info.sevenDay);
}

SessionUsageLimitCard? _quotaCardForModel(
  List<SessionUsageLimitCard> cards,
  String? selectedModel,
) {
  final normalizedModel = selectedModel?.trim().toLowerCase();
  if (normalizedModel != null && normalizedModel.isNotEmpty) {
    for (final card in cards) {
      if (card.id.trim().toLowerCase() == normalizedModel) return card;
    }
  }
  for (final card in cards) {
    if (card.id.trim().toLowerCase() == 'codex') return card;
  }
  for (final card in cards) {
    if (card.fiveHour != null && card.sevenDay != null) return card;
  }
  return cards.isEmpty ? null : cards.first;
}

Color _meterColor(ColorScheme colors, double utilization) {
  if (utilization >= 90) return colors.error;
  if (utilization >= 75) return Colors.orange;
  return colors.primary;
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: const EdgeInsets.all(16), child: Text(text)),
  );
}

String _compactTokens(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
  return value.toString();
}

String _compactQuotaSummary(
  AppLocalizations l,
  SessionInsightsStrings strings,
  SessionUsageInfo? info,
  String? selectedModel,
) {
  if (info == null) return strings.title;
  final selectedCard = _quotaCardForModel(info.limitCards, selectedModel);
  if (selectedCard != null) {
    final primary = selectedCard.fiveHour;
    if (primary != null) {
      return '${_windowLabel(primary, fallback: l.usageFiveHour)} '
          '${primary.utilization.clamp(0, 100).round()}%';
    }
    final secondary = selectedCard.sevenDay;
    if (secondary != null) {
      return '${_windowLabel(secondary, fallback: l.usageSevenDay)} '
          '${secondary.utilization.clamp(0, 100).round()}%';
    }
  }
  final primary = info.fiveHour;
  if (primary != null) {
    return '${_windowLabel(primary, fallback: l.usageFiveHour)} '
        '${primary.utilization.clamp(0, 100).round()}%';
  }
  final secondary = info.sevenDay;
  if (secondary != null) {
    return '${_windowLabel(secondary, fallback: l.usageSevenDay)} '
        '${secondary.utilization.clamp(0, 100).round()}%';
  }
  final available = info.resetCredits?.availableCount;
  if (available != null) {
    return '$available ${strings.available}';
  }
  return strings.quota;
}

String _windowLabel(SessionUsageWindow window, {required String fallback}) {
  final minutes = window.windowDurationMins;
  if (minutes == null || minutes <= 0) return fallback;
  if (minutes % (7 * 24 * 60) == 0) {
    return '${minutes ~/ (7 * 24 * 60) * 7}d';
  }
  if (minutes % (24 * 60) == 0) return '${minutes ~/ (24 * 60)}d';
  if (minutes % 60 == 0) return '${minutes ~/ 60}h';
  return '${minutes}m';
}

String _formatTokens(int value) => value.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (_) => ',',
);

String _remaining(DateTime date) {
  final difference = date.toLocal().difference(DateTime.now());
  if (difference.isNegative) return '0m';
  final days = difference.inDays;
  final hours = difference.inHours % 24;
  final minutes = difference.inMinutes % 60;
  if (days > 0) return '${days}d ${hours}h';
  if (difference.inHours > 0) return '${difference.inHours}h ${minutes}m';
  return '${difference.inMinutes}m';
}
