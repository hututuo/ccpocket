import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../services/bridge_service.dart';
import '../../../models/messages.dart';
import 'explore_state.dart';

class ExploreCubit extends Cubit<ExploreState> {
  final BridgeService bridge;
  final Duration requestTimeout;
  StreamSubscription<FileListMessage>? _fileListSub;
  StreamSubscription<ServerMessage>? _messageSub;
  Timer? _timeoutTimer;
  List<String> _recentPeekedFiles;
  String? _pendingRequestId;

  static int _requestCounter = 0;
  static final Map<BridgeService, Set<String>> _legacyPendingRequests = {};

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
    if (initialFiles.isNotEmpty) {
      _applyFiles(initialFiles, truncated: false, totalFiles: null);
    }
    _requestFiles(showLoading: initialFiles.isEmpty);
  }

  void _onFileListUpdated(FileListMessage message) {
    if (message.reset || !_matchesPendingResponse(message)) return;
    if (message.error != null) {
      _finishRequest();
      emit(
        state.copyWith(
          status: ExploreStatus.error,
          error: message.error,
          fileListTruncated: false,
          totalFiles: null,
        ),
      );
      return;
    }
    _finishRequest();
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
    final legacyPending = _legacyPendingRequests[bridge];
    return legacyPending?.length == 1 &&
        legacyPending!.contains(pendingRequestId);
  }

  void _onBridgeMessage(ServerMessage message) {
    if (message is! ErrorMessage ||
        message.errorCode != 'path_not_allowed' ||
        _pendingRequestId == null) {
      return;
    }
    // New Bridges return a correlated file_list failure. This fallback is
    // only for old Bridges and is safe when this is the sole pending Explorer
    // on the connection; otherwise the timeout avoids blaming the wrong pane.
    final legacyPending = _legacyPendingRequests[bridge];
    if (legacyPending?.length != 1 ||
        !legacyPending!.contains(_pendingRequestId)) {
      return;
    }
    _finishRequest();
    emit(state.copyWith(status: ExploreStatus.error, error: message.message));
  }

  void retry() => _requestFiles(showLoading: state.allFiles.isEmpty);

  void _requestFiles({required bool showLoading}) {
    _finishRequest();
    final requestId = 'explore-${++ExploreCubit._requestCounter}';
    _pendingRequestId = requestId;
    (_legacyPendingRequests[bridge] ??= {}).add(requestId);
    if (showLoading) {
      emit(state.copyWith(status: ExploreStatus.loading, error: null));
    } else if (state.error != null) {
      emit(state.copyWith(error: null));
    }
    _timeoutTimer = Timer(requestTimeout, () {
      if (_pendingRequestId != requestId || isClosed) return;
      _finishRequest();
      emit(
        state.copyWith(
          status: ExploreStatus.error,
          error:
              'The file list request timed out. Check the Bridge connection.',
        ),
      );
    });
    try {
      bridge.send(
        ClientMessage.listFiles(state.projectPath, requestId: requestId),
      );
    } catch (error) {
      _finishRequest();
      emit(
        state.copyWith(
          status: ExploreStatus.error,
          error: 'Failed to request files: $error',
        ),
      );
    }
  }

  void _finishRequest() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    final requestId = _pendingRequestId;
    _pendingRequestId = null;
    if (requestId == null) return;
    final pending = _legacyPendingRequests[bridge];
    pending?.remove(requestId);
    if (pending?.isEmpty == true) {
      _legacyPendingRequests.remove(bridge);
    }
  }

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
  Future<void> close() {
    _finishRequest();
    _fileListSub?.cancel();
    _messageSub?.cancel();
    return super.close();
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
