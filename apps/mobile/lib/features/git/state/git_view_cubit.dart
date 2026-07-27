import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../models/messages.dart';
import '../../../services/bridge_service.dart';
import '../../../utils/diff_parser.dart';
import 'git_view_state.dart';

typedef _LegacyDiffImageKey = ({BridgeService bridge, String filePath});

/// Manages diff viewer state: file parsing, collapse/expand, and git actions.
///
/// Two modes controlled by constructor parameters:
/// - [initialDiff] provided → parse immediately (individual tool result).
/// - [projectPath] provided → request `git diff` from Bridge and subscribe.
class GitViewCubit extends Cubit<GitViewState> {
  static const _legacyDiffLane = 'git-diff-legacy';

  final BridgeService _bridge;
  StreamSubscription<DiffResultMessage>? _diffSub;
  StreamSubscription<DiffImageResultMessage>? _diffImageSub;
  StreamSubscription<GitStageResultMessage>? _stageSub;
  StreamSubscription<GitUnstageResultMessage>? _unstageSub;
  StreamSubscription<GitUnstageHunksResultMessage>? _unstageHunksSub;
  StreamSubscription<GitFetchResultMessage>? _fetchSub;
  StreamSubscription<GitPullResultMessage>? _pullSub;
  StreamSubscription<GitPushResultMessage>? _pushResultSub;
  StreamSubscription<GitCommitResultMessage>? _commitResultSub;
  StreamSubscription<GitRemoteStatusResultMessage>? _remoteStatusSub;
  StreamSubscription<GitRevertFileResultMessage>? _revertSub;
  StreamSubscription<GitRevertHunksResultMessage>? _revertHunksSub;
  StreamSubscription<GitBranchesResultMessage>? _branchesSub;
  StreamSubscription<GitCheckoutBranchResultMessage>? _checkoutSub;
  StreamSubscription<BridgeConnectionState>? _connectionSub;
  final String? _projectPath;
  final String? _sessionId;
  final void Function({bool forceRemote})? _onStatusRefreshRequested;
  final Duration operationTimeout;
  Timer? _diffTimeout;
  Timer? _stagingTimeout;
  Timer? _fetchTimeout;
  Timer? _pullTimeout;
  Timer? _pushTimeout;
  Timer? _legacyDiffAcquireTimer;
  bool? _queuedLegacyDiffStaged;
  String? _pendingMutation;

  GitViewCubit({
    required BridgeService bridge,
    String? initialDiff,
    String? projectPath,
    String? worktreePath,
    String? sessionId,
    void Function({bool forceRemote})? onStatusRefreshRequested,
    this.operationTimeout = const Duration(seconds: 15),
  }) : _bridge = bridge,
       _projectPath = projectPath,
       _sessionId = sessionId,
       _onStatusRefreshRequested = onStatusRefreshRequested,
       super(
         _initialState(
           initialDiff,
           projectPath,
           isWorktree: worktreePath != null,
         ),
       ) {
    if (projectPath != null) {
      _requestDiff(projectPath);
      _diffImageSub = _bridge.diffImageResults.listen(_onDiffImageResult);
      _stageSub = _bridge.gitStageResults.listen(_onStageResult);
      _unstageSub = _bridge.gitUnstageResults.listen(_onUnstageResult);
      _unstageHunksSub = _bridge.gitUnstageHunksResults.listen(
        _onUnstageHunksResult,
      );
      _fetchSub = _bridge.gitFetchResults.listen(_onFetchResult);
      _pullSub = _bridge.gitPullResults.listen(_onPullResult);
      _pushResultSub = _bridge.gitPushResults.listen(_onPushResult);
      _commitResultSub = _bridge.gitCommitResults.listen(_onCommitResult);
      _revertSub = _bridge.gitRevertFileResults.listen(_onRevertResult);
      _revertHunksSub = _bridge.gitRevertHunksResults.listen(
        _onRevertHunksResult,
      );
      _remoteStatusSub = _bridge.gitRemoteStatusResults.listen(_onRemoteStatus);
      _branchesSub = _bridge.gitBranchesResults.listen(_onBranchesResult);
      _checkoutSub = _bridge.gitCheckoutBranchResults.listen(_onCheckoutResult);
      _connectionSub = _bridge.connectionStatus.listen(_onConnectionState);
      // Fetch on init to get fresh remote state + current branch
      _fetchAndUpdateStatus();
      _bridge.send(ClientMessage.gitBranches(projectPath));
    }
  }

  static GitViewState _initialState(
    String? initialDiff,
    String? projectPath, {
    bool isWorktree = false,
  }) {
    if (initialDiff != null) {
      return GitViewState(files: parseDiff(initialDiff));
    }
    if (projectPath != null) {
      return GitViewState(loading: true, isWorktree: isWorktree);
    }
    return const GitViewState();
  }

