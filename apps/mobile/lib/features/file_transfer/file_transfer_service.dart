import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/messages.dart';
import '../../services/bridge_service.dart';
import '../../services/notification_service.dart';
import 'adaptive_transfer_chunk_sizer.dart';
import 'file_transfer_cancellation.dart';
import 'file_transfer_http.dart';
import 'file_transfer_storage.dart';

const fileTransferRecentResultLimit = 12;
const fileTransferReceiveQueueLimit = 8;
const fileTransferReceiveQueueByteLimit = 30 * 1024 * 1024 * 1024;
const fileTransferStorageSafetyReserveBytes = 512 * 1024 * 1024;
const fileTransferCompletionRecoveryRetryLimit = 5;
const fileTransferCompletionRecoveryMaxRetryDelay = Duration(minutes: 1);
const _fileTransferAutoResumePreference = 'file_transfer_v2_auto_resume';
const _fileTransferReceivedSeenBeforePreference =
    'file_transfer_received_seen_before_v1';

enum FileTransferDirection { receive, upload }

enum FileTransferStatus {
  queued,
  preparing,
  transferring,
  paused,
  succeeded,
  failed,
  cancelled,
}

class FileTransferRecord {
  final String id;
  final FileTransferDirection direction;
  final FileTransferStatus status;
  final String filename;
  final int transferredBytes;
  final int totalBytes;
  final DateTime updatedAt;
  final String? savedFilename;
  final String? savedPath;
  final String? errorCode;
  final String? error;

  const FileTransferRecord({
    required this.id,
    required this.direction,
    required this.status,
    required this.filename,
    required this.transferredBytes,
    required this.totalBytes,
    required this.updatedAt,
    this.savedFilename,
    this.savedPath,
    this.errorCode,
    this.error,
  });

  double get progress => totalBytes == 0
      ? (status == FileTransferStatus.succeeded ? 1 : 0)
      : (transferredBytes / totalBytes).clamp(0, 1);
}

class FileTransferSelection {
  final String path;
  final String filename;
  final int sizeBytes;

  const FileTransferSelection({
    required this.path,
    required this.filename,
    required this.sizeBytes,
  });
}

class FileTransferUploadTicket {
  const FileTransferUploadTicket({
    required this.id,
    required this.completion,
  });

  final String id;
  final Future<FileTransferRecord> completion;
}

typedef FileMutationAuthorizationCallback =
    Future<FileMutationAuthorization?> Function(
      FileMutationOperation operation,
    );

abstract interface class FileTransferDocumentPicker {
  Future<FileTransferSelection?> pickFile({required int maxSizeBytes});
}

abstract interface class FileTransferCapacityGateway {
  Future<int?> availableCapacityBytes(String path);
}

enum FileTransferCommitProbe { ready, linked, complete, collision }

class FileTransferCommitProbeResult {
  final FileTransferCommitProbe state;
  final String? resourceIdentifier;

  const FileTransferCommitProbeResult(this.state, {this.resourceIdentifier});
}

abstract interface class FileTransferCommitGateway {
  Future<void> markTransient(String path);

  Future<String> chooseFinalFilename({
    required String directoryPath,
    required String requestedFilename,
  });

  Future<FileTransferCommitProbeResult> probeCommit({
    required String partialPath,
    required String finalPath,
    String? expectedResourceIdentifier,
  });

  Future<String> linkNoClobber({
    required String partialPath,
    required String finalPath,
  });

  Future<void> finalizeLinkedCommit({
    required String partialPath,
    required String finalPath,
    required String expectedResourceIdentifier,
  });
}

abstract interface class FileTransferNotificationGateway {
  Future<void> received(String filename);
  Future<void> failed(String filename, String message);
}

abstract interface class FileTransferBridgeGateway {
  bool get isConnected;
  String? get httpBaseUrl;
  String? get logicalConnectionIdentity;
  Set<String> get capabilities;
  Stream<BridgeConnectionState> get connectionStatus;
  Stream<void> get capabilityChanges;
  Stream<LocalFeatureServerMessage> get messages;
  void send(ClientMessage message);
}

class BridgeServiceFileTransferGateway implements FileTransferBridgeGateway {
  const BridgeServiceFileTransferGateway(this._bridge);

  final BridgeService _bridge;

  @override
  bool get isConnected => _bridge.isConnected;
  @override
  String? get httpBaseUrl => _bridge.httpBaseUrl;
  @override
  String? get logicalConnectionIdentity => _bridge.logicalConnectionIdentity;
  @override
  Set<String> get capabilities => _bridge.bridgeCapabilities;
  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      _bridge.connectionStatus;
  @override
  Stream<void> get capabilityChanges => _bridge.sessionList
      .map(
        (_) => (
          connected: _bridge.isConnected,
          identity: _bridge.logicalConnectionIdentity,
          supported: _bridge.bridgeCapabilities.contains(
            fileTransferCapability,
          ),
        ),
      )
      .distinct()
      .map<void>((_) {});
  @override
  Stream<LocalFeatureServerMessage> get messages =>
      _bridge.localFeatureMessages;
  @override
  void send(ClientMessage message) => _bridge.send(message);
}

class FlutterSecureFileTransferSecretStore implements FileTransferSecretStore {
  const FlutterSecureFileTransferSecretStore(this._storage);
  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class NotificationServiceFileTransferGateway
    implements FileTransferNotificationGateway {
  const NotificationServiceFileTransferGateway(this._notifications);
  final NotificationService _notifications;

  @override
  Future<void> received(String filename) => _notifications.show(
    title: 'File received',
    body: '$filename was saved to Files > CC Pocket > Downloads.',
    id: _notificationId('received:$filename'),
    payload: fileTransferNotificationPayload,
  );

  @override
  Future<void> failed(String filename, String message) => _notifications.show(
    title: 'File transfer paused',
    body: '$filename: $message',
    id: _notificationId('failed:$filename'),
  );
}

const fileTransferNotificationPayload = 'ccpocket:file-transfer';

int _notificationId(String value) {
  var hash = 0;
  for (final code in value.codeUnits) {
    hash = ((hash * 31) + code) & 0x7fffffff;
  }
  return 0x31000000 | (hash & 0x0fffffff);
}

Future<Directory> defaultFileTransferDownloadsDirectory() async {
  final documents = await getApplicationDocumentsDirectory();
  return Directory(path.join(documents.path, 'Downloads'));
}

http.Client defaultFileTransferHttpClient() {
  final native = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  return IOClient(native);
}

class FileTransferService extends ChangeNotifier {
  FileTransferService({
    required FileTransferBridgeGateway bridge,
    required FileTransferStorage storage,
    required FileTransferDocumentPicker picker,
    required FileTransferCapacityGateway capacity,
    required FileTransferCommitGateway commit,
    required bool platformSupported,
    bool receivedFileExportSupported = false,
    FileTransferNotificationGateway? notifications,
    http.Client? httpClient,
    SharedPreferences? preferences,
    DateTime Function()? clock,
    String Function()? requestIdGenerator,
    this.receiveQueueLimit = fileTransferReceiveQueueLimit,
    this.receiveQueueByteLimit = fileTransferReceiveQueueByteLimit,
    this.recentResultLimit = fileTransferRecentResultLimit,
    this.completionRecoveryRetryDelay = const Duration(seconds: 5),
    this.completionRecoveryRetryLimit =
        fileTransferCompletionRecoveryRetryLimit,
    this.completionRecoveryMaxRetryDelay =
        fileTransferCompletionRecoveryMaxRetryDelay,
  }) : assert(completionRecoveryRetryLimit > 0),
       assert(!completionRecoveryRetryDelay.isNegative),
       assert(!completionRecoveryMaxRetryDelay.isNegative),
       _bridge = bridge,
       _storage = storage,
       _picker = picker,
       _capacity = capacity,
       _commit = commit,
       _platformSupported = platformSupported,
       // ignore: prefer_initializing_formals
       _receivedFileExportSupported = receivedFileExportSupported,
       _notifications = notifications,
       _httpClient = httpClient ?? defaultFileTransferHttpClient(),
       _ownsHttpClient = httpClient == null,
       _preferences = preferences,
       _clock = clock ?? DateTime.now,
       _requestIdGenerator = requestIdGenerator ?? _secureRequestId {
    _http = FileTransferHttpTransport(_httpClient);
    _autoResume =
        preferences?.getBool(_fileTransferAutoResumePreference) ?? true;
    _lastCapabilitySnapshot = _capabilitySnapshot();
    _messageSubscription = _bridge.messages.listen(_handleMessage);
    _connectionSubscription = _bridge.connectionStatus.listen(
      _handleConnectionState,
    );
    _capabilitySubscription = _bridge.capabilityChanges.listen(
      (_) => _handleCapabilityChange(),
    );
  }

  final FileTransferBridgeGateway _bridge;
  final FileTransferStorage _storage;
  final FileTransferDocumentPicker _picker;
  final FileTransferCapacityGateway _capacity;
  final FileTransferCommitGateway _commit;
  final bool _platformSupported;
  final bool _receivedFileExportSupported;
  final FileTransferNotificationGateway? _notifications;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final SharedPreferences? _preferences;
  final DateTime Function() _clock;
  final String Function() _requestIdGenerator;
  final int receiveQueueLimit;
  final int receiveQueueByteLimit;
  final int recentResultLimit;
  final Duration completionRecoveryRetryDelay;
  final int completionRecoveryRetryLimit;
  final Duration completionRecoveryMaxRetryDelay;
  late final FileTransferHttpTransport _http;

  late final StreamSubscription<LocalFeatureServerMessage> _messageSubscription;
  late final StreamSubscription<BridgeConnectionState> _connectionSubscription;
  late final StreamSubscription<void> _capabilitySubscription;
  final Queue<_ReceiveWork> _receiveQueue = Queue();
  final Queue<_ReceiveWork> _completionRecoveryQueue = Queue();
  final Queue<UploadTransferCheckpoint> _uploadRecoveryQueue = Queue();
  final Set<String> _knownReceiveIds = {};
  final Map<String, ({int generation, int sizeBytes})> _receiveReservations =
      {};
  final LinkedHashMap<
    String,
    ({String savedFilename, int sizeBytes, String sourceFilename, String etag})
  >
  _completedReceives = LinkedHashMap();
  final List<FileTransferRecord> _recentResults = [];
  final Map<String, AdaptiveTransferChunkSizer> _chunkSizers = {};
  final Map<String, int> _completionRecoveryAttempts = {};
  final Map<String, Completer<FileTransferRecord>> _uploadCompletions = {};
  final Map<String, FileMutationAuthorization>
  _uploadMutationAuthorizations = {};
  List<ReceivedFileTransfer> _receivedFiles = const [];
  Set<String> _unreadReceivedPaths = const {};

  FileTransferCancellation? _activeCancellation;
  _TransferWork? _activeWork;
  _TransferWork? _pausedWork;
  _PendingUploadResponse? _pendingUploadResponse;
  _PendingDownloadResume? _pendingDownloadResume;
  _PendingCancel? _pendingCancel;
  FileTransferRecord? _activeRecord;
  bool _processing = false;
  bool _recoveryScheduled = false;
  bool _completionRecoveryRetryScheduled = false;
  bool _recoveryDeferredForCapacity = false;
  bool _resumeScheduled = false;
  bool _resumeWhenIdleRequested = false;
  bool _recoveryRescanRequested = false;
  bool _disposed = false;
  bool _autoResume = true;
  bool _receivedInboxLoaded = false;
  int _receivedSeenBeforeMicros = 0;
  int _connectionEpoch = 0;
  int _logicalIdentityGeneration = 0;
  int _completionRecoveryRetryGeneration = 0;
  int _queuedReceiveBytes = 0;
  int _reservedReceiveBytes = 0;
  DateTime? _lastProgressNotify;
  ({bool connected, String? identity, bool supported})? _lastCapabilitySnapshot;

