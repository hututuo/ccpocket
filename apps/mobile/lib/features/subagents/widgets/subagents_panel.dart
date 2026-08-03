import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart'
    show
        AssistantContent,
        AssistantServerMessage,
        ErrorMessage,
        ResultMessage,
        ServerMessage,
        SubagentInfo,
        TextContent,
        ThinkingContent,
        ToolResultMessage,
        ToolUseContent,
        UserInputMessage;
import '../../../services/bridge_service.dart';
import '../l10n/subagents_strings.dart';
import '../state/subagents_controller.dart';

/// Read-only Active/Done browser that can fill either a right pane or a sheet.
class SubagentsPanel extends StatefulWidget {
  const SubagentsPanel({
    super.key,
    required this.sessionId,
    required this.bridgeService,
    this.detachedProviderThreadId,
    this.detachedCodexSourceId,
    this.onClose,
    this.controller,
  });

  final String sessionId;
  final BridgeService bridgeService;
  final String? detachedProviderThreadId;
  final String? detachedCodexSourceId;
  final VoidCallback? onClose;
  final SubagentsController? controller;

  @override
  State<SubagentsPanel> createState() => _SubagentsPanelState();
}

class _SubagentsPanelState extends State<SubagentsPanel> {
  late SubagentsController _controller;
  late bool _ownsController;
  bool _showActive = true;
  String? _selectedThreadId;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        SubagentsController(
          sessionId: widget.sessionId,
          bridge: widget.bridgeService,
          detachedProviderThreadId: widget.detachedProviderThreadId,
          detachedCodexSourceId: widget.detachedCodexSourceId,
        );
    _controller.addListener(_changed);
    _controller.setDetailsVisible(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.subagents.isEmpty) _controller.refresh();
    });
  }

  @override
  void didUpdateWidget(covariant SubagentsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId == widget.sessionId &&
        oldWidget.detachedProviderThreadId == widget.detachedProviderThreadId &&
        oldWidget.detachedCodexSourceId == widget.detachedCodexSourceId &&
        oldWidget.controller == widget.controller &&
        oldWidget.bridgeService == widget.bridgeService) {
      return;
    }
    _controller.removeListener(_changed);
    _controller.setDetailsVisible(false);
    if (_ownsController) _controller.dispose();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        SubagentsController(
          sessionId: widget.sessionId,
          bridge: widget.bridgeService,
          detachedProviderThreadId: widget.detachedProviderThreadId,
          detachedCodexSourceId: widget.detachedCodexSourceId,
        );
    _controller.addListener(_changed);
    _controller.setDetailsVisible(true);
    _selectedThreadId = null;
    _controller.refresh();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.setDetailsVisible(false);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedThreadId;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: selected == null
            ? _buildList(context)
            : _buildDetails(context, selected),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final l = AppLocalizations.of(context);
    final strings = SubagentsStrings.of(context);
    final active = _controller.activeSubagents;
    final done = _controller.doneSubagents;
    final visible = (_showActive ? active : done).toList();
    return Column(
      children: [
        _PanelHeader(
          title: strings.title,
          onClose: widget.onClose,
          trailing: IconButton(
            key: const ValueKey('subagents_refresh'),
            tooltip: l.refresh,
            onPressed: _controller.listLoading ? null : _controller.refresh,
            icon: _controller.listLoading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: true,
                  label: Text('${strings.active} (${active.length})'),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('${strings.done} (${done.length})'),
                ),
              ],
              selected: {_showActive},
              onSelectionChanged: (value) {
                setState(() => _showActive = value.first);
              },
            ),
          ),
        ),
        if (_controller.listError != null)
          _ErrorRow(
            message: _localizedError(strings, _controller.listError!),
            onRetry: _controller.refresh,
          ),
        if (_controller.listTruncated)
          _BoundedResultHint(
            text: strings.truncated(_controller.subagents.length),
          ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    _showActive ? strings.emptyActive : strings.emptyDone,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final agent = visible[index];
                    return _SubagentTile(
                      agent: agent,
                      onTap: () {
                        setState(() => _selectedThreadId = agent.threadId);
                        if (!_controller.histories.containsKey(
                          agent.threadId,
                        )) {
                          _controller.loadHistory(agent.threadId);
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDetails(BuildContext context, String threadId) {
    final l = AppLocalizations.of(context);
    final strings = SubagentsStrings.of(context);
    SubagentInfo? agent;
    for (final item in _controller.subagents) {
      if (item.threadId == threadId) {
        agent = item;
        break;
      }
    }
    final history = _controller.histories[threadId];
    final loading = _controller.historyLoadingIds.contains(threadId);
    final error = _controller.historyErrors[threadId];
    return Column(
      children: [
        _PanelHeader(
          title: agent?.displayName ?? strings.details,
          leading: IconButton(
            tooltip: l.back,
            onPressed: () => setState(() => _selectedThreadId = null),
            icon: const Icon(Icons.arrow_back),
          ),
          onClose: widget.onClose,
          trailing: IconButton(
            key: const ValueKey('subagent_history_refresh'),
            tooltip: l.refresh,
            onPressed: loading ? null : () => _controller.loadHistory(threadId),
            icon: loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ),
        if (agent != null) _AgentMetadata(agent: agent),
        if (error != null)
          _ErrorRow(
            message: _localizedError(strings, error),
            onRetry: () => _controller.loadHistory(threadId),
          ),
        if (history?.truncated ?? false)
          _BoundedResultHint(text: strings.truncated(history!.messages.length)),
        Expanded(
          child: history == null && loading
              ? const Center(child: CircularProgressIndicator())
              : history == null || history.messages.isEmpty
              ? Center(child: Text(strings.emptyHistory))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: history.messages.length,
                  itemBuilder: (context, index) =>
                      _TranscriptMessage(message: history.messages[index]),
                ),
        ),
      ],
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.title,
    this.leading,
    this.trailing,
    this.onClose,
  });

  final String title;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      leading ?? const SizedBox(width: 12),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      ?trailing,
      if (onClose != null)
        IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
    ],
  );
}

class _SubagentTile extends StatelessWidget {
  const _SubagentTile({required this.agent, required this.onTap});
  final SubagentInfo agent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subtitle = [
      agent.role,
      agent.model,
      agent.preview,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: ValueKey('subagent_${agent.threadId}'),
        leading: Icon(
          agent.isActive ? Icons.motion_photos_on_outlined : Icons.task_alt,
          color: agent.isActive ? cs.primary : cs.onSurfaceVariant,
        ),
        title: Text(agent.displayName),
        subtitle: subtitle.isEmpty
            ? Text(agent.status)
            : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _AgentMetadata extends StatelessWidget {
  const _AgentMetadata({required this.agent});
  final SubagentInfo agent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final values = [
      agent.status,
      agent.role,
      agent.model,
      agent.reasoningEffort,
    ].whereType<String>().where((value) => value.isNotEmpty).toList();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        values.join(' · '),
        style: TextStyle(color: cs.onSurfaceVariant),
      ),
    );
  }
}