  /// Monotonic id source shared by all cubits so every get_diff in the app
  /// gets a distinct requestId (`diff_result` is a global broadcast stream).
  static int _diffRequestCounter = 0;
  static int _diffImageRequestCounter = 0;

  /// Old Bridges do not echo image request identity. Accept such a response
  /// only when one cubit on that exact Bridge is waiting for the relative path;
  /// otherwise two projects containing e.g. assets/logo.png are ambiguous.
  static final Map<_LegacyDiffImageKey, Set<String>>
      _legacyPendingDiffImageRequests = {};
  final Map<String, String> _pendingDiffImageRequestIds = {};

  /// requestId of this cubit's latest get_diff; older or foreign responses
  /// are discarded.
  String? _pendingDiffRequestId;

  bool get _supportsCorrelatedDiff =>
      _bridge.bridgeCapabilities.contains(gitDiffRequestCorrelationCapability);

  /// Send get_diff stamped with a fresh requestId. The Bridge echoes it in
  /// diff_result so each cubit consumes only its own response; old Bridges
  /// ignore the extra key and echo nothing. Those legacy requests share one
  /// Bridge-level lane so a response can reach only its actual owner.
  void _sendGetDiff(String projectPath, {required bool staged}) {
    if (!_supportsCorrelatedDiff) {
      if (_bridge.isGitOperationLaneQuarantined(_legacyDiffLane)) {
        _legacyDiffAcquireTimer?.cancel();
        _legacyDiffAcquireTimer = null;
        _queuedLegacyDiffStaged = null;
        emit(
          state.copyWith(
            loading: false,
            error:
                'The legacy Bridge did not finish the previous Git request. '
                'Reconnect before retrying.',
            errorCode: 'git_legacy_request_quarantined',
          ),
        );
        return;
      }
      if (_pendingDiffRequestId != null &&
          _bridge.ownsGitOperationLane(_legacyDiffLane, this)) {
        _queuedLegacyDiffStaged = staged;
        return;
      }
      if (!_bridge.tryAcquireGitOperationLane(_legacyDiffLane, this)) {
        _queuedLegacyDiffStaged = staged;
        _legacyDiffAcquireTimer ??= Timer(
          const Duration(milliseconds: 100),
          () {
            _legacyDiffAcquireTimer = null;
            if (isClosed) return;
            final queued = _queuedLegacyDiffStaged;
            if (queued == null) return;
            _queuedLegacyDiffStaged = null;
            _sendGetDiff(projectPath, staged: queued);
          },
        );
        return;
      }
    }
    _legacyDiffAcquireTimer?.cancel();
    _legacyDiffAcquireTimer = null;
    _queuedLegacyDiffStaged = null;
    _clearPendingDiffImageRequests();
    if (state.loadingImageIndices.isNotEmpty) {
      emit(state.copyWith(loadingImageIndices: const {}));
    }
    final requestId = 'gitdiff-${++GitViewCubit._diffRequestCounter}';
    _pendingDiffRequestId = requestId;
    _diffTimeout?.cancel();
    _diffTimeout = Timer(operationTimeout, () {
      if (isClosed || _pendingDiffRequestId != requestId) return;
      _pendingDiffRequestId = null;
      if (_supportsCorrelatedDiff) {
        _bridge.releaseGitOperationLane(_legacyDiffLane, this);
      } else {
        _bridge.quarantineGitOperationLane(_legacyDiffLane, this);
      }
      final queued = _queuedLegacyDiffStaged;
      _queuedLegacyDiffStaged = null;
      if (queued != null && _supportsCorrelatedDiff) {
        _sendGetDiff(projectPath, staged: queued);
        return;
      }
      emit(
        state.copyWith(
          loading: false,
          error: 'Git diff request timed out. Check the Bridge connection.',
          errorCode: 'git_request_timeout',
        ),
      );
    });
    _bridge.send(
      ClientMessage.getDiff(projectPath, staged: staged, requestId: requestId),
    );
  }