  bool get platformSupported => _platformSupported;
  bool get receivedFileExportSupported => _receivedFileExportSupported;
  bool get isConnected => _bridge.isConnected;
  bool get supportedByBridge =>
      _bridge.capabilities.contains(fileTransferCapability);
  bool get uploadMutationAuthRequired =>
      _bridge.capabilities.contains(fileTransferUploadAuthCapability);
  bool get uploadAvailable =>
      _platformSupported && isConnected && supportedByBridge;
  bool get autoResume => _autoResume;
  FileTransferRecord? get activeTransfer => _activeRecord;
  FileTransferRecord? get pausedTransfer => switch (_pausedWork) {
    _ReceiveWork(:final checkpoint) => _recordForReceive(
      checkpoint,
      FileTransferStatus.paused,
    ),
    _UploadWork(:final checkpoint) => _recordForUpload(
      checkpoint,
      FileTransferStatus.paused,
    ),
    _ => null,
  };
  List<FileTransferRecord> get recentResults =>
      List.unmodifiable(_recentResults);
  List<ReceivedFileTransfer> get receivedFiles =>
      List.unmodifiable(_receivedFiles);
  int get unreadReceivedCount => _unreadReceivedPaths.length;
  int get queuedReceiveCount => _receiveQueue.length;
  int get queuedReceiveBytes => _queuedReceiveBytes;
  int get queuedUploadCount => _uploadRecoveryQueue.length;
  int get queuedTransferCount => queuedReceiveCount + queuedUploadCount;

  Future<void> initialize() async {
    if (_platformSupported) {
      try {
        await _storage.cleanupPickerOrphans();
      } catch (_) {
        // File transfer is optional and must never block the app from starting.
      }
    }
    try {
      await refreshReceivedFiles(initialize: true);
    } catch (_) {
      // The inbox is advisory and must never block transfer recovery.
    }
    _scheduleRecovery();
  }

  Future<void> refreshReceivedFiles({bool initialize = false}) async {
    final files = await _storage.listReceivedFiles();
    if (!_receivedInboxLoaded) {
      final saved = _preferences?.getInt(
        _fileTransferReceivedSeenBeforePreference,
      );
      if (saved == null && initialize) {
        _receivedSeenBeforeMicros = _latestReceivedMicros(files);
        if (_preferences != null) {
          await _preferences.setInt(
            _fileTransferReceivedSeenBeforePreference,
            _receivedSeenBeforeMicros,
          );
        }
      } else {
        _receivedSeenBeforeMicros = saved ?? 0;
      }
      _receivedInboxLoaded = true;
    }
    _receivedFiles = files;
    _unreadReceivedPaths = {
      for (final file in files)
        if (file.modifiedAt.microsecondsSinceEpoch >
            _receivedSeenBeforeMicros)
          file.path,
    };
    _notify(force: true);
  }

  Future<void> markReceivedFilesSeen() async {
    final latest = _latestReceivedMicros(_receivedFiles);
    if (latest > _receivedSeenBeforeMicros) {
      _receivedSeenBeforeMicros = latest;
      await _preferences?.setInt(
        _fileTransferReceivedSeenBeforePreference,
        latest,
      );
    }
    if (_unreadReceivedPaths.isEmpty) return;
    _unreadReceivedPaths = const {};
    _notify(force: true);
  }

  Future<void> setAutoResume(bool enabled) async {
    if (_autoResume == enabled) return;
    _autoResume = enabled;
    await _preferences?.setBool(_fileTransferAutoResumePreference, enabled);
    if (enabled) {
      _resumePausedIfReady();
      _scheduleRecovery();
    }
    _notify(force: true);
  }

  Future<void> startQueuedTransfers() => _drainAndScheduleRecovery();

  Future<FileTransferRecord?> uploadToMac({
    FileMutationAuthorizationCallback? authorizeMutation,
  }) async {
    final identity = _requireUploadIngressReady(rejectIfBusy: true);
    await _markTransientStorage(identity);
    final selection = await _picker.pickFile(
      maxSizeBytes: maxFileTransferBytes,
    );
    if (selection == null) return null;
    final ticket = await _enqueueUploadSelection(
      selection,
      identity: identity,
      authorizeMutation: authorizeMutation,
    );
    return ticket.completion;
  }

  Future<FileTransferUploadTicket> enqueueDroppedFile({
    required String filename,
    required Stream<List<int>> bytes,
    int? expectedSizeBytes,
    FileMutationAuthorizationCallback? authorizeMutation,
  }) async {
    final identity = _requireUploadIngressReady(
      rejectIfBusy: uploadMutationAuthRequired,
    );
    _validateIngressMetadata(filename, expectedSizeBytes);
    await _markTransientStorage(identity);
    final pickerRoot = await _storage.pickerStagingDirectory();
    await _requireCapacity(pickerRoot.path, expectedSizeBytes ?? 0);
    final staged = await _storage.stageExternalFile(
      filename: filename,
      bytes: expectedSizeBytes == null
          ? _capacityCheckedDropStream(bytes, pickerRoot.path)
          : bytes,
      maxSizeBytes: maxFileTransferBytes,
      expectedSizeBytes: expectedSizeBytes,
    );
    return _enqueueUploadSelection(
      FileTransferSelection(
        path: staged.file.path,
        filename: staged.filename,
        sizeBytes: staged.sizeBytes,
      ),
      identity: identity,
      authorizeMutation: authorizeMutation,
    );
  }

  Stream<List<int>> _capacityCheckedDropStream(
    Stream<List<int>> source,
    String targetPath,
  ) async* {
    const checkIntervalBytes = 16 * 1024 * 1024;
    var bytesSinceCheck = 0;
    await for (final chunk in source) {
      bytesSinceCheck += chunk.length;
      if (bytesSinceCheck >= checkIntervalBytes) {
        await _requireCapacity(
          targetPath,
          bytesSinceCheck + checkIntervalBytes,
        );
        bytesSinceCheck = 0;
      }
      yield chunk;
    }
  }

  String _requireUploadIngressReady({required bool rejectIfBusy}) {
    if (!_platformSupported) {
      throw const FileTransferException('platform_unsupported');
    }
    if (!uploadAvailable) {
      throw FileTransferException(
        isConnected ? 'bridge_unsupported' : 'bridge_disconnected',
      );
    }
    if (rejectIfBusy && (_processing || _pausedWork != null)) {
      throw const FileTransferException('transfer_busy');
    }
    final identity = _stableIdentity;
    if (identity == null) {
      throw const FileTransferException('stable_bridge_identity_required');
    }
    return identity;
  }

  Future<FileTransferUploadTicket> _enqueueUploadSelection(
    FileTransferSelection selection, {
    required String identity,
    FileMutationAuthorizationCallback? authorizeMutation,
  }) async {
    _validateSelection(selection);
    final localId = _requestIdGenerator();
    final requestId = _requestIdGenerator();
    final transferId = _requestIdGenerator();
    final resumeToken = _secureToken();
    final checkpoint = await _storage.adoptPickerCopy(
      logicalIdentity: identity,
      localId: localId,
      requestId: requestId,
      transferId: transferId,
      resumeToken: resumeToken,
      filename: selection.filename,
      sizeBytes: selection.sizeBytes,
      pickerCopy: File(selection.path),
    );
    try {
      final authorization = await _authorizeUploadMutation(
        checkpoint,
        authorizeMutation,
      );
      if (authorization != null) {
        _uploadMutationAuthorizations[checkpoint.transferId] = authorization;
      }
    } catch (_) {
      await _storage
          .deleteUpload(checkpoint, deleteStaged: true)
          .catchError((_) {});
      rethrow;
    }
    final completion = Completer<FileTransferRecord>();
    _uploadCompletions[localId] = completion;
    _uploadRecoveryQueue.add(checkpoint);
    _notify(force: true);
    _launch(_drainAndScheduleRecovery());
    return FileTransferUploadTicket(
      id: localId,
      completion: completion.future,
    );
  }

  void pauseActive() {
    _activeCancellation?.cancel();
  }

  Future<void> continuePaused({
    FileMutationAuthorizationCallback? authorizeMutation,
  }) async {
    final work = _pausedWork;
    if (work == null || _processing) return;
    if (!uploadAvailable) {
      throw const FileTransferException('bridge_disconnected');
    }
    FileMutationAuthorization? uploadAuthorization;
    if (work case _UploadWork(:final checkpoint)) {
      uploadAuthorization = await _authorizeUploadMutation(
        checkpoint,
        authorizeMutation,
      );
    }
    _pausedWork = null;
    if (work case _ReceiveWork(:final checkpoint, :final secret)) {
      work.renewLease = true;
      _enqueueReceive(
        _ReceiveWork(checkpoint, secret, renewLease: true),
        first: true,
      );
    } else if (work case _UploadWork(:final checkpoint)) {
      if (uploadAuthorization != null) {
        _uploadMutationAuthorizations[checkpoint.transferId] =
            uploadAuthorization;
      }
      _uploadRecoveryQueue.addFirst(checkpoint);
    }
    _notify(force: true);
    await _drainAndScheduleRecovery();
  }

  Future<void> cancelTransfer(String id) async {
    final active = _activeWork;
    if (active?.id == id) {
      if (active is _ReceiveWork &&
          active.checkpoint.commitState == 'complete') {
        return;
      }
      final request = active!.cancelRequest ??= _requestBridgeCancel(active);
      _activeCancellation?.cancel();
      await request;
      _failPendingUpload(const FileTransferException('cancelled'));
      _failPendingDownload(const FileTransferException('cancelled'));
      return;
    }
    final paused = _pausedWork;
    if (paused?.id != id) return;
    final request = paused!.cancelRequest ??= _requestBridgeCancel(paused);
    await request;
    paused.cancelled = true;
    _pausedWork = null;
    await _cleanupWork(paused);
    _remember(_recordForWork(paused, FileTransferStatus.cancelled));
    _notify(force: true);
    if (_autoResume) {
      _launch(_drainAndScheduleRecovery());
    } else if (_recoveryDeferredForCapacity &&
        _receiveQueue.isEmpty &&
        _uploadRecoveryQueue.isEmpty) {
      // Manual mode must not run the next batch automatically, but cancelling
      // the only paused item must reveal a deferred batch so the Start action
      // cannot disappear with resumable checkpoints still on disk.
      _scheduleRecovery();
    }
  }

