import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/codex_action_broker/codex_action_broker_service.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final featureMessages =
      StreamController<LocalFeatureServerMessage>.broadcast();
  final connections = StreamController<BridgeConnectionState>.broadcast();
  final sessionEvents = StreamController<List<SessionInfo>>.broadcast();
  final sent = <Map<String, dynamic>>[];
  bool connected = true;
  bool brokerSupported = true;
  String? currentBridgeId = 'bridge-1';
  String? currentSourceId = 'source-1';

  @override
  bool get isConnected => connected;

  @override
  bool get supportsCodexActionBroker => brokerSupported;

  @override
  String? get bridgeInstanceId => currentBridgeId;

  @override
  String? get codexSourceId => currentSourceId;

  @override
  Stream<LocalFeatureServerMessage> get localFeatureMessages =>
      featureMessages.stream;

  @override
  Stream<BridgeConnectionState> get connectionStatus => connections.stream;

  @override
  Stream<List<SessionInfo>> get sessionList => sessionEvents.stream;

  @override
  void send(ClientMessage message) {
    sent.add(jsonDecode(message.toJson()) as Map<String, dynamic>);
  }

  void emit(LocalFeatureServerMessage message) => featureMessages.add(message);

  @override
  void dispose() {
    featureMessages.close();
    connections.close();
    sessionEvents.close();
    super.dispose();
  }
}

CodexActionBrokerHealth _health({
  bool ready = true,
  bool writerLeaseHeld = true,
  String generation = 'cab:generation-1',
  String? degradedReason,
}) => CodexActionBrokerHealth(
  ready: ready,
  controlReady: true,
  degraded: degradedReason != null,
  writerLeaseHeld: writerLeaseHeld,
  degradedReason: degradedReason,
  authorityGeneration: generation,
);

