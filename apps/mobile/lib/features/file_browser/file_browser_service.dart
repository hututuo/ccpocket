import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/messages.dart';
import '../../services/bridge_service.dart';

const _fileBrowserPinsPreference = 'file_browser_v1_pins';
const _fileBrowserMaxPins = 64;
const _fileBrowserDirectoryCacheLimit = 20;
const _fileBrowserDirectoryCacheNodeBudget = 5000;
const _fileBrowserVisibleNodeBudget = 5000;
const _fileBrowserDirectoryCacheTtl = Duration(minutes: 5);
const _fileBrowserRequestTimeout = Duration(seconds: 15);

enum FileBrowserAvailability {
  disconnected,
  unsupported,
  loading,
  ready,
  error,
}

class FileBrowserException implements Exception {
  final String code;
  final String message;

  const FileBrowserException(this.code, [this.message = '']);

  @override
  String toString() => message.isEmpty ? code : '$code: $message';
}

abstract interface class FileBrowserBridgeGateway {
  bool get isConnected;
  String? get logicalConnectionIdentity;
  String? get httpBaseUrl;
  Set<String> get capabilities;
  Stream<BridgeConnectionState> get connectionStatus;
  Stream<void> get capabilityChanges;
  Stream<LocalFeatureServerMessage> get messages;
  void send(ClientMessage message);
}

class BridgeServiceFileBrowserGateway implements FileBrowserBridgeGateway {
  const BridgeServiceFileBrowserGateway(this._bridge);

  final BridgeService _bridge;

  @override
  bool get isConnected => _bridge.isConnected;

  @override
  String? get logicalConnectionIdentity => _bridge.logicalConnectionIdentity;

  @override
  String? get httpBaseUrl => _bridge.httpBaseUrl;

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
          supported: _bridge.bridgeCapabilities.contains(fileBrowserCapability),
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

class FileBrowserDirectorySnapshot {
  final String rootId;
  final String relativePath;
  final String directoryRevision;
  final List<FileBrowserNode> entries;
  final String? nextCursor;
  final DateTime loadedAt;
  final bool truncated;

  const FileBrowserDirectorySnapshot({
    required this.rootId,
    required this.relativePath,
    required this.directoryRevision,
    required this.entries,
    required this.nextCursor,
    required this.loadedAt,
    this.truncated = false,
  });

  bool get hasMore => nextCursor != null;
}

class FileBrowserPreview {
  final String rootId;
  final String relativePath;
  final Uri previewUri;
  final String filename;
  final String mimeType;
  final int sizeBytes;
  final String previewKind;
  final String expiresAt;

  const FileBrowserPreview({
    required this.rootId,
    required this.relativePath,
    required this.previewUri,
    required this.filename,
    required this.mimeType,
    required this.sizeBytes,
    required this.previewKind,
    required this.expiresAt,
  });
}

class FileBrowserPin {
  final String logicalConnectionIdentity;
  final String bridgeInstanceId;
  final String rootId;
  final String relativePath;
  final String rootLabel;
  final String label;
  final DateTime addedAt;

  const FileBrowserPin({
    required this.logicalConnectionIdentity,
    required this.bridgeInstanceId,
    required this.rootId,
    required this.relativePath,
    required this.rootLabel,
    required this.label,
    required this.addedAt,
  });

  String get key =>
      '$logicalConnectionIdentity\u0000$bridgeInstanceId\u0000$rootId\u0000$relativePath';

  Map<String, Object?> toJson() => <String, Object?>{
    'logicalConnectionIdentity': logicalConnectionIdentity,
    'bridgeInstanceId': bridgeInstanceId,
    'rootId': rootId,
    'relativePath': relativePath,
    'rootLabel': rootLabel,
    'label': label,
    'addedAt': addedAt.toUtc().toIso8601String(),
  };

