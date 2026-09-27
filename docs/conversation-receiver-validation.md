# Conversation receiver validation

The headless receiver test mounts the production `DurableSessionPreviewUpdater`
and uses a real Bridge, WebSocket, Mobile decoder, sync service, SQLite repository
and ChatSessionCubit. All provider content is synthetic. A separate full-page
test below covers the parent screen/cache observer. Shared-runtime ownership
has a separate synthetic real-socket gate in `shared-runtime-wire-validation.md`.
OS process restart and physical device UI remain separate validation gates.
Passing these tests does not authorize deployment.

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
After validating canonical content, the test disposes its sync writer before the
warm accepted-input scenario. Otherwise a legitimate partial live-input patch
could race database closure and invalidate the independently complete cold-cache
fixture. The live socket/receipt path remains active for warm acceptance.

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
The full suite uses `CCPOCKET_CHAIN_TRACE_PARENT` with unique per-process folders
and saves failure traces even when a receiver assertion fails.
Fixtures use isolated HOME/CODEX_HOME and ephemeral loopback ports, and remove
their temporary provider home after shutdown. Trace artifacts remain available.
Record the exact source SHA and workflow run when reporting results; candidate
builds, signing, installation and device acceptance must remain separately stated.

## Complete chat page acceptance

The conversation_full_page_test.dart test mounts the real CodexSessionScreen,
with production BridgeService, ConversationContentSyncService, SessionListCubit
and an on-disk SQLite repository. Its existing widget host now accepts a real
BridgeService as well as the mock used by isolated unit tests. The test always
selects the synthetic **stdio JSON-RPC** provider; the Bridge is never mocked.
The widget host stubs only OS engine/drop-format registration and maps font
assets to the repository's bundled JetBrains Mono font, with font HTTP fetching disabled.
These platform stubs do not claim native drag-and-drop or typeface acceptance.
Provider initialization is awaited explicitly; a session-list row alone can
precede the actual runtime-ready signal.

Only the provider receives the expected messages. The test does not construct a
ChatSessionCubit, call its update methods, feed cached messages into an updater,
or trigger a screen cache reload. The production page subscribes to sync updates
and reads SQLite itself. Test frame pumping lets those asynchronous reads render.
For each update, SQLite IDs/text/order must match the page's production Cubit;
visible text and actual intermediate-group descendants are checked separately.
The page, updater and Cubit identities must stay unchanged during updates.

The case checkpoints cover:

1. Initial cached user message, two live intermediate outputs, and final answer.
2. Two collapsed intermediate segments with final text outside the container.
3. Same ID/count with revised text, updated without leaving the page.
4. Actual disclosure taps, intermediate text order/ancestry and collapse behavior.
5. Page disposal/recreation preserving rows and restoring collapsed history.
6. Duplicate/late real Bridge frames, drained by replay-specific ACK barriers.
7. Socket termination, cached display and page recreation while still offline.
8. Same-source reconnect, then rejected old-subscription frames.
9. Reordered and dropped frames followed by a new subscription and new final text.

After the Bridge build, run from apps/mobile:

    flutter test test/blackbox/conversation_full_page_test.dart --reporter expanded

The cloud workflow runs this separately before both receiver modes and again
within the full Mobile suite. The full-page-timeline.jsonl evidence records PASS
checkpoints and the first failing stage alongside RPC/wire traces. Every claim
still needs the exact source SHA and completed workflow result.

Page recreation is a widget lifecycle test, not navigation-router, OS process
restart, simulator, keyboard, scrolling-feel, iPhone or backgrounding acceptance.
The receiver test separately covers a cold SQLite/repository reopen. Synthetic
provider coverage does not replace private real-rollout replay or shared-runtime
control ownership validation. No production service, signing or installation is
part of these tests.
