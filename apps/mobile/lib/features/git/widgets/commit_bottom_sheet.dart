import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/app_localizations.dart';
import '../../../widgets/workspace_pane_chrome.dart';
import '../state/commit_cubit.dart';
import '../state/commit_state.dart';

/// Shows the commit bottom sheet.
void showCommitBottomSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: macOSModalBottomSheetConstraints(context),
    builder: (_) => BlocProvider.value(
      value: context.read<CommitCubit>(),
      child: const _CommitBottomSheetContent(),
    ),
  );
}

class _CommitBottomSheetContent extends StatefulWidget {
  const _CommitBottomSheetContent();

  @override
  State<_CommitBottomSheetContent> createState() =>
      _CommitBottomSheetContentState();
}

class _CommitBottomSheetContentState extends State<_CommitBottomSheetContent> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CommitCubit, CommitState>(
      builder: (context, state) {
        final cubit = context.read<CommitCubit>();
        final cs = Theme.of(context).colorScheme;
        final l = AppLocalizations.of(context);
        final isIdle = state.status == CommitStatus.idle;
        final isBusy =
            state.status == CommitStatus.committing ||
            state.status == CommitStatus.pushing;

        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Title
                Text(
                  l.gitCommit,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 12),

                // Success state
                if (state.status == CommitStatus.success) ...[
                  Icon(Icons.check_circle, color: cs.primary, size: 48),
                  const SizedBox(height: 8),
                  Text(
                    state.commitHash != null
                        ? l.gitCommittedHash(state.commitHash!)
                        : l.gitSuccess,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      cubit.reset();
                      Navigator.of(context).pop();
                    },
                    child: Text(l.done),
                  ),
                ]
                // Error state
                else if (state.status == CommitStatus.error) ...[
                  Icon(Icons.error_outline, color: cs.error, size: 48),
                  const SizedBox(height: 8),
                  Text(
                    state.error ?? l.gitUnknownError,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.error, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: cubit.reset, child: Text(l.tryAgain)),
                ]
                // Idle / busy state
                else ...[
                  // Commit message input
                  TextField(
                    key: const ValueKey('commit_message_field'),
                    controller: _controller,
                    enabled: !state.autoGenerate && isIdle,
                    onChanged: cubit.setMessage,
                    decoration: InputDecoration(
                      hintText: state.autoGenerate
                          ? l.gitAutoGenerateWithAi
                          : l.gitCommitMessage,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLines: 3,
                    minLines: 1,
                  ),
                  const SizedBox(height: 8),

                  // Auto-generate toggle
                  Row(
                    children: [
                      Switch(
                        key: const ValueKey('auto_generate_switch'),
                        value: state.autoGenerate,
                        onChanged: isIdle
                            ? (_) => cubit.toggleAutoGenerate()
                            : null,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        l.gitAutoGenerateMessage,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Progress indicator
                  if (isBusy) ...[
                    LinearProgressIndicator(
                      key: const ValueKey('commit_progress'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      switch (state.status) {
                        CommitStatus.committing => l.gitCommitting,
                        CommitStatus.pushing => l.gitPushing,
                        _ => '',
                      },
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Action buttons
                  if (isIdle) ...[
                    FilledButton.icon(
                      key: const ValueKey('commit_button_action'),
                      onPressed: _canCommit(state) ? cubit.commit : null,
                      icon: const Icon(Icons.check),
                      label: Text(l.gitCommit),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const ValueKey('commit_push_button'),
                      onPressed: _canCommit(state) ? cubit.commitAndPush : null,
                      icon: const Icon(Icons.upload),
                      label: Text(l.gitCommitAndPush),
                    ),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  bool _canCommit(CommitState state) {
    return state.autoGenerate || state.message.trim().isNotEmpty;
  }
}
