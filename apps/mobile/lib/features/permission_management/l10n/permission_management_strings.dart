import 'package:flutter/widgets.dart';

/// Feature-local copy keeps the removable permission host out of the
/// upstream ARB and generated-localization surface.
class PermissionManagementStrings {
  const PermissionManagementStrings({
    required this.title,
    required this.subtitle,
    required this.intro,
    required this.refreshTooltip,
    required this.requestAction,
    required this.openSettingsAction,
    required this.appUpdateRequired,
    required this.actionFailed,
    required this.statusNotDetermined,
    required this.statusAuthorized,
    required this.statusAuthorizedWhenInUse,
    required this.statusAuthorizedAlways,
    required this.statusDenied,
    required this.statusRestricted,
    required this.statusLimited,
    required this.statusProvisional,
    required this.statusEphemeral,
    required this.statusSystemManaged,
    required this.statusUnavailable,
    required this.statusUnknown,
    required this.notificationsTitle,
    required this.notificationsDescription,
    required this.cameraTitle,
    required this.cameraDescription,
    required this.photoLibraryTitle,
    required this.photoLibraryDescription,
    required this.microphoneTitle,
    required this.microphoneDescription,
    required this.speechRecognitionTitle,
    required this.speechRecognitionDescription,
    required this.locationAlwaysTitle,
    required this.locationAlwaysDescription,
    required this.localNetworkTitle,
    required this.localNetworkDescription,
    required this.filesTitle,
    required this.filesDescription,
    required this.biometricsTitle,
    required this.biometricsDescription,
  });

  final String title;
  final String subtitle;
  final String intro;
  final String refreshTooltip;
  final String requestAction;
  final String openSettingsAction;
  final String appUpdateRequired;
  final String actionFailed;
  final String statusNotDetermined;
  final String statusAuthorized;
  final String statusAuthorizedWhenInUse;
  final String statusAuthorizedAlways;
  final String statusDenied;
  final String statusRestricted;
  final String statusLimited;
  final String statusProvisional;
  final String statusEphemeral;
  final String statusSystemManaged;
  final String statusUnavailable;
  final String statusUnknown;
  final String notificationsTitle;
  final String notificationsDescription;
  final String cameraTitle;
  final String cameraDescription;
  final String photoLibraryTitle;
  final String photoLibraryDescription;
  final String microphoneTitle;
  final String microphoneDescription;
  final String speechRecognitionTitle;
  final String speechRecognitionDescription;
  final String locationAlwaysTitle;
  final String locationAlwaysDescription;
  final String localNetworkTitle;
  final String localNetworkDescription;
  final String filesTitle;
  final String filesDescription;
  final String biometricsTitle;
  final String biometricsDescription;

  static PermissionManagementStrings of(BuildContext context) =>
      forLocale(Localizations.localeOf(context));

  static PermissionManagementStrings forLocale(Locale locale) =>
      switch (locale.languageCode) {
        'zh' => _zh,
        'ja' => _ja,
        'ko' => _ko,
        _ => _en,
      };

  static const _en = PermissionManagementStrings(
    title: 'Permission Management',
    subtitle: 'Review phone access and grant it only when needed',
    intro:
        'CC Pocket requests system access only after you actively use a feature or tap Request. The Bridge may declare a required permission, but it cannot grant access silently.',
    refreshTooltip: 'Refresh permissions',
    requestAction: 'Request',
    openSettingsAction: 'Open System Settings',
    appUpdateRequired:
        'This permission host is unavailable. Install a newer CC Pocket build to manage these permissions.',
    actionFailed: 'The permission action could not be completed.',
    statusNotDetermined: 'Not requested',
    statusAuthorized: 'Allowed',
    statusAuthorizedWhenInUse: 'While using the app only',
    statusAuthorizedAlways: 'Always allowed',
    statusDenied: 'Denied',
    statusRestricted: 'Restricted',
    statusLimited: 'Limited access',
    statusProvisional: 'Quietly allowed',
    statusEphemeral: 'Temporary access',
    statusSystemManaged: 'Managed by iOS',
    statusUnavailable: 'Unavailable',
    statusUnknown: 'Unknown status',
    notificationsTitle: 'Notifications',
    notificationsDescription: 'Session, approval, and file-transfer alerts.',
    cameraTitle: 'Camera',
    cameraDescription: 'Scan a Bridge connection QR code.',
    photoLibraryTitle: 'Photo Library',
    photoLibraryDescription:
        'Attach photos and videos, or save received media to your library.',
    microphoneTitle: 'Microphone',
    microphoneDescription: 'Capture audio for voice input.',
    speechRecognitionTitle: 'Speech Recognition',
    speechRecognitionDescription: 'Convert voice input into message text.',
    locationAlwaysTitle: 'Background Location',
    locationAlwaysDescription:
        'Keeps only the lightweight notification connection alive during an active task. Coordinates are never read, stored, or uploaded.',
    localNetworkTitle: 'Local Network',
    localNetworkDescription:
        'Find and connect to Bridges on your network. iOS presents this permission when discovery is used.',
    filesTitle: 'Files',
    filesDescription:
        'Files are shared one at a time through the system picker; there is no permanent library permission.',
    biometricsTitle: 'Face ID & Biometrics',
    biometricsDescription:
        'Protect credentials and private content when a security feature uses biometrics.',
  );

