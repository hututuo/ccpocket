import 'dart:convert';

import 'package:flutter/material.dart';

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
    'SubAgentActivity' => ToolCategory.subagent,
    'ContextCompaction' => ToolCategory.compact,
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
  required bool zh,
  Map<String, dynamic> input = const {},
}) {
  final normalized = name == 'SubAgent' ? input['tool']?.toString() : name;
  return switch (normalized) {
    'Read' => zh ? '读取文件' : 'Read file',
    'ReadSkill' => zh ? '读取 Skill' : 'Read Skill',
    'Write' ||
    'Edit' ||
    'NotebookEdit' ||
    'MultiEdit' ||
    'FileChange' => zh ? '修改文件' : 'File change',
    'Bash' => zh ? '运行命令' : 'Run command',
    'MultiCommand' => zh ? '运行多个命令' : 'Run multiple commands',
    'Search' || 'Grep' => zh ? '搜索内容' : 'Search files',
    'Glob' || 'ListFiles' => zh ? '查看目录' : 'List files',
    'WebSearch' => zh ? '搜索网页' : 'Search web',
    'WebFetch' => zh ? '读取网页' : 'Read web page',
    'spawnAgent' ||
    'spawn_agent' ||
    'SpawnAgent' => zh ? '开启子 Agent' : 'Start sub-agent',
    'sendInput' ||
    'send_input' ||
    'SendAgentInput' => zh ? '引导子 Agent' : 'Guide sub-agent',
    'resumeAgent' ||
    'resume_agent' ||
    'ResumeAgent' => zh ? '继续子 Agent' : 'Resume sub-agent',
    'wait' || 'WaitForAgents' => zh ? '等待子 Agent' : 'Wait for sub-agents',
    'closeAgent' ||
    'close_agent' ||
    'CloseAgent' => zh ? '关闭子 Agent' : 'Close sub-agent',
    'SubAgentActivity' => zh ? '子 Agent 活动' : 'Sub-agent activity',
    'ContextCompaction' => zh ? '压缩上下文' : 'Compact context',
    'Wait' || 'Sleep' => zh ? '等待' : 'Wait',
    'ViewImage' => zh ? '查看图片' : 'View image',
    'ImageGeneration' => zh ? '生成图片' : 'Generate image',
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

String _fallbackSummary(Map<String, dynamic> input) {
  final keys = input.keys.take(3).join(', ');
  return keys.isNotEmpty ? keys : '{}';
}
