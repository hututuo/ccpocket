class FileTransferStrings {
  FileTransferStrings(String? languageTag)
    : languageCode = _normalizeLanguageCode(languageTag);

  final String languageCode;

  String _pick({
    required String zh,
    required String ja,
    required String ko,
    required String en,
  }) => switch (languageCode) {
    'zh' => zh,
    'ja' => ja,
    'ko' => ko,
    _ => en,
  };

  String get title =>
      _pick(zh: '文件互传', ja: 'ファイル転送', ko: '파일 전송', en: 'File Transfer');

  String get subtitle => _pick(
    zh: 'Mac 与 iPhone 双向续传',
    ja: 'Mac と iPhone 間で再開可能な双方向転送',
    ko: 'Mac과 iPhone 간 양방향 이어받기',
    en: 'Resumable Mac ↔ iPhone transfer',
  );

  String get uploadToMac => _pick(
    zh: '上传到 Mac',
    ja: 'Mac にアップロード',
    ko: 'Mac으로 업로드',
    en: 'Upload to Mac',
  );

  String get releaseToAttach => _pick(
    zh: '松手添加到对话',
    ja: 'ドロップしてこの会話に添付',
    ko: '놓아서 이 대화에 첨부',
    en: 'Release to attach to this conversation',
  );

  String get releaseToSend => _pick(
    zh: '松开发送到电脑',
    ja: 'ドロップして Mac に送信',
    ko: '놓아서 Mac으로 보내기',
    en: 'Release to send to Mac',
  );

  String get droppedFileUnreadable => _pick(
    zh: '无法读取拖入的文件。',
    ja: 'ドロップしたファイルを読み込めませんでした。',
    ko: '드롭한 파일을 읽을 수 없습니다.',
    en: 'The dropped file could not be read.',
  );

  String get waitForUploads => _pick(
    zh: '请等待文件上传完成后再发送。',
    ja: 'ファイルのアップロード完了後に送信してください。',
    ko: '파일 업로드가 끝난 후 보내 주세요.',
    en: 'Wait for file uploads to finish before sending.',
  );

  String get addingToTransferQueue => _pick(
    zh: '正在加入传输队列…',
    ja: '転送キューに追加しています…',
    ko: '전송 대기열에 추가하는 중…',
    en: 'Adding to the transfer queue…',
  );

  String get secureConnectionTransferHint => _pick(
    zh: '文件将通过当前连接安全传输',
    ja: 'ファイルは現在の接続で安全に転送されます',
    ko: '파일은 현재 연결을 통해 안전하게 전송됩니다',
    en: 'The file will use the current secure connection',
  );

  String sentWithoutDirectAttachment(String filename) => _pick(
    zh: '$filename 已发送到电脑；更新 Bridge 后可直接附加到会话。',
    ja: '$filename を Mac に送信しました。会話へ直接添付するには Bridge を更新してください。',
    ko: '$filename 파일을 Mac으로 보냈습니다. 대화에 바로 첨부하려면 Bridge를 업데이트하세요.',
    en: '$filename was sent to the Mac. Update Bridge to attach it here.',
  );

  String sentToMac(String filename) => _pick(
    zh: '$filename 已发送到电脑。',
    ja: '$filename を Mac に送信しました。',
    ko: '$filename 파일을 Mac으로 보냈습니다.',
    en: '$filename was sent to the Mac.',
  );

  String transferPaused(String filename) => _pick(
    zh: '$filename 的传输已暂停。',
    ja: '$filename の転送を一時停止しました。',
    ko: '$filename 파일 전송이 일시 중지되었습니다.',
    en: 'Transfer of $filename is paused.',
  );

  String uploadFailed(String filename) => _pick(
    zh: '$filename 上传失败。',
    ja: '$filename をアップロードできませんでした。',
    ko: '$filename 파일을 업로드하지 못했습니다.',
    en: '$filename could not be uploaded.',
  );

  String sendFailed(String filename) => _pick(
    zh: '$filename 发送失败。',
    ja: '$filename を送信できませんでした。',
    ko: '$filename 파일을 보내지 못했습니다.',
    en: '$filename could not be sent.',
  );

  String unableToQueue(String filename, Object error) => _pick(
    zh: '$filename 无法加入传输：$error',
    ja: '$filename を転送に追加できませんでした：$error',
    ko: '$filename 파일을 전송에 추가하지 못했습니다: $error',
    en: '$filename could not be added to transfer: $error',
  );

  String get ready => _pick(
    zh: '已连接，可双向传输',
    ja: '接続済み、双方向に転送できます',
    ko: '연결됨, 양방향 전송 가능',
    en: 'Connected and ready',
  );

  String unavailableStatus({
    required bool platformSupported,
    required bool connected,
  }) {
    if (!platformSupported) {
      return _pick(
        zh: '当前 iPhone 系统或 APP 构建不支持文件互传',
        ja: 'この iPhone のシステムまたはアプリはファイル転送に対応していません',
        ko: '현재 iPhone 시스템 또는 앱은 파일 전송을 지원하지 않습니다',
        en: 'This iPhone system or app build does not support File Transfer',
      );
    }
    if (!connected) {
      return _pick(
        zh: '连接 Mac 后才可文件互传',
        ja: 'ファイル転送には Mac への接続が必要です',
        ko: '파일 전송을 사용하려면 Mac에 연결하세요',
        en: 'Connect to the Mac for File Transfer',
      );
    }
    return _pick(
      zh: '当前 Bridge 不支持文件互传 V2',
      ja: '現在の Bridge はファイル転送 V2 に対応していません',
      ko: '현재 Bridge는 파일 전송 V2를 지원하지 않습니다',
      en: 'File Transfer V2 unavailable',
    );
  }

  String get filesLocation => _pick(
    zh: '接收文件：文件 App > CC Pocket > Downloads',
    ja: '受信先：ファイル App > CC Pocket > Downloads',
    ko: '받은 파일: 파일 앱 > CC Pocket > Downloads',
    en: 'Received files: Files > CC Pocket > Downloads',
  );

  String get autoResume => _pick(
    zh: '自动继续未完成传输',
    ja: '未完了の転送を自動的に再開',
    ko: '완료되지 않은 전송 자동 재개',
    en: 'Automatically resume',
  );

  String get autoResumeDescription => _pick(
    zh: '仅在同一台已连接的 Mac 上续传，不进入聊天离线队列',
    ja: '同じ接続中の Mac でのみ再開し、チャットのオフラインキューには入りません',
    ko: '연결된 동일 Mac에서만 재개하며 채팅 오프라인 대기열에는 넣지 않습니다',
    en: 'Only on the same live Mac; never enters the chat offline queue',
  );

  String get limit => _pick(
    zh: '单文件上限 15 GiB · 分块流式传输',
    ja: '1 ファイル最大 15 GiB · チャンク単位でストリーミング',
    ko: '파일당 최대 15 GiB · 청크 단위 스트리밍 전송',
    en: '15 GiB per file · streamed in chunks',
  );

  String get recent =>
      _pick(zh: '最近传输', ja: '最近の転送', ko: '최근 전송', en: 'Recent transfers');

  String get received => _pick(
    zh: '电脑发来的文件',
    ja: 'Mac から受信したファイル',
    ko: 'Mac에서 받은 파일',
    en: 'Files received from Mac',
  );

  String get preview => _pick(zh: '预览', ja: 'プレビュー', ko: '미리보기', en: 'Preview');

  String get share => _pick(zh: '分享', ja: '共有', ko: '공유', en: 'Share');

  String get saveElsewhere => _pick(
    zh: '另存到文件',
    ja: 'ファイルに別名で保存',
    ko: '파일 앱에 별도 저장',
    en: 'Save to Files',
  );

  String get savedElsewhere =>
      _pick(zh: '文件已另存', ja: 'ファイルを保存しました', ko: '파일을 저장했습니다', en: 'File saved');

  String get noRecent => _pick(
    zh: '还没有传输记录',
    ja: '転送履歴はまだありません',
    ko: '아직 전송 기록이 없습니다',
    en: 'No recent transfers',
  );

  String get pause => _pick(zh: '暂停', ja: '一時停止', ko: '일시 정지', en: 'Pause');
  String get resume => _pick(zh: '继续', ja: '再開', ko: '계속', en: 'Resume');
  String get cancel =>
      _pick(zh: '取消传输', ja: '転送をキャンセル', ko: '전송 취소', en: 'Cancel');

  String get cancelTitle => _pick(
    zh: '取消这个传输？',
    ja: 'この転送をキャンセルしますか？',
    ko: '이 전송을 취소할까요?',
    en: 'Cancel this transfer?',
  );

  String get cancelBody => _pick(
    zh: '未完成的分块和恢复凭据会被清理；已经完成的目标文件不会删除。',
    ja: '未完了のチャンクと再開情報は削除されます。完了済みのファイルは削除されません。',
    ko: '완료되지 않은 청크와 재개 정보는 삭제되며 완료된 파일은 삭제되지 않습니다.',
    en: 'Partial data and resume credentials will be removed. Completed files are never deleted.',
  );

  String get completed => _pick(zh: '已完成', ja: '完了', ko: '완료', en: 'Completed');
  String get failed => _pick(zh: '失败', ja: '失敗', ko: '실패', en: 'Failed');

  String startQueued(int count) => _pick(
    zh: '开始 $count 个待接收文件',
    ja: '待機中の $count 件の転送を開始',
    ko: '대기 중인 전송 $count개 시작',
    en: 'Start $count queued transfer(s)',
  );

  String receivedBanner(int count) => _pick(
    zh: '电脑发来了 $count 个文件',
    ja: 'Mac から $count 件のファイルを受信しました',
    ko: 'Mac에서 파일 $count개를 받았습니다',
    en: '$count file(s) received from Mac',
  );

  String get receivedNotificationTitle => _pick(
    zh: '文件已接收',
    ja: 'ファイルを受信しました',
    ko: '파일을 받았습니다',
    en: 'File received',
  );

  String receivedNotificationBody(String filename) => _pick(
    zh: '$filename 已保存到“文件”App > CC Pocket > Downloads。',
    ja: '$filename を「ファイル」App > CC Pocket > Downloads に保存しました。',
    ko: '$filename 파일을 파일 앱 > CC Pocket > Downloads에 저장했습니다.',
    en: '$filename was saved to Files > CC Pocket > Downloads.',
  );

  String get pausedNotificationTitle => _pick(
    zh: '文件传输已暂停',
    ja: 'ファイル転送を一時停止しました',
    ko: '파일 전송이 일시 정지되었습니다',
    en: 'File transfer paused',
  );

  String pausedNotificationBody(String filename, String message) {
    final detail = errorDetail(message);
    return _pick(
      zh: '$filename：$detail',
      ja: '$filename：$detail',
      ko: '$filename: $detail',
      en: '$filename: $detail',
    );
  }

  String errorDetail(String raw) => switch (raw.trim()) {
    'insufficient_storage' => _pick(
      zh: '可用存储空间不足',
      ja: '空き容量が不足しています',
      ko: '사용 가능한 저장 공간이 부족합니다',
      en: 'Not enough storage space',
    ),
    'bridge_disconnected' => _pick(
      zh: 'Bridge 连接已断开',
      ja: 'Bridge との接続が切れました',
      ko: 'Bridge 연결이 끊어졌습니다',
      en: 'Bridge disconnected',
    ),
    'connection_failed' => _pick(
      zh: '连接失败',
      ja: '接続に失敗しました',
      ko: '연결에 실패했습니다',
      en: 'Connection failed',
    ),
    'total_timeout' || 'idle_timeout' || 'timeout' => _pick(
      zh: '传输超时',
      ja: '転送がタイムアウトしました',
      ko: '전송 시간이 초과되었습니다',
      en: 'Transfer timed out',
    ),
    'paused' => pause,
    'cancelled' => _pick(zh: '已取消', ja: 'キャンセル済み', ko: '취소됨', en: 'Cancelled'),
    _ => raw,
  };
}

String _normalizeLanguageCode(String? languageTag) {
  final normalized = (languageTag ?? '').trim().toLowerCase();
  if (normalized.isEmpty) return 'en';
  return normalized.split(RegExp('[-_]')).first;
}
