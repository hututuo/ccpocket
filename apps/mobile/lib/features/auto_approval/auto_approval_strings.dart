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
    required this.disableAll,
    required this.disableAllFailed,
    required this.disabledAll,
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
  final String disableAll;
  final String disableAllFailed;
  final String disabledAll;

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
        'CC Pocket approves eligible requests while this app is connected.',
    disabledDescription: 'Approval requests still wait for you.',
    warningTitle: 'Scope and risk',
    warningBody:
        'Commands, file changes, additional permissions, MCP approvals, and '
        'plan completion may proceed without another prompt. Approving plan '
        'completion immediately starts executing that plan.',
    exclusions:
        'Questions that need your answer and plugin or connector installation '
        'remain manual.',
    unavailable:
        'Auto approval requires a Codex conversation with a stable ID.',
    updateFailed: 'Could not save the auto-approval setting.',
    statusEnabled: 'Auto approval on',
    approvedCount: (count) => '$count approval requests sent in this app run',
    globalTitle: 'Auto approval supervision',
    globalDescription: (count) =>
        '$count conversation${count == 1 ? '' : 's'} will resume supervision when connected.',
    globalNone: 'No conversations are set to auto-approve.',
    disableAll: 'Disable all',
    disableAllFailed: 'Could not disable all auto approvals.',
    disabledAll: 'All auto approvals are disabled.',
  );

  static final _zh = AutoApprovalStrings._(
    title: '自动批准',
    menuLabel: '自动批准',
    switchTitle: '自动批准此会话',
    enabledDescription: 'CC Pocket 在线连接时，会自动批准符合条件的请求。',
    disabledDescription: '审批请求仍会等待你手动处理。',
    warningTitle: '托管范围与风险',
    warningBody: '命令、文件修改、额外权限和 MCP 审批可能不再逐次询问；批准计划完成后会立即开始执行该计划。',
    exclusions: '需要你填写答案的问题，以及插件或连接器安装，仍然必须手动处理。',
    unavailable: '只有带稳定会话标识的 Codex 会话支持自动批准。',
    updateFailed: '无法保存自动批准设置，请重试。',
    statusEnabled: '自动批准已开启',
    approvedCount: (count) => '本次 App 运行已自动发送 $count 次批准',
    globalTitle: '自动批准托管',
    globalDescription: (count) => '已有 $count 个会话启用托管，重新连接后会继续生效。',
    globalNone: '当前没有启用自动批准的会话。',
    disableAll: '全部关闭',
    disableAllFailed: '无法关闭全部自动批准，请重试。',
    disabledAll: '已关闭全部自动批准。',
  );

  static final _ja = AutoApprovalStrings._(
    title: '自動承認',
    menuLabel: '自動承認',
    switchTitle: 'この会話を自動承認',
    enabledDescription: 'CC Pocket の接続中、対象のリクエストを自動承認します。',
    disabledDescription: '承認リクエストは手動操作を待ちます。',
    warningTitle: '範囲とリスク',
    warningBody:
        'コマンド、ファイル変更、追加権限、MCP 承認、計画完了が確認なしで進む場合があります。'
        '計画完了の承認後は、その計画の実行が直ちに開始されます。',
    exclusions: '回答が必要な質問とプラグイン／コネクタのインストールは手動のままです。',
    unavailable: '安定した ID を持つ Codex 会話でのみ利用できます。',
    updateFailed: '自動承認の設定を保存できませんでした。',
    statusEnabled: '自動承認オン',
    approvedCount: (count) => 'この起動中に承認を $count 件送信',
    globalTitle: '自動承認の監督',
    globalDescription: (count) => '接続時に $count 件の会話で自動承認が再開されます。',
    globalNone: '自動承認が有効な会話はありません。',
    disableAll: 'すべて無効化',
    disableAllFailed: 'すべての自動承認を無効化できませんでした。',
    disabledAll: 'すべての自動承認を無効化しました。',
  );

  static final _ko = AutoApprovalStrings._(
    title: '자동 승인',
    menuLabel: '자동 승인',
    switchTitle: '이 대화 자동 승인',
    enabledDescription: 'CC Pocket이 연결된 동안 가능한 요청을 자동 승인합니다.',
    disabledDescription: '승인 요청은 계속 사용자의 처리를 기다립니다.',
    warningTitle: '범위 및 위험',
    warningBody:
        '명령, 파일 변경, 추가 권한, MCP 승인 및 계획 완료가 추가 확인 없이 진행될 수 있습니다. '
        '계획 완료를 승인하면 해당 계획 실행이 즉시 시작됩니다.',
    exclusions: '답변이 필요한 질문과 플러그인 또는 커넥터 설치는 계속 수동으로 처리합니다.',
    unavailable: '안정적인 ID가 있는 Codex 대화에서만 사용할 수 있습니다.',
    updateFailed: '자동 승인 설정을 저장하지 못했습니다.',
    statusEnabled: '자동 승인 켜짐',
    approvedCount: (count) => '이번 앱 실행에서 승인 요청 $count건 전송',
    globalTitle: '자동 승인 관리',
    globalDescription: (count) => '연결되면 대화 $count개에서 자동 승인이 다시 시작됩니다.',
    globalNone: '자동 승인이 설정된 대화가 없습니다.',
    disableAll: '모두 끄기',
    disableAllFailed: '모든 자동 승인을 끄지 못했습니다.',
    disabledAll: '모든 자동 승인을 껐습니다.',
  );
}
