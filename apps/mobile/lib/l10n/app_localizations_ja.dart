// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'CC Pocket';

  @override
  String get cancel => 'キャンセル';

  @override
  String get save => '保存';

  @override
  String get delete => '削除';

  @override
  String get remove => '削除';

  @override
  String get open => '開く';

  @override
  String get submit => '送信';

  @override
  String confirmWithCount(int count) {
    return '確認（$count件）';
  }

  @override
  String get reviewYourAnswers => '回答を確認';

  @override
  String get groupedSessions => 'プロジェクト別';

  @override
  String get sessionListView => '最近のチャット';

  @override
  String get tooltipToggleRecentGrouping => 'セッション一覧の表示を切り替え';

  @override
  String get loadMore => 'さらに読み込む';

  @override
  String get worktreesTitle => 'Worktree';

  @override
  String get removeWorktreeTitle => 'Worktreeを削除';

  @override
  String removeWorktreeConfirm(String branch, String path) {
    return 'ブランチ「$branch」のWorktreeを削除しますか？\nパス: $path';
  }

  @override
  String get noWorktreesFound => 'Worktreeが見つかりません';

  @override
  String get mainRepository => 'メインリポジトリ';

  @override
  String sessionShortTitle(String id) {
    return 'セッション $id';
  }

  @override
  String get debugBundlePromptCopied => 'Agent用プロンプトをコピーしました。AIチャットに貼り付けてください。';

  @override
  String get debugBundleBuildFailed => 'デバッグバンドルを作成できませんでした';

  @override
  String get copyCodexCliJoinCommand => 'Codex CLI参加コマンドをコピー';

  @override
  String get codexCliJoinCommandCopied => 'Codex CLI参加コマンドをコピーしました';

  @override
  String get sessionStarted => 'セッションを開始しました';

  @override
  String get reviewSummary => '回答の確認';

  @override
  String stepOfTotal(int current, int total) {
    return '$total件中$current件目';
  }

  @override
  String get sessionCost => 'セッション費用';

  @override
  String sessionContextUsage(int count, int percent) {
    return '$count件のメッセージ（コンテキスト約$percent%）';
  }

  @override
  String get screenshotDeleted => 'スクリーンショットを削除しました';

  @override
  String monthsAgo(int months) {
    return '$monthsか月前';
  }

  @override
  String get addToConversation => '会話に追加';

  @override
  String get removeProjectTitle => 'プロジェクトを削除';

  @override
  String removeProjectConfirm(Object name) {
    return '「$name」を最近のプロジェクトから削除しますか？';
  }

  @override
  String get rename => '名前を変更';

  @override
  String get renameSession => 'セッション名を変更';

  @override
  String get renameFailed => 'この会話の名前を変更できません';

  @override
  String renameFailedWithError(String error) {
    return 'この会話の名前を変更できません：$error';
  }

  @override
  String get pin => 'セッションをピン留め';

  @override
  String get unpin => 'セッションのピン留めを解除';

  @override
  String get pinProject => 'プロジェクトをピン留め';

  @override
  String get unpinProject => 'プロジェクトのピン留めを解除';

  @override
  String get sessionNameHint => 'セッション名';

  @override
  String get clearName => '名前をクリア';

  @override
  String get connect => '接続';

  @override
  String toolSuggestionTitle(Object toolName) {
    return 'Codex に $toolName を追加しますか？';
  }

  @override
  String toolSuggestionInstall(Object toolName) {
    return '$toolName をインストール';
  }

  @override
  String get toolSuggestionInstalling => 'インストール中…';

  @override
  String get toolSuggestionNotNow => '今回はしない';

  @override
  String get toolSuggestionAuthDescription => '必要なアプリを接続し、完了したら確認してください。';

  @override
  String toolSuggestionConnect(Object appName) {
    return '$appName を接続';
  }

  @override
  String get toolSuggestionComplete => '接続が完了しました';

  @override
  String get toolSuggestionFailed => 'インストールに失敗しました';

  @override
  String get toolSuggestionOpenFailed => '接続ページを開けませんでした。';

  @override
  String get copy => 'コピー';

  @override
  String get markdownLinkOpenFailed => 'リンクを開けませんでした。';

  @override
  String get markdownLinkUnsupported => 'この種類のリンクには対応していません。';

  @override
  String get markdownFileUnavailable => 'このファイルはここではプレビューできません。';

  @override
  String get filePreviewShowSource => 'ソースを表示';

  @override
  String get filePreviewShowPreview => 'プレビューを表示';

  @override
  String get filePreviewRenderedHtml => 'HTMLレンダリングプレビュー';

  @override
  String get copied => 'コピーしました';

  @override
  String copiedValue(String value) {
    return '「$value」をコピーしました';
  }

  @override
  String get copiedUrl => 'URLをコピーしました';

  @override
  String get copiedToClipboard => 'クリップボードにコピーしました';

  @override
  String get lineCopied => '行をコピーしました';

  @override
  String get start => '開始';

  @override
  String get stop => '停止';

  @override
  String get send => '送信';

  @override
  String get settings => '設定';

  @override
  String get gallery => 'ギャラリー';

  @override
  String get git => 'Git';

  @override
  String get explorer => 'エクスプローラー';

  @override
  String get gitUnavailableTip => 'Git未検出 — Git機能は利用できません';

  @override
  String get gitUnavailableTitle => 'Gitを利用できません';

  @override
  String get gitUnavailableHint => 'このプロジェクトではGit機能を利用できません';

  @override
  String get errorAuthenticationTitle => '認証エラー';

  @override
  String get errorCodexAuthenticationTitle => 'Codex 認証エラー';

  @override
  String get errorCodexCliNotInstalledTitle => 'Codex CLI がインストールされていません';

  @override
  String get errorPathNotAllowedTitle => 'パスは許可されていません';

  @override
  String get errorBridgeUpdateRequiredTitle => 'Bridge の更新が必要です';

  @override
  String get errorAutoModeUnavailableTitle => 'Auto モードは利用できません';

  @override
  String get errorCodexWarningTitle => 'Codex の警告';

  @override
  String get errorClaudeAuthLoginHint =>
      'Bridge マシンで「claude auth login」を実行してください';

  @override
  String get errorAnthropicApiKeyHint =>
      'Bridge マシンで ANTHROPIC_API_KEY を設定してください';

  @override
  String get errorOpenAiApiKeyHint => 'Bridge マシンの OPENAI_API_KEY を確認してください';

  @override
  String get errorCodexCliInstallHint =>
      'Bridge マシンに Codex CLI をインストールしてから Bridge を再起動してください';

  @override
  String get errorPathAllowedDirsHint =>
      'Bridge サーバーの BRIDGE_ALLOWED_DIRS を更新してください';

  @override
  String get errorAutoModeUnavailableHint =>
      'ここでは Default モードを使用するか、Auto モード対応の Claude 環境に切り替えてください';

  @override
  String get autoModeFallbackDefaultTip =>
      'Auto mode はこの環境で使えないため Default に切り替えました';

  @override
  String galleryWithCount(int count) {
    return 'ギャラリー ($count)';
  }

  @override
  String get disconnect => '切断';

  @override
  String get back => '戻る';

  @override
  String get next => '次へ';

  @override
  String get done => '完了';

  @override
  String get skip => 'スキップ';

  @override
  String get edit => '編集';

  @override
  String get share => '共有';

  @override
  String get all => 'すべて';

  @override
  String get none => 'なし';

  @override
  String get dismissKeyboard => 'キーボードを閉じる';

  @override
  String get serverUnreachable => 'サーバーに接続できません';

  @override
  String get serverUnreachableBody => 'Bridge サーバーに到達できません:';

  @override
  String get setupSteps => 'セットアップ手順:';

  @override
  String get setupStep1Title => 'Bridge Server を起動';

  @override
  String get setupStep1Command => 'npx --yes @ccpocket/bridge@latest';

  @override
  String get setupStep2Title => '常時起動したい場合はサービス登録';

  @override
  String get setupStep2Command => 'npx --yes @ccpocket/bridge@latest setup';

  @override
  String get setupNetworkHint =>
      '両方のデバイスが同じネットワーク上にあることを確認してください（または Tailscale を使用）。';

  @override
  String get connectAnyway => '接続を続行';

  @override
  String get stopSession => 'セッションを停止';

  @override
  String get stopSessionConfirm => 'このセッションを停止しますか？ Claude プロセスが終了します。';

  @override
  String get startNewWithSameSettings => '同じ設定で新規開始';

  @override
  String get copyResumeCommand => '再開コマンドをコピー';

  @override
  String get copyResumeCommandSubtitle => 'mac / Linuxに引き継ぎ';

  @override
  String get resumeCommandCopied => '再開コマンドをコピーしました';

  @override
  String get editSettingsThenStart => '設定を変更して開始';

  @override
  String get serverRequiresApiKey => 'このサーバーには API キーが必要です';

  @override
  String get bridgeServerUpdated => 'Bridge Server を更新しました';

  @override
  String get bridgeUpdateStarted => 'Bridge を更新しています。接続を閉じてマシン一覧に戻ります。';

  @override
  String get bridgeUpdateReconnectHint =>
      'Bridge Server を更新しました。マシン一覧から再接続してください。';

  @override
  String get failedToUpdateServer => 'サーバーの更新に失敗しました';

  @override
  String get bridgeServerStarted => 'Bridge Server を起動しました';

  @override
  String get failedToStartServer => 'サーバーの起動に失敗しました';

  @override
  String get bridgeServerStopped => 'Bridge Server を停止しました';

  @override
  String get failedToStopServer => 'サーバーの停止に失敗しました';

  @override
  String get sshPassword => 'SSH パスワード';

  @override
  String sshPasswordPrompt(String machineName) {
    return '$machineName の SSH パスワードを入力';
  }

  @override
  String get password => 'パスワード';

  @override
  String get machineEditAddTitle => 'マシンを追加';

  @override
  String get machineEditEditTitle => 'マシンを編集';

  @override
  String get machineEditDismissKeyboardTooltip => 'キーボードを閉じる';

  @override
  String get machineEditBasicInfo => '基本情報';

  @override
  String get machineEditName => '名前';

  @override
  String get machineEditNameHint => 'Home Mac';

  @override
  String get machineEditHostLabel => 'Host（IP またはホスト名）';

  @override
  String get machineEditHostHint => '100.64.1.2';

  @override
  String get machineEditPort => 'ポート';

  @override
  String get machineEditBridgePortHint => '8765';

  @override
  String get machineEditApiKey => 'API Key';

  @override
  String get machineEditOptional => '任意';

  @override
  String get machineEditUseSecureConnection => 'セキュア接続を使う';

  @override
  String get machineEditUseSecureConnectionSubtitle =>
      'WSS で接続し、ヘルスチェックに HTTPS を使います';

  @override
  String get machineEditSshConfiguration => 'SSH 設定';

  @override
  String get machineEditEnableSshRemoteStartup => 'SSH リモート起動を有効にする';

  @override
  String get machineEditEnableSshRemoteStartupSubtitle =>
      'オフライン時に Bridge Server をリモート起動します';

  @override
  String get machineEditSshUsername => 'SSH ユーザー名';

  @override
  String get machineEditSshUsernameHint => 'myuser';

  @override
  String get machineEditSshPort => 'SSH ポート';

  @override
  String get machineEditSshPortHint => '22';

  @override
  String get machineEditTargetAuthentication => '接続先の認証';

  @override
  String get machineEditPrivateKey => '秘密鍵';

  @override
  String get machineEditSshPrivateKeyPem => 'SSH 秘密鍵（PEM）';

  @override
  String get machineEditOpenSshPrivateKeyHint =>
      '-----BEGIN OPENSSH PRIVATE KEY-----';

  @override
  String get machineEditSavedPrivateKeyIndicator =>
      'Private Key は保存済みです。新しく入力すると置き換えます。';

  @override
  String get machineEditUseSshJumpHost => 'SSH Jump Host を使う';

  @override
  String get machineEditUseSshJumpHostSubtitle => '踏み台または中継 SSH ホスト経由で接続します';

  @override
  String get machineEditSshJumpHost => 'SSH 踏み台ホスト';

  @override
  String get machineEditJumpHost => '踏み台ホスト';

  @override
  String get machineEditJumpHostHint => 'bastion.example.com';

  @override
  String get machineEditJumpPort => '踏み台ポート';

  @override
  String get machineEditJumpUsername => '踏み台ユーザー名';

  @override
  String get machineEditJumpUsernameHint => '未入力なら SSH Username を使います';

  @override
  String get machineEditJumpHostAuthentication => 'Jump Host の認証';

  @override
  String get machineEditJumpHostAuthenticationSubtitle =>
      '未入力なら接続先の SSH 認証情報を再利用します';

  @override
  String get machineEditJumpPassword => '踏み台パスワード';

  @override
  String get machineEditSavedJumpHostPasswordIndicator =>
      'Jump Host パスワードは保存済みです。新しく入力すると置き換えます。';

  @override
  String get machineEditJumpPrivateKeyPem => '踏み台秘密鍵（PEM）';

  @override
  String get machineEditSavedJumpHostPrivateKeyIndicator =>
      'Jump Host Private Key は保存済みです。新しく入力すると置き換えます。';

  @override
  String get machineEditTesting => 'テスト中...';

  @override
  String get machineEditTestConnection => '接続をテスト';

  @override
  String get machineEditConnectionSuccessful => '接続に成功しました';

  @override
  String get machineEditFillSshCredentials => 'SSH 認証情報を入力してください';

  @override
  String get machineEditAddAndConnect => '追加して接続';

  @override
  String get deleteMachine => 'マシンを削除';

  @override
  String deleteMachineConfirm(String displayName) {
    return '\"$displayName\" を削除しますか？保存された認証情報もすべて削除されます。';
  }

  @override
  String get connectToBridgeServer => 'Bridge Server に接続';

  @override
  String get connectingToBridge => 'Bridge に安全に接続しています…';

  @override
  String get loadingSessionStatus => '接続しました。セッション状態を読み込んでいます…';

  @override
  String get loadingConversationCatalog => 'セッション状態の準備が完了しました。会話一覧を読み込んでいます…';

  @override
  String get bridgeConnectionTakingLonger =>
      'Bridge には接続しましたが、会話一覧の準備に時間がかかっています。このまま待つか、再試行またはキャンセルできます。';

  @override
  String get authenticatingWithBridge => 'Bridge で認証しています...';

  @override
  String get preparingCodexRuntime =>
      'Bridge はオンラインです。共有 Codex ランタイムを準備しています...';

  @override
  String get codexRuntimeTakingLonger =>
      'Bridge プロセスはオンラインですが、共有 Codex ランタイムはまだ準備中です。待機、再試行、またはキャンセルできます。';

  @override
  String get useCachedConversations => 'キャッシュを使用して開く';

  @override
  String get bridgeConnectionAttemptFailed =>
      'Bridge 接続を利用可能な状態にできませんでした。アドレスと認証情報を確認して再試行してください。';

  @override
  String get externalBridgeConnectionTitle => 'この Bridge に接続しますか？';

  @override
  String externalBridgeConnectionBody(String target) {
    return '別のアプリまたはリンクから $target への接続が要求されました。信頼できる Bridge の場合のみ続行してください。';
  }

  @override
  String get orConnectManually => 'または手動で接続';

  @override
  String get serverUrl => 'サーバー URL';

  @override
  String get serverUrlHint => 'ws://<host-ip>:8765';

  @override
  String get apiKeyOptional => 'API キー（任意）';

  @override
  String get apiKeyHint => '認証なしの場合は空欄';

  @override
  String get scanQrCode => 'QR コードをスキャン';

  @override
  String get qrScanInvalid => '有効な CC Pocket 接続用 QR コードではありません';

  @override
  String get qrScanUnavailable =>
      'このプラットフォームではカメラで QR コードを読み取れません。Bridge の URL を手動で入力してください。';

  @override
  String get qrScanHint => 'Bridge サーバーに表示された QR コードへ\nカメラを向けてください';

  @override
  String get setupGuide => 'セットアップガイド';

  @override
  String get showSessions => '左ペインを表示';

  @override
  String get hideSessions => '左ペインを隠す';

  @override
  String get workspaceLandingSelectSessionMessage => '左ペインでセッションを選択してください。';

  @override
  String get workspaceLandingCreateSessionMessage =>
      '左ペインの New からセッションを作成してください。';

  @override
  String get workspaceLandingDisconnectedMessage =>
      'Bridge に接続されていません。左ペインから接続するか、セットアップガイドを開いてマシンを設定してください。';

  @override
  String get running => '実行中';

  @override
  String get recentSessions => '最近のセッション';

  @override
  String get search => '検索';

  @override
  String get searchSessions => 'セッションを検索...';

  @override
  String get sessionDisplayModeFirst => '先頭';

  @override
  String get sessionDisplayModeLast => '末尾';

  @override
  String get sessionDisplayModeSummary => '要約';

  @override
  String get allAiTools => 'すべての AI ツール';

  @override
  String get allProjects => 'すべてのプロジェクト';

  @override
  String get named => '名前付き';

  @override
  String get machines => 'マシン';

  @override
  String get refreshStatus => '状態を更新';

  @override
  String get add => '追加';

  @override
  String get noSavedMachinesDescription =>
      '保存済みのマシンはありません。\n追加すると、すばやく接続したり Bridge Server をリモート起動したりできます。';

  @override
  String get readyToStart => '準備完了';

  @override
  String get readyToStartDescription =>
      '+ ボタンを押してセッションを作成し、Claude でコーディングを始めましょう。';

  @override
  String get newSession => '新規セッション';

  @override
  String get neverConnected => '未接続';

  @override
  String get justNow => 'たった今';

  @override
  String minutesAgo(int minutes) {
    return '$minutes分前';
  }

  @override
  String hoursAgo(int hours) {
    return '$hours時間前';
  }

  @override
  String daysAgo(int days) {
    return '$days日前';
  }

  @override
  String get unfavorite => 'お気に入り解除';

  @override
  String get favorite => 'お気に入り';

  @override
  String get updateBridge => 'Bridge を更新';

  @override
  String get bridgeIsUpToDate => 'Bridge は最新です';

  @override
  String get bridgeUpdateAvailable => '更新があります';

  @override
  String get bridgeUpdateRequiresSetup => 'SSH と Bridge の自動起動セットアップが必要です';

  @override
  String get bridgeVersionUnknown => 'Bridge のバージョンを確認できません';

  @override
  String bridgeVersionCurrentExpected(String current, String expected) {
    return '現在 v$current、推奨 v$expected以上';
  }

  @override
  String bridgeVersionCurrentLatest(String current, String latest) {
    return '現在 v$current、最新版 v$latest';
  }

  @override
  String get bridgeLatestVersionChecking => 'Bridge の最新版を確認中...';

  @override
  String get bridgeLatestVersionUnavailable => 'Bridge の最新版を確認できません';

  @override
  String get bridgeLatestVersionRetry => '最新版の確認を再試行';

  @override
  String get bridgeUpdateSetupTitle => 'Bridge 更新の準備';

  @override
  String get bridgeUpdateSetupDescription =>
      'このマシンで Bridge の更新機能を使うには、SSH 接続と Bridge の自動起動セットアップが必要です。';

  @override
  String get bridgeUpdateSetupEnableSsh => 'Bridge 接続設定で SSH を有効にします。';

  @override
  String get bridgeUpdateSetupRunCommand => '接続先マシンでセットアップコマンドを実行しておきます。';

  @override
  String get bridgeUpdateSetupCommand => 'npx @ccpocket/bridge@latest setup';

  @override
  String get stopServer => 'サーバーを停止';

  @override
  String get update => '更新';

  @override
  String get download => 'ダウンロード';

  @override
  String appUpdateAvailable(String version) {
    return 'v$version が利用可能です';
  }

  @override
  String get macosNativeAppBannerTitle => 'macOS ネイティブ版をおすすめします';

  @override
  String get macosNativeAppBannerSubtitle =>
      'Mac では、macOS に最適化された CC Pocket ネイティブ版を GitHub Releases からインストールできます。';

  @override
  String get openGitHubReleases => 'GitHub Releases を開く';

  @override
  String get macosNativeAppSettingsTitle => 'macOS ネイティブ版';

  @override
  String get macosNativeAppSettingsSubtitle =>
      'macOS に最適化されているため、Mac ではネイティブ版がおすすめです。';

  @override
  String get supportBannerTitle => 'CC Pocketが役に立っていたら';

  @override
  String get supportBannerSubtitle => 'サポートで継続開発を後押しできます';

  @override
  String get supportBannerAction => 'サポートを見る';

  @override
  String get offline => 'オフライン';

  @override
  String get unreachable => '接続不可';

  @override
  String get checking => '確認中...';

  @override
  String get recentProjects => '最近のプロジェクト';

  @override
  String get orEnterPath => 'またはパスを入力';

  @override
  String get projectPath => 'プロジェクトパス';

  @override
  String get projectPathHint => '/path/to/your/project';

  @override
  String get permission => 'パーミッション';

  @override
  String get approval => '承認';

  @override
  String get restart => '再起動';

  @override
  String get worktree => 'Worktree';

  @override
  String get advanced => '詳細設定';

  @override
  String get modelOptional => 'モデル（任意）';

  @override
  String get effort => '推論強度';

  @override
  String get defaultLabel => 'デフォルト';

  @override
  String get codexProfilePrecedenceNote =>
      'Profile で同じ設定を指定している場合は、以下の項目より Profile の設定が優先されます。';

  @override
  String get maxTurns => 'Max Turns';

  @override
  String get maxTurnsHint => '例: 8';

  @override
  String get maxTurnsError => '1以上の整数を入力してください';

  @override
  String get maxBudgetUsd => '最大予算 (USD)';

  @override
  String get maxBudgetHint => '例: 1.00';

  @override
  String get maxBudgetError => '0以上の数値を入力してください';

  @override
  String get fallbackModel => 'フォールバックモデル';

  @override
  String get forkSessionOnResume => '再開時にセッションを分岐';

  @override
  String get persistSessionHistory => 'セッション履歴を保持';

  @override
  String get model => 'モデル';

  @override
  String get sandbox => 'Sandbox';

  @override
  String get reasoning => '推論';

  @override
  String get webSearch => 'ウェブ検索';

  @override
  String get networkAccess => 'ネットワークアクセス';

  @override
  String get additionalWritableRootsTitle => '追加で利用できるディレクトリ';

  @override
  String get additionalWritableRootsDescription =>
      'このセッションでは、Codex の config.toml の writable_roots に加えて有効になります。';

  @override
  String get additionalWritableRootsTooltip =>
      '選択中のプロジェクトに加えて、別プロジェクトのファイルも読み書きしたいときに使います。';

  @override
  String get additionalWritableRootsSuggestions => '最近のプロジェクト';

  @override
  String get addDirectory => 'ディレクトリを追加';

  @override
  String get directoryPath => 'ディレクトリパス';

  @override
  String get worktreeNew => '新規';

  @override
  String worktreeExisting(int count) {
    return '既存 ($count)';
  }

  @override
  String get branchOptional => 'ブランチ（任意）';

  @override
  String get branchHint => 'feature/...';

  @override
  String get noExistingWorktrees => '既存の worktree はありません';

  @override
  String get planApprovalSummary => '上のプランを確認して、承認するか計画を続けてください';

  @override
  String get planApprovalSummaryCard => 'プランを確認して、承認するか計画を続けてください';

  @override
  String get toolApprovalSummary => 'ツール実行には承認が必要です';

  @override
  String get planApproval => 'プラン承認';

  @override
  String get approvalRequired => '承認が必要';

  @override
  String get viewEditPlan => 'プランを表示';

  @override
  String get keepPlanning => '計画を続ける';

  @override
  String get keepPlanningHint => '変更点を入力...';

  @override
  String get sendFeedbackKeepPlanning => 'フィードバックを送信して計画を続ける';

  @override
  String get acceptAndClear => '承認 & クリア';

  @override
  String get acceptPlan => 'プラン承認';

  @override
  String get continuePlanning => '計画を続ける';

  @override
  String get reject => '拒否';

  @override
  String get approve => '承認';

  @override
  String get always => '常に許可';

  @override
  String get approveOnce => '今回だけ許可';

  @override
  String get approveForSession => 'このセッション中は許可';

  @override
  String get approveAlways => '常に許可';

  @override
  String get approveAlwaysSub => '';

  @override
  String get approveSessionMain => 'セッション中許可';

  @override
  String get approveSessionSub => '';

  @override
  String get permissionDefaultDescription => '標準の承認フローです';

  @override
  String get permissionAutoDescription => 'Claude が安全チェック付きで承認を自動処理します';

  @override
  String get permissionAcceptEditsDescription => 'ファイル編集を自動で承認します';

  @override
  String get permissionPlanDescription => '変更を実行する前に分析と計画を行います';

  @override
  String get permissionBypassDescription => 'ほとんどの承認確認なしで実行します';

  @override
  String get executionDefaultDescription => '標準の承認フローです';

  @override
  String get executionAcceptEditsDescription => 'ファイル編集を自動で承認します';

  @override
  String get executionFullAccessDescription => 'ほとんどの承認確認なしで実行します';

  @override
  String get codexPlanModeDescription => '先にプランを作成し、承認後に実行を開始します';

  @override
  String get sandboxRestrictedDescription => '制限された環境でコマンドを実行します';

  @override
  String get sandboxNativeDescription => 'ネイティブ環境でコマンドを実行します';

  @override
  String get sandboxNativeCautionDescription => 'ネイティブ環境でコマンドを実行します（注意）';

  @override
  String get sheetSubtitleApproval => 'どの操作に承認が必要かを制御します';

  @override
  String get sheetSubtitleSandboxCodex =>
      'Codex は安全のためデフォルトで Sandbox が有効です。無効にするとシステムへのフルアクセスが可能になります。';

  @override
  String get sheetSubtitleSandboxClaude =>
      'Claude はデフォルトでネイティブ実行です。Sandbox を有効にするとアクセスが制限されます。';

  @override
  String get sheetSubtitleModel => 'モデルによって速度・能力・コストが異なります。';

  @override
  String get sheetSubtitleEffort => '高い Effort はより丁寧な分析を行いますが、時間とコストが増えます。';

  @override
  String get claudeEffortLowDesc => '高速な応答、分析は少なめ';

  @override
  String get claudeEffortMediumDesc => '速度と品質のバランス';

  @override
  String get claudeEffortHighDesc => 'より丁寧な分析';

  @override
  String get claudeEffortXHighDesc => '複雑な作業向けの拡張推論';

  @override
  String get claudeEffortMaxDesc => '最も丁寧、最も遅い';

  @override
  String get reasoningEffortNoneDesc => '推論なし';

  @override
  String get reasoningEffortMinimalDesc => '最速、分析は最小限';

  @override
  String get reasoningEffortLowDesc => '高速な応答、分析は少なめ';

  @override
  String get reasoningEffortMediumDesc => '速度と品質のバランス';

  @override
  String get reasoningEffortHighDesc => 'より丁寧な分析';

  @override
  String get reasoningEffortXhighDesc => '最も丁寧、最も遅い';

  @override
  String get reasoningEffortMaxDesc => '最も難しい問題向けの最大推論';

  @override
  String get reasoningEffortUltraDesc => '最大推論と自動タスク委譲';

  @override
  String get reasoningEffortModelSpecificDesc => 'モデル固有の推論レベル';

  @override
  String get changePermissionModeTitle => 'Permission Mode を変更';

  @override
  String changePermissionModeBody(String mode) {
    return '$mode に切り替えるとセッションが再起動します。会話は保持されます。';
  }

  @override
  String get changeExecutionModeTitle => 'Execution Mode を変更';

  @override
  String changeExecutionModeBody(String mode) {
    return '$mode に切り替えるとセッションが再起動します。会話は保持されます。';
  }

  @override
  String get changeApprovalPolicyTitle => 'Approval Policy を変更';

  @override
  String changeApprovalPolicyBody(String mode) {
    return '$mode に切り替えるとセッションが再起動します。会話は保持されます。';
  }

  @override
  String get applyPermissionsTitle => '権限変更を適用';

  @override
  String applyPermissionsBody(String mode) {
    return '$mode をいつ有効にするか選択してください。';
  }

  @override
  String get applyPermissionsNextTurnTitle => '次のターンから';

  @override
  String get applyPermissionsNextTurnDescription =>
      '現在の実行を中断しません。現在のターンと表示済みの承認は従来の権限のままです。目標モードの次のステップを含む、まだ開始していない次のターンから適用します。';

  @override
  String get applyPermissionsRestartNowTitle => '今すぐ再起動';

  @override
  String get applyPermissionsRestartNowDescription =>
      '現在のターンを中断して保留中の承認を閉じ、新しい権限で同じ会話を再開します。';

  @override
  String get permissionModeNextTurnAppliedTip =>
      '権限を保存しました。まだ開始していない次のターンから適用され、現在の承認は従来の権限のままです。';

  @override
  String get codexApprovalUntrustedDescription =>
      'trusted コマンドだけ自動実行し、それ以外は確認します';

  @override
  String get codexApprovalOnRequestDescription => '必要だと判断した操作だけ確認します';

  @override
  String get codexApprovalOnFailureDescription =>
      '通常は確認せず実行し、失敗時だけ追加権限を確認します（非推奨）';

  @override
  String get codexApprovalNeverDescription => '確認せず実行し、失敗時も承認を求めません';

  @override
  String get codexAutoReview => '自動レビュー';

  @override
  String get codexAutoReviewDescription => '承認リクエストを Codex が自動レビューします';

  @override
  String get codexAutoReviewDisabledByPolicy => '組織の Browser Use ポリシーにより無効です';

  @override
  String get codexAutoReviewUnavailableDescription =>
      'Never Ask では承認リクエストが発生しないため利用できません';

  @override
  String get guardianApprovalTitle => '自動レビューで承認';

  @override
  String get guardianApprovalDeniedTitle => '自動レビューで却下';

  @override
  String get guardianApprovalTimedOutTitle => '自動レビューがタイムアウト';

  @override
  String get guardianApprovalAbortedTitle => '自動レビューを中止';

  @override
  String get guardianApprovalUnknownRisk => 'リスク未評価';

  @override
  String get guardianApprovalLowRisk => '低リスク';

  @override
  String get guardianApprovalMediumRisk => '中リスク';

  @override
  String get guardianApprovalHighRisk => '高リスク';

  @override
  String get guardianApprovalCriticalRisk => '重大リスク';

  @override
  String get guardianApprovalDetails => '詳細';

  @override
  String get guardianApprovalHideDetails => '詳細を閉じる';

  @override
  String get guardianApprovalReasonLabel => '審査理由';

  @override
  String get guardianApprovalInstructionLabel => '実行内容';

  @override
  String get guardianApprovalInstructionUnavailable =>
      'この Codex バージョンでは具体的な実行内容が提供されませんでした。';

  @override
  String guardianApprovalWorkingDirectory(String path) {
    return '作業ディレクトリ: $path';
  }

  @override
  String get guardianApprovalAuthorizationUnknown => '不明';

  @override
  String get guardianApprovalAuthorizationLow => '低';

  @override
  String get guardianApprovalAuthorizationMedium => '中';

  @override
  String get guardianApprovalAuthorizationHigh => '高';

  @override
  String get guardianApprovalLowRiskAllowReason => '自動レビューが低リスクと判断し、実行を許可しました。';

  @override
  String get guardianApprovalTimedOutReason => '自動レビューはこのリクエストの評価中にタイムアウトしました。';

  @override
  String guardianApprovalAuthorization(String authorization) {
    return '承認レベル: $authorization';
  }

  @override
  String get enablePlanModeTitle => 'Plan Mode を有効化';

  @override
  String get disablePlanModeTitle => 'Plan Mode を無効化';

  @override
  String get enablePlanModeBody => 'Plan Mode を有効化するとセッションが再起動します。会話は保持されます。';

  @override
  String get disablePlanModeBody => 'Plan Mode を無効化するとセッションが再起動します。会話は保持されます。';

  @override
  String get codexNativePlanModeUnavailable =>
      'この Codex ランタイムはネイティブ Plan モードに対応していません。Codex を更新するか、互換性のある Bridge に再接続してください。';

  @override
  String get changeSandboxModeTitle => 'Sandbox Mode を変更';

  @override
  String changeSandboxModeBody(String mode) {
    return '$mode に切り替えるとセッションが再起動します。会話は保持されます。';
  }

  @override
  String get messagePlaceholder => 'Claude にメッセージ...';

  @override
  String get codexMessagePlaceholder => 'Codex にメッセージ...';

  @override
  String get queuedInputForReconnect => '再接続待ちキュー';

  @override
  String get queuedInputPendingDelivery => '送信確認中';

  @override
  String get queuedInputForNextTurn => '次のターンに送信予定';

  @override
  String get sessionCardQueuedInput => 'キュー中';

  @override
  String queuedInputImageCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '画像$count枚',
    );
    return '$_temp0';
  }

  @override
  String get tooltipSteerQueuedMessage => 'キュー中のメッセージを指示として送信';

  @override
  String get tooltipMoveQueuedMessageToInput => 'キュー中のメッセージを入力欄へ移動';

  @override
  String get tooltipCancelQueuedMessage => 'キュー中のメッセージをキャンセル';

  @override
  String get reconnecting => 'Bridge との接続が一時的に切れました。自動で再接続しています...';

  @override
  String get reconnectingQueuedMessages =>
      'Bridge との接続が一時的に切れました。自動で再接続しています。待機中のメッセージは保持されています。';

  @override
  String get disconnectedMessagesQueued =>
      'Bridge に接続できません。操作は端末に保存され、再接続後に送信されます。';

  @override
  String get sessionQueuedForReconnect => 'セッションを再接続待ちキューに追加しました';

  @override
  String get resumeAlreadyQueued => '再開はすでにキューに入っています';

  @override
  String get resumeQueuedForReconnect => '再開を再接続待ちキューに追加しました';

  @override
  String get pendingActionWillCreateOnReconnect => 'Bridge 再接続後に作成します';

  @override
  String get pendingActionWillResumeOnReconnect => 'Bridge 再接続後に再開します';

  @override
  String get pendingActionStatus => '待機中';

  @override
  String get pendingActionProcessingStatus => '復元中';

  @override
  String get pendingActionProcessingStartStatus => '準備中';

  @override
  String get pendingActionProcessingStartDescription => 'Bridge でセッションを準備しています';

  @override
  String get pendingActionProcessingResumeDescription =>
      '画像が多いセッションは時間がかかることがあります';

  @override
  String get pendingActionProcessingStartTitle => '新規セッションを作成中';

  @override
  String get pendingActionProcessingResumeTitle => 'セッション履歴を読み込んでいます';

  @override
  String get tooltipCancelPendingAction => '待機中の操作をキャンセル';

  @override
  String get queuedLocally => 'ローカルでキュー中';

  @override
  String get queuedSubmissionSaveFailed =>
      'このキューメッセージを保存できませんでした。テキストと添付ファイルは入力欄に残っています。';

  @override
  String get processingOnBridge => 'Bridge で処理中';

  @override
  String get offlinePendingNewSessionTitle => '新規セッション待機中';

  @override
  String get offlinePendingResumeTitle => '再開待機中';

  @override
  String diffLines(int count) {
    return '$count 行の diff';
  }

  @override
  String changedLines(int count) {
    return '変更$count行';
  }

  @override
  String hunkCount(int count) {
    return '$countハンク';
  }

  @override
  String fileCount(int count) {
    return '$countファイル';
  }

  @override
  String get tapInterruptHoldStop => 'タップ: 中断, 長押し: 停止';

  @override
  String get tapDetachDesktopTurn => 'タップまたは長押し: スマートフォンから切断（Desktop の処理は継続）';

  @override
  String get rewind => '巻き戻す';

  @override
  String get rewindToHere => 'ここまで巻き戻す';

  @override
  String get rewindModeConversationAndCode => '会話とコードを復元';

  @override
  String get rewindModeConversationOnly => '会話のみ復元';

  @override
  String get rewindModeCodeOnly => 'コードのみ復元';

  @override
  String get rewindConfirmTitle => '巻き戻しの確認';

  @override
  String rewindConfirmBody(Object mode) {
    return 'モード: $mode\n\nこの操作は元に戻せません。実行しますか？';
  }

  @override
  String get rewindCannotRewindFiles => 'ファイルを巻き戻せません';

  @override
  String get codexRewindConfirmTitle => '会話を巻き戻しますか？';

  @override
  String get codexRewindConfirmBody =>
      'このメッセージの直前までチャットを戻し、メッセージを入力欄に戻します。ファイル変更はそのまま残ります。';

  @override
  String get fork => '分岐';

  @override
  String get forkConversation => '会話を分岐';

  @override
  String get forkConversationTitle => '会話を分岐しますか？';

  @override
  String get forkConversationBody =>
      'この応答時点から新しいCodexセッションを作成します。現在のセッションは変更されません。';

  @override
  String get forkTargetNotFound => '分岐元のユーザー発言が見つかりません';

  @override
  String get tapToRetry => 'タップしてリトライ';

  @override
  String diffSummaryAddedRemoved(int added, int removed) {
    return '+$added/-$removed 行';
  }

  @override
  String lineCountSummary(int count) {
    return '$count 行';
  }

  @override
  String get toolResult => 'ツール結果';

  @override
  String toolDisplayRead(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'ファイルを読み取り',
      'other': '読み取り済み',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayReadSkill(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'Skill を読み取り',
      'other': 'Skill を読み取り済み',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayFileChange(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'ファイルを変更',
      'completed': 'ファイルを変更しました',
      'result': 'ファイル変更が完了しました',
      'other': 'ファイルを変更',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayCommand(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'コマンドを実行',
      'completed': 'コマンドを実行しました',
      'result': 'ターミナルコマンドが完了しました',
      'other': 'コマンドを実行',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayMultipleCommands(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': '複数のコマンドを実行',
      'completed': '複数のコマンドを実行しました',
      'result': '複数のコマンドが完了しました',
      'other': '複数のコマンドを実行',
    });
    return '$_temp0';
  }

  @override
  String toolDisplaySearchFiles(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'ファイルを検索',
      'other': 'ファイルを検索しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayListFiles(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'ファイル一覧を表示',
      'other': 'ファイル一覧を表示しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplaySearchWeb(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'ウェブを検索',
      'other': 'ウェブを検索しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayReadWebPage(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'ウェブページを読み取り',
      'other': 'ウェブページを読み取りました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayStartSubAgent(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'サブ Agent を開始',
      'other': 'サブ Agent を開始しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayGuideSubAgent(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'サブ Agent を誘導',
      'other': 'サブ Agent を誘導しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayResumeSubAgent(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'サブ Agent を再開',
      'other': 'サブ Agent を再開しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayWaitForSubAgents(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'サブ Agent を待機',
      'other': 'サブ Agent を待機しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayCloseSubAgent(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'サブ Agent を終了',
      'other': 'サブ Agent を終了しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayInterruptSubAgent(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'サブ Agent を中断',
      'other': 'サブ Agent を中断しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayListSubAgents(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'サブ Agent を表示',
      'other': 'サブ Agent を表示しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayInteractWithSubAgent(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'サブ Agent と対話',
      'other': 'サブ Agent と対話しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplaySubAgentActivity(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'サブ Agent のアクティビティ',
      'other': 'サブ Agent のアクティビティを更新しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayCompactContext(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'コンテキストを圧縮',
      'other': 'コンテキストを圧縮しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayUpdatePlan(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': '計画を更新',
      'other': '計画を更新しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayCreateGoal(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': '目標を作成',
      'other': '目標を作成しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayReadGoal(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': '目標を確認',
      'other': '目標を確認しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayUpdateGoal(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': '目標を更新',
      'other': '目標を更新しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayRequestUserInput(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': 'ユーザー入力を要求',
      'other': 'ユーザー入力を要求しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayWait(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': '待機',
      'other': '待機が完了しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayViewImage(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': '画像を表示',
      'other': '画像を表示しました',
    });
    return '$_temp0';
  }

  @override
  String toolDisplayGenerateImage(String phase) {
    String _temp0 = intl.Intl.selectLogic(phase, {
      'action': '画像を生成',
      'other': '画像生成が完了しました',
    });
    return '$_temp0';
  }

  @override
  String get chatProcessRunningTitle => '思考・実行中';

  @override
  String get chatProcessTitle => '思考と操作';

  @override
  String chatProcessItemCount(int count) {
    return '$count 件';
  }

  @override
  String get chatProcessIntermediateUpdates => '途中経過';

  @override
  String chatProcessUpdateCount(int count) {
    return '$count 件の更新';
  }

  @override
  String chatProcessUpdateDetailCount(int count, int detailCount) {
    return '$count 件の更新 · $detailCount 件の詳細';
  }

  @override
  String get chatProcessCurrentProgress => '現在の進捗';

  @override
  String get chatProcessLive => '進行中';

  @override
  String get chatProcessLatestTool => '最新のツール';

  @override
  String get chatProcessRunningTool => '実行中';

  @override
  String get answered => '回答済み';

  @override
  String agentIsAsking(Object agent) {
    return '$agent が質問しています';
  }

  @override
  String get submitAllAnswers => 'すべての回答を送信';

  @override
  String submitWithCount(int count) {
    return '送信 ($count 件選択)';
  }

  @override
  String get selectOptionsToSubmit => 'オプションを選択してください';

  @override
  String get typeYourAnswer => '回答を入力...';

  @override
  String get orTypeCustomAnswer => 'またはカスタム回答を入力...';

  @override
  String get otherAnswer => 'その他の回答...';

  @override
  String get selectAllThatApply => '該当するものをすべて選択';

  @override
  String get noScreenshotsYet => 'スクリーンショットはまだありません';

  @override
  String get screenshotButtonHint => 'チャットツールバーのスクリーンショットボタンで画面をキャプチャできます。';

  @override
  String get screenshotsWillAppearHere => 'Claude セッションのスクリーンショットがここに表示されます。';

  @override
  String allWithCount(int count) {
    return 'すべて ($count)';
  }

  @override
  String get noImages => '画像がありません';

  @override
  String get failedToDeleteImage => '画像の削除に失敗しました';

  @override
  String get failedToDownloadImage => '画像のダウンロードに失敗しました';

  @override
  String get failedToShareImage => '画像の共有に失敗しました';

  @override
  String get deleteScreenshot => 'スクリーンショットを削除しますか？';

  @override
  String get cannotBeUndone => 'この操作は取り消せません。';

  @override
  String get changes => '変更';

  @override
  String get refresh => '更新';

  @override
  String get diffCompareSideBySide => '並べて比較';

  @override
  String get diffCompareSlider => 'スライダー';

  @override
  String get diffCompareOverlay => 'オーバーレイ';

  @override
  String get diffCompareToggle => 'トグル';

  @override
  String get diffBefore => '変更前';

  @override
  String get diffAfter => '変更後';

  @override
  String get diffNewFile => '新規ファイル';

  @override
  String get diffDeleted => '削除済み';

  @override
  String get diffNoImage => '画像なし';

  @override
  String get noChanges => '変更なし';

  @override
  String get showAll => 'すべて表示';

  @override
  String get setupGuideTitle => 'セットアップガイド';

  @override
  String get guideAboutTitle => 'CC Pocket とは';

  @override
  String get guideAboutDescription =>
      'Bridge Server 経由で Codex や Claude をスマートフォンから使えるモバイルクライアントです。';

  @override
  String get guideAboutSdkNoteTitle => 'Claude Agent SDK について';

  @override
  String get guideAboutSdkNoteBody =>
      'Claude Code のライブラリ版です。履歴や .claude、CLAUDE.md などの設定ファイルを共有でき、承認フローもおおよそ同じ感覚で使えます。';

  @override
  String get guideAboutDiagramTitle => 'しくみ';

  @override
  String get guideAboutDiagramPhone => 'iPhone';

  @override
  String get guideAboutDiagramBridge => 'Bridge Server';

  @override
  String get guideAboutDiagramClaude => 'Codex CLI\n/ Claude Agent SDK';

  @override
  String get guideAboutDiagramCaption =>
      'PC の Bridge Server が Codex CLI や Claude Agent SDK に接続し、\nスマホからその Bridge に接続して使います。';

  @override
  String get guideBridgeTitle => 'Bridge Server の\nセットアップ';

  @override
  String get guideBridgeDescription =>
      'PC で Bridge Server を起動します。Claude を使う場合は ANTHROPIC_API_KEY も設定してください。';

  @override
  String get guideBridgePrerequisites => '必要なもの';

  @override
  String get guideBridgePrereq1 => 'Node.js がインストールされた Mac / PC';

  @override
  String get guideBridgePrereq2 => 'Claude を使う場合は ANTHROPIC_API_KEY を設定';

  @override
  String get guideBridgePrereq3 => 'Codex を使う場合は Codex の認証を完了';

  @override
  String get guideBridgeStep1 => 'npx で実行（推奨）';

  @override
  String get guideBridgeStep1Command => 'npx --yes @ccpocket/bridge@latest';

  @override
  String get guideBridgeStep2 => 'またはグローバルインストール';

  @override
  String get guideBridgeStep2Command =>
      'npm install -g @ccpocket/bridge\nccpocket-bridge';

  @override
  String get guideBridgeQrNote => '起動するとターミナルに QR コードが表示されます';

  @override
  String get guideConnectionTitle => '接続方法';

  @override
  String get guideConnectionDescription => '同じ Wi-Fi ネットワーク内なら、すぐに接続できます。';

  @override
  String get guideConnectionQr => 'QR コードスキャン';

  @override
  String get guideConnectionQrDescription =>
      'ターミナルに表示された QR コードを読み取るだけ。一番簡単です。';

  @override
  String get guideConnectionMdns => '自動検出 (mDNS)';

  @override
  String get guideConnectionMdnsDescription =>
      '同一 LAN 内の Bridge Server を自動で見つけて表示します。';

  @override
  String get guideConnectionManual => '手動入力';

  @override
  String get guideConnectionManualDescription =>
      'ws://<IP アドレス>:8765 の形式で直接入力します。';

  @override
  String get guideConnectionRecommended => 'おすすめ';

  @override
  String get guideTailscaleTitle => '外出先からの接続';

  @override
  String get guideTailscaleDescription =>
      '自宅の外からも使いたい場合は、Tailscale（VPN の一種）を使えば安全にリモート接続できます。';

  @override
  String get guideTailscaleStep1 => 'Mac と iPhone の両方に Tailscale をインストール';

  @override
  String get guideTailscaleStep2 => '同じアカウントでログイン';

  @override
  String get guideTailscaleStep3 =>
      'Bridge URL に Tailscale IP を使用\n(例: ws://100.x.x.x:8765)';

  @override
  String get guideTailscaleWebsite => 'Tailscale 公式サイト';

  @override
  String get guideTailscaleWebsiteHint => '詳しいセットアップ方法は公式サイトをご覧ください。';

  @override
  String get guideLaunchdTitle => '常時起動の設定';

  @override
  String get guideLaunchdDescription =>
      '毎回手動で Bridge Server を起動するのが面倒な場合、マシンの起動時に自動で立ち上がるよう設定できます。';

  @override
  String get guideLaunchdCommand => 'セットアップコマンド';

  @override
  String get guideLaunchdCommandValue =>
      'npx --yes @ccpocket/bridge@latest setup';

  @override
  String get guideLaunchdRecommendation =>
      'まずは手動起動で動作確認してから、安定したらサービス登録がおすすめです。';

  @override
  String get guideAutostartMacDescription =>
      'launchd に登録。シェル環境（nvm、Homebrew 等）が自動で引き継がれます。';

  @override
  String get guideAutostartLinuxDescription =>
      'systemd ユーザーサービスを作成。Raspberry Pi 等の Linux ホストに対応。';

  @override
  String get guideReadyTitle => '準備完了!';

  @override
  String get guideReadyDescription =>
      'Bridge Server を起動して、\nQR コードをスキャンするところから\n始めましょう。';

  @override
  String get guideReadyStart => 'さっそく始める';

  @override
  String get guideReadyHint => 'このガイドは設定画面からいつでも確認できます';

  @override
  String get creatingSession => 'セッション作成中...';

  @override
  String get resolvingLinkedSession => 'リンク先のセッションを検索しています...';

  @override
  String get resumingLinkedSession => 'セッションを再開しています...';

  @override
  String sessionLinkProgressStage(String stage) {
    String _temp0 = intl.Intl.selectLogic(stage, {
      'waiting_for_connection': 'Bridge に接続しています...',
      'waiting_for_identity': 'データソースを確認しています...',
      'request_sent': 'セッション要求を送信しています...',
      'request_accepted': 'Bridge が要求を受け付けました...',
      'runtime_checked': '実行中のセッションを確認しています...',
      'catalog_scanning': 'セッション一覧を検索しています...',
      'catalog_scanned': 'セッション一覧を確認しました...',
      'resolution_ready': 'セッションが見つかりました...',
      'resume_lock_waiting': 'セッションへのアクセスを待っています...',
      'resume_lock_acquired': 'セッションへのアクセスを取得しました...',
      'history_reading': '最近の履歴を読み込んでいます...',
      'history_read': '最近の履歴を読み込みました...',
      'runtime_starting': 'セッションを起動しています...',
      'metadata_loading': 'セッション情報を読み込んでいます...',
      'ready': 'セッションを開いています...',
      'other': 'セッションを読み込んでいます...',
    });
    return '$_temp0';
  }

  @override
  String get sessionUnavailableTitle => 'セッションを利用できません';

  @override
  String get sessionUnavailableDescription =>
      'このセッションは現在の Bridge では利用できません。最近のセッションから開いてください。';

  @override
  String get openRecentSessions => '最近のセッションを開く';

  @override
  String get copyForAgent => 'エージェント用にコピー';

  @override
  String get messageHistory => 'メッセージ履歴';

  @override
  String get viewChanges => '変更を確認';

  @override
  String get screenshot => 'スクリーンショット';

  @override
  String get screenshotSaved => 'スクリーンショットを保存しました';

  @override
  String get screenshotFailed => 'スクリーンショットの保存に失敗しました';

  @override
  String get fullScreen => 'フルスクリーン';

  @override
  String get captureEntireDesktop => 'デスクトップ全体を撮影';

  @override
  String get noWindowsFound => 'ウインドウが見つかりません';

  @override
  String get debug => 'デバッグ';

  @override
  String get logs => 'ログ';

  @override
  String get viewApplicationLogs => 'アプリケーションログを表示';

  @override
  String get mockPreview => 'モックプレビュー';

  @override
  String get viewMockChatScenarios => 'モックチャットシナリオを表示';

  @override
  String get updateTrack => 'アップデートトラック';

  @override
  String get updateTrackDescription => '変更後にアプリを再起動すると反映されます';

  @override
  String get updateTrackStable => 'Stable（安定版）';

  @override
  String get updateTrackStaging => 'Staging（テスト）';

  @override
  String get updateDownloaded => 'アップデートをダウンロードしました。アプリを再起動すると反映されます。';

  @override
  String get promptHistory => 'プロンプト履歴';

  @override
  String get frequent => '頻度順';

  @override
  String get recent => '新しい順';

  @override
  String get searchHint => '検索...';

  @override
  String get noMatchingPrompts => '一致するプロンプトがありません';

  @override
  String get noPromptHistoryYet => 'プロンプト履歴はまだありません';

  @override
  String get promptHistoryFilters => 'フィルター';

  @override
  String get promptHistoryFilterThisDevice => 'この端末で使った履歴';

  @override
  String get promptHistoryFilterThisProject => '開いているプロジェクト';

  @override
  String get promptHistoryFilterThisBridge => '接続中のBridge';

  @override
  String get promptHistoryFilterFavorites => 'お気に入り';

  @override
  String get promptHistoryFilterCommands => 'コマンドとスキル';

  @override
  String get promptHistoryOpenProjectEmptyHint =>
      '開いているプロジェクトのフィルターは、新しいアプリで記録した履歴にのみ有効です。';

  @override
  String get promptHistorySectionTitle => 'プロンプト履歴';

  @override
  String get promptHistorySyncTitle => 'プロンプト履歴を同期';

  @override
  String get promptHistoryReplaceTitle => '旧方式履歴でBridgeを上書き';

  @override
  String get promptHistoryReplaceSubtitle =>
      '旧方式履歴はアプリ側で管理されていました。新方式ではBridge側で履歴を管理します。メイン端末で移行済みの場合は通常不要です。サブ端末でBridgeの履歴を初期化してしまった場合に、接続中のBridge履歴をこの端末の旧方式履歴で上書きします。';

  @override
  String get promptHistoryReplaceConfirmAction => '上書き';

  @override
  String get promptHistoryReplaceDismissAction => '移行済みとして非表示';

  @override
  String get promptHistoryNotSyncedYet => 'まだ同期していません';

  @override
  String promptHistoryLatestSync(String time) {
    return '最終同期: $time';
  }

  @override
  String promptHistorySyncedBridges(int count) {
    return '$count件のBridgeを同期済み';
  }

  @override
  String promptHistorySyncSummaryWithFailures(int synced, int failed) {
    return '$synced件同期、$failed件失敗';
  }

  @override
  String promptHistoryBridgeId(String id) {
    return 'Bridge ID: $id';
  }

  @override
  String promptHistoryOtherBridgeRegistrations(String registrations) {
    return '他の登録: $registrations';
  }

  @override
  String get promptHistoryNoSyncTime => '同期時刻なし';

  @override
  String get approvalQueue => '承認キュー';

  @override
  String get resetQueue => 'キューをリセット';

  @override
  String get swipeSkip => 'スキップ';

  @override
  String get swipeSend => '送信';

  @override
  String get swipeDismiss => '却下';

  @override
  String get swipeApprove => '承認';

  @override
  String get swipeReject => '拒否';

  @override
  String get allClear => 'すべて完了!';

  @override
  String itemsProcessed(int count) {
    return '$count 件処理しました';
  }

  @override
  String bestStreak(int count) {
    return '最高連続: $count';
  }

  @override
  String get tryAgain => 'もう一度';

  @override
  String get waitingForTasks => 'タスク待ち';

  @override
  String get agentReadyForPrompt => 'エージェントは次のプロンプトを待っています。';

  @override
  String get backToSessions => 'セッション一覧に戻る';

  @override
  String get working => '処理中...';

  @override
  String get waitingForApprovalRequests => 'エージェントからの承認リクエストを待っています。';

  @override
  String get noActiveSessions => 'アクティブなセッションがありません';

  @override
  String get startSessionToBegin => 'セッションを開始して承認リクエストの受信を始めましょう。';

  @override
  String get settingsTitle => '設定';

  @override
  String get sectionGeneral => '一般';

  @override
  String get sectionConnectionAccounts => '接続とアカウント';

  @override
  String get sectionNotifications => '通知';

  @override
  String get sectionSupport => '応援';

  @override
  String get sectionEditor => 'エディタ';

  @override
  String get textDensity => '表示密度';

  @override
  String get textDensityDescription =>
      'OSの文字サイズ設定に、このアプリ倍率をさらに掛けます。100%はOS設定のままです。';

  @override
  String get codeFontSize => 'コード文字サイズ';

  @override
  String get codeFontFamily => 'コードフォント';

  @override
  String get codeFontPreview => 'プレビュー';

  @override
  String get indentSize => 'インデント幅';

  @override
  String get indentSizeSubtitle => '箇条書きのインデントに使用するスペース数';

  @override
  String get gitDiffInteractionMode => 'Git diff 操作';

  @override
  String get gitDiffQuickActions => 'クイック操作';

  @override
  String get gitDiffQuickActionsDescription =>
      '1本指の横スワイプで hunk の Stage / Unstage / Revert を実行します。長い行は折り返します。';

  @override
  String get gitDiffScrollFirst => '横スクロール優先';

  @override
  String get gitDiffScrollFirstDescription =>
      '長い行を折り返さず、hunk 単位で横スクロールできます。Git 操作はロングタップのメニューまたは下部ボタンから実行します。';

  @override
  String get imagePasteShortcut => '画像ペーストのショートカット';

  @override
  String get imagePasteShortcutCtrlV => 'Ctrl+V';

  @override
  String get imagePasteShortcutCtrlVDescription =>
      'macOS で推奨。Cmd+V を通常のペーストや音声入力ツール用に残します。';

  @override
  String get imagePasteShortcutCommandV => 'Cmd+V';

  @override
  String get imagePasteShortcutCommandVDescription =>
      '音声入力アプリ、クリップボード管理アプリ、テキスト展開ツールと競合する可能性があります。';

  @override
  String get gitDiffFocusAutoLandscape => 'diff集中モードで横画面にする';

  @override
  String get gitDiffFocusAutoLandscapeDescription =>
      'モバイルレイアウトでは、diff集中モードに入ると横画面に固定します。解除すると通常の回転に戻ります。';

  @override
  String get remoteGitStatusBadge => '未同期のGitコミットを薄いバッジで表示';

  @override
  String get remoteGitStatusBadgeDescription =>
      'fetch後に現在ブランチがpushまたはpull可能な場合、セッション画面のGitボタンに薄いバッジを表示します。';

  @override
  String get sectionAbout => '概要';

  @override
  String get theme => 'テーマ';

  @override
  String get themeSystem => 'システム';

  @override
  String get themeLight => 'ライト';

  @override
  String get themeDark => 'ダーク';

  @override
  String get appIconTitle => 'アプリアイコン';

  @override
  String get appIconMonthlySupporterPerk => '月額サポーター特典です。';

  @override
  String appIconSettingsSubtitle(String device) {
    return '$deviceのホーム画面に表示されるアイコンを変更できます。';
  }

  @override
  String get appIconSupporterDialogTitle => '月額サポーター特典';

  @override
  String get appIconSupporterSectionLabel => '月額サポーター特典';

  @override
  String get appIconPickerTitle => 'アプリアイコンを選ぶ';

  @override
  String get appIconPickerSubtitle => 'ホーム画面に表示するアイコンを選べます。';

  @override
  String get appIconOptionDefaultTitle => 'ダーク';

  @override
  String get appIconOptionDefaultSubtitle => '通常の CC Pocket アイコンです。';

  @override
  String get appIconOptionLightOutlineTitle => 'ライト';

  @override
  String get appIconOptionLightOutlineSubtitle => '軽やかなラインが映える明るめのバリエーション。';

  @override
  String get appIconOptionCopperEmeraldTitle => 'メタリック';

  @override
  String get appIconOptionCopperEmeraldSubtitle => '光沢感のある特別版。';

  @override
  String get language => '言語';

  @override
  String get languageSystem => '端末の設定に従う';

  @override
  String get voiceInput => '音声入力';

  @override
  String get pushNotifications => 'プッシュ通知';

  @override
  String get pushNotificationsSubtitle => 'Bridge 経由でセッション通知を受け取ります';

  @override
  String get pushNotificationsUnavailable => 'Firebase 設定後に利用できます';

  @override
  String get version => 'バージョン';

  @override
  String get loading => '読み込み中...';

  @override
  String get setupGuideSubtitle => '初めての方はこちら';

  @override
  String get openSourceLicenses => 'オープンソースライセンス';

  @override
  String get githubRepository => 'GitHub リポジトリ';

  @override
  String get changelog => '変更履歴';

  @override
  String get changelogTitle => '変更履歴';

  @override
  String get showAllMain => 'すべて表示 (main)';

  @override
  String get changelogFetchError => '変更履歴の取得に失敗しました';

  @override
  String get fcmBridgeNotInitialized => 'Bridge が未初期化です';

  @override
  String get fcmTokenFailed => 'FCM token を取得できませんでした';

  @override
  String get fcmEnabled => '通知を有効化しました';

  @override
  String get fcmEnabledPending => 'Bridge 再接続後に通知登録します';

  @override
  String get fcmDisabled => '通知を無効化しました';

  @override
  String get fcmDisabledPending => 'Bridge 再接続後に通知解除します';

  @override
  String get pushPrivacyMode => 'プライバシーモード';

  @override
  String get pushPrivacyModeSubtitle => '通知にプロジェクト名や内容を含めない';

  @override
  String get updateNotificationLanguage => '通知言語を更新';

  @override
  String get notificationLanguageUpdated => '通知言語を更新しました';

  @override
  String get defaultNotRecommended => 'Default（非推奨）';

  @override
  String get imageAttached => '画像添付';

  @override
  String get usageConnectToView => 'Bridge に接続すると利用量を表示できます';

  @override
  String get usageFetchFailed => '取得に失敗しました';

  @override
  String get usageFiveHour => '5時間';

  @override
  String get usageSevenDay => '7日間';

  @override
  String get settingsUsageSectionTitle => '利用量';

  @override
  String get settingsUsageNoCodexData => 'Codex の利用量データが見つかりませんでした。';

  @override
  String get usageDisplayModeRemaining => '残量';

  @override
  String get usageDisplayModeUsed => '使用量';

  @override
  String get settingsClaudeUsageDescription => 'Claude の公式課金ページをブラウザで開きます。';

  @override
  String get settingsClaudeApiBilling => 'API キーの課金';

  @override
  String get settingsClaudeSubscriptionUsage => 'サブスクリプション利用状況';

  @override
  String get settingsNewSessionTabs => '新規セッションタブ';

  @override
  String get settingsNewSessionTabsDescription =>
      '新規セッションで表示する AI ツールの選択肢と並び順を変更できます。';

  @override
  String get showBridgeNameInSessionList => 'Bridge名を表示';

  @override
  String get showBridgeNameInSessionListSubtitle =>
      '複数のBridgeが登録されているとき、接続中のBridge名をセッション一覧に表示します。';

  @override
  String get autoRenameCodexSessions => '自動Rename (Codex)';

  @override
  String get autoRenameCodexSessionsSubtitle =>
      '最初のエージェント応答後に Codex セッションへ自動で名前を付ける';

  @override
  String get showExtendedCodexEfforts => 'Effortスライダーに Max / Ultra を表示';

  @override
  String get showExtendedCodexEffortsSubtitle =>
      '選択した Codex モデルが対応している場合、スライダーに Max と Ultra を追加します';

  @override
  String get autoRenameClaudeSessions => '自動Rename (Claude)';

  @override
  String get autoRenameClaudeSessionsSubtitle =>
      '最初のエージェント応答後に Claude セッションへ自動で名前を付ける。API Key 利用時は追加の従量課金が発生します。';

  @override
  String get newSessionTabCodex => 'Codex';

  @override
  String get newSessionTabClaudeCode => 'Claude';

  @override
  String usageResetAt(String time) {
    return 'リセット: $time';
  }

  @override
  String get usageAlreadyReset => 'リセット済み';

  @override
  String attachedImages(int count) {
    return '添付画像 ($count)';
  }

  @override
  String get attachedImagesNoCount => '添付画像';

  @override
  String get failedToFetchImages => '画像を取得できませんでした';

  @override
  String get responseTimedOut => '応答がタイムアウトしました';

  @override
  String failedToFetchImagesWithError(String error) {
    return '画像の取得に失敗しました: $error';
  }

  @override
  String get retry => 'リトライ';

  @override
  String get clipboardNotAvailable => 'クリップボードにアクセスできません';

  @override
  String get failedToLoadImage => '画像の読み込みに失敗しました';

  @override
  String get generatedImagePromptLabel => 'プロンプト';

  @override
  String get generatedImageDetailsLabel => '詳細';

  @override
  String get generatedImageHideDetailsLabel => '詳細を閉じる';

  @override
  String get generatedImageStatusLabel => 'ステータス';

  @override
  String get generatedImageSavedPathLabel => '保存先';

  @override
  String get previousImage => '前の画像';

  @override
  String get nextImage => '次の画像';

  @override
  String generatedImagePositionLabel(int current, int total) {
    return '生成画像 $current / $total';
  }

  @override
  String get noImageInClipboard => 'クリップボードに画像がありません';

  @override
  String get failedToReadClipboard => 'クリップボードの読み取りに失敗しました';

  @override
  String imageLimitReached(int max) {
    return '画像は最大$max枚までです';
  }

  @override
  String imageLimitTruncated(int max, int dropped) {
    return '最初の$max枚のみ添付しました（$dropped枚を除外）';
  }

  @override
  String get selectFromGallery => 'ギャラリーから選択';

  @override
  String get pasteFromClipboard => 'クリップボードから貼付';

  @override
  String get voiceInputLanguage => '音声入力の言語';

  @override
  String get hideVoiceInput => '音声入力ボタンを非表示';

  @override
  String get hideVoiceInputSubtitle => 'サードパーティの音声入力キーボードを利用する場合に便利';

  @override
  String get archive => 'アーカイブ';

  @override
  String get archiveConfirm => 'このセッションをアーカイブしますか？';

  @override
  String get archiveConfirmMessage =>
      'セッションは一覧から非表示になります。Claude Codeからは引き続きアクセスできます。';

  @override
  String get sessionArchived => 'セッションをアーカイブしました';

  @override
  String get archiveFailed => 'セッションのアーカイブに失敗しました';

  @override
  String archiveFailedWithError(String error) {
    return 'セッションのアーカイブに失敗しました: $error';
  }

  @override
  String get noRecentSessions => '最近のセッションはありません';

  @override
  String get noSessionsMatchFilters => '現在のフィルター条件に一致するセッションがありません';

  @override
  String get adjustFiltersAndSearch => 'フィルター条件や検索語を変更してください';

  @override
  String get tooltipDisplayMode => 'カードに表示するメッセージを切替';

  @override
  String get tooltipProviderFilter => 'AIツールで絞り込み';

  @override
  String get tooltipProjectFilter => 'プロジェクトで絞り込み';

  @override
  String get tooltipNamedOnly => '名前を付けたセッションのみ';

  @override
  String get tooltipIndent => 'インデントを増やす';

  @override
  String get tooltipDedent => 'インデントを減らす';

  @override
  String get tooltipSlashCommand => 'コマンド・スキルを入力';

  @override
  String get slashCommandsTitle => 'コマンド';

  @override
  String get slashCommandsProject => 'プロジェクト';

  @override
  String get slashCommandsSkills => 'スキル';

  @override
  String get slashCommandsApps => 'アプリ';

  @override
  String get slashCommandsPlugins => 'プラグイン';

  @override
  String get slashCommandsBuiltIn => '組み込み';

  @override
  String get slashCommandCompactDescription => '会話のコンテキストを圧縮';

  @override
  String get slashCommandPlanDescription => 'プランモードに切り替え';

  @override
  String get slashCommandGoalDescription => '目標を設定または管理';

  @override
  String get slashCommandClearDescription => '会話を消去';

  @override
  String get slashCommandHelpDescription => 'ヘルプを表示';

  @override
  String get slashCommandContextDescription => 'コンテキスト使用量を表示';

  @override
  String get slashCommandCostDescription => 'コスト概要を表示';

  @override
  String get slashCommandInitDescription => 'プロジェクトを初期化';

  @override
  String get slashCommandReviewDescription => 'コードレビュー';

  @override
  String get slashCommandModelDescription => 'モデルを切り替え';

  @override
  String get slashCommandSkillsDescription => '利用可能なスキルを表示';

  @override
  String get slashCommandStatusDescription => '状態を表示';

  @override
  String get slashCommandMemoryDescription => 'CLAUDE.md を編集';

  @override
  String get slashCommandConfigDescription => '設定を開く';

  @override
  String get slashCommandPermissionsDescription => '権限を表示';

  @override
  String get slashCommandPrCommentsDescription => 'PR コメントを表示';

  @override
  String get slashCommandReleaseNotesDescription => 'リリースノートを表示';

  @override
  String get slashCommandSecurityReviewDescription => 'セキュリティレビューを実行';

  @override
  String get slashCommandResumeDescription => 'セッションを再開';

  @override
  String get slashCommandRenameDescription => 'セッション名を変更';

  @override
  String get slashCommandDoctorDescription => 'ヘルスチェックを実行';

  @override
  String get slashCommandMcpDescription => 'MCP サーバーを管理';

  @override
  String get slashCommandExportDescription => '会話をエクスポート';

  @override
  String get slashCommandAddDirDescription => 'ディレクトリを追加';

  @override
  String get slashCommandRewindDescription => '前の時点に巻き戻す';

  @override
  String get slashCommandVimDescription => 'Vim モードを有効化';

  @override
  String get slashCommandLoginDescription => 'アカウントを切り替え';

  @override
  String get tooltipMention => 'ファイル・プラグインをメンション';

  @override
  String get tooltipDollarMention => 'スキル・アプリを入力';

  @override
  String get tooltipPermissionMode => 'パーミッションモード';

  @override
  String get tooltipAttachImage => '画像を添付';

  @override
  String get tooltipPromptHistory => 'プロンプト履歴を開く';

  @override
  String get tooltipVoiceInput => '音声入力を開始';

  @override
  String get tooltipStopRecording => '録音を停止';

  @override
  String get tooltipSendMessage => 'メッセージを送信';

  @override
  String get tooltipRemoveImage => '画像を削除';

  @override
  String get tooltipClearDiff => 'Diff選択を解除';

  @override
  String get showMore => 'もっと見る';

  @override
  String get showLess => '閉じる';

  @override
  String get authErrorTitle => 'Claudeの再ログインが必要です';

  @override
  String get authErrorBody => 'BridgeマシンでClaudeに再ログインしてください。';

  @override
  String get authErrorPrimaryCommandLabel => '手順1';

  @override
  String get authErrorSecondaryCommandLabel => '手順2';

  @override
  String get authErrorAlternativeLabel => 'シェルから実行する場合';

  @override
  String get apiKeyRequiredTitle => 'APIキーが必要です';

  @override
  String get apiKeyRequiredBody =>
      'Anthropic の現行 Claude Agent SDK ドキュメントでは、サードパーティ製品で Claude のサブスクリプションログインを使うことは許可されていません。APIキーをご利用ください。';

  @override
  String get apiKeyRequiredHint => 'APIキーの取得:';

  @override
  String get authHelpTitle => '認証トラブルシューティング';

  @override
  String get authHelpFetchError => 'トラブルシューティングガイドを読み込めませんでした';

  @override
  String get authHelpButton => '手順を見る';

  @override
  String get authHelpLanguageJa => '日本語';

  @override
  String get authHelpLanguageEn => 'English';

  @override
  String get authHelpLanguageZhHans => '简体中文';

  @override
  String get authHelpLanguageKo => '한국어';

  @override
  String get terminalApp => 'ターミナルアプリ';

  @override
  String get terminalAppSubtitle => '外部ターミナルアプリでプロジェクトを開く';

  @override
  String get terminalAppNone => '未設定';

  @override
  String get terminalAppCustom => 'カスタム';

  @override
  String get terminalAppName => 'アプリ名';

  @override
  String get terminalUrlTemplate => 'URL テンプレート';

  @override
  String get terminalUrlTemplateHint => '変数: host, user, port, project_path';

  @override
  String get terminalSshUser => 'SSH ユーザー';

  @override
  String get terminalSshUserHint => '未入力時はマシンの SSH ユーザーを使用';

  @override
  String get openInTerminal => 'ターミナルで開く';

  @override
  String get terminalAppNotInstalled => 'ターミナルアプリを開けませんでした';

  @override
  String get terminalAppExperimental => 'プレビュー';

  @override
  String get terminalAppExperimentalNote =>
      'この機能はプレビュー版です。プリセットはアプリや環境によって動作しない場合があります。新しいプリセットの追加は GitHub で歓迎しています！';

  @override
  String get sectionSpread => 'CC Pocket を広める';

  @override
  String get spreadAppealMessage =>
      'CC Pocket はまだ利用者が少なく、このままだと開発を続けるのが難しい状況です。気に入っていたら、ストア評価（星だけでOK）や知り合いへの紹介で応援してください。';

  @override
  String get shareApp => 'SNSでシェア';

  @override
  String get shareAppSubtitle => '同僚や友人に紹介する';

  @override
  String shareText(String url) {
    return 'CC Pocket: Claude & Codex\nスマホからコーディングエージェントを操作できるアプリ 📱\n#ccpocket\n$url';
  }

  @override
  String get starOnGithub => 'GitHub にスターする';

  @override
  String get rateOnStore => 'App Store で評価する';

  @override
  String get rateOnStoreAndroid => 'Google Play で評価する';

  @override
  String get supporterTitle => 'サポーター';

  @override
  String get supporterMonthlyTitle => '月額サポーター';

  @override
  String get supporterMonthlyPlusTitle => '月額サポーター Plus';

  @override
  String get supporterSnackTitle => 'おやつで応援';

  @override
  String get supporterCoffeeTitle => 'ドリンクで応援';

  @override
  String get supporterLunchTitle => 'ランチで応援';

  @override
  String get supporterStatusActive => 'CC Pocket を応援してくれてありがとうございます。';

  @override
  String get supporterStatusInactive => 'アプリは無料のまま。継続開発を応援できます。';

  @override
  String get supporterStatusLoading => '応援状態を確認しています...';

  @override
  String get supportEntryInactiveTitle => '応援する';

  @override
  String get supportEntryInactiveSubtitle =>
      'CC Pocket が気に入ったら、継続開発を応援してもらえるとうれしいです。';

  @override
  String get supportEntryOneTimeTitle => '応援ありがとう';

  @override
  String get supportEntryOneTimeSubtitle => 'これまでの応援、ありがとうございます。';

  @override
  String get supportEntryActiveTitle => '応援中';

  @override
  String supportEntryActiveSubtitle(String date) {
    return 'いつもありがとうございます。$dateから応援中です。';
  }

  @override
  String get supporterMonthlyDescription => '継続的な開発を後押し';

  @override
  String get supporterMonthlyPerkLabel => 'アプリアイコン変更特典付き';

  @override
  String get supporterSnackDescription => 'おやつを1つおごる';

  @override
  String get supporterCoffeeDescription => 'ドリンクを1杯おごる';

  @override
  String get supporterLunchDescription => 'ランチを1食おごる';

  @override
  String get supporterBuyButton => '応援する';

  @override
  String get supporterActiveButton => '応援中';

  @override
  String get supporterSubscribedButton => '購読中';

  @override
  String get supporterRestoreButton => '購入を復元';

  @override
  String get supporterRetryButton => '再試行';

  @override
  String get supporterProductsUnavailable => '現在利用できる応援プランがありません。';

  @override
  String get supporterRestoreNoticeTitle => '購入の復元について';

  @override
  String get supporterRestoreNoticeBody =>
      '購入の復元は同じ Apple ID または Google アカウントで利用できます。iOS と Android の間で応援状態は共有されません。';

  @override
  String get supporterSummaryTitle => '応援サマリー';

  @override
  String supporterSummarySinceChip(String date) {
    return '$dateから応援中';
  }

  @override
  String supporterSummaryStreakChip(String duration) {
    return '継続 $duration';
  }

  @override
  String supporterSummaryOneTimeCount(int count) {
    return '単発 ×$count';
  }

  @override
  String supporterSummarySnackCount(int count) {
    return 'おやつ ×$count';
  }

  @override
  String supporterSummaryCoffeeCount(int count) {
    return 'ドリンク ×$count';
  }

  @override
  String supporterSummaryLunchCount(int count) {
    return 'ランチ ×$count';
  }

  @override
  String get supporterSummaryLessThanMonth => '1か月未満';

  @override
  String supporterSummaryDurationMonths(int count) {
    return '$countか月';
  }

  @override
  String get supporterSummarySinceLabel => '応援開始';

  @override
  String get supporterSummaryStreakLabel => '継続';

  @override
  String get supporterSummaryOngoingLabel => '継続中';

  @override
  String get supporterSummarySupportPeriodLabel => '応援期間';

  @override
  String get supporterImpactTitle => '応援でできること';

  @override
  String get supporterImpactBody =>
      'CC Pocket が気に入ったら、継続開発を応援してもらえるとうれしいです。アプリはこれからも無料の OSS として続けていきます。';

  @override
  String get supporterImpactAiTitle => '開発と運用のコスト';

  @override
  String get supporterImpactAiBody => 'AI 利用料、実機確認、テスト、配布まわりなどの継続コストを支えます。';

  @override
  String get supporterImpactDevicesTitle => '端末とテスト';

  @override
  String get supporterImpactDevicesBody =>
      '実機確認や OS アップデート追従など、安定運用に必要なコストを支えます。';

  @override
  String get supporterImpactMotivationTitle => '継続するモチベーション';

  @override
  String get supporterImpactMotivationBody =>
      '使ってくれている実感が、新機能や改善を続けるいちばんの後押しになります。';

  @override
  String get supporterPackagesTitle => '応援の方法';

  @override
  String get supporterSubscriptionGroupTitle => '毎月応援';

  @override
  String get supporterSubscriptionGroupBody => '継続的に応援してもらえるとうれしいです。';

  @override
  String get supporterOneTimeGroupTitle => '単発で応援';

  @override
  String get supporterOneTimeGroupBody =>
      'ランチやドリンクをおごる気持ちになったら、応援してもらえるとうれしいです。';

  @override
  String get supporterPurchaseInfoTitle => '購入について';

  @override
  String get supporterPurchaseInfoBody =>
      '購入の復元は同じ Apple ID または Google アカウントで利用できます。iOS と Android の間で応援状態は共有されません。';

  @override
  String get supporterPurchaseInfoLink => '詳しくはこちら';

  @override
  String get supporterPrivacyPolicyLink => 'プライバシーポリシー';

  @override
  String get supporterTermsOfUseLink => '利用規約（Apple標準EULA）';

  @override
  String get supporterLearnMoreTitle => '購入と応援について';

  @override
  String get supporterLearnMoreBody => '無料で提供し続ける考え方や、購入の復元の仕組みを確認できます。';

  @override
  String get supporterOpenLinkFailed => '案内ページを開けませんでした。';

  @override
  String get supporterPurchaseSuccess => 'CC Pocket を応援してくれてありがとうございます。';

  @override
  String get supporterPurchaseCancelled => '購入をキャンセルしました。';

  @override
  String supporterPurchaseFailed(String message) {
    return '購入に失敗しました: $message';
  }

  @override
  String get supporterRestoreSuccess => '購入情報を復元しました。';

  @override
  String supporterRestoreFailed(String message) {
    return '復元に失敗しました: $message';
  }

  @override
  String get gitDiscardAllChangesTitle => 'すべての変更を破棄しますか';

  @override
  String get gitDiscardVisibleUnstagedChangesMessage => '表示中の未ステージ変更をすべて破棄します。';

  @override
  String get gitDiscardChangeTitle => 'この変更を破棄しますか';

  @override
  String get gitDiscardFileUnstagedChangesMessage => 'このファイルの未ステージ変更をすべて破棄します。';

  @override
  String get gitDiscardHunkUnstagedChangesMessage => 'このハンクの未ステージ変更を破棄します。';

  @override
  String get googleSearchSelectionAction => 'Google で検索';

  @override
  String get approvalQuestionNotificationTitle => '質問があります - ccpocket';

  @override
  String get approvalRequiredNotificationTitle => '承認待ち - ccpocket';

  @override
  String get exitPlanModeNotificationBody => '作成したプランの確認が必要です';

  @override
  String get renderErrorFallback => 'このコンテンツを表示できませんでした';

  @override
  String get artifactFile => 'ファイル';

  @override
  String get artifactSource => 'ソース';

  @override
  String artifactLineLabel(int line) {
    return '$line 行目';
  }

  @override
  String get artifactOpenFailed => 'ファイルを開けませんでした。';

  @override
  String get artifactUnavailable => 'このファイルは利用できなくなりました。';

  @override
  String get artifactReconnect => 'Bridge に再接続して、もう一度お試しください。';

  @override
  String get artifactBridgeUpdateRequired => 'パソコン側の Bridge を更新してから、再接続してください。';

  @override
  String get artifactTimeout => 'ファイルの準備がタイムアウトしました。';

  @override
  String get artifactPrepareFailed => 'ファイルを準備できませんでした。';

  @override
  String get goalTitle => 'Goal';

  @override
  String get goalStart => 'Goalを開始';

  @override
  String get goalManage => 'Goalを管理';

  @override
  String get goalUnavailable => 'このCodexでは利用できません';

  @override
  String get goalUnavailableBody =>
      'このCodexランタイムはGoal操作に対応していません。Codexを更新するか、互換性のあるBridgeへ再接続してください。';

  @override
  String get goalLoading => 'Goalを読み込み中…';

  @override
  String get goalNoActiveTitle => '進行中のGoalはありません';

  @override
  String get goalNoActiveBody => 'Goalを開始すると、Codexが通常のターンを重ねながら継続して作業します。';

  @override
  String get goalManagementTitle => 'Goal管理';

  @override
  String get goalRefreshTooltip => 'Goalを更新';

  @override
  String get goalEditTooltip => 'Goalを編集';

  @override
  String get goalPauseTooltip => 'Goalを一時停止';

  @override
  String get goalResumeTooltip => 'Goalを再開';

  @override
  String get goalUpdateBudgetResume => '予算を変更して再開';

  @override
  String get goalClearTooltip => 'Goalを削除';

  @override
  String get goalStatusActive => '進行中';

  @override
  String get goalStatusPaused => '一時停止中';

  @override
  String get goalStatusBlocked => 'ブロック中';

  @override
  String get goalStatusUsageLimited => '利用上限';

  @override
  String get goalStatusBudgetLimited => '予算上限';

  @override
  String get goalStatusComplete => '完了';

  @override
  String get goalStatusUnknown => '不明';

  @override
  String get goalUpdating => 'Goalを更新中…';

  @override
  String get goalMutationStarting => 'Goalを開始中…';

  @override
  String get goalMutationSaving => 'Goalを保存中…';

  @override
  String get goalMutationPausing => '現在のステップ後に一時停止します…';

  @override
  String get goalMutationResuming => 'Goalを再開中…';

  @override
  String get goalMutationBudget => 'Goalの予算を更新中…';

  @override
  String get goalMutationClearing => 'Goalを削除中…';

  @override
  String get goalTokensUnit => 'トークン';

  @override
  String get goalBlockedExplanation =>
      'ブロックが繰り返されたためGoalモードが停止しました。必要な情報を追加するか目標を変更してから再開してください。';

  @override
  String get goalUsageLimitedExplanation =>
      '現在のアカウントが利用上限に達したためGoalモードが一時停止しました。';

  @override
  String get goalBudgetLimitedExplanation =>
      'Goalのtoken予算を使い切りました。予算を増やすか解除してから再開してください。';

  @override
  String get goalCompleteExplanation =>
      'CodexがこのGoalを完了と判断しました。別のGoalを始める前に削除してください。';

  @override
  String get goalUnknownExplanation =>
      'この状態は新しいCodexバージョンから届いています。推測せずそのまま表示します。';

  @override
  String get goalStartTitle => 'Goalを開始';

  @override
  String get goalEditTitle => 'Goalを編集';

  @override
  String get goalObjectiveLabel => '目標';

  @override
  String get goalObjectiveHint => '成果、制約、完了を確認する方法を入力してください。';

  @override
  String get goalObjectiveRequired => 'Goalの目標を入力してください。';

  @override
  String get goalTokenBudgetTitle => 'Token予算';

  @override
  String get goalTokenBudgetDescription => '任意。予算を使い切るとGoalモードは自動的に一時停止します。';

  @override
  String get goalMaximumTokens => '最大token数';

  @override
  String get goalTokensAlreadyUsedSuffix => 'tokens 使用済み';

  @override
  String get goalTokenBudgetPositive => '0より大きいtoken予算を入力してください。';

  @override
  String get goalTokenBudgetAboveUsed => '予算は使用済みtoken数より大きくしてください。';

  @override
  String get goalBudgetResumeDescription =>
      '予算上限に達したGoalを再開するには、予算を増やすか解除する必要があります。両方の変更は同時に適用されます。';

  @override
  String get goalBudgetBridgeUpdate => 'Goalのtoken予算を変更する前にBridgeを更新してください。';

  @override
  String get goalBudgetBridgeUpdateExisting =>
      'このGoalにはtoken予算があります。変更するにはBridgeを更新してください。';

  @override
  String get goalResumeAction => '再開';

  @override
  String get goalClearTitle => 'Goalを削除しますか？';

  @override
  String get goalClearBody =>
      'Codexは新しいGoalステップを開始しなくなります。実行中のステップは完了する場合があります。';

  @override
  String get goalClearAction => '削除';

  @override
  String get goalChangedElsewhere =>
      'このGoalは別のクライアントで変更されました。下書きは保持されています。キャンセルして最新のGoalを確認し、編集画面を開き直してください。';

  @override
  String get goalReconnectToManage => 'このGoalを管理するには、再接続して更新してください。';

  @override
  String get goalMutationTimeout => 'Goalの変更がタイムアウトしました。現在の状態を更新しています。';

  @override
  String get goalObjectiveTooLong => 'Goalの目標は4,000文字以内で入力してください。';

  @override
  String get goalLoadFailedTitle => 'Goalを読み込めませんでした';

  @override
  String get goalLoadFailedBody =>
      'Bridgeから確定したGoal状態が返されませんでした。既存のGoalは変更されていません。再接続するか再試行してください。';

  @override
  String get goalUpdateFailed => 'Goalの変更を保存できませんでした。下書きは保持されています。';

  @override
  String get goalClearFailed => 'Goalをクリアできませんでした。更新してから再試行してください。';

  @override
  String get sessionCompleteTitle => 'セッション完了';

  @override
  String get sessionDone => 'セッションが終了しました';

  @override
  String get statusStarting => '起動中';

  @override
  String get statusIdle => '待機中';

  @override
  String get statusRunning => '実行中';

  @override
  String get statusApproval => '承認待ち';

  @override
  String get statusCompacting => 'コンテキストを整理中';

  @override
  String get statusPlan => 'プラン';

  @override
  String get statusWorking => '作業中';

  @override
  String get statusNeedsYou => '対応が必要';

  @override
  String get statusUnavailable => '状態を確認できません';

  @override
  String get sessionStatusReviewPlan => 'プランを確認';

  @override
  String get sessionStatusApproveToolCall => 'ツール実行を承認';

  @override
  String get sessionStatusAnswerQuestion => '質問に回答';

  @override
  String get sessionStatusAnswerMcpRequest => 'MCPリクエストに回答';

  @override
  String get sessionStatusGrantPermissions => '権限を許可';

  @override
  String sessionStatusApproveTool(String toolName) {
    return '$toolName を承認';
  }

  @override
  String get sessionStatusCleaningContext => 'コンテキストを整理中';

  @override
  String get unread => '未読';

  @override
  String get runningOnDesktop => 'デスクトップで実行中';

  @override
  String get exploreRecentFiles => '最近のファイル';

  @override
  String get exploreLoadFailed => 'ファイルを読み込めませんでした';

  @override
  String get exploreBridgeDisconnected => 'Bridgeとの接続が切れたため、ファイルを読み込めません';

  @override
  String get exploreRequestTimedOut => 'ファイル一覧の取得がタイムアウトしました。Bridge接続を確認してください';

  @override
  String get explorePathNotAllowed => 'この場所は現在の読み取り権限の範囲外です';

  @override
  String exploreShowingFirstEntries(int visibleCount) {
    return '先頭の$visibleCount件を表示中';
  }

  @override
  String exploreShowingEntries(int visibleCount, int totalFiles) {
    return '$totalFiles件中$visibleCount件を表示中';
  }

  @override
  String get exploreRecentOpenFiles => '最近開いたファイル';

  @override
  String get exploreNoRecentOpenFiles => '最近開いたファイルはありません';

  @override
  String get exploreNoFiles => '参照できるファイルがありません';

  @override
  String get exploreNoVisibleFiles =>
      '表示可能なファイルが見つかりませんでした。生成フォルダやキャッシュフォルダは非表示の場合があります';

  @override
  String get close => '閉じる';

  @override
  String get gitUnstaged => '未ステージ';

  @override
  String get gitStaged => 'ステージ済み';

  @override
  String get gitStage => 'ステージ';

  @override
  String get gitUnstage => 'ステージ解除';

  @override
  String get gitRevert => '元に戻す';

  @override
  String get gitViewFile => 'ファイルを表示';

  @override
  String get gitOpenFullCurrentFile => '現在のファイル全体を開く';

  @override
  String get gitDiscardAllChangesInFile => 'このファイルの変更をすべて破棄';

  @override
  String get gitDiscardChangesInHunk => 'このハンクの変更を破棄';

  @override
  String get gitRequestChange => '変更を依頼';

  @override
  String get gitSendFileBackToAi => 'フィードバック付きでこのファイルをAIに送る';

  @override
  String get gitSendHunkBackToAi => 'フィードバック付きでこのハンクをAIに送る';

  @override
  String get gitFiles => 'ファイル';

  @override
  String get gitRevertAll => 'すべて元に戻す';

  @override
  String get gitStageAll => 'すべてステージ';

  @override
  String get gitUnstageAll => 'すべてステージ解除';

  @override
  String get gitCommit => 'コミット';

  @override
  String get gitCommitAndPush => 'コミットしてプッシュ';

  @override
  String gitCommittedHash(String hash) {
    return 'コミット済み: $hash';
  }

  @override
  String get gitSuccess => '完了';

  @override
  String get gitUnknownError => '不明なエラー';

  @override
  String get gitAutoGenerateWithAi => 'AIで自動生成';

  @override
  String get gitCommitMessage => 'コミットメッセージ';

  @override
  String get gitAutoGenerateMessage => 'コミットメッセージを自動生成';

  @override
  String get gitCommitting => 'コミット中...';

  @override
  String get gitPushing => 'プッシュ中...';

  @override
  String get gitBranches => 'ブランチ';

  @override
  String get gitNewBranch => '新しいブランチ';

  @override
  String get gitSearchBranches => 'ブランチを検索...';

  @override
  String get gitBranchInUseByWorktree => '別のワークツリーで使用中';

  @override
  String get gitBranchNameHint => 'ブランチ名（例: feat/login）';

  @override
  String get gitCreateAndCheckout => '作成してチェックアウト';

  @override
  String get gitNoUpstream => 'アップストリームなし';

  @override
  String get gitImageTooLarge => '画像が大きすぎてプレビューできません';

  @override
  String get gitImagePreviewUnavailable => '画像プレビューを利用できません';

  @override
  String get gitTapToLoadPreview => 'タップしてプレビューを読み込む';

  @override
  String get gitFocusDiff => 'diff集中表示';

  @override
  String get gitExitFocusMode => '集中モードを終了';

  @override
  String get gitNoStagedFiles => 'ステージ済みファイルはありません';

  @override
  String gitPullCommits(int count) {
    return '$count件のコミットをプル';
  }

  @override
  String get gitPullUnavailable => 'プルできません';

  @override
  String gitPushCommits(int count) {
    return '$count件のコミットをプッシュ';
  }

  @override
  String get gitPushUnavailable => 'プッシュできません';

  @override
  String get licenseSearchHint => 'パッケージを検索…';

  @override
  String get licenseNoPackagesFound => 'パッケージが見つかりません';

  @override
  String licenseEntryCount(Object count) {
    return 'ライセンス項目：$count';
  }

  @override
  String get bridgeMachine => 'Bridge マシン';

  @override
  String get bridgeNotConnected => '未接続';

  @override
  String get enabledAgentsBoth => '両方';

  @override
  String get speed => '速度';

  @override
  String readOnlyValue(Object value) {
    return '$value（読み取り専用）';
  }

  @override
  String get speedFastDescription => '1.5倍速、使用量が増えます';

  @override
  String get speedDefaultDescription => '標準速度';

  @override
  String get speedStandard => '標準';

  @override
  String get speedFast => '高速';

  @override
  String get speedCustom => 'カスタム';

  @override
  String get speedCustomReadOnly => 'カスタムサービス階層（読み取り専用）';

  @override
  String get speedFastOn => '高速モードはオンです';

  @override
  String get speedFastOff => '高速モードはオフです';

  @override
  String currentServiceTierReadOnly(Object value) {
    return '現在のサービス階層：$value（読み取り専用）';
  }

  @override
  String get codexSettingsUnknown => '不明 · 同期を待機中';

  @override
  String get codexSettingsWaitingForRuntime =>
      'Bridge がこの会話のランタイム設定を同期するのを待っています。設定は変更されていません。';

  @override
  String get codexSettingsReadOnlyDesktop =>
      'このターンは Codex Desktop が所有しています。ここでは設定は読み取り専用です。Desktop で変更するか、ターンの終了を待ってください。';

  @override
  String get codexSettingsUnavailable =>
      'Bridge がこの会話の設定書き込み権限を確認していないため、CC Pocket は変更を送信またはプレビューしません。';

  @override
  String get codexPermissionsOnRequest => '必要時に確認';

  @override
  String get codexPermissionsFullAccess => 'フルアクセス';

  @override
  String get codexPermissionsCustom => 'カスタム（config.toml）';

  @override
  String get codexPermissionsCustomShort => 'カスタム';

  @override
  String get codexPermissionsFromConfig => 'Codex は config.toml の権限設定を使用します';

  @override
  String get codexPermissionsFromProfile => 'Codex は選択したプロファイルの権限設定を使用します';

  @override
  String get permissionDefaultMode => 'デフォルト';

  @override
  String get permissionAutoMode => '自動';

  @override
  String get permissionChipAcceptEdits => '編集';

  @override
  String get permissionPlanMode => 'プラン';

  @override
  String get permissionChipBypass => 'バイパス';

  @override
  String get executionFullShort => 'フル';

  @override
  String get sandboxSafeMode => 'サンドボックス（安全モード）';

  @override
  String get sandboxStandard => '標準';

  @override
  String get sandboxOnLabel => 'サンドボックス有効';

  @override
  String get sandboxOffLabel => 'サンドボックス無効';

  @override
  String get sandboxOffShort => 'サンドボックスなし';

  @override
  String get effortUltraDescription => '使用量を増やし、タスクを自動委任します';

  @override
  String get scrollToBottom => '一番下へスクロール';

  @override
  String get switchSession => 'セッションを切り替え';

  @override
  String get terminalAppNameHint => 'マイターミナル';

  @override
  String historyToolDetailsPending(int count) {
    return '以前のツール詳細 $count 件はまだ読み込まれていません';
  }

  @override
  String get loadOnDemand => '読み込む';

  @override
  String get viewFullDiff => '差分全体を表示';

  @override
  String get turnHistoryLoadFailed => 'ターン履歴を読み込めませんでした';

  @override
  String get turnLoadFailed => 'このターンを読み込めませんでした。もう一度お試しください。';

  @override
  String get turnHistoryTitle => 'ターン履歴';

  @override
  String turnCount(int count) {
    return '$count ターン';
  }

  @override
  String get noTurnsYet => 'ターンはまだありません';

  @override
  String get turnHistoryHint => 'メッセージを送信すると、各ターンの先頭がここに表示されます';

  @override
  String get locatingTurn => 'このターンを読み込んで移動しています…';

  @override
  String fullHistoryUnavailable(int count) {
    return '完全な履歴インデックスを利用できません。読み込み済みの $count ターンを表示しています。';
  }

  @override
  String fullHistoryLoading(int count) {
    return '完全な履歴インデックスを読み込み中です。先に $count ターンを表示しています。';
  }

  @override
  String fullHistoryNotReady(int count) {
    return '読み込み済みの $count ターンを表示しています。完全な履歴インデックスはまだ準備中です。';
  }

  @override
  String get downloading => 'ダウンロード中…';

  @override
  String get downloadAndKeepResident => 'すべてダウンロードして保持';

  @override
  String get loadingOlderToolDetails => '以前のツール詳細を読み込んでいます…';

  @override
  String get loadToolDetailsFailed => '詳細を読み込めませんでした。再試行';

  @override
  String loadNextToolDetails(int count) {
    return '次の $count 件のツール詳細を読み込む';
  }

  @override
  String get codexApprovalUntrustedLabel => '信頼済みのみ';

  @override
  String get codexApprovalNeverAskLabel => '確認なし';

  @override
  String get planOnShort => 'プラン有効';

  @override
  String get planOffShort => 'プラン無効';

  @override
  String get statusPlanning => '計画中';

  @override
  String systemMessageLabel(String subtype) {
    return 'システム：$subtype';
  }
}
