import 'package:flutter/widgets.dart';

import '../mobile_update_models.dart';

/// Feature-local copy keeps the removable OTA host out of generated ARB files.
class MobileUpdateStrings {
  const MobileUpdateStrings({
    required this.title,
    required this.settingsSubtitle,
    required this.checkNow,
    required this.checking,
    required this.downloadUpdate,
    required this.downloading,
    required this.upToDate,
    required this.updateAvailable,
    required this.restartRequired,
    required this.restartMessage,
    required this.unavailable,
    required this.retry,
    required this.currentVersion,
    required this.currentPatch,
    required this.targetPatch,
    required this.latestPatch,
    required this.lastChecked,
    required this.neverChecked,
    required this.channel,
    required this.stableChannel,
    required this.ownerChannel,
    required this.ownerWarning,
    required this.modeTitle,
    required this.automaticMode,
    required this.automaticModeDescription,
    required this.silentMode,
    required this.silentModeDescription,
    required this.manualMode,
    required this.manualModeDescription,
    required this.networkFailure,
    required this.signatureFailure,
    required this.versionMismatchFailure,
    required this.downloadFailure,
    required this.installFailure,
    required this.unknownFailure,
    required this.developerUnlocked,
    required this.dismiss,
  });

  final String title;
  final String settingsSubtitle;
  final String checkNow;
  final String checking;
  final String downloadUpdate;
  final String downloading;
  final String upToDate;
  final String updateAvailable;
  final String restartRequired;
  final String restartMessage;
  final String unavailable;
  final String retry;
  final String currentVersion;
  final String currentPatch;
  final String targetPatch;
  final String latestPatch;
  final String lastChecked;
  final String neverChecked;
  final String channel;
  final String stableChannel;
  final String ownerChannel;
  final String ownerWarning;
  final String modeTitle;
  final String automaticMode;
  final String automaticModeDescription;
  final String silentMode;
  final String silentModeDescription;
  final String manualMode;
  final String manualModeDescription;
  final String networkFailure;
  final String signatureFailure;
  final String versionMismatchFailure;
  final String downloadFailure;
  final String installFailure;
  final String unknownFailure;
  final String developerUnlocked;
  final String dismiss;

  String failure(MobileUpdateFailureKind? kind) => switch (kind) {
    MobileUpdateFailureKind.network => networkFailure,
    MobileUpdateFailureKind.signature => signatureFailure,
    MobileUpdateFailureKind.versionMismatch => versionMismatchFailure,
    MobileUpdateFailureKind.download => downloadFailure,
    MobileUpdateFailureKind.install => installFailure,
    MobileUpdateFailureKind.unknown || null => unknownFailure,
  };

  String channelLabel(MobileUpdateChannel channel) =>
      channel == MobileUpdateChannel.owner ? ownerChannel : stableChannel;

  static MobileUpdateStrings of(BuildContext context) {
    return switch (Localizations.localeOf(context).languageCode) {
      'zh' => _zh,
      'ja' => _ja,
      'ko' => _ko,
      _ => _en,
    };
  }