  static FileBrowserPin? tryParse(Object? value) {
    if (value is! Map) return null;
    final json = Map<String, dynamic>.from(value);
    final identity = _boundedText(json['logicalConnectionIdentity'], 512);
    final bridgeId = _boundedText(json['bridgeInstanceId'], 256);
    final rootId = _boundedText(json['rootId'], 128);
    final relativePath = _validStoredRelativePath(json['relativePath']);
    final rootLabel = _boundedText(json['rootLabel'], 1024);
    final label = _boundedText(json['label'], 1024);
    final addedAt = DateTime.tryParse(json['addedAt'] as String? ?? '');
    if (identity == null ||
        bridgeId == null ||
        rootId == null ||
        relativePath == null ||
        rootLabel == null ||
        label == null ||
        addedAt == null) {
      return null;
    }
    return FileBrowserPin(
      logicalConnectionIdentity: identity,
      bridgeInstanceId: bridgeId,
      rootId: rootId,
      relativePath: relativePath,
      rootLabel: rootLabel,
      label: label,
      addedAt: addedAt.toUtc(),
    );
  }
}

class FileBrowserService extends ChangeNotifier {
  factory FileBrowserService({
    required FileBrowserBridgeGateway bridge,
    required SharedPreferences preferences,
    DateTime Function()? clock,
    String Function()? requestIdGenerator,
    Duration requestTimeout = _fileBrowserRequestTimeout,
  }) => FileBrowserService._(
    bridge,
    preferences,
    clock ?? DateTime.now,
    requestIdGenerator ?? _newRequestId,
    requestTimeout,
    _readPins(preferences),
  );

  FileBrowserService._(
    this._bridge,
    this._preferences,
    this._clock,
    this._requestIdGenerator,
    this._requestTimeout,
    this._pins,
  ) {
    _lastConnectionIdentity = _stableLogicalIdentity;
    _lastCapabilitySupported = supportedByBridge;
    _availability = !_bridge.isConnected
        ? FileBrowserAvailability.disconnected
        : supportedByBridge
        ? FileBrowserAvailability.loading
        : FileBrowserAvailability.unsupported;
    _messageSubscription = _bridge.messages.listen(_handleMessage);
    _connectionSubscription = _bridge.connectionStatus.listen(
      _handleConnectionState,
    );
    _capabilitySubscription = _bridge.capabilityChanges.listen(
      (_) => _handleCapabilityChange(),
    );
  }

  final FileBrowserBridgeGateway _bridge;
  final SharedPreferences _preferences;
  final DateTime Function() _clock;
  final String Function() _requestIdGenerator;
  final Duration _requestTimeout;
  final List<FileBrowserPin> _pins;
  final Map<String, _PendingFileBrowserRequest> _pending = {};
  final LinkedHashMap<String, FileBrowserDirectorySnapshot> _directoryCache =
      LinkedHashMap();
  final Map<String, Future<FileBrowserDirectorySnapshot>> _directoryLoads = {};
  final Map<String, Future<FileBrowserDirectorySnapshot>> _paginationLoads = {};
  final Map<String, int> _directoryMutationEpochs = {};

  late final StreamSubscription<LocalFeatureServerMessage> _messageSubscription;
  late final StreamSubscription<BridgeConnectionState> _connectionSubscription;
  late final StreamSubscription<void> _capabilitySubscription;

  FileBrowserAvailability _availability = FileBrowserAvailability.disconnected;
  List<FileBrowserRoot> _roots = const [];
  String? _bridgeInstanceId;
  String? _rootSetRevision;
  int _previewMaxBytes = maxFileBrowserPreviewBytes;
  int _downloadMaxBytes = maxFileBrowserDownloadBytes;
  bool _downloadAvailable = false;
  String? _lastErrorCode;
  String? _lastError;
  String? _lastConnectionIdentity;
  bool _lastCapabilitySupported = false;
  int _connectionGeneration = 0;
  int _scopeRevision = 0;
  int _nextDirectoryMutationEpoch = 0;
  int _directoryCacheNodeCount = 0;
  Future<void>? _rootsRefreshInFlight;
  bool _disposed = false;

  FileBrowserAvailability get availability => _availability;
  bool get isConnected => _bridge.isConnected;
  bool get supportedByBridge =>
      _bridge.capabilities.contains(fileBrowserCapability);
  List<FileBrowserRoot> get roots => List.unmodifiable(_roots);
  String? get bridgeInstanceId => _bridgeInstanceId;
  String? get rootSetRevision => _rootSetRevision;
  int get previewMaxBytes => _previewMaxBytes;
  int get downloadMaxBytes => _downloadMaxBytes;
  bool get downloadAvailable => _downloadAvailable;
  bool get hasStableConnectionIdentity => _stableLogicalIdentity != null;
  bool get canReceiveDownloads =>
      _downloadAvailable && hasStableConnectionIdentity;
  bool get canPersistPins =>
      hasStableConnectionIdentity && _bridgeInstanceId != null;
  String? get lastErrorCode => _lastErrorCode;
  String? get lastError => _lastError;
  int get scopeRevision => _scopeRevision;
  @visibleForTesting
  int get cachedDirectoryNodeCount => _directoryCacheNodeCount;

