import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../services/bridge_service.dart';
import '../../../models/messages.dart';
import 'explore_state.dart';

abstract final class ExploreFailureCode {
  static const loadFailed = 'load_failed';
  static const bridgeDisconnected = 'bridge_disconnected';
  static const requestTimedOut = 'request_timed_out';
  static const pathNotAllowed = 'path_not_allowed';
}

class ExploreCubit extends Cubit<ExploreState> {
  final BridgeService bridge;
  final Duration requestTimeout;
  StreamSubscription<FileListMessage>? _fileListSub;
  StreamSubscription<ServerMessage>? _messageSub;
  StreamSubscription<BridgeConnectionState>? _connectionSub;
  Timer? _timeoutTimer;
  List<String> _recentPeekedFiles;
  String? _pendingRequestId;
  bool _pendingUsesLegacyLane = false;
  bool _retryOnReconnect = false;

  static int _requestCounter = 0;
  static final Map<BridgeService, _LegacyExploreLane> _legacyLanes = {};

  ExploreCubit({
    required this.bridge,
    required String projectPath,
    List<String> initialFiles = const [],
    String initialPath = '',
    List<String> recentPeekedFiles = const [],
    this.requestTimeout = const Duration(seconds: 12),
  }) : _recentPeekedFiles = recentPeekedFiles.take(10).toList(),
       super(ExploreState(projectPath: projectPath, currentPath: initialPath)) {
    _fileListSub = bridge.fileListMessages.listen(_onFileListUpdated);
    _messageSub = bridge.messages.listen(_onBridgeMessage);
    _connectionSub = bridge.connectionStatus.listen(_onConnectionState);
    if (initialFiles.isNotEmpty) {
      _applyFiles(initialFiles, truncated: false, totalFiles: null);
    }
    _requestFiles(showLoading: initialFiles.isEmpty);
  }

  void _onFileListUpdated(FileListMessage message) {
    if (_pendingUsesLegacyLane) return;
    if (message.reset || !_matchesPendingResponse(message)) return;
    if (message.error != null) {
      _clearPendingLocal();
      emit(
        state.copyWith(
          status: ExploreStatus.error,
          error: _failureCodeFor(message),
          fileListTruncated: false,
          totalFiles: null,
        ),
      );
      return;
    }
    _clearPendingLocal();
    _applyFiles(
      message.files,
      truncated: message.truncated,
      totalFiles: message.totalFiles,
    );
  }

  bool _matchesPendingResponse(FileListMessage message) {
    final pendingRequestId = _pendingRequestId;
    if (pendingRequestId == null) return false;
    if (message.projectPath != null &&
        message.projectPath != state.projectPath) {
      return false;
    }
    if (message.requestId != null) {
      return message.requestId == pendingRequestId;
    }
    return false;
  }

  void _onBridgeMessage(ServerMessage message) {
    if (_pendingUsesLegacyLane) return;
    if (message is! ErrorMessage ||
        message.errorCode != 'path_not_allowed' ||
        _pendingRequestId == null) {
      return;
    }
    _clearPendingLocal();
    emit(
      state.copyWith(
        status: ExploreStatus.error,
        error: ExploreFailureCode.pathNotAllowed,
      ),
    );
  }

  void _onConnectionState(BridgeConnectionState status) {
    if (status == BridgeConnectionState.disconnected) {
      if (_pendingRequestId == null) return;
      _retryOnReconnect = true;
      _finishRequest();
      if (!isClosed) {
        emit(
          state.copyWith(
            status: ExploreStatus.error,
            error: ExploreFailureCode.bridgeDisconnected,
          ),
        );
      }
      return;
    }
    if (status == BridgeConnectionState.connected &&
        _retryOnReconnect &&
        !isClosed) {
      _retryOnReconnect = false;
      _requestFiles(showLoading: state.allFiles.isEmpty);
    }
  }

  void retry() => _requestFiles(showLoading: state.allFiles.isEmpty);

  void _requestFiles({required bool showLoading}) {
    _finishRequest();
    final requestId = 'explore-${++ExploreCubit._requestCounter}';
    _pendingRequestId = requestId;
    _pendingUsesLegacyLane = !bridge.supportsFileListRequestCorrelation;
    if (showLoading) {
      emit(state.copyWith(status: ExploreStatus.loading, error: null));
    } else if (state.error != null) {
      emit(state.copyWith(error: null));
    }
    if (_pendingUsesLegacyLane) {
      _legacyLaneFor(bridge).enqueue(
        owner: this,
        requestId: requestId,
        projectPath: state.projectPath,
        timeout: requestTimeout,
      );
      return;
    }
    _sendCorrelatedRequest(requestId);
  }