  void _requestDiff(String projectPath) {
    _diffSub = _bridge.diffResults.listen((result) {
      // A requestId that isn't ours means another session's diff or a stale
      // response from a superseded request (e.g. rapid mode switch) — drop it.
      // A legacy response has no identity and is accepted only by the owner of
      // the single compatibility lane.
      final requestId = result.requestId;
      if (requestId != null && requestId != _pendingDiffRequestId) return;
      if (requestId == null &&
          (_supportsCorrelatedDiff ||
              !_bridge.ownsGitOperationLane(_legacyDiffLane, this))) {
        return;
      }
      _diffTimeout?.cancel();
      _diffTimeout = null;
      _pendingDiffRequestId = null;
      _bridge.releaseGitOperationLane(_legacyDiffLane, this);
      final queued = _queuedLegacyDiffStaged;
      _queuedLegacyDiffStaged = null;
      if (queued != null) {
        _sendGetDiff(projectPath, staged: queued);
        return;
      }
      if (result.error != null) {
        emit(
          state.copyWith(
            loading: false,
            error: result.error,
            errorCode: result.errorCode,
          ),
        );
      } else if (result.diff.trim().isEmpty) {
        emit(state.copyWith(loading: false, files: []));
      } else {
        final files = _mergeImageChanges(
          parseDiff(result.diff),
          result.imageChanges,
        );
        emit(state.copyWith(loading: false, files: files));
      }
    });
    _sendGetDiff(projectPath, staged: _stagedParamForMode);
  }

  /// Whether this cubit supports refresh (projectPath mode).
  bool get canRefresh => _projectPath != null;

  /// The project path (for branch selector sheet).
  String? get projectPath => _projectPath;

  /// Re-request `git diff` from Bridge (e.g. for manual refresh).
  void refresh() {
    refreshDiffOnly(requestStatus: true, forceRemote: true);
    // Also fetch + update remote status on refresh
    _fetchAndUpdateStatus();
  }

  /// Re-request `git diff` from Bridge without fetching remote status.
  void refreshDiffOnly({bool requestStatus = false, bool forceRemote = false}) {
    final projectPath = _projectPath;
    if (projectPath == null) return;
    emit(state.copyWith(loading: true, error: null));
    _sendGetDiff(projectPath, staged: _stagedParamForMode);
    if (requestStatus) {
      _onStatusRefreshRequested?.call(forceRemote: forceRemote);
    }
  }

  /// Refresh after an external agent turn changed files.
  void refreshAfterExternalChange() {
    refreshDiffOnly(requestStatus: true);
  }

  /// Refresh after a repository mutation completed on a legacy Bridge whose
  /// broadcast result carried no project path.
  void refreshAfterLegacyRepositoryChange({bool branchChanged = false}) {
    refresh();
    if (!branchChanged) return;
    if (_sessionId != null) {
      _bridge.send(ClientMessage.refreshBranch(_sessionId));
    }
  }

  void refreshAfterLegacyBranchChange(String? currentBranch) {
    if (currentBranch != null) {
      emit(state.copyWith(currentBranch: currentBranch));
    }
    refreshAfterLegacyRepositoryChange(branchChanged: true);
  }

  bool get _stagedParamForMode => state.viewMode == GitViewMode.staged;

  /// Merge image change data from the server into parsed diff files.
  ///
  /// For each image file, checks the in-memory cache first. If the cache
  /// contains matching bytes (same oldSize/newSize), the cached bytes are
  /// restored immediately so the image renders without a network round-trip.
  List<DiffFile> _mergeImageChanges(
    List<DiffFile> files,
    List<DiffImageChange> imageChanges,
  ) {
    if (imageChanges.isEmpty) return files;

    final projectPath = _projectPath;
    final imageMap = <String, DiffImageChange>{
      for (final ic in imageChanges) ic.filePath: ic,
    };

    return files.map((file) {
      final ic = imageMap[file.filePath];
      if (ic == null) return file;

      // Check cache: if sizes match, restore bytes without network request.
      if (projectPath != null) {
        final cached = _bridge.getDiffImageCache(projectPath, file.filePath);
        if (cached != null &&
            cached.oldSize == ic.oldSize &&
            cached.newSize == ic.newSize) {
          final imageData = DiffImageData(
            oldSize: ic.oldSize,
            newSize: ic.newSize,
            oldBytes: cached.oldBytes,
            newBytes: cached.newBytes,
            mimeType: ic.mimeType,
            isSvg: ic.isSvg,
            loadable: ic.loadable,
            loaded: true,
            autoDisplay: ic.autoDisplay,
          );
          return DiffFile(
            filePath: file.filePath,
            hunks: file.hunks,
            isBinary: file.isBinary,
            isNewFile: file.isNewFile,
            isDeleted: file.isDeleted,
            isImage: true,
            imageData: imageData,
          );
        }
      }

      // No cache hit — use embedded data or leave for lazy loading.
      final hasEmbeddedData = ic.oldBase64 != null || ic.newBase64 != null;

      final imageData = DiffImageData(
        oldSize: ic.oldSize,
        newSize: ic.newSize,
        oldBytes: ic.oldBase64 != null ? base64Decode(ic.oldBase64!) : null,
        newBytes: ic.newBase64 != null ? base64Decode(ic.newBase64!) : null,
        mimeType: ic.mimeType,
        isSvg: ic.isSvg,
        loadable: ic.loadable,
        loaded: hasEmbeddedData,
        autoDisplay: ic.autoDisplay,
      );

      return DiffFile(
        filePath: file.filePath,
        hunks: file.hunks,
        isBinary: file.isBinary,
        isNewFile: file.isNewFile,
        isDeleted: file.isDeleted,
        isImage: true,
        imageData: imageData,
      );
    }).toList();
  }