  static const _zh = PermissionManagementStrings(
    title: '权限管理',
    subtitle: '查看手机权限，需要时再授权',
    intro: 'CC Pocket 只会在你主动使用某项功能或点击“请求”后申请系统权限。Bridge 可以声明所需权限，但不能静默获得授权。',
    refreshTooltip: '刷新权限状态',
    requestAction: '请求',
    openSettingsAction: '打开系统设置',
    appUpdateRequired: '当前构建不包含权限宿主。请安装较新的 CC Pocket 构建后再管理这些权限。',
    actionFailed: '权限操作未能完成。',
    statusNotDetermined: '尚未请求',
    statusAuthorized: '已允许',
    statusAuthorizedWhenInUse: '仅使用 App 时允许',
    statusAuthorizedAlways: '始终允许',
    statusDenied: '已拒绝',
    statusRestricted: '受系统限制',
    statusLimited: '有限访问',
    statusProvisional: '静默允许',
    statusEphemeral: '临时允许',
    statusSystemManaged: '由 iOS 管理',
    statusUnavailable: '不可用',
    statusUnknown: '未知状态',
    notificationsTitle: '通知',
    notificationsDescription: '用于会话、审批和文件互传提醒。',
    cameraTitle: '相机',
    cameraDescription: '扫描 Bridge 连接二维码。',
    photoLibraryTitle: '照片图库',
    photoLibraryDescription: '选择照片或视频发送，也可以把收到的媒体保存到系统图库。',
    microphoneTitle: '麦克风',
    microphoneDescription: '采集语音输入所需的音频。',
    speechRecognitionTitle: '语音识别',
    speechRecognitionDescription: '把语音输入转换为消息文字。',
    locationAlwaysTitle: '后台定位',
    locationAlwaysDescription: '仅在任务运行时维持轻量通知连接；不会读取、保存或上传坐标。',
    localNetworkTitle: '本地网络',
    localNetworkDescription: '发现并连接局域网内的 Bridge；iOS 会在实际发现设备时弹出授权。',
    filesTitle: '文件',
    filesDescription: '文件通过系统选择器逐次共享，不需要授予整个文件库的永久权限。',
    biometricsTitle: 'Face ID 与生物认证',
    biometricsDescription: '在安全功能实际使用生物认证时，用于保护凭据和私密内容。',
  );