  void _sendCorrelatedRequest(String requestId) {
    _armTimeout(requestId);
    try {
      bridge.send(
        ClientMessage.listFiles(state.projectPath, requestId: requestId),
      );
    } catch (error) {
      _clearPendingLocal();
      if (!isClosed) {
        emit(
          state.copyWith(
            status: ExploreStatus.error,
            error: ExploreFailureCode.loadFailed,
          ),
        );
      }
    }
  }

  void _armTimeout(String requestId) {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(requestTimeout, () {
      if (_pendingRequestId != requestId || isClosed) return;
      final usedLegacyLane = _pendingUsesLegacyLane;
      _clearPendingLocal();
      if (usedLegacyLane) {
        _legacyLanes[bridge]?.cancel(this, requestId);
      }
      emit(
        state.copyWith(
          status: ExploreStatus.error,
          error: ExploreFailureCode.requestTimedOut,
        ),
      );
    });
  }

  void _sendLegacyRequest(String requestId) {
    if (_pendingRequestId != requestId || !_pendingUsesLegacyLane || isClosed) {
      _legacyLanes[bridge]?.cancel(this, requestId);
      return;
    }
    _armTimeout(requestId);
    try {
      bridge.send(
        ClientMessage.listFiles(state.projectPath, requestId: requestId),
      );
    } catch (error) {
      _legacyLanes[bridge]?.sendFailed(this, requestId);
      _clearPendingLocal();
      if (!isClosed) {
        emit(
          state.copyWith(
            status: ExploreStatus.error,
            error: ExploreFailureCode.loadFailed,
          ),
        );
      }
    }
  }

  void _acceptLegacyResponse(String requestId, FileListMessage message) {
    if (_pendingRequestId != requestId || !_pendingUsesLegacyLane || isClosed) {
      return;
    }
    _clearPendingLocal();
    if (message.error != null) {
      emit(
        state.copyWith(
          status: ExploreStatus.error,
          error: _failureCodeFor(message),
          fileListTruncated: false,
          totalFiles: null,
        ),
      );
      return;
    }
    _applyFiles(
      message.files,
      truncated: message.truncated,
      totalFiles: message.totalFiles,
    );
  }

  void _acceptLegacyPathError(String requestId, ErrorMessage message) {
    if (_pendingRequestId != requestId || !_pendingUsesLegacyLane || isClosed) {
      return;
    }
    _clearPendingLocal();
    emit(
      state.copyWith(
        status: ExploreStatus.error,
        error: ExploreFailureCode.pathNotAllowed,
      ),
    );
  }

  void _legacyConnectionReset(String requestId) {
    if (_pendingRequestId != requestId || !_pendingUsesLegacyLane || isClosed) {
      return;
    }
    _retryOnReconnect = true;
    _clearPendingLocal();
    emit(
      state.copyWith(
        status: ExploreStatus.error,
        error: ExploreFailureCode.bridgeDisconnected,
      ),
    );
  }

  static String _failureCodeFor(FileListMessage message) =>
      message.errorCode == ExploreFailureCode.pathNotAllowed
      ? ExploreFailureCode.pathNotAllowed
      : ExploreFailureCode.loadFailed;

  void _finishRequest() {
    final requestId = _pendingRequestId;
    if (requestId == null) return;
    final usedLegacyLane = _pendingUsesLegacyLane;
    _clearPendingLocal();
    if (usedLegacyLane) {
      _legacyLanes[bridge]?.cancel(this, requestId);
    }
  }

