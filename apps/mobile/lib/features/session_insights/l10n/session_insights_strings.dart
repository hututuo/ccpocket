import 'package:flutter/widgets.dart';

/// Feature-local copy for session-insights text.
///
/// Keeping these strings beside the feature avoids widening the generated app
/// localization surface while still following the app's active locale.
class SessionInsightsStrings {
  const SessionInsightsStrings({
    required this.title,
    required this.context,
    required this.contextUnavailable,
    required this.quota,
    required this.quotaUnavailable,
    required this.source,
    required this.input,
    required this.cached,
    required this.output,
    required this.resetsIn,
    required this.resetCredits,
    required this.available,
    required this.resetCreditsUnavailable,
    required this.noResetCreditDetails,
  });

  final String title;
  final String context;
  final String contextUnavailable;
  final String quota;
  final String quotaUnavailable;
  final String source;
  final String input;
  final String cached;
  final String output;
  final String resetsIn;
  final String resetCredits;
  final String available;
  final String resetCreditsUnavailable;
  final String noResetCreditDetails;

  static SessionInsightsStrings of(BuildContext context) =>
      forLocale(Localizations.localeOf(context));

  static SessionInsightsStrings forLocale(Locale locale) =>
      switch (locale.languageCode) {
        'zh' => _zh,
        'ja' => _ja,
        'ko' => _ko,
        _ => _en,
      };

  static const _en = SessionInsightsStrings(
    title: 'Session insights',
    context: 'Context window',
    contextUnavailable: 'Context usage is not available from this Bridge yet.',
    quota: 'Account quota',
    quotaUnavailable: 'Quota data is not available.',
    source: 'Source',
    input: 'Input',
    cached: 'Cached',
    output: 'Output',
    resetsIn: 'Resets in',
    resetCredits: 'Reset credits',
    available: 'available',
    resetCreditsUnavailable: 'Reset-credit data is not available.',
    noResetCreditDetails: 'No reset-credit details were returned.',
  );

  static const _zh = SessionInsightsStrings(
    title: '会话详情',
    context: '上下文窗口',
    contextUnavailable: '当前 Bridge 暂未提供上下文占用。',
    quota: '账户额度',
    quotaUnavailable: '暂无额度数据。',
    source: '数据来源',
    input: '输入',
    cached: '缓存',
    output: '输出',
    resetsIn: '距离重置',
    resetCredits: '重置卡',
    available: '张可用',
    resetCreditsUnavailable: '暂无重置卡数据。',
    noResetCreditDetails: '未返回重置卡明细。',
  );

  static const _ja = SessionInsightsStrings(
    title: 'セッション情報',
    context: 'コンテキストウィンドウ',
    contextUnavailable: 'この Bridge ではコンテキスト使用量をまだ取得できません。',
    quota: 'アカウント上限',
    quotaUnavailable: '上限データを取得できません。',
    source: 'データソース',
    input: '入力',
    cached: 'キャッシュ',
    output: '出力',
    resetsIn: 'リセットまで',
    resetCredits: 'リセットクレジット',
    available: '件利用可能',
    resetCreditsUnavailable: 'リセットクレジットのデータを取得できません。',
    noResetCreditDetails: 'リセットクレジットの詳細はありません。',
  );

  static const _ko = SessionInsightsStrings(
    title: '세션 정보',
    context: '컨텍스트 창',
    contextUnavailable: '이 Bridge에서는 아직 컨텍스트 사용량을 확인할 수 없습니다.',
    quota: '계정 한도',
    quotaUnavailable: '한도 데이터를 사용할 수 없습니다.',
    source: '데이터 출처',
    input: '입력',
    cached: '캐시',
    output: '출력',
    resetsIn: '재설정까지',
    resetCredits: '재설정 크레딧',
    available: '개 사용 가능',
    resetCreditsUnavailable: '재설정 크레딧 데이터를 사용할 수 없습니다.',
    noResetCreditDetails: '재설정 크레딧 세부 정보가 없습니다.',
  );
}
