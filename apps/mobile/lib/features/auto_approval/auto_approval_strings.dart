import 'package:flutter/widgets.dart';

class AutoApprovalStrings {
  const AutoApprovalStrings._({
    required this.title,
    required this.menuLabel,
    required this.switchTitle,
    required this.enabledDescription,
    required this.disabledDescription,
    required this.warningTitle,
    required this.warningBody,
    required this.exclusions,
    required this.unavailable,
    required this.updateFailed,
    required this.statusEnabled,
    required this.approvedCount,
    required this.globalTitle,
    required this.globalDescription,
    required this.globalNone,
    required this.globalPending,
    required this.disableAll,
    required this.disableAllFailed,
    required this.disabledAll,
    required this.disableQueued,
  });

  final String title;
  final String menuLabel;
  final String switchTitle;
  final String enabledDescription;
  final String disabledDescription;
  final String warningTitle;
  final String warningBody;
  final String exclusions;
  final String unavailable;
  final String updateFailed;
  final String statusEnabled;
  final String Function(int count) approvedCount;
  final String globalTitle;
  final String Function(int count) globalDescription;
  final String globalNone;
  final String globalPending;
  final String disableAll;
  final String disableAllFailed;
  final String disabledAll;
  final String disableQueued;

  static AutoApprovalStrings of(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;
    return switch (language) {
      'zh' => _zh,
      'ja' => _ja,
      'ko' => _ko,
      _ => _en,
    };
  }

  static final _en = AutoApprovalStrings._(
    title: 'Auto approval',
    menuLabel: 'Auto approval',
    switchTitle: 'Auto-approve this conversation',
    enabledDescription:
        'The Bridge on your computer keeps supervising this conversation, even when the phone disconnects.',
    disabledDescription: 'Approval requests still wait for you.',
    warningTitle: 'Scope and risk',
    warningBody:
        'Commands, network access, file changes, additional permissions, MCP '
        'approvals, and plan completion may proceed without another prompt. '
        'Approving plan completion immediately starts executing that plan.',
    exclusions:
        'Destructive shell commands such as rm, questions that need your '
        'answer, and plugin or connector installation remain manual.',
    unavailable:
        'Connect a current Bridge and open a Codex conversation with a stable ID.',
    updateFailed: 'Could not save the auto-approval setting.',
    statusEnabled: 'Auto approval on',
    approvedCount: (count) => '$count requests approved by this Bridge run',
    globalTitle: 'Auto approval supervision',
    globalDescription: (count) =>
        '$count conversation${count == 1 ? '' : 's'} supervised on the computer.',
    globalNone: 'No conversations are set to auto-approve.',
    globalPending:
        'Emergency stop queued; waiting for the computer to confirm it.',
    disableAll: 'Disable all',
    disableAllFailed: 'Could not disable all auto approvals.',
    disabledAll: 'All auto approvals are disabled.',
    disableQueued:
        'The emergency stop is queued and will reach the computer when Bridge reconnects.',
  );

  static final _zh = AutoApprovalStrings._(
    title: '自动批准',
    menuLabel: '自动批准',
    switchTitle: '自动批准此会话',
    enabledDescription: '由电脑端 Bridge 持续托管；即使手机断开，仍会继续处理符合条件的审批。',
    disabledDescription: '审批请求仍会等待你手动处理。',
    warningTitle: '托管范围与风险',
    warningBody: '命令、联网访问、文件修改、额外权限和 MCP 审批可能不再逐次询问；批准计划完成后会立即开始执行该计划。',
    exclusions: 'rm 等破坏性 shell 命令、需要你填写答案的问题，以及插件或连接器安装，始终保留人工处理。',
    unavailable: '请连接最新版 Bridge，并打开带稳定标识的 Codex 会话。',
    updateFailed: '无法保存自动批准设置，请重试。',
    statusEnabled: '自动批准已开启',
    approvedCount: (count) => '本次 Bridge 运行已自动批准 $count 次',
    globalTitle: '自动批准托管',
    globalDescription: (count) => '电脑端已有 $count 个会话启用持续托管。',
    globalNone: '当前没有启用自动批准的会话。',
    globalPending: '关闭请求已排队，正在等待电脑端确认。',
    disableAll: '全部关闭',
    disableAllFailed: '无法关闭全部自动批准，请重试。',
    disabledAll: '已关闭全部自动批准。',
    disableQueued: '电脑当前未连接；关闭请求已排队，Bridge 重连后会立即应用。',
  );