  void _clearPendingLocal() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _pendingRequestId = null;
    _pendingUsesLegacyLane = false;
  }

  static _LegacyExploreLane _legacyLaneFor(BridgeService bridge) =>
      _legacyLanes.putIfAbsent(
        bridge,
        () => _LegacyExploreLane(
          bridge,
          onIdle: (lane) {
            if (identical(_legacyLanes[bridge], lane)) {
              _legacyLanes.remove(bridge);
            }
          },
        ),
      );

  @visibleForTesting
  static bool debugHasLegacyLaneForBridge(BridgeService bridge) =>
      _legacyLanes.containsKey(bridge);

  void _applyFiles(
    List<String> files, {
    required bool truncated,
    required int? totalFiles,
  }) {
    final normalizedPath = normalizeExplorePath(files, state.currentPath);
    final entries = buildExploreEntries(files, currentPath: normalizedPath);
    emit(
      state.copyWith(
        currentPath: normalizedPath,
        allFiles: files,
        visibleEntries: entries,
        fileListTruncated: truncated,
        totalFiles: totalFiles,
        status: switch ((files.isEmpty, entries.isEmpty)) {
          (true, _) => ExploreStatus.empty,
          (_, false) => ExploreStatus.ready,
          (_, true) => ExploreStatus.empty,
        },
        error: null,
      ),
    );
  }

  void openDirectory(String relativePath) {
    final normalizedPath = normalizeExplorePath(state.allFiles, relativePath);
    final entries = buildExploreEntries(
      state.allFiles,
      currentPath: normalizedPath,
    );
    emit(
      state.copyWith(
        currentPath: normalizedPath,
        visibleEntries: entries,
        status: entries.isEmpty ? ExploreStatus.empty : ExploreStatus.ready,
      ),
    );
  }

  bool goUp() {
    if (state.currentPath.isEmpty) return false;
    final next = parentDirectoryOf(state.currentPath);
    final entries = buildExploreEntries(state.allFiles, currentPath: next);
    emit(
      state.copyWith(
        currentPath: next,
        visibleEntries: entries,
        status: entries.isEmpty ? ExploreStatus.empty : ExploreStatus.ready,
      ),
    );
    return true;
  }

  List<String> get breadcrumbs => breadcrumbsForPath(state.currentPath);
  List<String> get recentPeekedFiles => List.unmodifiable(_recentPeekedFiles);
  List<String> get allFiles => List.unmodifiable(state.allFiles);

  void recordPeekedFile(String path) {
    _recentPeekedFiles = updateRecentFileHistory(_recentPeekedFiles, path);
  }

  void jumpToFile(String filePath) {
    openDirectory(parentDirectoryOf(filePath));
  }

  ExploreScreenResult buildResult() => ExploreScreenResult(
    currentPath: state.currentPath,
    recentPeekedFiles: recentPeekedFiles,
  );

  @override
  Future<void> close() async {
    _finishRequest();
    await _fileListSub?.cancel();
    await _messageSub?.cancel();
    await _connectionSub?.cancel();
    return super.close();
  }
}

class _LegacyExploreRequest {
  const _LegacyExploreRequest({
    required this.owner,
    required this.requestId,
    required this.projectPath,
    required this.timeout,
  });

  final ExploreCubit owner;
  final String requestId;
  final String projectPath;
  final Duration timeout;
}

class _LegacyExploreLane {
  _LegacyExploreLane(this.bridge, {required this.onIdle}) {
    _fileListSub = bridge.fileListMessages.listen(
      _onFileList,
      onDone: _disposeFromClosedBridge,
    );
    _messageSub = bridge.messages.listen(
      _onBridgeMessage,
      onDone: _disposeFromClosedBridge,
    );
  }

  final BridgeService bridge;
  final void Function(_LegacyExploreLane lane) onIdle;
  final List<_LegacyExploreRequest> _queue = [];
  StreamSubscription<FileListMessage>? _fileListSub;
  StreamSubscription<ServerMessage>? _messageSub;
  _LegacyExploreRequest? _active;
  _LegacyExploreRequest? _quarantined;
  Timer? _quarantineTimer;
  bool _disposed = false;

  void enqueue({
    required ExploreCubit owner,
    required String requestId,
    required String projectPath,
    required Duration timeout,
  }) {
    if (_disposed) return;
    _queue.add(
      _LegacyExploreRequest(
        owner: owner,
        requestId: requestId,
        projectPath: projectPath,
        timeout: timeout,
      ),
    );
    _pump();
  }

  void cancel(ExploreCubit owner, String requestId) {
    if (_disposed) return;
    final active = _active;
    if (active?.owner == owner && active?.requestId == requestId) {
      _active = null;
      _beginQuarantine(active!);
      return;
    }
    _queue.removeWhere(
      (request) => request.owner == owner && request.requestId == requestId,
    );
    _disposeIfIdle();
  }

  void sendFailed(ExploreCubit owner, String requestId) {
    if (_disposed) return;
    final active = _active;
    if (active?.owner != owner || active?.requestId != requestId) return;
    _active = null;
    _pump();
  }

  void _pump() {
    if (_disposed || _active != null || _quarantined != null) return;
    while (_queue.isNotEmpty) {
      final request = _queue.removeAt(0);
      if (request.owner.isClosed ||
          request.owner._pendingRequestId != request.requestId ||
          !request.owner._pendingUsesLegacyLane) {
        continue;
      }
      _active = request;
      request.owner._sendLegacyRequest(request.requestId);
      return;
    }
    _disposeIfIdle();
  }

  void _onFileList(FileListMessage message) {
    if (_disposed) return;
    if (message.reset) {
      _reset();
      return;
    }
    final quarantined = _quarantined;
    if (quarantined != null) {
      if (_matches(quarantined, message)) {
        _clearQuarantine();
        _pump();
      }
      return;
    }
    final active = _active;
    if (active == null || !_matches(active, message)) return;
    _active = null;
    active.owner._acceptLegacyResponse(active.requestId, message);
    _pump();
  }

