import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Tool category classification based on CodePilot's approach.
///
/// Each category has a distinct icon, color, and summary extraction rule
/// for compact CLI-like display in chat bubbles.
enum ToolCategory {
  read,
  write,
  bash,
  search,
  subagent,
  compact,
  wait,
  image,
  other,
}

/// Where a semantic tool label is being rendered in its lifecycle.
///
/// [action] is the invocation row, [completed] is the compact activity
/// summary, and [result] is the terminal/result row beneath the invocation.
enum ToolDisplayPhase { action, completed, result }

/// Classify a tool name into a [ToolCategory].
ToolCategory categorizeToolName(String name) {
  // MCP tools have a server prefix (e.g. "mcp__dart-mcp__run_tests")
  if (name.startsWith('mcp__')) return ToolCategory.other;

  return switch (name) {
    'Read' || 'ReadSkill' => ToolCategory.read,
    'Write' ||
    'Edit' ||
    'NotebookEdit' ||
    'MultiEdit' ||
    'FileChange' => ToolCategory.write,
    'Bash' || 'MultiCommand' => ToolCategory.bash,
    'Grep' ||
    'Glob' ||
    'Search' ||
    'ListFiles' ||
    'WebSearch' ||
    'WebFetch' => ToolCategory.search,
    'SubAgent' ||
    'SpawnAgent' ||
    'SendAgentInput' ||
    'ResumeAgent' ||
    'WaitForAgents' ||
    'CloseAgent' ||
    'InterruptAgent' ||
    'ListAgents' ||
    'SubAgentInteraction' ||
    'SubAgentActivity' => ToolCategory.subagent,
    'ContextCompaction' ||
    'UpdatePlan' ||
    'CreateGoal' ||
    'ReadGoal' ||
    'UpdateGoal' => ToolCategory.compact,
    'Wait' || 'Sleep' => ToolCategory.wait,
    'ViewImage' || 'ImageGeneration' => ToolCategory.image,
    _ => ToolCategory.other,
  };
}

/// Extract a compact one-line summary from tool input.
///
/// Rules per category (following CodePilot's `getToolSummary()`):
/// - read/write  → file name only (`main.dart`)
/// - bash        → command, truncated to 60 chars
/// - search      → `"pattern"`, truncated to 50 chars
/// - other       → description or first meaningful key, 50 chars
String getToolSummary(ToolCategory category, Map<String, dynamic> input) {
  return switch (category) {
    ToolCategory.read || ToolCategory.write => _fileSummary(input),
    ToolCategory.bash => _bashSummary(input),
    ToolCategory.search => _searchSummary(input),
    ToolCategory.subagent ||
    ToolCategory.compact ||
    ToolCategory.wait ||
    ToolCategory.image ||
    ToolCategory.other => _otherSummary(input),
  };
}

/// Extract metadata that is safe and cheap to show before a tool is expanded.
///
/// Commands, search queries, prompts, and arbitrary object keys are deliberately
/// omitted here. They can be large and may contain code; the transcript only
/// builds those details after the user opens the disclosure.
String getToolCollapsedSummary(
  ToolCategory category,
  Map<String, dynamic> input,
) {
  return switch (category) {
    ToolCategory.read || ToolCategory.write => _fileSummary(input),
    ToolCategory.subagent => _agentIdentitySummary(input),
    ToolCategory.wait => _waitSummary(input),
    ToolCategory.image => _imageStatusSummary(input),
    ToolCategory.bash ||
    ToolCategory.search ||
    ToolCategory.compact ||
    ToolCategory.other => '',
  };
}

/// Icon for each tool category.
IconData getToolCategoryIcon(ToolCategory category) {
  return switch (category) {
    ToolCategory.read => Icons.description_outlined,
    ToolCategory.write => Icons.edit_note,
    ToolCategory.bash => Icons.terminal,
    ToolCategory.search => Icons.search,
    ToolCategory.subagent => Icons.account_tree_outlined,
    ToolCategory.compact => Icons.compress,
    ToolCategory.wait => Icons.timer_outlined,
    ToolCategory.image => Icons.image_outlined,
    ToolCategory.other => Icons.build_outlined,
  };
}

