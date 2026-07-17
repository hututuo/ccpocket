import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../models/messages.dart';
import '../../../services/bridge_service.dart';
import '../../../services/draft_service.dart';
import '../../../widgets/bubbles/ask_user_question_widget.dart';
import '../l10n/side_chat_strings.dart';
import '../state/side_chat_controller.dart';

class SideChatPanel extends StatefulWidget {
  const SideChatPanel({
    super.key,
    required this.parentSessionId,
    required this.bridgeService,
    required this.draftService,
    this.initialSelection,
    this.selectionRevision = 0,
    this.onClose,
    this.controller,
    this.autoOpen = true,
  });

  final String parentSessionId;
  final BridgeService bridgeService;
  final DraftService draftService;
  final String? initialSelection;
  final int selectionRevision;
  final VoidCallback? onClose;
  final SideChatController? controller;
  final bool autoOpen;

  @override
  State<SideChatPanel> createState() => _SideChatPanelState();
}

class _SideChatPanelState extends State<SideChatPanel> {
  late SideChatController _controller;
  late bool _ownsController;
  late TextEditingController _inputController;
  final ScrollController _scrollController = ScrollController();
  bool _syncingInput = false;
  int _previousEntryCount = 0;

  @override
  void initState() {
    super.initState();
    _attachController();
    _inputController = TextEditingController(text: _controller.draft)
      ..addListener(_onInputChanged);
    _applyInitialSelection();
    _syncInputFromState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.autoOpen) _controller.open();
    });
  }

  void _attachController() {
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        SideChatController(
          parentSessionId: widget.parentSessionId,
          bridge: widget.bridgeService,
          draftService: widget.draftService,
        );
    _controller.addListener(_onControllerChanged);
    _previousEntryCount = _controller.entries.length;
  }

  void _detachController() {
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) {
      _controller.close();
      _controller.dispose();
    }
  }

  void _applyInitialSelection() {
    final selection = widget.initialSelection;
    if (selection != null && selection.trim().isNotEmpty) {
      _controller.prefillSelection(selection);
    }
  }

  @override
  void didUpdateWidget(covariant SideChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final controllerChanged =
        oldWidget.controller != widget.controller ||
        oldWidget.parentSessionId != widget.parentSessionId ||
        oldWidget.bridgeService != widget.bridgeService ||
        oldWidget.draftService != widget.draftService;
    if (controllerChanged) {
      _detachController();
      _attachController();
      _syncInputFromState();
      if (widget.autoOpen) _controller.open();
    }
    if (controllerChanged ||
        oldWidget.selectionRevision != widget.selectionRevision ||
        oldWidget.initialSelection != widget.initialSelection) {
      _applyInitialSelection();
      _syncInputFromState();
    }
  }

  void _onInputChanged() {
    if (_syncingInput) return;
    _controller.updateDraft(_inputController.text);
  }

  void _syncInputFromState() {
    if (_inputController.text == _controller.draft) return;
    _syncingInput = true;
    _inputController.value = TextEditingValue(
      text: _controller.draft,
      selection: TextSelection.collapsed(offset: _controller.draft.length),
    );
    _syncingInput = false;
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _syncInputFromState();
    final shouldScroll = _controller.entries.length != _previousEntryCount;
    _previousEntryCount = _controller.entries.length;
    setState(() {});
    if (shouldScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      });
    }
  }

  void _closePanel() {
    _controller.close();
    widget.onClose?.call();
  }

  @override
  void dispose() {
    _detachController();
    _inputController
      ..removeListener(_onInputChanged)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = SideChatStrings.of(context);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            _Header(
              title: strings.title,
              status: _controller.processStatus,
              closeTooltip: strings.close,
              onClose: _closePanel,
            ),
            _IsolationNotice(text: strings.isolationNotice),
            if (_controller.lifecycle != SideChatLifecycle.open)
              _LifecycleBanner(
                lifecycle: _controller.lifecycle,
                strings: strings,
                errorCode: _controller.errorCode,
                errorMessage: _controller.errorMessage,
                onReopen: _controller.reopen,
              ),
            Expanded(
              child: _controller.entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          strings.empty,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey('side_chat_transcript'),
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                      itemCount: _controller.entries.length,
                      itemBuilder: (context, index) => _MessageBubble(
                        entry: _controller.entries[index],
                        strings: strings,
                      ),
                    ),
            ),
            if (_controller.pendingPermission case final permission?)
              _PermissionCard(
                permission: permission,
                strings: strings,
                onDecision: _controller.respondPermission,
              ),
            if (_controller.pendingQuestion case final question?)
              Padding(
                key: ValueKey('side_chat_question_${question.requestId}'),
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: AskUserQuestionWidget(
                  toolUseId: question.requestId,
                  input: {'questions': question.questions},
                  agentName: strings.title,
                  scrollable: false,
                  onAnswer: _controller.answerQuestion,
                ),
              ),
            _Composer(
              controller: _inputController,
              enabled: _controller.lifecycle == SideChatLifecycle.open,
              canSend: _controller.canSend,
              isRunning: _controller.isRunning,
              overLimit: _controller.draft.length > sideChatInputMaxCharacters,
              strings: strings,
              onSend: _controller.sendDraft,
              onInterrupt: _controller.interrupt,
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.status,
    required this.closeTooltip,
    required this.onClose,
  });

  final String title;
  final String? status;
  final String closeTooltip;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 8, 6),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (status != null)
                Text(
                  status!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('side_chat_close'),
          tooltip: closeTooltip,
          onPressed: onClose,
          icon: const Icon(Icons.close),
        ),
      ],
    ),
  );
}