  void _handleMessage(LocalFeatureServerMessage message) {
    if (message is FileTransferOfferMessage) {
      _launch(_handleOffer(message));
      return;
    }
    final cancelPending = _pendingCancel;
    if (message is FileTransferCancelResultMessage &&
        cancelPending != null &&
        cancelPending.epoch == _connectionEpoch &&
        message.requestId == cancelPending.requestId &&
        message.transferId == cancelPending.transferId &&
        message.direction == cancelPending.direction &&
        !cancelPending.result.isCompleted) {
      cancelPending.result.complete(message);
      return;
    }
    final downloadPending = _pendingDownloadResume;
    if (message is FileTransferDownloadResumedMessage &&
        downloadPending != null &&
        downloadPending.epoch == _connectionEpoch &&
        message.requestId == downloadPending.requestId &&
        message.transferId == downloadPending.transferId &&
        !downloadPending.result.isCompleted) {
      downloadPending.result.complete(message);
      return;
    }
    final pending = _pendingUploadResponse;
    if (pending == null || pending.epoch != _connectionEpoch) return;
    if (message is FileTransferUploadReadyMessage &&
        message.requestId == pending.requestId &&
        message.transferId == pending.transferId &&
        !pending.ready.isCompleted) {
      pending.ready.complete(message);
      return;
    }
    if (message is FileTransferUploadResultMessage &&
        message.requestId == pending.requestId &&
        pending.transferId == message.transferId &&
        !pending.result.isCompleted) {
      pending.result.complete(message);
    }
  }

  Future<void> _handleOffer(FileTransferOfferMessage offer) async {
    if (!_platformSupported || !supportedByBridge || !isConnected) return;
    final identity = _stableIdentity;
    if (identity == null) return;
    final offerGeneration = _logicalIdentityGeneration;
    final offerEpoch = _connectionEpoch;
    bool stillCurrent() =>
        offerGeneration == _logicalIdentityGeneration &&
        offerEpoch == _connectionEpoch &&
        uploadAvailable &&
        _stableIdentity == identity;
    final completed = _completedReceives[offer.transferId];
    if (completed != null) {
      if (completed.sizeBytes != offer.sizeBytes ||
          completed.sourceFilename != offer.filename ||
          completed.etag != offer.etag) {
        if (stillCurrent()) {
          _sendReceiveResult(
            offer.transferId,
            success: false,
            receivedBytes: completed.sizeBytes,
            errorCode: 'source_identity_changed',
            error: 'The source identity changed; local state was preserved.',
          );
        }
        return;
      }
      if (stillCurrent()) {
        _sendReceiveResult(
          offer.transferId,
          success: true,
          savedFilename: completed.savedFilename,
          receivedBytes: completed.sizeBytes,
        );
      }
      return;
    }
    if (_knownReceiveIds.contains(offer.transferId)) return;
    if (_receiveReservations.containsKey(offer.transferId)) return;
    if (offer.sizeBytes > maxFileTransferBytes ||
        !_tryReserveReceive(
          offer.transferId,
          offer.sizeBytes,
          offerGeneration,
        )) {
      if (stillCurrent()) {
        _sendReceiveResult(
          offer.transferId,
          success: false,
          receivedBytes: 0,
          errorCode: 'queue_limit',
          error: 'The bounded receive queue is full.',
        );
      }
      return;
    }
    try {
      final existing = (await _storage.loadReceives(
        identity,
      )).where((item) => item.transferId == offer.transferId).firstOrNull;
      if (!stillCurrent()) return;
      if (_knownReceiveIds.contains(offer.transferId)) return;
      if (existing != null &&
          (existing.etag != offer.etag ||
              existing.sizeBytes != offer.sizeBytes ||
              existing.filename != offer.filename)) {
        _sendReceiveResult(
          offer.transferId,
          success: false,
          receivedBytes: existing.receivedBytes,
          errorCode: 'source_identity_changed',
          error: 'The source identity changed; local state was preserved.',
        );
        return;
      }
      if (existing?.commitState == 'complete') {
        final secret = DownloadTransferSecret(
          downloadUrl: offer.downloadUrl,
          downloadToken: offer.downloadToken,
          logicalBridgeIdentity: identity,
        );
        await _storage.writeDownloadSecret(existing!, secret);
        if (!stillCurrent()) return;
        _releaseReceiveReservation(offer.transferId, offerGeneration);
        _knownReceiveIds.add(offer.transferId);
        _completionRecoveryQueue.addFirst(_ReceiveWork(existing, secret));
        _launch(_drain(completedOnly: true));
        return;
      }
      ReceiveTransferCheckpoint checkpoint;
      if (existing == null) {
        await _markTransientStorage(identity);
        if (!stillCurrent()) return;
        checkpoint = _storage.newReceiveCheckpoint(
          logicalIdentity: identity,
          offer: offer,
        );
        await _storage.initializeReceive(checkpoint);
        if (!stillCurrent()) return;
      } else {
        try {
          await _storage.reconcileReceivePartial(existing);
        } on FileTransferStorageException {
          if (stillCurrent()) {
            _sendReceiveResult(
              offer.transferId,
              success: false,
              receivedBytes: existing.receivedBytes,
              errorCode: 'checkpoint_mismatch',
              error: 'The local checkpoint no longer matches its partial file.',
            );
          }
          return;
        }
        if (!stillCurrent()) return;
        final now = _clock().toUtc();
        checkpoint = existing.copyWith(
          expiresAt: now.add(fileTransferCheckpointRetention),
          updatedAt: now,
        );
        await _storage.saveReceive(checkpoint);
        if (!stillCurrent()) return;
      }
      final secret = DownloadTransferSecret(
        downloadUrl: offer.downloadUrl,
        downloadToken: offer.downloadToken,
        logicalBridgeIdentity: identity,
      );
      await _storage.writeDownloadSecret(checkpoint, secret);
      if (!stillCurrent()) return;
      if (_knownReceiveIds.contains(offer.transferId)) return;
      _releaseReceiveReservation(offer.transferId, offerGeneration);
      _knownReceiveIds.add(offer.transferId);
      _enqueueReceive(_ReceiveWork(checkpoint, secret));
      _notify(force: true);
      if (_autoResume) _launch(_drain());
    } on FileTransferStorageException catch (error) {
      if (stillCurrent()) {
        _sendReceiveResult(
          offer.transferId,
          success: false,
          receivedBytes: 0,
          errorCode: error.code,
          error: 'The local transfer checkpoint could not be reserved.',
        );
      }
    } finally {
      _releaseReceiveReservation(offer.transferId, offerGeneration);
      if (offerEpoch != _connectionEpoch) {
        _recoveryRescanRequested = true;
        _scheduleRecovery();
      }
    }
  }

  void _enqueueReceive(_ReceiveWork work, {bool first = false}) {
    if (first) {
      _receiveQueue.addFirst(work);
    } else {
      _receiveQueue.add(work);
    }
    _queuedReceiveBytes += work.checkpoint.sizeBytes;
  }

  void _releaseReceiveReservation(String transferId, int generation) {
    final reservation = _receiveReservations[transferId];
    if (reservation == null || reservation.generation != generation) return;
    _receiveReservations.remove(transferId);
    _reservedReceiveBytes -= reservation.sizeBytes;
    assert(_reservedReceiveBytes >= 0);
  }

  bool _tryReserveReceive(String transferId, int sizeBytes, int generation) {
    if (generation != _logicalIdentityGeneration ||
        sizeBytes < 0 ||
        sizeBytes > maxFileTransferBytes ||
        _receiveReservations.containsKey(transferId) ||
        _receiveQueue.length + _receiveReservations.length >=
            receiveQueueLimit ||
        _queuedReceiveBytes + _reservedReceiveBytes + sizeBytes >
            receiveQueueByteLimit) {
      return false;
    }
    _receiveReservations[transferId] = (
      generation: generation,
      sizeBytes: sizeBytes,
    );
    _reservedReceiveBytes += sizeBytes;
    return true;
  }

  Future<void> _drain({bool completedOnly = false}) async {
    if (_processing || _disposed || !uploadAvailable) return;
    final drainGeneration = _logicalIdentityGeneration;
    _processing = true;
    try {
      while (!_disposed && uploadAvailable) {
        _TransferWork? work;
        while (_completionRecoveryQueue.isNotEmpty && work == null) {
          final candidate = _completionRecoveryQueue.removeFirst();
          if (candidate.checkpoint.expiresAt.isAfter(_clock().toUtc())) {
            work = candidate;
          }
        }
        if (work == null) {
          if (completedOnly || _pausedWork != null) {
            break;
          } else if (_receiveQueue.isNotEmpty) {
            work = _receiveQueue.removeFirst();
            _queuedReceiveBytes -= (work as _ReceiveWork).checkpoint.sizeBytes;
            assert(_queuedReceiveBytes >= 0);
          } else if (_uploadRecoveryQueue.isNotEmpty) {
            work = _UploadWork(_uploadRecoveryQueue.removeFirst());
          }
        }
        if (work == null) break;
        final workGeneration = _logicalIdentityGeneration;
        _activeWork = work;
        final cancellation = FileTransferCancellation();
        _activeCancellation = cancellation;
        var stopAfterWork = false;
        try {
          if (work is _ReceiveWork) {
            await _runReceive(work, cancellation);
          } else if (work is _UploadWork) {
            await _runUpload(work, cancellation);
          }
          _completionRecoveryAttempts.remove(work.id);
        } catch (error) {
          if (workGeneration != _logicalIdentityGeneration ||
              !_workMatchesCurrentIdentity(work)) {
            // A machine switch invalidates only in-memory ownership. The
            // checkpoint and partial/staged file stay durable so selecting
            // the original machine again can recover them normally.
            if (work is _ReceiveWork) {
              _knownReceiveIds.remove(work.checkpoint.transferId);
            }
            _chunkSizers.remove(work.id);
            stopAfterWork = true;
          } else if (work.cancelRequest case final cancelRequest?) {
            try {
              await cancelRequest;
              work.cancelled = true;
              await _cleanupWork(work);
              _remember(_recordForWork(work, FileTransferStatus.cancelled));
            } catch (cancelError) {
              work.cancelRequest = null;
              _pausedWork = work;
              _remember(
                _recordForWork(
                  work,
                  FileTransferStatus.paused,
                  errorCode: _errorCode(cancelError),
                  error: _errorMessage(cancelError),
                ),
              );
            }
          } else if (work.cancelled) {
            await _cleanupWork(work);
            _remember(_recordForWork(work, FileTransferStatus.cancelled));
          } else if (_isRecoverable(error) &&
              work is _ReceiveWork &&
              work.checkpoint.commitState == 'complete') {
            // The file is already durably published. A transport failure in
            // idempotent ACK/notification cleanup must not turn it back into a
            // manual "unfinished transfer", even when auto-resume is off.
            _remember(
              _recordForReceive(
                work.checkpoint,
                FileTransferStatus.succeeded,
                savedFilename: work.checkpoint.finalFilename,
              ),
            );
            final attempts = (_completionRecoveryAttempts[work.id] ?? 0) + 1;
            _completionRecoveryAttempts[work.id] = attempts;
            if (attempts < completionRecoveryRetryLimit &&
                work.checkpoint.expiresAt.isAfter(_clock().toUtc())) {
              _completionRecoveryQueue.addFirst(work);
              stopAfterWork = true;
              _scheduleCompletionRecoveryRetry();
            }
          } else if (_isRecoverable(error)) {
            _pausedWork = work;
            _remember(
              _recordForWork(
                work,
                FileTransferStatus.paused,
                errorCode: _errorCode(error),
                error: _errorMessage(error),
              ),
            );
            if (_errorCode(error) == 'insufficient_storage') {
              final failedFilename = work.filename;
              final failedMessage = _errorMessage(error);
              _notifySafely(
                () => _notifications?.failed(failedFilename, failedMessage),
              );
            }
          } else {
            _remember(
              _recordForWork(
                work,
                FileTransferStatus.failed,
                errorCode: _errorCode(error),
                error: _errorMessage(error),
              ),
            );
            if (work is _ReceiveWork) {
              _knownReceiveIds.remove(work.checkpoint.transferId);
            }
            _chunkSizers.remove(work.id);
          }
        } finally {
          _activeWork = null;
          _activeCancellation = null;
          _activeRecord = null;
          _pendingUploadResponse = null;
          _pendingDownloadResume = null;
          _pendingCancel = null;
          _notify(force: true);
        }
        if (stopAfterWork) break;
      }
    } finally {
      _processing = false;
      if (_resumeWhenIdleRequested) {
        _resumeWhenIdleRequested = false;
        _resumePausedIfReady();
      }
      if (completedOnly || drainGeneration != _logicalIdentityGeneration) {
        _scheduleRecovery();
      }
      if (drainGeneration != _logicalIdentityGeneration && _autoResume) {
        _launch(_drain());
      }
    }
  }

