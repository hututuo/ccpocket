import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../models/messages.dart';
import '../../../services/bridge_service.dart';
import 'commit_state.dart';

/// Manages the commit → push → PR creation flow.
class CommitCubit extends Cubit<CommitState> {
  final BridgeService _bridge;
  final String _projectPath;
  final String? _sessionId;
  final void Function()? onLegacyRepositoryChanged;
  final Duration operationTimeout;

  StreamSubscription<GitCommitResultMessage>? _commitSub;
  StreamSubscription<GitPushResultMessage>? _pushSub;
  StreamSubscription<BridgeConnectionState>? _connectionSub;
  Timer? _operationTimer;
  _CommitOperationPhase? _pendingPhase;

  /// What to do after a successful commit.
  _PostCommitAction _postCommitAction = _PostCommitAction.none;

  CommitCubit({
    required BridgeService bridge,
    required String projectPath,
    String? sessionId,
    this.onLegacyRepositoryChanged,
    this.operationTimeout = const Duration(seconds: 20),
  }) : _bridge = bridge,
       _projectPath = projectPath,
       _sessionId = sessionId,
       super(const CommitState()) {
    _commitSub = _bridge.gitCommitResults.listen(_onCommitResult);
    _pushSub = _bridge.gitPushResults.listen(_onPushResult);
    _connectionSub = _bridge.connectionStatus.listen(_onConnectionState);
  }

  // ---- Public API ----

  void setMessage(String message) => emit(state.copyWith(message: message));

  void toggleAutoGenerate() =>
      emit(state.copyWith(autoGenerate: !state.autoGenerate));

  /// Update staged file summary from GitViewCubit.
  void updateStagedSummary({
    required int fileCount,
    required int insertions,
    required int deletions,
  }) {
    emit(
      state.copyWith(
        stagedFileCount: fileCount,
        insertions: insertions,
        deletions: deletions,
      ),
    );
  }

  /// Commit only.
  void commit() {
    _postCommitAction = _PostCommitAction.none;
    _doCommit();
  }

  /// Commit then push.
  void commitAndPush() {
    _postCommitAction = _PostCommitAction.push;
    _doCommit();
  }

  /// Reset to idle state (e.g. after dismissing success/error).
  void reset() {
    if (_pendingPhase != null) return;
    emit(const CommitState());
  }

  // ---- Internal ----

  void _doCommit() {
    if (_pendingPhase != null ||
        !_bridge.tryAcquireGitOperationLane(
          BridgeService.gitMutationOperationLane,
          this,
        )) {
      emit(
        state.copyWith(
          status: CommitStatus.error,
          error:
              'Another Git change is still pending. Wait for it to finish '
              'before committing.',
        ),
      );
      return;
    }
    _pendingPhase = _CommitOperationPhase.commit;
    emit(state.copyWith(status: CommitStatus.committing, error: null));
    _startOperationTimer();
    try {
      _bridge.send(
        ClientMessage.gitCommit(
          _projectPath,
          sessionId: state.autoGenerate ? _sessionId : null,
          message: state.autoGenerate ? null : state.message,
          autoGenerate: state.autoGenerate ? true : null,
        ),
      );
    } catch (error) {
      _finishOperation();
      emit(state.copyWith(status: CommitStatus.error, error: error.toString()));
    }
  }

  /// Git results are broadcast to every listener; one stamped with another
  /// projectPath belongs to a different project's commit flow. Old Bridges
  /// echo no projectPath — accept those.
  bool _isForeignProject(String? resultProjectPath) =>
      resultProjectPath != null && resultProjectPath != _projectPath;

  void _onCommitResult(GitCommitResultMessage result) {
    if (_isForeignProject(result.projectPath) ||
        _pendingPhase != _CommitOperationPhase.commit ||
        !_bridge.ownsGitOperationLane(
          BridgeService.gitMutationOperationLane,
          this,
        )) {
      return;
    }
    _operationTimer?.cancel();
    _operationTimer = null;
    if (!result.success) {
      _finishOperation();
      emit(state.copyWith(status: CommitStatus.error, error: result.error));
      return;
    }

    emit(state.copyWith(commitHash: result.commitHash));
    if (result.projectPath == null) {
      onLegacyRepositoryChanged?.call();
    }

    if (_postCommitAction == _PostCommitAction.push) {
      _pendingPhase = _CommitOperationPhase.push;
      emit(state.copyWith(status: CommitStatus.pushing));
      _startOperationTimer();
      try {
        _bridge.send(ClientMessage.gitPush(_projectPath));
      } catch (error) {
        _finishOperation();
        emit(
          state.copyWith(status: CommitStatus.error, error: error.toString()),
        );
      }
    } else {
      _finishOperation();
      emit(state.copyWith(status: CommitStatus.success));
    }
  }

  void _onPushResult(GitPushResultMessage result) {
    if (_isForeignProject(result.projectPath) ||
        _pendingPhase != _CommitOperationPhase.push ||
        !_bridge.ownsGitOperationLane(
          BridgeService.gitMutationOperationLane,
          this,
        )) {
      return;
    }
    _finishOperation();
    if (!result.success) {
      emit(state.copyWith(status: CommitStatus.error, error: result.error));
      return;
    }

    emit(state.copyWith(status: CommitStatus.success));
  }

  void _startOperationTimer() {
    _operationTimer?.cancel();
    _operationTimer = Timer(operationTimeout, () {
      if (isClosed || _pendingPhase == null) return;
      _pendingPhase = null;
      _bridge.quarantineGitOperationLane(
        BridgeService.gitMutationOperationLane,
        this,
      );
      emit(
        state.copyWith(
          status: CommitStatus.error,
          error:
              'The Git operation timed out. Reconnect to the Bridge before '
              'trying another repository change.',
        ),
      );
    });
  }

  void _finishOperation() {
    _operationTimer?.cancel();
    _operationTimer = null;
    _pendingPhase = null;
    _bridge.releaseGitOperationLane(
      BridgeService.gitMutationOperationLane,
      this,
    );
  }

  void _onConnectionState(BridgeConnectionState connectionState) {
    if (_pendingPhase == null ||
        connectionState == BridgeConnectionState.connected) {
      return;
    }
    _finishOperation();
    emit(
      state.copyWith(
        status: CommitStatus.error,
        error: 'The Bridge disconnected before the Git operation completed.',
      ),
    );
  }

  @override
  Future<void> close() {
    _operationTimer?.cancel();
    if (_pendingPhase != null) {
      _bridge.quarantineGitOperationLane(
        BridgeService.gitMutationOperationLane,
        this,
      );
    }
    _bridge.releaseGitOperationLanes(this);
    _commitSub?.cancel();
    _pushSub?.cancel();
    _connectionSub?.cancel();
    return super.close();
  }
}

enum _PostCommitAction { none, push }

enum _CommitOperationPhase { commit, push }