  static const _zh = MobileUpdateStrings(
    title: '软件更新',
    settingsSubtitle: '检查并下载 CC Pocket 补丁',
    checkNow: '检查更新',
    checking: '正在检查更新…',
    downloadUpdate: '下载更新',
    downloading: '正在下载并校验更新…',
    upToDate: '已是最新版本',
    updateAvailable: '发现可用更新',
    restartRequired: '更新已下载',
    restartMessage: '完全关闭并重新打开 CC Pocket 后生效。',
    unavailable: '当前基础 IPA 不支持软件内更新，请安装新的基础 IPA。',
    retry: '重试',
    currentVersion: '基础版本',
    currentPatch: '当前补丁',
    targetPatch: '目标补丁',
    latestPatch: '当前通道最新补丁（下载完成后显示编号）',
    lastChecked: '上次检查',
    neverChecked: '尚未检查',
    channel: '更新通道',
    stableChannel: 'stable（稳定）',
    ownerChannel: 'owner（测试）',
    ownerWarning: '切换通道只影响以后检查的更新，不会立即降级已经安装的补丁。',
    modeTitle: '更新方式',
    automaticMode: '自动更新',
    automaticModeDescription: '每六小时最多检查一次，后台下载并提示重新打开。',
    silentMode: '静默更新',
    silentModeDescription: '后台检查和下载，但不主动弹出完成提示。',
    manualMode: '手动下载',
    manualModeDescription: '仅在你点击“检查更新”时联网，检查后由你确认下载。',
    networkFailure: '网络连接失败，请检查网络后重试。',
    signatureFailure: '更新签名校验失败，已拒绝安装。',
    versionMismatchFailure: '补丁与当前基础 IPA 版本不匹配。',
    downloadFailure: '更新下载失败，请重试。',
    installFailure: '更新安装失败，请重试或安装新的基础 IPA。',
    unknownFailure: '检查更新失败，请重试。',
    developerUnlocked: '开发者更新通道已解锁',
    dismiss: '知道了',
  );

  static const _en = MobileUpdateStrings(
    title: 'Software Update',
    settingsSubtitle: 'Check for and download CC Pocket patches',
    checkNow: 'Check for Updates',
    checking: 'Checking for updates…',
    downloadUpdate: 'Download Update',
    downloading: 'Downloading and verifying update…',
    upToDate: 'CC Pocket is up to date',
    updateAvailable: 'An update is available',
    restartRequired: 'Update downloaded',
    restartMessage: 'Fully close and reopen CC Pocket to apply it.',
    unavailable:
        'This base IPA does not support in-app updates. Install a new base IPA.',
    retry: 'Retry',
    currentVersion: 'Base version',
    currentPatch: 'Current patch',
    targetPatch: 'Target patch',
    latestPatch: 'Latest patch on this channel (number shown after download)',
    lastChecked: 'Last checked',
    neverChecked: 'Never checked',
    channel: 'Update channel',
    stableChannel: 'stable',
    ownerChannel: 'owner',
    ownerWarning:
        'Changing channels affects future checks only and does not immediately downgrade an installed patch.',
    modeTitle: 'Update mode',
    automaticMode: 'Automatic',
    automaticModeDescription:
        'Checks at most every six hours, downloads in the background, and prompts when ready.',
    silentMode: 'Silent',
    silentModeDescription:
        'Checks and downloads in the background without a completion prompt.',
    manualMode: 'Manual download',
    manualModeDescription:
        'Only checks when you tap the button and waits for download confirmation.',
    networkFailure:
        'Could not reach the update service. Check your network and retry.',
    signatureFailure:
        'Update signature verification failed. The update was rejected.',
    versionMismatchFailure: 'The patch does not match this base IPA version.',
    downloadFailure: 'The update could not be downloaded. Please retry.',
    installFailure:
        'The update could not be installed. Retry or install a new base IPA.',
    unknownFailure: 'The update check failed. Please retry.',
    developerUnlocked: 'Developer update channel unlocked',
    dismiss: 'Got it',
  );