  void _scheduleCompletionRecoveryRetry() {
    if (_completionRecoveryRetryScheduled ||
        _disposed ||
        _completionRecoveryQueue.isEmpty) {
      return;
    }
    final work = _completionRecoveryQueue.first;
    final attempts = _completionRecoveryAttempts[work.id] ?? 1;
    final multiplier = 1 << min(attempts - 1, 20);
    final retryMicros = min(
      completionRecoveryRetryDelay.inMicroseconds * multiplier,
      completionRecoveryMaxRetryDelay.inMicroseconds,
    );
    final retryGeneration = _completionRecoveryRetryGeneration;
    _completionRecoveryRetryScheduled = true;
    _launch(
      Future<void>.delayed(Duration(microseconds: retryMicros)).then((_) async {
        if (retryGeneration != _completionRecoveryRetryGeneration) return;
        _completionRecoveryRetryScheduled = false;
        if (!uploadAvailable) return;
        await _drain(completedOnly: true);
        if (_completionRecoveryQueue.isNotEmpty) {
          _scheduleCompletionRecoveryRetry();
        }
      }),
    );
  }

  void _resetCompletionRecoveryRetryRound({bool reopenExhausted = false}) {
    _completionRecoveryRetryGeneration++;
    _completionRecoveryRetryScheduled = false;
    if (reopenExhausted) {
      for (final transferId in _completionRecoveryAttempts.keys) {
        _completedReceives.remove(transferId);
      }
    }
    _completionRecoveryAttempts.clear();
  }

  Future<void> _drainAndScheduleRecovery() async {
    await _drain();
    if (_recoveryDeferredForCapacity || _recoveryRescanRequested) {
      _scheduleRecovery();
    }
  }

  Future<void> _runReceive(
    _ReceiveWork work,
    FileTransferCancellation cancellation,
  ) async {
    var checkpoint = work.checkpoint;
    final operationGeneration = _logicalIdentityGeneration;
    _requireReceiveContext(
      checkpoint,
      work.secret,
      operationGeneration: operationGeneration,
    );
    final partial = checkpoint.commitState == 'complete'
        ? await _storage.receivePartial(checkpoint)
        : await _storage.reconcileReceivePartial(checkpoint);
    _requireReceiveContext(
      checkpoint,
      work.secret,
      operationGeneration: operationGeneration,
    );
    if (checkpoint.commitState == 'committing' ||
        checkpoint.commitState == 'complete') {
      await _finishReceiveCommit(
        work,
        checkpoint,
        partial,
        cancellation,
        operationGeneration,
      );
      return;
    }
    final storedSecret = work.secret;
    if (storedSecret == null) {
      throw const FileTransferException('download_secret_missing');
    }
    DownloadTransferSecret secret = storedSecret;
    if (work.renewLease) {
      secret = await _renewDownloadLease(
        checkpoint,
        secret,
        cancellation,
        operationGeneration,
      );
      work.secret = secret;
      work.renewLease = false;
    }
    var url = _validatedUrl(
      secret.downloadUrl,
      transferId: checkpoint.transferId,
      endpoint: 'downloads',
    );
    await _requireCapacity(
      partial.parent.path,
      checkpoint.sizeBytes - checkpoint.receivedBytes,
    );
    var head = await _headDownloadWithRetry(
      url: url,
      checkpoint: checkpoint,
      secret: secret,
      cancellation: cancellation,
      operationGeneration: operationGeneration,
    );
    if (head.sizeBytes != checkpoint.sizeBytes ||
        head.etag != checkpoint.etag ||
        head.maxChunkSizeBytes > fileTransferChunkBytes) {
      throw const FileTransferException('download_identity_mismatch');
    }
    final chunkSizer = _chunkSizers.putIfAbsent(
      work.id,
      AdaptiveTransferChunkSizer.new,
    );
    while (checkpoint.receivedBytes < checkpoint.sizeBytes) {
      if (head.expiresAt.difference(_clock().toUtc()) <
          const Duration(minutes: 5)) {
        secret = await _renewDownloadLease(
          checkpoint,
          secret,
          cancellation,
          operationGeneration,
        );
        work.secret = secret;
        url = _validatedUrl(
          secret.downloadUrl,
          transferId: checkpoint.transferId,
          endpoint: 'downloads',
        );
        head = await _headDownloadWithRetry(
          url: url,
          checkpoint: checkpoint,
          secret: secret,
          cancellation: cancellation,
          operationGeneration: operationGeneration,
        );
      }
      await _requireCapacity(
        partial.parent.path,
        checkpoint.sizeBytes - checkpoint.receivedBytes,
      );
      final chunkBytes = chunkSizer.nextChunkBytes(
        totalBytes: checkpoint.sizeBytes,
        remainingBytes: checkpoint.sizeBytes - checkpoint.receivedBytes,
        serverMaxBytes: head.maxChunkSizeBytes,
      );
      final end = checkpoint.receivedBytes + chunkBytes - 1;
      final previousOffset = checkpoint.receivedBytes;
      _activeRecord = _recordForReceive(
        checkpoint,
        FileTransferStatus.transferring,
      );
      final stopwatch = Stopwatch()..start();
      late final int next;
      try {
        next = await _downloadChunkWithRetry(
          url: url,
          checkpoint: checkpoint,
          secret: secret,
          partial: partial,
          endInclusive: end,
          cancellation: cancellation,
          operationGeneration: operationGeneration,
          onProgress: (value) => _progress(
            _recordForReceive(
              checkpoint.copyWith(receivedBytes: value),
              FileTransferStatus.transferring,
            ),
          ),
        );
        stopwatch.stop();
        chunkSizer.recordSuccess(bytes: chunkBytes, elapsed: stopwatch.elapsed);
      } catch (_) {
        chunkSizer.recordFailure();
        rethrow;
      }
      final now = _clock().toUtc();
      checkpoint = checkpoint.copyWith(
        receivedBytes: next,
        expiresAt: now.add(fileTransferCheckpointRetention),
        updatedAt: now,
      );
      work.checkpoint = checkpoint;
      await _storage.commitReceiveChunk(
        checkpoint: checkpoint,
        partial: partial,
        previousOffset: previousOffset,
      );
      _progress(
        _recordForReceive(checkpoint, FileTransferStatus.transferring),
        force: true,
      );
    }
    if (await partial.length() != checkpoint.sizeBytes) {
      throw const FileTransferException('download_size_mismatch');
    }
    final downloads = await _storage.downloadsDirectory();
    final chosen = await _commit.chooseFinalFilename(
      directoryPath: downloads.path,
      requestedFilename: checkpoint.filename,
    );
    final commitStartedAt = _clock().toUtc();
    checkpoint = checkpoint.copyWith(
      commitState: 'committing',
      finalFilename: chosen,
      expiresAt: commitStartedAt.add(fileTransferCheckpointRetention),
      updatedAt: commitStartedAt,
    );
    work.checkpoint = checkpoint;
    await _storage.saveReceive(checkpoint);
    _requireReceiveContext(
      checkpoint,
      work.secret,
      operationGeneration: operationGeneration,
    );
    await _finishReceiveCommit(
      work,
      checkpoint,
      partial,
      cancellation,
      operationGeneration,
    );
  }

  Future<void> _finishReceiveCommit(
    _ReceiveWork work,
    ReceiveTransferCheckpoint checkpoint,
    File partial,
    FileTransferCancellation cancellation,
    int operationGeneration,
  ) async {
    var current = checkpoint;
    _requireReceiveContext(
      current,
      work.secret,
      operationGeneration: operationGeneration,
    );
    var finalName = current.finalFilename!;
    final downloads = await _storage.downloadsDirectory();
    for (var attempt = 0; attempt < 100; attempt += 1) {
      final finalPath = path.join(downloads.path, finalName);
      final probe = await _commit.probeCommit(
        partialPath: partial.path,
        finalPath: finalPath,
        expectedResourceIdentifier: current.finalResourceIdentifier,
      );
      if (current.commitState == 'complete') {
        if (probe.state == FileTransferCommitProbe.linked) {
          await _commit.finalizeLinkedCommit(
            partialPath: partial.path,
            finalPath: finalPath,
            expectedResourceIdentifier: current.finalResourceIdentifier!,
          );
        } else if (probe.state != FileTransferCommitProbe.complete) {
          throw const FileTransferException('commit_tombstone_mismatch');
        }
        if (!await _prepareCompletedReceiveAcknowledgement(
          work,
          current,
          finalName,
          cancellation,
          operationGeneration,
        )) {
          return;
        }
        await _completeReceiveCommit(
          work,
          current,
          finalName,
          operationGeneration,
        );
        return;
      }
      if (probe.state == FileTransferCommitProbe.collision) {
        finalName = await _commit.chooseFinalFilename(
          directoryPath: downloads.path,
          requestedFilename: current.filename,
        );
        final collisionAt = _clock().toUtc();
        current = current.copyWith(
          finalFilename: finalName,
          expiresAt: collisionAt.add(fileTransferCheckpointRetention),
          updatedAt: collisionAt,
        );
        work.checkpoint = current;
        await _storage.saveReceive(current);
        continue;
      }
      String resourceIdentifier;
      if (probe.state == FileTransferCommitProbe.linked &&
          probe.resourceIdentifier != null) {
        resourceIdentifier = probe.resourceIdentifier!;
      } else {
        try {
          resourceIdentifier = await _commit.linkNoClobber(
            partialPath: partial.path,
            finalPath: finalPath,
          );
        } on FileTransferException catch (error) {
          if (error.code == 'commit_collision') continue;
          rethrow;
        }
      }
      final completedAt = _clock().toUtc();
      current = current.copyWith(
        commitState: 'complete',
        finalResourceIdentifier: resourceIdentifier,
        notificationPending: _notifications != null,
        expiresAt: completedAt.add(fileTransferCheckpointRetention),
        updatedAt: completedAt,
      );
      work.checkpoint = current;
      await _storage.saveReceive(current);
      await _commit.finalizeLinkedCommit(
        partialPath: partial.path,
        finalPath: finalPath,
        expectedResourceIdentifier: resourceIdentifier,
      );
      if (!await _prepareCompletedReceiveAcknowledgement(
        work,
        current,
        finalName,
        cancellation,
        operationGeneration,
      )) {
        return;
      }
      await _completeReceiveCommit(
        work,
        current,
        finalName,
        operationGeneration,
      );
      return;
    }
    throw const FileTransferException('commit_collision_exhausted');
  }