  static final _ja = AutoApprovalStrings._(
    title: '自動承認',
    menuLabel: '自動承認',
    switchTitle: 'この会話を自動承認',
    enabledDescription: 'パソコン側の Bridge が、スマートフォン切断後も監督を続けます。',
    disabledDescription: '承認リクエストは手動操作を待ちます。',
    warningTitle: '範囲とリスク',
    warningBody:
        'コマンド、ネットワーク、ファイル変更、追加権限、MCP 承認、計画完了が確認なしで進む場合があります。'
        '計画完了の承認後は、その計画の実行が直ちに開始されます。',
    exclusions: 'rm などの破壊的コマンド、回答が必要な質問、プラグイン／コネクタのインストールは手動のままです。',
    unavailable: '最新の Bridge と安定した ID を持つ Codex 会話が必要です。',
    updateFailed: '自動承認の設定を保存できませんでした。',
    statusEnabled: '自動承認オン',
    approvedCount: (count) => 'この起動中に承認を $count 件送信',
    globalTitle: '自動承認の監督',
    globalDescription: (count) => '接続時に $count 件の会話で自動承認が再開されます。',
    globalNone: '自動承認が有効な会話はありません。',
    globalPending: '緊急停止を予約しました。パソコン側の確認を待っています。',
    disableAll: 'すべて無効化',
    disableAllFailed: 'すべての自動承認を無効化できませんでした。',
    disabledAll: 'すべての自動承認を無効化しました。',
    disableQueued: 'パソコンは未接続です。Bridge の再接続時に緊急停止を適用します。',
  );

  static final _ko = AutoApprovalStrings._(
    title: '자동 승인',
    menuLabel: '자동 승인',
    switchTitle: '이 대화 자동 승인',
    enabledDescription: '컴퓨터의 Bridge가 휴대전화 연결이 끊겨도 계속 관리합니다.',
    disabledDescription: '승인 요청은 계속 사용자의 처리를 기다립니다.',
    warningTitle: '범위 및 위험',
    warningBody:
        '명령, 네트워크, 파일 변경, 추가 권한, MCP 승인 및 계획 완료가 추가 확인 없이 진행될 수 있습니다. '
        '계획 완료를 승인하면 해당 계획 실행이 즉시 시작됩니다.',
    exclusions: 'rm 같은 파괴적 명령, 답변이 필요한 질문, 플러그인 또는 커넥터 설치는 수동으로 처리합니다.',
    unavailable: '최신 Bridge와 안정적인 ID가 있는 Codex 대화가 필요합니다.',
    updateFailed: '자동 승인 설정을 저장하지 못했습니다.',
    statusEnabled: '자동 승인 켜짐',
    approvedCount: (count) => '이번 앱 실행에서 승인 요청 $count건 전송',
    globalTitle: '자동 승인 관리',
    globalDescription: (count) => '연결되면 대화 $count개에서 자동 승인이 다시 시작됩니다.',
    globalNone: '자동 승인이 설정된 대화가 없습니다.',
    globalPending: '긴급 중지가 대기 중이며 컴퓨터의 확인을 기다리고 있습니다.',
    disableAll: '모두 끄기',
    disableAllFailed: '모든 자동 승인을 끄지 못했습니다.',
    disabledAll: '모든 자동 승인을 껐습니다.',
    disableQueued: '컴퓨터가 연결되어 있지 않습니다. Bridge 재연결 시 긴급 중지를 적용합니다.',
  );
}
