import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../models/messages.dart';
import '../../../services/bridge_service.dart';
import 'branch_state.dart';

/// Manages branch listing, search, creation, and checkout.
class BranchCubit extends Cubit<BranchState> {
  static const _legacyBranchListLane = 'git-branches-legacy';

  final BridgeService _bridge;
  final String _projectPath;
  final void Function(String? currentBranch)? onLegacyRepositoryChanged;
  final Duration operationTimeout;

  StreamSubscription<GitBranchesResultMessage>? _branchesSub;
  StreamSubscription<GitCreateBranchResultMessage>? _createSub;
  StreamSubscription<GitCheckoutBranchResultMessage>? _checkoutSub;
  StreamSubscription<BridgeConnectionState>? _connectionSub;
  Timer? _operationTimer;
  String? _pendingOperation;
  bool _legacyRepositoryChangePending = false;

  BranchCubit({
    required BridgeService bridge,
    required String projectPath,
    this.onLegacyRepositoryChanged,
    this.operationTimeout = const Duration(seconds: 15),
  }) : _bridge = bridge,
       _projectPath = projectPath,
       super(const BranchState()) {
    _branchesSub = _bridge.gitBranchesResults.listen(_onBranchesResult);
    _createSub = _bridge.gitCreateBranchResults.listen(_onCreateResult);
    _checkoutSub = _bridge.gitCheckoutBranchResults.listen(_onCheckoutResult);
    _connectionSub = _bridge.connectionStatus.listen(_onConnectionState);
  }

  bool get _supportsProjectCorrelation => _bridge.bridgeCapabilities.contains(
    gitProjectResultCorrelationCapability,
  );
  String get _branchListLane => _supportsProjectCorrelation
      ? 'git-branches:$_projectPath'
      : _legacyBranchListLane;

  // ---- Public API ----

  /// Load (or refresh) the branch list from the Bridge.
  void loadBranches() {
    if (_pendingOperation != null) return;
    if (!_bridge.tryAcquireGitOperationLane(_branchListLane, this)) {
      emit(
        state.copyWith(
          loading: false,
          error:
              'Another legacy Git branch request is still pending. '
              'Wait for it to finish and retry.',
        ),
      );
      return;
    }
    _pendingOperation = 'list';
    emit(state.copyWith(loading: true, error: null));
    _startOperationTimer();
    _bridge.send(ClientMessage.gitBranches(_projectPath));
  }

  /// Filter branches locally by [query].
  void search(String query) {
    emit(state.copyWith(query: query));
  }

  /// Branches filtered by the current search query.
  List<String> get filteredBranches {
    if (state.query.isEmpty) return state.branches;
    final q = state.query.toLowerCase();
    return state.branches.where((b) => b.toLowerCase().contains(q)).toList();
  }

  /// Create a new branch and optionally check it out.
  void createBranch(String name, {bool checkout = true}) {
    if (!_beginMutation('create')) return;
    emit(state.copyWith(creating: true, error: null));
    _bridge.send(
      ClientMessage.gitCreateBranch(_projectPath, name, checkout: checkout),
    );
  }

  /// Checkout an existing branch.
  void checkout(String branch) {
    if (!_beginMutation('checkout')) return;
    emit(state.copyWith(loading: true, error: null));
    _bridge.send(ClientMessage.gitCheckoutBranch(_projectPath, branch));
  }

  // ---- Callbacks ----

  /// Git results are broadcast to every listener; one stamped with another
  /// projectPath belongs to a different project's branch view. Old Bridges
  /// echo no projectPath — accept those.
  bool _isForeignProject(String? resultProjectPath) =>
      resultProjectPath != null && resultProjectPath != _projectPath;

  void _onBranchesResult(GitBranchesResultMessage result) {
    if (_pendingOperation != 'list' ||
        _isForeignProject(result.projectPath) ||
        (_supportsProjectCorrelation && result.projectPath == null) ||
        !_bridge.ownsGitOperationLane(_branchListLane, this)) {
      return;
    }
    _finishOperation(_branchListLane);
    if (result.error != null) {
      _completeLegacyRepositoryChange(null);
      emit(state.copyWith(loading: false, error: result.error));
      return;
    }
    emit(
      state.copyWith(
        loading: false,
        current: result.current,
        branches: result.branches,
        checkedOutBranches: result.checkedOutBranches,
        remoteStatusByBranch: result.remoteStatusByBranch,
      ),
    );
    _completeLegacyRepositoryChange(result.current);
  }