  Future<bool> _prepareCompletedReceiveAcknowledgement(
    _ReceiveWork work,
    ReceiveTransferCheckpoint checkpoint,
    String saved,
    FileTransferCancellation cancellation,
    int operationGeneration,
  ) async {
    if (!work.renewLease) return true;
    work.renewLease = false;
    final secret = work.secret;
    if (secret == null) {
      await _forgetAcknowledgedReceiveCheckpoint(
        work,
        checkpoint,
        saved,
        operationGeneration,
      );
      return false;
    }
    try {
      work.secret = await _renewDownloadLease(
        checkpoint,
        secret,
        cancellation,
        operationGeneration,
      );
      return true;
    } on FileTransferException catch (error) {
      if (!_downloadStateIsMissing(error)) rethrow;
      await _forgetAcknowledgedReceiveCheckpoint(
        work,
        checkpoint,
        saved,
        operationGeneration,
      );
      return false;
    }
  }

  Future<void> _forgetAcknowledgedReceiveCheckpoint(
    _ReceiveWork work,
    ReceiveTransferCheckpoint checkpoint,
    String saved,
    int operationGeneration,
  ) async {
    _requireReceiveContext(
      checkpoint,
      work.secret,
      operationGeneration: operationGeneration,
    );
    _recordCompletedReceive(work, checkpoint, saved);
    final notificationCleared = await _deliverPendingReceiveNotification(
      work,
      checkpoint,
      saved,
    );
    if (notificationCleared.notificationPending) {
      throw const FileTransferException('notification_pending');
    }
    _requireReceiveContext(
      checkpoint,
      work.secret,
      operationGeneration: operationGeneration,
    );
    try {
      // The final file was verified above. A missing Bridge entry proves that
      // no acknowledgement route remains, so only local transfer metadata and
      // its Keychain token are removed; the saved file is never touched.
      await _storage.deleteReceive(checkpoint, deletePartial: true);
    } catch (_) {
      // Keep the completion tombstone for a later idempotent cleanup attempt.
    }
  }

  Future<void> _completeReceiveCommit(
    _ReceiveWork work,
    ReceiveTransferCheckpoint checkpoint,
    String saved,
    int operationGeneration,
  ) async {
    // Keep the ThisDeviceOnly token with the bounded completion tombstone.
    // If this live-only acknowledgement races a disconnect, recovery can first
    // rebind with download_resume_v2 and safely acknowledge again. A later
    // download_not_found response removes both token and tombstone.
    _requireReceiveContext(
      checkpoint,
      work.secret,
      operationGeneration: operationGeneration,
    );
    _sendReceiveResult(
      checkpoint.transferId,
      success: true,
      savedFilename: saved,
      receivedBytes: checkpoint.sizeBytes,
    );
    _recordCompletedReceive(work, checkpoint, saved);
    final notificationCleared = await _deliverPendingReceiveNotification(
      work,
      checkpoint,
      saved,
    );
    if (notificationCleared.notificationPending) {
      throw const FileTransferException('notification_pending');
    }
  }

  void _recordCompletedReceive(
    _ReceiveWork work,
    ReceiveTransferCheckpoint checkpoint,
    String saved,
  ) {
    _completedReceives.remove(checkpoint.transferId);
    _completedReceives[checkpoint.transferId] = (
      savedFilename: saved,
      sizeBytes: checkpoint.sizeBytes,
      sourceFilename: checkpoint.filename,
      etag: checkpoint.etag,
    );
    while (_completedReceives.length > 256) {
      _completedReceives.remove(_completedReceives.keys.first);
    }
    _knownReceiveIds.remove(checkpoint.transferId);
    _chunkSizers.remove(work.id);
    _remember(
      _recordForReceive(
        checkpoint,
        FileTransferStatus.succeeded,
        savedFilename: saved,
      ),
    );
    _launch(refreshReceivedFiles());
  }

  Future<ReceiveTransferCheckpoint> _deliverPendingReceiveNotification(
    _ReceiveWork work,
    ReceiveTransferCheckpoint checkpoint,
    String saved,
  ) async {
    if (!checkpoint.notificationPending || _notifications == null) {
      return checkpoint;
    }
    try {
      await _notifications.received(saved);
      final notifiedAt = _clock().toUtc();
      final notified = checkpoint.copyWith(
        notificationPending: false,
        expiresAt: notifiedAt.add(fileTransferCheckpointRetention),
        updatedAt: notifiedAt,
      );
      await _storage.saveReceive(notified);
      work.checkpoint = notified;
      return notified;
    } catch (_) {
      // Completion is already durable. Keep the pending marker so a later
      // reconnect/restart can retry. The production notification id is stable,
      // so a crash after delivery but before this save replaces, rather than
      // multiplies, the visible notification.
      return checkpoint;
    }
  }

  Future<DownloadTransferSecret> _renewDownloadLease(
    ReceiveTransferCheckpoint checkpoint,
    DownloadTransferSecret secret,
    FileTransferCancellation cancellation,
    int operationGeneration,
  ) async {
    _requireReceiveContext(
      checkpoint,
      secret,
      operationGeneration: operationGeneration,
    );
    final requestId = _requestIdGenerator();
    final pending = _PendingDownloadResume(
      requestId: requestId,
      transferId: checkpoint.transferId,
      epoch: _connectionEpoch,
    );
    _pendingDownloadResume = pending;
    _sendLive(
      resumeFileTransferDownload(
        requestId: requestId,
        transferId: checkpoint.transferId,
        downloadToken: secret.downloadToken,
      ),
    );
    final resumed = await _waitWithCancellation(
      pending.result.future,
      cancellation,
      const Duration(seconds: 30),
    );
    _requireReceiveContext(
      checkpoint,
      secret,
      operationGeneration: operationGeneration,
    );
    final bridgeExpiry = resumed.expiresAt == null
        ? null
        : DateTime.tryParse(resumed.expiresAt!);
    if (!resumed.success ||
        resumed.sizeBytes != checkpoint.sizeBytes ||
        resumed.etag != checkpoint.etag ||
        bridgeExpiry == null) {
      throw FileTransferException(
        resumed.errorCode ?? 'download_resume_failed',
        resumed.error,
      );
    }
    // The token is stable for this Bridge transfer, while the reachable HTTP
    // origin is connection-scoped. A reconnect through Tailscale, LAN, or an
    // SSH tunnel can legitimately change that origin without changing the
    // caller-owned logical machine identity. Rebuild the fixed endpoint only
    // after the current Bridge has proved the token via download_resume_v2.
    final refreshedSecret = DownloadTransferSecret(
      downloadUrl: _currentDownloadUrl(checkpoint.transferId).toString(),
      downloadToken: secret.downloadToken,
      logicalBridgeIdentity: secret.logicalBridgeIdentity,
    );
    final renewedAt = _clock().toUtc();
    await _storage.writeDownloadSecret(checkpoint, refreshedSecret);
    await _storage.saveReceive(
      checkpoint.copyWith(
        expiresAt: renewedAt.add(fileTransferCheckpointRetention),
        updatedAt: renewedAt,
      ),
    );
    return refreshedSecret;
  }

  Future<void> _requestBridgeCancel(_TransferWork work) async {
    if (!uploadAvailable) {
      throw const FileTransferException('bridge_disconnected');
    }
    final operationGeneration = _logicalIdentityGeneration;
    if (_pendingCancel != null) {
      throw const FileTransferException('cancel_busy');
    }
    final requestId = _requestIdGenerator();
    final FileTransferCancelDirection direction;
    final String transferId;
    String? resumeToken;
    String? downloadToken;
    if (work is _ReceiveWork) {
      direction = FileTransferCancelDirection.download;
      transferId = work.checkpoint.transferId;
      final secret =
          work.secret ?? await _storage.readDownloadSecret(work.checkpoint);
      if (secret == null || secret.logicalBridgeIdentity != _stableIdentity) {
        throw const FileTransferException('download_secret_missing');
      }
      downloadToken = secret.downloadToken;
    } else if (work is _UploadWork) {
      direction = FileTransferCancelDirection.upload;
      transferId = work.checkpoint.transferId;
      final secret = await _storage.readUploadSecret(work.checkpoint);
      if (secret == null || secret.logicalBridgeIdentity != _stableIdentity) {
        throw const FileTransferException('upload_secret_missing');
      }
      resumeToken = secret.resumeToken;
    } else {
      throw const FileTransferException('invalid_transfer');
    }
    if (operationGeneration != _logicalIdentityGeneration ||
        !_workMatchesCurrentIdentity(work)) {
      throw const FileTransferException('bridge_identity_mismatch');
    }
    final pending = _PendingCancel(
      requestId: requestId,
      transferId: transferId,
      direction: direction,
      epoch: _connectionEpoch,
    );
    _pendingCancel = pending;
    try {
      _sendLive(
        cancelFileTransfer(
          requestId: requestId,
          transferId: transferId,
          direction: direction,
          resumeToken: resumeToken,
          downloadToken: downloadToken,
        ),
      );
      final result = await pending.result.future.timeout(
        const Duration(seconds: 15),
      );
      if (!result.success && result.errorCode != 'not_found') {
        throw FileTransferException(
          result.errorCode ?? 'cancel_failed',
          result.error,
        );
      }
    } finally {
      if (identical(_pendingCancel, pending)) _pendingCancel = null;
    }
  }

  Future<DownloadTransferHead> _headDownloadWithRetry({
    required Uri url,
    required ReceiveTransferCheckpoint checkpoint,
    required DownloadTransferSecret secret,
    required FileTransferCancellation cancellation,
    required int operationGeneration,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        return await _http.headDownload(
          url: url,
          token: secret.downloadToken,
          cancellation: cancellation,
        );
      } catch (error) {
        lastError = error;
        final leaseExpired =
            error is FileTransferHttpException &&
            error.statusCode == HttpStatus.notFound;
        if (!_autoResume ||
            cancellation.isCancelled ||
            (!leaseExpired && !_isRecoverable(error)) ||
            attempt == 2) {
          rethrow;
        }
        if (leaseExpired) {
          await _renewDownloadLease(
            checkpoint,
            secret,
            cancellation,
            operationGeneration,
          );
        }
        await _retryDelay(attempt);
      }
    }
    throw lastError!;
  }