  /// Maximum number of concurrent image loads to prevent server overload.
  static const _maxConcurrentLoads = 3;

  void _registerPendingDiffImageRequest(String filePath, String requestId) {
    final previous = _pendingDiffImageRequestIds[filePath];
    if (previous != null) {
      _removeLegacyPendingDiffImageRequest(filePath, previous);
    }
    _pendingDiffImageRequestIds[filePath] = requestId;
    final key = (bridge: _bridge, filePath: filePath);
    (_legacyPendingDiffImageRequests[key] ??= {}).add(requestId);
  }

  void _removeLegacyPendingDiffImageRequest(
    String filePath,
    String requestId,
  ) {
    final key = (bridge: _bridge, filePath: filePath);
    final pending = _legacyPendingDiffImageRequests[key];
    pending?.remove(requestId);
    if (pending?.isEmpty == true) {
      _legacyPendingDiffImageRequests.remove(key);
    }
  }

  void _completePendingDiffImageRequest(String filePath, String requestId) {
    if (_pendingDiffImageRequestIds[filePath] != requestId) return;
    _pendingDiffImageRequestIds.remove(filePath);
    _removeLegacyPendingDiffImageRequest(filePath, requestId);
  }

  void _clearPendingDiffImageRequests() {
    for (final entry in _pendingDiffImageRequestIds.entries) {
      _removeLegacyPendingDiffImageRequest(entry.key, entry.value);
    }
    _pendingDiffImageRequestIds.clear();
  }

  /// Load image data on demand (for loadable or auto-display images).
  void loadImage(int fileIdx) {
    final projectPath = _projectPath;
    if (projectPath == null) return;
    if (fileIdx >= state.files.length) return;
    final file = state.files[fileIdx];
    final imageData = file.imageData;
    if (imageData == null || !imageData.loadable) return;
    if (imageData.loaded) return;
    if (state.loadingImageIndices.contains(fileIdx)) return;
    // Throttle concurrent loads to avoid overwhelming the server
    if (state.loadingImageIndices.length >= _maxConcurrentLoads) return;

    emit(
      state.copyWith(
        loadingImageIndices: {...state.loadingImageIndices, fileIdx},
      ),
    );

    final requestId =
        'gitimage-${++GitViewCubit._diffImageRequestCounter}';
    _registerPendingDiffImageRequest(file.filePath, requestId);
    _bridge.send(
      ClientMessage.getDiffImage(
        projectPath,
        file.filePath,
        'both',
        requestId: requestId,
      ),
    );
  }

  void _onDiffImageResult(DiffImageResultMessage result) {
    if (result.projectPath != null && result.projectPath != _projectPath) {
      return;
    }
    final expectedRequestId = _pendingDiffImageRequestIds[result.filePath];
    if (expectedRequestId == null) return;
    if (result.requestId != null) {
      if (result.requestId != expectedRequestId) return;
    } else {
      final legacyRequests = _legacyPendingDiffImageRequests[(
        bridge: _bridge,
        filePath: result.filePath,
      )];
      if (legacyRequests == null ||
          legacyRequests.length != 1 ||
          !legacyRequests.contains(expectedRequestId)) {
        return;
      }
    }
    final files = state.files;
    final idx = files.indexWhere((f) => f.filePath == result.filePath);
    if (idx == -1) return;

    final file = files[idx];
    final existing = file.imageData;
    if (existing == null) return;

    DiffImageData updated;
    bool removeFromLoading;

    if (result.version == 'both') {
      // Both old and new in a single response — always complete
      final oldBytes = result.oldBase64 != null
          ? base64Decode(result.oldBase64!)
          : null;
      final newBytes = result.newBase64 != null
          ? base64Decode(result.newBase64!)
          : null;
      updated = existing.copyWith(
        oldBytes: oldBytes,
        newBytes: newBytes,
        loaded: true,
      );
      removeFromLoading = true;
    } else {
      Uint8List? bytes;
      if (result.base64 != null) {
        bytes = base64Decode(result.base64!);
      }
      updated = result.version == 'old'
          ? existing.copyWith(oldBytes: bytes, loaded: true)
          : existing.copyWith(newBytes: bytes, loaded: true);

      // Check if both sides are loaded (or not needed)
      removeFromLoading =
          (file.isNewFile || updated.oldBytes != null) &&
          (file.isDeleted || updated.newBytes != null);
    }

    final newFiles = List<DiffFile>.from(files);
    newFiles[idx] = file.copyWithImageData(updated);

    // Persist loaded image bytes to in-memory cache for instant reuse.
    if (removeFromLoading && _projectPath != null) {
      _completePendingDiffImageRequest(result.filePath, expectedRequestId);
      _bridge.setDiffImageCache(
        _projectPath,
        file.filePath,
        DiffImageCacheEntry(
          oldSize: updated.oldSize,
          newSize: updated.newSize,
          oldBytes: updated.oldBytes,
          newBytes: updated.newBytes,
        ),
      );
    }

    emit(
      state.copyWith(
        files: newFiles,
        loadingImageIndices: removeFromLoading
            ? (Set<int>.from(state.loadingImageIndices)..remove(idx))
            : state.loadingImageIndices,
      ),
    );
  }