  List<FileBrowserPin> get currentPins {
    final identity = _stableLogicalIdentity;
    final bridgeId = _bridgeInstanceId;
    if (identity == null || bridgeId == null) return const [];
    final matching =
        _pins
            .where(
              (pin) =>
                  pin.logicalConnectionIdentity == identity &&
                  pin.bridgeInstanceId == bridgeId,
            )
            .toList(growable: false)
          ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return List.unmodifiable(matching);
  }

  Future<void> refreshRoots() {
    final inFlight = _rootsRefreshInFlight;
    if (inFlight != null) return inFlight;
    final operation = _refreshRoots();
    _rootsRefreshInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_rootsRefreshInFlight, operation)) {
        _rootsRefreshInFlight = null;
      }
    });
  }

  Future<void> _refreshRoots() async {
    if (!_bridge.isConnected) {
      _setAvailability(FileBrowserAvailability.disconnected);
      throw const FileBrowserException('bridge_disconnected');
    }
    if (!supportedByBridge) {
      _setAvailability(FileBrowserAvailability.unsupported);
      throw const FileBrowserException('bridge_unsupported');
    }
    _setAvailability(FileBrowserAvailability.loading);
    final requestScope = _scopeRevision;
    final requestId = _requestIdGenerator();
    try {
      final result = await _request<FileBrowserRootsResultMessage>(
        requestId: requestId,
        requestType: 'file_browser_roots_v1',
        message: requestFileBrowserRoots(requestId: requestId),
        matches: (message) => message is FileBrowserRootsResultMessage,
      );
      if (requestScope != _scopeRevision) {
        throw const FileBrowserException('bridge_scope_changed');
      }
      final previousBridgeId = _bridgeInstanceId;
      final previousRevision = _rootSetRevision;
      _bridgeInstanceId = result.bridgeInstanceId!;
      _rootSetRevision = result.rootSetRevision!;
      _roots = List.unmodifiable(result.roots);
      _previewMaxBytes = result.previewMaxBytes!;
      _downloadMaxBytes = result.downloadMaxBytes!;
      _downloadAvailable = result.downloadAvailable!;
      if (previousBridgeId != _bridgeInstanceId ||
          previousRevision != _rootSetRevision) {
        _clearDirectoryState();
        _scopeRevision++;
      }
      _lastErrorCode = null;
      _lastError = null;
      _setAvailability(FileBrowserAvailability.ready);
    } on FileBrowserException catch (error) {
      _lastErrorCode = error.code;
      _lastError = error.message;
      _setAvailability(
        error.code == 'bridge_unsupported' ||
                error.code == 'unsupported_message' ||
                error.code == 'unsupported_capability'
            ? FileBrowserAvailability.unsupported
            : FileBrowserAvailability.error,
      );
      rethrow;
    }
  }

  Future<FileBrowserDirectorySnapshot> loadDirectory({
    required String rootId,
    required String relativePath,
    bool showHidden = false,
    bool refresh = false,
  }) async {
    _requireReady();
    final cacheKey = _directoryCacheKey(rootId, relativePath, showHidden);
    final inFlight = _directoryLoads[cacheKey];
    if (inFlight != null) return inFlight;
    if (refresh) {
      _removeCachedDirectory(cacheKey);
    } else {
      final cached = _freshCachedDirectory(cacheKey);
      if (cached != null) return cached;
    }
    final scope = _scopeRevision;
    final mutationEpoch = _beginDirectoryMutation(cacheKey);
    final operation = _loadDirectoryRemote(
      cacheKey: cacheKey,
      rootId: rootId,
      relativePath: relativePath,
      showHidden: showHidden,
      scope: scope,
      mutationEpoch: mutationEpoch,
    );
    _directoryLoads[cacheKey] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_directoryLoads[cacheKey], operation)) {
        _directoryLoads.remove(cacheKey);
      }
      _finishDirectoryMutation(cacheKey, mutationEpoch);
    }
  }

  Future<FileBrowserDirectorySnapshot> _loadDirectoryRemote({
    required String cacheKey,
    required String rootId,
    required String relativePath,
    required bool showHidden,
    required int scope,
    required int mutationEpoch,
  }) async {
    final requestId = _requestIdGenerator();
    final result = await _request<FileBrowserListResultMessage>(
      requestId: requestId,
      requestType: 'file_browser_list_v1',
      message: requestFileBrowserList(
        requestId: requestId,
        rootId: rootId,
        relativePath: relativePath,
        pageSize: defaultFileBrowserPageSize,
        showHidden: showHidden,
      ),
      matches: (message) => message is FileBrowserListResultMessage,
    );
    if (result.rootId != rootId || result.relativePath != relativePath) {
      throw const FileBrowserException('response_scope_mismatch');
    }
    _requireCurrentDirectoryMutation(cacheKey, mutationEpoch, scope);
    final snapshot = _snapshotFromList(result);
    _cacheDirectory(cacheKey, snapshot);
    return snapshot;
  }

  Future<FileBrowserDirectorySnapshot> loadNextPage(
    FileBrowserDirectorySnapshot current, {
    bool showHidden = false,
  }) async {
    final cursor = current.nextCursor;
    if (cursor == null) return current;
    _requireReady();
    final cacheKey = _directoryCacheKey(
      current.rootId,
      current.relativePath,
      showHidden,
    );
    final paginationKey = '$cacheKey\u0000$cursor';
    final inFlight = _paginationLoads[paginationKey];
    if (inFlight != null) return inFlight;
    final scope = _scopeRevision;
    final mutationEpoch = _beginDirectoryMutation(cacheKey);
    final operation = _loadNextPageRemote(
      current: current,
      showHidden: showHidden,
      cacheKey: cacheKey,
      cursor: cursor,
      scope: scope,
      mutationEpoch: mutationEpoch,
    );
    _paginationLoads[paginationKey] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_paginationLoads[paginationKey], operation)) {
        _paginationLoads.remove(paginationKey);
      }
      _finishDirectoryMutation(cacheKey, mutationEpoch);
    }
  }

  Future<FileBrowserDirectorySnapshot> _loadNextPageRemote({
    required FileBrowserDirectorySnapshot current,
    required bool showHidden,
    required String cacheKey,
    required String cursor,
    required int scope,
    required int mutationEpoch,
  }) async {
    final requestId = _requestIdGenerator();
    final result = await _request<FileBrowserListResultMessage>(
      requestId: requestId,
      requestType: 'file_browser_list_v1',
      message: requestFileBrowserList(
        requestId: requestId,
        rootId: current.rootId,
        relativePath: current.relativePath,
        pageSize: defaultFileBrowserPageSize,
        cursor: cursor,
        showHidden: showHidden,
      ),
      matches: (message) => message is FileBrowserListResultMessage,
    );
    if (result.rootId != current.rootId ||
        result.relativePath != current.relativePath) {
      throw const FileBrowserException('response_scope_mismatch');
    }
    if (result.directoryRevision != current.directoryRevision) {
      throw const FileBrowserException(
        'directory_changed',
        'The directory changed while it was loading',
      );
    }
    _requireCurrentDirectoryMutation(cacheKey, mutationEpoch, scope);
    final merged = _mergeSortedNodes(current.entries, result.entries);
    final truncated =
        current.truncated ||
        merged.length > _fileBrowserVisibleNodeBudget ||
        (merged.length == _fileBrowserVisibleNodeBudget &&
            result.nextCursor != null);
    final visibleEntries = merged.length <= _fileBrowserVisibleNodeBudget
        ? merged
        : merged.take(_fileBrowserVisibleNodeBudget).toList(growable: false);
    final combined = FileBrowserDirectorySnapshot(
      rootId: current.rootId,
      relativePath: current.relativePath,
      directoryRevision: current.directoryRevision,
      entries: List.unmodifiable(visibleEntries),
      nextCursor: truncated ? null : result.nextCursor,
      loadedAt: _clock(),
      truncated: truncated,
    );
    _cacheDirectory(cacheKey, combined);
    return combined;
  }

  Future<List<FileBrowserStatResultItem>> statPins(
    Iterable<FileBrowserPin> pins,
  ) async {
    final list = pins.take(maxFileBrowserStatItems).toList(growable: false);
    if (list.isEmpty) return const [];
    _requireReady();
    final requestId = _requestIdGenerator();
    final result = await _request<FileBrowserStatResultMessage>(
      requestId: requestId,
      requestType: 'file_browser_stat_v1',
      message: requestFileBrowserStat(
        requestId: requestId,
        items: list
            .map(
              (pin) => FileBrowserPathRef(
                rootId: pin.rootId,
                relativePath: pin.relativePath,
              ),
            )
            .toList(growable: false),
      ),
      matches: (message) => message is FileBrowserStatResultMessage,
    );
    return result.items;
  }

  Future<FileBrowserPreview> preview(
    FileBrowserNode node,
    String rootId,
  ) async {
    _requireReady();
    if (!node.canPreview) {
      throw const FileBrowserException('preview_unavailable');
    }
    final requestId = _requestIdGenerator();
    final result = await _request<FileBrowserPreviewResultMessage>(
      requestId: requestId,
      requestType: 'file_browser_preview_v1',
      message: requestFileBrowserPreview(
        requestId: requestId,
        rootId: rootId,
        relativePath: node.relativePath,
        nodeRevision: node.nodeRevision,
      ),
      matches: (message) => message is FileBrowserPreviewResultMessage,
    );
    final previewUri = resolveFileBrowserPreviewUri(
      _bridge.httpBaseUrl,
      result.relativeUrl!,
    );
    return FileBrowserPreview(
      rootId: result.rootId!,
      relativePath: result.relativePath!,
      previewUri: previewUri,
      filename: result.filename!,
      mimeType: result.mimeType!,
      sizeBytes: result.sizeBytes!,
      previewKind: result.previewKind!,
      expiresAt: result.expiresAt!,
    );
  }

  Future<String> download(FileBrowserNode node, String rootId) async {
    _requireReady();
    if (!_downloadAvailable || !node.canDownload) {
      throw const FileBrowserException('download_unavailable');
    }
    if (!hasStableConnectionIdentity) {
      throw const FileBrowserException('stable_bridge_identity_required');
    }
    final requestId = _requestIdGenerator();
    final result = await _request<FileBrowserDownloadResultMessage>(
      requestId: requestId,
      requestType: 'file_browser_download_v1',
      message: requestFileBrowserDownload(
        requestId: requestId,
        rootId: rootId,
        relativePath: node.relativePath,
        nodeRevision: node.nodeRevision,
      ),
      matches: (message) => message is FileBrowserDownloadResultMessage,
    );
    return result.transferId!;
  }

  bool isPinned(String rootId, String relativePath) {
    final identity = _stableLogicalIdentity;
    final bridgeId = _bridgeInstanceId;
    if (identity == null || bridgeId == null) return false;
    return _pins.any(
      (pin) =>
          pin.logicalConnectionIdentity == identity &&
          pin.bridgeInstanceId == bridgeId &&
          pin.rootId == rootId &&
          pin.relativePath == relativePath,
    );
  }

  Future<void> togglePin({
    required FileBrowserRoot root,
    required String relativePath,
    String? label,
  }) async {
    final identity = _stableLogicalIdentity;
    final bridgeId = _bridgeInstanceId;
    if (identity == null || bridgeId == null) {
      throw const FileBrowserException('stable_bridge_identity_required');
    }
    final key =
        '$identity\u0000$bridgeId\u0000${root.rootId}\u0000$relativePath';
    final existing = _pins.indexWhere((pin) => pin.key == key);
    if (existing >= 0) {
      _pins.removeAt(existing);
    } else {
      final displayLabel = label?.trim().isNotEmpty == true
          ? label!.trim()
          : relativePath.isEmpty
          ? root.label
          : relativePath.split('/').last;
      _pins.add(
        FileBrowserPin(
          logicalConnectionIdentity: identity,
          bridgeInstanceId: bridgeId,
          rootId: root.rootId,
          relativePath: relativePath,
          rootLabel: root.label,
          label: displayLabel,
          addedAt: _clock().toUtc(),
        ),
      );
      if (_pins.length > _fileBrowserMaxPins) {
        _pins.sort((a, b) => a.addedAt.compareTo(b.addedAt));
        _pins.removeRange(0, _pins.length - _fileBrowserMaxPins);
      }
    }
    await _savePins();
    _notify();
  }

  Future<void> removePin(FileBrowserPin pin) async {
    final index = _pins.indexWhere((candidate) => candidate.key == pin.key);
    if (index < 0) return;
    _pins.removeAt(index);
    await _savePins();
    _notify();
  }

  void clearDirectoryCache() => _clearDirectoryCache();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_messageSubscription.cancel());
    unawaited(_connectionSubscription.cancel());
    unawaited(_capabilitySubscription.cancel());
    _failPending(const FileBrowserException('service_disposed'));
    super.dispose();
  }

  Future<T> _request<T extends FileBrowserResultMessage>({
    required String requestId,
    required String requestType,
    required ClientMessage message,
    required bool Function(LocalFeatureServerMessage) matches,
  }) async {
    _requireAvailableForRequest();
    if (_pending.containsKey(requestId)) {
      throw const FileBrowserException('duplicate_request_id');
    }
    final completer = Completer<FileBrowserResultMessage>();
    final pending = _PendingFileBrowserRequest(
      requestId: requestId,
      requestType: requestType,
      generation: _connectionGeneration,
      matches: matches,
      completer: completer,
    );
    _pending[requestId] = pending;
    pending.timer = Timer(_requestTimeout, () {
      if (_pending.remove(requestId) == pending) {
        completer.completeError(const FileBrowserException('request_timeout'));
      }
    });
    try {
      _bridge.send(message);
    } catch (_) {
      _pending.remove(requestId);
      pending.timer?.cancel();
      throw const FileBrowserException('bridge_disconnected');
    }
    final result = await completer.future;
    if (result is! T) {
      throw const FileBrowserException('response_type_mismatch');
    }
    return result;
  }

  void _handleMessage(LocalFeatureServerMessage message) {
    if (message is FileBrowserResultMessage) {
      final pending = _pending[message.requestId];
      if (pending == null ||
          pending.generation != _connectionGeneration ||
          !pending.matches(message)) {
        return;
      }
      _pending.remove(message.requestId);
      pending.timer?.cancel();
      if (message.success) {
        pending.completer.complete(message);
      } else {
        pending.completer.completeError(
          FileBrowserException(
            message.errorCode ?? 'file_browser_failed',
            message.error ?? '',
          ),
        );
      }
      return;
    }
    if (message is! LocalFeatureRequestErrorMessage ||
        message.featureId != fileBrowserFeatureId) {
      return;
    }
    _PendingFileBrowserRequest? pending;
    final requestId = message.requestId;
    if (requestId != null) {
      pending = _pending[requestId];
    } else {
      final matches = _pending.values
          .where((item) => item.requestType == message.requestType)
          .toList(growable: false);
      if (matches.length == 1) pending = matches.single;
    }
    if (pending == null || pending.generation != _connectionGeneration) return;
    _pending.remove(pending.requestId);
    pending.timer?.cancel();
    pending.completer.completeError(
      FileBrowserException(
        message.errorCode ?? 'unsupported_message',
        message.message,
      ),
    );
  }

  void _handleConnectionState(BridgeConnectionState state) {
    final nextIdentity = _stableLogicalIdentity;
    if (state != BridgeConnectionState.connected ||
        nextIdentity != _lastConnectionIdentity) {
      _connectionGeneration++;
      _failPending(const FileBrowserException('bridge_disconnected'));
      _resetBridgeScope();
    }
    _lastConnectionIdentity = nextIdentity;
    _lastCapabilitySupported = supportedByBridge;
    _setAvailability(
      state != BridgeConnectionState.connected
          ? FileBrowserAvailability.disconnected
          : supportedByBridge
          ? FileBrowserAvailability.loading
          : FileBrowserAvailability.unsupported,
    );
  }

  void _handleCapabilityChange() {
    final nextIdentity = _stableLogicalIdentity;
    final wasSupported = _lastCapabilitySupported;
    final isSupported = supportedByBridge;
    if (nextIdentity != _lastConnectionIdentity) {
      _connectionGeneration++;
      _failPending(const FileBrowserException('bridge_identity_changed'));
      _resetBridgeScope();
      _lastConnectionIdentity = nextIdentity;
    }
    if (!_bridge.isConnected) {
      _setAvailability(FileBrowserAvailability.disconnected);
    } else if (!isSupported) {
      if (wasSupported || _bridgeInstanceId != null || _roots.isNotEmpty) {
        _connectionGeneration++;
        _failPending(const FileBrowserException('bridge_unsupported'));
        _resetBridgeScope();
      }
      _setAvailability(FileBrowserAvailability.unsupported);
    } else {
      _setAvailability(
        _roots.isEmpty
            ? FileBrowserAvailability.loading
            : FileBrowserAvailability.ready,
      );
    }
    _lastCapabilitySupported = isSupported;
  }

  void _requireReady() {
    _requireAvailableForRequest();
    if (_bridgeInstanceId == null || _rootSetRevision == null) {
      throw const FileBrowserException('roots_not_loaded');
    }
  }

  void _requireAvailableForRequest() {
    if (!_bridge.isConnected) {
      throw const FileBrowserException('bridge_disconnected');
    }
    if (!supportedByBridge) {
      throw const FileBrowserException('bridge_unsupported');
    }
  }

  FileBrowserDirectorySnapshot _snapshotFromList(
    FileBrowserListResultMessage result,
  ) => FileBrowserDirectorySnapshot(
    rootId: result.rootId!,
    relativePath: result.relativePath!,
    directoryRevision: result.directoryRevision!,
    entries: List.unmodifiable(_sortNodes(result.entries)),
    nextCursor: result.nextCursor,
    loadedAt: _clock(),
  );

  List<FileBrowserNode> _sortNodes(Iterable<FileBrowserNode> nodes) {
    final list = nodes.toList(growable: false);
    list.sort(_compareNodes);
    return list;
  }

  int _compareNodes(FileBrowserNode left, FileBrowserNode right) {
    final directoryOrder = (left.isDirectory ? 0 : 1).compareTo(
      right.isDirectory ? 0 : 1,
    );
    if (directoryOrder != 0) return directoryOrder;
    final folded = left.name.toLowerCase().compareTo(right.name.toLowerCase());
    return folded != 0 ? folded : left.name.compareTo(right.name);
  }

  List<FileBrowserNode> _mergeSortedNodes(
    List<FileBrowserNode> current,
    List<FileBrowserNode> incoming,
  ) {
    if (incoming.isEmpty) return List<FileBrowserNode>.from(current);
    final incomingByPath = <String, FileBrowserNode>{
      for (final node in incoming) node.relativePath: node,
    };
    final retained = current
        .where((node) => !incomingByPath.containsKey(node.relativePath))
        .toList(growable: false);
    final additions = _sortNodes(incomingByPath.values);
    final merged = <FileBrowserNode>[];
    var left = 0;
    var right = 0;
    while (left < retained.length && right < additions.length) {
      if (_compareNodes(retained[left], additions[right]) <= 0) {
        merged.add(retained[left++]);
      } else {
        merged.add(additions[right++]);
      }
    }
    if (left < retained.length) merged.addAll(retained.skip(left));
    if (right < additions.length) merged.addAll(additions.skip(right));
    return merged;
  }

  void _cacheDirectory(String key, FileBrowserDirectorySnapshot snapshot) {
    _pruneExpiredDirectoryCache();
    _removeCachedDirectory(key);
    // Continuation cursors are short-lived, single-use server capabilities.
    // Persist only complete snapshots so returning to a cached directory never
    // tries to resume with an expired or server-evicted cursor.
    if (snapshot.hasMore ||
        snapshot.entries.length > _fileBrowserDirectoryCacheNodeBudget) {
      return;
    }
    _directoryCache[key] = snapshot;
    _directoryCacheNodeCount += snapshot.entries.length;
    while (_directoryCache.length > _fileBrowserDirectoryCacheLimit ||
        _directoryCacheNodeCount > _fileBrowserDirectoryCacheNodeBudget) {
      _removeCachedDirectory(_directoryCache.keys.first);
    }
  }

  FileBrowserDirectorySnapshot? _freshCachedDirectory(String key) {
    _pruneExpiredDirectoryCache();
    final cached = _directoryCache.remove(key);
    if (cached == null) return null;
    _directoryCache[key] = cached;
    return cached;
  }

  void _pruneExpiredDirectoryCache() {
    final now = _clock();
    final expired = _directoryCache.entries
        .where((entry) {
          final age = now.difference(entry.value.loadedAt);
          return age.isNegative || age >= _fileBrowserDirectoryCacheTtl;
        })
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in expired) {
      _removeCachedDirectory(key);
    }
  }

  void _removeCachedDirectory(String key) {
    final removed = _directoryCache.remove(key);
    if (removed == null) return;
    _directoryCacheNodeCount -= removed.entries.length;
  }

  void _clearDirectoryCache() {
    _directoryCache.clear();
    _directoryCacheNodeCount = 0;
  }

  void _clearDirectoryState() {
    _clearDirectoryCache();
    _directoryLoads.clear();
    _paginationLoads.clear();
    _directoryMutationEpochs.clear();
  }

  void _resetBridgeScope() {
    _clearDirectoryState();
    _rootsRefreshInFlight = null;
    _roots = const [];
    _bridgeInstanceId = null;
    _rootSetRevision = null;
    _previewMaxBytes = maxFileBrowserPreviewBytes;
    _downloadMaxBytes = maxFileBrowserDownloadBytes;
    _downloadAvailable = false;
    _scopeRevision++;
    _notify();
  }

  int _beginDirectoryMutation(String key) {
    final epoch = ++_nextDirectoryMutationEpoch;
    _directoryMutationEpochs[key] = epoch;
    return epoch;
  }

  void _finishDirectoryMutation(String key, int epoch) {
    if (_directoryMutationEpochs[key] == epoch) {
      _directoryMutationEpochs.remove(key);
    }
  }

  void _requireCurrentDirectoryMutation(String key, int epoch, int scope) {
    if (scope != _scopeRevision) {
      throw const FileBrowserException('bridge_scope_changed');
    }
    if (_directoryMutationEpochs[key] != epoch) {
      throw const FileBrowserException('request_superseded');
    }
  }

  String _directoryCacheKey(
    String rootId,
    String relativePath,
    bool showHidden,
  ) =>
      '${_stableLogicalIdentity ?? ''}\u0000${_bridgeInstanceId ?? ''}\u0000$rootId\u0000$relativePath\u0000$showHidden';

  String? get _stableLogicalIdentity {
    final value = _bridge.logicalConnectionIdentity?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  void _failPending(FileBrowserException error) {
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final item in pending) {
      item.timer?.cancel();
      if (!item.completer.isCompleted) item.completer.completeError(error);
    }
  }

  Future<void> _savePins() async {
    await _preferences.setString(
      _fileBrowserPinsPreference,
      jsonEncode(_pins.map((pin) => pin.toJson()).toList(growable: false)),
    );
  }

  void _setAvailability(FileBrowserAvailability value) {
    if (_availability == value) return;
    _availability = value;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

class _PendingFileBrowserRequest {
  final String requestId;
  final String requestType;
  final int generation;
  final bool Function(LocalFeatureServerMessage) matches;
  final Completer<FileBrowserResultMessage> completer;
  Timer? timer;

  _PendingFileBrowserRequest({
    required this.requestId,
    required this.requestType,
    required this.generation,
    required this.matches,
    required this.completer,
  });
}

extension FileBrowserNodePresentation on FileBrowserNode {
  bool get isDirectory =>
      kind == FileBrowserNodeKind.directory ||
      (kind == FileBrowserNodeKind.symlink &&
          targetKind == FileBrowserNodeKind.directory &&
          canOpen);
}

@visibleForTesting
Uri resolveFileBrowserPreviewUri(String? httpBaseUrl, String relativeUrl) {
  final base = Uri.tryParse(httpBaseUrl ?? '');
  final relative = Uri.tryParse(relativeUrl);
  if (base == null ||
      !base.hasScheme ||
      base.host.isEmpty ||
      (base.scheme != 'http' && base.scheme != 'https') ||
      relative == null ||
      relative.hasScheme ||
      relative.hasAuthority ||
      !relative.path.startsWith('/artifacts/')) {
    throw const FileBrowserException('invalid_preview_url');
  }
  final resolved = base.resolveUri(relative);
  if (resolved.scheme != base.scheme ||
      resolved.host != base.host ||
      resolved.port != base.port) {
    throw const FileBrowserException('invalid_preview_url');
  }
  return resolved;
}

List<FileBrowserPin> _readPins(SharedPreferences preferences) {
  final encoded = preferences.getString(_fileBrowserPinsPreference);
  if (encoded == null || encoded.length > 256 * 1024) return <FileBrowserPin>[];
  try {
    final decoded = jsonDecode(encoded);
    if (decoded is! List) return <FileBrowserPin>[];
    final unique = <String, FileBrowserPin>{};
    for (final value in decoded.take(_fileBrowserMaxPins)) {
      final pin = FileBrowserPin.tryParse(value);
      if (pin != null) unique[pin.key] = pin;
    }
    return unique.values.toList(growable: true);
  } catch (_) {
    return <FileBrowserPin>[];
  }
}

String? _boundedText(Object? value, int maxLength) {
  if (value is! String ||
      value.isEmpty ||
      value.trim() != value ||
      value.length > maxLength ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    return null;
  }
  return value;
}

String? _validStoredRelativePath(Object? value) {
  if (value is! String ||
      value.length > 4096 ||
      value.contains('\u0000') ||
      value.contains('\\') ||
      value.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value)) {
    return null;
  }
  if (value.isEmpty) return value;
  return value
          .split('/')
          .every(
            (segment) =>
                segment.isNotEmpty && segment != '.' && segment != '..',
          )
      ? value
      : null;
}

String _newRequestId() {
  final random = Random.secure().nextInt(0x7fffffff).toRadixString(16);
  return 'fb_${DateTime.now().microsecondsSinceEpoch}_$random';
}