  Future<int> _downloadChunkWithRetry({
    required Uri url,
    required ReceiveTransferCheckpoint checkpoint,
    required DownloadTransferSecret secret,
    required File partial,
    required int endInclusive,
    required FileTransferCancellation cancellation,
    required int operationGeneration,
    required void Function(int) onProgress,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        return await _http.downloadChunk(
          url: url,
          token: secret.downloadToken,
          etag: checkpoint.etag,
          partial: partial,
          offset: checkpoint.receivedBytes,
          endInclusive: endInclusive,
          totalSizeBytes: checkpoint.sizeBytes,
          cancellation: cancellation,
          onProgress: onProgress,
        );
      } catch (error) {
        lastError = error;
        final leaseExpired =
            error is FileTransferHttpException &&
            error.statusCode == HttpStatus.notFound;
        if (!_autoResume ||
            cancellation.isCancelled ||
            (!leaseExpired && !_isRecoverable(error)) ||
            attempt == 2) {
          rethrow;
        }
        if (leaseExpired) {
          await _renewDownloadLease(
            checkpoint,
            secret,
            cancellation,
            operationGeneration,
          );
        }
        await _retryDelay(attempt);
      }
    }
    throw lastError!;
  }

  Future<void> _retryDelay(int attempt) {
    final jitter = Random.secure().nextInt(150);
    return Future<void>.delayed(
      Duration(milliseconds: 150 * (attempt + 1) + jitter),
    );
  }

  Future<T> _waitWithCancellation<T>(
    Future<T> response,
    FileTransferCancellation cancellation,
    Duration timeout,
  ) => Future.any<T>([
    response,
    cancellation.whenCancelled.then<T>(
      (_) => throw const FileTransferException('paused'),
    ),
  ]).timeout(timeout);

  Future<void> _runUpload(
    _UploadWork work,
    FileTransferCancellation cancellation,
  ) async {
    var checkpoint = work.checkpoint;
    final operationGeneration = _logicalIdentityGeneration;
    final identity = _stableIdentity;
    if (identity == null) {
      throw const FileTransferException('bridge_identity_mismatch');
    }
    _requireUploadContext(
      checkpoint,
      identity,
      operationGeneration: operationGeneration,
    );
    final staged = await _storage.uploadStaged(checkpoint);
    if (!await staged.exists() ||
        await staged.length() != checkpoint.sizeBytes) {
      throw const FileTransferException('staged_file_mismatch');
    }
    var secret = await _storage.readUploadSecret(checkpoint);
    if (secret == null || secret.logicalBridgeIdentity != identity) {
      throw const FileTransferException('upload_secret_missing');
    }
    final mutationAuthorization = _uploadMutationAuthorizations.remove(
      checkpoint.transferId,
    );
    if (uploadMutationAuthRequired && mutationAuthorization == null) {
      throw const FileTransferException(
        'step_up_required',
        'Password or Face ID approval is required',
      );
    }
    _requireUploadContext(
      checkpoint,
      identity,
      operationGeneration: operationGeneration,
    );
    final prepareAt = _clock().toUtc();
    checkpoint = checkpoint.copyWith(
      requestId: _requestIdGenerator(),
      expiresAt: prepareAt.add(fileTransferCheckpointRetention),
      updatedAt: prepareAt,
    );
    work.checkpoint = checkpoint;
    await _storage.saveUpload(checkpoint);
    _requireUploadContext(
      checkpoint,
      identity,
      operationGeneration: operationGeneration,
    );
    final pending = _PendingUploadResponse(
      requestId: checkpoint.requestId,
      transferId: checkpoint.transferId,
      epoch: _connectionEpoch,
    );
    _pendingUploadResponse = pending;
    _activeRecord = _recordForUpload(checkpoint, FileTransferStatus.preparing);
    _sendLive(
      prepareFileTransferUpload(
        requestId: checkpoint.requestId,
        transferId: checkpoint.transferId,
        resumeToken: secret.resumeToken,
        filename: checkpoint.filename,
        sizeBytes: checkpoint.sizeBytes,
        mutationAuthorization: mutationAuthorization,
      ),
    );
    final first = await _waitWithCancellation<Object>(
      Future.any<Object>([pending.ready.future, pending.result.future]),
      cancellation,
      const Duration(seconds: 30),
    );
    _requireUploadContext(
      checkpoint,
      identity,
      operationGeneration: operationGeneration,
    );
    if (first is FileTransferUploadResultMessage) {
      await _completeUploadFromResult(work, checkpoint, first);
      return;
    }
    final ready = first as FileTransferUploadReadyMessage;
    if (ready.sizeBytes != checkpoint.sizeBytes ||
        ready.uploadOffset > checkpoint.sizeBytes ||
        ready.transferId != checkpoint.transferId ||
        ready.resumeToken != secret.resumeToken) {
      throw const FileTransferException('upload_ready_mismatch');
    }
    final readyAt = _clock().toUtc();
    checkpoint = checkpoint.copyWith(
      uploadedBytes: ready.uploadOffset,
      expiresAt: readyAt.add(fileTransferCheckpointRetention),
      updatedAt: readyAt,
    );
    work.checkpoint = checkpoint;
    pending.transferId = ready.transferId;
    secret = UploadTransferSecret(
      uploadUrl: ready.uploadUrl,
      uploadToken: ready.uploadToken,
      resumeToken: ready.resumeToken,
      logicalBridgeIdentity: identity,
    );
    await _storage.saveUpload(checkpoint);
    await _storage.writeUploadSecret(checkpoint, secret);
    _requireUploadContext(
      checkpoint,
      identity,
      operationGeneration: operationGeneration,
    );
    final url = _validatedUrl(
      ready.uploadUrl,
      transferId: ready.transferId,
      endpoint: 'uploads',
    );
    final head = await _http.headUpload(
      url: url,
      token: ready.uploadToken,
      cancellation: cancellation,
    );
    _requireUploadContext(
      checkpoint,
      identity,
      operationGeneration: operationGeneration,
    );
    if (head.sizeBytes != checkpoint.sizeBytes ||
        head.uploadOffset != checkpoint.uploadedBytes ||
        head.maxChunkSizeBytes != ready.maxChunkSizeBytes) {
      throw const FileTransferException('upload_head_mismatch');
    }
    if (head.complete) {
      final result = await _waitWithCancellation(
        pending.result.future,
        cancellation,
        const Duration(seconds: 30),
      );
      _requireUploadContext(
        checkpoint,
        identity,
        operationGeneration: operationGeneration,
      );
      await _completeUploadFromResult(work, checkpoint, result);
      return;
    }
    final chunkSizer = _chunkSizers.putIfAbsent(
      work.id,
      AdaptiveTransferChunkSizer.new,
    );
    while (checkpoint.uploadedBytes < checkpoint.sizeBytes) {
      _requireUploadContext(
        checkpoint,
        identity,
        operationGeneration: operationGeneration,
      );
      final chunkLength = chunkSizer.nextChunkBytes(
        totalBytes: checkpoint.sizeBytes,
        remainingBytes: checkpoint.sizeBytes - checkpoint.uploadedBytes,
        serverMaxBytes: min(head.maxChunkSizeBytes, fileTransferChunkBytes),
      );
      _activeRecord = _recordForUpload(
        checkpoint,
        FileTransferStatus.transferring,
      );
      final stopwatch = Stopwatch()..start();
      late final UploadChunkResult chunk;
      try {
        chunk = await _http.uploadChunk(
          url: url,
          token: ready.uploadToken,
          stagedFile: staged,
          offset: checkpoint.uploadedBytes,
          chunkLength: chunkLength,
          totalSizeBytes: checkpoint.sizeBytes,
          cancellation: cancellation,
          onProgress: (value) => _progress(
            _recordForUpload(
              checkpoint.copyWith(uploadedBytes: value),
              FileTransferStatus.transferring,
            ),
          ),
        );
        stopwatch.stop();
        chunkSizer.recordSuccess(
          bytes: chunkLength,
          elapsed: stopwatch.elapsed,
        );
      } catch (_) {
        chunkSizer.recordFailure();
        rethrow;
      }
      final chunkCommittedAt = _clock().toUtc();
      _requireUploadContext(
        checkpoint,
        identity,
        operationGeneration: operationGeneration,
      );
      checkpoint = checkpoint.copyWith(
        uploadedBytes: chunk.uploadOffset,
        expiresAt: chunkCommittedAt.add(fileTransferCheckpointRetention),
        updatedAt: chunkCommittedAt,
      );
      work.checkpoint = checkpoint;
      await _storage.saveUpload(checkpoint);
      _progress(
        _recordForUpload(checkpoint, FileTransferStatus.transferring),
        force: true,
      );
    }
    final result = await _waitWithCancellation(
      pending.result.future,
      cancellation,
      const Duration(seconds: 30),
    );
    _requireUploadContext(
      checkpoint,
      identity,
      operationGeneration: operationGeneration,
    );
    await _completeUploadFromResult(work, checkpoint, result);
  }

  Future<void> _completeUploadFromResult(
    _UploadWork work,
    UploadTransferCheckpoint checkpoint,
    FileTransferUploadResultMessage result,
  ) async {
    final savedFilename = result.filename;
    if (!result.success ||
        result.transferId != checkpoint.transferId ||
        result.sizeBytes != checkpoint.sizeBytes ||
        !_isSafeTransferLeaf(savedFilename)) {
      throw FileTransferException(
        result.errorCode ?? 'upload_failed',
        result.error,
      );
    }
    final completedAt = _clock().toUtc();
    final completed = checkpoint.copyWith(
      uploadedBytes: checkpoint.sizeBytes,
      expiresAt: completedAt.add(fileTransferCheckpointRetention),
      updatedAt: completedAt,
    );
    work.checkpoint = completed;
    try {
      // The Bridge has already committed this stable transfer identity. Local
      // cleanup must not turn a confirmed upload into a user-visible failure;
      // any surviving checkpoint is safe to reconcile idempotently later.
      await _storage.saveUpload(completed);
      await _storage.deleteUpload(completed, deleteStaged: true);
    } catch (_) {}
    _chunkSizers.remove(work.id);
    _uploadMutationAuthorizations.remove(checkpoint.transferId);
    _remember(
      _recordForUpload(
        completed,
        FileTransferStatus.succeeded,
        savedFilename: savedFilename,
        savedPath: result.savedPath,
      ),
    );
  }

  Future<void> _requireCapacity(String targetPath, int remainingBytes) async {
    final available = await _capacity.availableCapacityBytes(targetPath);
    if (available == null ||
        available < remainingBytes + fileTransferStorageSafetyReserveBytes) {
      throw const FileTransferException(
        'insufficient_storage',
        'Not enough free space to continue safely.',
      );
    }
  }

  void _requireReceiveContext(
    ReceiveTransferCheckpoint checkpoint,
    DownloadTransferSecret? secret, {
    required int operationGeneration,
  }) {
    final identity = _stableIdentity;
    if (operationGeneration != _logicalIdentityGeneration ||
        identity == null ||
        _storage.bridgeKey(identity) != checkpoint.bridgeKey ||
        (secret != null && secret.logicalBridgeIdentity != identity)) {
      throw const FileTransferException('bridge_identity_mismatch');
    }
  }

  void _requireUploadContext(
    UploadTransferCheckpoint checkpoint,
    String? identity, {
    required int operationGeneration,
  }) {
    if (operationGeneration != _logicalIdentityGeneration ||
        identity == null ||
        _stableIdentity != identity ||
        _storage.bridgeKey(identity) != checkpoint.bridgeKey) {
      throw const FileTransferException('bridge_identity_mismatch');
    }
  }

  bool _workMatchesCurrentIdentity(_TransferWork work) {
    final identity = _stableIdentity;
    if (identity == null) return false;
    final currentBridgeKey = _storage.bridgeKey(identity);
    return switch (work) {
      _ReceiveWork(:final checkpoint) =>
        checkpoint.bridgeKey == currentBridgeKey,
      _UploadWork(:final checkpoint) =>
        checkpoint.bridgeKey == currentBridgeKey,
    };
  }

  ({bool connected, String? identity, bool supported}) _capabilitySnapshot() =>
      (
        connected: _bridge.isConnected,
        identity: _stableIdentity,
        supported: _bridge.capabilities.contains(fileTransferCapability),
      );

  void _handleCapabilityChange() {
    final snapshot = _capabilitySnapshot();
    if (snapshot == _lastCapabilitySnapshot) return;
    final previous = _lastCapabilitySnapshot;
    _handleLogicalIdentityTransition(
      _lastCapabilitySnapshot?.identity,
      snapshot.identity,
    );
    _lastCapabilitySnapshot = snapshot;
    if (snapshot.supported && previous?.supported != true) {
      _resetCompletionRecoveryRetryRound(reopenExhausted: true);
    }
    _resumePausedIfReady();
    _launch(_drain(completedOnly: true));
    _scheduleRecovery();
    _notify(force: true);
  }

  void _handleConnectionState(BridgeConnectionState state) {
    final snapshot = _capabilitySnapshot();
    _handleLogicalIdentityTransition(
      _lastCapabilitySnapshot?.identity,
      snapshot.identity,
    );
    _lastCapabilitySnapshot = snapshot;
    if (state == BridgeConnectionState.connected) {
      _resumePausedIfReady();
      _launch(_drain(completedOnly: true));
      _scheduleRecovery();
      return;
    }
    _markQueuedReceivesForLeaseRefresh();
    _resetCompletionRecoveryRetryRound();
    _connectionEpoch++;
    _uploadMutationAuthorizations.clear();
    _completedReceives.clear();
    _activeCancellation?.cancel();
    _failPendingUpload(const FileTransferException('bridge_disconnected'));
    _failPendingDownload(const FileTransferException('bridge_disconnected'));
    _failPendingCancel(const FileTransferException('bridge_disconnected'));
    _notify(force: true);
  }

  void _handleLogicalIdentityTransition(String? previous, String? next) {
    if (previous == next) return;

    _logicalIdentityGeneration++;
    _connectionEpoch++;
    _resetCompletionRecoveryRetryRound();
    _activeCancellation?.cancel();
    final changed = const FileTransferException('bridge_identity_mismatch');
    _failUploadCompletions(changed);
    _failPendingUpload(changed);
    _failPendingDownload(changed);
    _failPendingCancel(changed);
    _pendingUploadResponse = null;
    _pendingDownloadResume = null;
    _pendingCancel = null;

    // These structures are connection-owned caches only. Durable checkpoints,
    // partial downloads, completed tombstones, and staged uploads intentionally
    // remain in the old machine's hashed storage scope for later recovery.
    _receiveQueue.clear();
    _completionRecoveryQueue.clear();
    _uploadRecoveryQueue.clear();
    _uploadMutationAuthorizations.clear();
    _knownReceiveIds.clear();
    _receiveReservations.clear();
    _completedReceives.clear();
    _chunkSizers.clear();
    _pausedWork = null;
    _activeRecord = null;
    _queuedReceiveBytes = 0;
    _reservedReceiveBytes = 0;
    _recoveryDeferredForCapacity = false;
    _resumeScheduled = false;
    _resumeWhenIdleRequested = false;
    _lastProgressNotify = null;
    _notify(force: true);
  }

  void _markQueuedReceivesForLeaseRefresh() {
    if (_activeWork case final _ReceiveWork active) {
      active.renewLease = true;
    }
    if (_pausedWork case final _ReceiveWork paused) {
      paused.renewLease = true;
    }
    for (final work in _receiveQueue) {
      work.renewLease = true;
    }
    for (final work in _completionRecoveryQueue) {
      work.renewLease = true;
    }
  }

  void _resumePausedIfReady() {
    if (_resumeScheduled || !_autoResume || _pausedWork == null) {
      return;
    }
    if (_processing) {
      if (uploadAvailable && _stableIdentity != null) {
        _resumeWhenIdleRequested = true;
      }
      return;
    }
    if (!uploadAvailable || _stableIdentity == null) return;
    _resumeScheduled = true;
    _launch(
      Future<void>.delayed(Duration.zero).then((_) async {
        try {
          if (_autoResume &&
              _pausedWork != null &&
              !_processing &&
              uploadAvailable &&
              _stableIdentity != null) {
            await continuePaused();
          }
        } finally {
          _resumeScheduled = false;
        }
      }),
    );
  }

  void _scheduleRecovery() {
    if (_disposed ||
        _recoveryScheduled ||
        _processing ||
        _pausedWork != null ||
        !_platformSupported ||
        !uploadAvailable ||
        _stableIdentity == null) {
      return;
    }
    _recoveryScheduled = true;
    _launch(_recover());
  }

  Future<void> _recover() async {
    var skippedForCapacity = false;
    _recoveryRescanRequested = false;
    final recoveryGeneration = _logicalIdentityGeneration;
    final identity = _stableIdentity ?? '';
    bool stillCurrent() =>
        identity.isNotEmpty &&
        recoveryGeneration == _logicalIdentityGeneration &&
        uploadAvailable &&
        _stableIdentity == identity;
    try {
      if (!stillCurrent()) return;
      await _markTransientStorage(identity);
      if (!stillCurrent()) return;
      final uploads = await _storage.loadUploads(identity);
      if (!stillCurrent()) return;
      for (final checkpoint in uploads) {
        if (!stillCurrent()) return;
        if (checkpoint.expiresAt.isBefore(_clock().toUtc())) {
          try {
            await _storage.deleteUpload(checkpoint, deleteStaged: true);
          } catch (_) {
            // Metadata remains the last durable cleanup marker, so a later
            // recovery can retry without losing ownership of the stage.
          }
          continue;
        }
        UploadTransferSecret? secret;
        try {
          secret = await _storage.readUploadSecret(checkpoint);
        } on FormatException {
          if (!stillCurrent()) return;
          try {
            await _storage.deleteUpload(checkpoint, deleteStaged: true);
          } catch (_) {}
          continue;
        } catch (_) {
          // A transient Keychain read failure is not proof that the secret is
          // gone. Preserve the checkpoint and retry on the next recovery.
          continue;
        }
        if (!stillCurrent()) return;
        if (secret == null || secret.logicalBridgeIdentity != identity) {
          try {
            await _storage.deleteUpload(checkpoint, deleteStaged: true);
          } catch (_) {}
          continue;
        }
        if (!_uploadRecoveryQueue.any(
          (item) => item.localId == checkpoint.localId,
        )) {
          _uploadRecoveryQueue.add(checkpoint);
        }
      }
      try {
        await _storage.cleanupUnreferencedUploadStages(identity);
      } catch (_) {
        // Optional cleanup must not stop valid checkpoint recovery.
      }
      if (!stillCurrent()) return;
      final receives = await _storage.loadReceives(identity);
      if (!stillCurrent()) return;
      for (final checkpoint in receives) {
        if (!stillCurrent()) return;
        if (checkpoint.expiresAt.isBefore(_clock().toUtc())) {
          try {
            await _storage.deleteReceive(checkpoint, deletePartial: true);
          } catch (_) {}
          continue;
        }
        if (_knownReceiveIds.contains(checkpoint.transferId) ||
            _receiveReservations.containsKey(checkpoint.transferId)) {
          continue;
        }
        if (checkpoint.commitState == 'complete' &&
            (_completedReceives.containsKey(checkpoint.transferId) ||
                (_completionRecoveryAttempts[checkpoint.transferId] ?? 0) >=
                    completionRecoveryRetryLimit)) {
          continue;
        }
        DownloadTransferSecret? secret;
        try {
          secret = await _storage.readDownloadSecret(checkpoint);
        } on FormatException {
          if (!stillCurrent()) return;
          if (checkpoint.commitState == 'complete') {
            // The final file and pending-notification state are non-secret and
            // already verified below. A corrupt token prevents ACK only; it
            // must not discard a still-undelivered local notification.
            secret = null;
          } else {
            try {
              await _storage.deleteReceive(checkpoint, deletePartial: true);
            } catch (_) {}
            continue;
          }
        } catch (_) {
          continue;
        }
        if (!stillCurrent()) return;
        if (_knownReceiveIds.contains(checkpoint.transferId) ||
            _receiveReservations.containsKey(checkpoint.transferId)) {
          continue;
        }
        if (checkpoint.commitState == 'complete') {
          _knownReceiveIds.add(checkpoint.transferId);
          _completionRecoveryQueue.add(
            _ReceiveWork(
              checkpoint,
              secret?.logicalBridgeIdentity == identity ? secret : null,
              renewLease: true,
            ),
          );
          continue;
        }
        if (secret == null || secret.logicalBridgeIdentity != identity) {
          try {
            await _storage.deleteReceive(checkpoint, deletePartial: true);
          } catch (_) {}
          continue;
        }
        if (_receiveReservations.containsKey(checkpoint.transferId)) {
          continue;
        }
        if (!_tryReserveReceive(
          checkpoint.transferId,
          checkpoint.sizeBytes,
          recoveryGeneration,
        )) {
          skippedForCapacity = true;
          continue;
        }
        try {
          try {
            await _storage.reconcileReceivePartial(checkpoint);
          } on FileTransferStorageException {
            continue;
          }
          if (!stillCurrent()) return;
          if (_knownReceiveIds.contains(checkpoint.transferId)) continue;
          _releaseReceiveReservation(checkpoint.transferId, recoveryGeneration);
          _knownReceiveIds.add(checkpoint.transferId);
          _enqueueReceive(_ReceiveWork(checkpoint, secret, renewLease: true));
        } finally {
          _releaseReceiveReservation(checkpoint.transferId, recoveryGeneration);
        }
      }
      if (!stillCurrent()) return;
      _notify(force: true);
      await _drain(completedOnly: !_autoResume);
    } finally {
      final current = stillCurrent();
      final rescanRequested = _recoveryRescanRequested;
      _recoveryDeferredForCapacity = current && skippedForCapacity;
      _recoveryScheduled = false;
      if (!current) {
        _scheduleRecovery();
      } else if (rescanRequested) {
        _scheduleRecovery();
      } else if (skippedForCapacity && _autoResume && _pausedWork == null) {
        _scheduleRecovery();
      }
    }
  }

  Uri _validatedUrl(
    String raw, {
    required String transferId,
    required String endpoint,
  }) {
    final base = Uri.tryParse(_bridge.httpBaseUrl ?? '');
    final uri = Uri.tryParse(raw);
    if (base == null ||
        !_isSafeHttpOrigin(base) ||
        uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.fragment.isNotEmpty ||
        !_sameOrigin(base, uri) ||
        uri.pathSegments.length != 4 ||
        uri.pathSegments[0] != 'api' ||
        uri.pathSegments[1] != 'file-transfers' ||
        uri.pathSegments[2] != endpoint ||
        uri.pathSegments[3] != transferId) {
      throw const FileTransferException('invalid_transfer_url');
    }
    return uri;
  }

  Uri _currentDownloadUrl(String transferId) {
    final base = Uri.tryParse(_bridge.httpBaseUrl ?? '');
    if (base == null || !_isSafeHttpOrigin(base)) {
      throw const FileTransferException('invalid_transfer_url');
    }
    final rebuilt = Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      pathSegments: ['api', 'file-transfers', 'downloads', transferId],
    );
    return _validatedUrl(
      rebuilt.toString(),
      transferId: transferId,
      endpoint: 'downloads',
    );
  }

  void _sendReceiveResult(
    String transferId, {
    required bool success,
    String? savedFilename,
    int? receivedBytes,
    String? error,
    String? errorCode,
  }) {
    if (!isConnected) return;
    try {
      _sendLive(
        acknowledgeFileTransferReceive(
          transferId: transferId,
          success: success,
          savedFilename: savedFilename,
          receivedBytes: receivedBytes,
          error: error,
          errorCode: errorCode,
        ),
      );
    } catch (_) {
      // Live-only acknowledgement: never replay through the chat queue.
    }
  }

  void _sendLive(ClientMessage message) {
    if (!isConnected) {
      throw const FileTransferException('bridge_disconnected');
    }
    try {
      _bridge.send(message);
    } catch (_) {
      throw const FileTransferException('bridge_disconnected');
    }
  }

  void _failPendingUpload(Object error) {
    final pending = _pendingUploadResponse;
    if (pending == null) return;
    if (!pending.ready.isCompleted) pending.ready.completeError(error);
    if (!pending.result.isCompleted) pending.result.completeError(error);
  }

  void _failPendingDownload(Object error) {
    final pending = _pendingDownloadResume;
    if (pending != null && !pending.result.isCompleted) {
      pending.result.completeError(error);
    }
  }

  void _failPendingCancel(Object error) {
    final pending = _pendingCancel;
    if (pending != null && !pending.result.isCompleted) {
      pending.result.completeError(error);
    }
  }

  void _launch(Future<void> future) {
    unawaited(future.catchError((Object _, StackTrace _) {}));
  }

  void _notifySafely(Future<void>? Function() notification) {
    try {
      final future = notification();
      if (future != null) _launch(future);
    } catch (_) {
      // Local notifications are advisory; plugin/channel failures must never
      // escape into transfer state or the app's chat event loop.
    }
  }

  Future<void> _cleanupWork(_TransferWork work) async {
    _chunkSizers.remove(work.id);
    if (work is _ReceiveWork) {
      await _storage.deleteReceive(work.checkpoint, deletePartial: true);
      _knownReceiveIds.remove(work.checkpoint.transferId);
    } else if (work is _UploadWork) {
      _uploadMutationAuthorizations.remove(work.checkpoint.transferId);
      await _storage.deleteUpload(work.checkpoint, deleteStaged: true);
    }
  }

  Future<void> _markTransientStorage(String logicalIdentity) async {
    final paths = await _storage.transientDirectoryPaths(logicalIdentity);
    for (final value in paths) {
      await _commit.markTransient(value);
    }
  }

  void _validateSelection(FileTransferSelection selection) {
    _validateIngressMetadata(selection.filename, selection.sizeBytes);
  }

  Future<FileMutationAuthorization?> _authorizeUploadMutation(
    UploadTransferCheckpoint checkpoint,
    FileMutationAuthorizationCallback? authorizeMutation,
  ) async {
    if (!uploadMutationAuthRequired) return null;
    if (authorizeMutation == null) {
      throw const FileTransferException('mutation_auth_required');
    }
    final authorization = await authorizeMutation(
      FileMutationOperation.upload(
        transferId: checkpoint.transferId,
        filename: checkpoint.filename,
        sizeBytes: checkpoint.sizeBytes,
      ),
    );
    if (authorization == null) {
      throw const FileTransferException('mutation_auth_cancelled');
    }
    return authorization;
  }

  void _validateIngressMetadata(String filename, int? sizeBytes) {
    if (filename.trim().isEmpty ||
        filename.length > 1024 ||
        filename.contains('\u0000') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(filename) ||
        path.basename(filename) != filename ||
        (sizeBytes != null &&
            (sizeBytes < 0 || sizeBytes > maxFileTransferBytes))) {
      throw const FileTransferException('invalid_selection');
    }
  }

  void _progress(FileTransferRecord record, {bool force = false}) {
    _activeRecord = record;
    final now = _clock();
    if (!force &&
        _lastProgressNotify != null &&
        now.difference(_lastProgressNotify!) <
            const Duration(milliseconds: 100)) {
      return;
    }
    _lastProgressNotify = now;
    _notify(force: true);
  }

  void _remember(FileTransferRecord record) {
    _recentResults.removeWhere((item) => item.id == record.id);
    _recentResults.insert(0, record);
    if (_recentResults.length > recentResultLimit) {
      _recentResults.removeRange(recentResultLimit, _recentResults.length);
    }
    if (record.direction == FileTransferDirection.upload &&
        const {
          FileTransferStatus.succeeded,
          FileTransferStatus.failed,
          FileTransferStatus.paused,
          FileTransferStatus.cancelled,
        }.contains(record.status)) {
      final completion = _uploadCompletions.remove(record.id);
      if (completion != null && !completion.isCompleted) {
        completion.complete(record);
      }
    }
    _notify(force: true);
  }

  void _failUploadCompletions(Object error) {
    final pending = _uploadCompletions.values.toList(growable: false);
    _uploadCompletions.clear();
    for (final completion in pending) {
      if (!completion.isCompleted) completion.completeError(error);
    }
  }

  String? get _stableIdentity {
    final value = _bridge.logicalConnectionIdentity?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  void _notify({bool force = false}) {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _activeCancellation?.cancel();
    _uploadMutationAuthorizations.clear();
    const disposed = FileTransferException('disposed');
    _failUploadCompletions(disposed);
    _failPendingUpload(disposed);
    _failPendingDownload(const FileTransferException('disposed'));
    _failPendingCancel(const FileTransferException('disposed'));
    unawaited(_messageSubscription.cancel());
    unawaited(_connectionSubscription.cancel());
    unawaited(_capabilitySubscription.cancel());
    if (_ownsHttpClient) _httpClient.close();
    super.dispose();
  }
}

