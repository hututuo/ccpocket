import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/messages.dart'
    show
        BridgeConnectionState,
        ClientMessage,
        CodexActionResultMessage,
        CodexMcpServerStatus,
        CodexMcpStatusResultMessage,
        CodexReviewTarget,
        LocalFeatureRequestErrorMessage,
        LocalFeatureServerMessage,
        requestCodexCompact,
        requestCodexMcpStatus,
        requestCodexReview;
import '../../services/bridge_service.dart';

class CodexCoreActionsController extends ChangeNotifier {
  static const _uuid = Uuid();

  CodexCoreActionsController({
    required this.sessionId,
    required this.bridge,
    this.requestTimeout = const Duration(seconds: 20),
  });

  final String sessionId;
  final BridgeService bridge;
  final Duration requestTimeout;

  StreamSubscription<LocalFeatureServerMessage>? _messageSubscription;
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  Timer? _actionTimer;
  Timer? _mcpTimer;
  String? _actionRequestId;
  String? _actionRequestType;
  String? _mcpRequestId;
  bool _started = false;
  bool _disposed = false;
  CodexActionResultMessage? _lastActionResult;
  List<CodexMcpServerStatus> _servers = const [];
  bool _mcpLoaded = false;
  bool _serversTruncated = false;
  String? _actionErrorCode;
  String? _actionError;
  String? _mcpErrorCode;
  String? _mcpError;

  bool get actionLoading => _actionRequestId != null;
  bool get mcpLoading => _mcpRequestId != null;
  bool get connected => bridge.isConnected;
  CodexActionResultMessage? get lastActionResult => _lastActionResult;
  List<CodexMcpServerStatus> get servers => _servers;
  bool get mcpLoaded => _mcpLoaded;
  bool get serversTruncated => _serversTruncated;
  String? get actionErrorCode => _actionErrorCode;
  String? get actionError => _actionError;
  String? get mcpErrorCode => _mcpErrorCode;
  String? get mcpError => _mcpError;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _messageSubscription = bridge
        .localFeatureMessagesForSession(sessionId)
        .listen(_onMessage);
    _connectionSubscription = bridge.connectionStatus.listen(
      _onConnectionState,
    );
  }

  bool requestCompact() => _sendAction(
    requestType: 'codex_compact_request',
    build: (requestId) =>
        requestCodexCompact(sessionId: sessionId, requestId: requestId),
  );

  bool requestReview(CodexReviewTarget target) => _sendAction(
    requestType: 'codex_review_request',
    build: (requestId) => requestCodexReview(
      sessionId: sessionId,
      requestId: requestId,
      target: target,
    ),
  );

  bool _sendAction({
    required String requestType,
    required ClientMessage Function(String requestId) build,
  }) {
    if (_disposed || !bridge.isConnected || actionLoading) return false;
    final requestId = _uuid.v4();
    _actionTimer?.cancel();
    _actionRequestId = requestId;
    _actionRequestType = requestType;
    _actionErrorCode = null;
    _actionError = null;
    _lastActionResult = null;
    notifyListeners();
    try {
      bridge.send(build(requestId));
    } catch (error) {
      _finishActionError('send_failed', error.toString());
      return false;
    }
    _actionTimer = Timer(requestTimeout, () {
      if (_disposed || _actionRequestId != requestId) return;
      _finishActionError('request_timeout', 'Request timed out');
    });
    return true;
  }

  bool refreshMcpStatus() {
    if (_disposed || !bridge.isConnected || mcpLoading) return false;
    final requestId = _uuid.v4();
    _mcpTimer?.cancel();
    _mcpRequestId = requestId;
    _mcpErrorCode = null;
    _mcpError = null;
    notifyListeners();
    try {
      bridge.send(
        requestCodexMcpStatus(sessionId: sessionId, requestId: requestId),
      );
    } catch (error) {
      _finishMcpError('send_failed', error.toString());
      return false;
    }
    _mcpTimer = Timer(requestTimeout, () {
      if (_disposed || _mcpRequestId != requestId) return;
      _finishMcpError('request_timeout', 'Request timed out');
    });
    return true;
  }

  void _onMessage(LocalFeatureServerMessage message) {
    if (message case LocalFeatureRequestErrorMessage()) {
      if (message.featureId != 'codex_core_actions') return;
      if (message.requestId == _actionRequestId &&
          message.requestType == _actionRequestType) {
        _finishActionError(
          message.errorCode ?? 'unsupported_bridge',
          message.message,
        );
      } else if (message.requestId == _mcpRequestId &&
          message.requestType == 'codex_mcp_status_request') {
        _finishMcpError(
          message.errorCode ?? 'unsupported_bridge',
          message.message,
        );
      }
      return;
    }
    if (message is CodexActionResultMessage &&
        message.requestId == _actionRequestId &&
        message.action == _expectedAction(_actionRequestType)) {
      _actionTimer?.cancel();
      _actionRequestId = null;
      _actionRequestType = null;
      _lastActionResult = message;
      if (!message.accepted) {
        _actionErrorCode = message.errorCode ?? message.status;
        _actionError = message.message;
      }
      notifyListeners();
      return;
    }
    if (message is CodexMcpStatusResultMessage &&
        message.requestId == _mcpRequestId) {
      _mcpTimer?.cancel();
      _mcpRequestId = null;
      if (message.status == 'completed') {
        _servers = message.servers;
        _mcpLoaded = true;
        _serversTruncated = message.serversTruncated;
        _mcpErrorCode = null;
        _mcpError = null;
      } else {
        _mcpErrorCode = message.errorCode ?? message.status;
        _mcpError = message.message;
      }
      notifyListeners();
    }
  }

  String? _expectedAction(String? requestType) => switch (requestType) {
    'codex_compact_request' => 'compact',
    'codex_review_request' => 'review',
    _ => null,
  };

  void _onConnectionState(BridgeConnectionState state) {
    if (state == BridgeConnectionState.connected) return;
    if (actionLoading) {
      _finishActionError('disconnected', 'Bridge disconnected');
    }
    if (mcpLoading) {
      _finishMcpError('disconnected', 'Bridge disconnected');
    }
  }

  void _finishActionError(String code, String message) {
    _actionTimer?.cancel();
    _actionRequestId = null;
    _actionRequestType = null;
    _actionErrorCode = code;
    _actionError = message;
    if (!_disposed) notifyListeners();
  }

  void _finishMcpError(String code, String message) {
    _mcpTimer?.cancel();
    _mcpRequestId = null;
    _mcpErrorCode = code;
    _mcpError = message;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _actionTimer?.cancel();
    _mcpTimer?.cancel();
    _messageSubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }
}
