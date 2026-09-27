# Conversation receiver validation

The headless receiver test mounts the production `DurableSessionPreviewUpdater`
and uses a real Bridge, WebSocket, Mobile decoder, sync service, SQLite repository
and ChatSessionCubit. All provider content is synthetic. The parent screen/cache
observer, shared-runtime ownership, OS process restart and physical device UI are
separate validation gates. Passing this test does not authorize deployment.

## Provider modes

- Default `notification`: a synthetic CodexProcess subclass invokes notification
  handling and supplies provider history. This preserves the original regression
  fixture and does not cover app-server framing or request/response correlation.
- `CCPOCKET_CHAIN_PROVIDER_MODE=stdio-json-rpc`: an isolated executable pipes
  provider bytes into the real private StdioCodexTransport and CodexProcess.
  Initialization, thread reads/resume, turn/start, notification decoding and the
  production input loop run normally. A synthetic loopback provider supplies the
  JSON-RPC responses; no installed Codex CLI, credentials or user history is used.
  The harness history adapter calls a real initialized CodexProcess over RPC and
  converts its returned turns. It does not test filesystem rollout discovery.

The synthetic catalog monitor signals provider-scoped changes explicitly. The
accepted outgoing message deliberately remains absent from canonical provider
history, distinguishing warm acceptance overlays from committed SQLite content.

## Faults and completion barriers

The wire controller records original Bridge-emitted text frames and replays those
exact bytes. Checkpoints are limited to a known subscription and committed
sequence. Hashes in `wire-fault.jsonl` identify the original payloads.

1. Save a checkpoint, revise final text without changing IDs or count, then replay
   the old checkpoint twice in reverse order. Drain original ACKs first and require
   an ACK for every replay. Reject the test barrier if ordinary traffic overlaps.
2. Terminate the real socket, read the committed cache offline, reconnect to the
   same source and verify a new subscription with no unnecessary timeline resend.
   Reconnection is explicit; automatic retry/backoff timing is not asserted.
3. Replay the old subscription on the new socket. Observe every decoded frame,
   require subscription-rejection diagnostics and unchanged cache/runtime authority.
4. Swap two newly emitted frames, then separately drop one new frame. Require a
   real sequence-gap diagnostic, subscription recovery and exact new content.
5. Preserve message IDs/order, two intermediate segments and final placement.
   Close SQLite, dispose the live chain, open a new database/repository/Cubit and
   compare committed content offline. No fixed sleep substitutes for completion.

## Running and evidence

Build the Bridge with `npm run bridge:build`. From `apps/mobile`, run
`flutter test test/blackbox/conversation_live_segment_receiver_test.dart`. Set the
provider mode above to run the same receiver assertions through raw RPC. The
`cloud-checks-candidate.yml` workflow executes both modes independently, followed
by the complete Flutter suite. Flutter need not be installed on the development
host when using this cloud workflow.

`CCPOCKET_CHAIN_TRACE_ROOT` selects an artifact directory. Evidence includes
provider reads/messages, original Bridge/client frames, wire-fault actions,
receiver checkpoints and (in RPC mode) raw `app-server-wire.jsonl` traffic.
Fixtures use isolated HOME/CODEX_HOME and ephemeral loopback ports, and remove
their temporary provider home after shutdown. Trace artifacts remain available.
Record the exact source SHA and workflow run when reporting results; candidate
builds, signing, installation and device acceptance must remain separately stated.