class FileTransferException implements Exception {
  final String code;
  final String? message;
  const FileTransferException(this.code, [this.message]);

  @override
  String toString() => message ?? code;
}

sealed class _TransferWork {
  bool cancelled = false;
  Future<void>? cancelRequest;
  String get id;
  String get filename;
}

class _ReceiveWork extends _TransferWork {
  ReceiveTransferCheckpoint checkpoint;
  DownloadTransferSecret? secret;
  bool renewLease;
  _ReceiveWork(this.checkpoint, this.secret, {this.renewLease = false});
  @override
  String get id => checkpoint.transferId;
  @override
  String get filename => checkpoint.filename;
}

class _PendingDownloadResume {
  final String requestId;
  final String transferId;
  final int epoch;
  final Completer<FileTransferDownloadResumedMessage> result = Completer();

  _PendingDownloadResume({
    required this.requestId,
    required this.transferId,
    required this.epoch,
  });
}

class _PendingCancel {
  final String requestId;
  final String transferId;
  final FileTransferCancelDirection direction;
  final int epoch;
  final Completer<FileTransferCancelResultMessage> result = Completer();

  _PendingCancel({
    required this.requestId,
    required this.transferId,
    required this.direction,
    required this.epoch,
  });
}

class _UploadWork extends _TransferWork {
  UploadTransferCheckpoint checkpoint;
  _UploadWork(this.checkpoint);
  @override
  String get id => checkpoint.localId;
  @override
  String get filename => checkpoint.filename;
}