  /// Toggle collapse state for a file at [fileIdx].
  void toggleCollapse(int fileIdx) {
    final current = state.collapsedFileIndices;
    emit(
      state.copyWith(
        collapsedFileIndices: current.contains(fileIdx)
            ? (Set<int>.from(current)..remove(fileIdx))
            : {...current, fileIdx},
      ),
    );
  }

  void toggleLineWrap() {
    emit(state.copyWith(lineWrapEnabled: !state.lineWrapEnabled));
  }

  // ---------------------------------------------------------------------------
  // Staging operations
  // ---------------------------------------------------------------------------

  /// Switch between unstaged (working-tree) and staged (index) diff view.
  void switchMode(GitViewMode mode) {
    if (mode == state.viewMode) return;
    emit(state.copyWith(viewMode: mode, loading: true, error: null, files: []));
    final projectPath = _projectPath;
    if (projectPath != null) {
      _sendGetDiff(projectPath, staged: mode == GitViewMode.staged);
    }
  }

  /// Stage a single file by index.
  void stageFile(int fileIdx) {
    final projectPath = _projectPath;
    if (projectPath == null || fileIdx >= state.files.length) return;
    if (!_beginMutation('stage')) return;
    emit(state.copyWith(staging: true));
    _scheduleStagingTimeout();
    _bridge.send(
      ClientMessage.gitStage(
        projectPath,
        files: [state.files[fileIdx].filePath],
      ),
    );
  }

  /// Unstage a single file by index.
  void unstageFile(int fileIdx) {
    final projectPath = _projectPath;
    if (projectPath == null || fileIdx >= state.files.length) return;
    if (!_beginMutation('unstage')) return;
    emit(state.copyWith(staging: true));
    _scheduleStagingTimeout();
    _bridge.send(
      ClientMessage.gitUnstage(
        projectPath,
        files: [state.files[fileIdx].filePath],
      ),
    );
  }

  /// Build the wire reference for a displayed hunk. Includes a content
  /// fingerprint so the Bridge targets exactly the hunk the user saw; the
  /// legacy `hunkIndex` stays for old Bridges that ignore the extra key.
  Map<String, dynamic> _hunkRef(int fileIdx, int hunkIdx) {
    final file = state.files[fileIdx];
    final ref = <String, dynamic>{'file': file.filePath, 'hunkIndex': hunkIdx};
    if (hunkIdx < file.hunks.length) {
      final fingerprint = buildHunkFingerprint(file.hunks[hunkIdx]);
      if (fingerprint != null) ref['fingerprint'] = fingerprint;
    }
    return ref;
  }

  void stageHunk(int fileIdx, int hunkIdx) {
    final projectPath = _projectPath;
    if (projectPath == null || fileIdx >= state.files.length) return;
    if (!_beginMutation('stage')) return;
    emit(state.copyWith(staging: true));
    _scheduleStagingTimeout();
    _bridge.send(
      ClientMessage.gitStage(projectPath, hunks: [_hunkRef(fileIdx, hunkIdx)]),
    );
  }

  void unstageHunk(int fileIdx, int hunkIdx) {
    final projectPath = _projectPath;
    if (projectPath == null || fileIdx >= state.files.length) return;
    if (!_beginMutation('unstage_hunks')) return;
    emit(state.copyWith(staging: true));
    _scheduleStagingTimeout();
    _bridge.send(
      ClientMessage.gitUnstageHunks(projectPath, [_hunkRef(fileIdx, hunkIdx)]),
    );
  }

