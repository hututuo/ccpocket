import 'dart:async';

import 'package:flutter/material.dart';

import '../../codex_session/codex_session_screen.dart';
import '../../../../models/messages.dart';
import '../../../../services/bridge_service.dart';
import '../../../../services/draft_service.dart';
import '../../../../widgets/chat_selection_actions.dart';
import '../l10n/side_chat_strings.dart';
import '../state/ephemeral_side_chat_registry_service.dart';
import 'side_chat_panel.dart';

/// Renders an official in-memory Codex fork with the ordinary conversation UI.
///
/// Hiding this pane keeps the live child in the Bridge registry. The child is
/// destroyed only through an explicit close request, parent teardown, or
/// Bridge shutdown.
class EphemeralSideChatPane extends StatefulWidget {
  const EphemeralSideChatPane({
    super.key,
    required this.parentSessionId,
    required this.bridgeService,
    required this.registryService,
    required this.draftService,
    this.childSessionId,
    this.initialSelection,
    this.selectionRevision = 0,
    this.onClose,
    this.sessionBuilder,
  });

  final String parentSessionId;
  final BridgeService bridgeService;
  final EphemeralSideChatRegistryService registryService;
  final DraftService draftService;
  final String? childSessionId;
  final String? initialSelection;
  final int selectionRevision;
  final VoidCallback? onClose;
  final Widget Function(EphemeralSideChatEntry entry)? sessionBuilder;

  @override
  State<EphemeralSideChatPane> createState() => _EphemeralSideChatPaneState();
}

class _EphemeralSideChatPaneState extends State<EphemeralSideChatPane> {
  EphemeralSideChatEntry? _entry;
  String? _error;
  bool _opening = false;
  bool _useLegacyFallback = false;
  int _openGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.registryService.addListener(_registryChanged);
    _resolveOrOpen();
  }

  @override
  void didUpdateWidget(covariant EphemeralSideChatPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registryService != widget.registryService) {
      oldWidget.registryService.removeListener(_registryChanged);
      widget.registryService.addListener(_registryChanged);
    }
    if (oldWidget.parentSessionId != widget.parentSessionId ||
        oldWidget.bridgeService != widget.bridgeService ||
        oldWidget.registryService != widget.registryService ||
        oldWidget.childSessionId != widget.childSessionId) {
      _resolveOrOpen();
      return;
    }
    if (oldWidget.selectionRevision != widget.selectionRevision &&
        _entry != null) {
      _prepareInitialDraft(_entry!.childSessionId);
    }
  }

  void _resolveOrOpen() {
    final generation = ++_openGeneration;
    _entry = null;
    _error = null;
    _opening = false;
    _useLegacyFallback = false;
    if (!widget.registryService.isSupported) {
      _useLegacyFallback = true;
      if (mounted) setState(() {});
      return;
    }
    final existingId = widget.childSessionId;
    if (existingId != null) {
      final existing = widget.registryService.entryForChild(existingId);
      if (existing != null &&
          existing.parentSessionId == widget.parentSessionId) {
        _entry = existing;
        _prepareInitialDraft(existing.childSessionId);
      } else {
        _error = '';
      }
      if (mounted) setState(() {});
      return;
    }
    _opening = true;
    if (mounted) setState(() {});
    unawaited(_open(generation));
  }

  Future<void> _open(int generation) async {
    try {
      final entry = await widget.registryService.open(widget.parentSessionId);
      if (!mounted || generation != _openGeneration) return;
      _prepareInitialDraft(entry.childSessionId);
      setState(() {
        _entry = entry;
        _opening = false;
      });
    } catch (_) {
      if (!mounted || generation != _openGeneration) return;
      setState(() {
        _opening = false;
        if (!widget.registryService.isSupported) {
          _useLegacyFallback = true;
        } else {
          _error = SideChatStrings.of(context).failed;
        }
      });
    }
  }

  void _registryChanged() {
    if (!mounted || _useLegacyFallback) return;
    final currentId = _entry?.childSessionId ?? widget.childSessionId;
    if (currentId == null) return;
    final next = widget.registryService.entryForChild(currentId);
    if (next != null && next.parentSessionId == widget.parentSessionId) {
      if (!identical(_entry, next)) setState(() => _entry = next);
      return;
    }
    if (_entry != null) {
      setState(() {
        _entry = null;
        _opening = false;
        _error = SideChatStrings.of(context).failed;
      });
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
    _openGeneration++;
    widget.registryService.removeListener(_registryChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_useLegacyFallback) {
      return KeyedSubtree(
        key: const ValueKey('ephemeral_side_chat_legacy_fallback'),
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

    final entry = _entry;
    if (entry != null) {
      final sessionBuilder = widget.sessionBuilder;
      if (sessionBuilder != null) return sessionBuilder(entry);
      return CodexSessionScreen(
        key: ValueKey('ephemeral_side_chat_${entry.childSessionId}'),
        sessionId: entry.childSessionId,
        projectPath: entry.projectPath,
        worktreePath: entry.worktreePath,
        gitBranch: entry.worktreeBranch,
        initialPermissionMode: entry.permissionMode,
        initialSandboxMode: entry.sandboxMode,
        initialApprovalPolicy: entry.approvalPolicy,
        initialApprovalsReviewer: entry.approvalsReviewer,
        onBackToSessions: widget.onClose,
        allowMessageFork: false,
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
                child: _opening || _error == null
                    ? const CircularProgressIndicator.adaptive(
                        key: ValueKey('ephemeral_side_chat_loading'),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error!.isEmpty ? strings.failed : _error!,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              key: const ValueKey('ephemeral_side_chat_retry'),
                              onPressed: _resolveOrOpen,
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