class _PendingUploadResponse {
  final String requestId;
  String? transferId;
  final int epoch;
  final Completer<FileTransferUploadReadyMessage> ready = Completer();
  final Completer<FileTransferUploadResultMessage> result = Completer();
  _PendingUploadResponse({
    required this.requestId,
    required this.transferId,
    required this.epoch,
  });
}

FileTransferRecord _recordForReceive(
  ReceiveTransferCheckpoint checkpoint,
  FileTransferStatus status, {
  String? savedFilename,
  String? errorCode,
  String? error,
}) => FileTransferRecord(
  id: checkpoint.transferId,
  direction: FileTransferDirection.receive,
  status: status,
  filename: checkpoint.filename,
  transferredBytes: checkpoint.receivedBytes,
  totalBytes: checkpoint.sizeBytes,
  updatedAt: checkpoint.updatedAt,
  savedFilename: savedFilename,
  errorCode: errorCode,
  error: error,
);

FileTransferRecord _recordForUpload(
  UploadTransferCheckpoint checkpoint,
  FileTransferStatus status, {
  String? savedFilename,
  String? savedPath,
  String? errorCode,
  String? error,
}) => FileTransferRecord(
  id: checkpoint.localId,
  direction: FileTransferDirection.upload,
  status: status,
  filename: checkpoint.filename,
  transferredBytes: checkpoint.uploadedBytes,
  totalBytes: checkpoint.sizeBytes,
  updatedAt: checkpoint.updatedAt,
  savedFilename: savedFilename,
  savedPath: savedPath,
  errorCode: errorCode,
  error: error,
);

FileTransferRecord _recordForWork(
  _TransferWork work,
  FileTransferStatus status, {
  String? errorCode,
  String? error,
}) => switch (work) {
  _ReceiveWork(:final checkpoint) => _recordForReceive(
    checkpoint,
    status,
    errorCode: errorCode,
    error: error,
  ),
  _UploadWork(:final checkpoint) => _recordForUpload(
    checkpoint,
    status,
    errorCode: errorCode,
    error: error,
  ),
};

bool _isRecoverable(Object error) {
  if (error is SocketException ||
      error is http.ClientException ||
      error is TimeoutException) {
    return true;
  }
  if (error is FileTransferHttpException) {
    final status = error.statusCode;
    if (status == HttpStatus.requestTimeout ||
        status == 425 ||
        status == HttpStatus.tooManyRequests ||
        (status != null && status >= 500) ||
        (status == HttpStatus.notFound && error.code.startsWith('upload_')) ||
        (status == HttpStatus.conflict && error.code.startsWith('upload_')) ||
        (status == null &&
            const {
              'paused',
              'total_timeout',
              'idle_timeout',
              'upload_offset_mismatch',
            }.contains(error.code))) {
      return true;
    }
  }
  final code = _errorCode(error);
  return const {
    'paused',
    'bridge_disconnected',
    'total_timeout',
    'idle_timeout',
    'insufficient_storage',
    'notification_pending',
    'upload_offset_mismatch',
    'step_up_required',
    'invalid_password',
    'password_rate_limited',
    'password_not_configured',
    'biometric_not_enrolled',
    'challenge_invalid_or_expired',
    'invalid_biometric_proof',
  }.contains(code);
}

@visibleForTesting
bool fileTransferErrorIsRecoverableForTest(Object error) =>
    _isRecoverable(error);

bool _downloadStateIsMissing(FileTransferException error) =>
    error.code == 'download_not_found' || error.code == 'not_found';

String _errorCode(Object error) => switch (error) {
  FileTransferException(:final code) => code,
  FileTransferHttpException(:final code) => code,
  FileTransferStorageException(:final code) => code,
  TimeoutException() => 'timeout',
  SocketException() => 'connection_failed',
  http.ClientException() => 'connection_failed',
  _ => 'transfer_failed',
};

String _errorMessage(Object error) => switch (error) {
  FileTransferException(:final message, :final code) => message ?? code,
  FileTransferHttpException(:final code) => code,
  FileTransferStorageException(:final code) => code,
  _ => 'The transfer could not be completed.',
};

bool _isSafeTransferLeaf(String? value) =>
    value != null &&
    value.trim().isNotEmpty &&
    value.length <= 1024 &&
    value != '.' &&
    value != '..' &&
    !value.contains('\u0000') &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value) &&
    path.basename(value) == value &&
    !value.contains('\\');

int _latestReceivedMicros(Iterable<ReceivedFileTransfer> files) {
  var latest = 0;
  for (final file in files) {
    final value = file.modifiedAt.microsecondsSinceEpoch;
    if (value > latest) latest = value;
  }
  return latest;
}

bool _isSafeHttpOrigin(Uri uri) =>
    uri.isAbsolute &&
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    (uri.path.isEmpty || uri.path == '/') &&
    !uri.hasQuery &&
    uri.fragment.isEmpty;

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    _effectivePort(left) == _effectivePort(right);

int _effectivePort(Uri uri) =>
    uri.hasPort ? uri.port : (uri.scheme.toLowerCase() == 'https' ? 443 : 80);

String _secureRequestId() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

String _secureToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
