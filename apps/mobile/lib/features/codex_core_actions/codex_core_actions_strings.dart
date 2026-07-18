import 'package:flutter/widgets.dart';

class CodexCoreActionsStrings {
  const CodexCoreActionsStrings({
    required this.title,
    required this.compactTitle,
    required this.compactBody,
    required this.compactAction,
    required this.compactConfirmTitle,
    required this.compactConfirmBody,
    required this.reviewTitle,
    required this.reviewBody,
    required this.reviewAction,
    required this.uncommitted,
    required this.baseBranch,
    required this.commit,
    required this.custom,
    required this.branchHint,
    required this.commitHint,
    required this.commitTitleHint,
    required this.instructionsHint,
    required this.inlineOnly,
    required this.mcpTitle,
    required this.mcpBody,
    required this.refresh,
    required this.noServers,
    required this.tools,
    required this.accepted,
    required this.busy,
    required this.unsupported,
    required this.disconnected,
    required this.failed,
    required this.cancel,
  });

  final String title;
  final String compactTitle;
  final String compactBody;
  final String compactAction;
  final String compactConfirmTitle;
  final String compactConfirmBody;
  final String reviewTitle;
  final String reviewBody;
  final String reviewAction;
  final String uncommitted;
  final String baseBranch;
  final String commit;
  final String custom;
  final String branchHint;
  final String commitHint;
  final String commitTitleHint;
  final String instructionsHint;
  final String inlineOnly;
  final String mcpTitle;
  final String mcpBody;
  final String refresh;
  final String noServers;
  final String tools;
  final String accepted;
  final String busy;
  final String unsupported;
  final String disconnected;
  final String failed;
  final String cancel;

  static CodexCoreActionsStrings of(BuildContext context) =>
      switch (Localizations.localeOf(context).languageCode) {
        'zh' => _zh,
        'ja' => _ja,
        'ko' => _ko,
        _ => _en,
      };

  static const _en = CodexCoreActionsStrings(
    title: 'Codex tools',
    compactTitle: 'Compact context',
    compactBody:
        'Ask Codex to compact this conversation. Available only while idle.',
    compactAction: 'Compact',
    compactConfirmTitle: 'Compact this conversation?',
    compactConfirmBody:
        'Codex will summarize older context. The conversation stays available.',
    reviewTitle: 'Code review',
    reviewBody: 'Start an official inline Codex review.',
    reviewAction: 'Start review',
    uncommitted: 'Uncommitted changes',
    baseBranch: 'Against base branch',
    commit: 'Commit',
    custom: 'Custom instructions',
    branchHint: 'Base branch, for example main',
    commitHint: 'Commit SHA',
    commitTitleHint: 'Optional title',
    instructionsHint: 'What should Codex review?',
    inlineOnly: 'Review results will appear in this conversation.',
    mcpTitle: 'MCP servers',
    mcpBody: 'Read-only status from the current Codex runtime.',
    refresh: 'Refresh',
    noServers: 'No MCP servers reported.',
    tools: 'tools',
    accepted: 'Accepted by Codex. Progress will appear in the conversation.',
    busy: 'Wait for the current turn to finish, then try again.',
    unsupported: 'This Bridge or Codex backend does not support this action.',
    disconnected: 'Reconnect to the Bridge to use Codex tools.',
    failed: 'The action could not be completed.',
    cancel: 'Cancel',
  );

