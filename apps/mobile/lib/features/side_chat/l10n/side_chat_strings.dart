import 'package:flutter/widgets.dart';

/// Feature-local strings keep the removable side-chat module out of the
/// upstream ARB/generated-localization surface.
class SideChatStrings {
  const SideChatStrings({
    required this.title,
    required this.selectionAction,
    required this.isolationNotice,
    required this.placeholder,
    required this.empty,
    required this.opening,
    required this.closing,
    required this.disconnected,
    required this.closed,
    required this.failed,
    required this.reopen,
    required this.send,
    required this.interrupt,
    required this.close,
    required this.allow,
    required this.allowAlways,
    required this.deny,
    required this.permissionTitle,
    required this.sending,
    required this.sendFailed,
    required this.inputTooLong,
    required this.bridgeUpdateRequired,
  });

  final String title;
  final String selectionAction;
  final String isolationNotice;
  final String placeholder;
  final String empty;
  final String opening;
  final String closing;
  final String disconnected;
  final String closed;
  final String failed;
  final String reopen;
  final String send;
  final String interrupt;
  final String close;
  final String allow;
  final String allowAlways;
  final String deny;
  final String permissionTitle;
  final String sending;
  final String sendFailed;
  final String inputTooLong;
  final String bridgeUpdateRequired;

  static SideChatStrings of(BuildContext context) =>
      forLocale(Localizations.localeOf(context));

  static SideChatStrings forLocale(Locale locale) =>
      switch (locale.languageCode) {
        'zh' => _zh,
        'ja' => _ja,
        'ko' => _ko,
        _ => _en,
      };

  String errorFor(String? code, String? detail) {
    if (code == 'bridge_update_required') return bridgeUpdateRequired;
    if (detail != null && detail.trim().isNotEmpty) return detail;
    return switch (code) {
      'bridge_disconnected' => disconnected,
      'open_timeout' => opening,
      'close_timeout' => closing,
      'input_too_long' => inputTooLong,
      _ => failed,
    };
  }

  static const _en = SideChatStrings(
    title: 'Side chat',
    selectionAction: 'Fork with selected text',
    isolationNotice:
        'Side chats are not saved; closing or reconnecting starts with an empty transcript. File changes remain shared in the same worktree.',
    placeholder: 'Ask in this side chat…',
    empty:
        'Start a separate conversation without changing the main transcript.',
    opening: 'Opening side chat…',
    closing: 'Closing side chat…',
    disconnected: 'Reconnect to the Bridge to continue.',
    closed: 'Side chat closed.',
    failed: 'Side chat could not continue.',
    reopen: 'Reopen',
    send: 'Send',
    interrupt: 'Interrupt',
    close: 'Close',
    allow: 'Allow',
    allowAlways: 'Always allow',
    deny: 'Deny',
    permissionTitle: 'Permission requested',
    sending: 'Sending…',
    sendFailed: 'Not sent',
    inputTooLong: 'The draft is too long to send.',
    bridgeUpdateRequired: 'Update the Bridge to use side chat.',
  );

  static const _zh = SideChatStrings(
    title: '侧边聊天',
    selectionAction: '用选中文本分叉会话',
    isolationNotice: '侧边聊天不会保存；关闭或重连后会从空记录开始。同一 worktree 中的文件改动仍会共享。',
    placeholder: '在侧边聊天中提问…',
    empty: '在不改变主会话记录的情况下开始独立对话。',
    opening: '正在打开侧边聊天…',
    closing: '正在关闭侧边聊天…',
    disconnected: '请重新连接 Bridge 后继续。',
    closed: '侧边聊天已关闭。',
    failed: '侧边聊天暂时无法继续。',
    reopen: '重新打开',
    send: '发送',
    interrupt: '中断',
    close: '关闭',
    allow: '允许',
    allowAlways: '始终允许',
    deny: '拒绝',
    permissionTitle: '需要权限',
    sending: '发送中…',
    sendFailed: '未发送',
    inputTooLong: '草稿过长，无法发送。',
    bridgeUpdateRequired: '请更新 Bridge 后再使用侧边聊天。',
  );

  static const _ja = SideChatStrings(
    title: 'サイドチャット',
    selectionAction: '選択したテキストで会話を分岐',
    isolationNotice:
        'サイドチャットは保存されず、終了または再接続後は空の履歴から始まります。同じ worktree のファイル変更は共有されます。',
    placeholder: 'サイドチャットで質問…',
    empty: 'メインの履歴を変えずに別の会話を始めます。',
    opening: 'サイドチャットを開いています…',
    closing: 'サイドチャットを閉じています…',
    disconnected: 'Bridge に再接続してください。',
    closed: 'サイドチャットを閉じました。',
    failed: 'サイドチャットを続行できません。',
    reopen: '再度開く',
    send: '送信',
    interrupt: '中断',
    close: '閉じる',
    allow: '許可',
    allowAlways: '常に許可',
    deny: '拒否',
    permissionTitle: '権限が必要です',
    sending: '送信中…',
    sendFailed: '未送信',
    inputTooLong: '下書きが長すぎます。',
    bridgeUpdateRequired: 'サイドチャットを使用するには Bridge を更新してください。',
  );

  static const _ko = SideChatStrings(
    title: '사이드 채팅',
    selectionAction: '선택한 텍스트로 대화 포크',
    isolationNotice:
        '사이드 채팅은 저장되지 않으며 닫거나 다시 연결하면 빈 기록으로 시작합니다. 같은 worktree의 파일 변경은 계속 공유됩니다.',
    placeholder: '사이드 채팅에서 질문…',
    empty: '기본 대화 기록을 바꾸지 않고 별도 대화를 시작합니다.',
    opening: '사이드 채팅을 여는 중…',
    closing: '사이드 채팅을 닫는 중…',
    disconnected: 'Bridge에 다시 연결해 주세요.',
    closed: '사이드 채팅이 닫혔습니다.',
    failed: '사이드 채팅을 계속할 수 없습니다.',
    reopen: '다시 열기',
    send: '보내기',
    interrupt: '중단',
    close: '닫기',
    allow: '허용',
    allowAlways: '항상 허용',
    deny: '거부',
    permissionTitle: '권한 필요',
    sending: '보내는 중…',
    sendFailed: '전송되지 않음',
    inputTooLong: '초안이 너무 깁니다.',
    bridgeUpdateRequired: '사이드 채팅을 사용하려면 Bridge를 업데이트하세요.',
  );
}