class _TranscriptMessage extends StatelessWidget {
  const _TranscriptMessage({required this.message});
  final ServerMessage message;

  @override
  Widget build(BuildContext context) {
    final strings = SubagentsStrings.of(context);
    final (label, text) = switch (message) {
      UserInputMessage(:final text) => (strings.user, text),
      AssistantServerMessage(:final message) => (
        strings.assistant,
        message.content
            .map(_assistantContentText)
            .where((v) => v.isNotEmpty)
            .join('\n'),
      ),
      ToolResultMessage(:final content, :final toolName) => (
        toolName ?? strings.tool,
        content,
      ),
      ResultMessage(:final result, :final error) => (
        strings.result,
        result ?? error ?? '',
      ),
      ErrorMessage(:final message) => (strings.error, message),
      _ => ('', ''),
    };
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty)
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 3),
          SelectableText(text),
        ],
      ),
    );
  }
}

String _assistantContentText(AssistantContent content) => switch (content) {
  TextContent(:final text) => text,
  ThinkingContent(:final thinking) => thinking,
  ToolUseContent(:final name, :final input) =>
    '$name\n${const JsonEncoder.withIndent('  ').convert(input)}',
};

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        Expanded(child: Text(message)),
        TextButton(
          onPressed: onRetry,
          child: Text(AppLocalizations.of(context).retry),
        ),
      ],
    ),
  );
}

class _BoundedResultHint extends StatelessWidget {
  const _BoundedResultHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
    child: Row(
      children: [
        Icon(
          Icons.info_outline,
          size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}

String _localizedError(SubagentsStrings strings, String error) =>
    switch (error) {
      'bridge_disconnected' => strings.bridgeDisconnected,
      'unsupported' => strings.unsupported,
      'source_unavailable' ||
      'codex_source_unavailable' => strings.sourceUnavailable,
      'codex_source_mismatch' => strings.sourceMismatch,
      _ => error,
    };