  /// Revert (discard) changes for a single file.
  void revertFile(int fileIdx) {
    final projectPath = _projectPath;
    if (projectPath == null || fileIdx >= state.files.length) return;
    if (!_beginMutation('revert_file')) return;
    emit(state.copyWith(staging: true));
    _scheduleStagingTimeout();
    _bridge.send(
      ClientMessage.gitRevertFile(projectPath, [state.files[fileIdx].filePath]),
    );
  }

  void revertHunk(int fileIdx, int hunkIdx) {
    final projectPath = _projectPath;
    if (projectPath == null || fileIdx >= state.files.length) return;
    if (!_beginMutation('revert_hunks')) return;
    emit(state.copyWith(staging: true));
    _scheduleStagingTimeout();
    _bridge.send(
      ClientMessage.gitRevertHunks(projectPath, [_hunkRef(fileIdx, hunkIdx)]),
    );
  }

  bool _pendingSwitchToStaged = false;
  bool _pendingSwitchToUnstaged = false;

  /// Stage all files.
  void stageAll() {
    final projectPath = _projectPath;
    if (projectPath == null || state.files.isEmpty) return;
    if (!_beginMutation('stage')) return;
    _pendingSwitchToStaged = true;
    emit(state.copyWith(staging: true));
    _scheduleStagingTimeout();
    _bridge.send(
      ClientMessage.gitStage(
        projectPath,
        files: state.files.map((f) => f.filePath).toList(),
      ),
    );
  }

  /// Unstage all files.
  void unstageAll() {
    final projectPath = _projectPath;
    if (projectPath == null || state.files.isEmpty) return;
    if (!_beginMutation('unstage')) return;
    _pendingSwitchToUnstaged = true;
    emit(state.copyWith(staging: true));
    _scheduleStagingTimeout();
    _bridge.send(
      ClientMessage.gitUnstage(
        projectPath,
        files: state.files.map((f) => f.filePath).toList(),
      ),
    );
  }

  /// Revert all visible files.
  void revertAll() {
    final projectPath = _projectPath;
    if (projectPath == null || state.files.isEmpty) return;
    if (!_beginMutation('revert_file')) return;
    emit(state.copyWith(staging: true));
    _scheduleStagingTimeout();
    _bridge.send(
      ClientMessage.gitRevertFile(
        projectPath,
        state.files.map((f) => f.filePath).toList(),
      ),
    );
  }

  /// Git results are broadcast to every listener; one stamped with another
  /// projectPath belongs to a different project's view. Old Bridges echo no
  /// projectPath — accept those.
  bool _isForeignProject(String? resultProjectPath) =>
      resultProjectPath != null && resultProjectPath != _projectPath;

  bool _beginMutation(String operation) {
    if (_pendingMutation != null ||
        !_bridge.tryAcquireGitOperationLane(
          BridgeService.gitMutationOperationLane,
          this,
        )) {
      emit(
        state.copyWith(
          error:
              'Another Git change is still pending. Wait for it to finish '
              'before starting a new one.',
          errorCode: 'git_operation_busy',
        ),
      );
      return false;
    }
    _pendingMutation = operation;
    return true;
  }

  bool _acceptMutationResult(String operation, String? resultProjectPath) {
    return !_isForeignProject(resultProjectPath) &&
        _pendingMutation == operation &&
        _bridge.ownsGitOperationLane(
          BridgeService.gitMutationOperationLane,
          this,
        );
  }

  void _completeMutation() {
    _pendingMutation = null;
    _bridge.releaseGitOperationLane(
      BridgeService.gitMutationOperationLane,
      this,
    );
  }

  void _quarantineTimedOutMutation() {
    if (_pendingMutation == null) return;
    _pendingMutation = null;
    _bridge.quarantineGitOperationLane(
      BridgeService.gitMutationOperationLane,
      this,
    );
  }

  void _scheduleStagingTimeout() {
    _stagingTimeout?.cancel();
    _stagingTimeout = Timer(operationTimeout, () {
      if (isClosed || !state.staging) return;
      _quarantineTimedOutMutation();
      _pendingSwitchToStaged = false;
      _pendingSwitchToUnstaged = false;
      emit(
        state.copyWith(
          staging: false,
          error: 'Git operation timed out. Check the Bridge connection.',
          errorCode: 'git_request_timeout',
        ),
      );
    });
  }

  void _completeStagingRequest() {
    _stagingTimeout?.cancel();
    _stagingTimeout = null;
    _completeMutation();
  }

