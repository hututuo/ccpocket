import 'package:flutter/widgets.dart';

class NotificationSettingsStrings {
  const NotificationSettingsStrings._(this.languageCode);

  factory NotificationSettingsStrings.of(BuildContext context) {
    return NotificationSettingsStrings._(
      Localizations.localeOf(context).languageCode,
    );
  }

  final String languageCode;

  bool get _zh => languageCode == 'zh';
  bool get _ja => languageCode == 'ja';
  bool get _ko => languageCode == 'ko';

  String get title =>
      _pick(zh: '通知设置', ja: '通知設定', ko: '알림 설정', en: 'Notification settings');

  String get entrySubtitle => _pick(
    zh: '选择需要处理、任务结束和中间进度通知',
    ja: '対応待ち、完了、途中経過の通知を選択',
    ko: '조치 필요, 완료 및 진행 알림 선택',
    en: 'Choose action, completion, and progress alerts',
  );

  String get deliverySection =>
      _pick(zh: '通知能力', ja: '通知機能', ko: '알림 기능', en: 'Delivery');

  String get masterTitle =>
      _pick(zh: '远程推送', ja: 'リモートプッシュ', ko: '원격 푸시', en: 'Remote push');

  String get masterConnectedSubtitle => _pick(
    zh: 'App 挂起或锁屏时，由当前电脑继续推送',
    ja: 'App の停止中やロック画面でも接続中のコンピュータから通知します',
    ko: '앱이 중단되거나 잠긴 동안 현재 컴퓨터에서 푸시',
    en: 'Continue delivery from this computer while the app is suspended',
  );

  String get masterDisconnectedSubtitle => _pick(
    zh: '连接到 Bridge 后即可配置远程推送',
    ja: 'Bridge に接続するとリモートプッシュを設定できます',
    ko: 'Bridge 연결 후 원격 푸시 설정 가능',
    en: 'Connect to a Bridge to configure remote push',
  );

  String get localNotifications =>
      _pick(zh: '本地通知', ja: 'ローカル通知', ko: '로컬 알림', en: 'Local notifications');

  String get localEnabled => _pick(
    zh: '系统已允许显示通知',
    ja: 'システムで通知が許可されています',
    ko: '시스템에서 알림이 허용됨',
    en: 'Allowed by the system',
  );

  String get localDisabled => _pick(
    zh: '系统尚未允许通知',
    ja: 'システムで通知が許可されていません',
    ko: '시스템 알림이 허용되지 않음',
    en: 'Not allowed by the system',
  );

  String get localUnavailable => _pick(
    zh: '当前平台无法检测',
    ja: '現在のプラットフォームでは確認できません',
    ko: '현재 플랫폼에서 확인할 수 없음',
    en: 'Unavailable on this platform',
  );

  String get requestPermission =>
      _pick(zh: '允许通知', ja: '通知を許可', ko: '알림 허용', en: 'Allow notifications');

  String get remoteNotifications => _pick(
    zh: '锁屏与挂起推送',
    ja: 'ロック画面・停止中のプッシュ',
    ko: '잠금 화면 및 일시 중단 푸시',
    en: 'Lock-screen and suspended push',
  );

  String get remoteEnabled => _pick(
    zh: '远程推送 Token 已就绪',
    ja: 'リモートプッシュ Token の準備が完了',
    ko: '원격 푸시 토큰 준비 완료',
    en: 'Remote push token is ready',
  );

  String get remoteDisabled =>
      _pick(zh: '尚未开启', ja: 'まだ有効ではありません', ko: '아직 켜지지 않음', en: 'Not enabled');

  String get remoteUnavailable => _pick(
    zh: '当前签名或 Firebase 配置未提供远程推送',
    ja: '現在の署名または Firebase 設定では利用できません',
    ko: '현재 서명 또는 Firebase 설정에서 사용할 수 없음',
    en: 'Unavailable with the current signing or Firebase configuration',
  );

  String get remotePending => _pick(
    zh: '正在检测或等待 Bridge 同步',
    ja: '確認中、または Bridge の同期待ち',
    ko: '확인 중이거나 Bridge 동기화 대기 중',
    en: 'Checking or waiting for Bridge sync',
  );

  String get selfSignedExplanation => _pick(
    zh: '本地通知不依赖 App Store 签名。App 被 iOS 完全挂起后仍能收到的远程推送，取决于 AltStore 重签后的描述文件是否保留 APNs 权限；上方会按实际 Token 状态显示。',
    ja: 'ローカル通知は App Store 署名を必要としません。iOS による完全停止後のリモート通知は、AltStore の再署名プロファイルに APNs 権限が残るかで決まります。',
    ko: '로컬 알림은 App Store 서명이 필요하지 않습니다. iOS가 앱을 완전히 중단한 뒤의 원격 푸시는 AltStore 재서명 프로필의 APNs 권한에 따라 달라집니다.',
    en: 'Local alerts do not require App Store signing. Remote delivery after iOS fully suspends the app depends on whether the AltStore signing profile preserves APNs entitlement.',
  );

