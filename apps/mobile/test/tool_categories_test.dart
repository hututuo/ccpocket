import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/utils/tool_categories.dart';

void main() {
  group('Codex semantic tool labels', () {
    test('covers command, skill, sub-agent, and compaction activities', () {
      final l = lookupAppLocalizations(const Locale('zh'));
      expect(getToolDisplayName('MultiCommand', l10n: l), '运行多个命令');
      expect(getToolDisplayName('ReadSkill', l10n: l), '读取 Skill');
      expect(getToolDisplayName('SpawnAgent', l10n: l), '开启子 Agent');
      expect(getToolDisplayName('ResumeAgent', l10n: l), '继续子 Agent');
      expect(getToolDisplayName('InterruptAgent', l10n: l), '中断子 Agent');
      expect(getToolDisplayName('ListAgents', l10n: l), '查看子 Agent');
      expect(getToolDisplayName('SubAgentInteraction', l10n: l), '与子 Agent 交互');
      expect(getToolDisplayName('ContextCompaction', l10n: l), '压缩上下文');
      expect(getToolDisplayName('UpdatePlan', l10n: l), '更新计划');
      expect(getToolDisplayName('RequestUserInput', l10n: l), '请求用户输入');
      expect(categorizeToolName('InterruptAgent'), ToolCategory.subagent);
      expect(categorizeToolName('SubAgentInteraction'), ToolCategory.subagent);
      expect(categorizeToolName('UpdatePlan'), ToolCategory.compact);
    });

    test('keeps unknown future tool names intact', () {
      final l = lookupAppLocalizations(const Locale('en'));
      expect(getToolDisplayName('FutureCodexTool', l10n: l), 'FutureCodexTool');
    });

    test('matches Codex lifecycle labels for exploration and commands', () {
      final l = lookupAppLocalizations(const Locale('zh'));
      expect(
        getToolDisplayName('Read', l10n: l, phase: ToolDisplayPhase.completed),
        '已读取',
      );
      expect(
        getToolDisplayName(
          'ListFiles',
          l10n: l,
          phase: ToolDisplayPhase.completed,
        ),
        '已列出文件',
      );
      expect(
        getToolDisplayName(
          'Search',
          l10n: l,
          phase: ToolDisplayPhase.completed,
        ),
        '已搜索',
      );
      expect(
        getToolDisplayName('Bash', l10n: l, phase: ToolDisplayPhase.completed),
        '已运行命令',
      );
      expect(
        getToolDisplayName('Bash', l10n: l, phase: ToolDisplayPhase.result),
        '终端命令已完成',
      );
    });

    test('localizes tool names for Japanese and Korean', () {
      final ja = lookupAppLocalizations(const Locale('ja'));
      final ko = lookupAppLocalizations(const Locale('ko'));

      expect(getToolDisplayName('Bash', l10n: ja), 'コマンドを実行');
      expect(
        getToolDisplayName(
          'SpawnAgent',
          l10n: ja,
          phase: ToolDisplayPhase.completed,
        ),
        'サブ Agent を開始しました',
      );
      expect(getToolDisplayName('WebSearch', l10n: ko), '웹 검색');
      expect(
        getToolDisplayName(
          'ImageGeneration',
          l10n: ko,
          phase: ToolDisplayPhase.result,
        ),
        '이미지 생성 완료',
      );
    });
  });

  group('getToolFullInput', () {
    test('bash: returns full command string', () {
      final result = getToolFullInput(ToolCategory.bash, {
        'command':
            'git add README.md README.ja.md apps/mobile/fastlane/metadata/en-US/description.txt',
      });
      expect(
        result,
        'git add README.md README.ja.md apps/mobile/fastlane/metadata/en-US/description.txt',
      );
    });

    test('bash: returns multiline command as-is', () {
      final cmd =
          'find /Users/project -name "*.dart" -not -path "*/build/*" | xargs grep -l "ToolUseTile" | sort | head -20';
      final result = getToolFullInput(ToolCategory.bash, {'command': cmd});
      expect(result, cmd);
    });

    test('bash: falls back to JSON when no command key', () {
      final result = getToolFullInput(ToolCategory.bash, {'foo': 'bar'});
      expect(result, contains('"foo"'));
    });

    test('search: returns pattern with path and glob', () {
      final result = getToolFullInput(ToolCategory.search, {
        'pattern': 'class\\s+ToolUseTile',
        'path': '/Users/project/apps/mobile/lib',
        'glob': '**/*.dart',
      });
      expect(result, contains('class\\s+ToolUseTile'));
      expect(result, contains('/Users/project/apps/mobile/lib'));
      expect(result, contains('**/*.dart'));
    });

    test('search: returns pattern only when no other fields', () {
      final result = getToolFullInput(ToolCategory.search, {
        'pattern': 'searchTerm',
      });
      expect(result, contains('searchTerm'));
    });

    test('read: returns full file path', () {
      final result = getToolFullInput(ToolCategory.read, {
        'file_path':
            '/Users/project/apps/mobile/lib/widgets/bubbles/assistant_bubble.dart',
      });
      expect(
        result,
        '/Users/project/apps/mobile/lib/widgets/bubbles/assistant_bubble.dart',
      );
    });

    test('write: returns full file path', () {
      final result = getToolFullInput(ToolCategory.write, {
        'file_path': '/Users/project/lib/main.dart',
      });
      expect(result, '/Users/project/lib/main.dart');
    });

    test('other: formats key-value pairs', () {
      final result = getToolFullInput(ToolCategory.other, {
        'description': 'Run the tests',
        'prompt': 'Check all files',
      });
      expect(result, contains('description'));
      expect(result, contains('Run the tests'));
    });

    test('fallback: returns JSON for empty input', () {
      final result = getToolFullInput(ToolCategory.other, {});
      expect(result, '{}');
    });
  });

  group('getToolCollapsedSummary', () {
    test('keeps file and agent identity but hides executable content', () {
      expect(
        getToolCollapsedSummary(ToolCategory.read, {
          'file_path': '/Users/project/lib/main.dart',
        }),
        'main.dart',
      );
      expect(
        getToolCollapsedSummary(ToolCategory.subagent, {
          'agent_id': 'agent-42',
          'prompt': 'private delegated instructions',
        }),
        'agent-42',
      );
      expect(
        getToolCollapsedSummary(ToolCategory.bash, {
          'command': 'rm -rf private-build-output',
        }),
        isEmpty,
      );
      expect(
        getToolCollapsedSummary(ToolCategory.search, {
          'query': 'secret implementation detail',
        }),
        isEmpty,
      );
      expect(
        getToolCollapsedSummary(ToolCategory.compact, {
          'title': 'Update plan',
          'todos': const [],
        }),
        isEmpty,
      );
    });
  });
}