  void _onStageResult(GitStageResultMessage result) {
    if (!_acceptMutationResult('stage', result.projectPath)) return;
    _completeStagingRequest();
    if (result.success) {
      emit(state.copyWith(staging: false));
      if (_pendingSwitchToStaged) {
        _pendingSwitchToStaged = false;
        switchMode(GitViewMode.staged);
        _onStatusRefreshRequested?.call();
      } else {
        refreshDiffOnly(requestStatus: true);
      }
    } else {
      _pendingSwitchToStaged = false;
      emit(state.copyWith(staging: false, error: result.error));
    }
  }

  void _onRevertResult(GitRevertFileResultMessage result) {
    if (!_acceptMutationResult('revert_file', result.projectPath)) return;
    _completeStagingRequest();
    if (result.success) {
      emit(state.copyWith(staging: false));
      refreshDiffOnly(requestStatus: true);
    } else {
      emit(state.copyWith(staging: false, error: result.error));
    }
  }

  void _onRevertHunksResult(GitRevertHunksResultMessage result) {
    if (!_acceptMutationResult('revert_hunks', result.projectPath)) return;
    _completeStagingRequest();
    if (result.success) {
      emit(state.copyWith(staging: false));
      refreshDiffOnly(requestStatus: true);
    } else {
      emit(state.copyWith(staging: false, error: result.error));
    }
  }

  void _onUnstageResult(GitUnstageResultMessage result) {
    if (!_acceptMutationResult('unstage', result.projectPath)) return;
    _completeStagingRequest();
    if (result.success) {
      emit(state.copyWith(staging: false));
      if (_pendingSwitchToUnstaged) {
        _pendingSwitchToUnstaged = false;
        switchMode(GitViewMode.unstaged);
        _onStatusRefreshRequested?.call();
      } else {
        refreshDiffOnly(requestStatus: true);
      }
    } else {
      _pendingSwitchToUnstaged = false;
      emit(state.copyWith(staging: false, error: result.error));
    }
  }

  void _onUnstageHunksResult(GitUnstageHunksResultMessage result) {
    if (!_acceptMutationResult('unstage_hunks', result.projectPath)) return;
    _completeStagingRequest();
    if (result.success) {
      emit(state.copyWith(staging: false));
      refreshDiffOnly(requestStatus: true);
    } else {
      emit(state.copyWith(staging: false, error: result.error));
    }
  }

  // ---------------------------------------------------------------------------
  // Remote operations (fetch / pull / push)
  // ---------------------------------------------------------------------------

  void _fetchAndUpdateStatus() {
    final projectPath = _projectPath;
    if (projectPath == null) return;
    emit(state.copyWith(fetching: true));
    _fetchTimeout?.cancel();
    _fetchTimeout = Timer(operationTimeout, () {
      if (isClosed || !state.fetching) return;
      emit(
        state.copyWith(
          fetching: false,
          error: 'Git fetch timed out. Check the Bridge connection.',
          errorCode: 'git_request_timeout',
        ),
      );
    });
    _bridge.send(ClientMessage.gitFetch(projectPath));
  }

  void _onFetchResult(GitFetchResultMessage result) {
    if (_isForeignProject(result.projectPath)) return;
    _fetchTimeout?.cancel();
    _fetchTimeout = null;
    emit(state.copyWith(fetching: false));
    if (!result.success) {
      emit(state.copyWith(error: result.error ?? 'Git fetch failed.'));
      return;
    }
    // After fetch, request remote status to get ahead/behind counts
    final projectPath = _projectPath;
    if (projectPath != null) {
      _bridge.send(ClientMessage.gitRemoteStatus(projectPath));
    }
  }

  void _onRemoteStatus(GitRemoteStatusResultMessage result) {
    if (_isForeignProject(result.projectPath)) return;
    emit(
      state.copyWith(
        commitsAhead: result.ahead,
        commitsBehind: result.behind,
        hasUpstream: result.hasUpstream,
      ),
    );
  }

  /// Pull from remote.
  void pull() {
    final projectPath = _projectPath;
    if (projectPath == null) return;
    if (!_beginMutation('pull')) return;
    emit(state.copyWith(pulling: true));
    _pullTimeout?.cancel();
    _pullTimeout = Timer(operationTimeout, () {
      if (isClosed || !state.pulling) return;
      _quarantineTimedOutMutation();
      emit(
        state.copyWith(
          pulling: false,
          error: 'Git pull timed out. Check the Bridge connection.',
          errorCode: 'git_request_timeout',
        ),
      );
    });
    _bridge.send(ClientMessage.gitPull(projectPath));
  }

  void _onPullResult(GitPullResultMessage result) {
    if (!_acceptMutationResult('pull', result.projectPath)) return;
    _pullTimeout?.cancel();
    _pullTimeout = null;
    _completeMutation();
    emit(state.copyWith(pulling: false));
    if (result.success) {
      refresh(); // refresh diff + remote status
    } else {
      emit(state.copyWith(error: result.error));
    }
  }