class _IsolationNotice extends StatelessWidget {
  const _IsolationNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('side_chat_isolation_notice'),
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}

class _LifecycleBanner extends StatelessWidget {
  const _LifecycleBanner({
    required this.lifecycle,
    required this.strings,
    required this.errorCode,
    required this.errorMessage,
    required this.onReopen,
  });

  final SideChatLifecycle lifecycle;
  final SideChatStrings strings;
  final String? errorCode;
  final String? errorMessage;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    final text = switch (lifecycle) {
      SideChatLifecycle.opening => strings.opening,
      SideChatLifecycle.closing => strings.closing,
      SideChatLifecycle.disconnected => strings.disconnected,
      SideChatLifecycle.failed => strings.errorFor(errorCode, errorMessage),
      SideChatLifecycle.closed => strings.closed,
      SideChatLifecycle.open => '',
    };
    final canReopen =
        lifecycle == SideChatLifecycle.closed ||
        lifecycle == SideChatLifecycle.failed ||
        lifecycle == SideChatLifecycle.disconnected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (lifecycle == SideChatLifecycle.opening ||
              lifecycle == SideChatLifecycle.closing)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
          if (canReopen)
            TextButton(
              key: const ValueKey('side_chat_reopen'),
              onPressed: onReopen,
              child: Text(strings.reopen),
            ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.entry, required this.strings});

  final SideChatEntry entry;
  final SideChatStrings strings;

  @override
  Widget build(BuildContext context) {
    final isUser = entry.role == 'user';
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: isUser
              ? colors.primaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MarkdownBody(data: entry.text, selectable: true),
            if (entry.delivery != SideChatEntryDelivery.sent)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  entry.delivery == SideChatEntryDelivery.sending
                      ? strings.sending
                      : strings.sendFailed,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: entry.delivery == SideChatEntryDelivery.failed
                        ? colors.error
                        : colors.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.permission,
    required this.strings,
    required this.onDecision,
  });

  final SideChatPermissionRequest permission;
  final SideChatStrings strings;
  final ValueChanged<SideChatPermissionDecision> onDecision;

  @override
  Widget build(BuildContext context) => Card(
    key: ValueKey('side_chat_permission_${permission.requestId}'),
    margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.permissionTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(permission.toolName),
          if (permission.input.isNotEmpty)
            Text(
              const JsonEncoder.withIndent('  ').convert(permission.input),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: () => onDecision(SideChatPermissionDecision.allow),
                child: Text(strings.allow),
              ),
              OutlinedButton(
                onPressed: () =>
                    onDecision(SideChatPermissionDecision.allowAlways),
                child: Text(strings.allowAlways),
              ),
              TextButton(
                onPressed: () => onDecision(SideChatPermissionDecision.deny),
                child: Text(strings.deny),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.canSend,
    required this.isRunning,
    required this.overLimit,
    required this.strings,
    required this.onSend,
    required this.onInterrupt,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool canSend;
  final bool isRunning;
  final bool overLimit;
  final SideChatStrings strings;
  final bool Function() onSend;
  final VoidCallback onInterrupt;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      12,
      6,
      12,
      8 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (overLimit)
          Text(
            strings.inputTooLong,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('side_chat_input'),
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 6,
                decoration: InputDecoration(
                  hintText: strings.placeholder,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (isRunning)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: IconButton.filledTonal(
                  key: const ValueKey('side_chat_interrupt'),
                  tooltip: strings.interrupt,
                  onPressed: onInterrupt,
                  icon: const Icon(Icons.stop),
                ),
              ),
            IconButton.filled(
              key: const ValueKey('side_chat_send'),
              tooltip: strings.send,
              onPressed: canSend ? () => onSend() : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ],
    ),
  );
}
