import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/messages.dart';
import '../../theme/app_theme.dart';

/// A compact activity notice for approval requests reviewed by Codex.
///
/// This deliberately avoids the warning/error palette so actual warnings keep
/// their visual priority. Details stay collapsed until the user asks for them.
class GuardianApprovalNotice extends StatefulWidget {
  final GuardianApprovalMessage message;
  const GuardianApprovalNotice({super.key, required this.message});

  @override
  State<GuardianApprovalNotice> createState() => _GuardianApprovalNoticeState();
}

class _GuardianApprovalNoticeState extends State<GuardianApprovalNotice> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final colorScheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final riskLabel = switch (widget.message.risk) {
      GuardianApprovalRisk.unknown => l.guardianApprovalUnknownRisk,
      GuardianApprovalRisk.low => l.guardianApprovalLowRisk,
      GuardianApprovalRisk.medium => l.guardianApprovalMediumRisk,
      GuardianApprovalRisk.high => l.guardianApprovalHighRisk,
      GuardianApprovalRisk.critical => l.guardianApprovalCriticalRisk,
    };
    final title = switch (widget.message.status) {
      GuardianApprovalStatus.approved => l.guardianApprovalTitle,
      GuardianApprovalStatus.denied => l.guardianApprovalDeniedTitle,
      GuardianApprovalStatus.timedOut => l.guardianApprovalTimedOutTitle,
      GuardianApprovalStatus.aborted => l.guardianApprovalAbortedTitle,
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Semantics(
            button: true,
            label: '$title, $riskLabel',
            hint: _expanded
                ? l.guardianApprovalHideDetails
                : l.guardianApprovalDetails,
            child: Material(
              key: const ValueKey('guardian_approval_card'),
              color: appColors.systemChip.withValues(alpha: 0.62),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: const ValueKey('guardian_approval_details_button'),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  key: const ValueKey('guardian_approval_compact_content'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _GuardianApprovalHeader(
                        title: title,
                        riskLabel: riskLabel,
                        expanded: _expanded,
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOut,
                        child: _expanded
                            ? _GuardianApprovalDetails(message: widget.message)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GuardianApprovalHeader extends StatelessWidget {
  final String title;
  final String riskLabel;
  final bool expanded;
  const _GuardianApprovalHeader({
    required this.title,
    required this.riskLabel,
    required this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final textStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: appColors.subtleText,
      fontWeight: FontWeight.w600,
      fontSize: 12,
      height: 1.1,
    );

    return Row(
      children: [
        Icon(Icons.shield_outlined, size: 14, color: appColors.subtleText),
        const SizedBox(width: 6),
        Expanded(
          child: Wrap(
            spacing: 5,
            runSpacing: 2,
            children: [
              Text(title, style: textStyle),
              Text('· $riskLabel', style: textStyle),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Icon(
          expanded ? Icons.expand_less : Icons.expand_more,
          size: 16,
          color: appColors.subtleText,
        ),
      ],
    );
  }
}

class _GuardianApprovalDetails extends StatelessWidget {
  final GuardianApprovalMessage message;
  const _GuardianApprovalDetails({required this.message});

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final l = AppLocalizations.of(context);
    final authorization = message.authorization?.trim();
    final instruction = _guardianInstruction(message.action);
    final reason = _localizedGuardianReason(l, message.reason);
    final detailStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: appColors.subtleText, height: 1.35);
    final labelStyle = detailStyle?.copyWith(
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(
            height: 1,
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(l.guardianApprovalReasonLabel, style: labelStyle),
            const SizedBox(height: 3),
            Text(reason, style: detailStyle),
          ],
          const SizedBox(height: 7),
          Text(l.guardianApprovalInstructionLabel, style: labelStyle),
          const SizedBox(height: 3),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: appColors.subtleText.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              instruction?.text ?? l.guardianApprovalInstructionUnavailable,
              style: detailStyle?.copyWith(
                fontFamily: instruction?.monospace == true ? 'monospace' : null,
                fontSize: 11.5,
              ),
            ),
          ),
          if (instruction?.workingDirectory case final cwd?) ...[
            const SizedBox(height: 5),
            Text(
              l.guardianApprovalWorkingDirectory(cwd),
              style: detailStyle?.copyWith(fontSize: 11),
            ),
          ],
          if (authorization != null && authorization.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              l.guardianApprovalAuthorization(
                _localizedGuardianAuthorization(l, authorization),
              ),
              style: detailStyle?.copyWith(fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

class _GuardianInstruction {
  final String text;
  final String? workingDirectory;
  final bool monospace;
  const _GuardianInstruction({
    required this.text,
    this.workingDirectory,
    this.monospace = false,
  });
}

_GuardianInstruction? _guardianInstruction(Map<String, dynamic>? action) {
  if (action == null || action.isEmpty) return null;
  final type = action['type'] as String?;
  final cwd = _nonEmptyString(action['cwd']);
  switch (type) {
    case 'command':
      final command = _nonEmptyString(action['command']);
      if (command == null) return null;
      return _GuardianInstruction(
        text: command,
        workingDirectory: cwd,
        monospace: true,
      );
    case 'execve':
      final argv = (action['argv'] as List?)
          ?.whereType<String>()
          .where((value) => value.isNotEmpty)
          .toList();
      final program = _nonEmptyString(action['program']);
      final command = argv != null && argv.isNotEmpty
          ? argv.map(_shellQuoteForDisplay).join(' ')
          : program;
      if (command == null) return null;
      return _GuardianInstruction(
        text: command,
        workingDirectory: cwd,
        monospace: true,
      );
    case 'applyPatch':
      final files = (action['files'] as List?)
          ?.whereType<String>()
          .where((value) => value.isNotEmpty)
          .toList();
      if (files == null || files.isEmpty) return null;
      return _GuardianInstruction(
        text: files.join('\n'),
        workingDirectory: cwd,
        monospace: true,
      );
    case 'networkAccess':
      final target = _nonEmptyString(action['target']);
      final protocol = _nonEmptyString(action['protocol']);
      final host = _nonEmptyString(action['host']);
      final port = action['port'];
      final endpoint =
          target ??
          '${protocol == null ? '' : '$protocol://'}'
              '${host ?? ''}'
              '${port is num ? ':$port' : ''}';
      if (endpoint.isEmpty) return null;
      return _GuardianInstruction(text: endpoint, monospace: true);
    case 'mcpToolCall':
      final title =
          _nonEmptyString(action['toolTitle']) ??
          _nonEmptyString(action['connectorName']);
      final server = _nonEmptyString(action['server']);
      final toolName = _nonEmptyString(action['toolName']);
      final fallback = [server, toolName].whereType<String>().join(' / ');
      final display = title ?? (fallback.isEmpty ? null : fallback);
      if (display == null) return null;
      return _GuardianInstruction(text: display);
    case 'requestPermissions':
      final permissions = action['permissions'];
      if (permissions == null) return null;
      return _GuardianInstruction(
        text: _prettyJson(permissions),
        monospace: true,
      );
    default:
      return _GuardianInstruction(
        text: _prettyJson(action),
        workingDirectory: cwd,
        monospace: true,
      );
  }
}

String _localizedGuardianAuthorization(
  AppLocalizations l,
  String authorization,
) {
  return switch (authorization.trim().toLowerCase()) {
    'unknown' => l.guardianApprovalAuthorizationUnknown,
    'low' => l.guardianApprovalAuthorizationLow,
    'medium' => l.guardianApprovalAuthorizationMedium,
    'high' => l.guardianApprovalAuthorizationHigh,
    _ => authorization,
  };
}

String _localizedGuardianReason(AppLocalizations l, String reason) {
  final normalized = reason.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (RegExp(
    r'^auto-review returned a low[- ]risk allow decision\.?$',
    caseSensitive: false,
  ).hasMatch(normalized)) {
    return l.guardianApprovalLowRiskAllowReason;
  }
  if (RegExp(
    r'^automatic approval review timed out while evaluating the requested approval\.?$',
    caseSensitive: false,
  ).hasMatch(normalized)) {
    return l.guardianApprovalTimedOutReason;
  }
  return reason.trim();
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

String _prettyJson(Object value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

String _shellQuoteForDisplay(String value) {
  if (RegExp(r'^[A-Za-z0-9_./:@%+=,-]+$').hasMatch(value)) return value;
  return "'${value.replaceAll("'", "'\"'\"'")}'";
}