  /// Push to remote.
  void push() {
    final projectPath = _projectPath;
    if (projectPath == null) return;
    if (!_beginMutation('push')) return;
    emit(state.copyWith(pushing: true));
    _pushTimeout?.cancel();
    _pushTimeout = Timer(operationTimeout, () {
      if (isClosed || !state.pushing) return;
      _quarantineTimedOutMutation();
      emit(
        state.copyWith(
          pushing: false,
          error: 'Git push timed out. Check the Bridge connection.',
          errorCode: 'git_request_timeout',
        ),
      );
    });
    _bridge.send(ClientMessage.gitPush(projectPath));
  }

  void _onPushResult(GitPushResultMessage result) {
    if (!_acceptMutationResult('push', result.projectPath)) return;
    _pushTimeout?.cancel();
    _pushTimeout = null;
    _completeMutation();
    emit(state.copyWith(pushing: false));
    if (result.success) {
      refresh();
    } else {
      emit(state.copyWith(error: result.error));
    }
  }

  void _onCommitResult(GitCommitResultMessage result) {
    // A pathless result belongs to a legacy CommitCubit that owns the
    // destructive lane. It cannot safely be attributed to this view.
    if (result.projectPath == null || _isForeignProject(result.projectPath)) {
      return;
    }
    if (result.success) {
      refresh();
    }
  }

  // ---------------------------------------------------------------------------
  // Branch operations
  // ---------------------------------------------------------------------------

  void _onBranchesResult(GitBranchesResultMessage result) {
    if (_isForeignProject(result.projectPath)) return;
    if (result.error == null) {
      emit(state.copyWith(currentBranch: result.current));
    }
  }

  void _onCheckoutResult(GitCheckoutBranchResultMessage result) {
    // Legacy checkout results are consumed by the BranchCubit lane owner.
    if (result.projectPath == null || _isForeignProject(result.projectPath)) {
      return;
    }
    if (result.success) {
      // Refresh diff + branch + remote status after checkout
      refresh();
      // Update session branch info so session list card reflects the change
      if (_sessionId != null) {
        _bridge.send(ClientMessage.refreshBranch(_sessionId));
      }
    }
  }

  void _onConnectionState(BridgeConnectionState connectionState) {
    if (connectionState == BridgeConnectionState.connected) return;
    final hadPendingOperation =
        _pendingDiffRequestId != null ||
        _pendingMutation != null ||
        state.staging ||
        state.fetching ||
        state.pulling ||
        state.pushing;
    if (!hadPendingOperation) return;

    _diffTimeout?.cancel();
    _stagingTimeout?.cancel();
    _fetchTimeout?.cancel();
    _pullTimeout?.cancel();
    _pushTimeout?.cancel();
    _legacyDiffAcquireTimer?.cancel();
    _pendingDiffRequestId = null;
    _pendingMutation = null;
    _queuedLegacyDiffStaged = null;
    _bridge.releaseGitOperationLanes(this);
    emit(
      state.copyWith(
        loading: false,
        staging: false,
        fetching: false,
        pulling: false,
        pushing: false,
        error: 'The Bridge disconnected before the Git operation completed.',
        errorCode: 'bridge_disconnected',
      ),
    );
  }

  @override
  Future<void> close() {
    _diffTimeout?.cancel();
    _stagingTimeout?.cancel();
    _fetchTimeout?.cancel();
    _pullTimeout?.cancel();
    _pushTimeout?.cancel();
    _legacyDiffAcquireTimer?.cancel();
    if (_pendingDiffRequestId != null && !_supportsCorrelatedDiff) {
      _bridge.quarantineGitOperationLane(_legacyDiffLane, this);
    }
    if (_pendingMutation != null) {
      _bridge.quarantineGitOperationLane(
        BridgeService.gitMutationOperationLane,
        this,
      );
    }
    _bridge.releaseGitOperationLanes(this);
    _clearPendingDiffImageRequests();
    _diffSub?.cancel();
    _diffImageSub?.cancel();
    _stageSub?.cancel();
    _unstageSub?.cancel();
    _unstageHunksSub?.cancel();
    _revertSub?.cancel();
    _revertHunksSub?.cancel();
    _fetchSub?.cancel();
    _pullSub?.cancel();
    _pushResultSub?.cancel();
    _commitResultSub?.cancel();
    _remoteStatusSub?.cancel();
    _branchesSub?.cancel();
    _checkoutSub?.cancel();
    _connectionSub?.cancel();
    return super.close();
  }
}
