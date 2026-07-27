import 'dart:async';

import 'package:flutter/material.dart';

import '../../codex_session/codex_session_screen.dart';
import '../../../../models/messages.dart';
import '../../../../services/bridge_service.dart';
import '../../../../services/draft_service.dart';
import '../../../../widgets/chat_selection_actions.dart';
import '../l10n/side_chat_strings.dart';
import '../state/ephemeral_side_chat_registry_service.dart';

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
    this.forceNew = false,
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
  final bool forceNew;
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
  bool _waitingForCapability = false;
  late String? _requestedChildSessionId;
  late bool _forceNew;
  int _openGeneration = 0;

  @override
  void initState() {
    super.initState();
    _requestedChildSessionId = widget.childSessionId;
    _forceNew = widget.forceNew;
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
        oldWidget.childSessionId != widget.childSessionId ||
        oldWidget.forceNew != widget.forceNew) {
      _requestedChildSessionId = widget.childSessionId;
      _forceNew = widget.forceNew;
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
    _waitingForCapability = false;
    if (!widget.registryService.isSupported) {
      _waitingForCapability = true;
      _error = '';
      if (mounted) setState(() {});
      return;
    }
    final existingId = _requestedChildSessionId;
    if (existingId != null) {
      final existing = widget.registryService.entryForChild(existingId);
      if (existing != null &&
          existing.parentSessionId == widget.parentSessionId) {
        _entry = existing;
        _prepareInitialDraft(existing.childSessionId);
        if (mounted) setState(() {});
        return;
      }
    }
    if (existingId == null && !_forceNew) {
      final existingEntries = widget.registryService.entriesForParent(
        widget.parentSessionId,
      );
      if (existingEntries.isNotEmpty) {
        final existing = existingEntries.first;
        _entry = existing;
        _prepareInitialDraft(existing.childSessionId);
        if (mounted) setState(() {});
        return;
      }
    }
    if (_forceNew && existingId == null) {
      _opening = true;
      if (mounted) setState(() {});
      unawaited(_open(generation));
      return;
    }
    _opening = true;
    if (mounted) setState(() {});
    unawaited(_refreshThenResolve(generation, existingId));
  }

  Future<void> _refreshThenResolve(
    int generation,
    String? requestedChildSessionId,
  ) async {
    try {
      await widget.registryService.refresh();
      if (!mounted || generation != _openGeneration) return;
      if (requestedChildSessionId != null) {
        final existing = widget.registryService.entryForChild(
          requestedChildSessionId,
        );
        if (existing == null ||
            existing.parentSessionId != widget.parentSessionId) {
          setState(() {
            _opening = false;
            _error = SideChatStrings.of(context).failed;
          });
          return;
        }
        _prepareInitialDraft(existing.childSessionId);
        setState(() {
          _entry = existing;
          _opening = false;
        });
        return;
      }

      final existingEntries = widget.registryService.entriesForParent(
        widget.parentSessionId,
      );
      if (existingEntries.isNotEmpty) {
        final existing = existingEntries.first;
        _prepareInitialDraft(existing.childSessionId);
        setState(() {
          _entry = existing;
          _opening = false;
        });
        return;
      }
      await _open(generation);
    } catch (_) {
      if (!mounted || generation != _openGeneration) return;
      setState(() {
        _opening = false;
        _error = SideChatStrings.of(context).failed;
      });
    }
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
        _waitingForCapability = !widget.registryService.isSupported;
        _error = _waitingForCapability
            ? SideChatStrings.of(context).bridgeUpdateRequired
            : SideChatStrings.of(context).failed;
      });
    }
  }

  void _registryChanged() {
    if (!mounted) return;
    if (_waitingForCapability && widget.registryService.isSupported) {
      _resolveOrOpen();
      return;
    }
    final currentId = _entry?.childSessionId ?? _requestedChildSessionId;
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

  void _retry() {
    _requestedChildSessionId = null;
    _forceNew = true;
    _resolveOrOpen();
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
        hideAuxiliaryDock: true,
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
                              _waitingForCapability
                                  ? strings.bridgeUpdateRequired
                                  : (_error!.isEmpty ? strings.failed : _error!),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              key: const ValueKey('ephemeral_side_chat_retry'),
                              onPressed: _retry,
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
