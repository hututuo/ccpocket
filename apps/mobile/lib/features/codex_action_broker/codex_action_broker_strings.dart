import 'package:flutter/widgets.dart';

import 'codex_action_broker_service.dart';

class CodexActionBrokerStrings {
  const CodexActionBrokerStrings._({
    required this.needYou,
    required this.refresh,
    required this.reject,
    required this.loading,
    required this.submitting,
    required this.awaitingCanonical,
    required this.reconnecting,
    required this.writerLeaseUnavailable,
    required this.handledElsewhere,
    required this.unsupportedRequest,
    required this.stale,
    required this.unavailable,
    required this.invalid,
  });

  final String needYou;
  final String refresh;
  final String reject;
  final String loading;
  final String submitting;
  final String awaitingCanonical;
  final String reconnecting;
  final String writerLeaseUnavailable;
  final String handledElsewhere;
  final String unsupportedRequest;
  final String stale;
  final String unavailable;
  final String invalid;

  static CodexActionBrokerStrings of(BuildContext context) =>
      switch (Localizations.localeOf(context).languageCode) {
        'zh' => _zh,
        'ja' => _ja,
        'ko' => _ko,
        _ => _en,
      };

  String messageFor(CodexActionBrokerInteractionPhase phase) => switch (phase) {
    CodexActionBrokerInteractionPhase.inactive => '',
    CodexActionBrokerInteractionPhase.loading => loading,
    CodexActionBrokerInteractionPhase.actionable => '',
    CodexActionBrokerInteractionPhase.submitting => submitting,
    CodexActionBrokerInteractionPhase.awaitingCanonical => awaitingCanonical,
    CodexActionBrokerInteractionPhase.reconnecting => reconnecting,
    CodexActionBrokerInteractionPhase.writerLeaseUnavailable =>
      writerLeaseUnavailable,
    CodexActionBrokerInteractionPhase.handledElsewhere => handledElsewhere,
    CodexActionBrokerInteractionPhase.unsupportedRequest => unsupportedRequest,
    CodexActionBrokerInteractionPhase.stale => stale,
    CodexActionBrokerInteractionPhase.unavailable => unavailable,
    CodexActionBrokerInteractionPhase.invalid => invalid,
  };

  static const _en = CodexActionBrokerStrings._(
    needYou: 'Need You',
    refresh: 'Refresh',
    reject: 'Reject',
    loading: 'Loading the current Codex request…',
    submitting: 'Sending your response…',
    awaitingCanonical: 'Sent. Waiting for Codex to confirm resolution…',
    reconnecting: 'Reconnecting to the Codex action broker…',
    writerLeaseUnavailable: 'Bridge is waiting for action-control ownership…',
    handledElsewhere: 'This request is being handled on another client.',
    unsupportedRequest: 'Handle this request in Codex Desktop.',
    stale: 'The turn or data source changed. Refreshing the request…',
    unavailable: 'This request is visible but cannot be changed right now.',
    invalid: 'Codex rejected this response. Refresh before trying again.',
  );

  static const _zh = CodexActionBrokerStrings._(
    needYou: '需要你处理',
    refresh: '刷新',
    reject: '拒绝',
    loading: '正在读取当前 Codex 请求…',
    submitting: '正在提交你的操作…',
    awaitingCanonical: '已提交，正在等待 Codex 确认请求已解决…',
    reconnecting: '正在重新连接 Codex 操作代理…',
    writerLeaseUnavailable: 'Bridge 正在等待取得操作控制权…',
    handledElsewhere: '此请求正在另一端处理。',
    unsupportedRequest: '此类请求请在 Codex Desktop 中处理。',
    stale: '会话来源或当前回合已变化，正在刷新请求…',
    unavailable: '请求仍可查看，但当前不能操作。',
    invalid: 'Codex 拒绝了这次操作，请刷新后再试。',
  );

  static const _ja = CodexActionBrokerStrings._(
    needYou: '確認が必要',
    refresh: '更新',
    reject: '拒否',
    loading: 'Codex の現在の要求を読み込んでいます…',
    submitting: '応答を送信しています…',
    awaitingCanonical: '送信済みです。Codex の確定を待っています…',
    reconnecting: 'Codex アクションブローカーに再接続しています…',
    writerLeaseUnavailable: 'Bridge が操作権限を待っています…',
    handledElsewhere: 'この要求は別のクライアントで処理中です。',
    unsupportedRequest: 'Codex Desktop で処理してください。',
    stale: 'ターンまたはデータ元が変わりました。更新しています…',
    unavailable: '要求は表示できますが、現在は操作できません。',
    invalid: 'Codex が応答を拒否しました。更新して再試行してください。',
  );

  static const _ko = CodexActionBrokerStrings._(
    needYou: '확인 필요',
    refresh: '새로고침',
    reject: '거부',
    loading: '현재 Codex 요청을 불러오는 중…',
    submitting: '응답을 보내는 중…',
    awaitingCanonical: '전송됨. Codex의 최종 확인을 기다리는 중…',
    reconnecting: 'Codex 작업 브로커에 다시 연결하는 중…',
    writerLeaseUnavailable: 'Bridge가 작업 제어 권한을 기다리는 중…',
    handledElsewhere: '다른 클라이언트에서 이 요청을 처리 중입니다.',
    unsupportedRequest: 'Codex Desktop에서 이 요청을 처리하세요.',
    stale: '턴 또는 데이터 원본이 변경되어 요청을 새로고침하는 중…',
    unavailable: '요청을 볼 수 있지만 지금은 조작할 수 없습니다.',
    invalid: 'Codex가 응답을 거부했습니다. 새로고침 후 다시 시도하세요.',
  );
}
