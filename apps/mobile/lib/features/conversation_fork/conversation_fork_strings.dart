import 'package:flutter/widgets.dart';

class ConversationForkStrings {
  const ConversationForkStrings._(this.languageCode);

  final String languageCode;

  static ConversationForkStrings of(BuildContext context) =>
      ConversationForkStrings._(
        Localizations.localeOf(context).languageCode.toLowerCase(),
      );

  bool get _zh => languageCode == 'zh';
  bool get _ja => languageCode == 'ja';
  bool get _ko => languageCode == 'ko';

  String get currentConversationBody {
    if (_zh) return '从当前完整进度创建一个新的 Codex 会话。原会话不会改变。';
    if (_ja) return '現在の完全な進行状況から新しい Codex 会話を作成します。元の会話は変更されません。';
    if (_ko) return '현재 전체 진행 상태에서 새 Codex 대화를 만듭니다. 원본 대화는 변경되지 않습니다.';
    return 'Create a new Codex conversation from the current complete state. The original conversation will not change.';
  }

  String get selectedTextBody {
    if (_zh) return '从当前完整进度创建一个新的 Codex 会话，并把选中文本放入新会话输入框。';
    if (_ja) return '現在の完全な進行状況から新しい Codex 会話を作成し、選択したテキストを入力欄に入れます。';
    if (_ko) return '현재 전체 진행 상태에서 새 Codex 대화를 만들고 선택한 텍스트를 입력창에 넣습니다.';
    return 'Create a new Codex conversation from the current complete state and place the selected text in its composer.';
  }

  String get idleRequired {
    if (_zh) return '会话正在运行或有排队消息，请在本轮结束后再分叉。';
    if (_ja) return '会話が実行中またはメッセージが待機中です。このターンの終了後に分岐してください。';
    if (_ko) return '대화가 실행 중이거나 메시지가 대기 중입니다. 이번 턴이 끝난 뒤 포크하세요.';
    return 'The conversation is running or has queued input. Fork it after the current turn finishes.';
  }
}
