import 'package:flutter/widgets.dart';

class CacheManagementStrings {
  const CacheManagementStrings._(this.languageCode);

  final String languageCode;

  static CacheManagementStrings of(BuildContext context) =>
      CacheManagementStrings._(
        Localizations.localeOf(context).languageCode.toLowerCase(),
      );

  bool get _zh => languageCode == 'zh';
  bool get _ja => languageCode == 'ja';
  bool get _ko => languageCode == 'ko';

  String get title {
    if (_zh) return '存储与缓存';
    if (_ja) return 'ストレージとキャッシュ';
    if (_ko) return '저장 공간 및 캐시';
    return 'Storage & cache';
  }

  String summary(int localCopies) {
    if (_zh) return '$localCopies 个会话历史保存在手机，可管理目录缓存';
    if (_ja) return '端末に保存済みの会話履歴 $localCopies 件と一覧キャッシュを管理';
    if (_ko) return '휴대폰에 저장된 대화 기록 $localCopies개 및 목록 캐시 관리';
    return '$localCopies downloaded histories; manage catalog cache';
  }

  String get temporaryCacheSection {
    if (_zh) return '临时缓存';
    if (_ja) return '一時キャッシュ';
    if (_ko) return '임시 캐시';
    return 'Temporary cache';
  }

  String get catalogCacheTitle {
    if (_zh) return '会话目录与最近消息缓存';
    if (_ja) return '会話一覧と最近のメッセージのキャッシュ';
    if (_ko) return '대화 목록 및 최근 메시지 캐시';
    return 'Conversation catalog & recent-message cache';
  }

  String catalogCacheSubtitle({required int summaries, required int windows}) {
    if (_zh) {
      return '$summaries 个会话摘要 · $windows 个最近消息窗口。'
          '一键清理会删除所有已连接 Mac 的这两类可重建缓存；已下载的完整历史不受影响。';
    }
    if (_ja) {
      return '概要 $summaries 件 · 最近のメッセージ $windows 件。'
          'すべての接続済み Mac の再構築可能なキャッシュだけを消去し、'
          'ダウンロード済みの完全な履歴は保持します。';
    }
    if (_ko) {
      return '대화 요약 $summaries개 · 최근 메시지 창 $windows개. '
          '연결했던 모든 Mac의 재구성 가능한 캐시만 지우며 '
          '다운로드한 전체 기록은 유지됩니다.';
    }
    return '$summaries summaries · $windows recent-message windows. '
        'Clears these rebuildable caches for every connected Mac; downloaded '
        'full histories are kept.';
  }

  String get clear {
    if (_zh) return '一键清理';
    if (_ja) return '消去';
    if (_ko) return '한 번에 지우기';
    return 'Clear';
  }

  String get clearing {
    if (_zh) return '正在清理…';
    if (_ja) return '消去中…';
    if (_ko) return '삭제 중…';
    return 'Clearing…';
  }

  String get cacheCleared {
    if (_zh) return '会话目录与最近消息缓存已清理；完整下载历史和电脑会话均未改变';
    if (_ja) return '一覧と最近のメッセージのキャッシュを消去しました。完全な履歴と Mac の会話は変更されません';
    if (_ko) return '목록과 최근 메시지 캐시를 지웠습니다. 전체 기록과 Mac 대화는 변경되지 않았습니다';
    return 'Catalog and recent-message caches cleared; downloaded histories '
        'and Mac conversations were unchanged';
  }

  String get downloadedSection {
    if (_zh) return '已下载的会话历史';
    if (_ja) return 'ダウンロード済みの会話履歴';
    if (_ko) return '다운로드한 대화 기록';
    return 'Downloaded conversation histories';
  }

  String get noDownloadedHistories {
    if (_zh) return '手机上暂时没有完整会话副本';
    if (_ja) return '端末に完全な会話コピーはありません';
    if (_ko) return '휴대폰에 전체 대화 사본이 없습니다';
    return 'No full conversation copies are stored on this phone';
  }

  String downloadedSubtitle({
    required int entries,
    required String bytes,
    required bool resident,
  }) {
    final status = resident
        ? (_zh
              ? '自动同步'
              : _ja
              ? '自動同期'
              : _ko
              ? '자동 동기화'
              : 'auto-sync')
        : (_zh
              ? '仅保留副本'
              : _ja
              ? 'コピーのみ'
              : _ko
              ? '사본만 보관'
              : 'saved copy');
    if (_zh) return '$entries 条记录 · $bytes · $status';
    if (_ja) return '$entries 件 · $bytes · $status';
    if (_ko) return '$entries개 · $bytes · $status';
    return '$entries records · $bytes · $status';
  }

  String get removeCopy {
    if (_zh) return '删除手机副本';
    if (_ja) return '端末のコピーを削除';
    if (_ko) return '휴대폰 사본 삭제';
    return 'Remove phone copy';
  }

  String get removeCopyWarning {
    if (_zh) return '只会删除这台手机上的完整历史和自动同步设置，不会删除电脑上的 Codex 会话。';
    if (_ja) return 'この端末の履歴と自動同期設定だけを削除します。Mac 上の Codex 会話は削除されません。';
    if (_ko) return '이 휴대폰의 기록과 자동 동기화 설정만 삭제합니다. Mac의 Codex 대화는 삭제되지 않습니다.';
    return 'This removes only the history and auto-sync setting on this phone. '
        'The Codex conversation on your Mac is not deleted.';
  }

  String get cancel {
    if (_zh) return '取消';
    if (_ja) return 'キャンセル';
    if (_ko) return '취소';
    return 'Cancel';
  }

  String get removed {
    if (_zh) return '手机会话副本已删除';
    if (_ja) return '端末の会話コピーを削除しました';
    if (_ko) return '휴대폰 대화 사본을 삭제했습니다';
    return 'Phone conversation copy removed';
  }

  String failed(String detail) {
    if (_zh) return '存储操作失败：$detail';
    if (_ja) return 'ストレージ操作に失敗しました：$detail';
    if (_ko) return '저장 공간 작업 실패: $detail';
    return 'Storage operation failed: $detail';
  }
}