  static const _ja = MobileUpdateStrings(
    title: 'ソフトウェア更新',
    settingsSubtitle: 'CC Pocket のパッチを確認・ダウンロード',
    checkNow: '更新を確認',
    checking: '更新を確認中…',
    downloadUpdate: '更新をダウンロード',
    downloading: '更新をダウンロードして検証中…',
    upToDate: '最新バージョンです',
    updateAvailable: '更新があります',
    restartRequired: '更新をダウンロードしました',
    restartMessage: 'CC Pocket を完全に終了して再度開くと反映されます。',
    unavailable: 'この基本 IPA はアプリ内更新に対応していません。新しい基本 IPA をインストールしてください。',
    retry: '再試行',
    currentVersion: '基本バージョン',
    currentPatch: '現在のパッチ',
    targetPatch: '対象パッチ',
    latestPatch: 'このチャンネルの最新パッチ（番号はダウンロード後に表示）',
    lastChecked: '最終確認',
    neverChecked: '未確認',
    channel: '更新チャンネル',
    stableChannel: 'stable（安定）',
    ownerChannel: 'owner（テスト）',
    ownerWarning: 'チャンネル変更は今後の確認にのみ影響し、インストール済みパッチを直ちにダウングレードしません。',
    modeTitle: '更新方法',
    automaticMode: '自動更新',
    automaticModeDescription: '最大6時間ごとに確認し、バックグラウンドでダウンロードして完了を通知します。',
    silentMode: 'サイレント更新',
    silentModeDescription: 'バックグラウンドで確認・ダウンロードし、完了通知は表示しません。',
    manualMode: '手動ダウンロード',
    manualModeDescription: 'ボタンを押した時だけ確認し、ダウンロード前に確認します。',
    networkFailure: 'ネットワーク接続に失敗しました。確認して再試行してください。',
    signatureFailure: '更新の署名検証に失敗したため、インストールを拒否しました。',
    versionMismatchFailure: 'パッチが現在の基本 IPA と一致しません。',
    downloadFailure: '更新のダウンロードに失敗しました。',
    installFailure: '更新のインストールに失敗しました。',
    unknownFailure: '更新の確認に失敗しました。',
    developerUnlocked: '開発者向け更新チャンネルを有効にしました',
    dismiss: '了解',
  );

  static const _ko = MobileUpdateStrings(
    title: '소프트웨어 업데이트',
    settingsSubtitle: 'CC Pocket 패치 확인 및 다운로드',
    checkNow: '업데이트 확인',
    checking: '업데이트 확인 중…',
    downloadUpdate: '업데이트 다운로드',
    downloading: '업데이트 다운로드 및 검증 중…',
    upToDate: '최신 버전입니다',
    updateAvailable: '업데이트가 있습니다',
    restartRequired: '업데이트 다운로드 완료',
    restartMessage: 'CC Pocket을 완전히 종료한 뒤 다시 열면 적용됩니다.',
    unavailable: '현재 기본 IPA는 앱 내 업데이트를 지원하지 않습니다. 새 기본 IPA를 설치하세요.',
    retry: '다시 시도',
    currentVersion: '기본 버전',
    currentPatch: '현재 패치',
    targetPatch: '대상 패치',
    latestPatch: '현재 채널의 최신 패치(다운로드 후 번호 표시)',
    lastChecked: '마지막 확인',
    neverChecked: '확인하지 않음',
    channel: '업데이트 채널',
    stableChannel: 'stable(안정)',
    ownerChannel: 'owner(테스트)',
    ownerWarning: '채널 변경은 이후 확인에만 적용되며 설치된 패치를 즉시 다운그레이드하지 않습니다.',
    modeTitle: '업데이트 방식',
    automaticMode: '자동 업데이트',
    automaticModeDescription: '최대 6시간마다 확인하고 백그라운드에서 다운로드한 뒤 알립니다.',
    silentMode: '조용히 업데이트',
    silentModeDescription: '백그라운드에서 확인하고 다운로드하지만 완료 알림은 표시하지 않습니다.',
    manualMode: '수동 다운로드',
    manualModeDescription: '버튼을 누를 때만 확인하고 다운로드 전에 승인을 받습니다.',
    networkFailure: '네트워크 연결에 실패했습니다. 확인 후 다시 시도하세요.',
    signatureFailure: '업데이트 서명 검증에 실패하여 설치를 거부했습니다.',
    versionMismatchFailure: '패치가 현재 기본 IPA와 일치하지 않습니다.',
    downloadFailure: '업데이트 다운로드에 실패했습니다.',
    installFailure: '업데이트 설치에 실패했습니다.',
    unknownFailure: '업데이트 확인에 실패했습니다.',
    developerUnlocked: '개발자 업데이트 채널 잠금 해제됨',
    dismiss: '확인',
  );
}