  String get typesSection =>
      _pick(zh: '通知类型', ja: '通知タイプ', ko: '알림 유형', en: 'Notification types');

  String get actionRequiredTitle =>
      _pick(zh: '需要你处理', ja: '対応が必要', ko: '조치 필요', en: 'Action required');

  String get actionRequiredSubtitle => _pick(
    zh: '审批请求、Codex 提问和计划确认',
    ja: '承認リクエスト、質問、プラン確認',
    ko: '승인 요청, 질문 및 계획 확인',
    en: 'Approvals, questions, and plan confirmation',
  );

  String get taskCompletedTitle =>
      _pick(zh: '任务完成', ja: 'タスク完了', ko: '작업 완료', en: 'Task completed');

  String get taskCompletedSubtitle => _pick(
    zh: '一轮对话正常完成时通知',
    ja: '1 回の処理が正常に完了したとき',
    ko: '한 번의 작업이 정상 완료될 때',
    en: 'When a turn finishes successfully',
  );

  String get taskFailedTitle =>
      _pick(zh: '任务失败', ja: 'タスク失敗', ko: '작업 실패', en: 'Task failed');

  String get taskFailedSubtitle => _pick(
    zh: '运行出错或异常结束时通知',
    ja: 'エラーまたは異常終了時',
    ko: '오류 또는 비정상 종료 시',
    en: 'When a run errors or ends unexpectedly',
  );

  String get progressTitle => _pick(
    zh: '中间进度',
    ja: '途中経過',
    ko: '중간 진행 상황',
    en: 'Intermediate progress',
  );

  String get progressSubtitle => _pick(
    zh: '工具阶段变化时提醒；每个会话最多约 45 秒一次',
    ja: 'ツール段階の変化を通知。セッションごとに約 45 秒に 1 回まで',
    ko: '도구 단계 변경 시 알림. 세션당 약 45초에 한 번으로 제한',
    en: 'Tool-stage changes, rate-limited to about once every 45 seconds',
  );

  String get foregroundTitle => _pick(
    zh: 'App 打开时也显示横幅',
    ja: 'App 使用中もバナーを表示',
    ko: '앱 사용 중에도 배너 표시',
    en: 'Show banners while the app is open',
  );

  String get foregroundSubtitle => _pick(
    zh: '正在查看同一个会话时仍会自动静音',
    ja: '同じセッションを表示中は引き続き抑制します',
    ko: '같은 세션을 보고 있을 때는 계속 음소거됨',
    en: 'Still suppressed while viewing the same session',
  );

  String get contentSection => _pick(
    zh: '内容与兼容性',
    ja: '内容と互換性',
    ko: '내용 및 호환성',
    en: 'Content and compatibility',
  );

  String get oldBridgeWarning => _pick(
    zh: '当前 Bridge 还不支持细分通知。设置会保存在手机上；更新后端后自动生效。旧后端仍只发送原有的关键与完成通知。',
    ja: '現在の Bridge は通知の細分化に未対応です。設定は端末に保存され、Bridge 更新後に自動適用されます。',
    ko: '현재 Bridge는 세부 알림 설정을 지원하지 않습니다. 설정은 기기에 저장되고 Bridge 업데이트 후 자동 적용됩니다.',
    en: 'This Bridge does not support granular notification filters yet. Your choices are saved and will apply after the Bridge is updated.',
  );

  String summary({
    required bool actionRequired,
    required bool completed,
    required bool failed,
    required bool progress,
  }) {
    final enabled = <String>[
      if (actionRequired) _pick(zh: '需要处理', ja: '対応待ち', ko: '조치', en: 'action'),
      if (completed) _pick(zh: '完成', ja: '完了', ko: '완료', en: 'completion'),
      if (failed) _pick(zh: '失败', ja: '失敗', ko: '실패', en: 'failure'),
      if (progress) _pick(zh: '进度', ja: '進捗', ko: '진행', en: 'progress'),
    ];
    if (enabled.isEmpty) {
      return _pick(
        zh: '所有类型均已关闭',
        ja: 'すべてのタイプがオフ',
        ko: '모든 유형 꺼짐',
        en: 'All categories are off',
      );
    }
    final joined = enabled.join(_zh || _ja ? '、' : ', ');
    return _pick(
      zh: '已开启：$joined',
      ja: '有効：$joined',
      ko: '켜짐: $joined',
      en: 'Enabled: $joined',
    );
  }

  String _pick({
    required String zh,
    required String ja,
    required String ko,
    required String en,
  }) {
    if (_zh) return zh;
    if (_ja) return ja;
    if (_ko) return ko;
    return en;
  }
}
