import 'package:flutter/widgets.dart';

class FileBrowserStrings {
  const FileBrowserStrings._(this.languageCode);

  final String languageCode;

  static FileBrowserStrings of(BuildContext context) => FileBrowserStrings._(
    Localizations.localeOf(context).languageCode.toLowerCase(),
  );

  bool get _zh => languageCode == 'zh';
  bool get _ja => languageCode == 'ja';
  bool get _ko => languageCode == 'ko';

  String get title {
    if (_zh) return '文件';
    if (_ja) return 'ファイル';
    if (_ko) return '파일';
    return 'Files';
  }

  String get locations {
    if (_zh) return '位置';
    if (_ja) return '場所';
    if (_ko) return '위치';
    return 'Locations';
  }

  String get pinned {
    if (_zh) return '已固定';
    if (_ja) return 'ピン留め';
    if (_ko) return '고정됨';
    return 'Pinned';
  }

  String get pinFolder {
    if (_zh) return '固定文件夹';
    if (_ja) return 'フォルダをピン留め';
    if (_ko) return '폴더 고정';
    return 'Pin folder';
  }

  String get unpinFolder {
    if (_zh) return '取消固定';
    if (_ja) return 'ピン留めを解除';
    if (_ko) return '고정 해제';
    return 'Unpin folder';
  }

  String get pinRequiresSavedMachine {
    if (_zh) return '保存这个 Mac 连接后才能固定文件夹';
    if (_ja) return 'この Mac 接続を保存するとフォルダをピン留めできます';
    if (_ko) return '이 Mac 연결을 저장하면 폴더를 고정할 수 있습니다';
    return 'Save this Mac connection to pin folders';
  }

  String get showHidden {
    if (_zh) return '显示隐藏文件';
    if (_ja) return '隠しファイルを表示';
    if (_ko) return '숨김 파일 표시';
    return 'Show hidden files';
  }

  String get hideHidden {
    if (_zh) return '隐藏隐藏文件';
    if (_ja) return '隠しファイルを非表示';
    if (_ko) return '숨김 파일 숨기기';
    return 'Hide hidden files';
  }

  String get emptyFolder {
    if (_zh) return '这个文件夹是空的';
    if (_ja) return 'このフォルダは空です';
    if (_ko) return '이 폴더는 비어 있습니다';
    return 'This folder is empty';
  }

  String get noLocations {
    if (_zh) return '没有可用位置';
    if (_ja) return '利用できる場所がありません';
    if (_ko) return '사용 가능한 위치가 없습니다';
    return 'No locations available';
  }

  String get noLocationsBody {
    if (_zh) return '在 Mac 的 Bridge 配置中加入允许浏览的文件夹后，这里会自动显示。';
    if (_ja) return 'Mac の Bridge 設定で参照可能なフォルダを追加すると、ここに表示されます。';
    if (_ko) return 'Mac Bridge 설정에 탐색할 폴더를 추가하면 여기에 표시됩니다.';
    return 'Add an allowed folder in the Mac Bridge settings and it will appear here.';
  }

  String get directoryLimitReached {
    if (_zh) return '为保证手机性能，这个文件夹只显示已加载的前 5000 项';
    if (_ja) return '端末の性能を保つため、このフォルダは読み込んだ先頭 5000 件まで表示します';
    if (_ko) return '휴대폰 성능을 위해 이 폴더는 불러온 처음 5000개 항목만 표시합니다';
    return 'To protect phone performance, this folder shows the first 5,000 loaded items.';
  }

  String get disconnected {
    if (_zh) return '连接 Mac 后即可浏览文件';
    if (_ja) return 'Mac に接続するとファイルを参照できます';
    if (_ko) return 'Mac에 연결하면 파일을 탐색할 수 있습니다';
    return 'Connect to your Mac to browse files';
  }

  String get updateBridgeTitle {
    if (_zh) return '需要更新 Bridge';
    if (_ja) return 'Bridge の更新が必要です';
    if (_ko) return 'Bridge 업데이트가 필요합니다';
    return 'Update the Bridge';
  }

  String get updateBridgeBody {
    if (_zh) return '当前 Mac 后端不支持文件管理。更新 CC Pocket Bridge 后，这个入口会自动启用。';
    if (_ja) return '現在の Mac Bridge はファイル管理に対応していません。更新後に自動で有効になります。';
    if (_ko) return '현재 Mac Bridge는 파일 관리를 지원하지 않습니다. 업데이트하면 자동으로 활성화됩니다.';
    return 'This Mac Bridge does not support file management yet. The entry enables automatically after the Bridge is updated.';
  }

  String get loadFailed {
    if (_zh) return '无法读取这个位置';
    if (_ja) return 'この場所を読み込めません';
    if (_ko) return '이 위치를 읽을 수 없습니다';
    return 'Could not read this location';
  }

  String get preview {
    if (_zh) return '预览';
    if (_ja) return 'プレビュー';
    if (_ko) return '미리보기';
    return 'Preview';
  }

  String get downloadStarted {
    if (_zh) return '已加入下载队列';
    if (_ja) return 'ダウンロードキューに追加しました';
    if (_ko) return '다운로드 대기열에 추가됨';
    return 'Added to the download queue';
  }

  String get downloadUnavailable {
    if (_zh) return '这个文件当前无法下载';
    if (_ja) return 'このファイルは現在ダウンロードできません';
    if (_ko) return '현재 이 파일을 다운로드할 수 없습니다';
    return 'This file cannot be downloaded right now';
  }

  String get downloadRequiresSavedMachine {
    if (_zh) return '先保存这台 Mac 的连接，才能把文件下载到手机';
    if (_ja) return 'ファイルを手元にダウンロードするには、この Mac 接続を保存してください';
    if (_ko) return '파일을 휴대폰으로 다운로드하려면 이 Mac 연결을 먼저 저장하세요';
    return 'Save this Mac connection before downloading files';
  }

  String get previewUnavailable {
    if (_zh) return '这个文件不能直接预览，可以下载后用其他 APP 打开';
    if (_ja) return '直接プレビューできません。ダウンロードして別のアプリで開けます';
    if (_ko) return '직접 미리 볼 수 없습니다. 다운로드한 뒤 다른 앱에서 열 수 있습니다';
    return 'This file cannot be previewed directly. Download it to open in another app.';
  }

  String get changedReloaded {
    if (_zh) return '文件夹内容已变化，已重新加载';
    if (_ja) return 'フォルダが変更されたため再読み込みしました';
    if (_ko) return '폴더 내용이 변경되어 다시 불러왔습니다';
    return 'The folder changed and was reloaded';
  }

  String get paginationRestarted {
    if (_zh) return '分页已失效，已从头重新加载';
    if (_ja) return 'ページ情報の期限が切れたため、最初から再読み込みしました';
    if (_ko) return '페이지 정보가 만료되어 처음부터 다시 불러왔습니다';
    return 'The page expired and was reloaded from the beginning';
  }

  String get refresh {
    if (_zh) return '刷新';
    if (_ja) return '更新';
    if (_ko) return '새로고침';
    return 'Refresh';
  }

  String operationFailed(String detail) {
    if (_zh) return detail.isEmpty ? '操作失败' : '操作失败：$detail';
    if (_ja) return detail.isEmpty ? '操作に失敗しました' : '操作に失敗しました：$detail';
    if (_ko) return detail.isEmpty ? '작업 실패' : '작업 실패: $detail';
    return detail.isEmpty ? 'Operation failed' : 'Operation failed: $detail';
  }
}