  static const _ja = PermissionManagementStrings(
    title: '権限管理',
    subtitle: '端末のアクセス権を確認し、必要なときだけ許可します',
    intro:
        'CC Pocket は、機能を明示的に使用するか「リクエスト」をタップした後にのみシステム権限を要求します。Bridge は必要な権限を宣言できますが、暗黙に許可を得ることはできません。',
    refreshTooltip: '権限を更新',
    requestAction: 'リクエスト',
    openSettingsAction: 'システム設定を開く',
    appUpdateRequired: 'このビルドでは権限ホストを利用できません。新しい CC Pocket ビルドをインストールしてください。',
    actionFailed: '権限操作を完了できませんでした。',
    statusNotDetermined: '未リクエスト',
    statusAuthorized: '許可済み',
    statusAuthorizedWhenInUse: 'App の使用中のみ',
    statusAuthorizedAlways: '常に許可',
    statusDenied: '拒否',
    statusRestricted: '制限中',
    statusLimited: '限定アクセス',
    statusProvisional: '静かに許可',
    statusEphemeral: '一時アクセス',
    statusSystemManaged: 'iOS が管理',
    statusUnavailable: '利用不可',
    statusUnknown: '不明な状態',
    notificationsTitle: '通知',
    notificationsDescription: 'セッション、承認、ファイル転送の通知に使用します。',
    cameraTitle: 'カメラ',
    cameraDescription: 'Bridge 接続用 QR コードを読み取ります。',
    photoLibraryTitle: '写真ライブラリ',
    photoLibraryDescription: '写真や動画を添付し、受信したメディアをライブラリに保存します。',
    microphoneTitle: 'マイク',
    microphoneDescription: '音声入力用の音声を取り込みます。',
    speechRecognitionTitle: '音声認識',
    speechRecognitionDescription: '音声入力をメッセージのテキストに変換します。',
    locationAlwaysTitle: 'バックグラウンド位置情報',
    locationAlwaysDescription: '実行中タスクの軽量通知接続だけを維持します。座標の読み取り、保存、送信は行いません。',
    localNetworkTitle: 'ローカルネットワーク',
    localNetworkDescription:
        'ネットワーク上の Bridge を検出して接続します。iOS は検出機能の使用時に権限を表示します。',
    filesTitle: 'ファイル',
    filesDescription: 'ファイルはシステムピッカーから個別に共有され、ライブラリ全体への恒久的な権限は不要です。',
    biometricsTitle: 'Face ID と生体認証',
    biometricsDescription: 'セキュリティ機能で生体認証を使用するときに、資格情報と非公開コンテンツを保護します。',
  );

  static const _ko = PermissionManagementStrings(
    title: '권한 관리',
    subtitle: '휴대전화 접근 권한을 확인하고 필요할 때만 허용합니다',
    intro:
        'CC Pocket은 기능을 직접 사용하거나 ‘요청’을 탭한 뒤에만 시스템 권한을 요청합니다. Bridge는 필요한 권한을 선언할 수 있지만 자동으로 권한을 얻을 수는 없습니다.',
    refreshTooltip: '권한 새로 고침',
    requestAction: '요청',
    openSettingsAction: '시스템 설정 열기',
    appUpdateRequired:
        '이 빌드에서는 권한 호스트를 사용할 수 없습니다. 더 새로운 CC Pocket 빌드를 설치해 주세요.',
    actionFailed: '권한 작업을 완료하지 못했습니다.',
    statusNotDetermined: '요청하지 않음',
    statusAuthorized: '허용됨',
    statusAuthorizedWhenInUse: '앱을 사용하는 동안만',
    statusAuthorizedAlways: '항상 허용',
    statusDenied: '거부됨',
    statusRestricted: '제한됨',
    statusLimited: '제한된 접근',
    statusProvisional: '조용히 허용됨',
    statusEphemeral: '임시 접근',
    statusSystemManaged: 'iOS에서 관리',
    statusUnavailable: '사용할 수 없음',
    statusUnknown: '알 수 없는 상태',
    notificationsTitle: '알림',
    notificationsDescription: '세션, 승인 및 파일 전송 알림에 사용합니다.',
    cameraTitle: '카메라',
    cameraDescription: 'Bridge 연결 QR 코드를 스캔합니다.',
    photoLibraryTitle: '사진 보관함',
    photoLibraryDescription: '사진과 동영상을 첨부하거나 받은 미디어를 보관함에 저장합니다.',
    microphoneTitle: '마이크',
    microphoneDescription: '음성 입력을 위한 오디오를 캡처합니다.',
    speechRecognitionTitle: '음성 인식',
    speechRecognitionDescription: '음성 입력을 메시지 텍스트로 변환합니다.',
    locationAlwaysTitle: '백그라운드 위치',
    locationAlwaysDescription:
        '실행 중인 작업의 가벼운 알림 연결만 유지하며 좌표를 읽거나 저장하거나 업로드하지 않습니다.',
    localNetworkTitle: '로컬 네트워크',
    localNetworkDescription:
        '네트워크의 Bridge를 찾아 연결합니다. iOS는 검색 기능을 사용할 때 권한을 표시합니다.',
    filesTitle: '파일',
    filesDescription:
        '파일은 시스템 선택기를 통해 하나씩 공유되며 전체 파일 보관함에 대한 영구 권한은 필요하지 않습니다.',
    biometricsTitle: 'Face ID 및 생체 인증',
    biometricsDescription: '보안 기능이 생체 인증을 사용할 때 자격 증명과 비공개 콘텐츠를 보호합니다.',
  );
}
