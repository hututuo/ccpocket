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
    required this.bridgeService,
    this.controller,
  });

  final String sessionId;
  final BridgeService bridgeService;
  final SessionInsightsController? controller;

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
    if (!hasContext && !(quota?.hasData ?? false) && !_controller.isLoading) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final percent = hasContext ? (usage.utilization * 100).round() : null;
    final percentValue = percent ?? 0;
    final color = percentValue >= 90
        ? cs.error
        : percentValue >= 75
        ? Colors.orange
        : cs.primary;
    final l = AppLocalizations.of(context);
    final strings = SessionInsightsStrings.of(context);
    final label = hasContext
        ? '$percent% · ${_compactTokens(usage.last.totalTokens)} / '
              '${_compactTokens(usage.modelContextWindow)}'
        : _compactQuotaSummary(l, strings, quota);
    return Semantics(
      button: true,
      label: hasContext ? '${strings.context} $percent%' : strings.quota,
      child: InkWell(
        key: const ValueKey('session_insights_bar'),
        onTap: _showDetails,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 18,
                child: hasContext
                    ? CircularProgressIndicator(
                        value: usage.utilization,
                        strokeWidth: 2.5,
                        backgroundColor: cs.surfaceContainerHighest,
                        color: color,
                      )
                    : _controller.isLoading
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : Icon(Icons.data_usage, size: 18, color: cs.primary),
              ),
              const SizedBox(width: 7),
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(width: 2),
              const Icon(Icons.expand_more, size: 17),
            ],
          ),
        ),
      ),
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
          ),
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
    required this.bridgeService,
    this.controller,
  });

  final String sessionId;
  final BridgeService bridgeService;
  final SessionInsightsController? controller;

  @override
  State<SessionInsightsPanel> createState() => _SessionInsightsPanelState();
}

class _SessionInsightsPanelState extends State<SessionInsightsPanel> {
  late SessionInsightsController _controller;
  late bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        SessionInsightsController(
          sessionId: widget.sessionId,
          bridge: widget.bridgeService,
        );
    _controller.addListener(_changed);
    _controller.start();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _InsightsDetails(
    contextUsage: _controller.contextUsage,
    usageInfo: _controller.codexUsage,
    loading: _controller.isLoading,
    onRefresh: () => _controller.refresh(force: true),
  );
}

class _InsightsDetails extends StatelessWidget {
  const _InsightsDetails({
    required this.contextUsage,
    required this.usageInfo,
    required this.loading,
    required this.onRefresh,
  });

  final ContextUsage? contextUsage;
  final SessionUsageInfo? usageInfo;
  final bool loading;
  final VoidCallback onRefresh;

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
              _ContextCard(usage: contextUsage),
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
  const _ContextCard({required this.usage});
  final ContextUsage? usage;

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
) {
  if (info == null) return strings.title;
  for (final card in info.limitCards) {
    final primary = card.fiveHour;
    if (primary != null) {
      return '${_windowLabel(primary, fallback: l.usageFiveHour)} '
          '${primary.utilization.clamp(0, 100).round()}%';
    }
    final secondary = card.sevenDay;
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