/// Category-aware color for the tool dot/icon.
Color getToolCategoryColor(ToolCategory category, AppColors appColors) {
  return switch (category) {
    ToolCategory.read => appColors.toolIcon,
    ToolCategory.write => appColors.toolIcon,
    ToolCategory.bash => appColors.toolIcon,
    ToolCategory.search => appColors.toolIcon,
    ToolCategory.subagent => appColors.toolIcon,
    ToolCategory.compact => appColors.toolIcon,
    ToolCategory.wait => appColors.toolIcon,
    ToolCategory.image => appColors.toolIcon,
    ToolCategory.other => appColors.toolIcon,
  };
}

/// Return the full, human-readable input text for a tool (no truncation).
///
/// Used in the expanded/preview card body so the user can see the complete
/// command, file path, search pattern, etc.
String getToolFullInput(ToolCategory category, Map<String, dynamic> input) {
  return switch (category) {
    ToolCategory.bash => _bashFullInput(input),
    ToolCategory.search => _searchFullInput(input),
    ToolCategory.read || ToolCategory.write => _fileFullInput(input),
    ToolCategory.subagent ||
    ToolCategory.compact ||
    ToolCategory.wait ||
    ToolCategory.image ||
    ToolCategory.other => _otherFullInput(input),
  };
}

/// Codex app-server item names are deliberately kept stable on the wire while
/// the transcript uses concise, user-facing labels. Unknown tools retain their
/// original name so newer Bridge versions remain forward compatible.
String getToolDisplayName(
  String name, {
  required AppLocalizations l10n,
  Map<String, dynamic> input = const {},
  ToolDisplayPhase phase = ToolDisplayPhase.action,
}) {
  final normalized = name == 'SubAgent' ? input['tool']?.toString() : name;
  final phaseName = phase.name;
  return switch (normalized) {
    'Read' => l10n.toolDisplayRead(phaseName),
    'ReadSkill' => l10n.toolDisplayReadSkill(phaseName),
    'Write' ||
    'Edit' ||
    'NotebookEdit' ||
    'MultiEdit' ||
    'FileChange' => l10n.toolDisplayFileChange(phaseName),
    'Bash' => l10n.toolDisplayCommand(phaseName),
    'MultiCommand' => l10n.toolDisplayMultipleCommands(phaseName),
    'Search' || 'Grep' => l10n.toolDisplaySearchFiles(phaseName),
    'Glob' || 'ListFiles' => l10n.toolDisplayListFiles(phaseName),
    'WebSearch' => l10n.toolDisplaySearchWeb(phaseName),
    'WebFetch' => l10n.toolDisplayReadWebPage(phaseName),
    'spawnAgent' ||
    'spawn_agent' ||
    'SpawnAgent' => l10n.toolDisplayStartSubAgent(phaseName),
    'sendInput' ||
    'send_input' ||
    'SendAgentInput' => l10n.toolDisplayGuideSubAgent(phaseName),
    'resumeAgent' ||
    'resume_agent' ||
    'ResumeAgent' => l10n.toolDisplayResumeSubAgent(phaseName),
    'wait' || 'WaitForAgents' => l10n.toolDisplayWaitForSubAgents(phaseName),
    'closeAgent' ||
    'close_agent' ||
    'CloseAgent' => l10n.toolDisplayCloseSubAgent(phaseName),
    'interruptAgent' ||
    'interrupt_agent' ||
    'InterruptAgent' => l10n.toolDisplayInterruptSubAgent(phaseName),
    'listAgents' ||
    'list_agents' ||
    'ListAgents' => l10n.toolDisplayListSubAgents(phaseName),
    'SubAgentInteraction' => l10n.toolDisplayInteractWithSubAgent(phaseName),
    'SubAgentActivity' => l10n.toolDisplaySubAgentActivity(phaseName),
    'ContextCompaction' => l10n.toolDisplayCompactContext(phaseName),
    'UpdatePlan' => l10n.toolDisplayUpdatePlan(phaseName),
    'CreateGoal' => l10n.toolDisplayCreateGoal(phaseName),
    'ReadGoal' => l10n.toolDisplayReadGoal(phaseName),
    'UpdateGoal' => l10n.toolDisplayUpdateGoal(phaseName),
    'RequestUserInput' => l10n.toolDisplayRequestUserInput(phaseName),
    'Wait' || 'Sleep' => l10n.toolDisplayWait(phaseName),
    'ViewImage' => l10n.toolDisplayViewImage(phaseName),
    'ImageGeneration' => l10n.toolDisplayGenerateImage(phaseName),
    _ => name,
  };
}

