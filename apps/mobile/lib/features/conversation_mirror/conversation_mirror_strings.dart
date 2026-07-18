import 'package:flutter/widgets.dart';

class ConversationMirrorStrings {
  const ConversationMirrorStrings._(this.languageCode);

  final String languageCode;

  static ConversationMirrorStrings of(BuildContext context) =>
      ConversationMirrorStrings._(
        Localizations.localeOf(context).languageCode.toLowerCase(),
      );

  bool get _zh => languageCode == 'zh';
  bool get _ja => languageCode == 'ja';
  bool get _ko => languageCode == 'ko';

  String get downloadAndSync {
    if (_zh) return '下载会话文本与工具记录并自动同步';
    if (_ja) return '会話のテキストとツール履歴を保存して自動同期';
    if (_ko) return '대화 텍스트와 도구 기록 저장 및 자동 동기화';
    return 'Save conversation text and tool history with auto-sync';
  }

  String get syncNow {
    if (_zh) return '立即同步手机副本';
    if (_ja) return 'モバイルコピーを今すぐ同期';
    if (_ko) return '휴대폰 사본 지금 동기화';
    return 'Sync phone copy now';
  }

  String get removeLocalCopy {
    if (_zh) return '删除手机副本';
    if (_ja) return 'モバイルコピーを削除';
    if (_ko) return '휴대폰 사본 삭제';
    return 'Remove phone copy';
  }

  String get downloading {
    if (_zh) return '正在下载可恢复的文本与工具记录…';
    if (_ja) return '復元可能なテキストとツール履歴を保存中…';
    if (_ko) return '복원 가능한 텍스트와 도구 기록 저장 중…';
    return 'Saving recoverable text and tool history…';
  }

  String get syncing {
    if (_zh) return '正在对账并同步新增内容…';
    if (_ja) return '差分を確認して新しい内容を同期中…';
    if (_ko) return '변경 사항 확인 및 새 콘텐츠 동기화 중…';
    return 'Reconciling and syncing new content…';
  }

  String downloaded(int entries) {
    if (_zh) return '文本与工具记录已保存到手机（$entries 条），后续会自动增量同步';
    if (_ja) return 'テキストとツール履歴を保存しました（$entries 件）。今後は自動同期されます';
    if (_ko) return '텍스트와 도구 기록이 저장됨($entries개). 이후 자동 증분 동기화됩니다';
    return 'Text and tool history saved ($entries entries); incremental auto-sync is on';
  }

  String get upToDate {
    if (_zh) return '手机副本已经是最新';
    if (_ja) return 'モバイルコピーは最新です';
    if (_ko) return '휴대폰 사본이 최신입니다';
    return 'The phone copy is up to date';
  }

  String get removed {
    if (_zh) return '已删除手机副本';
    if (_ja) return 'モバイルコピーを削除しました';
    if (_ko) return '휴대폰 사본을 삭제했습니다';
    return 'Phone copy removed';
  }

  String get unavailableForProvider {
    if (_zh) return '首版手机会话镜像仅支持 Codex 会话';
    if (_ja) return '初版のモバイル会話ミラーは Codex 会話のみ対応しています';
    if (_ko) return '첫 휴대폰 대화 미러는 Codex 대화만 지원합니다';
    return 'Phone conversation mirrors currently support Codex only';
  }

  String get bridgeUpdateRequired {
    if (_zh) return '当前 Bridge 不支持会话镜像，已保留原来的加载方式';
    if (_ja) return '現在の Bridge は会話ミラーに未対応です。従来の読み込みを使用します';
    if (_ko) return '현재 Bridge는 대화 미러를 지원하지 않아 기존 로딩을 유지합니다';
    return 'This Bridge does not support conversation mirrors; existing loading remains active';
  }

  String failed(String detail) {
    if (_zh) return '会话同步失败：$detail';
    if (_ja) return '会話の同期に失敗しました：$detail';
    if (_ko) return '대화 동기화 실패: $detail';
    return 'Conversation sync failed: $detail';
  }

  String get localCopyTooltip {
    if (_zh) return '已保存到手机；连接时自动同步';
    if (_ja) return 'モバイルに保存済み。接続中に自動同期';
    if (_ko) return '휴대폰에 저장됨 · 연결 시 자동 동기화';
    return 'Saved on phone; auto-syncs while connected';
  }

  String get syncingTooltip {
    if (_zh) return '正在同步手机副本';
    if (_ja) return 'モバイルコピーを同期中';
    if (_ko) return '휴대폰 사본 동기화 중';
    return 'Syncing phone copy';
  }
}
