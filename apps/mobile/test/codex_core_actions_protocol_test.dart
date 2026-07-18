import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

void main() {
  test('builds bounded compact and review requests', () {
    expect(
      _json(requestCodexCompact(sessionId: 's1', requestId: 'r1')),
      {
        'type': 'codex_compact_request',
        'sessionId': 's1',
        'requestId': 'r1',
      },
    );
    expect(
      _json(
        requestCodexReview(
          sessionId: 's1',
          requestId: 'r2',
          target: const CodexReviewBaseBranchTarget(' main '),
        ),
      ),
      {
        'type': 'codex_review_request',
        'sessionId': 's1',
        'requestId': 'r2',
        'target': {'type': 'baseBranch', 'branch': 'main'},
      },
    );
    expect(
      () => requestCodexReview(
        sessionId: 's1',
        requestId: 'r3',
        target: const CodexReviewCustomTarget('  '),
      ),
      throwsArgumentError,
    );
    expect(
      () => requestCodexReview(
        sessionId: 's1',
        requestId: 'r4',
        target: CodexReviewCommitTarget(List.filled(129, 'a').join()),
      ),
      throwsArgumentError,
    );
  });

  test('decodes correlated action results', () {
    final message = ServerMessage.fromJson({
      'type': 'codex_action_result',
      'sessionId': 's1',
      'requestId': 'r1',
      'action': 'review',
      'status': 'accepted',
      'turnId': 'turn-1',
      'reviewThreadId': 'thread-2',
    });
    expect(
      message,
      isA<CodexActionResultMessage>()
          .having((value) => value.accepted, 'accepted', isTrue)
          .having((value) => value.turnId, 'turnId', 'turn-1'),
    );

    expect(
      () => ServerMessage.fromJson({
        'type': 'codex_action_result',
        'sessionId': 's1',
        'requestId': 'r1',
        'action': 'delete',
        'status': 'accepted',
      }),
      throwsFormatException,
    );
  });

  test('decodes bounded MCP status without machine configuration fields', () {
    final message = ServerMessage.fromJson({
      'type': 'codex_mcp_status_result',
      'sessionId': 's1',
      'requestId': 'm1',
      'status': 'completed',
      'serversTruncated': false,
      'servers': [
        {
          'name': 'docs',
          'authStatus': 'authenticated',
          'toolCount': 1,
          'toolsTruncated': false,
          'serverInfo': {
            'name': 'docs',
            'title': 'Docs',
            'version': '1.0',
            'secret': 'must-not-survive',
          },
          'tools': [
            {
              'name': 'search',
              'title': 'Search',
              'description': 'Read docs',
              'inputSchema': {'type': 'object'},
            },
          ],
        },
      ],
    }) as CodexMcpStatusResultMessage;

    expect(message.servers, hasLength(1));
    expect(message.servers.single.serverInfo?.title, 'Docs');
    expect(message.servers.single.tools.single.name, 'search');
    expect(message.servers.single.toolCount, 1);
  });

  test('request correlation is exact by session, request, and action', () {
    final request = LocalFeatureProtocolHost.describeRequest(
      requestCodexCompact(sessionId: 's1', requestId: 'r1'),
    )!;
    const correct = CodexActionResultMessage(
      sessionId: 's1',
      requestId: 'r1',
      action: 'compact',
      status: 'accepted',
    );
    const wrongAction = CodexActionResultMessage(
      sessionId: 's1',
      requestId: 'r1',
      action: 'review',
      status: 'accepted',
    );
    expect(
      LocalFeatureProtocolHost.matchesTerminalResponse(request, correct),
      isTrue,
    );
    expect(
      LocalFeatureProtocolHost.matchesTerminalResponse(request, wrongAction),
      isFalse,
    );
  });
}
