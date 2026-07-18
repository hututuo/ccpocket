# Mobile File Transfer v01

Status: accepted

Date: 2026-07-18

## Objective

Add an independently removable, live Bridge file-transfer surface:

- `ccpocket-bridge send <path>` sends an explicit local file to a connected,
  compatible phone;
- the phone automatically downloads the offered file into the app Documents
  `Downloads` directory, which is already exposed through iOS Files, then
  posts a local notification;
- the phone can explicitly pick a document and upload it to the current Mac;
  the Bridge commits it atomically into `~/Downloads` without overwriting an
  existing file.
- pure transfer accepts files up to 15 GiB in either direction and resumes
  from the last durably confirmed byte after an interruption; the existing
  artifact preview surface remains independently capped at 2 GiB.

This is a CC Pocket transport feature. It is not Codex app-server state, never
enters conversation history, and never changes Codex session semantics.

## Authority and transport

- The existing authenticated WebSocket is the control plane. New Mobile peers
  advertise the additive response types they can consume; an old Mobile is
  never sent an offer it cannot parse.
- The existing Bridge HTTP listener is the byte plane. No extra listener,
  daemon, LaunchAgent, public relay, or global background queue is created.
- Mac-to-phone downloads use a transfer-only, identity-checked token and HTTP
  byte-range endpoint. They do not raise the 2 GiB preview limit. A persisted
  phone-side partial file records the source validator and confirmed offset so
  the same offer can continue after a network interruption or app restart.
  The CLI control endpoint remains loopback-only and uses the existing
  `X-CCPocket-Control` convention.
- Phone-to-Mac uploads use an authenticated WebSocket prepare/status exchange
  plus a short-lived random HTTP session token. The stable client transfer id,
  declared basename, total length, durable partial length, and expiry are
  persisted separately from the token. Re-preparing the same transfer after a
  disconnect issues a fresh token and returns the accepted offset; the token
  can authorize only that session and byte range.
- V2 uses a live authenticated socket to create or resume capabilities. iOS
  may suspend sockets in the background; this version does not claim silent
  APNs delivery. Durable partial state lets an interrupted transfer continue
  after the app and the same logical Bridge connection become active again.

## Storage and safety

- Mobile reserves a collision-free destination before streaming, writes to a
  private partial file, durably records the confirmed offset and source
  validator, verifies the exact 64-bit byte count, and publishes with an
  atomic no-clobber hard link only at the commit point. Existing files are
  never overwritten; a persisted committing/complete tombstone closes crash
  windows before the private partial link is removed.
- The iOS document picker copies a user-selected security-scoped document into
  a private resumable staging directory before Flutter uploads it. The staged
  copy survives transient disconnects and is removed after success, explicit
  cancellation, or retention expiry; it is never exposed as a completed file.
- Bridge upload names are basename-only, UTF-8 bounded, stripped of control
  characters and separators, and cannot be `.` or `..`.
- The Bridge resolves and validates the configured download directory, rejects
  symlink substitution at the destination boundary, reserves with exclusive
  creation, streams with a strict maximum, and publishes with an atomic
  no-clobber hard link on the same filesystem.
- Default Mac destination is `~/Downloads`; an optional
  `BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR` may narrow it to another explicit local
  directory. The response reports the actual collision-free basename.
- Transfer-only files are capped at 15 GiB; browser/app preview remains capped
  at 2 GiB. Each direction has bounded concurrency, queue length, connect,
  idle, total, offer/token TTL, and partial-retention limits. Disconnect never
  causes an upload or destructive intent to be replayed as a new transfer.
- The server advertises a 16 MiB maximum chunk, not a fixed allocation. A
  whole file at or below the negotiated maximum -- especially the common
  1--10 MiB case -- uses one exact-length streamed data request. Larger files
  start at 4 MiB and adapt between 1 and 16 MiB toward roughly 2--4 seconds per
  chunk: sustained success grows the window, while timeout, disconnect, or a
  failed chunk halves it. No 16 MiB buffer is preallocated merely because that
  is the limit. Resume correctness depends only on durably confirmed offsets,
  not on a persisted chunk size.
- Resume validates the exact server-accepted offset before appending. A stale
  source validator, mismatched length/name/id, offset disagreement, expired
  session, or replaced destination fails closed instead of concatenating the
  wrong bytes.

## CLI behavior

```text
ccpocket-bridge send <path> [--ttl <seconds>] [--base-url <url>] [--json]
```

- With exactly one compatible live phone, it sends the offer and reports the
  recipient count and expiry.
- With no compatible live phone, it fails without pretending the file was
  delivered.
- Multiple compatible phones require an explicit future targeting design;
  v2 fails closed instead of broadcasting private data unexpectedly.
- The source must be inside the existing Bridge allowed directories and must
  still match the opened file identity on every ranged download. The default
  lifetime must be long enough for a 15 GiB transfer; `--ttl` remains bounded
  and explicit.

## Mobile behavior

