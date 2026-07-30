import 'package:flutter/widgets.dart';

/// Feature-local copy for the read-only subagent browser's text.
class SubagentsStrings {
  const SubagentsStrings({
    required this.title,
    required this.active,
    required this.done,
    required this.details,
    required this.emptyActive,
    required this.emptyDone,
    required this.emptyHistory,
    required this.bridgeDisconnected,
    required this.unsupported,
    required this.sourceUnavailable,
    required this.sourceMismatch,
    required this.truncatedTemplate,
    required this.user,
    required this.assistant,
    required this.tool,
    required this.result,
    required this.error,
  });

  final String title;
  final String active;
  final String done;
  final String details;
  final String emptyActive;
  final String emptyDone;
  final String emptyHistory;
  final String bridgeDisconnected;
  final String unsupported;
  final String sourceUnavailable;
  final String sourceMismatch;
  final String truncatedTemplate;
  final String user;
  final String assistant;
  final String tool;
  final String result;
  final String error;

  String truncated(int count) =>
      truncatedTemplate.replaceAll('{count}', count.toString());

  static SubagentsStrings of(BuildContext context) =>
      forLocale(Localizations.localeOf(context));

  static SubagentsStrings forLocale(Locale locale) =>
      switch (locale.languageCode) {
        'zh' => _zh,
        'ja' => _ja,
        'ko' => _ko,
        _ => _en,
      };

  static const _en = SubagentsStrings(
    title: 'Subagents',
    active: 'Active',
    done: 'Done',
    details: 'Subagent details',
    emptyActive: 'No active subagents',
    emptyDone: 'No completed subagents',
    emptyHistory: 'No history available',
    bridgeDisconnected: 'Reconnect to the Bridge to load subagents.',
    unsupported: 'This Bridge does not support subagent browsing yet.',
    sourceUnavailable:
        'Reconnect after the Bridge confirms the Codex data source.',
    sourceMismatch:
        'This session belongs to a different Codex data source. Reopen it from the current Bridge.',
    truncatedTemplate: 'Bounded response: {count} shown.',
    user: 'User',
    assistant: 'Assistant',
    tool: 'Tool',
    result: 'Result',
    error: 'Error',
  );

  static const _zh = SubagentsStrings(
    title: '子 Agent',
    active: '进行中',
    done: '已完成',
    details: '子 Agent 详情',
    emptyActive: '没有进行中的子 Agent',
    emptyDone: '没有已完成的子 Agent',
    emptyHistory: '暂无历史记录',
    bridgeDisconnected: '请重新连接 Bridge 后查看子 Agent。',
    unsupported: '当前 Bridge 暂不支持查看子 Agent。',
    sourceUnavailable: '请等待 Bridge 确认 Codex 数据来源后重试。',
    sourceMismatch: '此会话属于另一 Codex 数据来源，请从当前 Bridge 重新打开。',
    truncatedTemplate: '为保证性能，仅显示 {count} 条结果。',
    user: '用户',
    assistant: '助手',
    tool: '工具',
    result: '结果',
    error: '错误',
  );

  static const _ja = SubagentsStrings(
    title: 'サブエージェント',
    active: '実行中',
    done: '完了',
    details: 'サブエージェントの詳細',
    emptyActive: '実行中のサブエージェントはありません',
    emptyDone: '完了したサブエージェントはありません',
    emptyHistory: '履歴はありません',
    bridgeDisconnected: 'Bridge に再接続してサブエージェントを読み込んでください。',
    unsupported: 'この Bridge はまだサブエージェントの表示に対応していません。',
    sourceUnavailable: 'Bridge が Codex データソースを確認してから再試行してください。',
    sourceMismatch: 'このセッションは別の Codex データソースに属しています。現在の Bridge から開き直してください。',
    truncatedTemplate: 'パフォーマンスのため、{count} 件の結果のみ表示しています。',
    user: 'ユーザー',
    assistant: 'アシスタント',
    tool: 'ツール',
    result: '結果',
    error: 'エラー',
  );

  static const _ko = SubagentsStrings(
    title: '하위 에이전트',
    active: '진행 중',
    done: '완료',
    details: '하위 에이전트 세부 정보',
    emptyActive: '진행 중인 하위 에이전트가 없습니다',
    emptyDone: '완료된 하위 에이전트가 없습니다',
    emptyHistory: '사용 가능한 기록이 없습니다',
    bridgeDisconnected: 'Bridge에 다시 연결하여 하위 에이전트를 불러오세요.',
    unsupported: '이 Bridge는 아직 하위 에이전트 보기를 지원하지 않습니다.',
    sourceUnavailable: 'Bridge가 Codex 데이터 소스를 확인한 뒤 다시 시도하세요.',
    sourceMismatch: '이 세션은 다른 Codex 데이터 소스에 속합니다. 현재 Bridge에서 다시 여세요.',
    truncatedTemplate: '성능을 위해 제한된 결과 {count}개만 표시합니다.',
    user: '사용자',
    assistant: '어시스턴트',
    tool: '도구',
    result: '결과',
    error: '오류',
  );
}
