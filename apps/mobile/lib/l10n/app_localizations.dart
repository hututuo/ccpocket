import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_ko.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ja'),
    Locale('en'),
    Locale('ko'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In ja, this message translates to:
  /// **'CC Pocket'**
  String get appTitle;

  /// No description provided for @cancel.
  ///
  /// In ja, this message translates to:
  /// **'キャンセル'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In ja, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @delete.
  ///
  /// In ja, this message translates to:
  /// **'削除'**
  String get delete;

  /// No description provided for @remove.
  ///
  /// In ja, this message translates to:
  /// **'削除'**
  String get remove;

  /// No description provided for @open.
  ///
  /// In ja, this message translates to:
  /// **'開く'**
  String get open;

  /// No description provided for @submit.
  ///
  /// In ja, this message translates to:
  /// **'送信'**
  String get submit;

  /// No description provided for @confirmWithCount.
  ///
  /// In ja, this message translates to:
  /// **'確認（{count}件）'**
  String confirmWithCount(int count);

  /// No description provided for @reviewYourAnswers.
  ///
  /// In ja, this message translates to:
  /// **'回答を確認'**
  String get reviewYourAnswers;

  /// No description provided for @groupedSessions.
  ///
  /// In ja, this message translates to:
  /// **'プロジェクト別'**
  String get groupedSessions;

  /// No description provided for @sessionListView.
  ///
  /// In ja, this message translates to:
  /// **'最近のチャット'**
  String get sessionListView;

  /// No description provided for @tooltipToggleRecentGrouping.
  ///
  /// In ja, this message translates to:
  /// **'セッション一覧の表示を切り替え'**
  String get tooltipToggleRecentGrouping;

  /// No description provided for @loadMore.
  ///
  /// In ja, this message translates to:
  /// **'さらに読み込む'**
  String get loadMore;

  /// No description provided for @worktreesTitle.
  ///
  /// In ja, this message translates to:
  /// **'Worktree'**
  String get worktreesTitle;

  /// No description provided for @removeWorktreeTitle.
  ///
  /// In ja, this message translates to:
  /// **'Worktreeを削除'**
  String get removeWorktreeTitle;

  /// No description provided for @removeWorktreeConfirm.
  ///
  /// In ja, this message translates to:
  /// **'ブランチ「{branch}」のWorktreeを削除しますか？\nパス: {path}'**
  String removeWorktreeConfirm(String branch, String path);

  /// No description provided for @noWorktreesFound.
  ///
  /// In ja, this message translates to:
  /// **'Worktreeが見つかりません'**
  String get noWorktreesFound;

  /// No description provided for @mainRepository.
  ///
  /// In ja, this message translates to:
  /// **'メインリポジトリ'**
  String get mainRepository;

  /// No description provided for @sessionShortTitle.
  ///
  /// In ja, this message translates to:
  /// **'セッション {id}'**
  String sessionShortTitle(String id);

  /// No description provided for @debugBundlePromptCopied.
  ///
  /// In ja, this message translates to:
  /// **'Agent用プロンプトをコピーしました。AIチャットに貼り付けてください。'**
  String get debugBundlePromptCopied;

  /// No description provided for @debugBundleBuildFailed.
  ///
  /// In ja, this message translates to:
  /// **'デバッグバンドルを作成できませんでした'**
  String get debugBundleBuildFailed;

  /// No description provided for @copyCodexCliJoinCommand.
  ///
  /// In ja, this message translates to:
  /// **'Codex CLI参加コマンドをコピー'**
  String get copyCodexCliJoinCommand;

  /// No description provided for @codexCliJoinCommandCopied.
  ///
  /// In ja, this message translates to:
  /// **'Codex CLI参加コマンドをコピーしました'**
  String get codexCliJoinCommandCopied;

  /// No description provided for @sessionStarted.
  ///
  /// In ja, this message translates to:
  /// **'セッションを開始しました'**
  String get sessionStarted;

  /// No description provided for @reviewSummary.
  ///
  /// In ja, this message translates to:
  /// **'回答の確認'**
  String get reviewSummary;

  /// No description provided for @stepOfTotal.
  ///
  /// In ja, this message translates to:
  /// **'{total}件中{current}件目'**
  String stepOfTotal(int current, int total);

  /// No description provided for @sessionCost.
  ///
  /// In ja, this message translates to:
  /// **'セッション費用'**
  String get sessionCost;

  /// No description provided for @sessionContextUsage.
  ///
  /// In ja, this message translates to:
  /// **'{count}件のメッセージ（コンテキスト約{percent}%）'**
  String sessionContextUsage(int count, int percent);

  /// No description provided for @screenshotDeleted.
  ///
  /// In ja, this message translates to:
  /// **'スクリーンショットを削除しました'**
  String get screenshotDeleted;

  /// No description provided for @monthsAgo.
  ///
  /// In ja, this message translates to:
  /// **'{months}か月前'**
  String monthsAgo(int months);

  /// No description provided for @addToConversation.
  ///
  /// In ja, this message translates to:
  /// **'会話に追加'**
  String get addToConversation;

  /// No description provided for @removeProjectTitle.
  ///
  /// In ja, this message translates to:
  /// **'プロジェクトを削除'**
  String get removeProjectTitle;

  /// No description provided for @removeProjectConfirm.
  ///
  /// In ja, this message translates to:
  /// **'「{name}」を最近のプロジェクトから削除しますか？'**
  String removeProjectConfirm(Object name);

  /// No description provided for @rename.
  ///
  /// In ja, this message translates to:
  /// **'名前を変更'**
  String get rename;

  /// No description provided for @renameSession.
  ///
  /// In ja, this message translates to:
  /// **'セッション名を変更'**
  String get renameSession;

  /// No description provided for @renameFailed.
  ///
  /// In ja, this message translates to:
  /// **'この会話の名前を変更できません'**
  String get renameFailed;

  /// No description provided for @renameFailedWithError.
  ///
  /// In ja, this message translates to:
  /// **'この会話の名前を変更できません：{error}'**
  String renameFailedWithError(String error);

  /// No description provided for @pin.
  ///
  /// In ja, this message translates to:
  /// **'セッションをピン留め'**
  String get pin;

  /// No description provided for @unpin.
  ///
  /// In ja, this message translates to:
  /// **'セッションのピン留めを解除'**
  String get unpin;

  /// No description provided for @pinProject.
  ///
  /// In ja, this message translates to:
  /// **'プロジェクトをピン留め'**
  String get pinProject;

  /// No description provided for @unpinProject.
  ///
  /// In ja, this message translates to:
  /// **'プロジェクトのピン留めを解除'**
  String get unpinProject;

  /// No description provided for @sessionNameHint.
  ///
  /// In ja, this message translates to:
  /// **'セッション名'**
  String get sessionNameHint;

  /// No description provided for @clearName.
  ///
  /// In ja, this message translates to:
  /// **'名前をクリア'**
  String get clearName;

  /// No description provided for @connect.
  ///
  /// In ja, this message translates to:
  /// **'接続'**
  String get connect;

  /// No description provided for @toolSuggestionTitle.
  ///
  /// In ja, this message translates to:
  /// **'Codex に {toolName} を追加しますか？'**
  String toolSuggestionTitle(Object toolName);

  /// No description provided for @toolSuggestionInstall.
  ///
  /// In ja, this message translates to:
  /// **'{toolName} をインストール'**
  String toolSuggestionInstall(Object toolName);

  /// No description provided for @toolSuggestionInstalling.
  ///
  /// In ja, this message translates to:
  /// **'インストール中…'**
  String get toolSuggestionInstalling;

  /// No description provided for @toolSuggestionNotNow.
  ///
  /// In ja, this message translates to:
  /// **'今回はしない'**
  String get toolSuggestionNotNow;

  /// No description provided for @toolSuggestionAuthDescription.
  ///
  /// In ja, this message translates to:
  /// **'必要なアプリを接続し、完了したら確認してください。'**
  String get toolSuggestionAuthDescription;

  /// No description provided for @toolSuggestionConnect.
  ///
  /// In ja, this message translates to:
  /// **'{appName} を接続'**
  String toolSuggestionConnect(Object appName);

  /// No description provided for @toolSuggestionComplete.
  ///
  /// In ja, this message translates to:
  /// **'接続が完了しました'**
  String get toolSuggestionComplete;

  /// No description provided for @toolSuggestionFailed.
  ///
  /// In ja, this message translates to:
  /// **'インストールに失敗しました'**
  String get toolSuggestionFailed;

  /// No description provided for @toolSuggestionOpenFailed.
  ///
  /// In ja, this message translates to:
  /// **'接続ページを開けませんでした。'**
  String get toolSuggestionOpenFailed;

  /// No description provided for @copy.
  ///
  /// In ja, this message translates to:
  /// **'コピー'**
  String get copy;

  /// No description provided for @markdownLinkOpenFailed.
  ///
  /// In ja, this message translates to:
  /// **'リンクを開けませんでした。'**
  String get markdownLinkOpenFailed;

  /// No description provided for @markdownLinkUnsupported.
  ///
  /// In ja, this message translates to:
  /// **'この種類のリンクには対応していません。'**
  String get markdownLinkUnsupported;

  /// No description provided for @markdownFileUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'このファイルはここではプレビューできません。'**
  String get markdownFileUnavailable;

  /// No description provided for @filePreviewShowSource.
  ///
  /// In ja, this message translates to:
  /// **'ソースを表示'**
  String get filePreviewShowSource;

  /// No description provided for @filePreviewShowPreview.
  ///
  /// In ja, this message translates to:
  /// **'プレビューを表示'**
  String get filePreviewShowPreview;

  /// No description provided for @filePreviewRenderedHtml.
  ///
  /// In ja, this message translates to:
  /// **'HTMLレンダリングプレビュー'**
  String get filePreviewRenderedHtml;

  /// No description provided for @copied.
  ///
  /// In ja, this message translates to:
  /// **'コピーしました'**
  String get copied;

  /// No description provided for @copiedValue.
  ///
  /// In ja, this message translates to:
  /// **'「{value}」をコピーしました'**
  String copiedValue(String value);

  /// No description provided for @copiedUrl.
  ///
  /// In ja, this message translates to:
  /// **'URLをコピーしました'**
  String get copiedUrl;

  /// No description provided for @copiedToClipboard.
  ///
  /// In ja, this message translates to:
  /// **'クリップボードにコピーしました'**
  String get copiedToClipboard;

  /// No description provided for @lineCopied.
  ///
  /// In ja, this message translates to:
  /// **'行をコピーしました'**
  String get lineCopied;

  /// No description provided for @start.
  ///
  /// In ja, this message translates to:
  /// **'開始'**
  String get start;

  /// No description provided for @stop.
  ///
  /// In ja, this message translates to:
  /// **'停止'**
  String get stop;

  /// No description provided for @send.
  ///
  /// In ja, this message translates to:
  /// **'送信'**
  String get send;

  /// No description provided for @settings.
  ///
  /// In ja, this message translates to:
  /// **'設定'**
  String get settings;

  /// No description provided for @gallery.
  ///
  /// In ja, this message translates to:
  /// **'ギャラリー'**
  String get gallery;

  /// No description provided for @git.
  ///
  /// In ja, this message translates to:
  /// **'Git'**
  String get git;

  /// No description provided for @explorer.
  ///
  /// In ja, this message translates to:
  /// **'エクスプローラー'**
  String get explorer;

  /// No description provided for @gitUnavailableTip.
  ///
  /// In ja, this message translates to:
  /// **'Git未検出 — Git機能は利用できません'**
  String get gitUnavailableTip;

  /// No description provided for @gitUnavailableTitle.
  ///
  /// In ja, this message translates to:
  /// **'Gitを利用できません'**
  String get gitUnavailableTitle;

  /// No description provided for @gitUnavailableHint.
  ///
  /// In ja, this message translates to:
  /// **'このプロジェクトではGit機能を利用できません'**
  String get gitUnavailableHint;

  /// No description provided for @errorAuthenticationTitle.
  ///
  /// In ja, this message translates to:
  /// **'認証エラー'**
  String get errorAuthenticationTitle;

  /// No description provided for @errorCodexAuthenticationTitle.
  ///
  /// In ja, this message translates to:
  /// **'Codex 認証エラー'**
  String get errorCodexAuthenticationTitle;

  /// No description provided for @errorCodexCliNotInstalledTitle.
  ///
  /// In ja, this message translates to:
  /// **'Codex CLI がインストールされていません'**
  String get errorCodexCliNotInstalledTitle;

  /// No description provided for @errorPathNotAllowedTitle.
  ///
  /// In ja, this message translates to:
  /// **'パスは許可されていません'**
  String get errorPathNotAllowedTitle;

  /// No description provided for @errorBridgeUpdateRequiredTitle.
  ///
  /// In ja, this message translates to:
  /// **'Bridge の更新が必要です'**
  String get errorBridgeUpdateRequiredTitle;

  /// No description provided for @errorAutoModeUnavailableTitle.
  ///
  /// In ja, this message translates to:
  /// **'Auto モードは利用できません'**
  String get errorAutoModeUnavailableTitle;

  /// No description provided for @errorCodexWarningTitle.
  ///
  /// In ja, this message translates to:
  /// **'Codex の警告'**
  String get errorCodexWarningTitle;

  /// No description provided for @errorCodexRuntimeWriterUnavailableTitle.
  ///
  /// In ja, this message translates to:
  /// **'会話の制御状態を同期しています'**
  String get errorCodexRuntimeWriterUnavailableTitle;

  /// No description provided for @errorCodexActionBrokerRequiredTitle.
  ///
  /// In ja, this message translates to:
  /// **'現在の承認リクエストを使用してください'**
  String get errorCodexActionBrokerRequiredTitle;

  /// No description provided for @errorClaudeAuthLoginHint.
  ///
  /// In ja, this message translates to:
  /// **'Bridge マシンで「claude auth login」を実行してください'**
  String get errorClaudeAuthLoginHint;

  /// No description provided for @errorAnthropicApiKeyHint.
  ///
  /// In ja, this message translates to:
  /// **'Bridge マシンで ANTHROPIC_API_KEY を設定してください'**
  String get errorAnthropicApiKeyHint;

  /// No description provided for @errorOpenAiApiKeyHint.
  ///
  /// In ja, this message translates to:
  /// **'Bridge マシンの OPENAI_API_KEY を確認してください'**
  String get errorOpenAiApiKeyHint;

  /// No description provided for @errorCodexCliInstallHint.
  ///
  /// In ja, this message translates to:
  /// **'Bridge マシンに Codex CLI をインストールしてから Bridge を再起動してください'**
  String get errorCodexCliInstallHint;

  /// No description provided for @errorPathAllowedDirsHint.
  ///
  /// In ja, this message translates to:
  /// **'Bridge サーバーの BRIDGE_ALLOWED_DIRS を更新してください'**
  String get errorPathAllowedDirsHint;

  /// No description provided for @errorAutoModeUnavailableHint.
  ///
  /// In ja, this message translates to:
  /// **'ここでは Default モードを使用するか、Auto モード対応の Claude 環境に切り替えてください'**
  String get errorAutoModeUnavailableHint;

  /// No description provided for @errorCodexRuntimeWriterUnavailableHint.
  ///
  /// In ja, this message translates to:
  /// **'アクティブな Bridge に再接続し、この会話の制御状態が同期されてから再試行してください。'**
  String get errorCodexRuntimeWriterUnavailableHint;

  /// No description provided for @errorCodexActionBrokerRequiredHint.
  ///
  /// In ja, this message translates to:
  /// **'現在の承認カードから応答してください。カードが表示されない場合は会話を更新してください。'**
  String get errorCodexActionBrokerRequiredHint;

  /// No description provided for @conversationRetryWaitingForRuntime.
  ///
  /// In ja, this message translates to:
  /// **'この会話は Bridge と制御状態を同期中です。失敗したメッセージは再送されていません。しばらくしてから再試行してください。'**
  String get conversationRetryWaitingForRuntime;

  /// No description provided for @conversationLatestTurnIncomplete.
  ///
  /// In ja, this message translates to:
  /// **'会話の最新部分を復元できていません。'**
  String get conversationLatestTurnIncomplete;

  /// No description provided for @autoModeFallbackDefaultTip.
  ///
  /// In ja, this message translates to:
  /// **'Auto mode はこの環境で使えないため Default に切り替えました'**
  String get autoModeFallbackDefaultTip;

  /// No description provided for @galleryWithCount.
  ///
  /// In ja, this message translates to:
  /// **'ギャラリー ({count})'**
  String galleryWithCount(int count);

  /// No description provided for @disconnect.
  ///
  /// In ja, this message translates to:
  /// **'切断'**
  String get disconnect;

  /// No description provided for @back.
  ///
  /// In ja, this message translates to:
  /// **'戻る'**
  String get back;

  /// No description provided for @next.
  ///
  /// In ja, this message translates to:
  /// **'次へ'**
  String get next;

  /// No description provided for @done.
  ///
  /// In ja, this message translates to:
  /// **'完了'**
  String get done;

  /// No description provided for @skip.
  ///
  /// In ja, this message translates to:
  /// **'スキップ'**
  String get skip;

  /// No description provided for @edit.
  ///
  /// In ja, this message translates to:
  /// **'編集'**
  String get edit;

  /// No description provided for @share.
  ///
  /// In ja, this message translates to:
  /// **'共有'**
  String get share;

  /// No description provided for @all.
  ///
  /// In ja, this message translates to:
  /// **'すべて'**
  String get all;

  /// No description provided for @none.
  ///
  /// In ja, this message translates to:
  /// **'なし'**
  String get none;

  /// No description provided for @dismissKeyboard.
  ///
  /// In ja, this message translates to:
  /// **'キーボードを閉じる'**
  String get dismissKeyboard;

  /// No description provided for @serverUnreachable.
  ///
  /// In ja, this message translates to:
  /// **'サーバーに接続できません'**
  String get serverUnreachable;

  /// No description provided for @serverUnreachableBody.
  ///
  /// In ja, this message translates to:
  /// **'Bridge サーバーに到達できません:'**
  String get serverUnreachableBody;

  /// No description provided for @setupSteps.
  ///
  /// In ja, this message translates to:
  /// **'セットアップ手順:'**
  String get setupSteps;

  /// No description provided for @setupStep1Title.
  ///
  /// In ja, this message translates to:
  /// **'Bridge Server を起動'**
  String get setupStep1Title;

  /// No description provided for @setupStep1Command.
  ///
  /// In ja, this message translates to:
  /// **'npx --yes @ccpocket/bridge@latest'**
  String get setupStep1Command;

  /// No description provided for @setupStep2Title.
  ///
  /// In ja, this message translates to:
  /// **'常時起動したい場合はサービス登録'**
  String get setupStep2Title;

  /// No description provided for @setupStep2Command.
  ///
  /// In ja, this message translates to:
  /// **'npx --yes @ccpocket/bridge@latest setup'**
  String get setupStep2Command;

  /// No description provided for @setupNetworkHint.
  ///
  /// In ja, this message translates to:
  /// **'両方のデバイスが同じネットワーク上にあることを確認してください（または Tailscale を使用）。'**
  String get setupNetworkHint;

  /// No description provided for @connectAnyway.
  ///
  /// In ja, this message translates to:
  /// **'接続を続行'**
  String get connectAnyway;

  /// No description provided for @stopSession.
  ///
  /// In ja, this message translates to:
  /// **'セッションを停止'**
  String get stopSession;

  /// No description provided for @stopSessionConfirm.
  ///
  /// In ja, this message translates to:
  /// **'このセッションを停止しますか？ Claude プロセスが終了します。'**
  String get stopSessionConfirm;

  /// No description provided for @startNewWithSameSettings.
  ///
  /// In ja, this message translates to:
  /// **'同じ設定で新規開始'**
  String get startNewWithSameSettings;

  /// No description provided for @copyResumeCommand.
  ///
  /// In ja, this message translates to:
  /// **'再開コマンドをコピー'**
  String get copyResumeCommand;

  /// No description provided for @copyResumeCommandSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'mac / Linuxに引き継ぎ'**
  String get copyResumeCommandSubtitle;

  /// No description provided for @resumeCommandCopied.
  ///
  /// In ja, this message translates to:
  /// **'再開コマンドをコピーしました'**
  String get resumeCommandCopied;

  /// No description provided for @editSettingsThenStart.
  ///
  /// In ja, this message translates to:
  /// **'設定を変更して開始'**
  String get editSettingsThenStart;

  /// No description provided for @serverRequiresApiKey.
  ///
  /// In ja, this message translates to:
  /// **'このサーバーには API キーが必要です'**
  String get serverRequiresApiKey;

  /// No description provided for @bridgeServerUpdated.
  ///
  /// In ja, this message translates to:
  /// **'Bridge Server を更新しました'**
  String get bridgeServerUpdated;

  /// No description provided for @bridgeUpdateStarted.
  ///
  /// In ja, this message translates to:
  /// **'Bridge を更新しています。接続を閉じてマシン一覧に戻ります。'**
  String get bridgeUpdateStarted;

  /// No description provided for @bridgeUpdateReconnectHint.
  ///
  /// In ja, this message translates to:
  /// **'Bridge Server を更新しました。マシン一覧から再接続してください。'**
  String get bridgeUpdateReconnectHint;

  /// No description provided for @failedToUpdateServer.
  ///
  /// In ja, this message translates to:
  /// **'サーバーの更新に失敗しました'**
  String get failedToUpdateServer;

  /// No description provided for @bridgeServerStarted.
  ///
  /// In ja, this message translates to:
  /// **'Bridge Server を起動しました'**
  String get bridgeServerStarted;

  /// No description provided for @failedToStartServer.
  ///
  /// In ja, this message translates to:
  /// **'サーバーの起動に失敗しました'**
  String get failedToStartServer;

  /// No description provided for @bridgeServerStopped.
  ///
  /// In ja, this message translates to:
  /// **'Bridge Server を停止しました'**
  String get bridgeServerStopped;

  /// No description provided for @failedToStopServer.
  ///
  /// In ja, this message translates to:
  /// **'サーバーの停止に失敗しました'**
  String get failedToStopServer;

  /// No description provided for @sshPassword.
  ///
  /// In ja, this message translates to:
  /// **'SSH パスワード'**
  String get sshPassword;

  /// No description provided for @sshPasswordPrompt.
  ///
  /// In ja, this message translates to:
  /// **'{machineName} の SSH パスワードを入力'**
  String sshPasswordPrompt(String machineName);

  /// No description provided for @password.
  ///
  /// In ja, this message translates to:
  /// **'パスワード'**
  String get password;

  /// No description provided for @machineEditAddTitle.
  ///
  /// In ja, this message translates to:
  /// **'マシンを追加'**
  String get machineEditAddTitle;

  /// No description provided for @machineEditEditTitle.
  ///
  /// In ja, this message translates to:
  /// **'マシンを編集'**
  String get machineEditEditTitle;

  /// No description provided for @machineEditDismissKeyboardTooltip.
  ///
  /// In ja, this message translates to:
  /// **'キーボードを閉じる'**
  String get machineEditDismissKeyboardTooltip;

  /// No description provided for @machineEditBasicInfo.
  ///
  /// In ja, this message translates to:
  /// **'基本情報'**
  String get machineEditBasicInfo;

  /// No description provided for @machineEditName.
  ///
  /// In ja, this message translates to:
  /// **'名前'**
  String get machineEditName;

  /// No description provided for @machineEditNameHint.
  ///
  /// In ja, this message translates to:
  /// **'Home Mac'**
  String get machineEditNameHint;

  /// No description provided for @machineEditHostLabel.
  ///
  /// In ja, this message translates to:
  /// **'Host（IP またはホスト名）'**
  String get machineEditHostLabel;

  /// No description provided for @machineEditHostHint.
  ///
  /// In ja, this message translates to:
  /// **'100.64.1.2'**
  String get machineEditHostHint;

  /// No description provided for @machineEditPort.
  ///
  /// In ja, this message translates to:
  /// **'ポート'**
  String get machineEditPort;

  /// No description provided for @machineEditBridgePortHint.
  ///
  /// In ja, this message translates to:
  /// **'8765'**
  String get machineEditBridgePortHint;

  /// No description provided for @machineEditApiKey.
  ///
  /// In ja, this message translates to:
  /// **'API Key'**
  String get machineEditApiKey;

  /// No description provided for @machineEditOptional.
  ///
  /// In ja, this message translates to:
  /// **'任意'**
  String get machineEditOptional;

  /// No description provided for @machineEditUseSecureConnection.
  ///
  /// In ja, this message translates to:
  /// **'セキュア接続を使う'**
  String get machineEditUseSecureConnection;

  /// No description provided for @machineEditUseSecureConnectionSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'WSS で接続し、ヘルスチェックに HTTPS を使います'**
  String get machineEditUseSecureConnectionSubtitle;

  /// No description provided for @machineEditSshConfiguration.
  ///
  /// In ja, this message translates to:
  /// **'SSH 設定'**
  String get machineEditSshConfiguration;

  /// No description provided for @machineEditEnableSshRemoteStartup.
  ///
  /// In ja, this message translates to:
  /// **'SSH リモート起動を有効にする'**
  String get machineEditEnableSshRemoteStartup;

  /// No description provided for @machineEditEnableSshRemoteStartupSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'オフライン時に Bridge Server をリモート起動します'**
  String get machineEditEnableSshRemoteStartupSubtitle;

  /// No description provided for @machineEditSshUsername.
  ///
  /// In ja, this message translates to:
  /// **'SSH ユーザー名'**
  String get machineEditSshUsername;

  /// No description provided for @machineEditSshUsernameHint.
  ///
  /// In ja, this message translates to:
  /// **'myuser'**
  String get machineEditSshUsernameHint;

  /// No description provided for @machineEditSshPort.
  ///
  /// In ja, this message translates to:
  /// **'SSH ポート'**
  String get machineEditSshPort;

  /// No description provided for @machineEditSshPortHint.
  ///
  /// In ja, this message translates to:
  /// **'22'**
  String get machineEditSshPortHint;

  /// No description provided for @machineEditTargetAuthentication.
  ///
  /// In ja, this message translates to:
  /// **'接続先の認証'**
  String get machineEditTargetAuthentication;

  /// No description provided for @machineEditPrivateKey.
  ///
  /// In ja, this message translates to:
  /// **'秘密鍵'**
  String get machineEditPrivateKey;

  /// No description provided for @machineEditSshPrivateKeyPem.
  ///
  /// In ja, this message translates to:
  /// **'SSH 秘密鍵（PEM）'**
  String get machineEditSshPrivateKeyPem;

  /// No description provided for @machineEditOpenSshPrivateKeyHint.
  ///
  /// In ja, this message translates to:
  /// **'-----BEGIN OPENSSH PRIVATE KEY-----'**
  String get machineEditOpenSshPrivateKeyHint;

  /// No description provided for @machineEditSavedPrivateKeyIndicator.
  ///
  /// In ja, this message translates to:
  /// **'Private Key は保存済みです。新しく入力すると置き換えます。'**
  String get machineEditSavedPrivateKeyIndicator;

  /// No description provided for @machineEditUseSshJumpHost.
  ///
  /// In ja, this message translates to:
  /// **'SSH Jump Host を使う'**
  String get machineEditUseSshJumpHost;

  /// No description provided for @machineEditUseSshJumpHostSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'踏み台または中継 SSH ホスト経由で接続します'**
  String get machineEditUseSshJumpHostSubtitle;

  /// No description provided for @machineEditSshJumpHost.
  ///
  /// In ja, this message translates to:
  /// **'SSH 踏み台ホスト'**
  String get machineEditSshJumpHost;

  /// No description provided for @machineEditJumpHost.
  ///
  /// In ja, this message translates to:
  /// **'踏み台ホスト'**
  String get machineEditJumpHost;

  /// No description provided for @machineEditJumpHostHint.
  ///
  /// In ja, this message translates to:
  /// **'bastion.example.com'**
  String get machineEditJumpHostHint;

  /// No description provided for @machineEditJumpPort.
  ///
  /// In ja, this message translates to:
  /// **'踏み台ポート'**
  String get machineEditJumpPort;

  /// No description provided for @machineEditJumpUsername.
  ///
  /// In ja, this message translates to:
  /// **'踏み台ユーザー名'**
  String get machineEditJumpUsername;

  /// No description provided for @machineEditJumpUsernameHint.
  ///
  /// In ja, this message translates to:
  /// **'未入力なら SSH Username を使います'**
  String get machineEditJumpUsernameHint;

  /// No description provided for @machineEditJumpHostAuthentication.
  ///
  /// In ja, this message translates to:
  /// **'Jump Host の認証'**
  String get machineEditJumpHostAuthentication;

  /// No description provided for @machineEditJumpHostAuthenticationSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'未入力なら接続先の SSH 認証情報を再利用します'**
  String get machineEditJumpHostAuthenticationSubtitle;

  /// No description provided for @machineEditJumpPassword.
  ///
  /// In ja, this message translates to:
  /// **'踏み台パスワード'**
  String get machineEditJumpPassword;

  /// No description provided for @machineEditSavedJumpHostPasswordIndicator.
  ///
  /// In ja, this message translates to:
  /// **'Jump Host パスワードは保存済みです。新しく入力すると置き換えます。'**
  String get machineEditSavedJumpHostPasswordIndicator;

  /// No description provided for @machineEditJumpPrivateKeyPem.
  ///
  /// In ja, this message translates to:
  /// **'踏み台秘密鍵（PEM）'**
  String get machineEditJumpPrivateKeyPem;

  /// No description provided for @machineEditSavedJumpHostPrivateKeyIndicator.
  ///
  /// In ja, this message translates to:
  /// **'Jump Host Private Key は保存済みです。新しく入力すると置き換えます。'**
  String get machineEditSavedJumpHostPrivateKeyIndicator;

  /// No description provided for @machineEditTesting.
  ///
  /// In ja, this message translates to:
  /// **'テスト中...'**
  String get machineEditTesting;

  /// No description provided for @machineEditTestConnection.
  ///
  /// In ja, this message translates to:
  /// **'接続をテスト'**
  String get machineEditTestConnection;

  /// No description provided for @machineEditConnectionSuccessful.
  ///
  /// In ja, this message translates to:
  /// **'接続に成功しました'**
  String get machineEditConnectionSuccessful;

  /// No description provided for @machineEditFillSshCredentials.
  ///
  /// In ja, this message translates to:
  /// **'SSH 認証情報を入力してください'**
  String get machineEditFillSshCredentials;

  /// No description provided for @machineEditAddAndConnect.
  ///
  /// In ja, this message translates to:
  /// **'追加して接続'**
  String get machineEditAddAndConnect;

  /// No description provided for @deleteMachine.
  ///
  /// In ja, this message translates to:
  /// **'マシンを削除'**
  String get deleteMachine;

  /// No description provided for @deleteMachineConfirm.
  ///
  /// In ja, this message translates to:
  /// **'\"{displayName}\" を削除しますか？保存された認証情報もすべて削除されます。'**
  String deleteMachineConfirm(String displayName);

  /// No description provided for @connectToBridgeServer.
  ///
  /// In ja, this message translates to:
  /// **'Bridge Server に接続'**
  String get connectToBridgeServer;

  /// No description provided for @connectingToBridge.
  ///
  /// In ja, this message translates to:
  /// **'Bridge に安全に接続しています…'**
  String get connectingToBridge;

  /// No description provided for @loadingSessionStatus.
  ///
  /// In ja, this message translates to:
  /// **'接続しました。セッション状態を読み込んでいます…'**
  String get loadingSessionStatus;

  /// No description provided for @loadingConversationCatalog.
  ///
  /// In ja, this message translates to:
  /// **'セッション状態の準備が完了しました。会話一覧を読み込んでいます…'**
  String get loadingConversationCatalog;

  /// No description provided for @bridgeConnectionTakingLonger.
  ///
  /// In ja, this message translates to:
  /// **'Bridge には接続しましたが、会話一覧の準備に時間がかかっています。このまま待つか、再試行またはキャンセルできます。'**
  String get bridgeConnectionTakingLonger;

  /// No description provided for @authenticatingWithBridge.
  ///
  /// In ja, this message translates to:
  /// **'Bridge で認証しています...'**
  String get authenticatingWithBridge;

  /// No description provided for @preparingCodexRuntime.
  ///
  /// In ja, this message translates to:
  /// **'Bridge はオンラインです。共有 Codex ランタイムを準備しています...'**
  String get preparingCodexRuntime;

  /// No description provided for @codexRuntimeTakingLonger.
  ///
  /// In ja, this message translates to:
  /// **'Bridge プロセスはオンラインですが、共有 Codex ランタイムはまだ準備中です。待機、再試行、またはキャンセルできます。'**
  String get codexRuntimeTakingLonger;

  /// No description provided for @useCachedConversations.
  ///
  /// In ja, this message translates to:
  /// **'キャッシュを使用して開く'**
  String get useCachedConversations;

  /// No description provided for @bridgeConnectionAttemptFailed.
  ///
  /// In ja, this message translates to:
  /// **'Bridge 接続を利用可能な状態にできませんでした。アドレスと認証情報を確認して再試行してください。'**
  String get bridgeConnectionAttemptFailed;

  /// No description provided for @externalBridgeConnectionTitle.
  ///
  /// In ja, this message translates to:
  /// **'この Bridge に接続しますか？'**
  String get externalBridgeConnectionTitle;

  /// No description provided for @externalBridgeConnectionBody.
  ///
  /// In ja, this message translates to:
  /// **'別のアプリまたはリンクから {target} への接続が要求されました。信頼できる Bridge の場合のみ続行してください。'**
  String externalBridgeConnectionBody(String target);

  /// No description provided for @orConnectManually.
  ///
  /// In ja, this message translates to:
  /// **'または手動で接続'**
  String get orConnectManually;

  /// No description provided for @serverUrl.
  ///
  /// In ja, this message translates to:
  /// **'サーバー URL'**
  String get serverUrl;

  /// No description provided for @serverUrlHint.
  ///
  /// In ja, this message translates to:
  /// **'ws://<host-ip>:8765'**
  String get serverUrlHint;

  /// No description provided for @apiKeyOptional.
  ///
  /// In ja, this message translates to:
  /// **'API キー（任意）'**
  String get apiKeyOptional;

  /// No description provided for @apiKeyHint.
  ///
  /// In ja, this message translates to:
  /// **'認証なしの場合は空欄'**
  String get apiKeyHint;

  /// No description provided for @bridgeConnectionKeyLabel.
  ///
  /// In ja, this message translates to:
  /// **'Bridge 接続キー'**
  String get bridgeConnectionKeyLabel;

  /// No description provided for @bridgeConnectionKeyRequiredTitle.
  ///
  /// In ja, this message translates to:
  /// **'Bridge 接続キーが必要です'**
  String get bridgeConnectionKeyRequiredTitle;

  /// No description provided for @bridgeConnectionKeyMissingBody.
  ///
  /// In ja, this message translates to:
  /// **'この Bridge には接続キーが必要です。Mac 側で設定したキーを入力するか、Bridge に表示された QR コードをもう一度スキャンしてください。'**
  String get bridgeConnectionKeyMissingBody;

  /// No description provided for @bridgeConnectionKeyRejectedBody.
  ///
  /// In ja, this message translates to:
  /// **'保存済みの Bridge 接続キーが正しくないか、変更されています。現在のキーを入力するか、Bridge に表示された QR コードをもう一度スキャンしてください。'**
  String get bridgeConnectionKeyRejectedBody;

  /// No description provided for @scanQrCode.
  ///
  /// In ja, this message translates to:
  /// **'QR コードをスキャン'**
  String get scanQrCode;

  /// No description provided for @qrScanInvalid.
  ///
  /// In ja, this message translates to:
  /// **'有効な CC Pocket 接続用 QR コードではありません'**
  String get qrScanInvalid;

  /// No description provided for @qrScanUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'このプラットフォームではカメラで QR コードを読み取れません。Bridge の URL を手動で入力してください。'**
  String get qrScanUnavailable;

  /// No description provided for @qrScanHint.
  ///
  /// In ja, this message translates to:
  /// **'Bridge サーバーに表示された QR コードへ\nカメラを向けてください'**
  String get qrScanHint;

  /// No description provided for @setupGuide.
  ///
  /// In ja, this message translates to:
  /// **'セットアップガイド'**
  String get setupGuide;

  /// No description provided for @showSessions.
  ///
  /// In ja, this message translates to:
  /// **'左ペインを表示'**
  String get showSessions;

  /// No description provided for @hideSessions.
  ///
  /// In ja, this message translates to:
  /// **'左ペインを隠す'**
  String get hideSessions;

  /// No description provided for @workspaceLandingSelectSessionMessage.
  ///
  /// In ja, this message translates to:
  /// **'左ペインでセッションを選択してください。'**
  String get workspaceLandingSelectSessionMessage;

  /// No description provided for @workspaceLandingCreateSessionMessage.
  ///
  /// In ja, this message translates to:
  /// **'左ペインの New からセッションを作成してください。'**
  String get workspaceLandingCreateSessionMessage;

  /// No description provided for @workspaceLandingDisconnectedMessage.
  ///
  /// In ja, this message translates to:
  /// **'Bridge に接続されていません。左ペインから接続するか、セットアップガイドを開いてマシンを設定してください。'**
  String get workspaceLandingDisconnectedMessage;

  /// No description provided for @running.
  ///
  /// In ja, this message translates to:
  /// **'実行中'**
  String get running;

  /// No description provided for @recentSessions.
  ///
  /// In ja, this message translates to:
  /// **'最近のセッション'**
  String get recentSessions;

  /// No description provided for @search.
  ///
  /// In ja, this message translates to:
  /// **'検索'**
  String get search;

  /// No description provided for @searchSessions.
  ///
  /// In ja, this message translates to:
  /// **'セッションを検索...'**
  String get searchSessions;

  /// No description provided for @sessionDisplayModeFirst.
  ///
  /// In ja, this message translates to:
  /// **'先頭'**
  String get sessionDisplayModeFirst;

  /// No description provided for @sessionDisplayModeLast.
  ///
  /// In ja, this message translates to:
  /// **'末尾'**
  String get sessionDisplayModeLast;

  /// No description provided for @sessionDisplayModeSummary.
  ///
  /// In ja, this message translates to:
  /// **'要約'**
  String get sessionDisplayModeSummary;

  /// No description provided for @allAiTools.
  ///
  /// In ja, this message translates to:
  /// **'すべての AI ツール'**
  String get allAiTools;

  /// No description provided for @allProjects.
  ///
  /// In ja, this message translates to:
  /// **'すべてのプロジェクト'**
  String get allProjects;

  /// No description provided for @named.
  ///
  /// In ja, this message translates to:
  /// **'名前付き'**
  String get named;

  /// No description provided for @machines.
  ///
  /// In ja, this message translates to:
  /// **'マシン'**
  String get machines;

  /// No description provided for @refreshStatus.
  ///
  /// In ja, this message translates to:
  /// **'状態を更新'**
  String get refreshStatus;

  /// No description provided for @add.
  ///
  /// In ja, this message translates to:
  /// **'追加'**
  String get add;

  /// No description provided for @noSavedMachinesDescription.
  ///
  /// In ja, this message translates to:
  /// **'保存済みのマシンはありません。\n追加すると、すばやく接続したり Bridge Server をリモート起動したりできます。'**
  String get noSavedMachinesDescription;

  /// No description provided for @readyToStart.
  ///
  /// In ja, this message translates to:
  /// **'準備完了'**
  String get readyToStart;

  /// No description provided for @readyToStartDescription.
  ///
  /// In ja, this message translates to:
  /// **'+ ボタンを押してセッションを作成し、Claude でコーディングを始めましょう。'**
  String get readyToStartDescription;

  /// No description provided for @newSession.
  ///
  /// In ja, this message translates to:
  /// **'新規セッション'**
  String get newSession;

  /// No description provided for @neverConnected.
  ///
  /// In ja, this message translates to:
  /// **'未接続'**
  String get neverConnected;

  /// No description provided for @justNow.
  ///
  /// In ja, this message translates to:
  /// **'たった今'**
  String get justNow;

  /// No description provided for @minutesAgo.
  ///
  /// In ja, this message translates to:
  /// **'{minutes}分前'**
  String minutesAgo(int minutes);

  /// No description provided for @hoursAgo.
  ///
  /// In ja, this message translates to:
  /// **'{hours}時間前'**
  String hoursAgo(int hours);

  /// No description provided for @daysAgo.
  ///
  /// In ja, this message translates to:
  /// **'{days}日前'**
  String daysAgo(int days);

  /// No description provided for @unfavorite.
  ///
  /// In ja, this message translates to:
  /// **'お気に入り解除'**
  String get unfavorite;

  /// No description provided for @favorite.
  ///
  /// In ja, this message translates to:
  /// **'お気に入り'**
  String get favorite;

  /// No description provided for @updateBridge.
  ///
  /// In ja, this message translates to:
  /// **'Bridge を更新'**
  String get updateBridge;

  /// No description provided for @bridgeIsUpToDate.
  ///
  /// In ja, this message translates to:
  /// **'Bridge は最新です'**
  String get bridgeIsUpToDate;

  /// No description provided for @bridgeUpdateAvailable.
  ///
  /// In ja, this message translates to:
  /// **'更新があります'**
  String get bridgeUpdateAvailable;

  /// No description provided for @bridgeUpdateRequiresSetup.
  ///
  /// In ja, this message translates to:
  /// **'SSH と Bridge の自動起動セットアップが必要です'**
  String get bridgeUpdateRequiresSetup;

  /// No description provided for @bridgeVersionUnknown.
  ///
  /// In ja, this message translates to:
  /// **'Bridge のバージョンを確認できません'**
  String get bridgeVersionUnknown;

  /// No description provided for @bridgeVersionCurrentExpected.
  ///
  /// In ja, this message translates to:
  /// **'現在 v{current}、推奨 v{expected}以上'**
  String bridgeVersionCurrentExpected(String current, String expected);

  /// No description provided for @bridgeVersionCurrentLatest.
  ///
  /// In ja, this message translates to:
  /// **'現在 v{current}、最新版 v{latest}'**
  String bridgeVersionCurrentLatest(String current, String latest);

  /// No description provided for @bridgeLatestVersionChecking.
  ///
  /// In ja, this message translates to:
  /// **'Bridge の最新版を確認中...'**
  String get bridgeLatestVersionChecking;

  /// No description provided for @bridgeLatestVersionUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'Bridge の最新版を確認できません'**
  String get bridgeLatestVersionUnavailable;

  /// No description provided for @bridgeLatestVersionRetry.
  ///
  /// In ja, this message translates to:
  /// **'最新版の確認を再試行'**
  String get bridgeLatestVersionRetry;

  /// No description provided for @bridgeUpdateSetupTitle.
  ///
  /// In ja, this message translates to:
  /// **'Bridge 更新の準備'**
  String get bridgeUpdateSetupTitle;

  /// No description provided for @bridgeUpdateSetupDescription.
  ///
  /// In ja, this message translates to:
  /// **'このマシンで Bridge の更新機能を使うには、SSH 接続と Bridge の自動起動セットアップが必要です。'**
  String get bridgeUpdateSetupDescription;

  /// No description provided for @bridgeUpdateSetupEnableSsh.
  ///
  /// In ja, this message translates to:
  /// **'Bridge 接続設定で SSH を有効にします。'**
  String get bridgeUpdateSetupEnableSsh;

  /// No description provided for @bridgeUpdateSetupRunCommand.
  ///
  /// In ja, this message translates to:
  /// **'接続先マシンでセットアップコマンドを実行しておきます。'**
  String get bridgeUpdateSetupRunCommand;

  /// No description provided for @bridgeUpdateSetupCommand.
  ///
  /// In ja, this message translates to:
  /// **'npx @ccpocket/bridge@latest setup'**
  String get bridgeUpdateSetupCommand;

  /// No description provided for @stopServer.
  ///
  /// In ja, this message translates to:
  /// **'サーバーを停止'**
  String get stopServer;

  /// No description provided for @update.
  ///
  /// In ja, this message translates to:
  /// **'更新'**
  String get update;

  /// No description provided for @download.
  ///
  /// In ja, this message translates to:
  /// **'ダウンロード'**
  String get download;

  /// No description provided for @appUpdateAvailable.
  ///
  /// In ja, this message translates to:
  /// **'v{version} が利用可能です'**
  String appUpdateAvailable(String version);

  /// No description provided for @macosNativeAppBannerTitle.
  ///
  /// In ja, this message translates to:
  /// **'macOS ネイティブ版をおすすめします'**
  String get macosNativeAppBannerTitle;

  /// No description provided for @macosNativeAppBannerSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'Mac では、macOS に最適化された CC Pocket ネイティブ版を GitHub Releases からインストールできます。'**
  String get macosNativeAppBannerSubtitle;

  /// No description provided for @openGitHubReleases.
  ///
  /// In ja, this message translates to:
  /// **'GitHub Releases を開く'**
  String get openGitHubReleases;

  /// No description provided for @macosNativeAppSettingsTitle.
  ///
  /// In ja, this message translates to:
  /// **'macOS ネイティブ版'**
  String get macosNativeAppSettingsTitle;

  /// No description provided for @macosNativeAppSettingsSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'macOS に最適化されているため、Mac ではネイティブ版がおすすめです。'**
  String get macosNativeAppSettingsSubtitle;

  /// No description provided for @supportBannerTitle.
  ///
  /// In ja, this message translates to:
  /// **'CC Pocketが役に立っていたら'**
  String get supportBannerTitle;

  /// No description provided for @supportBannerSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'サポートで継続開発を後押しできます'**
  String get supportBannerSubtitle;

  /// No description provided for @supportBannerAction.
  ///
  /// In ja, this message translates to:
  /// **'サポートを見る'**
  String get supportBannerAction;

  /// No description provided for @offline.
  ///
  /// In ja, this message translates to:
  /// **'オフライン'**
  String get offline;

  /// No description provided for @unreachable.
  ///
  /// In ja, this message translates to:
  /// **'接続不可'**
  String get unreachable;

  /// No description provided for @checking.
  ///
  /// In ja, this message translates to:
  /// **'確認中...'**
  String get checking;

  /// No description provided for @recentProjects.
  ///
  /// In ja, this message translates to:
  /// **'最近のプロジェクト'**
  String get recentProjects;

  /// No description provided for @orEnterPath.
  ///
  /// In ja, this message translates to:
  /// **'またはパスを入力'**
  String get orEnterPath;

  /// No description provided for @projectPath.
  ///
  /// In ja, this message translates to:
  /// **'プロジェクトパス'**
  String get projectPath;

  /// No description provided for @projectPathHint.
  ///
  /// In ja, this message translates to:
  /// **'/path/to/your/project'**
  String get projectPathHint;

  /// No description provided for @permission.
  ///
  /// In ja, this message translates to:
  /// **'パーミッション'**
  String get permission;

  /// No description provided for @approval.
  ///
  /// In ja, this message translates to:
  /// **'承認'**
  String get approval;

  /// No description provided for @restart.
  ///
  /// In ja, this message translates to:
  /// **'再起動'**
  String get restart;

  /// No description provided for @worktree.
  ///
  /// In ja, this message translates to:
  /// **'Worktree'**
  String get worktree;

  /// No description provided for @advanced.
  ///
  /// In ja, this message translates to:
  /// **'詳細設定'**
  String get advanced;

  /// No description provided for @modelOptional.
  ///
  /// In ja, this message translates to:
  /// **'モデル（任意）'**
  String get modelOptional;

  /// No description provided for @effort.
  ///
  /// In ja, this message translates to:
  /// **'推論強度'**
  String get effort;

  /// No description provided for @defaultLabel.
  ///
  /// In ja, this message translates to:
  /// **'デフォルト'**
  String get defaultLabel;

  /// No description provided for @codexProfilePrecedenceNote.
  ///
  /// In ja, this message translates to:
  /// **'Profile で同じ設定を指定している場合は、以下の項目より Profile の設定が優先されます。'**
  String get codexProfilePrecedenceNote;

  /// No description provided for @maxTurns.
  ///
  /// In ja, this message translates to:
  /// **'Max Turns'**
  String get maxTurns;

  /// No description provided for @maxTurnsHint.
  ///
  /// In ja, this message translates to:
  /// **'例: 8'**
  String get maxTurnsHint;

  /// No description provided for @maxTurnsError.
  ///
  /// In ja, this message translates to:
  /// **'1以上の整数を入力してください'**
  String get maxTurnsError;

  /// No description provided for @maxBudgetUsd.
  ///
  /// In ja, this message translates to:
  /// **'最大予算 (USD)'**
  String get maxBudgetUsd;

  /// No description provided for @maxBudgetHint.
  ///
  /// In ja, this message translates to:
  /// **'例: 1.00'**
  String get maxBudgetHint;

  /// No description provided for @maxBudgetError.
  ///
  /// In ja, this message translates to:
  /// **'0以上の数値を入力してください'**
  String get maxBudgetError;

  /// No description provided for @fallbackModel.
  ///
  /// In ja, this message translates to:
  /// **'フォールバックモデル'**
  String get fallbackModel;

  /// No description provided for @forkSessionOnResume.
  ///
  /// In ja, this message translates to:
  /// **'再開時にセッションを分岐'**
  String get forkSessionOnResume;

  /// No description provided for @persistSessionHistory.
  ///
  /// In ja, this message translates to:
  /// **'セッション履歴を保持'**
  String get persistSessionHistory;

  /// No description provided for @model.
  ///
  /// In ja, this message translates to:
  /// **'モデル'**
  String get model;

  /// No description provided for @sandbox.
  ///
  /// In ja, this message translates to:
  /// **'Sandbox'**
  String get sandbox;

  /// No description provided for @reasoning.
  ///
  /// In ja, this message translates to:
  /// **'推論'**
  String get reasoning;

  /// No description provided for @webSearch.
  ///
  /// In ja, this message translates to:
  /// **'ウェブ検索'**
  String get webSearch;

  /// No description provided for @networkAccess.
  ///
  /// In ja, this message translates to:
  /// **'ネットワークアクセス'**
  String get networkAccess;

  /// No description provided for @additionalWritableRootsTitle.
  ///
  /// In ja, this message translates to:
  /// **'追加で利用できるディレクトリ'**
  String get additionalWritableRootsTitle;

  /// No description provided for @additionalWritableRootsDescription.
  ///
  /// In ja, this message translates to:
  /// **'このセッションでは、Codex の config.toml の writable_roots に加えて有効になります。'**
  String get additionalWritableRootsDescription;

  /// No description provided for @additionalWritableRootsTooltip.
  ///
  /// In ja, this message translates to:
  /// **'選択中のプロジェクトに加えて、別プロジェクトのファイルも読み書きしたいときに使います。'**
  String get additionalWritableRootsTooltip;

  /// No description provided for @additionalWritableRootsSuggestions.
  ///
  /// In ja, this message translates to:
  /// **'最近のプロジェクト'**
  String get additionalWritableRootsSuggestions;

  /// No description provided for @addDirectory.
  ///
  /// In ja, this message translates to:
  /// **'ディレクトリを追加'**
  String get addDirectory;

  /// No description provided for @directoryPath.
  ///
  /// In ja, this message translates to:
  /// **'ディレクトリパス'**
  String get directoryPath;

  /// No description provided for @worktreeNew.
  ///
  /// In ja, this message translates to:
  /// **'新規'**
  String get worktreeNew;

  /// No description provided for @worktreeExisting.
  ///
  /// In ja, this message translates to:
  /// **'既存 ({count})'**
  String worktreeExisting(int count);

  /// No description provided for @branchOptional.
  ///
  /// In ja, this message translates to:
  /// **'ブランチ（任意）'**
  String get branchOptional;

  /// No description provided for @branchHint.
  ///
  /// In ja, this message translates to:
  /// **'feature/...'**
  String get branchHint;

  /// No description provided for @noExistingWorktrees.
  ///
  /// In ja, this message translates to:
  /// **'既存の worktree はありません'**
  String get noExistingWorktrees;

  /// No description provided for @planApprovalSummary.
  ///
  /// In ja, this message translates to:
  /// **'上のプランを確認して、承認するか計画を続けてください'**
  String get planApprovalSummary;

  /// No description provided for @planApprovalSummaryCard.
  ///
  /// In ja, this message translates to:
  /// **'プランを確認して、承認するか計画を続けてください'**
  String get planApprovalSummaryCard;

  /// No description provided for @toolApprovalSummary.
  ///
  /// In ja, this message translates to:
  /// **'ツール実行には承認が必要です'**
  String get toolApprovalSummary;

  /// No description provided for @planApproval.
  ///
  /// In ja, this message translates to:
  /// **'プラン承認'**
  String get planApproval;

  /// No description provided for @approvalRequired.
  ///
  /// In ja, this message translates to:
  /// **'承認が必要'**
  String get approvalRequired;

  /// No description provided for @viewEditPlan.
  ///
  /// In ja, this message translates to:
  /// **'プランを表示'**
  String get viewEditPlan;

  /// No description provided for @keepPlanning.
  ///
  /// In ja, this message translates to:
  /// **'計画を続ける'**
  String get keepPlanning;

  /// No description provided for @keepPlanningHint.
  ///
  /// In ja, this message translates to:
  /// **'変更点を入力...'**
  String get keepPlanningHint;

  /// No description provided for @sendFeedbackKeepPlanning.
  ///
  /// In ja, this message translates to:
  /// **'フィードバックを送信して計画を続ける'**
  String get sendFeedbackKeepPlanning;

  /// No description provided for @acceptAndClear.
  ///
  /// In ja, this message translates to:
  /// **'承認 & クリア'**
  String get acceptAndClear;

  /// No description provided for @acceptPlan.
  ///
  /// In ja, this message translates to:
  /// **'プラン承認'**
  String get acceptPlan;

  /// No description provided for @continuePlanning.
  ///
  /// In ja, this message translates to:
  /// **'計画を続ける'**
  String get continuePlanning;

  /// No description provided for @reject.
  ///
  /// In ja, this message translates to:
  /// **'拒否'**
  String get reject;

  /// No description provided for @approve.
  ///
  /// In ja, this message translates to:
  /// **'承認'**
  String get approve;

  /// No description provided for @always.
  ///
  /// In ja, this message translates to:
  /// **'常に許可'**
  String get always;

  /// No description provided for @approveOnce.
  ///
  /// In ja, this message translates to:
  /// **'今回だけ許可'**
  String get approveOnce;

  /// No description provided for @approveForSession.
  ///
  /// In ja, this message translates to:
  /// **'このセッション中は許可'**
  String get approveForSession;

  /// No description provided for @approveAlways.
  ///
  /// In ja, this message translates to:
  /// **'常に許可'**
  String get approveAlways;

  /// No description provided for @approveAlwaysSub.
  ///
  /// In ja, this message translates to:
  /// **''**
  String get approveAlwaysSub;

  /// No description provided for @approveSessionMain.
  ///
  /// In ja, this message translates to:
  /// **'セッション中許可'**
  String get approveSessionMain;

  /// No description provided for @approveSessionSub.
  ///
  /// In ja, this message translates to:
  /// **''**
  String get approveSessionSub;

  /// No description provided for @permissionDefaultDescription.
  ///
  /// In ja, this message translates to:
  /// **'標準の承認フローです'**
  String get permissionDefaultDescription;

  /// No description provided for @permissionAutoDescription.
  ///
  /// In ja, this message translates to:
  /// **'Claude が安全チェック付きで承認を自動処理します'**
  String get permissionAutoDescription;

  /// No description provided for @permissionAcceptEditsDescription.
  ///
  /// In ja, this message translates to:
  /// **'ファイル編集を自動で承認します'**
  String get permissionAcceptEditsDescription;

  /// No description provided for @permissionPlanDescription.
  ///
  /// In ja, this message translates to:
  /// **'変更を実行する前に分析と計画を行います'**
  String get permissionPlanDescription;

  /// No description provided for @permissionBypassDescription.
  ///
  /// In ja, this message translates to:
  /// **'ほとんどの承認確認なしで実行します'**
  String get permissionBypassDescription;

  /// No description provided for @executionDefaultDescription.
  ///
  /// In ja, this message translates to:
  /// **'標準の承認フローです'**
  String get executionDefaultDescription;

  /// No description provided for @executionAcceptEditsDescription.
  ///
  /// In ja, this message translates to:
  /// **'ファイル編集を自動で承認します'**
  String get executionAcceptEditsDescription;

  /// No description provided for @executionFullAccessDescription.
  ///
  /// In ja, this message translates to:
  /// **'ほとんどの承認確認なしで実行します'**
  String get executionFullAccessDescription;

  /// No description provided for @codexPlanModeDescription.
  ///
  /// In ja, this message translates to:
  /// **'先にプランを作成し、承認後に実行を開始します'**
  String get codexPlanModeDescription;

  /// No description provided for @sandboxRestrictedDescription.
  ///
  /// In ja, this message translates to:
  /// **'制限された環境でコマンドを実行します'**
  String get sandboxRestrictedDescription;

  /// No description provided for @sandboxNativeDescription.
  ///
  /// In ja, this message translates to:
  /// **'ネイティブ環境でコマンドを実行します'**
  String get sandboxNativeDescription;

  /// No description provided for @sandboxNativeCautionDescription.
  ///
  /// In ja, this message translates to:
  /// **'ネイティブ環境でコマンドを実行します（注意）'**
  String get sandboxNativeCautionDescription;

  /// No description provided for @sheetSubtitleApproval.
  ///
  /// In ja, this message translates to:
  /// **'どの操作に承認が必要かを制御します'**
  String get sheetSubtitleApproval;

  /// No description provided for @sheetSubtitleSandboxCodex.
  ///
  /// In ja, this message translates to:
  /// **'Codex は安全のためデフォルトで Sandbox が有効です。無効にするとシステムへのフルアクセスが可能になります。'**
  String get sheetSubtitleSandboxCodex;

  /// No description provided for @sheetSubtitleSandboxClaude.
  ///
  /// In ja, this message translates to:
  /// **'Claude はデフォルトでネイティブ実行です。Sandbox を有効にするとアクセスが制限されます。'**
  String get sheetSubtitleSandboxClaude;

  /// No description provided for @sheetSubtitleModel.
  ///
  /// In ja, this message translates to:
  /// **'モデルによって速度・能力・コストが異なります。'**
  String get sheetSubtitleModel;

  /// No description provided for @sheetSubtitleEffort.
  ///
  /// In ja, this message translates to:
  /// **'高い Effort はより丁寧な分析を行いますが、時間とコストが増えます。'**
  String get sheetSubtitleEffort;

  /// No description provided for @claudeEffortLowDesc.
  ///
  /// In ja, this message translates to:
  /// **'高速な応答、分析は少なめ'**
  String get claudeEffortLowDesc;

  /// No description provided for @claudeEffortMediumDesc.
  ///
  /// In ja, this message translates to:
  /// **'速度と品質のバランス'**
  String get claudeEffortMediumDesc;

  /// No description provided for @claudeEffortHighDesc.
  ///
  /// In ja, this message translates to:
  /// **'より丁寧な分析'**
  String get claudeEffortHighDesc;

  /// No description provided for @claudeEffortXHighDesc.
  ///
  /// In ja, this message translates to:
  /// **'複雑な作業向けの拡張推論'**
  String get claudeEffortXHighDesc;

  /// No description provided for @claudeEffortMaxDesc.
  ///
  /// In ja, this message translates to:
  /// **'最も丁寧、最も遅い'**
  String get claudeEffortMaxDesc;

  /// No description provided for @reasoningEffortNoneDesc.
  ///
  /// In ja, this message translates to:
  /// **'推論なし'**
  String get reasoningEffortNoneDesc;

  /// No description provided for @reasoningEffortMinimalDesc.
  ///
  /// In ja, this message translates to:
  /// **'最速、分析は最小限'**
  String get reasoningEffortMinimalDesc;

  /// No description provided for @reasoningEffortLowDesc.
  ///
  /// In ja, this message translates to:
  /// **'高速な応答、分析は少なめ'**
  String get reasoningEffortLowDesc;

  /// No description provided for @reasoningEffortMediumDesc.
  ///
  /// In ja, this message translates to:
  /// **'速度と品質のバランス'**
  String get reasoningEffortMediumDesc;

  /// No description provided for @reasoningEffortHighDesc.
  ///
  /// In ja, this message translates to:
  /// **'より丁寧な分析'**
  String get reasoningEffortHighDesc;

  /// No description provided for @reasoningEffortXhighDesc.
  ///
  /// In ja, this message translates to:
  /// **'最も丁寧、最も遅い'**
  String get reasoningEffortXhighDesc;

  /// No description provided for @reasoningEffortMaxDesc.
  ///
  /// In ja, this message translates to:
  /// **'最も難しい問題向けの最大推論'**
  String get reasoningEffortMaxDesc;

  /// No description provided for @reasoningEffortUltraDesc.
  ///
  /// In ja, this message translates to:
  /// **'最大推論と自動タスク委譲'**
  String get reasoningEffortUltraDesc;

  /// No description provided for @reasoningEffortModelSpecificDesc.
  ///
  /// In ja, this message translates to:
  /// **'モデル固有の推論レベル'**
  String get reasoningEffortModelSpecificDesc;

  /// No description provided for @changePermissionModeTitle.
  ///
  /// In ja, this message translates to:
  /// **'Permission Mode を変更'**
  String get changePermissionModeTitle;

  /// No description provided for @changePermissionModeBody.
  ///
  /// In ja, this message translates to:
  /// **'{mode} に切り替えるとセッションが再起動します。会話は保持されます。'**
  String changePermissionModeBody(String mode);

  /// No description provided for @changeExecutionModeTitle.
  ///
  /// In ja, this message translates to:
  /// **'Execution Mode を変更'**
  String get changeExecutionModeTitle;

  /// No description provided for @changeExecutionModeBody.
  ///
  /// In ja, this message translates to:
  /// **'{mode} に切り替えるとセッションが再起動します。会話は保持されます。'**
  String changeExecutionModeBody(String mode);

  /// No description provided for @changeApprovalPolicyTitle.
  ///
  /// In ja, this message translates to:
  /// **'Approval Policy を変更'**
  String get changeApprovalPolicyTitle;

  /// No description provided for @changeApprovalPolicyBody.
  ///
  /// In ja, this message translates to:
  /// **'{mode} に切り替えるとセッションが再起動します。会話は保持されます。'**
  String changeApprovalPolicyBody(String mode);

  /// No description provided for @applyPermissionsTitle.
  ///
  /// In ja, this message translates to:
  /// **'権限変更を適用'**
  String get applyPermissionsTitle;

  /// No description provided for @applyPermissionsBody.
  ///
  /// In ja, this message translates to:
  /// **'{mode} をいつ有効にするか選択してください。'**
  String applyPermissionsBody(String mode);

  /// No description provided for @applyPermissionsNextTurnTitle.
  ///
  /// In ja, this message translates to:
  /// **'次のターンから'**
  String get applyPermissionsNextTurnTitle;

  /// No description provided for @applyPermissionsNextTurnDescription.
  ///
  /// In ja, this message translates to:
  /// **'現在の実行を中断しません。現在のターンと表示済みの承認は従来の権限のままです。目標モードの次のステップを含む、まだ開始していない次のターンから適用します。'**
  String get applyPermissionsNextTurnDescription;

  /// No description provided for @applyPermissionsRestartNowTitle.
  ///
  /// In ja, this message translates to:
  /// **'今すぐ再起動'**
  String get applyPermissionsRestartNowTitle;

  /// No description provided for @applyPermissionsRestartNowDescription.
  ///
  /// In ja, this message translates to:
  /// **'現在のターンを中断して保留中の承認を閉じ、新しい権限で同じ会話を再開します。'**
  String get applyPermissionsRestartNowDescription;

  /// No description provided for @permissionModeNextTurnAppliedTip.
  ///
  /// In ja, this message translates to:
  /// **'権限を保存しました。まだ開始していない次のターンから適用され、現在の承認は従来の権限のままです。'**
  String get permissionModeNextTurnAppliedTip;

  /// No description provided for @manualContextCompactedTip.
  ///
  /// In ja, this message translates to:
  /// **'コンテキストを手動で圧縮しました。'**
  String get manualContextCompactedTip;

  /// No description provided for @codexApprovalUntrustedDescription.
  ///
  /// In ja, this message translates to:
  /// **'trusted コマンドだけ自動実行し、それ以外は確認します'**
  String get codexApprovalUntrustedDescription;

  /// No description provided for @codexApprovalOnRequestDescription.
  ///
  /// In ja, this message translates to:
  /// **'必要だと判断した操作だけ確認します'**
  String get codexApprovalOnRequestDescription;

  /// No description provided for @codexApprovalOnFailureDescription.
  ///
  /// In ja, this message translates to:
  /// **'通常は確認せず実行し、失敗時だけ追加権限を確認します（非推奨）'**
  String get codexApprovalOnFailureDescription;

  /// No description provided for @codexApprovalNeverDescription.
  ///
  /// In ja, this message translates to:
  /// **'確認せず実行し、失敗時も承認を求めません'**
  String get codexApprovalNeverDescription;

  /// No description provided for @codexAutoReview.
  ///
  /// In ja, this message translates to:
  /// **'自動レビュー'**
  String get codexAutoReview;

  /// No description provided for @codexAutoReviewDescription.
  ///
  /// In ja, this message translates to:
  /// **'承認リクエストを Codex が自動レビューします'**
  String get codexAutoReviewDescription;

  /// No description provided for @codexAutoReviewDisabledByPolicy.
  ///
  /// In ja, this message translates to:
  /// **'組織の Browser Use ポリシーにより無効です'**
  String get codexAutoReviewDisabledByPolicy;

  /// No description provided for @codexAutoReviewUnavailableDescription.
  ///
  /// In ja, this message translates to:
  /// **'Never Ask では承認リクエストが発生しないため利用できません'**
  String get codexAutoReviewUnavailableDescription;

  /// No description provided for @guardianApprovalTitle.
  ///
  /// In ja, this message translates to:
  /// **'自動レビューで承認'**
  String get guardianApprovalTitle;

  /// No description provided for @guardianApprovalDeniedTitle.
  ///
  /// In ja, this message translates to:
  /// **'自動レビューで却下'**
  String get guardianApprovalDeniedTitle;

  /// No description provided for @guardianApprovalTimedOutTitle.
  ///
  /// In ja, this message translates to:
  /// **'自動レビューがタイムアウト'**
  String get guardianApprovalTimedOutTitle;

  /// No description provided for @guardianApprovalAbortedTitle.
  ///
  /// In ja, this message translates to:
  /// **'自動レビューを中止'**
  String get guardianApprovalAbortedTitle;

  /// No description provided for @guardianApprovalUnknownRisk.
  ///
  /// In ja, this message translates to:
  /// **'リスク未評価'**
  String get guardianApprovalUnknownRisk;

  /// No description provided for @guardianApprovalLowRisk.
  ///
  /// In ja, this message translates to:
  /// **'低リスク'**
  String get guardianApprovalLowRisk;

  /// No description provided for @guardianApprovalMediumRisk.
  ///
  /// In ja, this message translates to:
  /// **'中リスク'**
  String get guardianApprovalMediumRisk;

  /// No description provided for @guardianApprovalHighRisk.
  ///
  /// In ja, this message translates to:
  /// **'高リスク'**
  String get guardianApprovalHighRisk;

  /// No description provided for @guardianApprovalCriticalRisk.
  ///
  /// In ja, this message translates to:
  /// **'重大リスク'**
  String get guardianApprovalCriticalRisk;

  /// No description provided for @guardianApprovalDetails.
  ///
  /// In ja, this message translates to:
  /// **'詳細'**
  String get guardianApprovalDetails;

  /// No description provided for @guardianApprovalHideDetails.
  ///
  /// In ja, this message translates to:
  /// **'詳細を閉じる'**
  String get guardianApprovalHideDetails;

  /// No description provided for @guardianApprovalReasonLabel.
  ///
  /// In ja, this message translates to:
  /// **'審査理由'**
  String get guardianApprovalReasonLabel;

  /// No description provided for @guardianApprovalInstructionLabel.
  ///
  /// In ja, this message translates to:
  /// **'実行内容'**
  String get guardianApprovalInstructionLabel;

  /// No description provided for @guardianApprovalInstructionUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'この Codex バージョンでは具体的な実行内容が提供されませんでした。'**
  String get guardianApprovalInstructionUnavailable;

  /// No description provided for @guardianApprovalWorkingDirectory.
  ///
  /// In ja, this message translates to:
  /// **'作業ディレクトリ: {path}'**
  String guardianApprovalWorkingDirectory(String path);

  /// No description provided for @guardianApprovalAuthorizationUnknown.
  ///
  /// In ja, this message translates to:
  /// **'不明'**
  String get guardianApprovalAuthorizationUnknown;

  /// No description provided for @guardianApprovalAuthorizationLow.
  ///
  /// In ja, this message translates to:
  /// **'低'**
  String get guardianApprovalAuthorizationLow;

  /// No description provided for @guardianApprovalAuthorizationMedium.
  ///
  /// In ja, this message translates to:
  /// **'中'**
  String get guardianApprovalAuthorizationMedium;

  /// No description provided for @guardianApprovalAuthorizationHigh.
  ///
  /// In ja, this message translates to:
  /// **'高'**
  String get guardianApprovalAuthorizationHigh;

  /// No description provided for @guardianApprovalLowRiskAllowReason.
  ///
  /// In ja, this message translates to:
  /// **'自動レビューが低リスクと判断し、実行を許可しました。'**
  String get guardianApprovalLowRiskAllowReason;

  /// No description provided for @guardianApprovalTimedOutReason.
  ///
  /// In ja, this message translates to:
  /// **'自動レビューはこのリクエストの評価中にタイムアウトしました。'**
  String get guardianApprovalTimedOutReason;

  /// No description provided for @guardianApprovalAuthorization.
  ///
  /// In ja, this message translates to:
  /// **'承認レベル: {authorization}'**
  String guardianApprovalAuthorization(String authorization);

  /// No description provided for @enablePlanModeTitle.
  ///
  /// In ja, this message translates to:
  /// **'Plan Mode を有効化'**
  String get enablePlanModeTitle;

  /// No description provided for @disablePlanModeTitle.
  ///
  /// In ja, this message translates to:
  /// **'Plan Mode を無効化'**
  String get disablePlanModeTitle;

  /// No description provided for @enablePlanModeBody.
  ///
  /// In ja, this message translates to:
  /// **'Plan Mode を有効化するとセッションが再起動します。会話は保持されます。'**
  String get enablePlanModeBody;

  /// No description provided for @disablePlanModeBody.
  ///
  /// In ja, this message translates to:
  /// **'Plan Mode を無効化するとセッションが再起動します。会話は保持されます。'**
  String get disablePlanModeBody;

  /// No description provided for @codexNativePlanModeUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'この Codex ランタイムはネイティブ Plan モードに対応していません。Codex を更新するか、互換性のある Bridge に再接続してください。'**
  String get codexNativePlanModeUnavailable;

  /// No description provided for @changeSandboxModeTitle.
  ///
  /// In ja, this message translates to:
  /// **'Sandbox Mode を変更'**
  String get changeSandboxModeTitle;

  /// No description provided for @changeSandboxModeBody.
  ///
  /// In ja, this message translates to:
  /// **'{mode} に切り替えるとセッションが再起動します。会話は保持されます。'**
  String changeSandboxModeBody(String mode);

  /// No description provided for @messagePlaceholder.
  ///
  /// In ja, this message translates to:
  /// **'Claude にメッセージ...'**
  String get messagePlaceholder;

  /// No description provided for @codexMessagePlaceholder.
  ///
  /// In ja, this message translates to:
  /// **'Codex にメッセージ...'**
  String get codexMessagePlaceholder;

  /// No description provided for @queuedInputForReconnect.
  ///
  /// In ja, this message translates to:
  /// **'再接続待ちキュー'**
  String get queuedInputForReconnect;

  /// No description provided for @queuedInputPendingDelivery.
  ///
  /// In ja, this message translates to:
  /// **'送信確認中'**
  String get queuedInputPendingDelivery;

  /// No description provided for @queuedInputForNextTurn.
  ///
  /// In ja, this message translates to:
  /// **'次のターンに送信予定'**
  String get queuedInputForNextTurn;

  /// No description provided for @sessionCardQueuedInput.
  ///
  /// In ja, this message translates to:
  /// **'キュー中'**
  String get sessionCardQueuedInput;

  /// No description provided for @queuedInputImageCount.
  ///
  /// In ja, this message translates to:
  /// **'{count, plural, other{画像{count}枚}}'**
  String queuedInputImageCount(int count);

  /// No description provided for @tooltipSteerQueuedMessage.
  ///
  /// In ja, this message translates to:
  /// **'キュー中のメッセージを指示として送信'**
  String get tooltipSteerQueuedMessage;

  /// No description provided for @tooltipMoveQueuedMessageToInput.
  ///
  /// In ja, this message translates to:
  /// **'キュー中のメッセージを入力欄へ移動'**
  String get tooltipMoveQueuedMessageToInput;

  /// No description provided for @tooltipCancelQueuedMessage.
  ///
  /// In ja, this message translates to:
  /// **'キュー中のメッセージをキャンセル'**
  String get tooltipCancelQueuedMessage;

  /// No description provided for @reconnecting.
  ///
  /// In ja, this message translates to:
  /// **'Bridge との接続が一時的に切れました。自動で再接続しています...'**
  String get reconnecting;

  /// No description provided for @reconnectingQueuedMessages.
  ///
  /// In ja, this message translates to:
  /// **'Bridge との接続が一時的に切れました。自動で再接続しています。待機中のメッセージは保持されています。'**
  String get reconnectingQueuedMessages;

  /// No description provided for @disconnectedMessagesQueued.
  ///
  /// In ja, this message translates to:
  /// **'Bridge に接続できません。操作は端末に保存され、再接続後に送信されます。'**
  String get disconnectedMessagesQueued;

  /// No description provided for @sessionQueuedForReconnect.
  ///
  /// In ja, this message translates to:
  /// **'セッションを再接続待ちキューに追加しました'**
  String get sessionQueuedForReconnect;

  /// No description provided for @resumeAlreadyQueued.
  ///
  /// In ja, this message translates to:
  /// **'再開はすでにキューに入っています'**
  String get resumeAlreadyQueued;

  /// No description provided for @resumeQueuedForReconnect.
  ///
  /// In ja, this message translates to:
  /// **'再開を再接続待ちキューに追加しました'**
  String get resumeQueuedForReconnect;

  /// No description provided for @pendingActionWillCreateOnReconnect.
  ///
  /// In ja, this message translates to:
  /// **'Bridge 再接続後に作成します'**
  String get pendingActionWillCreateOnReconnect;

  /// No description provided for @pendingActionWillResumeOnReconnect.
  ///
  /// In ja, this message translates to:
  /// **'Bridge 再接続後に再開します'**
  String get pendingActionWillResumeOnReconnect;

  /// No description provided for @pendingActionStatus.
  ///
  /// In ja, this message translates to:
  /// **'待機中'**
  String get pendingActionStatus;

  /// No description provided for @pendingActionProcessingStatus.
  ///
  /// In ja, this message translates to:
  /// **'復元中'**
  String get pendingActionProcessingStatus;

  /// No description provided for @pendingActionProcessingStartStatus.
  ///
  /// In ja, this message translates to:
  /// **'準備中'**
  String get pendingActionProcessingStartStatus;

  /// No description provided for @pendingActionProcessingStartDescription.
  ///
  /// In ja, this message translates to:
  /// **'Bridge でセッションを準備しています'**
  String get pendingActionProcessingStartDescription;

  /// No description provided for @pendingActionProcessingResumeDescription.
  ///
  /// In ja, this message translates to:
  /// **'画像が多いセッションは時間がかかることがあります'**
  String get pendingActionProcessingResumeDescription;

  /// No description provided for @pendingActionProcessingStartTitle.
  ///
  /// In ja, this message translates to:
  /// **'新規セッションを作成中'**
  String get pendingActionProcessingStartTitle;

  /// No description provided for @pendingActionProcessingResumeTitle.
  ///
  /// In ja, this message translates to:
  /// **'セッション履歴を読み込んでいます'**
  String get pendingActionProcessingResumeTitle;

  /// No description provided for @tooltipCancelPendingAction.
  ///
  /// In ja, this message translates to:
  /// **'待機中の操作をキャンセル'**
  String get tooltipCancelPendingAction;

  /// No description provided for @queuedLocally.
  ///
  /// In ja, this message translates to:
  /// **'ローカルでキュー中'**
  String get queuedLocally;

  /// No description provided for @queuedSubmissionSaveFailed.
  ///
  /// In ja, this message translates to:
  /// **'このキューメッセージを保存できませんでした。テキストと添付ファイルは入力欄に残っています。'**
  String get queuedSubmissionSaveFailed;

  /// No description provided for @processingOnBridge.
  ///
  /// In ja, this message translates to:
  /// **'Bridge で処理中'**
  String get processingOnBridge;

  /// No description provided for @offlinePendingNewSessionTitle.
  ///
  /// In ja, this message translates to:
  /// **'新規セッション待機中'**
  String get offlinePendingNewSessionTitle;

  /// No description provided for @offlinePendingResumeTitle.
  ///
  /// In ja, this message translates to:
  /// **'再開待機中'**
  String get offlinePendingResumeTitle;

  /// No description provided for @diffLines.
  ///
  /// In ja, this message translates to:
  /// **'{count} 行の diff'**
  String diffLines(int count);

  /// No description provided for @changedLines.
  ///
  /// In ja, this message translates to:
  /// **'変更{count}行'**
  String changedLines(int count);

  /// No description provided for @hunkCount.
  ///
  /// In ja, this message translates to:
  /// **'{count}ハンク'**
  String hunkCount(int count);

  /// No description provided for @fileCount.
  ///
  /// In ja, this message translates to:
  /// **'{count}ファイル'**
  String fileCount(int count);

  /// No description provided for @tapInterruptHoldStop.
  ///
  /// In ja, this message translates to:
  /// **'タップ: 中断, 長押し: 停止'**
  String get tapInterruptHoldStop;

  /// No description provided for @tapDetachDesktopTurn.
  ///
  /// In ja, this message translates to:
  /// **'タップまたは長押し: スマートフォンから切断（Desktop の処理は継続）'**
  String get tapDetachDesktopTurn;

  /// No description provided for @rewind.
  ///
  /// In ja, this message translates to:
  /// **'巻き戻す'**
  String get rewind;

  /// No description provided for @rewindToHere.
  ///
  /// In ja, this message translates to:
  /// **'ここまで巻き戻す'**
  String get rewindToHere;

  /// No description provided for @rewindModeConversationAndCode.
  ///
  /// In ja, this message translates to:
  /// **'会話とコードを復元'**
  String get rewindModeConversationAndCode;

  /// No description provided for @rewindModeConversationOnly.
  ///
  /// In ja, this message translates to:
  /// **'会話のみ復元'**
  String get rewindModeConversationOnly;

  /// No description provided for @rewindModeCodeOnly.
  ///
  /// In ja, this message translates to:
  /// **'コードのみ復元'**
  String get rewindModeCodeOnly;

  /// No description provided for @rewindConfirmTitle.
  ///
  /// In ja, this message translates to:
  /// **'巻き戻しの確認'**
  String get rewindConfirmTitle;

  /// No description provided for @rewindConfirmBody.
  ///
  /// In ja, this message translates to:
  /// **'モード: {mode}\n\nこの操作は元に戻せません。実行しますか？'**
  String rewindConfirmBody(Object mode);

  /// No description provided for @rewindCannotRewindFiles.
  ///
  /// In ja, this message translates to:
  /// **'ファイルを巻き戻せません'**
  String get rewindCannotRewindFiles;

  /// No description provided for @codexRewindConfirmTitle.
  ///
  /// In ja, this message translates to:
  /// **'会話を巻き戻しますか？'**
  String get codexRewindConfirmTitle;

  /// No description provided for @codexRewindConfirmBody.
  ///
  /// In ja, this message translates to:
  /// **'このメッセージの直前までチャットを戻し、メッセージを入力欄に戻します。ファイル変更はそのまま残ります。'**
  String get codexRewindConfirmBody;

  /// No description provided for @fork.
  ///
  /// In ja, this message translates to:
  /// **'分岐'**
  String get fork;

  /// No description provided for @forkConversation.
  ///
  /// In ja, this message translates to:
  /// **'会話を分岐'**
  String get forkConversation;

  /// No description provided for @forkConversationTitle.
  ///
  /// In ja, this message translates to:
  /// **'会話を分岐しますか？'**
  String get forkConversationTitle;

  /// No description provided for @forkConversationBody.
  ///
  /// In ja, this message translates to:
  /// **'この応答時点から新しいCodexセッションを作成します。現在のセッションは変更されません。'**
  String get forkConversationBody;

  /// No description provided for @forkTargetNotFound.
  ///
  /// In ja, this message translates to:
  /// **'分岐元のユーザー発言が見つかりません'**
  String get forkTargetNotFound;

  /// No description provided for @tapToRetry.
  ///
  /// In ja, this message translates to:
  /// **'タップしてリトライ'**
  String get tapToRetry;

  /// No description provided for @diffSummaryAddedRemoved.
  ///
  /// In ja, this message translates to:
  /// **'+{added}/-{removed} 行'**
  String diffSummaryAddedRemoved(int added, int removed);

  /// No description provided for @lineCountSummary.
  ///
  /// In ja, this message translates to:
  /// **'{count} 行'**
  String lineCountSummary(int count);

  /// No description provided for @toolResult.
  ///
  /// In ja, this message translates to:
  /// **'ツール結果'**
  String get toolResult;

  /// No description provided for @toolDisplayRead.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{ファイルを読み取り} other{読み取り済み}}'**
  String toolDisplayRead(String phase);

  /// No description provided for @toolDisplayReadSkill.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{Skill を読み取り} other{Skill を読み取り済み}}'**
  String toolDisplayReadSkill(String phase);

  /// No description provided for @toolDisplayFileChange.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{ファイルを変更} completed{ファイルを変更しました} result{ファイル変更が完了しました} other{ファイルを変更}}'**
  String toolDisplayFileChange(String phase);

  /// No description provided for @toolDisplayCommand.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{コマンドを実行} completed{コマンドを実行しました} result{ターミナルコマンドが完了しました} other{コマンドを実行}}'**
  String toolDisplayCommand(String phase);

  /// No description provided for @toolDisplayMultipleCommands.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{複数のコマンドを実行} completed{複数のコマンドを実行しました} result{複数のコマンドが完了しました} other{複数のコマンドを実行}}'**
  String toolDisplayMultipleCommands(String phase);

  /// No description provided for @toolDisplaySearchFiles.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{ファイルを検索} other{ファイルを検索しました}}'**
  String toolDisplaySearchFiles(String phase);

  /// No description provided for @toolDisplayListFiles.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{ファイル一覧を表示} other{ファイル一覧を表示しました}}'**
  String toolDisplayListFiles(String phase);

  /// No description provided for @toolDisplaySearchWeb.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{ウェブを検索} other{ウェブを検索しました}}'**
  String toolDisplaySearchWeb(String phase);

  /// No description provided for @toolDisplayReadWebPage.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{ウェブページを読み取り} other{ウェブページを読み取りました}}'**
  String toolDisplayReadWebPage(String phase);

  /// No description provided for @toolDisplayStartSubAgent.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{サブ Agent を開始} other{サブ Agent を開始しました}}'**
  String toolDisplayStartSubAgent(String phase);

  /// No description provided for @toolDisplayGuideSubAgent.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{サブ Agent を誘導} other{サブ Agent を誘導しました}}'**
  String toolDisplayGuideSubAgent(String phase);

  /// No description provided for @toolDisplayResumeSubAgent.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{サブ Agent を再開} other{サブ Agent を再開しました}}'**
  String toolDisplayResumeSubAgent(String phase);

  /// No description provided for @toolDisplayWaitForSubAgents.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{サブ Agent を待機} other{サブ Agent を待機しました}}'**
  String toolDisplayWaitForSubAgents(String phase);

  /// No description provided for @toolDisplayCloseSubAgent.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{サブ Agent を終了} other{サブ Agent を終了しました}}'**
  String toolDisplayCloseSubAgent(String phase);

  /// No description provided for @toolDisplayInterruptSubAgent.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{サブ Agent を中断} other{サブ Agent を中断しました}}'**
  String toolDisplayInterruptSubAgent(String phase);

  /// No description provided for @toolDisplayListSubAgents.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{サブ Agent を表示} other{サブ Agent を表示しました}}'**
  String toolDisplayListSubAgents(String phase);

  /// No description provided for @toolDisplayInteractWithSubAgent.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{サブ Agent と対話} other{サブ Agent と対話しました}}'**
  String toolDisplayInteractWithSubAgent(String phase);

  /// No description provided for @toolDisplaySubAgentActivity.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{サブ Agent のアクティビティ} other{サブ Agent のアクティビティを更新しました}}'**
  String toolDisplaySubAgentActivity(String phase);

  /// No description provided for @toolDisplayCompactContext.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{コンテキストを圧縮} other{コンテキストを圧縮しました}}'**
  String toolDisplayCompactContext(String phase);

  /// No description provided for @toolDisplayUpdatePlan.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{計画を更新} other{計画を更新しました}}'**
  String toolDisplayUpdatePlan(String phase);

  /// No description provided for @toolDisplayCreateGoal.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{目標を作成} other{目標を作成しました}}'**
  String toolDisplayCreateGoal(String phase);

  /// No description provided for @toolDisplayReadGoal.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{目標を確認} other{目標を確認しました}}'**
  String toolDisplayReadGoal(String phase);

  /// No description provided for @toolDisplayUpdateGoal.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{目標を更新} other{目標を更新しました}}'**
  String toolDisplayUpdateGoal(String phase);

  /// No description provided for @toolDisplayRequestUserInput.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{ユーザー入力を要求} other{ユーザー入力を要求しました}}'**
  String toolDisplayRequestUserInput(String phase);

  /// No description provided for @toolDisplayWait.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{待機} other{待機が完了しました}}'**
  String toolDisplayWait(String phase);

  /// No description provided for @toolDisplayViewImage.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{画像を表示} other{画像を表示しました}}'**
  String toolDisplayViewImage(String phase);

  /// No description provided for @toolDisplayGenerateImage.
  ///
  /// In ja, this message translates to:
  /// **'{phase, select, action{画像を生成} other{画像生成が完了しました}}'**
  String toolDisplayGenerateImage(String phase);

  /// No description provided for @chatProcessRunningTitle.
  ///
  /// In ja, this message translates to:
  /// **'思考・実行中'**
  String get chatProcessRunningTitle;

  /// No description provided for @chatProcessTitle.
  ///
  /// In ja, this message translates to:
  /// **'思考と操作'**
  String get chatProcessTitle;

  /// No description provided for @chatProcessItemCount.
  ///
  /// In ja, this message translates to:
  /// **'{count} 件'**
  String chatProcessItemCount(int count);

  /// No description provided for @chatProcessIntermediateUpdates.
  ///
  /// In ja, this message translates to:
  /// **'途中経過'**
  String get chatProcessIntermediateUpdates;

  /// No description provided for @chatProcessUpdateCount.
  ///
  /// In ja, this message translates to:
  /// **'{count} 件の更新'**
  String chatProcessUpdateCount(int count);

  /// No description provided for @chatProcessUpdateDetailCount.
  ///
  /// In ja, this message translates to:
  /// **'{count} 件の更新 · {detailCount} 件の詳細'**
  String chatProcessUpdateDetailCount(int count, int detailCount);

  /// No description provided for @chatProcessCurrentProgress.
  ///
  /// In ja, this message translates to:
  /// **'現在の進捗'**
  String get chatProcessCurrentProgress;

  /// No description provided for @chatProcessLive.
  ///
  /// In ja, this message translates to:
  /// **'進行中'**
  String get chatProcessLive;

  /// No description provided for @chatProcessLatestTool.
  ///
  /// In ja, this message translates to:
  /// **'最新のツール'**
  String get chatProcessLatestTool;

  /// No description provided for @chatProcessRunningTool.
  ///
  /// In ja, this message translates to:
  /// **'実行中'**
  String get chatProcessRunningTool;

  /// No description provided for @answered.
  ///
  /// In ja, this message translates to:
  /// **'回答済み'**
  String get answered;

  /// No description provided for @agentIsAsking.
  ///
  /// In ja, this message translates to:
  /// **'{agent} が質問しています'**
  String agentIsAsking(Object agent);

  /// No description provided for @submitAllAnswers.
  ///
  /// In ja, this message translates to:
  /// **'すべての回答を送信'**
  String get submitAllAnswers;

  /// No description provided for @submitWithCount.
  ///
  /// In ja, this message translates to:
  /// **'送信 ({count} 件選択)'**
  String submitWithCount(int count);

  /// No description provided for @selectOptionsToSubmit.
  ///
  /// In ja, this message translates to:
  /// **'オプションを選択してください'**
  String get selectOptionsToSubmit;

  /// No description provided for @typeYourAnswer.
  ///
  /// In ja, this message translates to:
  /// **'回答を入力...'**
  String get typeYourAnswer;

  /// No description provided for @orTypeCustomAnswer.
  ///
  /// In ja, this message translates to:
  /// **'またはカスタム回答を入力...'**
  String get orTypeCustomAnswer;

  /// No description provided for @otherAnswer.
  ///
  /// In ja, this message translates to:
  /// **'その他の回答...'**
  String get otherAnswer;

  /// No description provided for @selectAllThatApply.
  ///
  /// In ja, this message translates to:
  /// **'該当するものをすべて選択'**
  String get selectAllThatApply;

  /// No description provided for @noScreenshotsYet.
  ///
  /// In ja, this message translates to:
  /// **'スクリーンショットはまだありません'**
  String get noScreenshotsYet;

  /// No description provided for @screenshotButtonHint.
  ///
  /// In ja, this message translates to:
  /// **'チャットツールバーのスクリーンショットボタンで画面をキャプチャできます。'**
  String get screenshotButtonHint;

  /// No description provided for @screenshotsWillAppearHere.
  ///
  /// In ja, this message translates to:
  /// **'Claude セッションのスクリーンショットがここに表示されます。'**
  String get screenshotsWillAppearHere;

  /// No description provided for @allWithCount.
  ///
  /// In ja, this message translates to:
  /// **'すべて ({count})'**
  String allWithCount(int count);

  /// No description provided for @noImages.
  ///
  /// In ja, this message translates to:
  /// **'画像がありません'**
  String get noImages;

  /// No description provided for @failedToDeleteImage.
  ///
  /// In ja, this message translates to:
  /// **'画像の削除に失敗しました'**
  String get failedToDeleteImage;

  /// No description provided for @failedToDownloadImage.
  ///
  /// In ja, this message translates to:
  /// **'画像のダウンロードに失敗しました'**
  String get failedToDownloadImage;

  /// No description provided for @failedToShareImage.
  ///
  /// In ja, this message translates to:
  /// **'画像の共有に失敗しました'**
  String get failedToShareImage;

  /// No description provided for @deleteScreenshot.
  ///
  /// In ja, this message translates to:
  /// **'スクリーンショットを削除しますか？'**
  String get deleteScreenshot;

  /// No description provided for @cannotBeUndone.
  ///
  /// In ja, this message translates to:
  /// **'この操作は取り消せません。'**
  String get cannotBeUndone;

  /// No description provided for @changes.
  ///
  /// In ja, this message translates to:
  /// **'変更'**
  String get changes;

  /// No description provided for @refresh.
  ///
  /// In ja, this message translates to:
  /// **'更新'**
  String get refresh;

  /// No description provided for @diffCompareSideBySide.
  ///
  /// In ja, this message translates to:
  /// **'並べて比較'**
  String get diffCompareSideBySide;

  /// No description provided for @diffCompareSlider.
  ///
  /// In ja, this message translates to:
  /// **'スライダー'**
  String get diffCompareSlider;

  /// No description provided for @diffCompareOverlay.
  ///
  /// In ja, this message translates to:
  /// **'オーバーレイ'**
  String get diffCompareOverlay;

  /// No description provided for @diffCompareToggle.
  ///
  /// In ja, this message translates to:
  /// **'トグル'**
  String get diffCompareToggle;

  /// No description provided for @diffBefore.
  ///
  /// In ja, this message translates to:
  /// **'変更前'**
  String get diffBefore;

  /// No description provided for @diffAfter.
  ///
  /// In ja, this message translates to:
  /// **'変更後'**
  String get diffAfter;

  /// No description provided for @diffNewFile.
  ///
  /// In ja, this message translates to:
  /// **'新規ファイル'**
  String get diffNewFile;

  /// No description provided for @diffDeleted.
  ///
  /// In ja, this message translates to:
  /// **'削除済み'**
  String get diffDeleted;

  /// No description provided for @diffNoImage.
  ///
  /// In ja, this message translates to:
  /// **'画像なし'**
  String get diffNoImage;

  /// No description provided for @noChanges.
  ///
  /// In ja, this message translates to:
  /// **'変更なし'**
  String get noChanges;

  /// No description provided for @showAll.
  ///
  /// In ja, this message translates to:
  /// **'すべて表示'**
  String get showAll;

  /// No description provided for @setupGuideTitle.
  ///
  /// In ja, this message translates to:
  /// **'セットアップガイド'**
  String get setupGuideTitle;

  /// No description provided for @guideAboutTitle.
  ///
  /// In ja, this message translates to:
  /// **'CC Pocket とは'**
  String get guideAboutTitle;

  /// No description provided for @guideAboutDescription.
  ///
  /// In ja, this message translates to:
  /// **'Bridge Server 経由で Codex や Claude をスマートフォンから使えるモバイルクライアントです。'**
  String get guideAboutDescription;

  /// No description provided for @guideAboutSdkNoteTitle.
  ///
  /// In ja, this message translates to:
  /// **'Claude Agent SDK について'**
  String get guideAboutSdkNoteTitle;

  /// No description provided for @guideAboutSdkNoteBody.
  ///
  /// In ja, this message translates to:
  /// **'Claude Code のライブラリ版です。履歴や .claude、CLAUDE.md などの設定ファイルを共有でき、承認フローもおおよそ同じ感覚で使えます。'**
  String get guideAboutSdkNoteBody;

  /// No description provided for @guideAboutDiagramTitle.
  ///
  /// In ja, this message translates to:
  /// **'しくみ'**
  String get guideAboutDiagramTitle;

  /// No description provided for @guideAboutDiagramPhone.
  ///
  /// In ja, this message translates to:
  /// **'iPhone'**
  String get guideAboutDiagramPhone;

  /// No description provided for @guideAboutDiagramBridge.
  ///
  /// In ja, this message translates to:
  /// **'Bridge Server'**
  String get guideAboutDiagramBridge;

  /// No description provided for @guideAboutDiagramClaude.
  ///
  /// In ja, this message translates to:
  /// **'Codex CLI\n/ Claude Agent SDK'**
  String get guideAboutDiagramClaude;

  /// No description provided for @guideAboutDiagramCaption.
  ///
  /// In ja, this message translates to:
  /// **'PC の Bridge Server が Codex CLI や Claude Agent SDK に接続し、\nスマホからその Bridge に接続して使います。'**
  String get guideAboutDiagramCaption;

  /// No description provided for @guideBridgeTitle.
  ///
  /// In ja, this message translates to:
  /// **'Bridge Server の\nセットアップ'**
  String get guideBridgeTitle;

  /// No description provided for @guideBridgeDescription.
  ///
  /// In ja, this message translates to:
  /// **'PC で Bridge Server を起動します。Claude を使う場合は ANTHROPIC_API_KEY も設定してください。'**
  String get guideBridgeDescription;

  /// No description provided for @guideBridgePrerequisites.
  ///
  /// In ja, this message translates to:
  /// **'必要なもの'**
  String get guideBridgePrerequisites;

  /// No description provided for @guideBridgePrereq1.
  ///
  /// In ja, this message translates to:
  /// **'Node.js がインストールされた Mac / PC'**
  String get guideBridgePrereq1;

  /// No description provided for @guideBridgePrereq2.
  ///
  /// In ja, this message translates to:
  /// **'Claude を使う場合は ANTHROPIC_API_KEY を設定'**
  String get guideBridgePrereq2;

  /// No description provided for @guideBridgePrereq3.
  ///
  /// In ja, this message translates to:
  /// **'Codex を使う場合は Codex の認証を完了'**
  String get guideBridgePrereq3;

  /// No description provided for @guideBridgeStep1.
  ///
  /// In ja, this message translates to:
  /// **'npx で実行（推奨）'**
  String get guideBridgeStep1;

  /// No description provided for @guideBridgeStep1Command.
  ///
  /// In ja, this message translates to:
  /// **'npx --yes @ccpocket/bridge@latest'**
  String get guideBridgeStep1Command;

  /// No description provided for @guideBridgeStep2.
  ///
  /// In ja, this message translates to:
  /// **'またはグローバルインストール'**
  String get guideBridgeStep2;

  /// No description provided for @guideBridgeStep2Command.
  ///
  /// In ja, this message translates to:
  /// **'npm install -g @ccpocket/bridge\nccpocket-bridge'**
  String get guideBridgeStep2Command;

  /// No description provided for @guideBridgeQrNote.
  ///
  /// In ja, this message translates to:
  /// **'起動するとターミナルに QR コードが表示されます'**
  String get guideBridgeQrNote;

  /// No description provided for @guideConnectionTitle.
  ///
  /// In ja, this message translates to:
  /// **'接続方法'**
  String get guideConnectionTitle;

  /// No description provided for @guideConnectionDescription.
  ///
  /// In ja, this message translates to:
  /// **'同じ Wi-Fi ネットワーク内なら、すぐに接続できます。'**
  String get guideConnectionDescription;

  /// No description provided for @guideConnectionQr.
  ///
  /// In ja, this message translates to:
  /// **'QR コードスキャン'**
  String get guideConnectionQr;

  /// No description provided for @guideConnectionQrDescription.
  ///
  /// In ja, this message translates to:
  /// **'ターミナルに表示された QR コードを読み取るだけ。一番簡単です。'**
  String get guideConnectionQrDescription;

  /// No description provided for @guideConnectionMdns.
  ///
  /// In ja, this message translates to:
  /// **'自動検出 (mDNS)'**
  String get guideConnectionMdns;

  /// No description provided for @guideConnectionMdnsDescription.
  ///
  /// In ja, this message translates to:
  /// **'同一 LAN 内の Bridge Server を自動で見つけて表示します。'**
  String get guideConnectionMdnsDescription;

  /// No description provided for @guideConnectionManual.
  ///
  /// In ja, this message translates to:
  /// **'手動入力'**
  String get guideConnectionManual;

  /// No description provided for @guideConnectionManualDescription.
  ///
  /// In ja, this message translates to:
  /// **'ws://<IP アドレス>:8765 の形式で直接入力します。'**
  String get guideConnectionManualDescription;

  /// No description provided for @guideConnectionRecommended.
  ///
  /// In ja, this message translates to:
  /// **'おすすめ'**
  String get guideConnectionRecommended;

  /// No description provided for @guideTailscaleTitle.
  ///
  /// In ja, this message translates to:
  /// **'外出先からの接続'**
  String get guideTailscaleTitle;

  /// No description provided for @guideTailscaleDescription.
  ///
  /// In ja, this message translates to:
  /// **'自宅の外からも使いたい場合は、Tailscale（VPN の一種）を使えば安全にリモート接続できます。'**
  String get guideTailscaleDescription;

  /// No description provided for @guideTailscaleStep1.
  ///
  /// In ja, this message translates to:
  /// **'Mac と iPhone の両方に Tailscale をインストール'**
  String get guideTailscaleStep1;

  /// No description provided for @guideTailscaleStep2.
  ///
  /// In ja, this message translates to:
  /// **'同じアカウントでログイン'**
  String get guideTailscaleStep2;

  /// No description provided for @guideTailscaleStep3.
  ///
  /// In ja, this message translates to:
  /// **'Bridge URL に Tailscale IP を使用\n(例: ws://100.x.x.x:8765)'**
  String get guideTailscaleStep3;

  /// No description provided for @guideTailscaleWebsite.
  ///
  /// In ja, this message translates to:
  /// **'Tailscale 公式サイト'**
  String get guideTailscaleWebsite;

  /// No description provided for @guideTailscaleWebsiteHint.
  ///
  /// In ja, this message translates to:
  /// **'詳しいセットアップ方法は公式サイトをご覧ください。'**
  String get guideTailscaleWebsiteHint;

  /// No description provided for @guideLaunchdTitle.
  ///
  /// In ja, this message translates to:
  /// **'常時起動の設定'**
  String get guideLaunchdTitle;

  /// No description provided for @guideLaunchdDescription.
  ///
  /// In ja, this message translates to:
  /// **'毎回手動で Bridge Server を起動するのが面倒な場合、マシンの起動時に自動で立ち上がるよう設定できます。'**
  String get guideLaunchdDescription;

  /// No description provided for @guideLaunchdCommand.
  ///
  /// In ja, this message translates to:
  /// **'セットアップコマンド'**
  String get guideLaunchdCommand;

  /// No description provided for @guideLaunchdCommandValue.
  ///
  /// In ja, this message translates to:
  /// **'npx --yes @ccpocket/bridge@latest setup'**
  String get guideLaunchdCommandValue;

  /// No description provided for @guideLaunchdRecommendation.
  ///
  /// In ja, this message translates to:
  /// **'まずは手動起動で動作確認してから、安定したらサービス登録がおすすめです。'**
  String get guideLaunchdRecommendation;

  /// No description provided for @guideAutostartMacDescription.
  ///
  /// In ja, this message translates to:
  /// **'launchd に登録。シェル環境（nvm、Homebrew 等）が自動で引き継がれます。'**
  String get guideAutostartMacDescription;

  /// No description provided for @guideAutostartLinuxDescription.
  ///
  /// In ja, this message translates to:
  /// **'systemd ユーザーサービスを作成。Raspberry Pi 等の Linux ホストに対応。'**
  String get guideAutostartLinuxDescription;

  /// No description provided for @guideReadyTitle.
  ///
  /// In ja, this message translates to:
  /// **'準備完了!'**
  String get guideReadyTitle;

  /// No description provided for @guideReadyDescription.
  ///
  /// In ja, this message translates to:
  /// **'Bridge Server を起動して、\nQR コードをスキャンするところから\n始めましょう。'**
  String get guideReadyDescription;

  /// No description provided for @guideReadyStart.
  ///
  /// In ja, this message translates to:
  /// **'さっそく始める'**
  String get guideReadyStart;

  /// No description provided for @guideReadyHint.
  ///
  /// In ja, this message translates to:
  /// **'このガイドは設定画面からいつでも確認できます'**
  String get guideReadyHint;

  /// No description provided for @creatingSession.
  ///
  /// In ja, this message translates to:
  /// **'セッション作成中...'**
  String get creatingSession;

  /// No description provided for @resolvingLinkedSession.
  ///
  /// In ja, this message translates to:
  /// **'リンク先のセッションを検索しています...'**
  String get resolvingLinkedSession;

  /// No description provided for @resumingLinkedSession.
  ///
  /// In ja, this message translates to:
  /// **'セッションを再開しています...'**
  String get resumingLinkedSession;

  /// No description provided for @sessionLinkProgressStage.
  ///
  /// In ja, this message translates to:
  /// **'{stage, select, waiting_for_connection{Bridge に接続しています...} waiting_for_identity{データソースを確認しています...} request_sent{セッション要求を送信しています...} request_accepted{Bridge が要求を受け付けました...} runtime_checked{実行中のセッションを確認しています...} catalog_scanning{セッション一覧を検索しています...} catalog_scanned{セッション一覧を確認しました...} resolution_ready{セッションが見つかりました...} resume_lock_waiting{セッションへのアクセスを待っています...} resume_lock_acquired{セッションへのアクセスを取得しました...} history_reading{最近の履歴を読み込んでいます...} history_read{最近の履歴を読み込みました...} runtime_starting{セッションを起動しています...} metadata_loading{セッション情報を読み込んでいます...} ready{セッションを開いています...} other{セッションを読み込んでいます...}}'**
  String sessionLinkProgressStage(String stage);

  /// No description provided for @sessionUnavailableTitle.
  ///
  /// In ja, this message translates to:
  /// **'セッションを利用できません'**
  String get sessionUnavailableTitle;

  /// No description provided for @sessionUnavailableDescription.
  ///
  /// In ja, this message translates to:
  /// **'このセッションは現在の Bridge では利用できません。最近のセッションから開いてください。'**
  String get sessionUnavailableDescription;

  /// No description provided for @openRecentSessions.
  ///
  /// In ja, this message translates to:
  /// **'最近のセッションを開く'**
  String get openRecentSessions;

  /// No description provided for @copyForAgent.
  ///
  /// In ja, this message translates to:
  /// **'エージェント用にコピー'**
  String get copyForAgent;

  /// No description provided for @messageHistory.
  ///
  /// In ja, this message translates to:
  /// **'メッセージ履歴'**
  String get messageHistory;

  /// No description provided for @viewChanges.
  ///
  /// In ja, this message translates to:
  /// **'変更を確認'**
  String get viewChanges;

  /// No description provided for @screenshot.
  ///
  /// In ja, this message translates to:
  /// **'スクリーンショット'**
  String get screenshot;

  /// No description provided for @screenshotSaved.
  ///
  /// In ja, this message translates to:
  /// **'スクリーンショットを保存しました'**
  String get screenshotSaved;

  /// No description provided for @screenshotFailed.
  ///
  /// In ja, this message translates to:
  /// **'スクリーンショットの保存に失敗しました'**
  String get screenshotFailed;

  /// No description provided for @fullScreen.
  ///
  /// In ja, this message translates to:
  /// **'フルスクリーン'**
  String get fullScreen;

  /// No description provided for @captureEntireDesktop.
  ///
  /// In ja, this message translates to:
  /// **'デスクトップ全体を撮影'**
  String get captureEntireDesktop;

  /// No description provided for @noWindowsFound.
  ///
  /// In ja, this message translates to:
  /// **'ウインドウが見つかりません'**
  String get noWindowsFound;

  /// No description provided for @debug.
  ///
  /// In ja, this message translates to:
  /// **'デバッグ'**
  String get debug;

  /// No description provided for @logs.
  ///
  /// In ja, this message translates to:
  /// **'ログ'**
  String get logs;

  /// No description provided for @viewApplicationLogs.
  ///
  /// In ja, this message translates to:
  /// **'アプリケーションログを表示'**
  String get viewApplicationLogs;

  /// No description provided for @mockPreview.
  ///
  /// In ja, this message translates to:
  /// **'モックプレビュー'**
  String get mockPreview;

  /// No description provided for @viewMockChatScenarios.
  ///
  /// In ja, this message translates to:
  /// **'モックチャットシナリオを表示'**
  String get viewMockChatScenarios;

  /// No description provided for @updateTrack.
  ///
  /// In ja, this message translates to:
  /// **'アップデートトラック'**
  String get updateTrack;

  /// No description provided for @updateTrackDescription.
  ///
  /// In ja, this message translates to:
  /// **'変更後にアプリを再起動すると反映されます'**
  String get updateTrackDescription;

  /// No description provided for @updateTrackStable.
  ///
  /// In ja, this message translates to:
  /// **'Stable（安定版）'**
  String get updateTrackStable;

  /// No description provided for @updateTrackStaging.
  ///
  /// In ja, this message translates to:
  /// **'Staging（テスト）'**
  String get updateTrackStaging;

  /// No description provided for @updateDownloaded.
  ///
  /// In ja, this message translates to:
  /// **'アップデートをダウンロードしました。アプリを再起動すると反映されます。'**
  String get updateDownloaded;

  /// No description provided for @promptHistory.
  ///
  /// In ja, this message translates to:
  /// **'プロンプト履歴'**
  String get promptHistory;

  /// No description provided for @frequent.
  ///
  /// In ja, this message translates to:
  /// **'頻度順'**
  String get frequent;

  /// No description provided for @recent.
  ///
  /// In ja, this message translates to:
  /// **'新しい順'**
  String get recent;

  /// No description provided for @searchHint.
  ///
  /// In ja, this message translates to:
  /// **'検索...'**
  String get searchHint;

  /// No description provided for @noMatchingPrompts.
  ///
  /// In ja, this message translates to:
  /// **'一致するプロンプトがありません'**
  String get noMatchingPrompts;

  /// No description provided for @noPromptHistoryYet.
  ///
  /// In ja, this message translates to:
  /// **'プロンプト履歴はまだありません'**
  String get noPromptHistoryYet;

  /// No description provided for @promptHistoryFilters.
  ///
  /// In ja, this message translates to:
  /// **'フィルター'**
  String get promptHistoryFilters;

  /// No description provided for @promptHistoryFilterThisDevice.
  ///
  /// In ja, this message translates to:
  /// **'この端末で使った履歴'**
  String get promptHistoryFilterThisDevice;

  /// No description provided for @promptHistoryFilterThisProject.
  ///
  /// In ja, this message translates to:
  /// **'開いているプロジェクト'**
  String get promptHistoryFilterThisProject;

  /// No description provided for @promptHistoryFilterThisBridge.
  ///
  /// In ja, this message translates to:
  /// **'接続中のBridge'**
  String get promptHistoryFilterThisBridge;

  /// No description provided for @promptHistoryFilterFavorites.
  ///
  /// In ja, this message translates to:
  /// **'お気に入り'**
  String get promptHistoryFilterFavorites;

  /// No description provided for @promptHistoryFilterCommands.
  ///
  /// In ja, this message translates to:
  /// **'コマンドとスキル'**
  String get promptHistoryFilterCommands;

  /// No description provided for @promptHistoryOpenProjectEmptyHint.
  ///
  /// In ja, this message translates to:
  /// **'開いているプロジェクトのフィルターは、新しいアプリで記録した履歴にのみ有効です。'**
  String get promptHistoryOpenProjectEmptyHint;

  /// No description provided for @promptHistorySectionTitle.
  ///
  /// In ja, this message translates to:
  /// **'プロンプト履歴'**
  String get promptHistorySectionTitle;

  /// No description provided for @promptHistorySyncTitle.
  ///
  /// In ja, this message translates to:
  /// **'プロンプト履歴を同期'**
  String get promptHistorySyncTitle;

  /// No description provided for @promptHistoryReplaceTitle.
  ///
  /// In ja, this message translates to:
  /// **'旧方式履歴でBridgeを上書き'**
  String get promptHistoryReplaceTitle;

  /// No description provided for @promptHistoryReplaceSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'旧方式履歴はアプリ側で管理されていました。新方式ではBridge側で履歴を管理します。メイン端末で移行済みの場合は通常不要です。サブ端末でBridgeの履歴を初期化してしまった場合に、接続中のBridge履歴をこの端末の旧方式履歴で上書きします。'**
  String get promptHistoryReplaceSubtitle;

  /// No description provided for @promptHistoryReplaceConfirmAction.
  ///
  /// In ja, this message translates to:
  /// **'上書き'**
  String get promptHistoryReplaceConfirmAction;

  /// No description provided for @promptHistoryReplaceDismissAction.
  ///
  /// In ja, this message translates to:
  /// **'移行済みとして非表示'**
  String get promptHistoryReplaceDismissAction;

  /// No description provided for @promptHistoryNotSyncedYet.
  ///
  /// In ja, this message translates to:
  /// **'まだ同期していません'**
  String get promptHistoryNotSyncedYet;

  /// No description provided for @promptHistoryLatestSync.
  ///
  /// In ja, this message translates to:
  /// **'最終同期: {time}'**
  String promptHistoryLatestSync(String time);

  /// No description provided for @promptHistorySyncedBridges.
  ///
  /// In ja, this message translates to:
  /// **'{count}件のBridgeを同期済み'**
  String promptHistorySyncedBridges(int count);

  /// No description provided for @promptHistorySyncSummaryWithFailures.
  ///
  /// In ja, this message translates to:
  /// **'{synced}件同期、{failed}件失敗'**
  String promptHistorySyncSummaryWithFailures(int synced, int failed);

  /// No description provided for @promptHistoryBridgeId.
  ///
  /// In ja, this message translates to:
  /// **'Bridge ID: {id}'**
  String promptHistoryBridgeId(String id);

  /// No description provided for @promptHistoryOtherBridgeRegistrations.
  ///
  /// In ja, this message translates to:
  /// **'他の登録: {registrations}'**
  String promptHistoryOtherBridgeRegistrations(String registrations);

  /// No description provided for @promptHistoryNoSyncTime.
  ///
  /// In ja, this message translates to:
  /// **'同期時刻なし'**
  String get promptHistoryNoSyncTime;

  /// No description provided for @approvalQueue.
  ///
  /// In ja, this message translates to:
  /// **'承認キュー'**
  String get approvalQueue;

  /// No description provided for @resetQueue.
  ///
  /// In ja, this message translates to:
  /// **'キューをリセット'**
  String get resetQueue;

  /// No description provided for @swipeSkip.
  ///
  /// In ja, this message translates to:
  /// **'スキップ'**
  String get swipeSkip;

  /// No description provided for @swipeSend.
  ///
  /// In ja, this message translates to:
  /// **'送信'**
  String get swipeSend;

  /// No description provided for @swipeDismiss.
  ///
  /// In ja, this message translates to:
  /// **'却下'**
  String get swipeDismiss;

  /// No description provided for @swipeApprove.
  ///
  /// In ja, this message translates to:
  /// **'承認'**
  String get swipeApprove;

  /// No description provided for @swipeReject.
  ///
  /// In ja, this message translates to:
  /// **'拒否'**
  String get swipeReject;

  /// No description provided for @allClear.
  ///
  /// In ja, this message translates to:
  /// **'すべて完了!'**
  String get allClear;

  /// No description provided for @itemsProcessed.
  ///
  /// In ja, this message translates to:
  /// **'{count} 件処理しました'**
  String itemsProcessed(int count);

  /// No description provided for @bestStreak.
  ///
  /// In ja, this message translates to:
  /// **'最高連続: {count}'**
  String bestStreak(int count);

  /// No description provided for @tryAgain.
  ///
  /// In ja, this message translates to:
  /// **'もう一度'**
  String get tryAgain;

  /// No description provided for @waitingForTasks.
  ///
  /// In ja, this message translates to:
  /// **'タスク待ち'**
  String get waitingForTasks;

  /// No description provided for @agentReadyForPrompt.
  ///
  /// In ja, this message translates to:
  /// **'エージェントは次のプロンプトを待っています。'**
  String get agentReadyForPrompt;

  /// No description provided for @backToSessions.
  ///
  /// In ja, this message translates to:
  /// **'セッション一覧に戻る'**
  String get backToSessions;

  /// No description provided for @working.
  ///
  /// In ja, this message translates to:
  /// **'処理中...'**
  String get working;

  /// No description provided for @waitingForApprovalRequests.
  ///
  /// In ja, this message translates to:
  /// **'エージェントからの承認リクエストを待っています。'**
  String get waitingForApprovalRequests;

  /// No description provided for @noActiveSessions.
  ///
  /// In ja, this message translates to:
  /// **'アクティブなセッションがありません'**
  String get noActiveSessions;

  /// No description provided for @startSessionToBegin.
  ///
  /// In ja, this message translates to:
  /// **'セッションを開始して承認リクエストの受信を始めましょう。'**
  String get startSessionToBegin;

  /// No description provided for @settingsTitle.
  ///
  /// In ja, this message translates to:
  /// **'設定'**
  String get settingsTitle;

  /// No description provided for @sectionGeneral.
  ///
  /// In ja, this message translates to:
  /// **'一般'**
  String get sectionGeneral;

  /// No description provided for @sectionConnectionAccounts.
  ///
  /// In ja, this message translates to:
  /// **'接続とアカウント'**
  String get sectionConnectionAccounts;

  /// No description provided for @sectionNotifications.
  ///
  /// In ja, this message translates to:
  /// **'通知'**
  String get sectionNotifications;

  /// No description provided for @sectionSupport.
  ///
  /// In ja, this message translates to:
  /// **'応援'**
  String get sectionSupport;

  /// No description provided for @sectionEditor.
  ///
  /// In ja, this message translates to:
  /// **'エディタ'**
  String get sectionEditor;

  /// No description provided for @textDensity.
  ///
  /// In ja, this message translates to:
  /// **'表示密度'**
  String get textDensity;

  /// No description provided for @textDensityDescription.
  ///
  /// In ja, this message translates to:
  /// **'OSの文字サイズ設定に、このアプリ倍率をさらに掛けます。100%はOS設定のままです。'**
  String get textDensityDescription;

  /// No description provided for @codeFontSize.
  ///
  /// In ja, this message translates to:
  /// **'コード文字サイズ'**
  String get codeFontSize;

  /// No description provided for @codeFontFamily.
  ///
  /// In ja, this message translates to:
  /// **'コードフォント'**
  String get codeFontFamily;

  /// No description provided for @codeFontPreview.
  ///
  /// In ja, this message translates to:
  /// **'プレビュー'**
  String get codeFontPreview;

  /// No description provided for @indentSize.
  ///
  /// In ja, this message translates to:
  /// **'インデント幅'**
  String get indentSize;

  /// No description provided for @indentSizeSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'箇条書きのインデントに使用するスペース数'**
  String get indentSizeSubtitle;

  /// No description provided for @gitDiffInteractionMode.
  ///
  /// In ja, this message translates to:
  /// **'Git diff 操作'**
  String get gitDiffInteractionMode;

  /// No description provided for @gitDiffQuickActions.
  ///
  /// In ja, this message translates to:
  /// **'クイック操作'**
  String get gitDiffQuickActions;

  /// No description provided for @gitDiffQuickActionsDescription.
  ///
  /// In ja, this message translates to:
  /// **'1本指の横スワイプで hunk の Stage / Unstage / Revert を実行します。長い行は折り返します。'**
  String get gitDiffQuickActionsDescription;

  /// No description provided for @gitDiffScrollFirst.
  ///
  /// In ja, this message translates to:
  /// **'横スクロール優先'**
  String get gitDiffScrollFirst;

  /// No description provided for @gitDiffScrollFirstDescription.
  ///
  /// In ja, this message translates to:
  /// **'長い行を折り返さず、hunk 単位で横スクロールできます。Git 操作はロングタップのメニューまたは下部ボタンから実行します。'**
  String get gitDiffScrollFirstDescription;

  /// No description provided for @imagePasteShortcut.
  ///
  /// In ja, this message translates to:
  /// **'画像ペーストのショートカット'**
  String get imagePasteShortcut;

  /// No description provided for @imagePasteShortcutCtrlV.
  ///
  /// In ja, this message translates to:
  /// **'Ctrl+V'**
  String get imagePasteShortcutCtrlV;

  /// No description provided for @imagePasteShortcutCtrlVDescription.
  ///
  /// In ja, this message translates to:
  /// **'macOS で推奨。Cmd+V を通常のペーストや音声入力ツール用に残します。'**
  String get imagePasteShortcutCtrlVDescription;

  /// No description provided for @imagePasteShortcutCommandV.
  ///
  /// In ja, this message translates to:
  /// **'Cmd+V'**
  String get imagePasteShortcutCommandV;

  /// No description provided for @imagePasteShortcutCommandVDescription.
  ///
  /// In ja, this message translates to:
  /// **'音声入力アプリ、クリップボード管理アプリ、テキスト展開ツールと競合する可能性があります。'**
  String get imagePasteShortcutCommandVDescription;

  /// No description provided for @gitDiffFocusAutoLandscape.
  ///
  /// In ja, this message translates to:
  /// **'diff集中モードで横画面にする'**
  String get gitDiffFocusAutoLandscape;

  /// No description provided for @gitDiffFocusAutoLandscapeDescription.
  ///
  /// In ja, this message translates to:
  /// **'モバイルレイアウトでは、diff集中モードに入ると横画面に固定します。解除すると通常の回転に戻ります。'**
  String get gitDiffFocusAutoLandscapeDescription;

  /// No description provided for @remoteGitStatusBadge.
  ///
  /// In ja, this message translates to:
  /// **'未同期のGitコミットを薄いバッジで表示'**
  String get remoteGitStatusBadge;

  /// No description provided for @remoteGitStatusBadgeDescription.
  ///
  /// In ja, this message translates to:
  /// **'fetch後に現在ブランチがpushまたはpull可能な場合、セッション画面のGitボタンに薄いバッジを表示します。'**
  String get remoteGitStatusBadgeDescription;

  /// No description provided for @sectionAbout.
  ///
  /// In ja, this message translates to:
  /// **'概要'**
  String get sectionAbout;

  /// No description provided for @theme.
  ///
  /// In ja, this message translates to:
  /// **'テーマ'**
  String get theme;

  /// No description provided for @themeSystem.
  ///
  /// In ja, this message translates to:
  /// **'システム'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In ja, this message translates to:
  /// **'ライト'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In ja, this message translates to:
  /// **'ダーク'**
  String get themeDark;

  /// No description provided for @appIconTitle.
  ///
  /// In ja, this message translates to:
  /// **'アプリアイコン'**
  String get appIconTitle;

  /// No description provided for @appIconMonthlySupporterPerk.
  ///
  /// In ja, this message translates to:
  /// **'月額サポーター特典です。'**
  String get appIconMonthlySupporterPerk;

  /// No description provided for @appIconSettingsSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'{device}のホーム画面に表示されるアイコンを変更できます。'**
  String appIconSettingsSubtitle(String device);

  /// No description provided for @appIconSupporterDialogTitle.
  ///
  /// In ja, this message translates to:
  /// **'月額サポーター特典'**
  String get appIconSupporterDialogTitle;

  /// No description provided for @appIconSupporterSectionLabel.
  ///
  /// In ja, this message translates to:
  /// **'月額サポーター特典'**
  String get appIconSupporterSectionLabel;

  /// No description provided for @appIconPickerTitle.
  ///
  /// In ja, this message translates to:
  /// **'アプリアイコンを選ぶ'**
  String get appIconPickerTitle;

  /// No description provided for @appIconPickerSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'ホーム画面に表示するアイコンを選べます。'**
  String get appIconPickerSubtitle;

  /// No description provided for @appIconOptionDefaultTitle.
  ///
  /// In ja, this message translates to:
  /// **'ダーク'**
  String get appIconOptionDefaultTitle;

  /// No description provided for @appIconOptionDefaultSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'通常の CC Pocket アイコンです。'**
  String get appIconOptionDefaultSubtitle;

  /// No description provided for @appIconOptionLightOutlineTitle.
  ///
  /// In ja, this message translates to:
  /// **'ライト'**
  String get appIconOptionLightOutlineTitle;

  /// No description provided for @appIconOptionLightOutlineSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'軽やかなラインが映える明るめのバリエーション。'**
  String get appIconOptionLightOutlineSubtitle;

  /// No description provided for @appIconOptionCopperEmeraldTitle.
  ///
  /// In ja, this message translates to:
  /// **'メタリック'**
  String get appIconOptionCopperEmeraldTitle;

  /// No description provided for @appIconOptionCopperEmeraldSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'光沢感のある特別版。'**
  String get appIconOptionCopperEmeraldSubtitle;

  /// No description provided for @language.
  ///
  /// In ja, this message translates to:
  /// **'言語'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In ja, this message translates to:
  /// **'端末の設定に従う'**
  String get languageSystem;

  /// No description provided for @voiceInput.
  ///
  /// In ja, this message translates to:
  /// **'音声入力'**
  String get voiceInput;

  /// No description provided for @pushNotifications.
  ///
  /// In ja, this message translates to:
  /// **'プッシュ通知'**
  String get pushNotifications;

  /// No description provided for @pushNotificationsSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'Bridge 経由でセッション通知を受け取ります'**
  String get pushNotificationsSubtitle;

  /// No description provided for @pushNotificationsUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'Firebase 設定後に利用できます'**
  String get pushNotificationsUnavailable;

  /// No description provided for @version.
  ///
  /// In ja, this message translates to:
  /// **'バージョン'**
  String get version;

  /// No description provided for @loading.
  ///
  /// In ja, this message translates to:
  /// **'読み込み中...'**
  String get loading;

  /// No description provided for @setupGuideSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'初めての方はこちら'**
  String get setupGuideSubtitle;

  /// No description provided for @openSourceLicenses.
  ///
  /// In ja, this message translates to:
  /// **'オープンソースライセンス'**
  String get openSourceLicenses;

  /// No description provided for @githubRepository.
  ///
  /// In ja, this message translates to:
  /// **'GitHub リポジトリ'**
  String get githubRepository;

  /// No description provided for @changelog.
  ///
  /// In ja, this message translates to:
  /// **'変更履歴'**
  String get changelog;

  /// No description provided for @changelogTitle.
  ///
  /// In ja, this message translates to:
  /// **'変更履歴'**
  String get changelogTitle;

  /// No description provided for @showAllMain.
  ///
  /// In ja, this message translates to:
  /// **'すべて表示 (main)'**
  String get showAllMain;

  /// No description provided for @changelogFetchError.
  ///
  /// In ja, this message translates to:
  /// **'変更履歴の取得に失敗しました'**
  String get changelogFetchError;

  /// No description provided for @fcmBridgeNotInitialized.
  ///
  /// In ja, this message translates to:
  /// **'Bridge が未初期化です'**
  String get fcmBridgeNotInitialized;

  /// No description provided for @fcmTokenFailed.
  ///
  /// In ja, this message translates to:
  /// **'FCM token を取得できませんでした'**
  String get fcmTokenFailed;

  /// No description provided for @fcmEnabled.
  ///
  /// In ja, this message translates to:
  /// **'通知を有効化しました'**
  String get fcmEnabled;

  /// No description provided for @fcmEnabledPending.
  ///
  /// In ja, this message translates to:
  /// **'Bridge 再接続後に通知登録します'**
  String get fcmEnabledPending;

  /// No description provided for @fcmDisabled.
  ///
  /// In ja, this message translates to:
  /// **'通知を無効化しました'**
  String get fcmDisabled;

  /// No description provided for @fcmDisabledPending.
  ///
  /// In ja, this message translates to:
  /// **'Bridge 再接続後に通知解除します'**
  String get fcmDisabledPending;

  /// No description provided for @pushPrivacyMode.
  ///
  /// In ja, this message translates to:
  /// **'プライバシーモード'**
  String get pushPrivacyMode;

  /// No description provided for @pushPrivacyModeSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'通知にプロジェクト名や内容を含めない'**
  String get pushPrivacyModeSubtitle;

  /// No description provided for @updateNotificationLanguage.
  ///
  /// In ja, this message translates to:
  /// **'通知言語を更新'**
  String get updateNotificationLanguage;

  /// No description provided for @notificationLanguageUpdated.
  ///
  /// In ja, this message translates to:
  /// **'通知言語を更新しました'**
  String get notificationLanguageUpdated;

  /// No description provided for @defaultNotRecommended.
  ///
  /// In ja, this message translates to:
  /// **'Default（非推奨）'**
  String get defaultNotRecommended;

  /// No description provided for @imageAttached.
  ///
  /// In ja, this message translates to:
  /// **'画像添付'**
  String get imageAttached;

  /// No description provided for @usageConnectToView.
  ///
  /// In ja, this message translates to:
  /// **'Bridge に接続すると利用量を表示できます'**
  String get usageConnectToView;

  /// No description provided for @usageFetchFailed.
  ///
  /// In ja, this message translates to:
  /// **'取得に失敗しました'**
  String get usageFetchFailed;

  /// No description provided for @usageFiveHour.
  ///
  /// In ja, this message translates to:
  /// **'5時間'**
  String get usageFiveHour;

  /// No description provided for @usageSevenDay.
  ///
  /// In ja, this message translates to:
  /// **'7日間'**
  String get usageSevenDay;

  /// No description provided for @settingsUsageSectionTitle.
  ///
  /// In ja, this message translates to:
  /// **'利用量'**
  String get settingsUsageSectionTitle;

  /// No description provided for @settingsUsageNoCodexData.
  ///
  /// In ja, this message translates to:
  /// **'Codex の利用量データが見つかりませんでした。'**
  String get settingsUsageNoCodexData;

  /// No description provided for @usageDisplayModeRemaining.
  ///
  /// In ja, this message translates to:
  /// **'残量'**
  String get usageDisplayModeRemaining;

  /// No description provided for @usageDisplayModeUsed.
  ///
  /// In ja, this message translates to:
  /// **'使用量'**
  String get usageDisplayModeUsed;

  /// No description provided for @settingsClaudeUsageDescription.
  ///
  /// In ja, this message translates to:
  /// **'Claude の公式課金ページをブラウザで開きます。'**
  String get settingsClaudeUsageDescription;

  /// No description provided for @settingsClaudeApiBilling.
  ///
  /// In ja, this message translates to:
  /// **'API キーの課金'**
  String get settingsClaudeApiBilling;

  /// No description provided for @settingsClaudeSubscriptionUsage.
  ///
  /// In ja, this message translates to:
  /// **'サブスクリプション利用状況'**
  String get settingsClaudeSubscriptionUsage;

  /// No description provided for @settingsNewSessionTabs.
  ///
  /// In ja, this message translates to:
  /// **'新規セッションタブ'**
  String get settingsNewSessionTabs;

  /// No description provided for @settingsNewSessionTabsDescription.
  ///
  /// In ja, this message translates to:
  /// **'新規セッションで表示する AI ツールの選択肢と並び順を変更できます。'**
  String get settingsNewSessionTabsDescription;

  /// No description provided for @showBridgeNameInSessionList.
  ///
  /// In ja, this message translates to:
  /// **'Bridge名を表示'**
  String get showBridgeNameInSessionList;

  /// No description provided for @showBridgeNameInSessionListSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'複数のBridgeが登録されているとき、接続中のBridge名をセッション一覧に表示します。'**
  String get showBridgeNameInSessionListSubtitle;

  /// No description provided for @autoRenameCodexSessions.
  ///
  /// In ja, this message translates to:
  /// **'自動Rename (Codex)'**
  String get autoRenameCodexSessions;

  /// No description provided for @autoRenameCodexSessionsSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'最初のエージェント応答後に Codex セッションへ自動で名前を付ける'**
  String get autoRenameCodexSessionsSubtitle;

  /// No description provided for @showExtendedCodexEfforts.
  ///
  /// In ja, this message translates to:
  /// **'Effortスライダーに Max / Ultra を表示'**
  String get showExtendedCodexEfforts;

  /// No description provided for @showExtendedCodexEffortsSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'選択した Codex モデルが対応している場合、スライダーに Max と Ultra を追加します'**
  String get showExtendedCodexEffortsSubtitle;

  /// No description provided for @autoRenameClaudeSessions.
  ///
  /// In ja, this message translates to:
  /// **'自動Rename (Claude)'**
  String get autoRenameClaudeSessions;

  /// No description provided for @autoRenameClaudeSessionsSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'最初のエージェント応答後に Claude セッションへ自動で名前を付ける。API Key 利用時は追加の従量課金が発生します。'**
  String get autoRenameClaudeSessionsSubtitle;

  /// No description provided for @newSessionTabCodex.
  ///
  /// In ja, this message translates to:
  /// **'Codex'**
  String get newSessionTabCodex;

  /// No description provided for @newSessionTabClaudeCode.
  ///
  /// In ja, this message translates to:
  /// **'Claude'**
  String get newSessionTabClaudeCode;

  /// No description provided for @usageResetAt.
  ///
  /// In ja, this message translates to:
  /// **'リセット: {time}'**
  String usageResetAt(String time);

  /// No description provided for @usageAlreadyReset.
  ///
  /// In ja, this message translates to:
  /// **'リセット済み'**
  String get usageAlreadyReset;

  /// No description provided for @attachedImages.
  ///
  /// In ja, this message translates to:
  /// **'添付画像 ({count})'**
  String attachedImages(int count);

  /// No description provided for @attachedImagesNoCount.
  ///
  /// In ja, this message translates to:
  /// **'添付画像'**
  String get attachedImagesNoCount;

  /// No description provided for @failedToFetchImages.
  ///
  /// In ja, this message translates to:
  /// **'画像を取得できませんでした'**
  String get failedToFetchImages;

  /// No description provided for @responseTimedOut.
  ///
  /// In ja, this message translates to:
  /// **'応答がタイムアウトしました'**
  String get responseTimedOut;

  /// No description provided for @failedToFetchImagesWithError.
  ///
  /// In ja, this message translates to:
  /// **'画像の取得に失敗しました: {error}'**
  String failedToFetchImagesWithError(String error);

  /// No description provided for @retry.
  ///
  /// In ja, this message translates to:
  /// **'リトライ'**
  String get retry;

  /// No description provided for @clipboardNotAvailable.
  ///
  /// In ja, this message translates to:
  /// **'クリップボードにアクセスできません'**
  String get clipboardNotAvailable;

  /// No description provided for @failedToLoadImage.
  ///
  /// In ja, this message translates to:
  /// **'画像の読み込みに失敗しました'**
  String get failedToLoadImage;

  /// No description provided for @generatedImagePromptLabel.
  ///
  /// In ja, this message translates to:
  /// **'プロンプト'**
  String get generatedImagePromptLabel;

  /// No description provided for @generatedImageDetailsLabel.
  ///
  /// In ja, this message translates to:
  /// **'詳細'**
  String get generatedImageDetailsLabel;

  /// No description provided for @generatedImageHideDetailsLabel.
  ///
  /// In ja, this message translates to:
  /// **'詳細を閉じる'**
  String get generatedImageHideDetailsLabel;

  /// No description provided for @generatedImageStatusLabel.
  ///
  /// In ja, this message translates to:
  /// **'ステータス'**
  String get generatedImageStatusLabel;

  /// No description provided for @generatedImageSavedPathLabel.
  ///
  /// In ja, this message translates to:
  /// **'保存先'**
  String get generatedImageSavedPathLabel;

  /// No description provided for @previousImage.
  ///
  /// In ja, this message translates to:
  /// **'前の画像'**
  String get previousImage;

  /// No description provided for @nextImage.
  ///
  /// In ja, this message translates to:
  /// **'次の画像'**
  String get nextImage;

  /// No description provided for @generatedImagePositionLabel.
  ///
  /// In ja, this message translates to:
  /// **'生成画像 {current} / {total}'**
  String generatedImagePositionLabel(int current, int total);

  /// No description provided for @noImageInClipboard.
  ///
  /// In ja, this message translates to:
  /// **'クリップボードに画像がありません'**
  String get noImageInClipboard;

  /// No description provided for @failedToReadClipboard.
  ///
  /// In ja, this message translates to:
  /// **'クリップボードの読み取りに失敗しました'**
  String get failedToReadClipboard;

  /// No description provided for @imageLimitReached.
  ///
  /// In ja, this message translates to:
  /// **'画像は最大{max}枚までです'**
  String imageLimitReached(int max);

  /// No description provided for @imageLimitTruncated.
  ///
  /// In ja, this message translates to:
  /// **'最初の{max}枚のみ添付しました（{dropped}枚を除外）'**
  String imageLimitTruncated(int max, int dropped);

  /// No description provided for @selectFromGallery.
  ///
  /// In ja, this message translates to:
  /// **'ギャラリーから選択'**
  String get selectFromGallery;

  /// No description provided for @pasteFromClipboard.
  ///
  /// In ja, this message translates to:
  /// **'クリップボードから貼付'**
  String get pasteFromClipboard;

  /// No description provided for @voiceInputLanguage.
  ///
  /// In ja, this message translates to:
  /// **'音声入力の言語'**
  String get voiceInputLanguage;

  /// No description provided for @hideVoiceInput.
  ///
  /// In ja, this message translates to:
  /// **'音声入力ボタンを非表示'**
  String get hideVoiceInput;

  /// No description provided for @hideVoiceInputSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'サードパーティの音声入力キーボードを利用する場合に便利'**
  String get hideVoiceInputSubtitle;

  /// No description provided for @archive.
  ///
  /// In ja, this message translates to:
  /// **'アーカイブ'**
  String get archive;

  /// No description provided for @archiveConfirm.
  ///
  /// In ja, this message translates to:
  /// **'このセッションをアーカイブしますか？'**
  String get archiveConfirm;

  /// No description provided for @archiveConfirmMessage.
  ///
  /// In ja, this message translates to:
  /// **'セッションは一覧から非表示になります。Claude Codeからは引き続きアクセスできます。'**
  String get archiveConfirmMessage;

  /// No description provided for @sessionArchived.
  ///
  /// In ja, this message translates to:
  /// **'セッションをアーカイブしました'**
  String get sessionArchived;

  /// No description provided for @archiveFailed.
  ///
  /// In ja, this message translates to:
  /// **'セッションのアーカイブに失敗しました'**
  String get archiveFailed;

  /// No description provided for @archiveFailedWithError.
  ///
  /// In ja, this message translates to:
  /// **'セッションのアーカイブに失敗しました: {error}'**
  String archiveFailedWithError(String error);

  /// No description provided for @noRecentSessions.
  ///
  /// In ja, this message translates to:
  /// **'最近のセッションはありません'**
  String get noRecentSessions;

  /// No description provided for @noSessionsMatchFilters.
  ///
  /// In ja, this message translates to:
  /// **'現在のフィルター条件に一致するセッションがありません'**
  String get noSessionsMatchFilters;

  /// No description provided for @adjustFiltersAndSearch.
  ///
  /// In ja, this message translates to:
  /// **'フィルター条件や検索語を変更してください'**
  String get adjustFiltersAndSearch;

  /// No description provided for @tooltipDisplayMode.
  ///
  /// In ja, this message translates to:
  /// **'カードに表示するメッセージを切替'**
  String get tooltipDisplayMode;

  /// No description provided for @tooltipProviderFilter.
  ///
  /// In ja, this message translates to:
  /// **'AIツールで絞り込み'**
  String get tooltipProviderFilter;

  /// No description provided for @tooltipProjectFilter.
  ///
  /// In ja, this message translates to:
  /// **'プロジェクトで絞り込み'**
  String get tooltipProjectFilter;

  /// No description provided for @tooltipNamedOnly.
  ///
  /// In ja, this message translates to:
  /// **'名前を付けたセッションのみ'**
  String get tooltipNamedOnly;

  /// No description provided for @tooltipIndent.
  ///
  /// In ja, this message translates to:
  /// **'インデントを増やす'**
  String get tooltipIndent;

  /// No description provided for @tooltipDedent.
  ///
  /// In ja, this message translates to:
  /// **'インデントを減らす'**
  String get tooltipDedent;

  /// No description provided for @tooltipSlashCommand.
  ///
  /// In ja, this message translates to:
  /// **'コマンド・スキルを入力'**
  String get tooltipSlashCommand;

  /// No description provided for @slashCommandsTitle.
  ///
  /// In ja, this message translates to:
  /// **'コマンド'**
  String get slashCommandsTitle;

  /// No description provided for @slashCommandsProject.
  ///
  /// In ja, this message translates to:
  /// **'プロジェクト'**
  String get slashCommandsProject;

  /// No description provided for @slashCommandsSkills.
  ///
  /// In ja, this message translates to:
  /// **'スキル'**
  String get slashCommandsSkills;

  /// No description provided for @slashCommandsApps.
  ///
  /// In ja, this message translates to:
  /// **'アプリ'**
  String get slashCommandsApps;

  /// No description provided for @slashCommandsPlugins.
  ///
  /// In ja, this message translates to:
  /// **'プラグイン'**
  String get slashCommandsPlugins;

  /// No description provided for @slashCommandsBuiltIn.
  ///
  /// In ja, this message translates to:
  /// **'組み込み'**
  String get slashCommandsBuiltIn;

  /// No description provided for @slashCommandCompactDescription.
  ///
  /// In ja, this message translates to:
  /// **'会話のコンテキストを圧縮'**
  String get slashCommandCompactDescription;

  /// No description provided for @slashCommandPlanDescription.
  ///
  /// In ja, this message translates to:
  /// **'プランモードに切り替え'**
  String get slashCommandPlanDescription;

  /// No description provided for @slashCommandGoalDescription.
  ///
  /// In ja, this message translates to:
  /// **'目標を設定または管理'**
  String get slashCommandGoalDescription;

  /// No description provided for @slashCommandClearDescription.
  ///
  /// In ja, this message translates to:
  /// **'会話を消去'**
  String get slashCommandClearDescription;

  /// No description provided for @slashCommandHelpDescription.
  ///
  /// In ja, this message translates to:
  /// **'ヘルプを表示'**
  String get slashCommandHelpDescription;

  /// No description provided for @slashCommandContextDescription.
  ///
  /// In ja, this message translates to:
  /// **'コンテキスト使用量を表示'**
  String get slashCommandContextDescription;

  /// No description provided for @slashCommandCostDescription.
  ///
  /// In ja, this message translates to:
  /// **'コスト概要を表示'**
  String get slashCommandCostDescription;

  /// No description provided for @slashCommandInitDescription.
  ///
  /// In ja, this message translates to:
  /// **'プロジェクトを初期化'**
  String get slashCommandInitDescription;

  /// No description provided for @slashCommandReviewDescription.
  ///
  /// In ja, this message translates to:
  /// **'コードレビュー'**
  String get slashCommandReviewDescription;

  /// No description provided for @slashCommandModelDescription.
  ///
  /// In ja, this message translates to:
  /// **'モデルを切り替え'**
  String get slashCommandModelDescription;

  /// No description provided for @slashCommandSkillsDescription.
  ///
  /// In ja, this message translates to:
  /// **'利用可能なスキルを表示'**
  String get slashCommandSkillsDescription;

  /// No description provided for @slashCommandStatusDescription.
  ///
  /// In ja, this message translates to:
  /// **'状態を表示'**
  String get slashCommandStatusDescription;

  /// No description provided for @slashCommandMemoryDescription.
  ///
  /// In ja, this message translates to:
  /// **'CLAUDE.md を編集'**
  String get slashCommandMemoryDescription;

  /// No description provided for @slashCommandConfigDescription.
  ///
  /// In ja, this message translates to:
  /// **'設定を開く'**
  String get slashCommandConfigDescription;

  /// No description provided for @slashCommandPermissionsDescription.
  ///
  /// In ja, this message translates to:
  /// **'権限を表示'**
  String get slashCommandPermissionsDescription;

  /// No description provided for @slashCommandPrCommentsDescription.
  ///
  /// In ja, this message translates to:
  /// **'PR コメントを表示'**
  String get slashCommandPrCommentsDescription;

  /// No description provided for @slashCommandReleaseNotesDescription.
  ///
  /// In ja, this message translates to:
  /// **'リリースノートを表示'**
  String get slashCommandReleaseNotesDescription;

  /// No description provided for @slashCommandSecurityReviewDescription.
  ///
  /// In ja, this message translates to:
  /// **'セキュリティレビューを実行'**
  String get slashCommandSecurityReviewDescription;

  /// No description provided for @slashCommandResumeDescription.
  ///
  /// In ja, this message translates to:
  /// **'セッションを再開'**
  String get slashCommandResumeDescription;

  /// No description provided for @slashCommandRenameDescription.
  ///
  /// In ja, this message translates to:
  /// **'セッション名を変更'**
  String get slashCommandRenameDescription;

  /// No description provided for @slashCommandDoctorDescription.
  ///
  /// In ja, this message translates to:
  /// **'ヘルスチェックを実行'**
  String get slashCommandDoctorDescription;

  /// No description provided for @slashCommandMcpDescription.
  ///
  /// In ja, this message translates to:
  /// **'MCP サーバーを管理'**
  String get slashCommandMcpDescription;

  /// No description provided for @slashCommandExportDescription.
  ///
  /// In ja, this message translates to:
  /// **'会話をエクスポート'**
  String get slashCommandExportDescription;

  /// No description provided for @slashCommandAddDirDescription.
  ///
  /// In ja, this message translates to:
  /// **'ディレクトリを追加'**
  String get slashCommandAddDirDescription;

  /// No description provided for @slashCommandRewindDescription.
  ///
  /// In ja, this message translates to:
  /// **'前の時点に巻き戻す'**
  String get slashCommandRewindDescription;

  /// No description provided for @slashCommandVimDescription.
  ///
  /// In ja, this message translates to:
  /// **'Vim モードを有効化'**
  String get slashCommandVimDescription;

  /// No description provided for @slashCommandLoginDescription.
  ///
  /// In ja, this message translates to:
  /// **'アカウントを切り替え'**
  String get slashCommandLoginDescription;

  /// No description provided for @tooltipMention.
  ///
  /// In ja, this message translates to:
  /// **'ファイル・プラグインをメンション'**
  String get tooltipMention;

  /// No description provided for @tooltipDollarMention.
  ///
  /// In ja, this message translates to:
  /// **'スキル・アプリを入力'**
  String get tooltipDollarMention;

  /// No description provided for @tooltipPermissionMode.
  ///
  /// In ja, this message translates to:
  /// **'パーミッションモード'**
  String get tooltipPermissionMode;

  /// No description provided for @tooltipAttachImage.
  ///
  /// In ja, this message translates to:
  /// **'画像を添付'**
  String get tooltipAttachImage;

  /// No description provided for @tooltipPromptHistory.
  ///
  /// In ja, this message translates to:
  /// **'プロンプト履歴を開く'**
  String get tooltipPromptHistory;

  /// No description provided for @tooltipVoiceInput.
  ///
  /// In ja, this message translates to:
  /// **'音声入力を開始'**
  String get tooltipVoiceInput;

  /// No description provided for @tooltipStopRecording.
  ///
  /// In ja, this message translates to:
  /// **'録音を停止'**
  String get tooltipStopRecording;

  /// No description provided for @tooltipSendMessage.
  ///
  /// In ja, this message translates to:
  /// **'メッセージを送信'**
  String get tooltipSendMessage;

  /// No description provided for @tooltipRemoveImage.
  ///
  /// In ja, this message translates to:
  /// **'画像を削除'**
  String get tooltipRemoveImage;

  /// No description provided for @tooltipClearDiff.
  ///
  /// In ja, this message translates to:
  /// **'Diff選択を解除'**
  String get tooltipClearDiff;

  /// No description provided for @showMore.
  ///
  /// In ja, this message translates to:
  /// **'もっと見る'**
  String get showMore;

  /// No description provided for @showLess.
  ///
  /// In ja, this message translates to:
  /// **'閉じる'**
  String get showLess;

  /// No description provided for @authErrorTitle.
  ///
  /// In ja, this message translates to:
  /// **'Claudeの再ログインが必要です'**
  String get authErrorTitle;

  /// No description provided for @authErrorBody.
  ///
  /// In ja, this message translates to:
  /// **'BridgeマシンでClaudeに再ログインしてください。'**
  String get authErrorBody;

  /// No description provided for @authErrorPrimaryCommandLabel.
  ///
  /// In ja, this message translates to:
  /// **'手順1'**
  String get authErrorPrimaryCommandLabel;

  /// No description provided for @authErrorSecondaryCommandLabel.
  ///
  /// In ja, this message translates to:
  /// **'手順2'**
  String get authErrorSecondaryCommandLabel;

  /// No description provided for @authErrorAlternativeLabel.
  ///
  /// In ja, this message translates to:
  /// **'シェルから実行する場合'**
  String get authErrorAlternativeLabel;

  /// No description provided for @apiKeyRequiredTitle.
  ///
  /// In ja, this message translates to:
  /// **'APIキーが必要です'**
  String get apiKeyRequiredTitle;

  /// No description provided for @apiKeyRequiredBody.
  ///
  /// In ja, this message translates to:
  /// **'Anthropic の現行 Claude Agent SDK ドキュメントでは、サードパーティ製品で Claude のサブスクリプションログインを使うことは許可されていません。APIキーをご利用ください。'**
  String get apiKeyRequiredBody;

  /// No description provided for @apiKeyRequiredHint.
  ///
  /// In ja, this message translates to:
  /// **'APIキーの取得:'**
  String get apiKeyRequiredHint;

  /// No description provided for @authHelpTitle.
  ///
  /// In ja, this message translates to:
  /// **'認証トラブルシューティング'**
  String get authHelpTitle;

  /// No description provided for @authHelpFetchError.
  ///
  /// In ja, this message translates to:
  /// **'トラブルシューティングガイドを読み込めませんでした'**
  String get authHelpFetchError;

  /// No description provided for @authHelpButton.
  ///
  /// In ja, this message translates to:
  /// **'手順を見る'**
  String get authHelpButton;

  /// No description provided for @authHelpLanguageJa.
  ///
  /// In ja, this message translates to:
  /// **'日本語'**
  String get authHelpLanguageJa;

  /// No description provided for @authHelpLanguageEn.
  ///
  /// In ja, this message translates to:
  /// **'English'**
  String get authHelpLanguageEn;

  /// No description provided for @authHelpLanguageZhHans.
  ///
  /// In ja, this message translates to:
  /// **'简体中文'**
  String get authHelpLanguageZhHans;

  /// No description provided for @authHelpLanguageKo.
  ///
  /// In ja, this message translates to:
  /// **'한국어'**
  String get authHelpLanguageKo;

  /// No description provided for @terminalApp.
  ///
  /// In ja, this message translates to:
  /// **'ターミナルアプリ'**
  String get terminalApp;

  /// No description provided for @terminalAppSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'外部ターミナルアプリでプロジェクトを開く'**
  String get terminalAppSubtitle;

  /// No description provided for @terminalAppNone.
  ///
  /// In ja, this message translates to:
  /// **'未設定'**
  String get terminalAppNone;

  /// No description provided for @terminalAppCustom.
  ///
  /// In ja, this message translates to:
  /// **'カスタム'**
  String get terminalAppCustom;

  /// No description provided for @terminalAppName.
  ///
  /// In ja, this message translates to:
  /// **'アプリ名'**
  String get terminalAppName;

  /// No description provided for @terminalUrlTemplate.
  ///
  /// In ja, this message translates to:
  /// **'URL テンプレート'**
  String get terminalUrlTemplate;

  /// No description provided for @terminalUrlTemplateHint.
  ///
  /// In ja, this message translates to:
  /// **'変数: host, user, port, project_path'**
  String get terminalUrlTemplateHint;

  /// No description provided for @terminalSshUser.
  ///
  /// In ja, this message translates to:
  /// **'SSH ユーザー'**
  String get terminalSshUser;

  /// No description provided for @terminalSshUserHint.
  ///
  /// In ja, this message translates to:
  /// **'未入力時はマシンの SSH ユーザーを使用'**
  String get terminalSshUserHint;

  /// No description provided for @openInTerminal.
  ///
  /// In ja, this message translates to:
  /// **'ターミナルで開く'**
  String get openInTerminal;

  /// No description provided for @terminalAppNotInstalled.
  ///
  /// In ja, this message translates to:
  /// **'ターミナルアプリを開けませんでした'**
  String get terminalAppNotInstalled;

  /// No description provided for @terminalAppExperimental.
  ///
  /// In ja, this message translates to:
  /// **'プレビュー'**
  String get terminalAppExperimental;

  /// No description provided for @terminalAppExperimentalNote.
  ///
  /// In ja, this message translates to:
  /// **'この機能はプレビュー版です。プリセットはアプリや環境によって動作しない場合があります。新しいプリセットの追加は GitHub で歓迎しています！'**
  String get terminalAppExperimentalNote;

  /// No description provided for @sectionSpread.
  ///
  /// In ja, this message translates to:
  /// **'CC Pocket を広める'**
  String get sectionSpread;

  /// No description provided for @spreadAppealMessage.
  ///
  /// In ja, this message translates to:
  /// **'CC Pocket はまだ利用者が少なく、このままだと開発を続けるのが難しい状況です。気に入っていたら、ストア評価（星だけでOK）や知り合いへの紹介で応援してください。'**
  String get spreadAppealMessage;

  /// No description provided for @shareApp.
  ///
  /// In ja, this message translates to:
  /// **'SNSでシェア'**
  String get shareApp;

  /// No description provided for @shareAppSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'同僚や友人に紹介する'**
  String get shareAppSubtitle;

  /// No description provided for @shareText.
  ///
  /// In ja, this message translates to:
  /// **'CC Pocket: Claude & Codex\nスマホからコーディングエージェントを操作できるアプリ 📱\n#ccpocket\n{url}'**
  String shareText(String url);

  /// No description provided for @starOnGithub.
  ///
  /// In ja, this message translates to:
  /// **'GitHub にスターする'**
  String get starOnGithub;

  /// No description provided for @rateOnStore.
  ///
  /// In ja, this message translates to:
  /// **'App Store で評価する'**
  String get rateOnStore;

  /// No description provided for @rateOnStoreAndroid.
  ///
  /// In ja, this message translates to:
  /// **'Google Play で評価する'**
  String get rateOnStoreAndroid;

  /// No description provided for @supporterTitle.
  ///
  /// In ja, this message translates to:
  /// **'サポーター'**
  String get supporterTitle;

  /// No description provided for @supporterMonthlyTitle.
  ///
  /// In ja, this message translates to:
  /// **'月額サポーター'**
  String get supporterMonthlyTitle;

  /// No description provided for @supporterMonthlyPlusTitle.
  ///
  /// In ja, this message translates to:
  /// **'月額サポーター Plus'**
  String get supporterMonthlyPlusTitle;

  /// No description provided for @supporterSnackTitle.
  ///
  /// In ja, this message translates to:
  /// **'おやつで応援'**
  String get supporterSnackTitle;

  /// No description provided for @supporterCoffeeTitle.
  ///
  /// In ja, this message translates to:
  /// **'ドリンクで応援'**
  String get supporterCoffeeTitle;

  /// No description provided for @supporterLunchTitle.
  ///
  /// In ja, this message translates to:
  /// **'ランチで応援'**
  String get supporterLunchTitle;

  /// No description provided for @supporterStatusActive.
  ///
  /// In ja, this message translates to:
  /// **'CC Pocket を応援してくれてありがとうございます。'**
  String get supporterStatusActive;

  /// No description provided for @supporterStatusInactive.
  ///
  /// In ja, this message translates to:
  /// **'アプリは無料のまま。継続開発を応援できます。'**
  String get supporterStatusInactive;

  /// No description provided for @supporterStatusLoading.
  ///
  /// In ja, this message translates to:
  /// **'応援状態を確認しています...'**
  String get supporterStatusLoading;

  /// No description provided for @supportEntryInactiveTitle.
  ///
  /// In ja, this message translates to:
  /// **'応援する'**
  String get supportEntryInactiveTitle;

  /// No description provided for @supportEntryInactiveSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'CC Pocket が気に入ったら、継続開発を応援してもらえるとうれしいです。'**
  String get supportEntryInactiveSubtitle;

  /// No description provided for @supportEntryOneTimeTitle.
  ///
  /// In ja, this message translates to:
  /// **'応援ありがとう'**
  String get supportEntryOneTimeTitle;

  /// No description provided for @supportEntryOneTimeSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'これまでの応援、ありがとうございます。'**
  String get supportEntryOneTimeSubtitle;

  /// No description provided for @supportEntryActiveTitle.
  ///
  /// In ja, this message translates to:
  /// **'応援中'**
  String get supportEntryActiveTitle;

  /// No description provided for @supportEntryActiveSubtitle.
  ///
  /// In ja, this message translates to:
  /// **'いつもありがとうございます。{date}から応援中です。'**
  String supportEntryActiveSubtitle(String date);

  /// No description provided for @supporterMonthlyDescription.
  ///
  /// In ja, this message translates to:
  /// **'継続的な開発を後押し'**
  String get supporterMonthlyDescription;

  /// No description provided for @supporterMonthlyPerkLabel.
  ///
  /// In ja, this message translates to:
  /// **'アプリアイコン変更特典付き'**
  String get supporterMonthlyPerkLabel;

  /// No description provided for @supporterSnackDescription.
  ///
  /// In ja, this message translates to:
  /// **'おやつを1つおごる'**
  String get supporterSnackDescription;

  /// No description provided for @supporterCoffeeDescription.
  ///
  /// In ja, this message translates to:
  /// **'ドリンクを1杯おごる'**
  String get supporterCoffeeDescription;

  /// No description provided for @supporterLunchDescription.
  ///
  /// In ja, this message translates to:
  /// **'ランチを1食おごる'**
  String get supporterLunchDescription;

  /// No description provided for @supporterBuyButton.
  ///
  /// In ja, this message translates to:
  /// **'応援する'**
  String get supporterBuyButton;

  /// No description provided for @supporterActiveButton.
  ///
  /// In ja, this message translates to:
  /// **'応援中'**
  String get supporterActiveButton;

  /// No description provided for @supporterSubscribedButton.
  ///
  /// In ja, this message translates to:
  /// **'購読中'**
  String get supporterSubscribedButton;

  /// No description provided for @supporterRestoreButton.
  ///
  /// In ja, this message translates to:
  /// **'購入を復元'**
  String get supporterRestoreButton;

  /// No description provided for @supporterRetryButton.
  ///
  /// In ja, this message translates to:
  /// **'再試行'**
  String get supporterRetryButton;

  /// No description provided for @supporterProductsUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'現在利用できる応援プランがありません。'**
  String get supporterProductsUnavailable;

  /// No description provided for @supporterRestoreNoticeTitle.
  ///
  /// In ja, this message translates to:
  /// **'購入の復元について'**
  String get supporterRestoreNoticeTitle;

  /// No description provided for @supporterRestoreNoticeBody.
  ///
  /// In ja, this message translates to:
  /// **'購入の復元は同じ Apple ID または Google アカウントで利用できます。iOS と Android の間で応援状態は共有されません。'**
  String get supporterRestoreNoticeBody;

  /// No description provided for @supporterSummaryTitle.
  ///
  /// In ja, this message translates to:
  /// **'応援サマリー'**
  String get supporterSummaryTitle;

  /// No description provided for @supporterSummarySinceChip.
  ///
  /// In ja, this message translates to:
  /// **'{date}から応援中'**
  String supporterSummarySinceChip(String date);

  /// No description provided for @supporterSummaryStreakChip.
  ///
  /// In ja, this message translates to:
  /// **'継続 {duration}'**
  String supporterSummaryStreakChip(String duration);

  /// No description provided for @supporterSummaryOneTimeCount.
  ///
  /// In ja, this message translates to:
  /// **'単発 ×{count}'**
  String supporterSummaryOneTimeCount(int count);

  /// No description provided for @supporterSummarySnackCount.
  ///
  /// In ja, this message translates to:
  /// **'おやつ ×{count}'**
  String supporterSummarySnackCount(int count);

  /// No description provided for @supporterSummaryCoffeeCount.
  ///
  /// In ja, this message translates to:
  /// **'ドリンク ×{count}'**
  String supporterSummaryCoffeeCount(int count);

  /// No description provided for @supporterSummaryLunchCount.
  ///
  /// In ja, this message translates to:
  /// **'ランチ ×{count}'**
  String supporterSummaryLunchCount(int count);

  /// No description provided for @supporterSummaryLessThanMonth.
  ///
  /// In ja, this message translates to:
  /// **'1か月未満'**
  String get supporterSummaryLessThanMonth;

  /// No description provided for @supporterSummaryDurationMonths.
  ///
  /// In ja, this message translates to:
  /// **'{count}か月'**
  String supporterSummaryDurationMonths(int count);

  /// No description provided for @supporterSummarySinceLabel.
  ///
  /// In ja, this message translates to:
  /// **'応援開始'**
  String get supporterSummarySinceLabel;

  /// No description provided for @supporterSummaryStreakLabel.
  ///
  /// In ja, this message translates to:
  /// **'継続'**
  String get supporterSummaryStreakLabel;

  /// No description provided for @supporterSummaryOngoingLabel.
  ///
  /// In ja, this message translates to:
  /// **'継続中'**
  String get supporterSummaryOngoingLabel;

  /// No description provided for @supporterSummarySupportPeriodLabel.
  ///
  /// In ja, this message translates to:
  /// **'応援期間'**
  String get supporterSummarySupportPeriodLabel;

  /// No description provided for @supporterImpactTitle.
  ///
  /// In ja, this message translates to:
  /// **'応援でできること'**
  String get supporterImpactTitle;

  /// No description provided for @supporterImpactBody.
  ///
  /// In ja, this message translates to:
  /// **'CC Pocket が気に入ったら、継続開発を応援してもらえるとうれしいです。アプリはこれからも無料の OSS として続けていきます。'**
  String get supporterImpactBody;

  /// No description provided for @supporterImpactAiTitle.
  ///
  /// In ja, this message translates to:
  /// **'開発と運用のコスト'**
  String get supporterImpactAiTitle;

  /// No description provided for @supporterImpactAiBody.
  ///
  /// In ja, this message translates to:
  /// **'AI 利用料、実機確認、テスト、配布まわりなどの継続コストを支えます。'**
  String get supporterImpactAiBody;

  /// No description provided for @supporterImpactDevicesTitle.
  ///
  /// In ja, this message translates to:
  /// **'端末とテスト'**
  String get supporterImpactDevicesTitle;

  /// No description provided for @supporterImpactDevicesBody.
  ///
  /// In ja, this message translates to:
  /// **'実機確認や OS アップデート追従など、安定運用に必要なコストを支えます。'**
  String get supporterImpactDevicesBody;

  /// No description provided for @supporterImpactMotivationTitle.
  ///
  /// In ja, this message translates to:
  /// **'継続するモチベーション'**
  String get supporterImpactMotivationTitle;

  /// No description provided for @supporterImpactMotivationBody.
  ///
  /// In ja, this message translates to:
  /// **'使ってくれている実感が、新機能や改善を続けるいちばんの後押しになります。'**
  String get supporterImpactMotivationBody;

  /// No description provided for @supporterPackagesTitle.
  ///
  /// In ja, this message translates to:
  /// **'応援の方法'**
  String get supporterPackagesTitle;

  /// No description provided for @supporterSubscriptionGroupTitle.
  ///
  /// In ja, this message translates to:
  /// **'毎月応援'**
  String get supporterSubscriptionGroupTitle;

  /// No description provided for @supporterSubscriptionGroupBody.
  ///
  /// In ja, this message translates to:
  /// **'継続的に応援してもらえるとうれしいです。'**
  String get supporterSubscriptionGroupBody;

  /// No description provided for @supporterOneTimeGroupTitle.
  ///
  /// In ja, this message translates to:
  /// **'単発で応援'**
  String get supporterOneTimeGroupTitle;

  /// No description provided for @supporterOneTimeGroupBody.
  ///
  /// In ja, this message translates to:
  /// **'ランチやドリンクをおごる気持ちになったら、応援してもらえるとうれしいです。'**
  String get supporterOneTimeGroupBody;

  /// No description provided for @supporterPurchaseInfoTitle.
  ///
  /// In ja, this message translates to:
  /// **'購入について'**
  String get supporterPurchaseInfoTitle;

  /// No description provided for @supporterPurchaseInfoBody.
  ///
  /// In ja, this message translates to:
  /// **'購入の復元は同じ Apple ID または Google アカウントで利用できます。iOS と Android の間で応援状態は共有されません。'**
  String get supporterPurchaseInfoBody;

  /// No description provided for @supporterPurchaseInfoLink.
  ///
  /// In ja, this message translates to:
  /// **'詳しくはこちら'**
  String get supporterPurchaseInfoLink;

  /// No description provided for @supporterPrivacyPolicyLink.
  ///
  /// In ja, this message translates to:
  /// **'プライバシーポリシー'**
  String get supporterPrivacyPolicyLink;

  /// No description provided for @supporterTermsOfUseLink.
  ///
  /// In ja, this message translates to:
  /// **'利用規約（Apple標準EULA）'**
  String get supporterTermsOfUseLink;

  /// No description provided for @supporterLearnMoreTitle.
  ///
  /// In ja, this message translates to:
  /// **'購入と応援について'**
  String get supporterLearnMoreTitle;

  /// No description provided for @supporterLearnMoreBody.
  ///
  /// In ja, this message translates to:
  /// **'無料で提供し続ける考え方や、購入の復元の仕組みを確認できます。'**
  String get supporterLearnMoreBody;

  /// No description provided for @supporterOpenLinkFailed.
  ///
  /// In ja, this message translates to:
  /// **'案内ページを開けませんでした。'**
  String get supporterOpenLinkFailed;

  /// No description provided for @supporterPurchaseSuccess.
  ///
  /// In ja, this message translates to:
  /// **'CC Pocket を応援してくれてありがとうございます。'**
  String get supporterPurchaseSuccess;

  /// No description provided for @supporterPurchaseCancelled.
  ///
  /// In ja, this message translates to:
  /// **'購入をキャンセルしました。'**
  String get supporterPurchaseCancelled;

  /// No description provided for @supporterPurchaseFailed.
  ///
  /// In ja, this message translates to:
  /// **'購入に失敗しました: {message}'**
  String supporterPurchaseFailed(String message);

  /// No description provided for @supporterRestoreSuccess.
  ///
  /// In ja, this message translates to:
  /// **'購入情報を復元しました。'**
  String get supporterRestoreSuccess;

  /// No description provided for @supporterRestoreFailed.
  ///
  /// In ja, this message translates to:
  /// **'復元に失敗しました: {message}'**
  String supporterRestoreFailed(String message);

  /// No description provided for @gitDiscardAllChangesTitle.
  ///
  /// In ja, this message translates to:
  /// **'すべての変更を破棄しますか'**
  String get gitDiscardAllChangesTitle;

  /// No description provided for @gitDiscardVisibleUnstagedChangesMessage.
  ///
  /// In ja, this message translates to:
  /// **'表示中の未ステージ変更をすべて破棄します。'**
  String get gitDiscardVisibleUnstagedChangesMessage;

  /// No description provided for @gitDiscardChangeTitle.
  ///
  /// In ja, this message translates to:
  /// **'この変更を破棄しますか'**
  String get gitDiscardChangeTitle;

  /// No description provided for @gitDiscardFileUnstagedChangesMessage.
  ///
  /// In ja, this message translates to:
  /// **'このファイルの未ステージ変更をすべて破棄します。'**
  String get gitDiscardFileUnstagedChangesMessage;

  /// No description provided for @gitDiscardHunkUnstagedChangesMessage.
  ///
  /// In ja, this message translates to:
  /// **'このハンクの未ステージ変更を破棄します。'**
  String get gitDiscardHunkUnstagedChangesMessage;

  /// No description provided for @googleSearchSelectionAction.
  ///
  /// In ja, this message translates to:
  /// **'Google で検索'**
  String get googleSearchSelectionAction;

  /// No description provided for @approvalQuestionNotificationTitle.
  ///
  /// In ja, this message translates to:
  /// **'質問があります - ccpocket'**
  String get approvalQuestionNotificationTitle;

  /// No description provided for @approvalRequiredNotificationTitle.
  ///
  /// In ja, this message translates to:
  /// **'承認待ち - ccpocket'**
  String get approvalRequiredNotificationTitle;

  /// No description provided for @exitPlanModeNotificationBody.
  ///
  /// In ja, this message translates to:
  /// **'作成したプランの確認が必要です'**
  String get exitPlanModeNotificationBody;

  /// No description provided for @renderErrorFallback.
  ///
  /// In ja, this message translates to:
  /// **'このコンテンツを表示できませんでした'**
  String get renderErrorFallback;

  /// No description provided for @artifactFile.
  ///
  /// In ja, this message translates to:
  /// **'ファイル'**
  String get artifactFile;

  /// No description provided for @artifactSource.
  ///
  /// In ja, this message translates to:
  /// **'ソース'**
  String get artifactSource;

  /// No description provided for @artifactLineLabel.
  ///
  /// In ja, this message translates to:
  /// **'{line} 行目'**
  String artifactLineLabel(int line);

  /// No description provided for @artifactOpenFailed.
  ///
  /// In ja, this message translates to:
  /// **'ファイルを開けませんでした。'**
  String get artifactOpenFailed;

  /// No description provided for @artifactUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'このファイルは利用できなくなりました。'**
  String get artifactUnavailable;

  /// No description provided for @artifactReconnect.
  ///
  /// In ja, this message translates to:
  /// **'Bridge に再接続して、もう一度お試しください。'**
  String get artifactReconnect;

  /// No description provided for @artifactBridgeUpdateRequired.
  ///
  /// In ja, this message translates to:
  /// **'パソコン側の Bridge を更新してから、再接続してください。'**
  String get artifactBridgeUpdateRequired;

  /// No description provided for @artifactTimeout.
  ///
  /// In ja, this message translates to:
  /// **'ファイルの準備がタイムアウトしました。'**
  String get artifactTimeout;

  /// No description provided for @artifactPrepareFailed.
  ///
  /// In ja, this message translates to:
  /// **'ファイルを準備できませんでした。'**
  String get artifactPrepareFailed;

  /// No description provided for @goalTitle.
  ///
  /// In ja, this message translates to:
  /// **'Goal'**
  String get goalTitle;

  /// No description provided for @goalStart.
  ///
  /// In ja, this message translates to:
  /// **'Goalを開始'**
  String get goalStart;

  /// No description provided for @goalManage.
  ///
  /// In ja, this message translates to:
  /// **'Goalを管理'**
  String get goalManage;

  /// No description provided for @goalUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'このCodexでは利用できません'**
  String get goalUnavailable;

  /// No description provided for @goalUnavailableBody.
  ///
  /// In ja, this message translates to:
  /// **'このCodexランタイムはGoal操作に対応していません。Codexを更新するか、互換性のあるBridgeへ再接続してください。'**
  String get goalUnavailableBody;

  /// No description provided for @goalLoading.
  ///
  /// In ja, this message translates to:
  /// **'Goalを読み込み中…'**
  String get goalLoading;

  /// No description provided for @goalNoActiveTitle.
  ///
  /// In ja, this message translates to:
  /// **'進行中のGoalはありません'**
  String get goalNoActiveTitle;

  /// No description provided for @goalNoActiveBody.
  ///
  /// In ja, this message translates to:
  /// **'Goalを開始すると、Codexが通常のターンを重ねながら継続して作業します。'**
  String get goalNoActiveBody;

  /// No description provided for @goalManagementTitle.
  ///
  /// In ja, this message translates to:
  /// **'Goal管理'**
  String get goalManagementTitle;

  /// No description provided for @goalRefreshTooltip.
  ///
  /// In ja, this message translates to:
  /// **'Goalを更新'**
  String get goalRefreshTooltip;

  /// No description provided for @goalEditTooltip.
  ///
  /// In ja, this message translates to:
  /// **'Goalを編集'**
  String get goalEditTooltip;

  /// No description provided for @goalPauseTooltip.
  ///
  /// In ja, this message translates to:
  /// **'Goalを一時停止'**
  String get goalPauseTooltip;

  /// No description provided for @goalResumeTooltip.
  ///
  /// In ja, this message translates to:
  /// **'Goalを再開'**
  String get goalResumeTooltip;

  /// No description provided for @goalUpdateBudgetResume.
  ///
  /// In ja, this message translates to:
  /// **'予算を変更して再開'**
  String get goalUpdateBudgetResume;

  /// No description provided for @goalClearTooltip.
  ///
  /// In ja, this message translates to:
  /// **'Goalを削除'**
  String get goalClearTooltip;

  /// No description provided for @goalStatusActive.
  ///
  /// In ja, this message translates to:
  /// **'進行中'**
  String get goalStatusActive;

  /// No description provided for @goalStatusPaused.
  ///
  /// In ja, this message translates to:
  /// **'一時停止中'**
  String get goalStatusPaused;

  /// No description provided for @goalStatusBlocked.
  ///
  /// In ja, this message translates to:
  /// **'ブロック中'**
  String get goalStatusBlocked;

  /// No description provided for @goalStatusUsageLimited.
  ///
  /// In ja, this message translates to:
  /// **'利用上限'**
  String get goalStatusUsageLimited;

  /// No description provided for @goalStatusBudgetLimited.
  ///
  /// In ja, this message translates to:
  /// **'予算上限'**
  String get goalStatusBudgetLimited;

  /// No description provided for @goalStatusComplete.
  ///
  /// In ja, this message translates to:
  /// **'完了'**
  String get goalStatusComplete;

  /// No description provided for @goalStatusUnknown.
  ///
  /// In ja, this message translates to:
  /// **'不明'**
  String get goalStatusUnknown;

  /// No description provided for @goalUpdating.
  ///
  /// In ja, this message translates to:
  /// **'Goalを更新中…'**
  String get goalUpdating;

  /// No description provided for @goalMutationStarting.
  ///
  /// In ja, this message translates to:
  /// **'Goalを開始中…'**
  String get goalMutationStarting;

  /// No description provided for @goalMutationSaving.
  ///
  /// In ja, this message translates to:
  /// **'Goalを保存中…'**
  String get goalMutationSaving;

  /// No description provided for @goalMutationPausing.
  ///
  /// In ja, this message translates to:
  /// **'現在のステップ後に一時停止します…'**
  String get goalMutationPausing;

  /// No description provided for @goalMutationResuming.
  ///
  /// In ja, this message translates to:
  /// **'Goalを再開中…'**
  String get goalMutationResuming;

  /// No description provided for @goalMutationBudget.
  ///
  /// In ja, this message translates to:
  /// **'Goalの予算を更新中…'**
  String get goalMutationBudget;

  /// No description provided for @goalMutationClearing.
  ///
  /// In ja, this message translates to:
  /// **'Goalを削除中…'**
  String get goalMutationClearing;

  /// No description provided for @goalTokensUnit.
  ///
  /// In ja, this message translates to:
  /// **'トークン'**
  String get goalTokensUnit;

  /// No description provided for @goalBlockedExplanation.
  ///
  /// In ja, this message translates to:
  /// **'ブロックが繰り返されたためGoalモードが停止しました。必要な情報を追加するか目標を変更してから再開してください。'**
  String get goalBlockedExplanation;

  /// No description provided for @goalUsageLimitedExplanation.
  ///
  /// In ja, this message translates to:
  /// **'現在のアカウントが利用上限に達したためGoalモードが一時停止しました。'**
  String get goalUsageLimitedExplanation;

  /// No description provided for @goalBudgetLimitedExplanation.
  ///
  /// In ja, this message translates to:
  /// **'Goalのtoken予算を使い切りました。予算を増やすか解除してから再開してください。'**
  String get goalBudgetLimitedExplanation;

  /// No description provided for @goalCompleteExplanation.
  ///
  /// In ja, this message translates to:
  /// **'CodexがこのGoalを完了と判断しました。別のGoalを始める前に削除してください。'**
  String get goalCompleteExplanation;

  /// No description provided for @goalUnknownExplanation.
  ///
  /// In ja, this message translates to:
  /// **'この状態は新しいCodexバージョンから届いています。推測せずそのまま表示します。'**
  String get goalUnknownExplanation;

  /// No description provided for @goalStartTitle.
  ///
  /// In ja, this message translates to:
  /// **'Goalを開始'**
  String get goalStartTitle;

  /// No description provided for @goalEditTitle.
  ///
  /// In ja, this message translates to:
  /// **'Goalを編集'**
  String get goalEditTitle;

  /// No description provided for @goalObjectiveLabel.
  ///
  /// In ja, this message translates to:
  /// **'目標'**
  String get goalObjectiveLabel;

  /// No description provided for @goalObjectiveHint.
  ///
  /// In ja, this message translates to:
  /// **'成果、制約、完了を確認する方法を入力してください。'**
  String get goalObjectiveHint;

  /// No description provided for @goalObjectiveRequired.
  ///
  /// In ja, this message translates to:
  /// **'Goalの目標を入力してください。'**
  String get goalObjectiveRequired;

  /// No description provided for @goalTokenBudgetTitle.
  ///
  /// In ja, this message translates to:
  /// **'Token予算'**
  String get goalTokenBudgetTitle;

  /// No description provided for @goalTokenBudgetDescription.
  ///
  /// In ja, this message translates to:
  /// **'任意。予算を使い切るとGoalモードは自動的に一時停止します。'**
  String get goalTokenBudgetDescription;

  /// No description provided for @goalMaximumTokens.
  ///
  /// In ja, this message translates to:
  /// **'最大token数'**
  String get goalMaximumTokens;

  /// No description provided for @goalTokensAlreadyUsedSuffix.
  ///
  /// In ja, this message translates to:
  /// **'tokens 使用済み'**
  String get goalTokensAlreadyUsedSuffix;

  /// No description provided for @goalTokenBudgetPositive.
  ///
  /// In ja, this message translates to:
  /// **'0より大きいtoken予算を入力してください。'**
  String get goalTokenBudgetPositive;

  /// No description provided for @goalTokenBudgetAboveUsed.
  ///
  /// In ja, this message translates to:
  /// **'予算は使用済みtoken数より大きくしてください。'**
  String get goalTokenBudgetAboveUsed;

  /// No description provided for @goalBudgetResumeDescription.
  ///
  /// In ja, this message translates to:
  /// **'予算上限に達したGoalを再開するには、予算を増やすか解除する必要があります。両方の変更は同時に適用されます。'**
  String get goalBudgetResumeDescription;

  /// No description provided for @goalBudgetBridgeUpdate.
  ///
  /// In ja, this message translates to:
  /// **'Goalのtoken予算を変更する前にBridgeを更新してください。'**
  String get goalBudgetBridgeUpdate;

  /// No description provided for @goalBudgetBridgeUpdateExisting.
  ///
  /// In ja, this message translates to:
  /// **'このGoalにはtoken予算があります。変更するにはBridgeを更新してください。'**
  String get goalBudgetBridgeUpdateExisting;

  /// No description provided for @goalResumeAction.
  ///
  /// In ja, this message translates to:
  /// **'再開'**
  String get goalResumeAction;

  /// No description provided for @goalClearTitle.
  ///
  /// In ja, this message translates to:
  /// **'Goalを削除しますか？'**
  String get goalClearTitle;

  /// No description provided for @goalClearBody.
  ///
  /// In ja, this message translates to:
  /// **'Codexは新しいGoalステップを開始しなくなります。実行中のステップは完了する場合があります。'**
  String get goalClearBody;

  /// No description provided for @goalClearAction.
  ///
  /// In ja, this message translates to:
  /// **'削除'**
  String get goalClearAction;

  /// No description provided for @goalChangedElsewhere.
  ///
  /// In ja, this message translates to:
  /// **'このGoalは別のクライアントで変更されました。下書きは保持されています。キャンセルして最新のGoalを確認し、編集画面を開き直してください。'**
  String get goalChangedElsewhere;

  /// No description provided for @goalReconnectToManage.
  ///
  /// In ja, this message translates to:
  /// **'このGoalを管理するには、再接続して更新してください。'**
  String get goalReconnectToManage;

  /// No description provided for @goalMutationTimeout.
  ///
  /// In ja, this message translates to:
  /// **'Goalの変更がタイムアウトしました。現在の状態を更新しています。'**
  String get goalMutationTimeout;

  /// No description provided for @goalObjectiveTooLong.
  ///
  /// In ja, this message translates to:
  /// **'Goalの目標は4,000文字以内で入力してください。'**
  String get goalObjectiveTooLong;

  /// No description provided for @goalLoadFailedTitle.
  ///
  /// In ja, this message translates to:
  /// **'Goalを読み込めませんでした'**
  String get goalLoadFailedTitle;

  /// No description provided for @goalLoadFailedBody.
  ///
  /// In ja, this message translates to:
  /// **'Bridgeから確定したGoal状態が返されませんでした。既存のGoalは変更されていません。再接続するか再試行してください。'**
  String get goalLoadFailedBody;

  /// No description provided for @goalUpdateFailed.
  ///
  /// In ja, this message translates to:
  /// **'Goalの変更を保存できませんでした。下書きは保持されています。'**
  String get goalUpdateFailed;

  /// No description provided for @goalClearFailed.
  ///
  /// In ja, this message translates to:
  /// **'Goalをクリアできませんでした。更新してから再試行してください。'**
  String get goalClearFailed;

  /// No description provided for @sessionCompleteTitle.
  ///
  /// In ja, this message translates to:
  /// **'セッション完了'**
  String get sessionCompleteTitle;

  /// No description provided for @sessionDone.
  ///
  /// In ja, this message translates to:
  /// **'セッションが終了しました'**
  String get sessionDone;

  /// No description provided for @statusStarting.
  ///
  /// In ja, this message translates to:
  /// **'起動中'**
  String get statusStarting;

  /// No description provided for @statusIdle.
  ///
  /// In ja, this message translates to:
  /// **'待機中'**
  String get statusIdle;

  /// No description provided for @statusRunning.
  ///
  /// In ja, this message translates to:
  /// **'実行中'**
  String get statusRunning;

  /// No description provided for @statusApproval.
  ///
  /// In ja, this message translates to:
  /// **'承認待ち'**
  String get statusApproval;

  /// No description provided for @statusCompacting.
  ///
  /// In ja, this message translates to:
  /// **'コンテキストを整理中'**
  String get statusCompacting;

  /// No description provided for @statusPlan.
  ///
  /// In ja, this message translates to:
  /// **'プラン'**
  String get statusPlan;

  /// No description provided for @statusWorking.
  ///
  /// In ja, this message translates to:
  /// **'作業中'**
  String get statusWorking;

  /// No description provided for @statusNeedsYou.
  ///
  /// In ja, this message translates to:
  /// **'対応が必要'**
  String get statusNeedsYou;

  /// No description provided for @statusUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'状態を確認できません'**
  String get statusUnavailable;

  /// No description provided for @sessionStatusReviewPlan.
  ///
  /// In ja, this message translates to:
  /// **'プランを確認'**
  String get sessionStatusReviewPlan;

  /// No description provided for @sessionStatusApproveToolCall.
  ///
  /// In ja, this message translates to:
  /// **'ツール実行を承認'**
  String get sessionStatusApproveToolCall;

  /// No description provided for @sessionStatusAnswerQuestion.
  ///
  /// In ja, this message translates to:
  /// **'質問に回答'**
  String get sessionStatusAnswerQuestion;

  /// No description provided for @sessionStatusAnswerMcpRequest.
  ///
  /// In ja, this message translates to:
  /// **'MCPリクエストに回答'**
  String get sessionStatusAnswerMcpRequest;

  /// No description provided for @sessionStatusGrantPermissions.
  ///
  /// In ja, this message translates to:
  /// **'権限を許可'**
  String get sessionStatusGrantPermissions;

  /// No description provided for @sessionStatusApproveTool.
  ///
  /// In ja, this message translates to:
  /// **'{toolName} を承認'**
  String sessionStatusApproveTool(String toolName);

  /// No description provided for @sessionStatusCleaningContext.
  ///
  /// In ja, this message translates to:
  /// **'コンテキストを整理中'**
  String get sessionStatusCleaningContext;

  /// No description provided for @unread.
  ///
  /// In ja, this message translates to:
  /// **'未読'**
  String get unread;

  /// No description provided for @runningOnDesktop.
  ///
  /// In ja, this message translates to:
  /// **'デスクトップで実行中'**
  String get runningOnDesktop;

  /// No description provided for @exploreRecentFiles.
  ///
  /// In ja, this message translates to:
  /// **'最近のファイル'**
  String get exploreRecentFiles;

  /// No description provided for @exploreLoadFailed.
  ///
  /// In ja, this message translates to:
  /// **'ファイルを読み込めませんでした'**
  String get exploreLoadFailed;

  /// No description provided for @exploreBridgeDisconnected.
  ///
  /// In ja, this message translates to:
  /// **'Bridgeとの接続が切れたため、ファイルを読み込めません'**
  String get exploreBridgeDisconnected;

  /// No description provided for @exploreRequestTimedOut.
  ///
  /// In ja, this message translates to:
  /// **'ファイル一覧の取得がタイムアウトしました。Bridge接続を確認してください'**
  String get exploreRequestTimedOut;

  /// No description provided for @explorePathNotAllowed.
  ///
  /// In ja, this message translates to:
  /// **'この場所は現在の読み取り権限の範囲外です'**
  String get explorePathNotAllowed;

  /// No description provided for @exploreShowingFirstEntries.
  ///
  /// In ja, this message translates to:
  /// **'先頭の{visibleCount}件を表示中'**
  String exploreShowingFirstEntries(int visibleCount);

  /// No description provided for @exploreShowingEntries.
  ///
  /// In ja, this message translates to:
  /// **'{totalFiles}件中{visibleCount}件を表示中'**
  String exploreShowingEntries(int visibleCount, int totalFiles);

  /// No description provided for @exploreRecentOpenFiles.
  ///
  /// In ja, this message translates to:
  /// **'最近開いたファイル'**
  String get exploreRecentOpenFiles;

  /// No description provided for @exploreNoRecentOpenFiles.
  ///
  /// In ja, this message translates to:
  /// **'最近開いたファイルはありません'**
  String get exploreNoRecentOpenFiles;

  /// No description provided for @exploreNoFiles.
  ///
  /// In ja, this message translates to:
  /// **'参照できるファイルがありません'**
  String get exploreNoFiles;

  /// No description provided for @exploreNoVisibleFiles.
  ///
  /// In ja, this message translates to:
  /// **'表示可能なファイルが見つかりませんでした。生成フォルダやキャッシュフォルダは非表示の場合があります'**
  String get exploreNoVisibleFiles;

  /// No description provided for @close.
  ///
  /// In ja, this message translates to:
  /// **'閉じる'**
  String get close;

  /// No description provided for @gitUnstaged.
  ///
  /// In ja, this message translates to:
  /// **'未ステージ'**
  String get gitUnstaged;

  /// No description provided for @gitStaged.
  ///
  /// In ja, this message translates to:
  /// **'ステージ済み'**
  String get gitStaged;

  /// No description provided for @gitStage.
  ///
  /// In ja, this message translates to:
  /// **'ステージ'**
  String get gitStage;

  /// No description provided for @gitUnstage.
  ///
  /// In ja, this message translates to:
  /// **'ステージ解除'**
  String get gitUnstage;

  /// No description provided for @gitRevert.
  ///
  /// In ja, this message translates to:
  /// **'元に戻す'**
  String get gitRevert;

  /// No description provided for @gitViewFile.
  ///
  /// In ja, this message translates to:
  /// **'ファイルを表示'**
  String get gitViewFile;

  /// No description provided for @gitOpenFullCurrentFile.
  ///
  /// In ja, this message translates to:
  /// **'現在のファイル全体を開く'**
  String get gitOpenFullCurrentFile;

  /// No description provided for @gitDiscardAllChangesInFile.
  ///
  /// In ja, this message translates to:
  /// **'このファイルの変更をすべて破棄'**
  String get gitDiscardAllChangesInFile;

  /// No description provided for @gitDiscardChangesInHunk.
  ///
  /// In ja, this message translates to:
  /// **'このハンクの変更を破棄'**
  String get gitDiscardChangesInHunk;

  /// No description provided for @gitRequestChange.
  ///
  /// In ja, this message translates to:
  /// **'変更を依頼'**
  String get gitRequestChange;

  /// No description provided for @gitSendFileBackToAi.
  ///
  /// In ja, this message translates to:
  /// **'フィードバック付きでこのファイルをAIに送る'**
  String get gitSendFileBackToAi;

  /// No description provided for @gitSendHunkBackToAi.
  ///
  /// In ja, this message translates to:
  /// **'フィードバック付きでこのハンクをAIに送る'**
  String get gitSendHunkBackToAi;

  /// No description provided for @gitFiles.
  ///
  /// In ja, this message translates to:
  /// **'ファイル'**
  String get gitFiles;

  /// No description provided for @gitRevertAll.
  ///
  /// In ja, this message translates to:
  /// **'すべて元に戻す'**
  String get gitRevertAll;

  /// No description provided for @gitStageAll.
  ///
  /// In ja, this message translates to:
  /// **'すべてステージ'**
  String get gitStageAll;

  /// No description provided for @gitUnstageAll.
  ///
  /// In ja, this message translates to:
  /// **'すべてステージ解除'**
  String get gitUnstageAll;

  /// No description provided for @gitCommit.
  ///
  /// In ja, this message translates to:
  /// **'コミット'**
  String get gitCommit;

  /// No description provided for @gitCommitAndPush.
  ///
  /// In ja, this message translates to:
  /// **'コミットしてプッシュ'**
  String get gitCommitAndPush;

  /// No description provided for @gitCommittedHash.
  ///
  /// In ja, this message translates to:
  /// **'コミット済み: {hash}'**
  String gitCommittedHash(String hash);

  /// No description provided for @gitSuccess.
  ///
  /// In ja, this message translates to:
  /// **'完了'**
  String get gitSuccess;

  /// No description provided for @gitUnknownError.
  ///
  /// In ja, this message translates to:
  /// **'不明なエラー'**
  String get gitUnknownError;

  /// No description provided for @gitAutoGenerateWithAi.
  ///
  /// In ja, this message translates to:
  /// **'AIで自動生成'**
  String get gitAutoGenerateWithAi;

  /// No description provided for @gitCommitMessage.
  ///
  /// In ja, this message translates to:
  /// **'コミットメッセージ'**
  String get gitCommitMessage;

  /// No description provided for @gitAutoGenerateMessage.
  ///
  /// In ja, this message translates to:
  /// **'コミットメッセージを自動生成'**
  String get gitAutoGenerateMessage;

  /// No description provided for @gitCommitting.
  ///
  /// In ja, this message translates to:
  /// **'コミット中...'**
  String get gitCommitting;

  /// No description provided for @gitPushing.
  ///
  /// In ja, this message translates to:
  /// **'プッシュ中...'**
  String get gitPushing;

  /// No description provided for @gitBranches.
  ///
  /// In ja, this message translates to:
  /// **'ブランチ'**
  String get gitBranches;

  /// No description provided for @gitNewBranch.
  ///
  /// In ja, this message translates to:
  /// **'新しいブランチ'**
  String get gitNewBranch;

  /// No description provided for @gitSearchBranches.
  ///
  /// In ja, this message translates to:
  /// **'ブランチを検索...'**
  String get gitSearchBranches;

  /// No description provided for @gitBranchInUseByWorktree.
  ///
  /// In ja, this message translates to:
  /// **'別のワークツリーで使用中'**
  String get gitBranchInUseByWorktree;

  /// No description provided for @gitBranchNameHint.
  ///
  /// In ja, this message translates to:
  /// **'ブランチ名（例: feat/login）'**
  String get gitBranchNameHint;

  /// No description provided for @gitCreateAndCheckout.
  ///
  /// In ja, this message translates to:
  /// **'作成してチェックアウト'**
  String get gitCreateAndCheckout;

  /// No description provided for @gitNoUpstream.
  ///
  /// In ja, this message translates to:
  /// **'アップストリームなし'**
  String get gitNoUpstream;

  /// No description provided for @gitImageTooLarge.
  ///
  /// In ja, this message translates to:
  /// **'画像が大きすぎてプレビューできません'**
  String get gitImageTooLarge;

  /// No description provided for @gitImagePreviewUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'画像プレビューを利用できません'**
  String get gitImagePreviewUnavailable;

  /// No description provided for @gitTapToLoadPreview.
  ///
  /// In ja, this message translates to:
  /// **'タップしてプレビューを読み込む'**
  String get gitTapToLoadPreview;

  /// No description provided for @gitFocusDiff.
  ///
  /// In ja, this message translates to:
  /// **'diff集中表示'**
  String get gitFocusDiff;

  /// No description provided for @gitExitFocusMode.
  ///
  /// In ja, this message translates to:
  /// **'集中モードを終了'**
  String get gitExitFocusMode;

  /// No description provided for @gitNoStagedFiles.
  ///
  /// In ja, this message translates to:
  /// **'ステージ済みファイルはありません'**
  String get gitNoStagedFiles;

  /// No description provided for @gitPullCommits.
  ///
  /// In ja, this message translates to:
  /// **'{count}件のコミットをプル'**
  String gitPullCommits(int count);

  /// No description provided for @gitPullUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'プルできません'**
  String get gitPullUnavailable;

  /// No description provided for @gitPushCommits.
  ///
  /// In ja, this message translates to:
  /// **'{count}件のコミットをプッシュ'**
  String gitPushCommits(int count);

  /// No description provided for @gitPushUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'プッシュできません'**
  String get gitPushUnavailable;

  /// No description provided for @licenseSearchHint.
  ///
  /// In ja, this message translates to:
  /// **'パッケージを検索…'**
  String get licenseSearchHint;

  /// No description provided for @licenseNoPackagesFound.
  ///
  /// In ja, this message translates to:
  /// **'パッケージが見つかりません'**
  String get licenseNoPackagesFound;

  /// No description provided for @licenseEntryCount.
  ///
  /// In ja, this message translates to:
  /// **'ライセンス項目：{count}'**
  String licenseEntryCount(Object count);

  /// No description provided for @bridgeMachine.
  ///
  /// In ja, this message translates to:
  /// **'Bridge マシン'**
  String get bridgeMachine;

  /// No description provided for @bridgeNotConnected.
  ///
  /// In ja, this message translates to:
  /// **'未接続'**
  String get bridgeNotConnected;

  /// No description provided for @enabledAgentsBoth.
  ///
  /// In ja, this message translates to:
  /// **'両方'**
  String get enabledAgentsBoth;

  /// No description provided for @speed.
  ///
  /// In ja, this message translates to:
  /// **'速度'**
  String get speed;

  /// No description provided for @readOnlyValue.
  ///
  /// In ja, this message translates to:
  /// **'{value}（読み取り専用）'**
  String readOnlyValue(Object value);

  /// No description provided for @speedFastDescription.
  ///
  /// In ja, this message translates to:
  /// **'1.5倍速、使用量が増えます'**
  String get speedFastDescription;

  /// No description provided for @speedDefaultDescription.
  ///
  /// In ja, this message translates to:
  /// **'標準速度'**
  String get speedDefaultDescription;

  /// No description provided for @speedStandard.
  ///
  /// In ja, this message translates to:
  /// **'標準'**
  String get speedStandard;

  /// No description provided for @speedFast.
  ///
  /// In ja, this message translates to:
  /// **'高速'**
  String get speedFast;

  /// No description provided for @speedCustom.
  ///
  /// In ja, this message translates to:
  /// **'カスタム'**
  String get speedCustom;

  /// No description provided for @speedCustomReadOnly.
  ///
  /// In ja, this message translates to:
  /// **'カスタムサービス階層（読み取り専用）'**
  String get speedCustomReadOnly;

  /// No description provided for @speedFastOn.
  ///
  /// In ja, this message translates to:
  /// **'高速モードはオンです'**
  String get speedFastOn;

  /// No description provided for @speedFastOff.
  ///
  /// In ja, this message translates to:
  /// **'高速モードはオフです'**
  String get speedFastOff;

  /// No description provided for @currentServiceTierReadOnly.
  ///
  /// In ja, this message translates to:
  /// **'現在のサービス階層：{value}（読み取り専用）'**
  String currentServiceTierReadOnly(Object value);

  /// No description provided for @codexSettingsUnknown.
  ///
  /// In ja, this message translates to:
  /// **'不明 · 同期を待機中'**
  String get codexSettingsUnknown;

  /// No description provided for @codexSettingsWaitingForRuntime.
  ///
  /// In ja, this message translates to:
  /// **'Bridge がこの会話のランタイム設定を同期するのを待っています。設定は変更されていません。'**
  String get codexSettingsWaitingForRuntime;

  /// No description provided for @codexSettingsReadOnlyDesktop.
  ///
  /// In ja, this message translates to:
  /// **'このターンは Codex Desktop が所有しています。ここでは設定は読み取り専用です。Desktop で変更するか、ターンの終了を待ってください。'**
  String get codexSettingsReadOnlyDesktop;

  /// No description provided for @codexSettingsUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'Bridge がこの会話の設定書き込み権限を確認していないため、CC Pocket は変更を送信またはプレビューしません。'**
  String get codexSettingsUnavailable;

  /// No description provided for @codexPermissionsOnRequest.
  ///
  /// In ja, this message translates to:
  /// **'必要時に確認'**
  String get codexPermissionsOnRequest;

  /// No description provided for @codexPermissionsFullAccess.
  ///
  /// In ja, this message translates to:
  /// **'フルアクセス'**
  String get codexPermissionsFullAccess;

  /// No description provided for @codexPermissionsCustom.
  ///
  /// In ja, this message translates to:
  /// **'カスタム（config.toml）'**
  String get codexPermissionsCustom;

  /// No description provided for @codexPermissionsCustomShort.
  ///
  /// In ja, this message translates to:
  /// **'カスタム'**
  String get codexPermissionsCustomShort;

  /// No description provided for @codexPermissionsFromConfig.
  ///
  /// In ja, this message translates to:
  /// **'Codex は config.toml の権限設定を使用します'**
  String get codexPermissionsFromConfig;

  /// No description provided for @codexPermissionsFromProfile.
  ///
  /// In ja, this message translates to:
  /// **'Codex は選択したプロファイルの権限設定を使用します'**
  String get codexPermissionsFromProfile;

  /// No description provided for @permissionDefaultMode.
  ///
  /// In ja, this message translates to:
  /// **'デフォルト'**
  String get permissionDefaultMode;

  /// No description provided for @permissionAutoMode.
  ///
  /// In ja, this message translates to:
  /// **'自動'**
  String get permissionAutoMode;

  /// No description provided for @permissionChipAcceptEdits.
  ///
  /// In ja, this message translates to:
  /// **'編集'**
  String get permissionChipAcceptEdits;

  /// No description provided for @permissionPlanMode.
  ///
  /// In ja, this message translates to:
  /// **'プラン'**
  String get permissionPlanMode;

  /// No description provided for @permissionChipBypass.
  ///
  /// In ja, this message translates to:
  /// **'バイパス'**
  String get permissionChipBypass;

  /// No description provided for @executionFullShort.
  ///
  /// In ja, this message translates to:
  /// **'フル'**
  String get executionFullShort;

  /// No description provided for @sandboxSafeMode.
  ///
  /// In ja, this message translates to:
  /// **'サンドボックス（安全モード）'**
  String get sandboxSafeMode;

  /// No description provided for @sandboxStandard.
  ///
  /// In ja, this message translates to:
  /// **'標準'**
  String get sandboxStandard;

  /// No description provided for @sandboxOnLabel.
  ///
  /// In ja, this message translates to:
  /// **'サンドボックス有効'**
  String get sandboxOnLabel;

  /// No description provided for @sandboxOffLabel.
  ///
  /// In ja, this message translates to:
  /// **'サンドボックス無効'**
  String get sandboxOffLabel;

  /// No description provided for @sandboxOffShort.
  ///
  /// In ja, this message translates to:
  /// **'サンドボックスなし'**
  String get sandboxOffShort;

  /// No description provided for @effortUltraDescription.
  ///
  /// In ja, this message translates to:
  /// **'使用量を増やし、タスクを自動委任します'**
  String get effortUltraDescription;

  /// No description provided for @scrollToBottom.
  ///
  /// In ja, this message translates to:
  /// **'一番下へスクロール'**
  String get scrollToBottom;

  /// No description provided for @switchSession.
  ///
  /// In ja, this message translates to:
  /// **'セッションを切り替え'**
  String get switchSession;

  /// No description provided for @terminalAppNameHint.
  ///
  /// In ja, this message translates to:
  /// **'マイターミナル'**
  String get terminalAppNameHint;

  /// No description provided for @historyToolDetailsPending.
  ///
  /// In ja, this message translates to:
  /// **'以前のツール詳細 {count} 件はまだ読み込まれていません'**
  String historyToolDetailsPending(int count);

  /// No description provided for @loadOnDemand.
  ///
  /// In ja, this message translates to:
  /// **'読み込む'**
  String get loadOnDemand;

  /// No description provided for @viewFullDiff.
  ///
  /// In ja, this message translates to:
  /// **'差分全体を表示'**
  String get viewFullDiff;

  /// No description provided for @turnHistoryLoadFailed.
  ///
  /// In ja, this message translates to:
  /// **'ターン履歴を読み込めませんでした'**
  String get turnHistoryLoadFailed;

  /// No description provided for @turnLoadFailed.
  ///
  /// In ja, this message translates to:
  /// **'このターンを読み込めませんでした。もう一度お試しください。'**
  String get turnLoadFailed;

  /// No description provided for @turnHistoryTitle.
  ///
  /// In ja, this message translates to:
  /// **'ターン履歴'**
  String get turnHistoryTitle;

  /// No description provided for @turnCount.
  ///
  /// In ja, this message translates to:
  /// **'{count} ターン'**
  String turnCount(int count);

  /// No description provided for @noTurnsYet.
  ///
  /// In ja, this message translates to:
  /// **'ターンはまだありません'**
  String get noTurnsYet;

  /// No description provided for @turnHistoryHint.
  ///
  /// In ja, this message translates to:
  /// **'メッセージを送信すると、各ターンの先頭がここに表示されます'**
  String get turnHistoryHint;

  /// No description provided for @locatingTurn.
  ///
  /// In ja, this message translates to:
  /// **'このターンを読み込んで移動しています…'**
  String get locatingTurn;

  /// No description provided for @userMessageIndexUnavailable.
  ///
  /// In ja, this message translates to:
  /// **'軽量なユーザーメッセージ索引を利用できません。読み込み済みの {count} ターンを表示しています。'**
  String userMessageIndexUnavailable(int count);

  /// No description provided for @userMessageIndexLoading.
  ///
  /// In ja, this message translates to:
  /// **'軽量なユーザーメッセージ索引を同期中です。先に {count} ターンを表示しています。'**
  String userMessageIndexLoading(int count);

  /// No description provided for @userMessageIndexNotReady.
  ///
  /// In ja, this message translates to:
  /// **'読み込み済みの {count} ターンを表示しています。軽量なユーザーメッセージ索引を同期中です。'**
  String userMessageIndexNotReady(int count);

  /// No description provided for @downloading.
  ///
  /// In ja, this message translates to:
  /// **'ダウンロード中…'**
  String get downloading;

  /// No description provided for @loadingOlderToolDetails.
  ///
  /// In ja, this message translates to:
  /// **'以前のツール詳細を読み込んでいます…'**
  String get loadingOlderToolDetails;

  /// No description provided for @loadToolDetailsFailed.
  ///
  /// In ja, this message translates to:
  /// **'詳細を読み込めませんでした。再試行'**
  String get loadToolDetailsFailed;

  /// No description provided for @loadNextToolDetails.
  ///
  /// In ja, this message translates to:
  /// **'次の {count} 件のツール詳細を読み込む'**
  String loadNextToolDetails(int count);

  /// No description provided for @codexApprovalUntrustedLabel.
  ///
  /// In ja, this message translates to:
  /// **'信頼済みのみ'**
  String get codexApprovalUntrustedLabel;

  /// No description provided for @codexApprovalNeverAskLabel.
  ///
  /// In ja, this message translates to:
  /// **'確認なし'**
  String get codexApprovalNeverAskLabel;

  /// No description provided for @planOnShort.
  ///
  /// In ja, this message translates to:
  /// **'プラン有効'**
  String get planOnShort;

  /// No description provided for @planOffShort.
  ///
  /// In ja, this message translates to:
  /// **'プラン無効'**
  String get planOffShort;

  /// No description provided for @statusPlanning.
  ///
  /// In ja, this message translates to:
  /// **'計画中'**
  String get statusPlanning;

  /// No description provided for @systemMessageLabel.
  ///
  /// In ja, this message translates to:
  /// **'システム：{subtype}'**
  String systemMessageLabel(String subtype);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja', 'ko', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
    case 'ko':
      return AppLocalizationsKo();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
