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
    if (_zh) return '设为常驻会话（完整下载并自动同步）';
    if (_ja) return '会話のテキストとツール履歴を保存して自動同期';
    if (_ko) return '대화 텍스트와 도구 기록 저장 및 자동 동기화';
    return 'Keep resident (download fully and auto-sync)';
  }

  String get stopResident {
    if (_zh) return '取消常驻（保留手机副本）';
    if (_ja) return '常駐を解除（モバイルコピーは保持）';
    if (_ko) return '상주 해제(휴대폰 사본 유지)';
    return 'Stop residency (keep phone copy)';
  }

  String get residentTitle {
    if (_zh) return '常驻会话';
    if (_ja) return '常駐会話';
    if (_ko) return '상주 대화';
    return 'Resident conversations';
  }

  String get manageResident {
    if (_zh) return '常驻与完整同步';
    if (_ja) return '常駐と完全同期';
    if (_ko) return '상주 및 전체 동기화';
    return 'Residency and full sync';
  }

  String get waitingForConversationIdentity {
    if (_zh) return '正在等待 Codex 建立可持久化的会话 ID…';
    if (_ja) return 'Codex の永続会話 ID を待っています…';
    if (_ko) return 'Codex 영구 대화 ID를 기다리는 중…';
    return 'Waiting for Codex to establish a durable conversation ID…';
  }

  String residentEntries(int entries) {
    if (_zh) return '手机已保存 $entries 条记录';
    if (_ja) return 'モバイルに $entries 件保存済み';
    if (_ko) return '휴대폰에 $entries개 기록 저장됨';
    return '$entries records stored on the phone';
  }

  String get residentSubtitle {
    if (_zh) return '完整保存在手机；APP 打开且已连接时自动增量同步';
    if (_ja) return '端末に完全保存し、接続中は自動的に差分同期します';
    if (_ko) return '휴대폰에 완전히 저장하고 연결 중 자동 증분 동기화';
    return 'Fully stored on phone and incrementally synced while connected';
  }

  String get runningPrefix {
    if (_zh) return '进行中 · ';
    if (_ja) return '実行中 · ';
    if (_ko) return '실행 중 · ';
    return 'Running · ';
  }

  String get removeLocalCopyWarning {
    if (_zh) return '只会删除手机里的完整副本并取消常驻，不会删除电脑上的 Codex 会话。';
    if (_ja) return '端末内の完全コピーと常駐設定だけを削除し、Mac 上の Codex 会話は削除しません。';
    if (_ko) return '휴대폰의 전체 사본과 상주 설정만 삭제하며 Mac의 Codex 대화는 삭제하지 않습니다.';
    return 'This removes only the full phone copy and residency; the Codex conversation on your Mac is not deleted.';
  }

  String get cancel {
    if (_zh) return '取消';
    if (_ja) return 'キャンセル';
    if (_ko) return '취소';
    return 'Cancel';
  }

  String get connectToDownload {
    if (_zh) return '首次常驻需要先连接 Bridge；已有手机副本可离线开启常驻。';
    if (_ja) return '初回の常駐には Bridge 接続が必要です。既存の端末コピーはオフラインでも常駐にできます。';
    if (_ko) {
      return '처음 상주하려면 Bridge 연결이 필요합니다. 기존 휴대폰 사본은 오프라인에서도 상주로 전환할 수 있습니다.';
    }
    return 'Connect to the Bridge for the first full download; an existing phone copy can be made resident offline.';
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

  String get residencyStopped {
    if (_zh) return '已取消常驻；手机副本仍保留';
    if (_ja) return '常駐を解除しました。モバイルコピーは保持されます';
    if (_ko) return '상주를 해제했습니다. 휴대폰 사본은 유지됩니다';
    return 'Residency stopped; the phone copy was kept';
  }

  String get residentLimitReached {
    if (_zh) return '最多可同时常驻 8 个会话，请先取消一个';
    if (_ja) return '常駐できる会話は最大8件です。先に1件解除してください';
    if (_ko) return '동시에 최대 8개 대화만 상주할 수 있습니다';
    return 'Up to 8 conversations can stay resident; remove one first';
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
    if (_zh) return '常驻在手机；连接时自动增量同步';
    if (_ja) return 'モバイルに保存済み。接続中に自動同期';
    if (_ko) return '휴대폰에 저장됨 · 연결 시 자동 동기화';
    return 'Resident on phone; incrementally syncs while connected';
  }

  String get savedCopyTooltip {
    if (_zh) return '手机中有完整副本；当前未常驻';
    if (_ja) return 'モバイルに完全なコピーがあります。現在は常駐していません';
    if (_ko) return '휴대폰에 전체 사본이 있지만 현재 상주하지 않음';
    return 'A full phone copy exists but is not currently resident';
  }

  String get syncingTooltip {
    if (_zh) return '正在同步手机副本';
    if (_ja) return 'モバイルコピーを同期中';
    if (_ko) return '휴대폰 사본 동기화 중';
    return 'Syncing phone copy';
  }
}
