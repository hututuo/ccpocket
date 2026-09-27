# Shared-runtime wire validation

This regression gate uses synthetic provider data with production Bridge code.
It complements the Mobile receiver and full-page tests in
`conversation-receiver-validation.md`; it does not replace those tests.

## Executed path

The fixture binds a WebSocket app-server to a private Unix socket and provides
an isolated version-only executable. The production daemon verifier checks the
fixture's file ownership, path, permissions and socket identity. The version
response is synthetic: this does not validate the installed Codex daemon or
Desktop compatibility.

Production `UnixSocketCodexTransport`, `CodexProcess`, attachment registry,
`CodexSharedRuntimeControl`, file-backed Action Broker, writer lease and
`BridgeWebSocketServer` execute unchanged. Two API-key-authenticated loopback
clients send ordinary action protocol messages. There is no mocked Bridge,
control transport, Action Broker, writer lease or WebSocket message handler.
The catalog watcher is inert because these cases exercise control ownership,
not filesystem discovery. Provider identities and content are synthetic.

## Assertions

- An observer cannot rename, archive, unarchive or delete, even when its source's
  writer gates are open. Read RPCs continue to work. Unit tests additionally
  fence `thread/start` and preserve the formal-writer/private modes.
- Formal adoption replaces the observer atomically. A competing formal owner
  fails before opening another socket; another thread remains readable.
- Disconnecting and reattaching clears ownership of the former turn and pending
  approvals. Reading the still-active turn cannot grant approval or interrupt
  authority to the replacement attachment.
- Two control connections share one on-disk writer lease. The standby can read
  but cannot mutate. Only releasing the holder allows the standby to acquire a
  new authority generation; the former lease cannot reassert ownership.
- Two authenticated clients see the same live approval. Wrong source, thread,
  turn or generation is rejected without a provider response. Concurrent valid
  approvals emit exactly one provider response.
- A real control socket disconnect/reconnect changes authority. Old control and
  client responses fail closed. Replaying the same provider request bytes on
  the replacement socket creates a new opaque request; only the new authority
  can answer it.

The approval payload check counts shared object references for every serialized
occurrence. It rejects genuine ancestor cycles, excessive nesting, nodes,
individual string bytes and serialized bytes. Regression cases include real
command, file-change and permission projections that intentionally share arrays
or permission objects between display context and response metadata.

## Running and evidence

From `packages/bridge`:

```sh
npx vitest run src/codex-shared-runtime-wire.test.ts \
  src/codex-shared-runtime-pilot.test.ts \
  src/codex-action-payload-limits.test.ts
```

Set `CCPOCKET_SHARED_WIRE_TRACE_DIR` to retain JSON evidence. Each test writes its
name, asserted checkpoints, source SHA when running in GitHub, and captured
provider/client frames with SHA-256 hashes. The reconnect case replays the
original provider bytes. Client-side action envelopes are derived from actual
Bridge projections; no fixture fabricates a Bridge reply. Evidence is preserved
on assertion failure as well. The cloud workflow uploads these records from the
complete Bridge suite, including failed runs.

The socket gate runs on macOS/Linux and skips Windows, where daemon mode is not
supported. It needs Node dependencies, not a local Flutter installation.

## Separate gates

This proves server-side protocol and authority behavior with synthetic data.
It does not prove a Flutter approval button, application navigation, a private
frozen rollout, the real Desktop daemon/version, OS lifecycle, phone interaction
or production deployment. Existing full-page receiver evidence remains tied to
its own source SHA; rerun the cloud suite for the candidate containing these fixes.
Signing, installation, OTA, release and stable promotion remain separate actions.