  void _onBridgeMessage(ServerMessage message) {
    if (_disposed ||
        message is! ErrorMessage ||
        message.errorCode != 'path_not_allowed') {
      return;
    }
    final quarantined = _quarantined;
    if (quarantined != null) {
      _clearQuarantine();
      _pump();
      return;
    }
    final active = _active;
    if (active == null) return;
    _active = null;
    active.owner._acceptLegacyPathError(active.requestId, message);
    _pump();
  }

  bool _matches(_LegacyExploreRequest request, FileListMessage message) {
    final responseRequestId = message.requestId;
    if (responseRequestId != null) {
      return responseRequestId == request.requestId;
    }
    final responseProjectPath = message.projectPath;
    return responseProjectPath == null ||
        responseProjectPath == request.projectPath;
  }

  void _beginQuarantine(_LegacyExploreRequest request) {
    _quarantined = request;
    _quarantineTimer?.cancel();
    _quarantineTimer = Timer(request.timeout, () {
      if (_disposed || _quarantined?.requestId != request.requestId) return;
      _clearQuarantine();
      _pump();
    });
  }

  void _clearQuarantine() {
    _quarantineTimer?.cancel();
    _quarantineTimer = null;
    _quarantined = null;
  }

  void _reset() {
    final requests = <_LegacyExploreRequest>[?_active, ..._queue];
    _active = null;
    _queue.clear();
    _clearQuarantine();
    for (final request in requests) {
      request.owner._legacyConnectionReset(request.requestId);
    }
    _disposeIfIdle();
  }

  void _disposeIfIdle() {
    if (_disposed ||
        _active != null ||
        _quarantined != null ||
        _queue.isNotEmpty) {
      return;
    }
    scheduleMicrotask(() {
      if (_disposed ||
          _active != null ||
          _quarantined != null ||
          _queue.isNotEmpty) {
        return;
      }
      _dispose();
    });
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    _active = null;
    _queue.clear();
    _clearQuarantine();

    final fileListSub = _fileListSub;
    _fileListSub = null;
    if (fileListSub != null) {
      unawaited(fileListSub.cancel());
    }
    final messageSub = _messageSub;
    _messageSub = null;
    if (messageSub != null) {
      unawaited(messageSub.cancel());
    }
    onIdle(this);
  }

  void _disposeFromClosedBridge() {
    if (_disposed) return;
    _disposed = true;
    _active = null;
    _queue.clear();
    _clearQuarantine();
    _fileListSub = null;
    _messageSub = null;
    onIdle(this);
  }
}

List<ExploreEntry> buildExploreEntries(
  List<String> files, {
  required String currentPath,
}) {
  final prefix = currentPath.isEmpty ? '' : '$currentPath/';
  final directories = <String>{};
  final entries = <ExploreEntry>[];

  for (final file in files) {
    if (!file.startsWith(prefix)) continue;
    final remainder = file.substring(prefix.length);
    if (remainder.isEmpty) continue;

    final slashIndex = remainder.indexOf('/');
    if (slashIndex == -1) {
      entries.add(
        ExploreEntry(name: remainder, relativePath: file, isDirectory: false),
      );
      continue;
    }

    final dirName = remainder.substring(0, slashIndex);
    if (directories.add(dirName)) {
      final relativePath = currentPath.isEmpty
          ? dirName
          : '$currentPath/$dirName';
      entries.add(
        ExploreEntry(
          name: dirName,
          relativePath: relativePath,
          isDirectory: true,
        ),
      );
    }
  }

  entries.sort((a, b) {
    if (a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  return entries;
}

String parentDirectoryOf(String currentPath) {
  final lastSlash = currentPath.lastIndexOf('/');
  if (lastSlash == -1) return '';
  return currentPath.substring(0, lastSlash);
}

String normalizeExplorePath(List<String> files, String currentPath) {
  var candidate = currentPath.trim();
  while (candidate.isNotEmpty) {
    final prefix = '$candidate/';
    if (files.any((file) => file.startsWith(prefix))) {
      return candidate;
    }
    candidate = parentDirectoryOf(candidate);
  }
  return '';
}

List<String> breadcrumbsForPath(String currentPath) {
  if (currentPath.isEmpty) return const [];
  final segments = currentPath.split('/');
  final breadcrumbs = <String>[];
  for (var i = 0; i < segments.length; i++) {
    breadcrumbs.add(segments.take(i + 1).join('/'));
  }
  return breadcrumbs;
}

List<String> updateRecentFileHistory(
  List<String> current,
  String path, {
  int limit = 10,
}) {
  final normalized = path.trim();
  if (normalized.isEmpty) return current;
  final next = [normalized, ...current.where((file) => file != normalized)];
  return next.take(limit).toList();
}