CodexActionBrokerRequest _request({
  String opaqueRequestId = 'opaque-1',
  String source = 'source-1',
  String thread = 'thread-1',
  String turn = 'turn-1',
  String generation = 'cab:generation-1',
  CodexActionBrokerRequestState state = CodexActionBrokerRequestState.pending,
  CodexActionBrokerRequestKind kind =
      CodexActionBrokerRequestKind.commandApproval,
  bool live = true,
  DateTime? observedAt,
  Map<String, dynamic>? input,
  Set<CodexActionBrokerDecision> actions = const {
    CodexActionBrokerDecision.approve,
    CodexActionBrokerDecision.approveAlways,
    CodexActionBrokerDecision.reject,
  },
}) => CodexActionBrokerRequest(
  opaqueRequestId: opaqueRequestId,
  codexSourceId: source,
  threadId: thread,
  turnId: turn,
  kind: kind,
  state: state,
  observedAt: observedAt ?? DateTime.utc(2026, 8, 1),
  expiresAt: DateTime.utc(2026, 8, 1, 0, 5),
  updatedAt: DateTime.utc(2026, 8, 1, 0, 0, 1),
  authorityGeneration: generation,
  live: live,
  toolName: kind == CodexActionBrokerRequestKind.commandApproval
      ? 'Bash'
      : null,
  input:
      input ??
      (kind == CodexActionBrokerRequestKind.userInput
          ? const {
              'questions': [
                {
                  'id': 'q1',
                  'question': 'Continue?',
                  'header': 'Choice',
                  'options': [],
                  'multiSelect': false,
                },
              ],
            }
          : const {'command': 'echo ok'}),
  allowedActions: actions,
);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late _Bridge bridge;
  late CodexActionBrokerRuntimeFence fence;
  late CodexActionBrokerService service;
  var nextId = 0;

  setUp(() {
    bridge = _Bridge();
    fence = const CodexActionBrokerRuntimeFence(
      turnId: 'turn-1',
      authorityGeneration: 'daemon:runtime-uuid-1',
      executionHost: 'desktopAppServer',
    );
    service = CodexActionBrokerService(
      bridge: bridge,
      threadId: 'thread-1',
      expectedBridgeInstanceId: 'bridge-1',
      expectedCodexSourceId: 'source-1',
      runtimeFence: () => fence,
      createId: () => 'id-${++nextId}',
      loadClaimantId: () async => 'mobile-claimant',
    )..start();
  });

  tearDown(() {
    service.dispose();
    bridge.dispose();
  });

  test('ordinary Desktop activity does not create an approval overlay', () {
    expect(service.ownsDetachedInteraction(waitingApproval: false), isFalse);
    expect(service.ownsDetachedInteraction(waitingApproval: true), isTrue);
    expect(service.phase, CodexActionBrokerInteractionPhase.loading);

    bridge.currentSourceId = 'different-source';
    expect(service.ownsDetachedInteraction(waitingApproval: false), isFalse);
    expect(service.ownsDetachedInteraction(waitingApproval: true), isTrue);
    expect(service.actionable, isFalse);
    expect(service.phase, CodexActionBrokerInteractionPhase.stale);
  });

  test(
    'stale old-turn request only owns an explicit waiting surface',
    () async {
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request(turn: 'old-turn')],
        ),
      );
      await _flush();

      expect(service.ownsDetachedInteraction(waitingApproval: false), isFalse);
      expect(service.ownsDetachedInteraction(waitingApproval: true), isTrue);
      expect(service.actionable, isFalse);
      expect(service.phase, CodexActionBrokerInteractionPhase.stale);
    },
  );

  test(
    'waiting approval without a request reports broker health honestly',
    () async {
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(
            ready: false,
            degradedReason: 'unsupported_server_request',
          ),
        ),
      );
      await _flush();
      expect(service.ownsDetachedInteraction(waitingApproval: true), isTrue);
      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.unsupportedRequest,
      );

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(ready: false, writerLeaseHeld: false),
        ),
      );
      await _flush();
      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.writerLeaseUnavailable,
      );

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(ready: false),
        ),
      );
      await _flush();
      expect(service.phase, CodexActionBrokerInteractionPhase.unavailable);

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
        ),
      );
      await _flush();
      expect(service.phase, CodexActionBrokerInteractionPhase.stale);
    },
  );

  test('old Bridge keeps the legacy path and sends no broker request', () {
    service.dispose();
    bridge.brokerSupported = false;
    bridge.sent.clear();
    service = CodexActionBrokerService(
      bridge: bridge,
      threadId: 'thread-1',
      expectedBridgeInstanceId: 'bridge-1',
      expectedCodexSourceId: 'source-1',
      runtimeFence: () => fence,
      createId: () => 'old-${++nextId}',
      loadClaimantId: () async => 'mobile-claimant',
    )..start();

    expect(service.capabilityNegotiated, isFalse);
    expect(service.ownsDetachedInteraction(waitingApproval: true), isFalse);
    expect(bridge.sent, isEmpty);
  });

  test(
    'catalog emissions do not repeatedly request broker snapshots',
    () async {
      expect(
        bridge.sent.where((message) => message['type'] == 'get_codex_actions'),
        hasLength(1),
      );

      bridge.sessionEvents.add(const []);
      bridge.sessionEvents.add(const []);
      await _flush();

      expect(
        bridge.sent.where((message) => message['type'] == 'get_codex_actions'),
        hasLength(1),
      );
    },
  );

  test('only an exact live writer-leased request is actionable', () async {
    bridge.emit(
      CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.snapshot,
        health: _health(),
        requests: [_request()],
      ),
    );
    await _flush();

    expect(service.actionable, isTrue);
    expect(service.presentation?.permission.toolName, 'Bash');
    expect(
      await service.respond(
        CodexActionBrokerDecision.approve,
        opaqueRequestId: 'opaque-1',
      ),
      isTrue,
    );
    final response = bridge.sent.last;
    expect(response['type'], 'respond_codex_action');
    expect(response['codexSourceId'], 'source-1');
    expect(response['threadId'], 'thread-1');
    expect(response['turnId'], 'turn-1');
    expect(response['authorityGeneration'], 'cab:generation-1');
    expect(response['claimantId'], 'mobile-claimant');
    expect(response['operationId'], isA<String>());

    bridge.emit(
      CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.response,
        requestId: response['requestId'] as String,
        opaqueRequestId: 'opaque-1',
        outcome: CodexActionBrokerResponseOutcome.submitted,
      ),
    );
    await _flush();
    expect(service.phase, CodexActionBrokerInteractionPhase.awaitingCanonical);
    final sentCount = bridge.sent.length;
    expect(
      await service.respond(
        CodexActionBrokerDecision.approve,
        opaqueRequestId: 'opaque-1',
      ),
      isFalse,
    );
    expect(bridge.sent, hasLength(sentCount));

    bridge.emit(
      CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.request,
        request: _request(state: CodexActionBrokerRequestState.resolved),
      ),
    );
    await _flush();
    expect(service.visibleRequest, isNull);
  });

  test(
    'wrong top-level opaque response cannot consume the pending RPC',
    () async {
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request()],
        ),
      );
      await _flush();
      await service.respond(
        CodexActionBrokerDecision.approve,
        opaqueRequestId: 'opaque-1',
      );
      final requestId = bridge.sent.last['requestId'] as String;

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.response,
          requestId: requestId,
          opaqueRequestId: 'wrong-opaque',
          outcome: CodexActionBrokerResponseOutcome.submitted,
        ),
      );
      await _flush();
      expect(service.phase, CodexActionBrokerInteractionPhase.submitting);

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.response,
          requestId: requestId,
          opaqueRequestId: 'opaque-1',
          outcome: CodexActionBrokerResponseOutcome.submitted,
        ),
      );
      await _flush();
      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.awaitingCanonical,
      );
    },
  );

  test(
    'wrong embedded response fences cannot consume the pending RPC',
    () async {
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request()],
        ),
      );
      await _flush();
      await service.respond(
        CodexActionBrokerDecision.approve,
        opaqueRequestId: 'opaque-1',
      );
      final requestId = bridge.sent.last['requestId'] as String;

      for (final wrongRequest in [
        _request(source: 'wrong-source'),
        _request(turn: 'wrong-turn'),
        _request(generation: 'wrong-generation'),
      ]) {
        bridge.emit(
          CodexActionBrokerEventMessage(
            event: CodexActionBrokerEventKind.response,
            requestId: requestId,
            opaqueRequestId: 'opaque-1',
            outcome: CodexActionBrokerResponseOutcome.submitted,
            request: wrongRequest,
          ),
        );
        await _flush();
        expect(service.phase, CodexActionBrokerInteractionPhase.submitting);
      }

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.response,
          requestId: requestId,
          opaqueRequestId: 'opaque-1',
          outcome: CodexActionBrokerResponseOutcome.submitted,
          request: _request(),
        ),
      );
      await _flush();
      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.awaitingCanonical,
      );
    },
  );

  test(
    'outcomeUnknown waits for canonical resolution and only refreshes',
    () async {
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request()],
        ),
      );
      await _flush();
      await service.respond(
        CodexActionBrokerDecision.reject,
        opaqueRequestId: 'opaque-1',
      );
      final response = bridge.sent.last;
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.response,
          requestId: response['requestId'] as String,
          opaqueRequestId: 'opaque-1',
          outcome: CodexActionBrokerResponseOutcome.outcomeUnknown,
        ),
      );
      await _flush();

      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.awaitingCanonical,
      );
      final operationId = response['operationId'];
      expect(
        await service.respond(
          CodexActionBrokerDecision.reject,
          opaqueRequestId: 'opaque-1',
        ),
        isFalse,
      );
      expect(service.refresh(), isTrue);
      expect(bridge.sent.last['type'], 'get_codex_actions');
      expect(
        bridge.sent
            .where((message) => message['operationId'] == operationId)
            .length,
        1,
      );
    },
  );

  test('unavailable response stays guarded until a fresh snapshot', () async {
    bridge.emit(
      CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.snapshot,
        health: _health(),
        requests: [_request()],
      ),
    );
    await _flush();
    await service.respond(
      CodexActionBrokerDecision.approve,
      opaqueRequestId: 'opaque-1',
    );
    final response = bridge.sent.last;
    bridge.emit(
      CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.response,
        requestId: response['requestId'] as String,
        opaqueRequestId: 'opaque-1',
        outcome: CodexActionBrokerResponseOutcome.unavailable,
      ),
    );
    await _flush();
    expect(service.actionable, isFalse);
    expect(service.phase, CodexActionBrokerInteractionPhase.unavailable);

    bridge.emit(
      CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.snapshot,
        health: _health(),
        requests: [_request()],
      ),
    );
    await _flush();
    expect(service.phase, CodexActionBrokerInteractionPhase.actionable);
  });

  test(
    'canonical snapshot clears an in-flight request it no longer lists',
    () async {
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request()],
        ),
      );
      await _flush();
      expect(
        await service.respond(
          CodexActionBrokerDecision.approve,
          opaqueRequestId: 'opaque-1',
        ),
        isTrue,
      );
      expect(service.phase, CodexActionBrokerInteractionPhase.submitting);

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
        ),
      );
      await _flush();
      expect(service.visibleRequest, isNull);

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request()],
        ),
      );
      await _flush();
      expect(service.phase, CodexActionBrokerInteractionPhase.actionable);
    },
  );

  test(
    'a request without safe projected actions stays non-interactive',
    () async {
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request(actions: const {})],
        ),
      );
      await _flush();

      expect(service.actionable, isFalse);
      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.unsupportedRequest,
      );
    },
  );

  test(
    'a reject-only question stays guarded instead of self-answering',
    () async {
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [
            _request(
              kind: CodexActionBrokerRequestKind.userInput,
              actions: const {CodexActionBrokerDecision.reject},
            ),
          ],
        ),
      );
      await _flush();

      expect(service.presentation?.usesAskUserUi, isTrue);
      expect(service.actionable, isFalse);
      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.unsupportedRequest,
      );
    },
  );

  test('a live pending request wins over an older claimed request', () async {
    bridge.emit(
      CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.snapshot,
        health: _health(),
        requests: [
          _request(
            opaqueRequestId: 'claimed-old',
            state: CodexActionBrokerRequestState.claimed,
            observedAt: DateTime.utc(2026, 8, 1),
          ),
          _request(
            opaqueRequestId: 'pending-new',
            observedAt: DateTime.utc(2026, 8, 1, 0, 1),
          ),
        ],
      ),
    );
    await _flush();

    expect(service.visibleRequest?.opaqueRequestId, 'pending-new');
    expect(service.phase, CodexActionBrokerInteractionPhase.actionable);
  });

  test('claimant loading rechecks live health before sending', () async {
    service.dispose();
    final claimant = Completer<String>();
    service = CodexActionBrokerService(
      bridge: bridge,
      threadId: 'thread-1',
      expectedBridgeInstanceId: 'bridge-1',
      expectedCodexSourceId: 'source-1',
      runtimeFence: () => fence,
      createId: () => 'deferred-${++nextId}',
      loadClaimantId: () => claimant.future,
    )..start();
    bridge.emit(
      CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.snapshot,
        health: _health(),
        requests: [_request()],
      ),
    );
    await _flush();

    final response = service.respond(
      CodexActionBrokerDecision.approve,
      opaqueRequestId: 'opaque-1',
    );
    bridge.emit(
      CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.health,
        health: _health(ready: false, writerLeaseHeld: false),
      ),
    );
    claimant.complete('mobile-claimant');

    expect(await response, isFalse);
    expect(
      bridge.sent.where((message) => message['type'] == 'respond_codex_action'),
      isEmpty,
    );
  });

  test(
    'correlated protocol error leaves a refreshable guarded request',
    () async {
      service.dispose();
      service = CodexActionBrokerService(
        bridge: bridge,
        threadId: 'thread-1',
        expectedBridgeInstanceId: 'bridge-1',
        expectedCodexSourceId: 'source-1',
        runtimeFence: () => fence,
        responseTimeout: const Duration(milliseconds: 1),
        createId: () => 'error-timeout-${++nextId}',
        loadClaimantId: () async => 'mobile-claimant',
      )..start();
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request()],
        ),
      );
      await _flush();
      await service.respond(
        CodexActionBrokerDecision.approve,
        opaqueRequestId: 'opaque-1',
      );
      final response = bridge.sent.last;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.awaitingCanonical,
      );

      bridge.emit(
        LocalFeatureRequestErrorMessage(
          featureId: 'codex_action_broker',
          ownerSessionId: 'other-thread',
          requestType: 'respond_codex_action',
          requestId: response['requestId'] as String,
          message: 'wrong owner',
          errorCode: 'unsupported_message',
        ),
      );
      await _flush();
      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.awaitingCanonical,
      );

      bridge.emit(
        LocalFeatureRequestErrorMessage(
          featureId: 'codex_action_broker',
          ownerSessionId: 'thread-1',
          requestType: 'respond_codex_action',
          requestId: response['requestId'] as String,
          message: 'unsupported',
          errorCode: 'unsupported_message',
        ),
      );
      await _flush();

      expect(service.phase, CodexActionBrokerInteractionPhase.unavailable);
      expect(bridge.sent.last['type'], 'get_codex_actions');

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request()],
        ),
      );
      await _flush();
      expect(service.phase, CodexActionBrokerInteractionPhase.actionable);
    },
  );

  test(
    'lost response becomes outcome-unknown and never auto-retries',
    () async {
      service.dispose();
      service = CodexActionBrokerService(
        bridge: bridge,
        threadId: 'thread-1',
        expectedBridgeInstanceId: 'bridge-1',
        expectedCodexSourceId: 'source-1',
        runtimeFence: () => fence,
        responseTimeout: const Duration(milliseconds: 1),
        createId: () => 'timeout-${++nextId}',
        loadClaimantId: () async => 'mobile-claimant',
      )..start();
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request()],
        ),
      );
      await _flush();
      await service.respond(
        CodexActionBrokerDecision.approve,
        opaqueRequestId: 'opaque-1',
      );
      final response = bridge.sent.last;
      final responseCount = bridge.sent
          .where((message) => message['type'] == 'respond_codex_action')
          .length;

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.awaitingCanonical,
      );
      expect(
        bridge.sent
            .where((message) => message['type'] == 'respond_codex_action')
            .length,
        responseCount,
      );

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.response,
          requestId: response['requestId'] as String,
          opaqueRequestId: 'opaque-1',
          outcome: CodexActionBrokerResponseOutcome.submitted,
        ),
      );
      await _flush();
      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.awaitingCanonical,
      );
    },
  );

  test(
    'late unavailable response releases timeout quarantine after refresh',
    () async {
      service.dispose();
      service = CodexActionBrokerService(
        bridge: bridge,
        threadId: 'thread-1',
        expectedBridgeInstanceId: 'bridge-1',
        expectedCodexSourceId: 'source-1',
        runtimeFence: () => fence,
        responseTimeout: const Duration(milliseconds: 1),
        createId: () => 'late-unavailable-${++nextId}',
        loadClaimantId: () async => 'mobile-claimant',
      )..start();
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request()],
        ),
      );
      await _flush();
      await service.respond(
        CodexActionBrokerDecision.approve,
        opaqueRequestId: 'opaque-1',
      );
      final response = bridge.sent.last;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.awaitingCanonical,
      );

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.response,
          requestId: response['requestId'] as String,
          opaqueRequestId: 'opaque-1',
          outcome: CodexActionBrokerResponseOutcome.unavailable,
        ),
      );
      await _flush();
      expect(service.phase, CodexActionBrokerInteractionPhase.unavailable);

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request()],
        ),
      );
      await _flush();
      expect(service.phase, CodexActionBrokerInteractionPhase.actionable);
    },
  );

  test(
    'wrong source, turn, generation or writer lease never becomes actionable',
    () async {
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(writerLeaseHeld: false, ready: false),
          requests: [_request()],
        ),
      );
      await _flush();
      expect(service.actionable, isFalse);
      expect(
        service.phase,
        CodexActionBrokerInteractionPhase.writerLeaseUnavailable,
      );

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request(turn: 'turn-other')],
        ),
      );
      await _flush();
      expect(service.actionable, isFalse);
      expect(service.phase, CodexActionBrokerInteractionPhase.stale);

      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [_request(generation: 'cab:old-generation')],
        ),
      );
      await _flush();
      expect(service.actionable, isFalse);
      expect(service.phase, CodexActionBrokerInteractionPhase.stale);

      bridge.currentSourceId = 'source-other';
      expect(service.visibleRequest, isNull);
      expect(service.actionable, isFalse);
    },
  );

  test(
    'question projection reuses AskUserQuestion and preserves reject',
    () async {
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [
            _request(
              kind: CodexActionBrokerRequestKind.userInput,
              actions: const {
                CodexActionBrokerDecision.answer,
                CodexActionBrokerDecision.reject,
              },
            ),
          ],
        ),
      );
      await _flush();

      expect(service.presentation?.usesAskUserUi, isTrue);
      expect(service.presentation?.permission.toolName, 'AskUserQuestion');
      expect(
        service.visibleRequest?.allowedActions,
        contains(CodexActionBrokerDecision.reject),
      );
    },
  );

  test(
    'MCP approval choices remain expressible through native question UI',
    () async {
      bridge.emit(
        CodexActionBrokerEventMessage(
          event: CodexActionBrokerEventKind.snapshot,
          health: _health(),
          requests: [
            _request(
              kind: CodexActionBrokerRequestKind.mcpElicitation,
              actions: const {
                CodexActionBrokerDecision.answer,
                CodexActionBrokerDecision.reject,
              },
              input: const {
                'questions': [
                  {
                    'id': 'approval',
                    'question': 'Allow this tool?',
                    'header': 'Approve app tool call?',
                    'options': [
                      {'label': 'Approve this Session'},
                      {'label': 'Always allow'},
                    ],
                    'multiSelect': false,
                  },
                ],
              },
            ),
          ],
        ),
      );
      await _flush();

      expect(service.presentation?.usesAskUserUi, isTrue);
      expect(service.presentation?.permission.toolName, 'AskUserQuestion');
      expect(service.phase, CodexActionBrokerInteractionPhase.actionable);
    },
  );
}