  static const _zh = CodexCoreActionsStrings(
    title: 'Codex 工具',
    compactTitle: '压缩上下文',
    compactBody: '让 Codex 压缩当前对话的上下文；只能在本轮结束后执行。',
    compactAction: '开始压缩',
    compactConfirmTitle: '压缩当前对话？',
    compactConfirmBody: 'Codex 会总结较早的上下文，对话记录仍会保留。',
    reviewTitle: '代码审查',
    reviewBody: '启动 Codex 官方的会话内代码审查。',
    reviewAction: '开始审查',
    uncommitted: '未提交的更改',
    baseBranch: '与基准分支比较',
    commit: '指定 Commit',
    custom: '自定义要求',
    branchHint: '基准分支，例如 main',
    commitHint: 'Commit SHA',
    commitTitleHint: '可选标题',
    instructionsHint: '希望 Codex 审查什么？',
    inlineOnly: '审查结果会出现在当前对话中。',
    mcpTitle: 'MCP 服务器',
    mcpBody: '只读查看当前 Codex 运行时报告的状态。',
    refresh: '刷新',
    noServers: '当前没有报告 MCP 服务器。',
    tools: '个工具',
    accepted: 'Codex 已接收，后续进度会显示在当前对话中。',
    busy: '请等待当前一轮结束后再试。',
    unsupported: '当前 Bridge 或 Codex 后端不支持此操作。',
    disconnected: '重新连接 Bridge 后才能使用 Codex 工具。',
    failed: '操作未能完成。',
    cancel: '取消',
  );

  static const _ja = CodexCoreActionsStrings(
    title: 'Codex ツール',
    compactTitle: 'コンテキストを圧縮',
    compactBody: '会話を Codex に圧縮させます。アイドル時のみ利用できます。',
    compactAction: '圧縮',
    compactConfirmTitle: 'この会話を圧縮しますか？',
    compactConfirmBody: 'Codex が古いコンテキストを要約します。会話履歴は残ります。',
    reviewTitle: 'コードレビュー',
    reviewBody: 'Codex の公式インラインレビューを開始します。',
    reviewAction: 'レビュー開始',
    uncommitted: '未コミットの変更',
    baseBranch: 'ベースブランチとの差分',
    commit: 'コミット',
    custom: 'カスタム指示',
    branchHint: '例: main',
    commitHint: 'Commit SHA',
    commitTitleHint: '任意のタイトル',
    instructionsHint: 'レビュー内容を入力',
    inlineOnly: '結果はこの会話に表示されます。',
    mcpTitle: 'MCP サーバー',
    mcpBody: '現在の Codex ランタイムの読み取り専用ステータスです。',
    refresh: '更新',
    noServers: 'MCP サーバーは報告されていません。',
    tools: 'ツール',
    accepted: 'Codex が受け付けました。進行状況は会話に表示されます。',
    busy: '現在のターンが終わってから再試行してください。',
    unsupported: 'この Bridge または Codex は対応していません。',
    disconnected: 'Bridge に再接続してください。',
    failed: '操作を完了できませんでした。',
    cancel: 'キャンセル',
  );

  static const _ko = CodexCoreActionsStrings(
    title: 'Codex 도구',
    compactTitle: '컨텍스트 압축',
    compactBody: 'Codex가 대화를 압축합니다. 유휴 상태에서만 가능합니다.',
    compactAction: '압축',
    compactConfirmTitle: '이 대화를 압축할까요?',
    compactConfirmBody: 'Codex가 이전 컨텍스트를 요약하며 대화 기록은 유지됩니다.',
    reviewTitle: '코드 리뷰',
    reviewBody: 'Codex 공식 인라인 리뷰를 시작합니다.',
    reviewAction: '리뷰 시작',
    uncommitted: '커밋하지 않은 변경',
    baseBranch: '기준 브랜치와 비교',
    commit: '커밋',
    custom: '사용자 지정 지시',
    branchHint: '예: main',
    commitHint: 'Commit SHA',
    commitTitleHint: '선택 제목',
    instructionsHint: '리뷰할 내용을 입력하세요',
    inlineOnly: '결과는 이 대화에 표시됩니다.',
    mcpTitle: 'MCP 서버',
    mcpBody: '현재 Codex 런타임의 읽기 전용 상태입니다.',
    refresh: '새로고침',
    noServers: '보고된 MCP 서버가 없습니다.',
    tools: '도구',
    accepted: 'Codex가 요청을 받았습니다. 진행 상황은 대화에 표시됩니다.',
    busy: '현재 턴이 끝난 후 다시 시도하세요.',
    unsupported: '현재 Bridge 또는 Codex에서 지원하지 않습니다.',
    disconnected: 'Bridge에 다시 연결하세요.',
    failed: '작업을 완료하지 못했습니다.',
    cancel: '취소',
  );
}
