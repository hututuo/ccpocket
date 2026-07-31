import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/codex_core_actions/codex_core_actions_controller.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final local = StreamController<LocalFeatureServerMessage>.broadcast();
  final connections = StreamController<BridgeConnectionState>.broadcast();
  final sent = <ClientMessage>[];
  bool connected = true;

  @override
  bool get isConnected => connected;

  @override
  Stream<BridgeConnectionState> get connectionStatus => connections.stream;

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => local.stream.where((message) => message.sessionId == sessionId);

  @override
  void send(ClientMessage message) => sent.add(message);

  @override
  void dispose() {
    local.close();
    connections.close();
    super.dispose();
  }
}

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('compact accepts only the exact correlated result', () async {
    final bridge = _Bridge();
    final controller = CodexCoreActionsController(
      sessionId: 's1',
      bridge: bridge,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    expect(controller.requestCompact(), isTrue);
    final requestId = _json(bridge.sent.single)['requestId'] as String;
    bridge.local.add(
      const CodexActionResultMessage(
        sessionId: 's1',
        requestId: 'wrong',
        action: 'compact',
        status: 'accepted',
      ),
    );
    await _flush();
    expect(controller.actionLoading, isTrue);

    bridge.local.add(
      CodexActionResultMessage(
        sessionId: 's1',
        requestId: requestId,
        action: 'review',
        status: 'accepted',
      ),
    );
    await _flush();
    expect(controller.actionLoading, isTrue);

    bridge.local.add(
      CodexActionResultMessage(
        sessionId: 's1',
        requestId: requestId,
        action: 'compact',
        status: 'accepted',
      ),
    );
    await _flush();
    expect(controller.actionLoading, isFalse);
    expect(controller.lastActionResult?.accepted, isTrue);
  });

  test('busy review is visible and is not reported as accepted', () async {
    final bridge = _Bridge();
    final controller = CodexCoreActionsController(
      sessionId: 's1',
      bridge: bridge,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    expect(
      controller.requestReview(const CodexReviewUncommittedTarget()),
      isTrue,
    );
    final requestId = _json(bridge.sent.single)['requestId'] as String;
    bridge.local.add(
      CodexActionResultMessage(
        sessionId: 's1',
        requestId: requestId,
        action: 'review',
        status: 'rejected',
        errorCode: 'session_busy',
        message: 'active turn',
      ),
    );
    await _flush();
    expect(controller.lastActionResult?.accepted, isFalse);
    expect(controller.actionErrorCode, 'session_busy');
  });

  test(
    'duplicate compact is ignored and the pending request times out',
    () async {
      final bridge = _Bridge();
      final controller = CodexCoreActionsController(
        sessionId: 's1',
        bridge: bridge,
        requestTimeout: const Duration(milliseconds: 1),
      )..start();
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      expect(controller.requestCompact(), isTrue);
      expect(controller.requestCompact(), isFalse);
      expect(bridge.sent, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.actionLoading, isFalse);
      expect(controller.actionErrorCode, 'request_timeout');
    },
  );

  test('old Bridge generic error closes only the matching request', () async {
    final bridge = _Bridge();
    final controller = CodexCoreActionsController(
      sessionId: 's1',
      bridge: bridge,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.refreshMcpStatus();
    final requestId = _json(bridge.sent.single)['requestId'] as String;
    bridge.local.add(
      const LocalFeatureRequestErrorMessage(
        featureId: 'codex_core_actions',
        ownerSessionId: 's1',
        requestType: 'codex_mcp_status_request',
        requestId: 'wrong',
        message: 'unsupported',
        errorCode: 'unsupported_message',
      ),
    );
    await _flush();
    expect(controller.mcpLoading, isTrue);

    bridge.local.add(
      LocalFeatureRequestErrorMessage(
        featureId: 'codex_core_actions',
        ownerSessionId: 's1',
        requestType: 'codex_mcp_status_request',
        requestId: requestId,
        message: 'unsupported',
        errorCode: 'unsupported_message',
      ),
    );
    await _flush();
    expect(controller.mcpLoading, isFalse);
    expect(controller.mcpErrorCode, 'unsupported_message');
    expect(controller.mcpLoaded, isFalse);
  });

  test('MCP empty state becomes authoritative only after a response', () async {
    final bridge = _Bridge();
    final controller = CodexCoreActionsController(
      sessionId: 's1',
      bridge: bridge,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    expect(controller.mcpLoaded, isFalse);
    controller.refreshMcpStatus();
    final requestId = _json(bridge.sent.single)['requestId'] as String;
    bridge.local.add(
      CodexMcpStatusResultMessage(
        sessionId: 's1',
        requestId: requestId,
        status: 'completed',
        servers: const [],
        serversTruncated: false,
      ),
    );
    await _flush();
    expect(controller.mcpLoaded, isTrue);
    expect(controller.servers, isEmpty);
  });

  test('disconnect clears pending live-only requests', () async {
    final bridge = _Bridge();
    final controller = CodexCoreActionsController(
      sessionId: 's1',
      bridge: bridge,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.requestCompact();
    controller.refreshMcpStatus();
    bridge.connected = false;
    bridge.connections.add(BridgeConnectionState.disconnected);
    await _flush();
    expect(controller.actionLoading, isFalse);
    expect(controller.mcpLoading, isFalse);
    expect(controller.actionErrorCode, 'disconnected');
    expect(controller.mcpErrorCode, 'disconnected');
  });

  test('stale runtime binding fails closed before any core action send', () {
    final bridge = _Bridge();
    var currentSessionId = 's1';
    final controller = CodexCoreActionsController(
      sessionId: 's1',
      bridge: bridge,
      sessionIdIsCurrent: (candidate) => candidate == currentSessionId,
    )..start();
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    currentSessionId = 's2';
    expect(controller.requestCompact(), isFalse);
    expect(
      controller.requestReview(const CodexReviewUncommittedTarget()),
      isFalse,
    );
    expect(controller.refreshMcpStatus(), isFalse);
    expect(bridge.sent, isEmpty);
  });
}
