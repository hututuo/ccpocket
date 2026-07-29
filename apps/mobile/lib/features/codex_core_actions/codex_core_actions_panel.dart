import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/messages.dart'
    show
        CodexMcpServerStatus,
        CodexReviewBaseBranchTarget,
        CodexReviewCommitTarget,
        CodexReviewCustomTarget,
        CodexReviewTarget,
        CodexReviewUncommittedTarget;
import '../../services/bridge_service.dart';
import 'codex_core_actions_controller.dart';
import 'codex_core_actions_strings.dart';

enum CodexReviewTargetKind { uncommitted, baseBranch, commit, custom }

class CodexCoreActionsPanel extends StatefulWidget {
  const CodexCoreActionsPanel({
    super.key,
    required this.sessionId,
    required this.bridge,
    this.initialSection,
    this.controller,
  });

  final String sessionId;
  final BridgeService bridge;
  final String? initialSection;
  final CodexCoreActionsController? controller;

  @override
  State<CodexCoreActionsPanel> createState() => _CodexCoreActionsPanelState();
}

class _CodexCoreActionsPanelState extends State<CodexCoreActionsPanel> {
  late CodexCoreActionsController _controller;
  late bool _ownsController;
  CodexReviewTargetKind _targetKind = CodexReviewTargetKind.uncommitted;
  final _branchController = TextEditingController(text: 'main');
  final _shaController = TextEditingController();
  final _titleController = TextEditingController();
  final _instructionsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        CodexCoreActionsController(
          sessionId: widget.sessionId,
          bridge: widget.bridge,
        );
    _controller.addListener(_changed);
    _controller.start();
    if (widget.initialSection == 'mcp') {
      scheduleMicrotask(_controller.refreshMcpStatus);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (_ownsController) _controller.dispose();
    _branchController.dispose();
    _shaController.dispose();
    _titleController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = CodexCoreActionsStrings.of(context);
    final sections = <String, Widget>{
      'review': _reviewCard(context, strings),
      'mcp': _mcpCard(context, strings),
    };
    final first = sections.remove(widget.initialSection);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          ?first,
          for (final section in sections.values) ...[
            if (first != null || section != sections.values.first)
              const SizedBox(height: 12),
            section,
          ],
        ],
      ),
    );
  }

  Widget _reviewCard(BuildContext context, CodexCoreActionsStrings strings) {
    return _ActionCard(
      key: const ValueKey('codex_core_review_card'),
      icon: Icons.rate_review_outlined,
      title: strings.reviewTitle,
      body: strings.reviewBody,
      footer: _actionFeedback(strings, action: 'review'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<CodexReviewTargetKind>(
            key: const ValueKey('codex_review_target'),
            initialValue: _targetKind,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: [
              DropdownMenuItem(
                value: CodexReviewTargetKind.uncommitted,
                child: Text(strings.uncommitted),
              ),
              DropdownMenuItem(
                value: CodexReviewTargetKind.baseBranch,
                child: Text(strings.baseBranch),
              ),
              DropdownMenuItem(
                value: CodexReviewTargetKind.commit,
                child: Text(strings.commit),
              ),
              DropdownMenuItem(
                value: CodexReviewTargetKind.custom,
                child: Text(strings.custom),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _targetKind = value);
            },
          ),
          const SizedBox(height: 10),
          ..._reviewTargetFields(strings),
          Text(
            strings.inlineOnly,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            key: const ValueKey('codex_review_start'),
            onPressed: !_controller.connected || _controller.actionLoading
                ? null
                : _startReview,
            icon: _controller.actionLoading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(strings.reviewAction),
          ),
        ],
      ),
    );
  }

  List<Widget> _reviewTargetFields(CodexCoreActionsStrings strings) =>
      switch (_targetKind) {
        CodexReviewTargetKind.uncommitted => const [],
        CodexReviewTargetKind.baseBranch => [
          TextField(
            key: const ValueKey('codex_review_branch'),
            controller: _branchController,
            decoration: InputDecoration(
              labelText: strings.branchHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
        ],
        CodexReviewTargetKind.commit => [
          TextField(
            key: const ValueKey('codex_review_sha'),
            controller: _shaController,
            decoration: InputDecoration(
              labelText: strings.commitHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('codex_review_title'),
            controller: _titleController,
            decoration: InputDecoration(
              labelText: strings.commitTitleHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
        ],
        CodexReviewTargetKind.custom => [
          TextField(
            key: const ValueKey('codex_review_instructions'),
            controller: _instructionsController,
            minLines: 3,
            maxLines: 7,
            decoration: InputDecoration(
              labelText: strings.instructionsHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
        ],
      };

  void _startReview() {
    CodexReviewTarget target;
    try {
      target = switch (_targetKind) {
        CodexReviewTargetKind.uncommitted =>
          const CodexReviewUncommittedTarget(),
        CodexReviewTargetKind.baseBranch => CodexReviewBaseBranchTarget(
          _branchController.text,
        ),
        CodexReviewTargetKind.commit => CodexReviewCommitTarget(
          _shaController.text,
          title: _titleController.text,
        ),
        CodexReviewTargetKind.custom => CodexReviewCustomTarget(
          _instructionsController.text,
        ),
      };
      target.toJson();
    } on ArgumentError catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message.toString())));
      return;
    }
    _controller.requestReview(target);
  }

  Widget _mcpCard(BuildContext context, CodexCoreActionsStrings strings) {
    return _ActionCard(
      key: const ValueKey('codex_core_mcp_card'),
      icon: Icons.dns_outlined,
      title: strings.mcpTitle,
      body: strings.mcpBody,
      footer: _mcpFeedback(strings),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('codex_mcp_refresh'),
            onPressed: !_controller.connected || _controller.mcpLoading
                ? null
                : _controller.refreshMcpStatus,
            icon: _controller.mcpLoading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(strings.refresh),
          ),
          if (!_controller.mcpLoading &&
              _controller.mcpLoaded &&
              _controller.mcpError == null &&
              _controller.servers.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(strings.noServers),
            ),
          for (final server in _controller.servers)
            _McpServerTile(server: server, strings: strings),
          if (_controller.serversTruncated)
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('…')),
        ],
      ),
    );
  }

  Widget? _actionFeedback(
    CodexCoreActionsStrings strings, {
    required String action,
  }) {
    final result = _controller.lastActionResult;
    if (result?.action == action && result?.accepted == true) {
      return _Feedback(text: strings.accepted, success: true);
    }
    final code = _controller.actionErrorCode;
    if (code == null) return null;
    return _Feedback(
      text: codexCoreActionErrorText(strings, code, _controller.actionError),
      success: false,
    );
  }

  Widget? _mcpFeedback(CodexCoreActionsStrings strings) {
    final code = _controller.mcpErrorCode;
    if (code == null) return null;
    return _Feedback(
      text: codexCoreActionErrorText(strings, code, _controller.mcpError),
      success: false,
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.child,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(body),
            const SizedBox(height: 14),
            child,
            if (footer case final value?) ...[
              const SizedBox(height: 10),
              value,
            ],
          ],
        ),
      ),
    );
  }
}

class _Feedback extends StatelessWidget {
  const _Feedback({required this.text, required this.success});

  final String text;
  final bool success;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      text,
      key: ValueKey(success ? 'codex_action_success' : 'codex_action_error'),
      style: TextStyle(color: success ? cs.primary : cs.error),
    );
  }
}

class _McpServerTile extends StatelessWidget {
  const _McpServerTile({required this.server, required this.strings});

  final CodexMcpServerStatus server;
  final CodexCoreActionsStrings strings;

  @override
  Widget build(BuildContext context) {
    final title = server.serverInfo?.title ?? server.name;
    return ExpansionTile(
      key: ValueKey('codex_mcp_server_${server.name}'),
      tilePadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(
        '${server.authStatus} · ${server.toolCount} ${strings.tools}',
      ),
      children: [
        for (final tool in server.tools)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 16),
            title: Text(tool.title ?? tool.name),
            subtitle: tool.description == null
                ? null
                : Text(tool.description!, maxLines: 3),
          ),
        if (server.toolsTruncated)
          const ListTile(dense: true, title: Text('…')),
      ],
    );
  }
}
