# Bridge warm-switch investigation v01

Status: reference; architecture direction requires implementation and tests.

## Incident facts

At 2026-07-31 18:38 local time, thread
`019fa630-e195-7eb1-a856-9b6e95e6e494` sent a delegation to the persistent
release thread `019f8e9d-2490-79c0-817c-87e3eb93ea2f`. The delegation said
“请立即执行” and explicitly authorized a Bridge LaunchAgent switch/restart and
owner OTA. That stale delegated authority conflicted with the user's later
instruction to wait for a direct backend-update command. The release thread
was corrected before installing its stale `234ccd89` staging runtime; the
production entry remained `compat.10-4fcdcd25` until the user subsequently
authorized the direct latest-source deployment recorded alongside this note.

The source thread was resumed through a Bridge-owned private app-server. The
release target did not appear in Bridge `resume_session` logs and continued
after the Bridge restart, so that release turn was hosted by an independent
Codex execution path. Cross-thread delivery and execution ownership are
separate: sending to another thread does not make the target Bridge-owned.

## Current lifecycle fact

Production currently leaves `BRIDGE_CODEX_APP_SERVER_MODE` unset, which means
`private`. Each Bridge session spawns `codex app-server --listen stdio://` as a
child. `CodexProcess.stop()` terminates that child; Bridge shutdown calls
`sessionManager.destroyAll()`. A private app-server and an in-flight turn cannot
be transferred to a replacement Bridge because the stdio pipes and JSON-RPC
state belong to the old process.

## Safe near-term switch

Until app-server lifecycle is separated, Bridge updates must be drain-aware:

1. Build and smoke the candidate without touching production.
2. Enter a maintenance/drain state that rejects new starts and mutations but
   keeps reads available.
3. Wait for all Bridge-owned turns to become idle; show the blocking thread IDs
   and require explicit force confirmation rather than using a fixed timeout.
4. Persist queues, cache state, watermarks, runtime/thread bindings, and the
   rollback entry.
5. Let an independent host updater—not a session using the target Bridge—flip
   the versioned runtime and restart launchd transactionally.
6. Reconnect Mobile, rescan authoritative thread/status state, fill gaps, and
   leave maintenance only after health and identity checks pass.

This avoids interruption but may defer an update until long turns finish.

## Long-term warm switch

Move app-server ownership to a separate LaunchAgent and run Bridge in existing
`external` mode against a loopback endpoint. Then a Bridge restart closes only
its WebSocket client while the app-server and active turns remain alive. The
new Bridge reconnects, reads `thread/list` and status, and reconciles missed
timeline gaps.

Before production use, the experimental transport needs loopback-only binding,
authentication or a protected Unix-socket equivalent, stable source identity,
reconnect/event-gap recovery, ownership tests, and a separate drain procedure
for upgrading the app-server daemon itself. `managed` mode is not sufficient:
the shared app-server is still a Bridge child and Bridge shutdown explicitly
stops it.

## Release authority gate

A worker may build or register a release request, but it must not activate a
runtime merely by messaging the persistent release thread. Activation requires
a fresh, expiring authorization record containing the exact source HEAD,
scope, channel, target service, and user/coordinator approval. The release
thread must re-read that record immediately before the irreversible switch;
newer user instructions revoke the old generation. Build and activation are
separate gates.
