import 'package:flutter/widgets.dart';

class SessionArchiveStrings {
  const SessionArchiveStrings._(this.languageCode);

  final String languageCode;

  static SessionArchiveStrings of(BuildContext context) =>
      SessionArchiveStrings._(
        Localizations.localeOf(context).languageCode.toLowerCase(),
      );

  bool get _zh => languageCode == 'zh';
  bool get _ja => languageCode == 'ja';
  bool get _ko => languageCode == 'ko';

  String get title {
    if (_zh) return '已归档会话';
    if (_ja) return 'アーカイブ済み会話';
    if (_ko) return '보관된 대화';
    return 'Archived sessions';
  }

  String get empty {
    if (_zh) return '这里还没有归档会话';
    if (_ja) return 'アーカイブ済みの会話はありません';
    if (_ko) return '보관된 대화가 없습니다';
    return 'No archived sessions';
  }

  String get restore {
    if (_zh) return '恢复';
    if (_ja) return '復元';
    if (_ko) return '복원';
    return 'Restore';
  }

  String get deletePermanently {
    if (_zh) return '永久删除';
    if (_ja) return '完全に削除';
    if (_ko) return '영구 삭제';
    return 'Delete permanently';
  }

  String get deleteTitle {
    if (_zh) return '永久删除这个 Codex 会话？';
    if (_ja) return 'この Codex 会話を完全に削除しますか？';
    if (_ko) return '이 Codex 대화를 영구 삭제할까요?';
    return 'Permanently delete this Codex session?';
  }

  String get deleteWarning {
    if (_zh) {
      return '此操作不可撤销。Codex 会同时删除这个会话派生出的所有子会话。请输入 DELETE 以确认。';
    }
    if (_ja) {
      return '元に戻せません。Codex はこの会話から派生した子会話も削除します。確認のため DELETE と入力してください。';
    }
    if (_ko) {
      return '되돌릴 수 없습니다. Codex는 이 대화에서 생성된 하위 대화도 함께 삭제합니다. 확인하려면 DELETE를 입력하세요.';
    }
    return 'This cannot be undone. Codex also deletes every spawned descendant of this session. Type DELETE to confirm.';
  }

  String get typeDelete {
    if (_zh) return '输入 DELETE';
    if (_ja) return 'DELETE と入力';
    if (_ko) return 'DELETE 입력';
    return 'Type DELETE';
  }

  String get cancel {
    if (_zh) return '取消';
    if (_ja) return 'キャンセル';
    if (_ko) return '취소';
    return 'Cancel';
  }

  String get unsupported {
    if (_zh) return '当前 Bridge 不支持归档管理，请先更新 Bridge';
    if (_ja) return '現在の Bridge はアーカイブ管理に対応していません';
    if (_ko) return '현재 Bridge는 보관함 관리를 지원하지 않습니다';
    return 'Update the Bridge to manage archived sessions';
  }

  String get truncated {
    if (_zh) return '仅显示最近 1000 个归档会话';
    if (_ja) return '直近 1000 件のみ表示しています';
    if (_ko) return '최근 1000개만 표시합니다';
    return 'Showing the 1,000 most recent archived sessions';
  }

  String get restored {
    if (_zh) return '会话已恢复';
    if (_ja) return '会話を復元しました';
    if (_ko) return '대화를 복원했습니다';
    return 'Session restored';
  }

  String get deleted {
    if (_zh) return '会话及其派生子会话已永久删除';
    if (_ja) return '会話と派生した子会話を削除しました';
    if (_ko) return '대화와 파생된 하위 대화를 영구 삭제했습니다';
    return 'Session and spawned descendants deleted';
  }

  String failed(String detail) {
    if (_zh) return '操作失败：$detail';
    if (_ja) return '操作に失敗しました：$detail';
    if (_ko) return '작업 실패: $detail';
    return 'Operation failed: $detail';
  }
}
