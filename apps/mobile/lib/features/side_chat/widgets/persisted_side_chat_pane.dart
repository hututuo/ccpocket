import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../codex_session/codex_session_screen.dart';
import '../../../../models/messages.dart';
import '../../../../services/bridge_service.dart';
import '../../../../services/draft_service.dart';
import '../../../../widgets/chat_selection_actions.dart';
import '../l10n/side_chat_strings.dart';
import 'side_chat_panel.dart';

/// Opens a persisted official child and renders it with the ordinary Codex
/// conversation screen. The custom legacy panel is retained only as an
/// old-Bridge compatibility fallback.
class PersistedSideChatPane extends StatefulWidget {
  const PersistedSideChatPane({
    super.key,
    required this.parentSessionId,
    required this.bridgeService,
    required this.draftService,
    this.initialSelection,
    this.selectionRevision = 0,
    this.onClose,
  });

  final String parentSessionId;
  final BridgeService bridgeService;
  final DraftService draftService;
  final String? initialSelection;
  final int selectionRevision;
  final VoidCallback? onClose;

  @override
  State<PersistedSideChatPane> createState() => _PersistedSideChatPaneState();
}

class _PersistedSideChatPaneState extends State<PersistedSideChatPane> {
  StreamSubscription<LocalFeatureServerMessage>? _subscription;
  Timer? _timeout;
  String? _requestId;
  PersistedSideChatOpenedMessage? _opened;
  String? _error;
  bool _useLegacyFallback = false;

  @override
  void initState() {
    super.initState();
    _listenAndOpen();
  }

  @override
  void didUpdateWidget(covariant PersistedSideChatPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.parentSessionId != widget.parentSessionId ||
        oldWidget.bridgeService != widget.bridgeService) {
      _listenAndOpen();
    }
  }

  void _listenAndOpen() {
    _subscription?.cancel();
    _timeout?.cancel();
    _opened = null;
    _error = null;
    _useLegacyFallback = false;
    _subscription = widget.bridgeService
        .localFeatureMessagesForSession(widget.parentSessionId)
        .listen(_onMessage);
    if (!widget.bridgeService.bridgeCapabilities.contains(
      persistedSideChatCapability,
    )) {
      setState(() => _useLegacyFallback = true);
      return;
    }
    _open();
  }

  void _open() {
    if (!widget.bridgeService.isConnected) {
      setState(() => _error = SideChatStrings.of(context).disconnected);
      return;
    }
    final requestId = const Uuid().v4();
    _requestId = requestId;
    setState(() {
      _opened = null;
      _error = null;
      _useLegacyFallback = false;
    });
    try {
      widget.bridgeService.send(
        requestOpenPersistedSideChat(
          parentSessionId: widget.parentSessionId,
          requestId: requestId,
        ),
      );
    } catch (_) {
      setState(() => _error = SideChatStrings.of(context).disconnected);
      return;
    }
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 15), () {
      if (!mounted || _requestId != requestId || _opened != null) return;
      setState(() => _error = SideChatStrings.of(context).failed);
    });
  }

  void _onMessage(LocalFeatureServerMessage message) {
    if (!mounted) return;
    if (message case PersistedSideChatOpenedMessage(
      :final requestId,
      :final childSessionId,
      :final error,
      :final errorCode,
    ) when requestId == _requestId) {
      _timeout?.cancel();
      if (childSessionId != null) {
        _prepareInitialDraft(childSessionId);
        setState(() => _opened = message);
      } else if (errorCode == 'unsupported_capability' ||
          errorCode == 'unsupported_bridge') {
        setState(() => _useLegacyFallback = true);
      } else {
        setState(() => _error = error ?? SideChatStrings.of(context).failed);
      }
      return;
    }
    if (message case LocalFeatureRequestErrorMessage(
      featureId: 'persisted_side_chat',
      requestType: 'open_persisted_side_chat',
      :final requestId,
    ) when requestId == _requestId) {
      _timeout?.cancel();
      setState(() => _useLegacyFallback = true);
    }
  }

  void _prepareInitialDraft(String childSessionId) {
    final selected = normalizeChatSelection(widget.initialSelection ?? '');
    if (selected.isEmpty) return;
    final quote = selected
        .split('\n')
        .map((line) => line.isEmpty ? '>' : '> $line')
        .join('\n');
    final current = widget.draftService.getDraft(childSessionId) ?? '';
    final next = current.trim().isEmpty
        ? '$quote\n\n'
        : '${current.trimRight()}\n\n$quote\n\n';
    widget.draftService.saveDraft(childSessionId, next);
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_useLegacyFallback) {
      return KeyedSubtree(
        key: const ValueKey('persisted_side_chat_legacy_fallback'),
        child: SideChatPanel(
          parentSessionId: widget.parentSessionId,
          bridgeService: widget.bridgeService,
          draftService: widget.draftService,
          initialSelection: widget.initialSelection,
          selectionRevision: widget.selectionRevision,
          onClose: widget.onClose,
        ),
      );
    }
    final opened = _opened;
    if (opened != null && opened.childSessionId != null) {
      return CodexSessionScreen(
        key: ValueKey('persisted_side_chat_${opened.childSessionId}'),
        sessionId: opened.childSessionId!,
        projectPath: opened.projectPath,
        worktreePath: opened.worktreePath,
        gitBranch: opened.worktreeBranch,
        initialPermissionMode: opened.permissionMode,
        initialSandboxMode: opened.sandboxMode,
        initialApprovalPolicy: opened.approvalPolicy,
        initialApprovalsReviewer: opened.approvalsReviewer,
        onBackToSessions: widget.onClose,
      );
    }

    final strings = SideChatStrings.of(context);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: strings.close,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: _error == null
                    ? const CircularProgressIndicator.adaptive(
                        key: ValueKey('persisted_side_chat_loading'),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              key: const ValueKey('persisted_side_chat_retry'),
                              onPressed: _open,
                              icon: const Icon(Icons.refresh),
                              label: Text(strings.reopen),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