// ---------------------------------------------------------------------------
// Private helpers — full input (untruncated)
// ---------------------------------------------------------------------------

String _bashFullInput(Map<String, dynamic> input) {
  final cmd = input['command']?.toString();
  if (cmd != null && cmd.isNotEmpty) return cmd;
  return _jsonFallback(input);
}

String _searchFullInput(Map<String, dynamic> input) {
  final parts = <String>[];
  final pattern = input['pattern'] ?? input['query'] ?? input['url'];
  if (pattern != null) parts.add(pattern.toString());
  if (input['path'] != null) parts.add('path: ${input['path']}');
  if (input['glob'] != null) parts.add('glob: ${input['glob']}');
  if (input['type'] != null) parts.add('type: ${input['type']}');
  if (parts.isEmpty) return _jsonFallback(input);
  return parts.join('\n');
}

String _fileFullInput(Map<String, dynamic> input) {
  final raw = input['file_path'] ?? input['path'] ?? input['notebook_path'];
  if (raw != null) return raw.toString();
  return _jsonFallback(input);
}

String _otherFullInput(Map<String, dynamic> input) {
  if (input.isEmpty) return '{}';
  final parts = <String>[];
  for (final entry in input.entries) {
    final value = entry.value?.toString() ?? '';
    parts.add('${entry.key}: $value');
  }
  return parts.join('\n');
}

String _jsonFallback(Map<String, dynamic> input) {
  return const JsonEncoder.withIndent('  ').convert(input);
}

// ---------------------------------------------------------------------------
// Private helpers — summary (truncated)
// ---------------------------------------------------------------------------

String _fileSummary(Map<String, dynamic> input) {
  final raw = input['file_path'] ?? input['path'] ?? input['notebook_path'];
  if (raw != null) {
    final path = raw.toString();
    final idx = path.lastIndexOf('/');
    return idx >= 0 ? path.substring(idx + 1) : path;
  }
  // FileChange: extract from changes array
  final changes = input['changes'];
  if (changes is List && changes.isNotEmpty) {
    final first = changes[0];
    if (first is Map) {
      final path = first['path']?.toString() ?? '';
      final name = path.contains('/')
          ? path.substring(path.lastIndexOf('/') + 1)
          : path;
      return changes.length == 1 ? name : '$name +${changes.length - 1} files';
    }
  }
  return _fallbackSummary(input);
}

String _bashSummary(Map<String, dynamic> input) {
  final cmd = input['command']?.toString();
  if (cmd == null || cmd.isEmpty) return _fallbackSummary(input);
  return cmd.length > 60 ? '${cmd.substring(0, 57)}...' : cmd;
}

String _searchSummary(Map<String, dynamic> input) {
  final pattern =
      input['pattern'] ?? input['query'] ?? input['url'] ?? input['prompt'];
  if (pattern == null) return _fallbackSummary(input);
  final s = pattern.toString();
  final truncated = s.length > 50 ? '${s.substring(0, 47)}...' : s;
  return '"$truncated"';
}

String _otherSummary(Map<String, dynamic> input) {
  // Task agent: use description
  final desc = input['description'] ?? input['prompt'] ?? input['skill'];
  if (desc != null) {
    final s = desc.toString();
    return s.length > 50 ? '${s.substring(0, 47)}...' : s;
  }
  return _fallbackSummary(input);
}

String _agentIdentitySummary(Map<String, dynamic> input) {
  final value =
      input['agent_name'] ??
      input['agentName'] ??
      input['agent_id'] ??
      input['agentId'];
  return value?.toString().trim() ?? '';
}

String _waitSummary(Map<String, dynamic> input) {
  final value =
      input['duration'] ??
      input['duration_ms'] ??
      input['timeout'] ??
      input['timeout_ms'];
  return value?.toString().trim() ?? '';
}

String _imageStatusSummary(Map<String, dynamic> input) =>
    input['status']?.toString().replaceAll('_', ' ').trim() ?? '';

String _fallbackSummary(Map<String, dynamic> input) {
  final keys = input.keys.take(3).join(', ');
  return keys.isNotEmpty ? keys : '{}';
}
