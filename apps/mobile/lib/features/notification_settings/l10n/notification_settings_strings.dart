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

  String get remoteRelayUnavailable => _pick(
    zh: 'Bridge 尚未配置推送中继；请先更新并配置 Bridge',
    ja: 'Bridge のプッシュ中継が未設定です',
    ko: 'Bridge 푸시 릴레이가 구성되지 않음',
    en: 'The Bridge push relay is not configured',
  );

  String get remoteRegistrationFailed => _pick(
    zh: '推送 Token 未被后端确认，请检查 Bridge 日志与网络',
    ja: 'バックエンドでプッシュ Token を確認できませんでした',
    ko: '백엔드에서 푸시 토큰을 확인하지 못함',
    en: 'The backend did not confirm the push token',
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

  String get backgroundConnectionSection => _pick(
    zh: '实验性后台连接',
    ja: '試験的バックグラウンド接続',
    ko: '실험적 백그라운드 연결',
    en: 'Experimental background connection',
  );

  String get backgroundKeepAliveTitle => _pick(
    zh: '任务运行时保持本地通知',
    ja: 'タスク実行中のローカル通知を維持',
    ko: '작업 중 로컬 알림 연결 유지',
    en: 'Keep local alerts during active tasks',
  );

  String get backgroundKeepAliveExplanation => _pick(
    zh: '需要“始终”定位权限。后台只接收轻量通知事件，不解析流式正文、不刷新会话界面；重新打开 App 后才按序号增量追平。坐标不会被读取、保存或上传。低电量模式、严重温控、任务结束或断线超过两分钟时会自动停止。',
    ja: '「常に」位置情報が必要です。バックグラウンドでは軽量通知だけを受信し、ストリーム本文や会話 UI は更新しません。App を開いた後に差分を取得します。座標は読み取り・保存・送信されず、低電力、熱負荷、完了、長時間の切断時は自動停止します。',
    ko: '“항상” 위치 권한이 필요합니다. 백그라운드에서는 가벼운 알림만 받고 스트림 본문이나 대화 UI를 갱신하지 않으며, 앱을 열면 증분 동기화합니다. 좌표는 읽거나 저장하거나 업로드하지 않고 저전력, 열 압력, 작업 완료 또는 장시간 연결 끊김 시 자동 중지됩니다.',
    en: 'Requires Always Location. In the background, CC Pocket receives only lightweight alert events and does not parse streamed text or refresh chat UI; reopening the app performs an incremental catch-up. Coordinates are never read, stored, or uploaded. Low Power Mode, thermal pressure, completion, or a two-minute disconnect stops it automatically.',
  );

  String get grantAlwaysLocation => _pick(
    zh: '授权“始终”定位',
    ja: '位置情報を「常に許可」',
    ko: '위치 “항상 허용”',
    en: 'Grant Always Location',
  );

  String get openSystemSettings => _pick(
    zh: '打开系统设置',
    ja: 'システム設定を開く',
    ko: '시스템 설정 열기',
    en: 'Open System Settings',
  );

  String backgroundKeepAliveStatus(String phase) => switch (phase) {
    'initializing' => _pick(
      zh: '正在检测宿主能力',
      ja: 'ホスト機能を確認中',
      ko: '호스트 기능 확인 중',
      en: 'Checking host support',
    ),
    'disabled' => _pick(zh: '已关闭', ja: 'オフ', ko: '꺼짐', en: 'Off'),
    'base_app_update_required' => _pick(
      zh: '需要安装包含后台定位宿主的新基础 IPA',
      ja: '新しいベース IPA が必要です',
      ko: '새 기본 IPA 설치 필요',
      en: 'A newer base IPA with the native host is required',
    ),
    'bridge_update_required' || 'bridge_mode_unavailable' => _pick(
      zh: '需要更新 Bridge 后端',
      ja: 'Bridge の更新が必要です',
      ko: 'Bridge 업데이트 필요',
      en: 'A newer Bridge is required',
    ),
    'location_always_required' || 'updating_permission' => _pick(
      zh: '等待“始终”定位与通知权限',
      ja: '位置情報「常に許可」と通知の権限待ち',
      ko: '위치 항상 허용 및 알림 권한 필요',
      en: 'Waiting for Always Location and notification permission',
    ),
    'notification_permission_required' => _pick(
      zh: '系统通知未开启，请在设置中允许通知',
      ja: 'システム設定で通知を許可してください',
      ko: '시스템 설정에서 알림을 허용하세요',
      en: 'Allow notifications in System Settings',
    ),
    'notification_permission_unavailable' => _pick(
      zh: '无法确认系统通知权限，后台连接不会启动',
      ja: '通知権限を確認できないため開始しません',
      ko: '알림 권한을 확인할 수 없어 시작하지 않음',
      en: 'Notification permission could not be verified',
    ),
    'ready' => _pick(
      zh: '已就绪；仅在有运行中任务并进入后台时启动',
      ja: '準備完了。実行中タスクでのみ開始します',
      ko: '준비됨. 실행 중인 작업에서만 시작',
      en: 'Ready; starts only for an active task in the background',
    ),
    'prepared' => _pick(
      zh: '正在准备进入后台',
      ja: 'バックグラウンド移行を準備中',
      ko: '백그라운드 전환 준비 중',
      en: 'Preparing for background delivery',
    ),
    'receiving_notifications_only' => _pick(
      zh: '后台仅接收轻量通知',
      ja: 'バックグラウンドで軽量通知のみ受信中',
      ko: '백그라운드에서 가벼운 알림만 수신 중',
      en: 'Receiving lightweight notifications only',
    ),
    'waiting_for_active_task' => _pick(
      zh: '没有运行中任务，已停止以节省电量',
      ja: '実行中タスクがないため停止中',
      ko: '실행 중인 작업이 없어 절전 중',
      en: 'Stopped to save power until a task is active',
    ),
    'low_power_mode' => _pick(
      zh: '低电量模式下已暂停',
      ja: '低電力モードで一時停止中',
      ko: '저전력 모드에서 일시 중지',
      en: 'Paused in Low Power Mode',
    ),
    'thermal_pressure' => _pick(
      zh: '设备温度较高，已暂停',
      ja: '熱負荷のため一時停止中',
      ko: '열 압력으로 일시 중지',
      en: 'Paused due to thermal pressure',
    ),
    'bridge_disconnected' || 'bridge_disconnected_power_pause' => _pick(
      zh: 'Bridge 未连接，已停止后台常驻',
      ja: 'Bridge 未接続のため停止中',
      ko: 'Bridge 연결이 없어 중지됨',
      en: 'Stopped because the Bridge is disconnected',
    ),
    _ => _pick(
      zh: '等待下一次后台任务',
      ja: '次のバックグラウンドタスクを待機中',
      ko: '다음 백그라운드 작업 대기 중',
      en: 'Waiting for the next background task',
    ),
  };

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