  void _onCreateResult(GitCreateBranchResultMessage result) {
    if (!_acceptMutation('create', result.projectPath)) return;
    _finishOperation(BridgeService.gitMutationOperationLane);
    if (!result.success) {
      emit(state.copyWith(creating: false, error: result.error));
      return;
    }
    if (result.projectPath == null) {
      _legacyRepositoryChangePending = true;
    }
    emit(state.copyWith(creating: false));
    // Refresh branch list to include the new branch
    loadBranches();
  }

  void _onCheckoutResult(GitCheckoutBranchResultMessage result) {
    if (!_acceptMutation('checkout', result.projectPath)) return;
    _finishOperation(BridgeService.gitMutationOperationLane);
    if (!result.success) {
      emit(state.copyWith(loading: false, error: result.error));
      return;
    }
    if (result.projectPath == null) {
      _legacyRepositoryChangePending = true;
    }
    // Refresh to update current branch
    loadBranches();
  }

  bool _beginMutation(String operation) {
    if (_pendingOperation != null ||
        !_bridge.tryAcquireGitOperationLane(
          BridgeService.gitMutationOperationLane,
          this,
        )) {
      emit(
        state.copyWith(
          loading: false,
          creating: false,
          error:
              'Another Git change is still pending. Wait for it to finish '
              'before changing branches.',
        ),
      );
      return false;
    }
    _pendingOperation = operation;
    _startOperationTimer();
    return true;
  }

  bool _acceptMutation(String operation, String? resultProjectPath) {
    return _pendingOperation == operation &&
        !_isForeignProject(resultProjectPath) &&
        _bridge.ownsGitOperationLane(
          BridgeService.gitMutationOperationLane,
          this,
        );
  }

  void _startOperationTimer() {
    _operationTimer?.cancel();
    _operationTimer = Timer(operationTimeout, () {
      if (isClosed || _pendingOperation == null) return;
      final operation = _pendingOperation;
      _pendingOperation = null;
      if (operation == 'list') {
        _bridge.quarantineGitOperationLane(_branchListLane, this);
        _completeLegacyRepositoryChange(null);
      } else {
        _bridge.quarantineGitOperationLane(
          BridgeService.gitMutationOperationLane,
          this,
        );
      }
      emit(
        state.copyWith(
          loading: false,
          creating: false,
          error:
              'The Git branch operation timed out. Reconnect to the Bridge '
              'before retrying.',
        ),
      );
    });
  }

  void _finishOperation(String lane) {
    _operationTimer?.cancel();
    _operationTimer = null;
    _pendingOperation = null;
    _bridge.releaseGitOperationLane(lane, this);
  }

  void _completeLegacyRepositoryChange(String? currentBranch) {
    if (!_legacyRepositoryChangePending) return;
    _legacyRepositoryChangePending = false;
    onLegacyRepositoryChanged?.call(currentBranch);
  }

  void _onConnectionState(BridgeConnectionState connectionState) {
    if (_pendingOperation == null ||
        connectionState == BridgeConnectionState.connected) {
      return;
    }
    _operationTimer?.cancel();
    _operationTimer = null;
    _pendingOperation = null;
    _legacyRepositoryChangePending = false;
    _bridge.releaseGitOperationLanes(this);
    emit(
      state.copyWith(
        loading: false,
        creating: false,
        error:
            'The Bridge disconnected before the Git branch operation '
            'completed.',
      ),
    );
  }

  @override
  Future<void> close() {
    _operationTimer?.cancel();
    final operation = _pendingOperation;
    if (operation == 'list') {
      _bridge.quarantineGitOperationLane(_branchListLane, this);
    } else if (operation != null) {
      _bridge.quarantineGitOperationLane(
        BridgeService.gitMutationOperationLane,
        this,
      );
    }
    _bridge.releaseGitOperationLanes(this);
    _branchesSub?.cancel();
    _createSub?.cancel();
    _checkoutSub?.cancel();
    _connectionSub?.cancel();
    return super.close();
  }
}