- A dedicated service handles offers, one transfer at a time, outside the chat
  runtime and offline outgoing-message queue. Only resumable transfer metadata
  and private partial bytes persist; no Codex message is synthesized.
- Success and failure acknowledgements are correlated by transfer id. Duplicate
  offers are idempotent and cannot reserve duplicate files.
- A successful receive posts a local notification with the saved filename.
- A small transfer surface exposes `Upload to Mac`, current progress, recent
  in-memory results, and the iOS Files location. Old Bridges show the feature
  as unavailable without affecting chat.

## Compatibility matrix

| Mobile | Bridge | Behavior |
|---|---|---|
| old | new | no advertised offer support; no transfer messages sent |
| new | old | no `file_transfer_v2` capability; upload UI disabled |
| new | new | live automatic receive and explicit upload enabled |
| any | future | unknown message types are ignored; the security-sensitive v2 shapes reject unexpected control fields, and incompatible extensions use a new capability/version |

## Module boundary

Keep animation, Bridge transfer, and Mobile transfer as separate commits. The
Bridge behavior commit owns the CLI, HTTP/token manager, protocol, tests, and a
documented whitelist of narrow `cli.ts`, `index.ts`, parser, WebSocket, and
session-list capability hooks. The Mobile behavior commit owns its service,
iOS picker, UI, protocol/tests, and a documented whitelist of narrow app host
hooks. Each behavior commit must be directly revertible from final HEAD, leave
the opposite peer usable, and pass remaining build/tests. Complete reverse
order must reproduce the selected pre-transfer tree exactly.

## Verification gates

- loopback-only CLI control and zero-recipient failure;
- source identity/path authorization and token expiry/single use;
- upload traversal, symlink, collision, oversize, short/long body, disconnect,
  timeout, cancellation, offset mismatch, stale validator, Bridge/app restart,
  partial retention, and atomic-commit tests;
- 15 GiB boundary arithmetic is tested without allocating a 15 GiB fixture;
  preview tests continue to reject files above 2 GiB;
- old/new peer protocol tests and strict request/transfer correlation;
- Mobile duplicate-offer, queue bound, byte mismatch, notification, picker
  cleanup, disconnect and reduced-storage failure tests;
- Bridge full build/tests, Flutter analyze/full tests, iOS Simulator build;
- direct Bridge/Mobile feature reverts and complete reverse-tree equality;
- no deployment, installation, or LaunchAgent restart without a separate
  explicit decision.

## Acceptance results

The accepted source is isolated on
`feature/mobile-codex-parity-modular-final` at `83a0ca9`. The two removable
behavior commits are `e439bf3` (`feat(bridge): 增加可续传手机文件互传`) and
`83a0ca9` (`feat(mobile): 增加双向断点续传文件互传`). They remain outside the
stable branch and outside the running Bridge and installed phone app.

- Adaptive transfer behavior is frozen as follows: a file no larger than the
  negotiated maximum uses one exact streamed request; larger files start at
  4 MiB, adapt between 1 and 16 MiB toward a roughly 2--4 second request, halve
  after failure, and always use the exact remaining tail. Chunk size is not
  persisted and no 16 MiB buffer is preallocated solely because it is the
  server maximum.
- The complete Bridge build and suite passed: 70 files, 1325 tests, 0
  failures. The dedicated Bridge transfer suite passed 96 tests.
- Flutter analysis completed with 0 errors and 0 warnings; 48 informational
  lints remain. The complete Flutter suite passed 1790 tests with 4
  environment-dependent skips and 0 failures. The dedicated Mobile transfer
  suite passed 104 tests.
- An unsigned iOS Simulator build completed at
  `apps/mobile/build/ios/iphonesimulator/Runner.app`; native RunnerTests passed
  9 of 9 on iPhone 17 Pro / iOS 26.1.
- Direct Bridge removal from final HEAD was conflict-free. The old Bridge
  rebuilt and passed 348 focused regressions, while the retained new Mobile
  passed 96 protocol/UI tests including the explicit unsupported-old-Bridge
  fallback. Its synthetic gated tree was
  `c7eb15d961f7e6e00fa1bd28a0beb7f87bea174e`.
- Direct Mobile removal from final HEAD was conflict-free. The retained Bridge
  rebuilt and passed all 96 transfer tests; the restored old Mobile analyzed
  with 0 errors and 0 warnings. Its synthetic gated tree was
  `c4f71253c0e9ee4553a899b93b48b03bb72b0d42`.
- Reverse-removing Mobile and then Bridge reproduced `623040a^{tree}` exactly:
  both trees were `5f163412b7d127512c20ea73adffd87781b6c1d6`.
- The final independent review reported P0 = 0, P1 = 0, and P2 = 0 after the
  receive-state, notification-retry, identity-generation, lock-metadata, and
  shutdown-observability corrections.
- No Bridge process, LaunchAgent, Simulator installation, physical-phone app,
  Codex session source, or global configuration was changed by this batch.
